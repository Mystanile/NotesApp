import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)

/// What the lasso shows: the loop as it's drawn, and the selection's box
/// once there is one. Drawn in page space inside a `PageViewportLayer`,
/// like the shape preview, and never hit-tested - the gestures live on the
/// canvas host (`InkSelectionController`), where they can share touches
/// with the Pencil.
struct InkSelectionOverlay: View {
    var display: InkSelectionDisplay
    /// The canvas zoom the overlay is drawn through, so line widths and
    /// dashes stay the same size on screen at any magnification.
    var scale: CGFloat

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if display.lasso.count > 1 {
                Path { path in path.addLines(display.lasso) }
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 1.5 / zoom, lineCap: .round, lineJoin: .round,
                                               dash: [6 / zoom, 4 / zoom]))
            }
            if let corners = display.corners, corners.count == 4 {
                let box = Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                box.fill(Color.accentColor.opacity(0.08))
                box.stroke(Color.accentColor,
                           style: StrokeStyle(lineWidth: 1.5 / zoom, lineJoin: .round, dash: [6 / zoom, 4 / zoom]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Corner handles on the selection box: drag one to resize the ink about
/// its centre. A Mac has no pinch, and on an iPad it's a finger's way to
/// do the same. Drawn in page space, like the box; the drag is measured
/// in page points through the named space, whatever the zoom.
struct InkSelectionHandles: View {
    var corners: [CGPoint]
    var scale: CGFloat
    var controller: InkSelectionController

    @State private var lastDistance: CGFloat?

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }
    private static let space = "inkSelectionPage"

    var body: some View {
        let center = InkSelection.center(of: corners)
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(corners.indices, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5 / zoom))
                    .frame(width: 14 / zoom, height: 14 / zoom)
                    .contentShape(Circle().inset(by: -12 / zoom))
                    .position(corners[index])
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                            .onChanged { value in
                                let distance = hypot(value.location.x - center.x, value.location.y - center.y)
                                guard let last = lastDistance else {
                                    controller.beginGesture()
                                    lastDistance = max(hypot(value.startLocation.x - center.x,
                                                             value.startLocation.y - center.y), 1)
                                    return
                                }
                                guard distance > 4 else { return }
                                controller.scale(by: distance / last)
                                lastDistance = distance
                            }
                            .onEnded { _ in
                                lastDistance = nil
                                controller.endGesture()
                            }
                    )
            }
            if corners.count == 4 {
                // Re-presents the edit menu. A 44 pt target, set just
                // outside the top-right corner so the resize handle there
                // keeps its own.
                let anchor = corners[1]
                Button { controller.presentMenu() } label: {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 28 / zoom, height: 28 / zoom)
                        .overlay {
                            HStack(spacing: 3 / zoom) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle().fill(Color.white.opacity(0.95)).frame(width: 4 / zoom, height: 4 / zoom)
                                }
                            }
                        }
                        .frame(width: Metrics.minHitTarget / zoom, height: Metrics.minHitTarget / zoom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: anchor.x + 30 / zoom, y: anchor.y - 30 / zoom)
                .accessibilityLabel("Selection actions")
            }
        }
        .coordinateSpace(.named(Self.space))
    }
}

/// What the lasso's edit menu offers, in order. The list is a pure function
/// of the state so a test can pin it; `SelectionMenu.menu` turns it into a
/// `UIMenu`.
nonisolated enum SelectionMenuItem: Equatable, Sendable {
    case cut, copy, paste, duplicate, delete, colour, copyAsImage, convertToText, linkTo, makeNode, tape

    var title: String {
        switch self {
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .duplicate: return "Duplicate"
        case .delete: return "Delete"
        case .colour: return "Colour"
        case .copyAsImage: return "Copy as Image"
        case .convertToText: return "Convert to Text"
        case .linkTo: return "Link This To\u{2026}"
        case .makeNode: return "Make Node"
        case .tape: return "Tape"
        }
    }

    var systemImage: String {
        switch self {
        case .cut: return "scissors"
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .duplicate: return "plus.square.on.square"
        case .delete: return "trash"
        case .colour: return "paintpalette"
        case .copyAsImage: return "photo"
        case .convertToText: return "character.textbox"
        case .linkTo: return "link"
        case .makeNode: return "scribble"
        case .tape: return "rectangle.on.rectangle"
        }
    }
}

nonisolated enum SelectionMenu {
    /// - `hasSelection`: ink is selected. Without it the only thing worth
    ///   offering is Paste (a right-click on empty page), and only if the
    ///   pasteboard holds ink.
    /// - `pasteboardHasInk`: Paste is left out rather than greyed, so the
    ///   menu stays short.
    /// - `isPaged`: a paged page, which can hold links and nodes; the
    ///   whiteboard has neither.
    /// - `hasTape`: the tape action is wired up.
    static func items(hasSelection: Bool, pasteboardHasInk: Bool, isPaged: Bool,
                      hasTape: Bool = false) -> [SelectionMenuItem] {
        guard hasSelection else { return pasteboardHasInk ? [.paste] : [] }
        var items: [SelectionMenuItem] = [.cut, .copy]
        if pasteboardHasInk { items.append(.paste) }
        items += [.duplicate, .delete, .colour, .copyAsImage, .convertToText]
        if isPaged { items += [.linkTo, .makeNode] }
        if hasTape { items.append(.tape) }
        return items
    }
}

/// The lasso menu's custom actions, handed in by the screen that owns the
/// page (the same callbacks the old floating toolbar received). Cut, Copy,
/// Paste, Duplicate and Delete are not here: those are the host's and the
/// controller's own. A nil closure leaves its item out.
struct SelectionMenuActions {
    var onRecolor: ((UIColor) -> Void)?
    var onCopyAsImage: (() -> Void)?
    var onConvertToText: (() -> Void)?
    /// Nil on the whiteboard (no link anchors yet).
    var onLinkTo: (() -> Void)?
    /// Nil on the whiteboard (no nodes).
    var onMakeNode: (() -> Void)?
    /// Left nil for now; another task adds Tape.
    var onTape: (() -> Void)?
}

extension SelectionMenu {
    /// The menu for the current selection. Cut, Copy and Paste go through
    /// the host's responder methods, so the keyboard, the system Edit menu
    /// and this menu share one implementation.
    @MainActor static func menu(for controller: InkSelectionController, host: CanvasHostView) -> UIMenu? {
        let actions = controller.menuActions
        let entries = Self.items(hasSelection: controller.hasSelection,
                                 pasteboardHasInk: InkSelectionController.pasteboardHasInk,
                                 isPaged: actions.onMakeNode != nil || actions.onLinkTo != nil,
                                 hasTape: actions.onTape != nil)
        var elements: [UIMenuElement] = []
        for item in entries {
            let image = UIImage(systemName: item.systemImage)
            switch item {
            case .cut:
                elements.append(UIAction(title: item.title, image: image) { [weak host] _ in host?.cut(nil) })
            case .copy:
                elements.append(UIAction(title: item.title, image: image) { [weak host] _ in host?.copy(nil) })
            case .paste:
                elements.append(UIAction(title: item.title, image: image) { [weak host] _ in host?.paste(nil) })
            case .duplicate:
                elements.append(UIAction(title: item.title, image: image) { [weak controller] _ in controller?.duplicate() })
            case .delete:
                elements.append(UIAction(title: item.title, image: image, attributes: .destructive) { [weak controller] _ in
                    controller?.delete()
                })
            case .colour:
                if let onRecolor = actions.onRecolor { elements.append(colourMenu(onRecolor)) }
            case .copyAsImage:
                if let run = actions.onCopyAsImage { elements.append(UIAction(title: item.title, image: image) { _ in run() }) }
            case .convertToText:
                if let run = actions.onConvertToText { elements.append(UIAction(title: item.title, image: image) { _ in run() }) }
            case .linkTo:
                if let run = actions.onLinkTo { elements.append(UIAction(title: item.title, image: image) { _ in run() }) }
            case .makeNode:
                if let run = actions.onMakeNode { elements.append(UIAction(title: item.title, image: image) { _ in run() }) }
            case .tape:
                if let run = actions.onTape { elements.append(UIAction(title: item.title, image: image) { _ in run() }) }
            }
        }
        return elements.isEmpty ? nil : UIMenu(children: elements)
    }

    /// The ten swatches, then the colours used lately - the same palette
    /// and the same `recentInkColors` the drawing toolbar keeps.
    @MainActor static func colourMenu(_ onRecolor: @escaping (UIColor) -> Void) -> UIMenu {
        func action(hex: String, name: String) -> UIAction {
            let color = Color(hex: hex).fixedUIColor
            let dot = UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
            return UIAction(title: name, image: dot) { _ in onRecolor(color) }
        }
        var groups: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: InkPalette.swatches.map { action(hex: $0.hex, name: $0.name) })
        ]
        let recents = InkPalette.decodeRecents(UserDefaults.standard.string(forKey: InkPalette.recentsKey) ?? "")
        if !recents.isEmpty {
            groups.append(UIMenu(title: "Recent", options: .displayInline,
                                 children: recents.map { action(hex: $0, name: $0) }))
        }
        return UIMenu(title: "Colour", image: UIImage(systemName: "paintpalette"), children: groups)
    }
}
#endif
