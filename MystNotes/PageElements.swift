import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
import PencilKit

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

    /// A node's ink shown on this page (a "transclusion" link). It carries
    /// what is needed to draw the owner's strokes and nothing of the owner's
    /// elements: that is what keeps mutual transclusion finite.
    nonisolated struct Transclusion: Hashable, Sendable {
        /// Where it sits on this (the host) page.
        var frame: CGRect
        var ownerPageID: UUID
        /// The node's stroke ids, sorted, so the hash does not depend on order.
        var strokeIDs: [String]
        /// The owner's ink file and `modifiedAt`, so the host's thumbnail key
        /// changes when the owner is edited.
        var ownerStamp: String
        /// The node's name, for the placeholder.
        var title: String
    }

    var texts: [Text] = []
    /// SF Symbols, drawn yellow as on the page.
    var stickers: [Symbol] = []
    var links: [Anchor] = []
    var transclusions: [Transclusion] = []

    var isEmpty: Bool { texts.isEmpty && stickers.isEmpty && links.isEmpty && transclusions.isEmpty }

    /// Draws into the current UIKit context, in page points. Transcluded
    /// ink, then text, then stickers, then link anchors - the overlay's order.
    ///
    /// SYNCHRONOUS ON PURPOSE, and it must never call `InkRenderQueue.run`:
    /// thumbnails already call this from inside `InkRenderQueue.run` (a serial
    /// queue, so a nested run would wait on itself forever), and an export
    /// calls it on the main thread, which the render-queue gotcha allows.
    /// `regionInk` is how the owner's strokes are read; tests inject a store.
    func draw(in pageSize: CGSize,
              regionInk: (UUID, Set<UUID>) -> (strokes: [PKStroke], bounds: CGRect)? = { DrawingStore.regionInk(pageID: $0, ids: $1) }) {
        for transclusion in transclusions { Self.drawTransclusion(transclusion, regionInk: regionInk) }
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

    // MARK: Transcluded ink

    /// The region's ink as a transparent bitmap of its bounds (a little
    /// padded, so a stroke's width is not clipped), drawn under the light
    /// trait so dark mode does not turn black ink white (CLAUDE.md). Pure
    /// rendering, no queue: the caller is on `InkRenderQueue` or the main
    /// thread. `scale` is capped so a whole-page region stays under ~3000 px.
    nonisolated static func transclusionImage(strokes: [PKStroke], bounds: CGRect, scale: CGFloat) -> UIImage? {
        guard !strokes.isEmpty, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let rect = bounds.insetBy(dx: -4, dy: -4)
        let longest = max(rect.width, rect.height, 1)
        let effective = min(max(scale, 0.1), 3000 / longest)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: rect, scale: effective)
        }
        return image
    }

    private static func drawTransclusion(_ transclusion: Transclusion,
                             regionInk: (UUID, Set<UUID>) -> (strokes: [PKStroke], bounds: CGRect)?) {
        let ids = Set(transclusion.strokeIDs.compactMap(UUID.init(uuidString:)))
        if !ids.isEmpty, let ink = regionInk(transclusion.ownerPageID, ids),
           let context = UIGraphicsGetCurrentContext() {
            // Pixels per point of the target (an export is scaled up), so
            // the bitmap is as sharp as the page it lands on and no more.
            let ctm = context.ctm
            let pixelsPerPoint = hypot(ctm.a, ctm.b)
            if let image = transclusionImage(strokes: ink.strokes, bounds: ink.bounds,
                                             scale: min(max(pixelsPerPoint, 0.5), 3)) {
                image.draw(in: fitted(image.size, in: transclusion.frame))
                return
            }
        }
        drawPlaceholder(title: transclusion.title, in: transclusion.frame)
    }

    /// A dashed rounded box reading "title - ink removed": the node's ink is
    /// gone (erased, or its page not here yet). Nothing is deleted for it.
    private static func drawPlaceholder(title: String, in frame: CGRect) {
        guard frame.width > 4, frame.height > 4 else { return }
        let gray = UIColor(white: 0.45, alpha: 1)
        let box = UIBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), cornerRadius: 8)
        box.lineWidth = 1.5
        box.setLineDash([6, 4], count: 2, phase: 0)
        UIColor(white: 0.5, alpha: 0.08).setFill()
        box.fill()
        gray.setStroke()
        box.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: "\u{2039}\(title)\u{203A} \u{00B7} ink removed", attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: gray,
            .paragraphStyle: paragraph
        ])
        let inner = frame.insetBy(dx: 8, dy: 4)
        let height = label.boundingRect(with: CGSize(width: inner.width, height: inner.height),
                                        options: [.usesLineFragmentOrigin], context: nil).height
        label.draw(with: CGRect(x: inner.minX, y: inner.midY - height / 2, width: inner.width, height: height),
                   options: [.usesLineFragmentOrigin], context: nil)
    }

    /// "ink file|modifiedAt" of an owner page: any change to either changes
    /// every host's thumbnail key. "-" for a page that is not here.
    @MainActor
    static func ownerStamp(of page: Page?) -> String {
        guard let page else { return "-" }
        return [page.drawingFileRef ?? "-", page.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "-"].joined(separator: "|")
    }

    /// The transclusions on `hostID`, resolved against `links` (which must
    /// include the nodes) and the owner pages in `owners`. A node that has
    /// not arrived yet still yields one, with no strokes, so it draws the
    /// placeholder until it does.
    @MainActor
    static func resolveTransclusions(hostedOn hostID: UUID, links: [Link], owners: [UUID: Page]) -> [Transclusion] {
        links.filter { $0.sourcePageID == hostID && Links.isTransclusion($0) }.map { link in
            let node = Links.node(for: link, in: links)
            return Transclusion(
                frame: CGRect(x: link.anchorX, y: link.anchorY, width: link.anchorWidth, height: link.anchorHeight),
                ownerPageID: link.destinationPageID,
                strokeIDs: (node?.strokeIDs ?? []).sorted(),
                ownerStamp: ownerStamp(of: owners[link.destinationPageID]),
                title: node?.title ?? "Node")
        }
        .sorted { ($0.frame.minY, $0.frame.minX, $0.ownerPageID.uuidString) < ($1.frame.minY, $1.frame.minX, $1.ownerPageID.uuidString) }
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
        // Plain anchors only (kind nil). Tape (kind "tape") is never drawn into
        // an export or a thumbnail: it covers ink on screen, and the ink is the data.
        self.links = all.filter { $0.sourcePageID == page.id && $0.kind == nil }.map {
            Anchor(frame: CGRect(x: $0.anchorX, y: $0.anchorY, width: $0.anchorWidth, height: $0.anchorHeight),
                   destinationPageID: $0.destinationPageID)
        }
        // Only a page that hosts one pays for the owner lookup. A thumbnail
        // passes `links: []` and is handed its transclusions by the parent.
        let hosted = all.filter { $0.sourcePageID == page.id && Links.isTransclusion($0) }
        if !hosted.isEmpty {
            let ids = Array(Set(hosted.map(\.destinationPageID)))
            let owners = (try? page.modelContext?.fetch(FetchDescriptor<Page>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            transclusions = Self.resolveTransclusions(hostedOn: page.id, links: all,
                                               owners: Dictionary(owners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
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
    var textColorHex: String = "#000000"
    var fontDesign: String = "default"
    var isBold = false
    var isItalic = false
    /// The pages its `[[` mentions point at, so undoing a delete brings
    /// them back with the text.
    var mentions: [UUID] = []
}

extension TextBlockSnapshot {
    init(of block: TypedTextBlock, mentions: [UUID]) {
        self.init(id: block.id, content: block.content,
                  frame: CGRect(x: block.frameX, y: block.frameY, width: block.frameWidth, height: block.frameHeight),
                  fontSize: block.fontSize, textColorHex: block.textColorHex, fontDesign: block.fontDesign,
                  isBold: block.isBold, isItalic: block.isItalic, mentions: mentions)
    }
}
#endif
