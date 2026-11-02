import Foundation
import AVFoundation
import Observation

/// ElevenLabs text-to-speech. Network only when asked.
nonisolated struct SpeechClient {
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"
    static let maxCharacters = 2_500

    var apiKey: String?
    var voiceID: String
    var session: URLSession

    init(apiKey: String? = Keychain.get(Keychain.Account.elevenlabs),
         voiceID: String = SpeechClient.defaultVoiceID,
         session: URLSession = .shared) {
        self.apiKey = apiKey
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = trimmed.isEmpty ? SpeechClient.defaultVoiceID : trimmed
        self.session = session
    }

    func makeRequest(text: String) throws -> URLRequest {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIError.noKey
        }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_multilingual_v2"
        ])
        return request
    }

    func synthesize(_ text: String) async throws -> Data {
        let request = try makeRequest(text: text)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: throw AIError.other("ElevenLabs didn't accept that key. Check it in Settings.")
                case 429: throw AIError.other("ElevenLabs is asking us to slow down. Try again in a moment.")
                case 404, 422: throw AIError.other("ElevenLabs couldn't use that voice. Check the voice ID in Settings.")
                default: throw AIError.other("ElevenLabs had a problem (\(http.statusCode)). Try again later.")
                }
            }
            guard !data.isEmpty else { throw AIError.decoding }
            return data
        } catch let error as AIError {
            throw error
        } catch let error as URLError {
            throw AIError.from(urlError: error)
        }
    }

    /// Splits text into chunks of at most `limit` characters, preferring
    /// sentence or whitespace boundaries.
    static func chunks(_ text: String, limit: Int = maxCharacters) -> [String] {
        var result: [String] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { ".!?\n".contains($0) })
                ?? window.lastIndex(where: { $0 == " " })
            let end = cut.map { rest.index(after: $0) } ?? window.endIndex
            result.append(String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[end...]
        }
        let last = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { result.append(last) }
        return result
    }
}

/// Reads text aloud: ElevenLabs when a key is saved, otherwise the device's
/// own voice. Playback is on-demand only.
@MainActor @Observable
final class ReadAloudPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var error: String?

    private var player: AVAudioPlayer?
    private var synthesizer: AVSpeechSynthesizer?
    private var task: Task<Void, Never>?

    func play(text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        error = nil
        configureSession()
        let key = Keychain.get(Keychain.Account.elevenlabs)
        if key == nil {
            speakOnDevice(trimmed)
            return
        }
        let voice = UserDefaults.standard.string(forKey: AppSettings.Keys.elevenVoiceID) ?? SpeechClient.defaultVoiceID
        let client = SpeechClient(apiKey: key, voiceID: voice)
        let parts = SpeechClient.chunks(trimmed)
        isLoading = true
        task = Task { [weak self] in
            do {
                for part in parts {
                    let data = try await client.synthesize(part)
                    guard let self, !Task.isCancelled else { return }
                    try await self.playAndWait(data)
                    if Task.isCancelled { return }
                }
                self?.finish()
            } catch is CancellationError {
                self?.finish()
            } catch {
                self?.fail(error)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        isPlaying = false
        isLoading = false
    }

    // MARK: Internals

    private var continuation: CheckedContinuation<Void, Never>?

    private func playAndWait(_ data: Data) async throws {
        let p = try AVAudioPlayer(data: data)
        p.delegate = self
        player = p
        isLoading = false
        isPlaying = true
        p.play()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                continuation = c
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeContinuation() }
        }
    }

    private func resumeContinuation() {
        continuation?.resume()
        continuation = nil
    }

    private func finish() {
        isPlaying = false
        isLoading = false
    }

    private func fail(_ err: Error) {
        isPlaying = false
        isLoading = false
        error = (err as? LocalizedError)?.errorDescription ?? "Couldn't play that."
    }

    private func configureSession() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        #endif
    }

    private func speakOnDevice(_ text: String) {
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        isPlaying = true
        synth.speak(utterance)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.resumeContinuation()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isPlaying = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isPlaying = false }
    }
}
