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
        }
        .coordinateSpace(.named(Self.space))
    }
}

/// The controls that appear while ink is selected. Styled like
/// `ImageAdjustToolbar` so the two read as the same family of UI.
struct InkSelectionToolbar: View {
    var canPaste: Bool
    var onCut: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onRecolor: (Color) -> Void = { _ in }
    var onCopyAsImage: () -> Void = {}
    var onConvertToText: () -> Void = {}
    /// Nil hides the button (the whiteboard draws no link anchors yet).
    var onLinkTo: (() -> Void)? = nil
    var onDone: () -> Void

    private let colors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .brown]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            compact
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var colourButtons: some View {
        ForEach(colors, id: \.self) { color in
            Button { onRecolor(color) } label: {
                Label { Text(color.description.capitalized) } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(color)
                }
            }
        }
    }

    private var full: some View {
        HStack(spacing: 4) {
            iconButton("scissors", help: "Cut", action: onCut)
            iconButton("doc.on.doc", help: "Copy", action: onCopy)
            iconButton("doc.on.clipboard", help: "Paste", action: onPaste)
                .disabled(!canPaste)
                .opacity(canPaste ? 1 : 0.4)
            iconButton("plus.square.on.square", help: "Duplicate", action: onDuplicate)
            Divider().frame(height: 24)
            Menu { colourButtons } label: {
                Image(systemName: "paintpalette").font(.system(size: 17)).frame(width: 36, height: 34)
            }
            .help("Colour")
            iconButton("photo", help: "Copy as Image", action: onCopyAsImage)
            iconButton("character.textbox", help: "Convert to Text", action: onConvertToText)
            if let onLinkTo {
                iconButton("link", help: "Link This To…", action: onLinkTo)
            }
            Divider().frame(height: 24)
            iconButton("trash", help: "Delete", isDestructive: true, action: onDelete)
            Divider().frame(height: 24)
            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// For windows under ~460 pt: the rarely used actions go in a menu.
    private var compact: some View {
        HStack(spacing: 4) {
            iconButton("scissors", help: "Cut", action: onCut)
            iconButton("doc.on.doc", help: "Copy", action: onCopy)
            iconButton("trash", help: "Delete", isDestructive: true, action: onDelete)
            Menu {
                Button { onPaste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .disabled(!canPaste)
                Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Menu { colourButtons } label: { Label("Colour", systemImage: "paintpalette") }
                Button { onCopyAsImage() } label: { Label("Copy as Image", systemImage: "photo") }
                Button { onConvertToText() } label: { Label("Convert to Text", systemImage: "character.textbox") }
                if let onLinkTo {
                    Button { onLinkTo() } label: { Label("Link This To…", systemImage: "link") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17)).frame(width: 36, height: 34)
            }
            .help("More")
            .accessibilityLabel("More")
            Divider().frame(height: 24)
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color.accentColor)
            }
            .help("Done")
            .accessibilityLabel("Done")
        }
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
