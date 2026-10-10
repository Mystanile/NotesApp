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
    // Lifted by every page edit (see Page.markModified) - the library's
    // sort key, not a merge key.
    var modifiedAt: Date = Date()

    // When the notebook's own settings - title, cover, folder - last
    // changed. Sync compares this, not modifiedAt, so a rename here can't
    // lose to a later page edit elsewhere. Optional so old rows migrate to
    // nil. Set it through markSettingsModified(at:).
    var settingsModifiedAt: Date?

    /// Starred in the library. A setting: it merges on
    /// `settingsModifiedAt` - which a star sets directly, without lifting
    /// `modifiedAt`, so starring a notebook doesn't reorder Recent.
    var isFavorite: Bool?

    /// Opening it asks for Face ID / the passcode (`NotebookLock`). A
    /// setting, on the settings clock like the star.
    var isLocked: Bool?

    var folder: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Page.notebook)
    var pages: [Page]? = []

    init(title: String = "Untitled Notebook", coverStyle: String = "default", folder: Folder? = nil) {
        self.id = UUID()
        self.title = title
        self.coverStyle = coverStyle
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.settingsModifiedAt = Date()
        self.folder = folder
    }
}

extension Notebook {
    /// Records a change to the notebook's own settings (title, cover,
    /// folder). Also lifts `modifiedAt` for the library sort.
    func markSettingsModified(at date: Date = Date()) {
        settingsModifiedAt = date
        if modifiedAt < date { modifiedAt = date }
    }
}

// MARK: - Page

@Model
final class Page {
    var id: UUID = UUID()
    var index: Int = 0
    var type: String = "paged"       // "paged" | "whiteboard"
    var template: String = "blank"   // one of `PageTemplate.options`

    /// In the notebook's outline, under `title` if it has one. Page
    /// content: set it, then `markModified()`.
    var isBookmarked: Bool?
    var title: String?

    // File on disk, not stored in the DB directly
    var drawingFileRef: String?
    var backgroundRef: String?

    // The page's shape, width / height. nil means the app's default page
    // (see PageGeometry.defaultAspectRatio). Importing a PDF sets this from
    // that PDF page's own media box, which is what makes an imported
    // engineering-paper template *be* the page - portrait, full bleed -
    // instead of a portrait picture floating in the middle of a
    // landscape-shaped canvas.
    var aspectRatio: Double?

    // Populated later by the Vision OCR pipeline (Phase 6), used for search
    var recognizedTextCache: String?

    // When this page's drawing was last OCR'd. Compared against the drawing
    // file's modification date so unchanged pages aren't re-recognized on
    // every search (OCR is the slow part).
    var ocrUpdatedAt: Date?

    // When the user last changed this page: ink, background, an element
    // added, its index moved. This is what sync compares page against
    // page, so it must move on every real edit and never on derived data
    // (`recognizedTextCache` / `ocrUpdatedAt` are not edits). Optional
    // without a default so pages from before the field migrate to nil,
    // which merge treats as older than any date. Set it through
    // `markModified(at:)`, not directly.
    var modifiedAt: Date?

    var notebook: Notebook?

    @Relationship(deleteRule: .cascade, inverse: \TypedTextBlock.page)
    var textBlocks: [TypedTextBlock]? = []

    @Relationship(deleteRule: .cascade, inverse: \Sticker.page)
    var stickers: [Sticker]? = []

    // The inverse of ImportedDocument.page, so deleting a page - or the
    // notebook or folder above it - takes its artwork rows too. Without
    // it the rows survived pointing at a page that was gone, and the
    // next notebook to open crashed on `doc.page` (Sept 21, 2026). Views
    // still build the stacks from a fetch; this exists for the cascade.
    @Relationship(deleteRule: .cascade, inverse: \ImportedDocument.page)
    var importedDocuments: [ImportedDocument]? = []

    init(index: Int = 0, type: String = "paged", template: String = "blank", notebook: Notebook? = nil) {
        self.id = UUID()
        self.index = index
        self.type = type
        self.template = template
        self.modifiedAt = Date()
        self.notebook = notebook
    }
}

extension Page {
    /// Records a user edit to this page. Also lifts the notebook's
    /// `modifiedAt` so the library sorts it to the top, but never lowers
    /// it - another page may have been edited more recently.
    func markModified(at date: Date = Date()) {
        modifiedAt = date
        if let notebook, notebook.modifiedAt < date {
            notebook.modifiedAt = date
        }
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

    // Typography. All defaulted so a record from before these fields
    // existed reads back exactly as it looked (17 pt system, regular).
    // `fontDesign` is one of `TextBlockFontDesign`'s raw values; unknown
    // values fall back to the system font rather than failing to render.
    var fontSize: Double = 17
    var fontDesign: String = "default"
    var isBold: Bool = false
    var isItalic: Bool = false

    var page: Page?

    init(content: String = "", page: Page? = nil) {
        self.id = UUID()
        self.content = content
        self.page = page
    }
}

/// The font families a text block can use. Kept to the system designs
/// rather than a font-name string so every device renders the same thing -
/// a named font that isn't installed on the other side would silently swap
/// to something else after a sync.
enum TextBlockFontDesign: String, CaseIterable, Identifiable {
    case `default`, serif, rounded, monospaced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        }
    }

    /// Unknown raw values (a newer build's future addition) render as the
    /// system font instead of dropping the block.
    static func from(_ raw: String) -> TextBlockFontDesign {
        TextBlockFontDesign(rawValue: raw) ?? .default
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

    // Where the imported artwork sits on the page, as *fractions* of the
    // page's width/height (0...1) rather than absolute points. Fractions
    // are resolution-independent, so the same placement renders correctly
    // on any canvas size and in the page thumbnails, which have no idea
    // what size canvas the artwork was originally placed against.
    // All-nil means "unplaced": aspect-fit centered, matching how every
    // import behaved before placement was adjustable.
    var frameX: Double?
    var frameY: Double?
    var frameWidth: Double?
    var frameHeight: Double?

    // Clockwise rotation in degrees, in 90-degree steps. nil == 0.
    var rotationDegrees: Double?

    // Visible region of the *source* artwork, as fractions of its own size
    // (0...1). All-nil means uncropped. Kept separate from the frame above
    // so cropping is non-destructive - the imported file is never rewritten
    // and a crop can always be widened again.
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?

    // Position in the page's artwork stack, bottom first. A page holds
    // any number of these - a PDF page as its paper with photos placed
    // over it - and this is the order they are drawn in. nil == 0, which
    // is every artwork imported before a page could hold more than one.
    var stackOrder: Int?

    var page: Page?

    init(sourceType: String = "pdf", fileRef: String = "", pdfPageIndex: Int = 0, page: Page? = nil) {
        self.id = UUID()
        self.sourceType = sourceType
        self.fileRef = fileRef
        self.pdfPageIndex = pdfPageIndex
        self.page = page
    }
}

extension ImportedDocument {
    /// The artwork on one page, bottom first - the order it is drawn in.
    /// `ImportedDocument` has no inverse relationship from `Page`, so
    /// callers hand in the documents they already hold. Ties (two imports
    /// from before ordering existed) fall back to the id, so every device
    /// draws the same stack.
    static func stack(on pageID: UUID, in documents: [ImportedDocument]) -> [ImportedDocument] {
        documents
            .filter { $0.page?.id == pageID }
            .sorted { ($0.stackOrder ?? 0, $0.id.uuidString) < ($1.stackOrder ?? 0, $1.id.uuidString) }
    }

    /// Where a new import goes in a page's existing stack. A full-bleed
    /// PDF is the page's paper and goes under everything already there; a
    /// picture is placed on the page and goes on top. Nothing is replaced
    /// either way.
    static func stackOrder(under stack: [ImportedDocument]) -> Int { (stack.first?.stackOrder ?? 0) - 1 }
    static func stackOrder(over stack: [ImportedDocument]) -> Int { (stack.last?.stackOrder ?? 0) + 1 }

    /// Every page's stack at once, for the views that draw many pages -
    /// the page strip asks for every page in the notebook.
    static func stacksByPage(_ documents: [ImportedDocument]) -> [UUID: [ImportedDocument]] {
        var result: [UUID: [ImportedDocument]] = [:]
        for doc in documents {
            guard let id = doc.page?.id else { continue }
            result[id, default: []].append(doc)
        }
        for id in result.keys {
            result[id]?.sort { ($0.stackOrder ?? 0, $0.id.uuidString) < ($1.stackOrder ?? 0, $1.id.uuidString) }
        }
        return result
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

    // M2: a link is a graph edge (BACKLOG, "M2 design"). All optional; nil
    // means what every link before M2 was - an explicit link to a page,
    // which `destinationPageID` names. `destinationPageID` stays filled for
    // every kind that lives on a page, so older code keeps navigating.
    /// "explicit" (nil), later "tag" and "transclusion".
    var kind: String?
    /// "page" (nil), "region", "textBlock", "notebook".
    var destinationKind: String?
    /// The target's own id when it isn't the page: a text block's or a
    /// notebook's UUID string.
    var destinationID: String?
    /// A region's strokes, by their stable ids (invariant 6).
    var strokeIDs: [String]?

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
    /// Clockwise, about the frame's centre. nil is unturned: every sticker
    /// from before stickers could rotate (Sept 25, 2026).
    var rotationDegrees: Double?

    var page: Page?

    init(assetRef: String = "", page: Page? = nil) {
        self.id = UUID()
        self.assetRef = assetRef
        self.page = page
    }
}
