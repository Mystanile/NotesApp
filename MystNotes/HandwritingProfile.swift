import Foundation
import CoreGraphics

/// The user's handwriting as data: for each character, one or more samples
/// of how they write it. `HandwritingSynth` lays text out from these, so the
/// AI can write onto a page "in your handwriting".
///
/// Coordinates are **baseline-relative and normalized to an x-height of
/// 1.0**, y down (screen convention): the baseline is y = 0, the top of a
/// lowercase "x" is y = -1, a capital reaches about y = -1.5, a descender
/// about y = +0.5. x = 0 is the glyph's left edge *including* its left side
/// bearing; `advance` is the distance to the next glyph's origin, also in
/// x-heights. Nothing in here depends on the page, the pen or the screen, so
/// a profile written on one device renders the same on another.
///
/// Every type here is `nonisolated`: this project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and the profile is read and
/// written off the main thread (invariant 10).
nonisolated struct GlyphPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    /// Brush width relative to the pen it was captured with (1.0 = that
    /// pen's nominal width). The synth multiplies by the width it is asked
    /// for, so a profile is not tied to one pen size.
    var size: CGFloat
    var force: CGFloat
    /// Seconds since the start of the stroke.
    var t: TimeInterval
}

nonisolated struct GlyphSample: Codable, Equatable, Sendable {
    var strokes: [[GlyphPoint]]
    /// Distance to the next glyph's origin, in x-heights.
    var advance: CGFloat
}

nonisolated struct HandwritingProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = HandwritingProfile.currentVersion
    var createdAt: Date = Date()
    /// Keyed by the single character as a String ("a", "A", "7", "&").
    var glyphs: [String: [GlyphSample]] = [:]

    init(version: Int = HandwritingProfile.currentVersion, createdAt: Date = Date(),
         glyphs: [String: [GlyphSample]] = [:]) {
        self.version = version
        self.createdAt = createdAt
        self.glyphs = glyphs
    }

    var isEmpty: Bool { glyphs.values.allSatisfy(\.isEmpty) }

    func samples(for character: Character) -> [GlyphSample] {
        glyphs[String(character)] ?? []
    }

    /// Stores `sample` as the `pass`-th variation of `character`: replaces
    /// that slot if it exists, appends otherwise.
    mutating func setSample(_ sample: GlyphSample, for character: Character, pass: Int) {
        var list = glyphs[String(character)] ?? []
        if pass >= 0, pass < list.count {
            list[pass] = sample
        } else {
            list.append(sample)
        }
        glyphs[String(character)] = list
    }
}

/// The characters Linework can learn, in the order the capture sheet asks
/// for them.
nonisolated enum HandwritingCharset {
    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")
    static let punctuation = Array(".,!?'\"-:;()/&+=@#")
    static var all: [Character] { lowercase + uppercase + digits + punctuation }
}

/// Where the profile lives and how it is read and written.
///
/// `Documents/Handwriting/profile.json`, written atomically. Never
/// `removeItem` (invariant 3): replacing overwrites, resetting moves the old
/// file into `Handwriting/trash/` through `DrawingStore.moveToTrash`
/// (`profile-<ms>-reset.json`), which the 30-day `TrashRetention` sweep
/// already understands.
nonisolated enum HandwritingProfileStore {
    static var directoryURL: URL {
        FileStore.baseDirectory().appendingPathComponent("Handwriting", isDirectory: true)
    }

    /// Exposed so export and backup can include it.
    /// TODO(invariant 9): `LibraryExport` / `Backup` must add this file;
    /// that wiring is a later task. Until then a profile is not in exports.
    static var fileURL: URL {
        directoryURL.appendingPathComponent("profile.json")
    }

    /// Writes are serialized so two quick saves can't land out of order.
    private static let writeQueue = DispatchQueue(label: "MystNotes.HandwritingProfileStore")

    static func load(from url: URL = HandwritingProfileStore.fileURL) -> HandwritingProfile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let profile = try decoder().decode(HandwritingProfile.self, from: data)
            if profile.version > HandwritingProfile.currentVersion { throw CocoaError(.fileReadCorruptFile) }
            return profile
        } catch {
            // Unreadable, or from a newer app. Keep it recoverable rather
            // than let the next save overwrite it.
            DrawingStore.moveToTrash(url, tag: "unreadable")
            return nil
        }
    }

    static func save(_ profile: HandwritingProfile, to url: URL = HandwritingProfileStore.fileURL) throws {
        let data = try encoder().encode(profile)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// The same save, off the caller's thread. `nonisolated static` and
    /// capture-free (the profile is a value) for the reason given on
    /// `DrawingStore.saveDetached`.
    static func saveInBackground(_ profile: HandwritingProfile, to url: URL = HandwritingProfileStore.fileURL) {
        writeQueue.async {
            do { try save(profile, to: url) }
            catch { AppLog.note("handwriting", "save failed: \(error)") }
        }
    }

    /// Starts over: the old profile goes to `trash/`, it is not deleted.
    @discardableResult
    static func reset(at url: URL = HandwritingProfileStore.fileURL) -> Bool {
        writeQueue.sync { DrawingStore.moveToTrash(url, tag: "reset") }
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
