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
/// Paper colour, one of three. A display preference (`AppSettings`).
nonisolated enum PaperColor: String, CaseIterable, Sendable {
    case white, cream, dark
    var label: String {
        switch self { case .white: return "White"; case .cream: return "Cream"; case .dark: return "Dark" }
    }
}

/// Line spacing, one of three. Multiplies the ruling's spacing.
nonisolated enum LineSpacingOption: String, CaseIterable, Sendable {
    case narrow, normal, wide
    var label: String {
        switch self { case .narrow: return "Narrow"; case .normal: return "Normal"; case .wide: return "Wide" }
    }
    var multiplier: CGFloat {
        switch self { case .narrow: return 0.8; case .normal: return 1; case .wide: return 1.25 }
    }
}

/// What the paper looks like: fill, ruling colour and spacing. One value,
/// resolved from `AppSettings`, handed to the live page, the thumbnails and
/// the exporter so they agree (it is part of `PageThumbnailRequest`, so a
/// change re-renders every thumbnail).
///
/// Dark paper is a display preference: the live canvas runs in a dark
/// interface style so PencilKit shows black ink as white, but exports and
/// thumbnails use white paper (`outputStyle`), because their ink is rendered
/// in the light trait and would vanish on a dark fill.
nonisolated struct PaperStyle: Hashable, Sendable {
    var color: PaperColor = .white
    var spacing: LineSpacingOption = .normal

    static let standard = PaperStyle()

    var multiplier: CGFloat { spacing.multiplier }
    var isDark: Bool { color == .dark }

    /// Fill as sRGB components.
    var fillRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch color {
        case .white: return (1, 1, 1)
        case .cream: return (0xFB / 255, 0xF7 / 255, 0xEE / 255)
        case .dark: return (0x1E / 255, 0x1F / 255, 0x24 / 255)
        }
    }

    /// Ruling as sRGB components plus alpha.
    var rulingRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        switch color {
        case .white: return (0.5, 0.5, 0.5, 0.25)
        case .cream: return (0.45, 0.40, 0.33, 0.28)
        case .dark: return (1, 1, 1, 0.18)
        }
    }

    var fillCGColor: CGColor {
        let f = fillRGB
        return CGColor(srgbRed: f.r, green: f.g, blue: f.b, alpha: 1)
    }

    func rulingCGColor(alphaScale: CGFloat = 1) -> CGColor {
        let c = rulingRGBA
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: min(c.a * alphaScale, 1))
    }

    var fillColor: Color {
        let f = fillRGB
        return Color(.sRGB, red: Double(f.r), green: Double(f.g), blue: Double(f.b), opacity: 1)
    }

    /// The style for thumbnails and exports: dark paper becomes white.
    var outputStyle: PaperStyle {
        PaperStyle(color: isDark ? .white : color, spacing: spacing)
    }

    /// Resolved from the stored raw values; unknown ones fall back to the defaults.
    static func resolve(colorRaw: String?, spacingRaw: String?) -> PaperStyle {
        PaperStyle(color: colorRaw.flatMap(PaperColor.init(rawValue:)) ?? .white,
                   spacing: spacingRaw.flatMap(LineSpacingOption.init(rawValue:)) ?? .normal)
    }

    /// The current preferences.
    static var current: PaperStyle {
        resolve(colorRaw: AppSettings.paperColorRaw, spacingRaw: AppSettings.lineSpacingRaw)
    }
}

nonisolated enum PageTemplate {
    /// The papers a user can pick, in menu order.
    static let options: [(id: String, label: String)] = [
        ("blank", "Blank"), ("lined", "Lined"), ("grid", "Grid"), ("dotted", "Dotted"),
        ("engineering", "Engineering"), ("cornell", "Cornell"),
    ]

    static let lineSpacing: CGFloat = 32
    static let dotSpacing: CGFloat = 24
    /// Engineering paper: a fine grid, every fifth line heavier.
    static let engineeringSpacing: CGFloat = 16
    /// Cornell notes: the cue column's width, and the summary box's height,
    /// as fractions of the page.
    static let cornellCueFraction: CGFloat = 0.28
    static let cornellSummaryFraction: CGFloat = 0.2
    /// White 0.5 at 25% - what `Color.gray.opacity(0.25)` resolved to in
    /// light mode, which is the ruling everyone has been looking at.
    static let patternGray: CGFloat = 0.5
    static let patternAlpha: CGFloat = 0.25

    /// Whether `template` puts anything on the page at all.
    static func isEmpty(_ template: String) -> Bool {
        switch template {
        case "lined", "grid", "dotted", "engineering", "cornell": return false
        default: return true
        }
    }

    /// Draws the ruling for `template` across `size`, in page points. The
    /// caller owns the paper colour underneath.
    static func draw(_ template: String, in size: CGSize, context: CGContext, paper: PaperStyle = .standard) {
        guard size.width > 0, size.height > 0, !isEmpty(template) else { return }
        context.saveGState()
        defer { context.restoreGState() }

        let color = paper.rulingCGColor()
        let k = paper.multiplier
        let lineStep = lineSpacing * k, dotStep = dotSpacing * k, engStep = engineeringSpacing * k
        switch template {
        case "lined":
            context.setStrokeColor(color)
            context.setLineWidth(1)
            strokeRows(in: size, step: lineStep, context: context)
            context.strokePath()
        case "grid":
            context.setStrokeColor(color)
            context.setLineWidth(1)
            strokeRows(in: size, step: lineStep, context: context)
            strokeColumns(in: size, step: lineStep, context: context)
            context.strokePath()
        case "dotted":
            context.setFillColor(color)
            var y = dotStep
            while y < size.height {
                var x = dotStep
                while x < size.width {
                    context.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += dotStep
                }
                y += dotStep
            }
        case "engineering":
            // Minor lines, then the heavier every-fifth ones over them.
            var major: [CGFloat] = []
            var index = 1
            context.setStrokeColor(color)
            context.setLineWidth(0.75)
            var offset = engStep
            while offset < max(size.width, size.height) {
                if index % 5 == 0 { major.append(offset) } else {
                    if offset < size.height { context.move(to: CGPoint(x: 0, y: offset)); context.addLine(to: CGPoint(x: size.width, y: offset)) }
                    if offset < size.width { context.move(to: CGPoint(x: offset, y: 0)); context.addLine(to: CGPoint(x: offset, y: size.height)) }
                }
                offset += engStep
                index += 1
            }
            context.strokePath()
            context.setStrokeColor(paper.rulingCGColor(alphaScale: 2))
            context.setLineWidth(1.25)
            for offset in major {
                if offset < size.height { context.move(to: CGPoint(x: 0, y: offset)); context.addLine(to: CGPoint(x: size.width, y: offset)) }
                if offset < size.width { context.move(to: CGPoint(x: offset, y: 0)); context.addLine(to: CGPoint(x: offset, y: size.height)) }
            }
            context.strokePath()
        case "cornell":
            // Lined notes, a cue column down the left and a summary box
            // across the bottom - the lines stop at the summary.
            let summaryTop = size.height * (1 - cornellSummaryFraction)
            context.setStrokeColor(color)
            context.setLineWidth(1)
            strokeRows(in: CGSize(width: size.width, height: summaryTop), step: lineStep, context: context)
            context.strokePath()
            context.setStrokeColor(paper.rulingCGColor(alphaScale: 2.5))
            context.setLineWidth(1.5)
            let cueX = size.width * cornellCueFraction
            context.move(to: CGPoint(x: cueX, y: 0)); context.addLine(to: CGPoint(x: cueX, y: summaryTop))
            context.move(to: CGPoint(x: 0, y: summaryTop)); context.addLine(to: CGPoint(x: size.width, y: summaryTop))
            context.strokePath()
        default:
            break
        }
    }

    private static func strokeRows(in size: CGSize, step: CGFloat, context: CGContext) {
        var y = step
        while y < size.height {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
    }

    private static func strokeColumns(in size: CGSize, step: CGFloat, context: CGContext) {
        var x = step
        while x < size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size.height))
            x += step
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
    let template: String  // one of `PageTemplate.options`; unknown ones are blank
    /// The paper itself. An imported photo draws its own white behind it
    /// only when it covers the page; otherwise the paper below shows
    /// through, which is the point.
    var showsPaper: Bool = true

    /// The paper preferences, live: changing them in Settings redraws.
    @AppStorage(AppSettings.Keys.paperColor) private var paperColorRaw = PaperColor.white.rawValue
    @AppStorage(AppSettings.Keys.lineSpacing) private var lineSpacingRaw = LineSpacingOption.normal.rawValue

    var body: some View {
        let paper = PaperStyle.resolve(colorRaw: paperColorRaw, spacingRaw: lineSpacingRaw)
        Canvas { context, size in
            context.withCGContext { cg in
                PageTemplate.draw(template, in: size, context: cg, paper: paper)
            }
        }
        .background(showsPaper ? paper.fillColor : Color.clear)
    }
}
