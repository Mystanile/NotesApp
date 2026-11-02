import XCTest
import SwiftData
@testable import Mystnotes

/// Custom page templates: the templates notebook, hiding it from the
/// library, and starting a page from a template.
@MainActor
final class PageTemplatesTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                             ImportedDocument.self, Link.self, Sticker.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    func testTemplatesNotebook_isNilWithoutCreate_andCreatedOnceWithItsRole() throws {
        let context = try makeContext()
        XCTAssertNil(PageTemplates.templatesNotebook(in: context, create: false))

        let first = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        let second = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        XCTAssertEqual(first.id, second.id, "created twice")
        XCTAssertEqual(first.role, "templates")
        XCTAssertEqual(first.title, "Templates")
        XCTAssertNotNil(first.settingsModifiedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Notebook>()).count, 1)
        XCTAssertEqual(PageTemplates.templatesNotebook(in: context, create: false)?.id, first.id)
    }

    func testLibraryFilter_hidesTheTemplatesNotebook() throws {
        let context = try makeContext()
        let ordinary = Notebook(title: "Physics")
        context.insert(ordinary)
        let templates = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        let all = try context.fetch(FetchDescriptor<Notebook>())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(PageTemplates.libraryNotebooks(all).map(\.id), [ordinary.id])
        XCTAssertFalse(PageTemplates.libraryNotebooks(all).contains { $0.id == templates.id })
    }

    func testTemplates_areListedInIndexOrder() throws {
        let context = try makeContext()
        let notebook = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        for index in [2, 0, 1] {
            let page = Page(index: index, notebook: notebook)
            page.title = "T\(index)"
            context.insert(page)
        }
        XCTAssertEqual(PageTemplates.templates(in: context).map { $0.title ?? "" }, ["T0", "T1", "T2"])
    }

    func testInsertFromTemplate_copiesPaperNotInk_andRenumbersAfterTheCurrentPage() throws {
        let context = try makeContext()
        let templates = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        let template = Page(index: 0, type: "paged", template: "grid", notebook: templates)
        template.aspectRatio = 0.5
        template.drawingFileRef = "ink-that-must-not-travel.strokes"
        template.recognizedTextCache = "hello"
        context.insert(template)
        let art = ImportedDocument(sourceType: "pdf", fileRef: "paper.pdf", pdfPageIndex: 2, page: template)
        (art.frameX, art.frameY, art.frameWidth, art.frameHeight) = (0, 0, 1, 1)
        art.rotationDegrees = 90
        (art.cropX, art.cropY, art.cropWidth, art.cropHeight) = (0.1, 0.1, 0.8, 0.8)
        context.insert(art)
        context.insert(TypedTextBlock(content: "no text either", page: template))

        let notebook = Notebook(title: "N")
        context.insert(notebook)
        let pages = (0..<3).map { Page(index: $0, notebook: notebook) }
        pages.forEach(context.insert)
        notebook.pages = pages

        let made = PageTemplates.insertPage(copyingPaperOf: template, into: notebook, at: pages[1].index + 1,
                                            paperOnly: false, in: context)
        try context.save()

        let ordered = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(ordered.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(ordered.map(\.id), [pages[0].id, pages[1].id, made.id, pages[2].id])
        XCTAssertNotNil(pages[2].modifiedAt)

        XCTAssertEqual(made.template, "grid")
        XCTAssertEqual(made.type, "paged")
        XCTAssertEqual(made.aspectRatio, 0.5)
        XCTAssertEqual(made.backgroundRef, "paper.pdf")
        XCTAssertNil(made.drawingFileRef, "ink copied")
        XCTAssertNil(made.recognizedTextCache)
        XCTAssertTrue(made.textBlocks?.isEmpty ?? true, "text copied")

        let copy = try XCTUnwrap(made.importedDocuments?.first)
        XCTAssertEqual(made.importedDocuments?.count, 1)
        XCTAssertNotEqual(copy.id, art.id)
        XCTAssertEqual(copy.fileRef, "paper.pdf")
        XCTAssertEqual(copy.pdfPageIndex, 2)
        XCTAssertEqual(copy.frameWidth, 1)
        XCTAssertEqual(copy.rotationDegrees, 90)
        XCTAssertEqual(copy.cropX, 0.1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportedDocument>()).count, 2, "template keeps its own row")
    }

    func testSaveAsTemplate_takesOnlyAPaperLayer_andAppendsToTheTemplatesNotebook() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "N")
        context.insert(notebook)
        let withPaper = Page(index: 0, template: "lined", notebook: notebook)
        let withPhoto = Page(index: 1, template: "dotted", notebook: notebook)
        [withPaper, withPhoto].forEach(context.insert)
        let paper = ImportedDocument(sourceType: "pdf", fileRef: "p.pdf", pdfPageIndex: 0, page: withPaper)
        context.insert(paper)
        let photo = ImportedDocument(sourceType: "image", fileRef: "x.png", pdfPageIndex: 0, page: withPhoto)
        context.insert(photo)

        let first = try XCTUnwrap(PageTemplates.saveAsTemplate(withPaper, in: context))
        let second = try XCTUnwrap(PageTemplates.saveAsTemplate(withPhoto, in: context))

        XCTAssertEqual(first.importedDocuments?.first?.fileRef, "p.pdf")
        XCTAssertTrue(second.importedDocuments?.isEmpty ?? true, "a placed photo is not paper")
        XCTAssertEqual(second.template, "dotted")
        XCTAssertEqual(PageTemplates.templates(in: context).map(\.id), [first.id, second.id])
        XCTAssertEqual(first.notebook?.role, "templates")
    }

    func testRename_setsTheTitle_andEmptyGoesBackToTheDefault() throws {
        let context = try makeContext()
        let notebook = try XCTUnwrap(PageTemplates.templatesNotebook(in: context, create: true))
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        page.modifiedAt = Date(timeIntervalSince1970: 0)
        PageTemplates.rename(page, to: "  Cornell A4 ")
        XCTAssertEqual(page.title, "Cornell A4")
        XCTAssertGreaterThan(try XCTUnwrap(page.modifiedAt), Date(timeIntervalSince1970: 0))
        PageTemplates.rename(page, to: "  ")
        XCTAssertNil(page.title)
        XCTAssertEqual(PageTemplates.displayName(page), "Template 1")
    }
}
