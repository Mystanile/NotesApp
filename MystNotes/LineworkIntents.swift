import Foundation
import SwiftUI
import SwiftData
import AppIntents

// Shortcuts and Siri: open a notebook, add a page, search. Locked notebooks
// are never listed, searched or written to by an intent (Face ID can't be
// shown from a shortcut).

// MARK: - Navigation requests

/// A request from outside the view tree (Spotlight, an intent) to show a
/// notebook, optionally at a page. `ContentView` consumes it.
struct PendingNavigation: Equatable {
    let notebookID: UUID
    let pageID: UUID?
}

@MainActor
@Observable
final class AppNavigationRequests {
    static let shared = AppNavigationRequests()
    var pendingPage: PendingNavigation?
    /// Set once by the app at launch so intents can reach the store. An
    /// intent that runs the app in the background launches this process
    /// too, so `App.init` has already run.
    @ObservationIgnored var container: ModelContainer?

    func request(notebookID: UUID, pageID: UUID? = nil) {
        pendingPage = PendingNavigation(notebookID: notebookID, pageID: pageID)
    }

    /// A Spotlight page hit carries only the page id; its notebook is looked up.
    func requestPage(_ pageID: UUID) {
        guard let context = container?.mainContext else { return }
        var descriptor = FetchDescriptor<Page>(predicate: #Predicate { $0.id == pageID })
        descriptor.fetchLimit = 1
        guard let notebookID = (try? context.fetch(descriptor))?.first?.notebook?.id else { return }
        request(notebookID: notebookID, pageID: pageID)
    }
}

// MARK: - Data access for intents

enum LineworkIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLibrary, notFound, locked

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLibrary: "Linework isn't ready yet. Open the app once and try again."
        case .notFound: "That notebook no longer exists."
        case .locked: "That notebook is locked. Open it in Linework."
        }
    }
}

@MainActor
enum LineworkIntentData {
    static func context() throws -> ModelContext {
        guard let container = AppNavigationRequests.shared.container else { throw LineworkIntentError.noLibrary }
        return container.mainContext
    }

    /// Notebooks an intent may see: not locked, not the templates notebook.
    static func openNotebooks(in context: ModelContext) -> [Notebook] {
        let all = (try? context.fetch(FetchDescriptor<Notebook>(sortBy: [SortDescriptor(\.title)]))) ?? []
        return PageTemplates.libraryNotebooks(all).filter { $0.isLocked != true }
    }

    static func notebook(id: UUID, in context: ModelContext) throws -> Notebook {
        var descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let notebook = try context.fetch(descriptor).first, !PageTemplates.isTemplatesNotebook(notebook) else {
            throw LineworkIntentError.notFound
        }
        guard notebook.isLocked != true else { throw LineworkIntentError.locked }
        return notebook
    }

    /// Mirrors the end of `addPage(like:)`: a page after the last one,
    /// attached, marked modified (which lifts the notebook), saved.
    @discardableResult
    static func appendPage(to notebook: Notebook, in context: ModelContext) throws -> Page {
        let next = ((notebook.pages ?? []).map(\.index).max() ?? -1) + 1
        let page = Page(index: next, notebook: notebook)
        context.insert(page)
        if !(notebook.pages ?? []).contains(where: { $0.id == page.id }) {
            notebook.pages = (notebook.pages ?? []) + [page]
        }
        page.markModified()
        try context.save()
        return page
    }

    /// Titles of up to `limit` pages whose title or cached text contains `query`.
    static func searchTitles(_ query: String, in context: ModelContext, limit: Int = 5) -> [String] {
        let snapshots = SpotlightSnapshots.capture(in: context)
        return IntentSearch.titles(matching: query, in: snapshots, limit: limit)
    }
}

/// Pure so it can be tested. Works on the same snapshots Spotlight uses,
/// which already leave out locked and templates notebooks.
nonisolated enum IntentSearch {
    static func titles(matching query: String, in notebooks: [SpotlightNotebookSnapshot], limit: Int = 5) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var out: [String] = []
        for spec in SpotlightItems.specs(from: notebooks) where !spec.isNotebook {
            if spec.title.localizedCaseInsensitiveContains(needle)
                || spec.contentDescription.localizedCaseInsensitiveContains(needle) {
                out.append(spec.title)
                if out.count == limit { break }
            }
        }
        return out
    }
}

// MARK: - Entity

nonisolated struct NotebookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Notebook"
    static let defaultQuery = NotebookEntityQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

nonisolated struct NotebookEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [NotebookEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [NotebookEntity] {
        await Self.all().filter { $0.title.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [NotebookEntity] {
        await Self.all()
    }

    @MainActor
    private static func all() -> [NotebookEntity] {
        guard let context = try? LineworkIntentData.context() else { return [] }
        return LineworkIntentData.openNotebooks(in: context).map { NotebookEntity(id: $0.id, title: $0.title) }
    }
}

// MARK: - Intents

nonisolated struct OpenNotebookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Notebook"
    static let openAppWhenRun = true

    @Parameter(title: "Notebook") var notebook: NotebookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigationRequests.shared.request(notebookID: notebook.id)
        return .result()
    }
}

nonisolated struct NewPageIntent: AppIntent {
    static let title: LocalizedStringResource = "New Page"
    static let openAppWhenRun = true

    @Parameter(title: "Notebook") var notebook: NotebookEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let context = try LineworkIntentData.context()
        let target = try LineworkIntentData.notebook(id: notebook.id, in: context)
        let page = try LineworkIntentData.appendPage(to: target, in: context)
        AppNavigationRequests.shared.request(notebookID: target.id, pageID: page.id)
        return .result()
    }
}

nonisolated struct SearchLineworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"

    @Parameter(title: "Search for") var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let context = try LineworkIntentData.context()
        let titles = LineworkIntentData.searchTitles(query, in: context)
        return .result(value: titles.isEmpty ? "No matching pages." : titles.joined(separator: "\n"))
    }
}

nonisolated struct LineworkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenNotebookIntent(), phrases: ["Open notebook in \(.applicationName)"],
                    shortTitle: "Open Notebook", systemImageName: "book")
        AppShortcut(intent: NewPageIntent(), phrases: ["New page in \(.applicationName)"],
                    shortTitle: "New Page", systemImageName: "plus.square")
        AppShortcut(intent: SearchLineworkIntent(), phrases: ["Search \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
    }
}
