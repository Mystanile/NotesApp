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
