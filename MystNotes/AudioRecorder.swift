import Foundation
import AVFoundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Records audio while the user writes, and plays it back (M3 seed).
///
/// Everything here is user-initiated and off the drawing path: nothing
/// starts until Record is tapped, and the only recurring work is a light
/// timer that updates two numbers for the bar. The audio is AAC in an
/// `.m4a`, written to a temp file and moved into Documents when the
/// recording stops, so a half-written file never sits under a name a
/// `Recording` points at. The file then syncs as a content-addressed
/// payload like an imported document's.
///
/// Wiring (the detail view owns one of these in `@State`):
///
///     @State private var audio = PageAudioController()
///     audio.record(page: page)      // start; asks for the microphone once
///     audio.stop()                  // stop recording (saves) or playback
///     audio.play(recording: r)      // start or resume
///
/// Call `audio.stop()` when the view disappears: recording does not
/// continue in the background (the app has no audio background mode), so
/// it is also stopped and saved when the app enters the background.
@MainActor
@Observable
final class PageAudioController: NSObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {

    enum MicrophoneAccess { case undetermined, granted, denied }

    static let rates: [Float] = [1, 1.5, 2]
    /// A recording shorter than this is a stray tap and is thrown away
    /// (its temp file is simply left for the system to clear).
    static let minimumDuration: TimeInterval = 0.5

    // MARK: Observable state

    private(set) var isRecording = false
    private(set) var isPlaying = false
    /// Seconds recorded so far in the current recording.
    private(set) var elapsed: TimeInterval = 0
    /// Playhead, seconds into the recording being played.
    private(set) var currentTime: TimeInterval = 0
    /// The recording loaded in the player (playing or paused), if any.
    private(set) var playingRecording: Recording?
    private(set) var rate: Float = 1
    private(set) var access: MicrophoneAccess = .undetermined
    /// A calm, user-facing sentence when something could not happen.
    var message: String?
    /// Recordings being transcribed right now.
    private(set) var transcribing: Set<UUID> = []
    /// The page the current recording is being made on.
    private(set) var recordingPageID: UUID?
    /// When the current recording began (wall clock). Strokes written after
    /// this carry offsets in the file.
    private(set) var recordingStartedAt: Date?

    // MARK: Private state

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tempURL: URL?
    @ObservationIgnored private var recordingPage: Page?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let directory: () -> URL

    /// `directory` is where finished recordings are stored; tests pass a
    /// temp directory.
    init(directory: @escaping () -> URL = { FileStore.baseDirectory() }) {
        self.directory = directory
        super.init()
        refreshAccess()
    }

    // MARK: Permission

    func refreshAccess() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: access = .granted
        case .denied: access = .denied
        default: access = .undetermined
        }
    }

    // MARK: Recording

    /// Starts recording on `page`. The first time, the system asks for the
    /// microphone; a refusal sets `access = .denied` and a `message`, and
    /// nothing else happens.
    func record(page: Page) {
        guard !isRecording else { return }
        message = nil
        Task { [weak self] in
            guard let self else { return }
            refreshAccess()
            if access == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
                refreshAccess()
            }
            guard access == .granted else {
                message = "Microphone access is off. You can turn it on in Settings to record audio on a page."
                return
            }
            beginRecording(on: page)
        }
    }

    private func beginRecording(on page: Page) {
        guard !isRecording else { return }
        pause()
        do {
            #if os(iOS) || targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            #endif
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("recording-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 64_000
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            let started = Date()
            guard recorder.record() else {
                message = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            tempURL = url
            recordingPage = page
            recordingPageID = page.id
            recordingStartedAt = started
            elapsed = 0
            isRecording = true
            startTimer(interval: 0.25)
            observeInterruptions()
        } catch {
            message = "Couldn't start recording."
            AppLog.note("audio", "record failed: \(error)")
        }
    }

    /// Stops whatever is running: a recording is saved to its page,
    /// playback is stopped and rewound.
    func stop() {
        if isRecording {
            finishRecording()
        } else {
            stopPlayback()
        }
    }

    private func finishRecording() {
        guard let recorder, let url = tempURL else { return }
        let duration = recorder.currentTime
        let started = recordingStartedAt
        let page = recordingPage
        recorder.stop()
        self.recorder = nil
        tempURL = nil
        recordingPage = nil
        recordingPageID = nil
        recordingStartedAt = nil
        isRecording = false
        elapsed = 0
        stopTimer()
        removeObservers()
        deactivateSession()

        guard duration >= Self.minimumDuration, let page, let started else { return }
        let name = "\(UUID().uuidString).m4a"
        do {
            try Self.install(url, as: name, in: directory())
        } catch {
            message = "Couldn't save the recording."
            AppLog.note("audio", "install failed: \(error)")
            return
        }
        // The page may have been deleted while recording.
        guard let context = page.modelContext else { return }
        let recording = Recording(page: page, startedAt: started, duration: duration, fileRef: name)
        context.insert(recording)
        page.recordings?.append(recording)
        page.markModified()
        do { try context.save() } catch {
            AppLog.note("audio", "save failed: \(error)")
        }
        transcribe(recording, announce: false)
    }

    // MARK: Transcription

    /// Transcribes `recording` on device, off the main thread, and stores the
    /// result. Derived data: this does not call `Page.markModified`; the
    /// transcript syncs with the page's next push. A failure or an empty
    /// result leaves the recording as it was; `announce` decides whether the
    /// user is told (a manual tap is, the automatic pass is not).
    func transcribe(_ recording: Recording, announce: Bool = true) {
        let id = recording.id
        guard !transcribing.contains(id) else { return }
        let url = directory().appendingPathComponent(recording.fileRef)
        guard !recording.fileRef.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
            if announce { message = "This recording's audio hasn't arrived on this device yet." }
            return
        }
        transcribing.insert(id)
        let task = RecordingTranscriber.transcribeDetached(fileURL: url, localeIdentifier: Locale.current.identifier)
        Task { [weak self, weak recording] in
            let outcome = await task.result
            guard let self else { return }
            transcribing.remove(id)
            switch outcome {
            case .success(let segments) where !segments.isEmpty:
                guard let recording, let context = recording.modelContext else { return }
                recording.transcript = segments.map(\.text).joined(separator: " ")
                recording.transcriptSegments = TranscriptSegment.encode(segments)
                do { try context.save() } catch {
                    AppLog.note("audio", "transcript save failed: \(error)")
                }
            case .success:
                if announce { message = "No speech was found, or transcription isn't available for this language on this device." }
            case .failure(let error):
                AppLog.note("audio", "transcribe failed: \(error)")
                if announce { message = "Couldn't transcribe that recording." }
            }
        }
    }

    /// Puts a finished temp file into `directory` under `name`, atomically:
    /// a rename on one volume, else a copy to a hidden staging name then a
    /// rename. The file never appears half-written under `name`, and
    /// nothing is removed except our own staging file after a failure.
    nonisolated static func install(_ temp: URL, as name: String, in directory: URL) throws {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(name)
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch {
            let staging = directory.appendingPathComponent(".\(name).tmp")
            try fm.copyItem(at: temp, to: staging)
            do { try fm.moveItem(at: staging, to: destination) } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    // MARK: Playback

    /// Plays `recording` from where it was paused, or from the start.
    func play(recording: Recording) {
        guard !isRecording else { return }
        message = nil
        if let player, playingRecording?.id == recording.id {
            player.enableRate = true
            player.rate = rate
            activatePlaybackSession()
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            isPlaying = true
            startTimer(interval: 0.1)
            return
        }
        let url = directory().appendingPathComponent(recording.fileRef)
        guard !recording.fileRef.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
            message = "This recording's audio hasn't arrived on this device yet."
            return
        }
        do {
            activatePlaybackSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            playingRecording = recording
            currentTime = 0
            player.play()
            isPlaying = true
            startTimer(interval: 0.1)
        } catch {
            message = "Couldn't play that recording."
            AppLog.note("audio", "play failed: \(error)")
        }
    }

    func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        currentTime = player.currentTime
        isPlaying = false
        stopTimer()
    }

    func togglePlayback(of recording: Recording) {
        if isPlaying, playingRecording?.id == recording.id { pause() } else { play(recording: recording) }
    }

    /// Moves the playhead; keeps playing if it was playing.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Loads `recording` if it is not the loaded one, then moves the playhead
    /// to `time` (used by a tap on a transcript segment).
    func seek(to time: TimeInterval, in recording: Recording) {
        if playingRecording?.id != recording.id {
            play(recording: recording)
            guard playingRecording?.id == recording.id else { return }
        }
        seek(to: time)
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        guard let player else { return }
        player.enableRate = true
        player.rate = newRate
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingRecording = nil
        isPlaying = false
        currentTime = 0
        stopTimer()
        deactivateSession()
    }

    /// Deletes a recording: stops it if it is the one loaded, removes the
    /// record, marks the page modified, and moves the file to `trash/`
    /// unless another recording shares it. Saves.
    func delete(_ recording: Recording) {
        if playingRecording?.id == recording.id { stopPlayback() }
        guard let context = recording.modelContext else { return }
        Recording.delete(recording, in: context, store: DrawingStore.inDirectory(directory()))
        do { try context.save() } catch {
            AppLog.note("audio", "delete save failed: \(error)")
        }
    }

    // MARK: Delegates

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isPlaying = false
            stopTimer()
            if let duration = self.player?.duration { currentTime = duration }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.message = "Recording stopped unexpectedly."
            if self?.isRecording == true { self?.finishRecording() }
        }
    }

    // MARK: Session, timer, interruptions

    private func activatePlaybackSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard !isRecording, !isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Added to the common run-loop modes: a pencil on the canvas puts the
    /// main run loop in tracking mode, where a default-mode timer never
    /// fires and the elapsed time would freeze while the user writes.
    private func startTimer(interval: TimeInterval) {
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if isRecording, let recorder {
            elapsed = recorder.currentTime
        } else if isPlaying, let player {
            currentTime = player.currentTime
        }
    }

    private func observeInterruptions() {
        removeObservers()
        let center = NotificationCenter.default
        #if os(iOS) || targetEnvironment(macCatalyst)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.InterruptionType.began.rawValue, self?.isRecording == true else { return }
                self?.finishRecording()
            }
        })
        #endif
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isRecording == true { self?.finishRecording() }
            }
        })
        #endif
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers = []
    }
}
