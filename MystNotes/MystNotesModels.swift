import Foundation
import SwiftData

// MARK: - Folder

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""

    var parentFolder: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parentFolder)
    var subfolders: [Folder]? = []

    @Relationship(deleteRule: .cascade, inverse: \Notebook.folder)
    var notebooks: [Notebook]? = []

    init(name: String = "", parentFolder: Folder? = nil) {
        self.id = UUID()
        self.name = name
        self.parentFolder = parentFolder
    }
}

// MARK: - Notebook

@Model
final class Notebook {
    var id: UUID = UUID()
    var title: String = "Untitled Notebook"
    var coverStyle: String = "default"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    var folder: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]? = []

    init(title: String = "Untitled Notebook", coverStyle: String = "default", folder: Folder? = nil) {
        self.id = UUID()
        self.title = title
        self.coverStyle = coverStyle
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.folder = folder
    }
}

// MARK: - Page

@Model
final class Page {
    var id: UUID = UUID()
    var index: Int = 0
    var type: String = "paged"       // "paged" | "whiteboard"
    var template: String = "blank"   // "blank" | "lined" | "grid" | "dotted"

    // File on disk, not stored in the DB directly
    var drawingFileRef: String?
    var backgroundRef: String?

    // Populated later by the Vision OCR pipeline (Phase 6), used for search
    var recognizedTextCache: String?

    // When this page's drawing was last OCR'd. Compared against the drawing
    // file's modification date so unchanged pages aren't re-recognized on
    // every search (OCR is the slow part).
    var ocrUpdatedAt: Date?

    var notebook: Notebook?

    @Relationship(deleteRule: .cascade, inverse: \TypedTextBlock.page)
    var textBlocks: [TypedTextBlock]? = []

    @Relationship(deleteRule: .cascade, inverse: \Sticker.page)
    var stickers: [Sticker]? = []

    init(index: Int = 0, type: String = "paged", template: String = "blank", notebook: Notebook? = nil) {
        self.id = UUID()
        self.index = index
        self.type = type
        self.template = template
        self.notebook = notebook
    }
}

// MARK: - TypedTextBlock

@Model
final class TypedTextBlock {
    var id: UUID = UUID()
    var content: String = ""

    // Frame stored as flat Doubles rather than CGRect for SwiftData/CloudKit compatibility
    var frameX: Double = 0
    var frameY: Double = 0
    var frameWidth: Double = 200
    var frameHeight: Double = 44

    // Defaults to black (not left to the system's adaptive text color) so
    // text is visible immediately regardless of light/dark mode. Stored as
    // a hex string since SwiftData/CloudKit can't store Color directly.
    var textColorHex: String = "#000000"

    var page: Page?

    init(content: String = "", page: Page? = nil) {
        self.id = UUID()
        self.content = content
        self.page = page
    }
}

// MARK: - ImportedDocument

@Model
final class ImportedDocument {
    var id: UUID = UUID()
    var sourceType: String = "pdf" // "pdf" | "image" | "pptx"
    var fileRef: String = ""

    // Which page within the source PDF this record/Page represents.
    // Always 0 for images (a single "page").
    var pdfPageIndex: Int = 0

    var page: Page?

    init(sourceType: String = "pdf", fileRef: String = "", pdfPageIndex: Int = 0, page: Page? = nil) {
        self.id = UUID()
        self.sourceType = sourceType
        self.fileRef = fileRef
        self.pdfPageIndex = pdfPageIndex
        self.page = page
    }
}

// MARK: - Link (internal hyperlink)

@Model
final class Link {
    var id: UUID = UUID()
    var sourcePageID: UUID = UUID()
    var destinationPageID: UUID = UUID()

    var anchorX: Double = 0
    var anchorY: Double = 0
    var anchorWidth: Double = 44
    var anchorHeight: Double = 44

    init(sourcePageID: UUID = UUID(), destinationPageID: UUID = UUID()) {
        self.id = UUID()
        self.sourcePageID = sourcePageID
        self.destinationPageID = destinationPageID
    }
}

// MARK: - Sticker

@Model
final class Sticker {
    var id: UUID = UUID()
    var assetRef: String = ""

    var frameX: Double = 0
    var frameY: Double = 0
    var frameWidth: Double = 60
    var frameHeight: Double = 60

    var page: Page?

    init(assetRef: String = "", page: Page? = nil) {
        self.id = UUID()
        self.assetRef = assetRef
        self.page = page
    }
}
