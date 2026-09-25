import Foundation
import SwiftData

/// Invariant 4: the folder is the source of truth and SwiftData is a
/// rebuildable index over it. This is the rebuild.
///
/// Empties the local index and pulls the sync folder into it, which is
/// exactly what a brand-new device does. Ink that is already local and
/// matches the folder's record stays; ink that differs - an edit that was
/// never pushed - goes to `trash/` as a conflict, never away. Notebook
/// files or payloads that haven't arrived yet leave the pull incomplete,
/// and the folder watcher finishes it when they land.
///
/// With no sync folder chosen, the local mirror (`SyncEnvironment.mirror`,
/// `Documents/Library/`) is rebuilt from instead: the same layout, kept
/// on this device by every push, referencing the local payloads in
/// place.
nonisolated enum LibraryRebuild {
    static func rebuild(container: ModelContainer, environment: SyncEnvironment) throws {
        // Rows an older build left pointing at deleted pages would fault
        // the page when the wipe below saves; drop them first.
        try dropOrphanedArtwork(container: container)

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // Everything. Folders cascade to notebooks, notebooks to pages, pages
        // to their blocks and stickers; links and imported documents hang
        // off raw ids and need deleting on their own, as do notebooks and
        // pages that have no parent.
        for folder in try context.fetch(FetchDescriptor<Folder>()) { context.delete(folder) }
        for notebook in try context.fetch(FetchDescriptor<Notebook>()) { context.delete(notebook) }
        for page in try context.fetch(FetchDescriptor<Page>()) { context.delete(page) }
        for link in try context.fetch(FetchDescriptor<Link>()) { context.delete(link) }
        for doc in try context.fetch(FetchDescriptor<ImportedDocument>()) { context.delete(doc) }
        for block in try context.fetch(FetchDescriptor<TypedTextBlock>()) { context.delete(block) }
        for sticker in try context.fetch(FetchDescriptor<Sticker>()) { context.delete(sticker) }
        try context.save()

        // The folder is the record now; nothing has been pulled or pushed.
        environment.state.lastAppliedRemoteSignature = nil
        environment.state.lastPushSignature = ""

        try SyncRunner(container: container, environment: environment).run(pull: true, push: false)
    }
}

extension LibraryRebuild {
    /// Drops `ImportedDocument` rows whose page no longer exists. Before
    /// Sept 21, 2026 a notebook or folder deletion (local, or by a sync
    /// tombstone) left its artwork rows behind pointing at deleted pages,
    /// and the next notebook to open crashed on `doc.page`. The cascade on
    /// `Page.importedDocuments` stops new ones; this clears the ones a
    /// store already has. Runs at launch, off the main thread.
    ///
    /// The check goes through `persistentModelID`, which is the stored
    /// foreign key and never fires the fault - `doc.page?.id` is the crash.
    /// The removal is a batch delete for the same reason: a `delete` +
    /// `save` maintains the inverse, which loads the missing page and dies.
    @discardableResult
    static func dropOrphanedArtwork(container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pages = Set(try context.fetchIdentifiers(FetchDescriptor<Page>()))
        let orphans = try context.fetch(FetchDescriptor<ImportedDocument>())
            .filter { doc in doc.page.map { !pages.contains($0.persistentModelID) } ?? true }
            .map(\.id)
        guard !orphans.isEmpty else { return 0 }
        try context.delete(model: ImportedDocument.self, where: #Predicate { orphans.contains($0.id) })
        return orphans.count
    }

    static func dropOrphanedArtworkInBackground(container: ModelContainer) {
        Task.detached(priority: .utility) {
            do {
                let dropped = try dropOrphanedArtwork(container: container)
                if dropped > 0 { AppLog.note("index", "dropped \(dropped) orphaned artwork row(s)") }
            } catch {
                AppLog.note("index", "orphaned artwork sweep failed: \(error)")
            }
        }
    }
}
