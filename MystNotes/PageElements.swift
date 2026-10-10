import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit

/// What sits on a page above its ink - typed text, stickers, link anchors -
/// as plain values, so an export and a thumbnail (off the main thread) draw
/// them the way `PageElementsOverlayView` shows them. Exports used to leave
/// stickers and link anchors out entirely, and thumbnails had no text
/// (invariant 9, Sept 25, 2026).
nonisolated struct PageElements: Hashable, Sendable {
    struct Text: Hashable, Sendable {
        var content: String
        var frame: CGRect
        var fontSize: Double
        var fontDesign: String
        var isBold: Bool
        var isItalic: Bool
        var colorHex: String
    }
    struct Symbol: Hashable, Sendable {
        var name: String
        var frame: CGRect
        /// Clockwise degrees about the frame's centre.
        var rotation: Double = 0
    }
    struct Anchor: Hashable, Sendable {
        var frame: CGRect
        var destinationPageID: UUID
    }

    var texts: [Text] = []
    /// SF Symbols, drawn yellow as on the page.
    var stickers: [Symbol] = []
    var links: [Anchor] = []

    var isEmpty: Bool { texts.isEmpty && stickers.isEmpty && links.isEmpty }

    /// Draws into the current UIKit context, in page points. Text, then
    /// stickers, then link anchors - the overlay's order.
    func draw(in pageSize: CGSize) {
        for text in texts where !text.content.isEmpty {
            // As `TextBlockView` lays it out: the stored frame is the box,
            // 6pt of padding inside it, the width is the wrap width and the
            // height a floor the text may grow past.
            let inset: CGFloat = 6
            let rect = CGRect(x: text.frame.minX + inset, y: text.frame.minY + inset,
                              width: max(text.frame.width - inset * 2, 1),
                              height: max(pageSize.height - text.frame.minY - inset, 1))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            NSAttributedString(string: text.content, attributes: [
                .font: Self.font(for: text),
                .foregroundColor: Self.color(hex: text.colorHex),
                .paragraphStyle: paragraph
            ]).draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
        }
        for sticker in stickers {
            guard let image = Self.symbol(sticker.name, color: .systemYellow),
                  let context = UIGraphicsGetCurrentContext() else { continue }
            let frame = Self.fitted(image.size, in: sticker.frame)
            context.saveGState()
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: sticker.rotation * .pi / 180)
            image.draw(in: CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height))
            context.restoreGState()
        }
        for link in links {
            let circle = Self.fitted(CGSize(width: 1, height: 1), in: link.frame)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: circle).fill()
            Self.symbol("link.circle.fill", color: .systemBlue)?.draw(in: circle)
        }
    }

    /// The UIKit font matching `TextBlockView`'s SwiftUI one, so an export
    /// wraps at the same places the editor does.
    static func font(for text: Text) -> UIFont {
        let base = UIFont.systemFont(ofSize: CGFloat(text.fontSize), weight: text.isBold ? .bold : .regular)
        var descriptor = base.fontDescriptor
        let design: UIFontDescriptor.SystemDesign
        switch text.fontDesign {
        case "serif": design = .serif
        case "rounded": design = .rounded
        case "monospaced": design = .monospaced
        default: design = .default
        }
        if design != .default, let designed = descriptor.withDesign(design) { descriptor = designed }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if text.isBold { traits.insert(.traitBold) }
        if text.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
        return UIFont(descriptor: descriptor, size: CGFloat(text.fontSize))
    }

    /// `Color(hex:)`'s parse, straight to a fixed UIColor - off the main
    /// actor, and never re-resolved for dark mode.
    static func color(hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func symbol(_ name: String, color: UIColor) -> UIImage? {
        let configured = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 200))
            ?? UIImage(systemName: "star.fill")
        return configured?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// A picture of `size`'s shape aspect-fitted in `frame`, centred - as
    /// `.scaledToFit()` places a symbol.
    private static func fitted(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

extension PageElements {
    /// Read off the models, on the main actor. Links are the ones whose
    /// anchor sits on this page (`sourcePageID`); pass them, or leave nil
    /// to fetch them from the page's own context.
    @MainActor
    init(page: Page, links: [Link]? = nil) {
        texts = (page.textBlocks ?? []).map {
            Text(content: $0.content, frame: CGRect(x: $0.frameX, y: $0.frameY, width: $0.frameWidth, height: $0.frameHeight),
                 fontSize: $0.fontSize, fontDesign: $0.fontDesign, isBold: $0.isBold, isItalic: $0.isItalic,
                 colorHex: $0.textColorHex)
        }
        stickers = (page.stickers ?? []).map {
            Symbol(name: $0.assetRef.isEmpty ? "star.fill" : $0.assetRef,
                   frame: CGRect(x: $0.frameX, y: $0.frameY, width: $0.frameWidth, height: $0.frameHeight),
                   rotation: $0.rotationDegrees ?? 0)
        }
        let all = links ?? (try? page.modelContext?.fetch(FetchDescriptor<Link>())) ?? []
        self.links = all.filter { $0.sourcePageID == page.id && $0.kind != "mention" }.map {
            Anchor(frame: CGRect(x: $0.anchorX, y: $0.anchorY, width: $0.anchorWidth, height: $0.anchorHeight),
                   destinationPageID: $0.destinationPageID)
        }
    }
}

/// What Convert to Text puts on the page, kept as a value so undo can take
/// the box away and redo put the same one back.
struct TextBlockSnapshot {
    var id: UUID
    var content: String
    var frame: CGRect = .zero
    var fontSize: Double = 17
}
#endif
