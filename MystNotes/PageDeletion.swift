import Foundation
import SwiftData

/// Deleting a page for real: the page and everything tied to it. Moved out
/// of `NotebookDetailView.deletePage` unchanged (Sept 25, 2026), when Delete
/// Page became undoable - the view now holds a deletion pending and runs
/// this only once it can no longer be undone.
enum PageDeletion {
    /// Removes `page` and what hangs off it: Links pointing either way,
    /// its artwork rows (Page has no inverse to cascade them), its ink to
    /// `trash/`, any imported file no other page uses to `trash/`, a page
    /// tombstone so sync removes it elsewhere, and the remaining pages
    /// re-sequenced so their indexes stay contiguous. The caller saves.
    static func delete(_ page: Page, from notebook: Notebook, in context: ModelContext,
                       drawingStore: DrawingStore, tombstones: SyncStateStore = LiveSyncStateStore.shared,
                       now: Date = Date()) {
        // A link travels with its source page, so pages that linked here
        // are marked too (Links.removeAll).
        Links.removeAll(touching: [page.id], in: context, now: now)
        // Work out which imported files this page is the last user of
        // BEFORE deleting its records - a multi-page PDF import shares one
        // file across many pages, so it can only be removed once none of
        // them reference it any more. Skipping this leaked every imported
        // photo permanently.
        let documents = (try? context.fetch(FetchDescriptor<ImportedDocument>())) ?? []
        let refsHere = Set(documents.filter { $0.page?.id == page.id }.map(\.fileRef))
        let refsElsewhere = Set(documents.filter { $0.page?.id != page.id }.map(\.fileRef))
        let orphanedRefs = refsHere.subtracting(refsElsewhere).filter { !$0.isEmpty }

        for doc in documents where doc.page?.id == page.id {
            context.delete(doc)
        }

        drawingStore.trashDrawing(forPageID: page.id)
        for ref in orphanedRefs {
            drawingStore.trashPayload(named: ref)
        }

        // Its audio, the same way: to trash/ unless another page's
        // recording names the same file.
        let recordings = (try? context.fetch(FetchDescriptor<Recording>())) ?? []
        let recordingRefsHere = Set(recordings.filter { $0.page?.id == page.id }.map(\.fileRef))
        let recordingRefsElsewhere = Set(recordings.filter { $0.page?.id != page.id }.map(\.fileRef))
        for ref in recordingRefsHere.subtracting(recordingRefsElsewhere) where !ref.isEmpty {
            drawingStore.trashPayload(named: ref)
        }

        notebook.pages?.removeAll { $0.id == page.id }
        context.delete(page) // cascades to its TypedTextBlocks/Stickers
        // So sync removes it elsewhere instead of bringing it back from
        // another device's copy. A page edited there *after* this moment
        // survives - the edit is newer than the deletion.
        SyncTombstones.merge([Tombstone(kind: .page, id: page.id, deletedAt: now)], into: tombstones)

        let remaining = (notebook.pages ?? []).sorted { $0.index < $1.index }
        for (newIndex, remainingPage) in remaining.enumerated() where remainingPage.index != newIndex {
            remainingPage.index = newIndex
            remainingPage.markModified()
        }
        notebook.modifiedAt = now
    }
}
