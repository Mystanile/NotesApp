import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// The paper pattern itself - blank, lined, grid or dotted - drawn into a
/// `CGContext` in page points.
///
/// One implementation, three callers: the live canvas (`PageBackgroundView`
/// below), the page-strip thumbnails and the exporter. They used to disagree
/// completely: only the canvas drew a template at all, so a lined page
/// exported and thumbnailed as blank paper, and importing a photo replaced
/// the template outright because the artwork *was* the page's background.
/// Now the paper is always the bottom layer and imported artwork sits on
/// top of it.
///
/// The pattern colour is a fixed gray, not a dynamic system one: a page is
/// white paper whatever the system appearance, and a dynamic gray would
/// make the ruling change colour in dark mode the way the ink itself once
/// did.
nonisolated enum PageTemplate {
    /// The papers a user can pick, in menu order.
    static let options: [(id: String, label: String)] = [
        ("blank", "Blank"), ("lined", "Lined"), ("grid", "Grid"), ("dotted", "Dotted"),
    ]

    static let lineSpacing: CGFloat = 32
    static let dotSpacing: CGFloat = 24
    /// White 0.5 at 25% - what `Color.gray.opacity(0.25)` resolved to in
    /// light mode, which is the ruling everyone has been looking at.
    static let patternGray: CGFloat = 0.5
    static let patternAlpha: CGFloat = 0.25

    /// Whether `template` puts anything on the page at all.
    static func isEmpty(_ template: String) -> Bool {
        switch template {
        case "lined", "grid", "dotted": return false
        default: return true
        }
    }

    /// Draws the ruling for `template` across `size`, in page points. The
    /// caller owns the paper colour underneath.
    static func draw(_ template: String, in size: CGSize, context: CGContext) {
        guard size.width > 0, size.height > 0, !isEmpty(template) else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let color = CGColor(gray: patternGray, alpha: patternAlpha)
        switch template {
        case "lined":
            context.setStrokeColor(color)
            context.setLineWidth(1)
            strokeRows(in: size, context: context)
            context.strokePath()
        case "grid":
            context.setStrokeColor(color)
            context.setLineWidth(1)
            strokeRows(in: size, context: context)
            strokeColumns(in: size, context: context)
            context.strokePath()
        case "dotted":
            context.setFillColor(color)
            var y = dotSpacing
            while y < size.height {
                var x = dotSpacing
                while x < size.width {
                    context.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += dotSpacing
                }
                y += dotSpacing
            }
        default:
            break
        }
    }

    private static func strokeRows(in size: CGSize, context: CGContext) {
        var y = lineSpacing
        while y < size.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
            y += lineSpacing
        }
    }

    private static func strokeColumns(in size: CGSize, context: CGContext) {
        var x = lineSpacing
        while x < size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
            x += lineSpacing
        }
    }
}

/// Renders the paper background pattern (blank/lined/grid/dotted) behind the
/// PencilKit canvas. PencilKit has no concept of "paper" itself, so this sits
/// underneath a transparent PKCanvasView in a ZStack.
///
/// The ruling goes through `PageTemplate` rather than being drawn here, so
/// what you write on, what the thumbnail shows and what you export are the
/// same paper.
struct PageBackgroundView: View {
    let template: String  // "blank" | "lined" | "grid" | "dotted"
    /// The paper itself. An imported photo draws its own white behind it
    /// only when it covers the page; otherwise the paper below shows
    /// through, which is the point.
    var showsPaper: Bool = true

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                PageTemplate.draw(template, in: size, context: cg)
            }
        }
        .background(showsPaper ? Color.white : Color.clear)
    }
}
