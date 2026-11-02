import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// The compact bar for recording and playing a page's audio. It floats like
/// the other bars (`surfaceCard`), and the caller places it, usually near
/// the bottom of the page. Three states:
///
/// - recording: a red dot, the elapsed time, Stop;
/// - idle with recordings: Record, Play/Pause, a scrubber, the time, the
///   speed menu and the recordings menu (pick one, delete one);
/// - idle without any: just Record.
///
/// A refused microphone shows one calm sentence and a button to Settings.
struct AudioPlayerBar: View {
    var audio: PageAudioController
    var page: Page
    /// Called after a tap on the scrubber or a seek; lets the host refresh
    /// its overlay immediately if it wants to. Optional.
    var onSeek: ((TimeInterval) -> Void)? = nil

    @Environment(\.openURL) private var openURL
    @State private var chosenID: UUID?
    @State private var pendingDelete: Recording?
    @State private var showTranscript = false

    private var recordings: [Recording] { Recording.ordered(page.recordings ?? []) }

    /// The recording the controls act on: the loaded one, else the user's
    /// pick, else the newest.
    private var selected: Recording? {
        if let loaded = audio.playingRecording, loaded.page?.id == page.id { return loaded }
        if let id = chosenID, let match = recordings.first(where: { $0.id == id }) { return match }
        return recordings.last
    }

    var body: some View {
        VStack(spacing: Space.s) {
            if audio.isRecording {
                recordingRow
            } else {
                idleRow
                if let current = selected { transcriptSection(for: current) }
            }
            if audio.access == .denied || audio.message != nil {
                notice
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .surfaceCard()
        .animation(Motion.snappy, value: audio.isRecording)
        .confirmationDialog("Delete this recording?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { recording in
            Button("Delete Recording", role: .destructive) {
                audio.delete(recording)
                if chosenID == recording.id { chosenID = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: { recording in
            Text("\(recording.displayTitle) will be removed from this page. The audio file is kept in the trash for 30 days.")
        }
    }

    // MARK: Recording

    private var recordingRow: some View {
        HStack(spacing: Space.m) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(Recording.clock(audio.elapsed))
                .font(Typography.mono)
                .monospacedDigit()
                .accessibilityLabel("Recording, \(Recording.clock(audio.elapsed))")
            Spacer(minLength: Space.m)
            Button {
                audio.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(Typography.label)
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
            .minimumHitTarget()
            .accessibilityLabel("Stop recording")
        }
    }

    // MARK: Idle / playback

    private var idleRow: some View {
        HStack(spacing: Space.s) {
            Button {
                audio.record(page: page)
            } label: {
                Image(systemName: "mic.fill").foregroundStyle(Color.red)
            }
            .buttonStyle(ToolIconButtonStyle())
            .accessibilityLabel("Record audio")

            if let current = selected {
                Button {
                    audio.togglePlayback(of: current)
                } label: {
                    Image(systemName: audio.isPlaying && audio.playingRecording?.id == current.id ? "pause.fill" : "play.fill")
                }
                .buttonStyle(ToolIconButtonStyle())
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { audio.playingRecording?.id == current.id ? audio.currentTime : 0 },
                        set: { audio.seek(to: $0); onSeek?($0) }
                    ),
                    in: 0...max(current.duration, 0.1)
                )
                .frame(minWidth: 120)
                .accessibilityLabel("Playback position")

                Text("\(Recording.clock(audio.playingRecording?.id == current.id ? audio.currentTime : 0)) / \(Recording.clock(current.duration))")
                    .font(Typography.mono)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                rateMenu
                recordingsMenu(current: current)
            } else {
                Text("Record audio while you write")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, Space.s)
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcriptSection(for current: Recording) -> some View {
        DisclosureGroup(isExpanded: $showTranscript) {
            let segments = current.segments
            if audio.transcribing.contains(current.id) {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on this device")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else if segments.isEmpty {
                if let plain = current.transcript, !plain.isEmpty {
                    Text(plain).font(Typography.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        audio.transcribe(current)
                    } label: {
                        Label("Transcribe", systemImage: "text.quote")
                            .font(Typography.label)
                    }
                    .buttonStyle(.plain)
                    .minimumHitTarget()
                    .accessibilityLabel("Transcribe this recording")
                }
            } else {
                let loaded = audio.playingRecording?.id == current.id
                let active = loaded ? TranscriptSegment.index(at: audio.currentTime, in: segments) : nil
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            Button {
                                audio.seek(to: segment.start, in: current)
                                onSeek?(segment.start)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                    Text(Recording.clock(segment.start))
                                        .font(Typography.mono)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    Text(segment.text)
                                        .font(Typography.caption)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, Space.s)
                                .background(index == active ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(Recording.clock(segment.start)), \(segment.text)")
                            .accessibilityAddTraits(index == active ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        } label: {
            Text("Transcript")
                .font(Typography.label)
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PageAudioController.rates, id: \.self) { value in
                Button {
                    audio.setRate(value)
                } label: {
                    if audio.rate == value { Label(rateText(value), systemImage: "checkmark") } else { Text(rateText(value)) }
                }
            }
        } label: {
            Text(rateText(audio.rate))
                .font(Typography.label)
                .padding(.horizontal, Space.s)
                .minimumHitTarget()
        }
        .accessibilityLabel("Playback speed")
    }

    private func recordingsMenu(current: Recording) -> some View {
        Menu {
            ForEach(recordings, id: \.id) { recording in
                Button {
                    chosenID = recording.id
                    audio.stopPlayback()
                    audio.play(recording: recording)
                } label: {
                    let line = "\(recording.displayTitle) (\(Recording.clock(recording.duration)))"
                    if recording.id == current.id { Label(line, systemImage: "checkmark") } else { Text(line) }
                }
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = current
            } label: {
                Label("Delete Recording", systemImage: "trash")
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .medium))
                .frame(width: Metrics.toolButton, height: Metrics.toolButton)
                .minimumHitTarget()
        }
        .accessibilityLabel("Recordings on this page")
    }

    private func rateText(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))x" : String(format: "%.1fx", value)
    }

    // MARK: Notice

    private var notice: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "mic.slash").foregroundStyle(.secondary)
            Text(audio.message ?? "Microphone access is off.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            #if canImport(UIKit)
            if audio.access == .denied {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .font(Typography.label)
            }
            #endif
            Button {
                audio.message = nil
            } label: {
                Image(systemName: "xmark").imageScale(.small)
            }
            .buttonStyle(.plain)
            .minimumHitTarget()
            .accessibilityLabel("Dismiss")
        }
    }
}
