import Foundation

/// How long trashed payloads are kept, and the sweep that finally removes
/// them.
///
/// Nothing in this app deletes ink. A deleted page, the losing side of a
/// same-page conflict, a file that wouldn't decode, a payload no notebook
/// references any more and a tombstoned notebook's file all go to a
/// `trash/` beside where they lived - locally and in the sync folder
/// (invariant 3). That is the right default and it grows without bound.
///
/// **The decision (Sept 18, 2026): 30 days, then removed.** Long enough
/// that "I deleted the wrong page last week" is recoverable on any device
/// that has synced since, short enough that a shared folder doesn't fill up
/// with a year of superseded payloads. This sweep is the **one place in the
/// app where `removeItem` on a payload is allowed**, and only for a file
/// that has been in `trash/` for the whole period.
///
/// The age comes from the name, not the file's timestamps:
/// `DrawingStore.moveToTrash` writes `<base>-<milliseconds>-<tag>.<ext>`,
/// and that stamp is the moment it was trashed. A sync provider rewrites
/// modification dates when it downloads a file, so an evicted item that
/// came back yesterday would otherwise look one day old forever - or, worse
/// on the other side, a file whose date the provider set *earlier* would be
/// swept before its time. The name travels unchanged. Modification date is
/// only the fallback for something that doesn't parse.
nonisolated enum TrashRetention {

    /// The retention period. `SyncEnvironment.trashRetentionPeriod` is what
    /// callers read, so a test can shorten it.
    static let defaultPeriod: TimeInterval = 30 * 24 * 60 * 60

    /// The name every trash directory has, beside the files it holds.
    static let directoryName = "trash"

    struct Entry: Equatable {
        var url: URL
        var trashedAt: Date
        /// Why it was trashed: "deleted", "conflict", "unreadable", "orphan".
        var tag: String
        var bytes: Int
    }

    struct Summary: Equatable {
        var count: Int = 0
        var bytes: Int = 0
        /// The oldest entry's age, for "oldest 12 days" in Settings.
        var oldest: Date?

        var isEmpty: Bool { count == 0 }

        func age(at now: Date) -> TimeInterval? {
            oldest.map { now.timeIntervalSince($0) }
        }
    }

    /// Everything currently in `directory` (a `trash/` directory itself).
    static func entries(in directory: URL) -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        return names.compactMap { name -> Entry? in
            guard !name.hasPrefix(".") else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            let parsed = parse(name)
            return Entry(
                url: url,
                trashedAt: parsed.trashedAt ?? values.contentModificationDate ?? .distantPast,
                tag: parsed.tag ?? "unknown",
                bytes: values.fileSize ?? 0
            )
        }
    }

    /// `<base>-<milliseconds>-<tag>.<ext>`, as `DrawingStore.moveToTrash`
    /// writes it. The base is usually a UUID, which has dashes of its own,
    /// so this reads from the end: the last component is the tag and the
    /// one before it is the stamp.
    static func parse(_ filename: String) -> (trashedAt: Date?, tag: String?) {
        let base = (filename as NSString).deletingPathExtension
        let parts = base.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return (nil, nil) }
        let tag = String(parts[parts.count - 1])
        let stamp = String(parts[parts.count - 2])
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter }),
              !stamp.isEmpty, stamp.allSatisfy({ $0.isNumber }),
              let milliseconds = Double(stamp) else { return (nil, nil) }
        return (Date(timeIntervalSince1970: milliseconds / 1000), tag)
    }

    /// What `directory` holds, for the Settings readout.
    static func summary(of directories: [URL]) -> Summary {
        var summary = Summary()
        for entry in directories.flatMap(entries(in:)) {
            summary.count += 1
            summary.bytes += entry.bytes
            if entry.trashedAt < (summary.oldest ?? .distantFuture) { summary.oldest = entry.trashedAt }
        }
        return summary
    }

    /// Removes everything in `directory` that has been there for `period`.
    /// Returns what went, for the log.
    ///
    /// This is the allowed `removeItem` on a payload. It only ever runs
    /// against a directory named `trash` - the guard below is not
    /// decoration, it is the thing standing between a wrong argument and
    /// someone's notebook.
    @discardableResult
    static func sweep(_ directory: URL, olderThan period: TimeInterval, now: Date) -> (removed: Int, bytes: Int) {
        guard directory.lastPathComponent == directoryName else {
            AppLog.note("trash", "refused to sweep \(directory.lastPathComponent): not a trash directory")
            return (0, 0)
        }
        guard period > 0 else { return (0, 0) }

        let cutoff = now.addingTimeInterval(-period)
        var removed = 0
        var bytes = 0
        for entry in entries(in: directory) where entry.trashedAt < cutoff {
            do {
                try FileManager.default.removeItem(at: entry.url)
                removed += 1
                bytes += entry.bytes
            } catch {
                AppLog.note("trash", "could not remove \(entry.url.lastPathComponent): \(error)")
            }
        }
        if removed > 0 {
            AppLog.note("trash", "swept \(removed) item(s), \(bytes) bytes, older than \(Int(period / 86400)) days")
        }
        return (removed, bytes)
    }

    /// Empties `directories` regardless of age - what the Settings button
    /// does, on an explicit ask.
    @discardableResult
    static func emptyNow(_ directories: [URL]) -> (removed: Int, bytes: Int) {
        var total = (removed: 0, bytes: 0)
        for directory in directories {
            let swept = sweep(directory, olderThan: 0.001, now: .distantFuture)
            total.removed += swept.removed
            total.bytes += swept.bytes
        }
        return total
    }

    /// The local sweep, at launch. Detached from a `nonisolated` context
    /// so it really does leave the main thread - see the
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION` note in CLAUDE.md.
    static func sweepLocalInBackground(now: @escaping @Sendable () -> Date = { Date() }) {
        let directories = localDirectories(
            payloads: FileStore.baseDirectory(),
            mirror: SyncEnvironment.mirrorDirectory
        )
        Task.detached(priority: .utility) {
            for directory in directories {
                sweep(directory, olderThan: defaultPeriod, now: now())
            }
        }
    }

    /// The trash directories this device owns: payloads, and the local
    /// mirror's notebook files. The sync folder's own are swept inside the
    /// sync run, while the folder is held.
    static func localDirectories(payloads: URL, mirror: URL) -> [URL] {
        [
            payloads.appendingPathComponent(directoryName, isDirectory: true),
            mirror.appendingPathComponent("notebooks", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true),
            mirror.appendingPathComponent("files", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        ]
    }
}
