import Foundation

/// Spaced repetition for tape, "SM-2 lite": pure functions over plain values,
/// so the maths is tested without a model container and can run anywhere.
/// `Link.reviewState` stores `State` as JSON; the due date inside is a
/// `SnapshotDates` string (milliseconds), like every date a synced file holds.
nonisolated enum ReviewScheduler {
    enum Grade: String, CaseIterable, Sendable {
        case again, hard, good, easy

        var title: String {
            switch self {
            case .again: return "Again"
            case .hard: return "Hard"
            case .good: return "Good"
            case .easy: return "Easy"
            }
        }
    }

    struct State: Equatable, Sendable {
        var due: Date
        /// Days. 0 after a lapse (the card comes back in minutes).
        var interval: Double
        var ease: Double
        var reps: Int
        var lapses: Int
    }

    static let startingEase = 2.5
    static let minimumEase = 1.3
    /// What Again waits before the card is due again.
    static let againDelay: TimeInterval = 10 * 60
    static let day: TimeInterval = 24 * 60 * 60

    /// The state a never-reviewed tape is treated as having: due now.
    static func fresh(now: Date) -> State {
        State(due: now, interval: 0, ease: startingEase, reps: 0, lapses: 0)
    }

    /// The state after `grade`, from `state` (nil: never reviewed), at `now`.
    ///
    /// - Again: interval 0, due in 10 minutes, one lapse, ease -0.2 (floor 1.3), reps restart.
    /// - Hard: interval x 1.2 (at least 1 day), ease -0.15 (floor 1.3).
    /// - Good: first review 1 day, second 3 days, then interval x ease.
    /// - Easy: Good's interval x 1.3, ease +0.15.
    static func next(state: State?, grade: Grade, now: Date) -> State {
        var s = state ?? fresh(now: now)
        switch grade {
        case .again:
            s.interval = 0
            s.reps = 0
            s.lapses += 1
            s.ease = max(minimumEase, s.ease - 0.2)
            s.due = now.addingTimeInterval(againDelay)
            return s
        case .hard:
            s.interval = max(1, s.interval * 1.2)
            s.ease = max(minimumEase, s.ease - 0.15)
        case .good:
            s.interval = goodInterval(s)
        case .easy:
            s.interval = goodInterval(s) * 1.3
            s.ease += 0.15
        }
        s.reps += 1
        s.due = now.addingTimeInterval(s.interval * day)
        return s
    }

    /// Good's next interval for `s` before this review is counted.
    private static func goodInterval(_ s: State) -> Double {
        switch s.reps {
        case 0: return 1
        case 1: return 3
        default: return max(1, s.interval) * s.ease
        }
    }

    /// Never reviewed counts as due.
    static func isDue(_ state: State?, now: Date) -> Bool {
        guard let state else { return true }
        return state.due <= now
    }

    // MARK: JSON in `Link.reviewState`

    private struct Wire: Codable {
        var due: String
        var interval: Double
        var ease: Double
        var reps: Int
        var lapses: Int
    }

    static func encode(_ state: State) -> String {
        let wire = Wire(due: SnapshotDates.string(from: state.due), interval: state.interval,
                        ease: state.ease, reps: state.reps, lapses: state.lapses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// nil for nil, empty or unreadable text: the tape is treated as never reviewed.
    static func decode(_ json: String?) -> State? {
        guard let json, let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              let due = SnapshotDates.date(from: wire.due) else { return nil }
        return State(due: due, interval: wire.interval, ease: wire.ease, reps: wire.reps, lapses: wire.lapses)
    }
}
