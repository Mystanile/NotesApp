import Foundation

/// Codable mirrors of the SwiftData models, plus the container written to the
/// user's chosen sync folder as `Mystnotes/library.json`. The live `@Model`
/// classes aren't `Codable`, and serializing SwiftData directly is fragile,
/// so `SyncEngine` translates between these DTOs and the model graph.
///
/// Merge granularity is the notebook: a `NotebookDTO` carries its whole page
/// tree, so when one side's copy wins (newer `modifiedAt`) it replaces the
/// other wholesale. Folders are a flat upsert by id; deletions travel as
/// `Tombstone`s.

let librarySnapshotFormatVersion = 1

struct LibrarySnapshot: Codable {
    var formatVersion: Int = librarySnapshotFormatVersion
    var exportedAt: Date
    var deviceName: String
    var folders: [FolderDTO]
    var notebooks: [NotebookDTO]
    var tombstones: [Tombstone]

    /// A cheap fingerprint of the meaningful contents, used to skip a push
    /// when nothing has changed since the last one.
    var signature: String {
        var parts: [String] = []
        for folder in folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("F:\(folder.id):\(folder.name):\(folder.parentID?.uuidString ?? "-")")
        }
        for notebook in notebooks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("N:\(notebook.id):\(notebook.modifiedAt.timeIntervalSince1970)")
            for page in notebook.pages.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                parts.append("P:\(page.id):\(page.modifiedAt?.timeIntervalSince1970 ?? 0)")
            }
        }
        for tombstone in tombstones.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append("T:\(tombstone.id):\(tombstone.deletedAt.timeIntervalSince1970)")
        }
        return parts.joined(separator: "|")
    }

    /// Every payload file (drawings, imported PDFs/images) referenced anywhere
    /// in the snapshot - what `SyncEngine` copies alongside `library.json`.
    var referencedFileNames: Set<String> {
        var names: Set<String> = []
        for notebook in notebooks {
            for page in notebook.pages {
                if let ref = page.drawingFileRef, !ref.isEmpty { names.insert(ref) }
                if let ref = page.backgroundRef, !ref.isEmpty { names.insert(ref) }
                for doc in page.importedDocuments where !doc.fileRef.isEmpty {
                    names.insert(doc.fileRef)
                }
            }
        }
        return names
    }
}

// MARK: - Tombstone

struct Tombstone: Codable, Hashable {
    enum Kind: String, Codable { case folder, notebook }
    var kind: Kind
    var id: UUID
    var deletedAt: Date
}

/// Local record of folders/notebooks deleted on this device, kept in
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

struct NotebookDTO: Codable {
    var id: UUID
    var title: String
    var coverStyle: String
    var createdAt: Date
    var modifiedAt: Date
    var folderID: UUID?
    var pages: [PageDTO]
    var links: [LinkDTO]
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
