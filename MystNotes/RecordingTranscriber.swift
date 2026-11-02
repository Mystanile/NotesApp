import Foundation
import AVFoundation
import Speech

/// One timed stretch of a recording's transcript. Seconds into the audio.
/// Stored as JSON in `Recording.transcriptSegments`.
nonisolated struct TranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

nonisolated extension TranscriptSegment {
    /// JSON for `Recording.transcriptSegments`. Never throws: an encoding
    /// failure yields "[]".
    static func encode(_ segments: [TranscriptSegment]) -> String {
        guard let data = try? JSONEncoder().encode(segments),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Reads `Recording.transcriptSegments`. nil, empty or malformed JSON
    /// gives [] (calm: the plain `transcript` is still there).
    static func decode(_ json: String?) -> [TranscriptSegment] {
        guard let json, let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else { return [] }
        return segments
    }

    /// Index of the segment containing `time`: the last one that has
    /// started by then, as long as `time` is not past its end by more than
    /// `grace` seconds (a gap between segments keeps the previous one lit).
    static func index(at time: Double, in segments: [TranscriptSegment], grace: Double = 1.5) -> Int? {
        guard let i = segments.lastIndex(where: { $0.start <= time }) else { return nil }
        return time <= segments[i].end + grace ? i : nil
    }

    /// Where a tap on the segment containing `time` should seek to.
    static func seekTarget(at time: Double, in segments: [TranscriptSegment]) -> Double? {
        index(at: time, in: segments).map { segments[$0].start }
    }

    /// Joins words (or any small timed pieces) into sentence-ish segments:
    /// a segment closes at sentence-ending punctuation once it is at least
    /// `minSpan` long, when it would pass `maxSpan`, or after a pause longer
    /// than `maxGap`. Pieces are concatenated as given (speech runs carry
    /// their own spaces), then trimmed.
    static func merge(_ pieces: [TranscriptSegment], maxSpan: Double = 12,
                      minSpan: Double = 2, maxGap: Double = 1.5) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: TranscriptSegment?

        func flush() {
            if var done = current {
                done.text = done.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !done.text.isEmpty { result.append(done) }
            }
            current = nil
        }

        for piece in pieces where !piece.text.isEmpty {
            if let open = current {
                let tooLong = piece.end - open.start > maxSpan
                let paused = piece.start - open.end > maxGap
                if tooLong || paused { flush() }
            }
            if var open = current {
                open.text += piece.text
                open.end = max(open.end, piece.end)
                current = open
            } else {
                current = piece
            }
            if let open = current, open.end - open.start >= minSpan,
               let last = open.text.trimmingCharacters(in: .whitespacesAndNewlines).last,
               ".?!\u{3002}\u{FF1F}\u{FF01}".contains(last) {
                flush()
            }
        }
        flush()
        return result
    }
}

/// On-device transcription of a finished recording with the iOS 26 Speech
/// framework (`SpeechAnalyzer` + `SpeechTranscriber`). Nothing leaves the
/// device. Runs off the main thread (`transcribeDetached`) and only after a
/// recording is finished or when the user taps Transcribe.
///
/// UNVERIFIED (written without Xcode; check on the first build): the exact
/// spellings of the calls in `makeTranscriber`, `ensureAssets`,
/// `runAnalysis` and `pieces(from:)`. Each Speech call sits in one of those
/// small functions so a rename is a one-line fix.
nonisolated enum RecordingTranscriber {

    /// Starts the work on the background pool. Capture-free by construction
    /// (only values passed in), so it does not inherit the main actor.
    nonisolated static func transcribeDetached(fileURL: URL, localeIdentifier: String)
        -> Task<[TranscriptSegment], Error> {
        Task.detached(priority: .utility) {
            try await transcribe(fileURL: fileURL, locale: Locale(identifier: localeIdentifier))
        }
    }

    /// The timed segments of the speech in `fileURL`. [] when the language
    /// is not supported on this device, the models can't be installed, or
    /// the audio holds no speech: those are calm outcomes, not errors.
    static func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment] {
        guard let transcriber = await makeTranscriber(for: locale) else { return [] }
        guard await ensureAssets(for: transcriber) else { return [] }

        let file = try AVAudioFile(forReading: fileURL)
        // Collect while the analyzer feeds the file in; the results stream
        // ends when the analyzer finishes.
        let collector = Task { () -> [TranscriptSegment] in
            var pieces: [TranscriptSegment] = []
            for try await result in transcriber.results {
                pieces.append(contentsOf: Self.pieces(from: result))
            }
            return pieces
        }
        do {
            try await runAnalysis(of: file, with: transcriber)
        } catch {
            collector.cancel()
            throw error
        }
        let pieces = try await collector.value
        return TranscriptSegment.merge(pieces)
    }

    // MARK: Speech framework calls (isolated; fix here if a name differs)

    /// nil when speech recognition is unavailable or `locale` has no
    /// supported equivalent.
    private static func makeTranscriber(for locale: Locale) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable else { return nil }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        return SpeechTranscriber(locale: supported,
                                 transcriptionOptions: [],
                                 reportingOptions: [],            // final results only
                                 attributeOptions: [.audioTimeRange])
    }

    /// True when the language models are installed (downloading them first
    /// if needed).
    private static func ensureAssets(for transcriber: SpeechTranscriber) async -> Bool {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            AppLog.note("transcribe", "assets unavailable: \(error)")
            return false
        }
    }

    private static func runAnalysis(of file: AVAudioFile, with transcriber: SpeechTranscriber) async throws {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    }

    /// One piece per attributed run that carries an `audioTimeRange`.
    private static func pieces(from result: SpeechTranscriber.Result) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let text = String(result.text[run.range].characters)
            guard !text.isEmpty else { continue }
            out.append(TranscriptSegment(start: range.start.seconds,
                                         end: range.end.seconds,
                                         text: text))
        }
        return out
    }
}

extension Recording {
    /// The timed segments, [] when there are none.
    var segments: [TranscriptSegment] { TranscriptSegment.decode(transcriptSegments) }
    var hasTranscript: Bool { !(transcript ?? "").isEmpty }
}
