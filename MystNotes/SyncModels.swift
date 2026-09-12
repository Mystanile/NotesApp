import Foundation
import CryptoKit

/// Codable mirrors of the SwiftData models, plus the files written to the
/// user's chosen sync folder. The live `@Model` classes aren't `Codable`,
/// and serializing SwiftData directly is fragile, so `SyncEngine`
/// translates between these DTOs and the model graph.
///
/// On disk (format 2):
///
///     Mystnotes/
///       index.json              LibraryIndex - folders, tombstones, and one
///                               NotebookIndexEntry per notebook
///       notebooks/<uuid>.json   NotebookDTO - that notebook's pages and links
///       files/                  payloads
///       library.json            format 1: the whole library in one file.
///                               Read once when index.json is absent; never
///                               written again, never deleted.
///
/// Merge granularity is the page: each `PageDTO` carries its own
/// `modifiedAt` and `SyncRunner` decides page by page which side is newer.
/// Notebook settings (title, cover, folder) merge on `settingsModifiedAt`.
/// Folders are a flat upsert by id; deletions of folders, notebooks and
/// pages travel as `Tombstone`s.

/// The newest format this build can read. A folder written by a newer
/// build is refused, not guessed at.
let librarySnapshotFormatVersion = 2

/// Snapshot dates carry milliseconds. Whole-second ISO-8601 (the default
/// `.iso8601` strategy) made two edits inside one second compare equal
/// and made a device's own dates look different after a round trip.
/// Decoding accepts both forms so snapshots written before this still read.
enum SnapshotDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let encoding: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(fractional.string(from: date))
    }

    static let decoding: JSONDecoder.DateDecodingStrategy = .custom { decoder in
        let string = try decoder.singleValueContainer().decode(String.self)
        if let date = fractional.date(from: string) ?? whole.date(from: string) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "Unreadable date \(string)"))
    }

    static func stamp(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSince1970) } ?? "-"
    }
}

// MARK: - index.json

struct LibraryIndex: Codable {
    var formatVersion: Int = librarySnapshotFormatVersion
    var exportedAt: Date
    var deviceName: String
    var folders: [FolderDTO]
    var notebooks: [NotebookIndexEntry]
    var tombstones: [Tombstone]

    /// A fingerprint of everything that matters for "has anything changed
    /// since the last push". Computable from the index alone, so a puller
    /// can compare its own library against a folder without opening a
    /// single notebook file.
    var signature: String {
        Self.signature(folders: folders, notebooks: notebooks, tombstones: tombstones)
    }

    static func signature(folders: [FolderDTO], notebooks: [NotebookIndexEntry], tombstones: [Tombstone]) -> String {
        var parts: [String] = []
        for folder in folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("F:\(folder.id):\(folder.name):\(folder.parentID?.uuidString ?? "-")")
        }
        for notebook in notebooks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("N:\(notebook.id):\(SnapshotDates.stamp(notebook.settingsModifiedAt)):\(notebook.contentSignature)")
        }
        for tombstone in tombstones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("T:\(tombstone.kind.rawValue):\(tombstone.id):\(tombstone.deletedAt.timeIntervalSince1970)")
        }
        return parts.joined(separator: "|")
    }
}

/// What the index knows about a notebook: enough to list it, merge its
/// settings, and decide whether `notebooks/<id>.json` needs reading.
struct NotebookIndexEntry: Codable {
    var id: UUID
    var title: String
    var coverStyle: String
    var createdAt: Date
    var modifiedAt: Date
    var settingsModifiedAt: Date?
    var folderID: UUID?
    /// See `NotebookDTO.contentSignature`.
    var contentSignature: String

    init(_ notebook: NotebookDTO) {
        id = notebook.id
        title = notebook.title
        coverStyle = notebook.coverStyle
        createdAt = notebook.createdAt
        modifiedAt = notebook.modifiedAt
        settingsModifiedAt = notebook.settingsModifiedAt
        folderID = notebook.folderID
        contentSignature = notebook.contentSignature
    }
}

// MARK: - In-memory library (and the format-1 library.json)

/// A whole library as `SyncRunner` works with it. Built from the model
/// graph for a push, or assembled from `index.json` plus whichever
/// notebook files needed reading for a pull - in which case `notebooks`
/// holds only those, and `notebookIndex` the full list.
///
/// Also the exact shape of the format-1 `library.json`, which is why it
/// stays `Codable`: `notebookIndex` is absent there and derived.
struct LibrarySnapshot: Codable {
    var formatVersion: Int = librarySnapshotFormatVersion
    var exportedAt: Date
    var deviceName: String
    var folders: [FolderDTO]
    var notebooks: [NotebookDTO]
    var notebookIndex: [NotebookIndexEntry]?
    var tombstones: [Tombstone]

    var index: [NotebookIndexEntry] {
        notebookIndex ?? notebooks.map(NotebookIndexEntry.init)
    }

    var signature: String {
        LibraryIndex.signature(folders: folders, notebooks: index, tombstones: tombstones)
    }

    func makeIndex() -> LibraryIndex {
        LibraryIndex(exportedAt: exportedAt, deviceName: deviceName,
                     folders: folders, notebooks: index, tombstones: tombstones)
    }
}

// MARK: - Tombstone

struct Tombstone: Codable, Hashable {
    /// `page` was added with per-page merge; a build from before it can't
    /// decode a snapshot that contains one.
    enum Kind: String, Codable { case folder, notebook, page }
    var kind: Kind
    var id: UUID
    var deletedAt: Date
}

/// Local record of folders/notebooks/pages deleted on this device, kept in
/// `UserDefaults` so the deletion survives until it has been pushed to the
/// sync folder (and to guard against the item reappearing from another
/// device's older snapshot). Remote tombstones seen during a pull are merged
/// in here too, so a later push re-broadcasts them.
///
/// The store defaults to the app's real one; `SyncRunner` passes its
/// environment's store so each simulated device in the sync tests keeps its
/// own list.
enum SyncTombstones {
    private static let lock = NSLock()
    /// Tombstones older than this are pruned - long enough that every device
    /// has realistically synced, without the list growing forever.
    private static let retention: TimeInterval = 90 * 24 * 60 * 60

    static func load(from store: SyncStateStore = LiveSyncStateStore.shared) -> [Tombstone] {
        guard let data = store.tombstonesData,
              let decoded = try? JSONDecoder().decode([Tombstone].self, from: data)
        else { return [] }
        return decoded
    }

    static func merge(_ incoming: [Tombstone], into store: SyncStateStore = LiveSyncStateStore.shared) {
        lock.lock(); defer { lock.unlock() }
        var newestByID: [UUID: Tombstone] = [:]
        for stone in load(from: store) + incoming {
            if let existing = newestByID[stone.id], existing.deletedAt >= stone.deletedAt { continue }
            newestByID[stone.id] = stone
        }
        let cutoff = Date().addingTimeInterval(-retention)
        let pruned = newestByID.values.filter { $0.deletedAt >= cutoff }
        store.tombstonesData = try? JSONEncoder().encode(Array(pruned))
    }
}

// MARK: - DTOs

struct FolderDTO: Codable {
    var id: UUID
    var name: String
    var parentID: UUID?
}

/// One notebook, complete: what `notebooks/<id>.json` holds.
struct NotebookDTO: Codable {
    /// Optional because notebooks embedded in a format-1 `library.json`
    /// have no version of their own.
    var formatVersion: Int? = librarySnapshotFormatVersion
    var id: UUID
    var title: String
    var coverStyle: String
    var createdAt: Date
    var modifiedAt: Date
    /// Absent in older snapshots; nil loses to any date.
    var settingsModifiedAt: Date?
    var folderID: UUID?
    var pages: [PageDTO]
    var links: [LinkDTO]

    /// Fingerprint of the page set: which pages exist and when each was
    /// last edited. Two libraries whose notebooks share a signature hold
    /// the same page versions, so the notebook file needn't be read.
    var contentSignature: String {
        Self.contentSignature(of: pages.map { ($0.id, $0.modifiedAt) })
    }

    static func contentSignature(of pages: [(id: UUID, modifiedAt: Date?)]) -> String {
        let lines = pages
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\(SnapshotDates.stamp($0.modifiedAt))" }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct PageDTO: Codable {
    var id: UUID
    var index: Int
    var type: String
    var template: String
    var drawingFileRef: String?
    var backgroundRef: String?
    var recognizedTextCache: String?
    var ocrUpdatedAt: Date?
    /// Absent in snapshots written before this field existed; decodes as
    /// nil, which merge treats as older than any date.
    var modifiedAt: Date?
    /// Absent in older snapshots. See `Page.aspectRatio`.
    var aspectRatio: Double?
    var textBlocks: [TextBlockDTO]
    var stickers: [StickerDTO]
    var importedDocuments: [ImportedDocumentDTO]
}

struct TextBlockDTO: Codable {
    var id: UUID
    var content: String
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
    var textColorHex: String
}

struct StickerDTO: Codable {
    var id: UUID
    var assetRef: String
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
}

struct ImportedDocumentDTO: Codable {
    var id: UUID
    var sourceType: String
    var fileRef: String
    var pdfPageIndex: Int
    var frameX: Double?
    var frameY: Double?
    var frameWidth: Double?
    var frameHeight: Double?
    var rotationDegrees: Double?
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?
}

struct LinkDTO: Codable {
    var id: UUID
    var sourcePageID: UUID
    var destinationPageID: UUID
    var anchorX: Double
    var anchorY: Double
    var anchorWidth: Double
    var anchorHeight: Double
}
