import Foundation
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#endif

/// Builds the "Welcome to Mystnotes" notebook shown the first time someone's
/// library is empty — a real notebook, not a static walkthrough image, so
/// its pen strokes, text boxes, sticker, and link are the actual elements
/// the notebook interface supports, demonstrated in place. Runs once ever,
/// gated by `AppSettings.hasSeededTutorialNotebook` (see `LibraryView`) so
/// deliberately deleting it doesn't bring it back.
enum TutorialNotebookFactory {
    @MainActor
    static func makeWelcomeNotebook(in context: ModelContext) {
        let notebook = Notebook(title: "Welcome to Mystnotes", coverStyle: "default")
        context.insert(notebook)

        let welcomePage = makeWelcomePage(notebook: notebook, context: context)

        var pages: [Page] = [welcomePage]
        pages.append(makeDrawingPage(notebook: notebook, context: context))
        pages.append(makeShapesPage(notebook: notebook, context: context))
        pages.append(makeElementsPage(notebook: notebook, context: context, linkBackTo: welcomePage.id))
        pages.append(makeWhiteboardPage(notebook: notebook, context: context))
        pages.append(makeWrapUpPage(notebook: notebook, context: context))

        for (index, page) in pages.enumerated() {
            page.index = index
        }
        notebook.pages = pages
        notebook.modifiedAt = Date()
    }

    // MARK: - Page 1: Welcome

    private static func makeWelcomePage(notebook: Notebook, context: ModelContext) -> Page {
        let page = Page(index: 0, type: "paged", template: "blank", notebook: notebook)
        context.insert(page)

        addText(
            "Welcome to Mystnotes",
            frame: (x: 40, y: 50, w: 520, h: 60),
            to: page, in: context
        )
        addText(
            "This notebook is real — everything on these pages is made of actual ink, text boxes, and stickers, the same building blocks every notebook you make is built from. Flip through the page strip below the canvas to see what's possible, then delete this one whenever you've got the hang of it (long-press its cover in the Library, then Delete).",
            frame: (x: 40, y: 130, w: 520, h: 160),
            to: page, in: context
        )
        return page
    }

    // MARK: - Page 2: Drawing

    private static func makeDrawingPage(notebook: Notebook, context: ModelContext) -> Page {
        let page = Page(index: 1, type: "paged", template: "lined", notebook: notebook)
        context.insert(page)

        addText(
            "Draw naturally",
            frame: (x: 40, y: 40, w: 480, h: 44),
            to: page, in: context
        )
        addText(
            "Apple Pencil, finger, or — on the Mac — mouse and trackpad all work here. Open the tool picker's pen menu to switch between five ink types and pick a color and width. That's a real stroke below, not a picture of one.",
            frame: (x: 40, y: 96, w: 520, h: 110),
            to: page, in: context
        )

        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        var strokes: [PKStroke] = []
        // A loose, friendly flourish underline beneath the word "naturally".
        strokes.append(stroke(
            points: bezier(from: CGPoint(x: 60, y: 250), control: CGPoint(x: 260, y: 320), to: CGPoint(x: 480, y: 240), samples: 40),
            color: .systemIndigo, width: 6
        ))
        // A checkmark, to feel like a deliberate, confident mark rather than a scribble.
        strokes.append(stroke(
            points: [
                CGPoint(x: 90, y: 380), CGPoint(x: 90, y: 380),
                CGPoint(x: 130, y: 430), CGPoint(x: 220, y: 320)
            ],
            color: .label, width: 8
        ))
        writeDrawing(strokes, to: page)
        #endif

        return page
    }

    // MARK: - Page 3: Shapes & tools

    private static func makeShapesPage(notebook: Notebook, context: ModelContext) -> Page {
        let page = Page(index: 2, type: "paged", template: "grid", notebook: notebook)
        context.insert(page)

        addText(
            "Shapes clean themselves up",
            frame: (x: 40, y: 40, w: 520, h: 44),
            to: page, in: context
        )
        addText(
            "The shape tool (square-in-a-circle icon) turns a rough freehand rectangle or oval into a perfect one automatically, in your current pen color. Lasso-select any stroke afterward to move, resize, or rotate it.",
            frame: (x: 40, y: 96, w: 520, h: 100),
            to: page, in: context
        )

        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        var strokes: [PKStroke] = []
        strokes.append(stroke(points: rectanglePoints(in: CGRect(x: 60, y: 260, width: 180, height: 130)), color: .systemTeal, width: 5))
        strokes.append(stroke(points: ellipsePoints(in: CGRect(x: 300, y: 250, width: 170, height: 150), samples: 60), color: .systemOrange, width: 5))
        writeDrawing(strokes, to: page)
        #endif

        return page
    }

    // MARK: - Page 4: Text, stickers & links

    private static func makeElementsPage(notebook: Notebook, context: ModelContext, linkBackTo destinationPageID: UUID) -> Page {
        let page = Page(index: 3, type: "paged", template: "blank", notebook: notebook)
        context.insert(page)

        addText(
            "Text, stickers & links",
            frame: (x: 40, y: 40, w: 520, h: 44),
            to: page, in: context
        )
        addText(
            "Add any of these from the + menu in the toolbar. All three are always draggable — tap and hold, then move.",
            frame: (x: 40, y: 96, w: 520, h: 70),
            to: page, in: context
        )
        addText(
            "This is a text box. Tap it to edit, drag it to move.",
            frame: (x: 60, y: 220, w: 300, h: 90),
            to: page, in: context
        )

        let sticker = Sticker(assetRef: "star.fill", page: page)
        sticker.frameX = 420
        sticker.frameY = 230
        sticker.frameWidth = 70
        sticker.frameHeight = 70
        context.insert(sticker)
        if page.stickers == nil { page.stickers = [sticker] } else { page.stickers?.append(sticker) }
        addText(
            "A sticker",
            frame: (x: 400, y: 310, w: 120, h: 34),
            to: page, in: context
        )

        addText(
            "That blue circle below is a link — tap it to jump straight to the Welcome page.",
            frame: (x: 60, y: 340, w: 300, h: 70),
            to: page, in: context
        )
        let link = Link(sourcePageID: page.id, destinationPageID: destinationPageID)
        link.anchorX = 220
        link.anchorY = 420
        link.anchorWidth = 48
        link.anchorHeight = 48
        context.insert(link)

        return page
    }

    // MARK: - Page 5: Whiteboard

    private static func makeWhiteboardPage(notebook: Notebook, context: ModelContext) -> Page {
        let page = Page(index: 4, type: "whiteboard", template: "blank", notebook: notebook)
        context.insert(page)

        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        var strokes: [PKStroke] = []
        // Whiteboard pages are a big scroll-and-zoom canvas (3000x3000pt) —
        // draw the note near its top-left so it's visible without scrolling.
        strokes.append(stroke(
            points: [CGPoint(x: 80, y: 60), CGPoint(x: 90, y: 60)],
            color: .label, width: 2
        ))
        strokes.append(stroke(
            points: bezier(from: CGPoint(x: 60, y: 160), control: CGPoint(x: 220, y: 80), to: CGPoint(x: 420, y: 160), samples: 40),
            color: .systemPurple, width: 6
        ))
        strokes.append(stroke(
            points: [CGPoint(x: 400, y: 130), CGPoint(x: 440, y: 160), CGPoint(x: 400, y: 190)],
            color: .systemPurple, width: 6
        ))
        writeDrawing(strokes, to: page)
        #endif

        return page
    }

    // MARK: - Page 6: Wrap-up

    private static func makeWrapUpPage(notebook: Notebook, context: ModelContext) -> Page {
        let page = Page(index: 5, type: "paged", template: "dotted", notebook: notebook)
        context.insert(page)

        addText(
            "Search, present & sync",
            frame: (x: 40, y: 40, w: 520, h: 44),
            to: page, in: context
        )
        addText(
            "The magnifying glass in the Library searches every notebook at once — typed text, PDF text, and even your handwriting, recognized on-device.\n\nThe play-rectangle icon here in the notebook toolbar drops all the chrome for a clean screen share.\n\nEverything syncs to your other devices over iCloud automatically — no setup needed.\n\nThat's the whole tour. Go make something.",
            frame: (x: 40, y: 96, w: 520, h: 300),
            to: page, in: context
        )
        return page
    }

    // MARK: - Shared helpers

    @discardableResult
    private static func addText(
        _ content: String,
        frame: (x: Double, y: Double, w: Double, h: Double),
        to page: Page,
        in context: ModelContext
    ) -> TypedTextBlock {
        let block = TypedTextBlock(content: content, page: page)
        block.frameX = frame.x
        block.frameY = frame.y
        block.frameWidth = frame.w
        block.frameHeight = frame.h
        context.insert(block)
        if page.textBlocks == nil { page.textBlocks = [block] } else { page.textBlocks?.append(block) }
        return block
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private static func writeDrawing(_ strokes: [PKStroke], to page: Page) {
        let drawing = PKDrawing(strokes: strokes)
        let url = FileStore.url(for: "\(page.id.uuidString).drawing")
        do {
            try drawing.dataRepresentation().write(to: url)
            page.drawingFileRef = url.lastPathComponent
        } catch {
            print("Failed to write tutorial drawing: \(error)")
        }
    }

    private static func stroke(points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        let ink = PKInk(.pen, color: color)
        var strokePoints: [PKStrokePoint] = []
        var timeOffset: TimeInterval = 0
        for (index, point) in points.enumerated() {
            if index > 0 {
                let prev = points[index - 1]
                let dx = point.x - prev.x, dy = point.y - prev.y
                timeOffset += Double(sqrt(dx * dx + dy * dy)) * 0.002
            }
            strokePoints.append(PKStrokePoint(
                location: point,
                timeOffset: timeOffset,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ))
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }

    private static func rectanglePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
    }

    private static func ellipsePoints(in rect: CGRect, samples: Int) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2, ry = rect.height / 2
        return (0...samples).map { i in
            let angle = (CGFloat(i) / CGFloat(samples)) * 2 * .pi
            return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
        }
    }

    /// A soft quadratic-bezier curve, sampled into points — used for the
    /// friendly flourish strokes rather than straight lines.
    private static func bezier(from start: CGPoint, control: CGPoint, to end: CGPoint, samples: Int) -> [CGPoint] {
        (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples)
            let mt = 1 - t
            let x = mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x
            let y = mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y
            return CGPoint(x: x, y: y)
        }
    }
    #endif
}
