import SwiftUI
import SwiftData

/// Renders every typed-text block, sticker, and link anchor for the current
/// page as positioned, draggable overlay views on top of the canvas.
/// Existing elements are always interactive (drag to move, tap to edit/
/// navigate) regardless of which drawing tool is active — only creating a
/// NEW element requires a toolbar button, not a special "mode," which is
/// what keeps this from fighting with PencilKit for touch input.
struct PageElementsOverlayView: View {
    @Bindable var page: Page

    /// The canvas zoom these elements are being drawn through. Element
    /// frames are page coordinates while a `DragGesture` reports screen
    /// points, so drags are divided by this - otherwise a sticker moves
    /// twice as far as your finger the moment you pinch in.
    var scale: CGFloat = 1

    @Query private var allLinks: [Link]

    var onNavigateToPage: (UUID) -> Void
    var onSave: () -> Void
    var onRequestLinkDestinationChange: (Link) -> Void

    private var links: [Link] {
        allLinks.filter { $0.sourcePageID == page.id }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(page.textBlocks ?? [], id: \.id) { block in
                TextBlockView(block: block, scale: scale, onSave: onSave)
            }

            ForEach(page.stickers ?? [], id: \.id) { sticker in
                StickerElementView(sticker: sticker, scale: scale, onSave: onSave)
            }

            ForEach(links, id: \.id) { link in
                LinkAnchorView(
                    link: link,
                    scale: scale,
                    onNavigate: onNavigateToPage,
                    onSave: onSave,
                    onRequestDestinationChange: onRequestLinkDestinationChange
                )
            }
        }
    }
}

// MARK: - Typed text block

/// A typed text box. Tap into it to edit; while it has focus a formatting
/// bar sits above it (font, size, bold, italic, colour, delete, done) and
/// a handle at the bottom-right corner resizes the box.
///
/// The bar and the handle are chrome, so they're drawn at screen size:
/// this view lives inside `PageViewportLayer`, which scales everything by
/// the canvas zoom, and the two are counter-scaled by `1/zoom` so a pinch
/// changes the text on the page but never the controls around it.
private struct TextBlockView: View {
    @Bindable var block: TypedTextBlock
    var scale: CGFloat = 1
    var onSave: () -> Void

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }

    @Environment(\.modelContext) private var modelContext
    @FocusState private var isFocused: Bool
    // Plain (Double, Double) rather than CGPoint on purpose: CGPoint's x/y
    // are CGFloat, and CGFloat doesn't implicitly convert to/from Double
    // (our model's storage type) the way Double converts INTO CGFloat.
    // Keeping this as Double avoids that mismatch entirely.
    @State private var dragOrigin: (x: Double, y: Double)?
    @State private var resizeOrigin: (width: Double, height: Double)?

    private static let minimumWidth: Double = 80
    private static let minimumHeight: Double = 32
    private static let fontSizeRange: ClosedRange<Double> = 8...96
    private static let fontSizeStep: Double = 2
    private static let handleSize: CGFloat = 22

    private var font: Font {
        let design: Font.Design
        switch TextBlockFontDesign.from(block.fontDesign) {
        case .default: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .monospaced: design = .monospaced
        }
        let base = Font.system(size: block.fontSize, weight: block.isBold ? .bold : .regular, design: design)
        return block.isItalic ? base.italic() : base
    }

    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: block.textColorHex) },
            set: { newColor in
                block.textColorHex = newColor.toHex()
                onSave()
            }
        )
    }

    var body: some View {
        TextField("Type…", text: $block.content, axis: .vertical)
            .font(font)
            .foregroundStyle(Color(hex: block.textColorHex))
            .focused($isFocused)
            .padding(6)
            // Width is the wrap width; height is a floor the text can grow
            // past, so a box never clips what's typed into it.
            .frame(width: block.frameWidth, alignment: .topLeading)
            .frame(minHeight: block.frameHeight, alignment: .topLeading)
            .background(.white.opacity(isFocused ? 0.95 : 0.85))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : Color.gray.opacity(0.3),
                                  lineWidth: isFocused ? 1.5 / zoom : 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if isFocused { resizeHandle }
            }
            .overlay(alignment: .topLeading) {
                if isFocused { formattingBar }
            }
            // .offset in the parent's topLeading ZStack, NOT .position: this
            // view's height is intrinsic (it grows as you type), while
            // block.frameHeight is a stored floor. Centring on that stale
            // height made the block drift away from where it was placed, and
            // the drift changed with every line of text. frameX/frameY are
            // top-left coordinates, which is exactly what offset applies here.
            .offset(x: block.frameX, y: block.frameY)
            .gesture(dragGesture)
            .onChange(of: block.content) { _, _ in onSave() }
            .contextMenu {
                Button(role: .destructive) { deleteBlock() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: Chrome

    /// Sits just above the box's top edge, left-aligned with it. Drawn at
    /// screen size regardless of zoom (see the type comment).
    private var formattingBar: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(TextBlockFontDesign.allCases) { design in
                    Button {
                        block.fontDesign = design.rawValue
                        onSave()
                    } label: {
                        if TextBlockFontDesign.from(block.fontDesign) == design {
                            Label(design.label, systemImage: "checkmark")
                        } else {
                            Text(design.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(TextBlockFontDesign.from(block.fontDesign).label)
                        .font(.footnote)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 28)
            }

            Divider().frame(height: 18)

            barButton("minus", disabled: block.fontSize <= Self.fontSizeRange.lowerBound) {
                setFontSize(block.fontSize - Self.fontSizeStep)
            }
            Text("\(Int(block.fontSize.rounded()))")
                .font(.footnote.monospacedDigit())
                .frame(minWidth: 24)
            barButton("plus", disabled: block.fontSize >= Self.fontSizeRange.upperBound) {
                setFontSize(block.fontSize + Self.fontSizeStep)
            }

            Divider().frame(height: 18)

            barButton("bold", isOn: block.isBold) {
                block.isBold.toggle()
                onSave()
            }
            barButton("italic", isOn: block.isItalic) {
                block.isItalic.toggle()
                onSave()
            }

            ColorPicker("Text color", selection: textColorBinding)
                .labelsHidden()
                .frame(width: 28, height: 28)

            Divider().frame(height: 18)

            barButton("trash") { deleteBlock() }
            barButton("keyboard.chevron.compact.down") { isFocused = false }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.barHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .fixedSize()
        // Counter the layer's zoom so the bar is always screen-sized. The
        // anchor keeps the visual bottom-left on the layout's bottom-left,
        // so the offset below only has to lift the *layout* frame clear of
        // the box: its own (unscaled) height plus an 8-screen-point gap.
        .scaleEffect(1 / zoom, anchor: .bottomLeading)
        .offset(y: -(Self.barHeight + 8 / zoom))
    }

    private static let barHeight: CGFloat = 34

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .scaleEffect(1 / zoom)
            // Straddle the corner so it reads as a grab point on the edge.
            .offset(x: Self.handleSize / (2 * zoom), y: Self.handleSize / (2 * zoom))
            .contentShape(Rectangle())
            // Screen-space translation, like the drag: the box is in page
            // points, so the delta is divided by the zoom.
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if resizeOrigin == nil {
                            resizeOrigin = (width: block.frameWidth, height: block.frameHeight)
                        }
                        let origin = resizeOrigin ?? (width: block.frameWidth, height: block.frameHeight)
                        block.frameWidth = max(Self.minimumWidth, origin.width + Double(value.translation.width / zoom))
                        block.frameHeight = max(Self.minimumHeight, origin.height + Double(value.translation.height / zoom))
                    }
                    .onEnded { _ in
                        resizeOrigin = nil
                        onSave()
                    }
            )
    }

    @ViewBuilder
    private func barButton(_ systemImage: String, isOn: Bool = false, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func setFontSize(_ size: Double) {
        block.fontSize = min(max(size, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        onSave()
    }

    private func deleteBlock() {
        isFocused = false
        modelContext.delete(block)
        onSave()
    }

    // NOTE: DragGesture.translation is CUMULATIVE from the start of the
    // gesture, not a per-frame delta — so we capture the block's starting
    // position once per drag and always compute new position as
    // origin + translation, rather than repeatedly adding translation
    // (which would compound into runaway movement).
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (x: block.frameX, y: block.frameY)
                }
                let origin = dragOrigin ?? (x: block.frameX, y: block.frameY)
                block.frameX = origin.x + Double(value.translation.width / zoom)
                block.frameY = origin.y + Double(value.translation.height / zoom)
            }
            .onEnded { _ in
                dragOrigin = nil
                onSave()
            }
    }
}

// MARK: - Sticker

private struct StickerElementView: View {
    @Bindable var sticker: Sticker
    var scale: CGFloat = 1
    var onSave: () -> Void

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }

    @Environment(\.modelContext) private var modelContext
    @State private var dragOrigin: (x: Double, y: Double)?

    var body: some View {
        Image(systemName: sticker.assetRef.isEmpty ? "star.fill" : sticker.assetRef)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.yellow)
            .frame(width: sticker.frameWidth, height: sticker.frameHeight)
            .offset(x: sticker.frameX, y: sticker.frameY)
            .gesture(dragGesture)
            .contextMenu {
                Button(role: .destructive) {
                    modelContext.delete(sticker)
                    onSave()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (x: sticker.frameX, y: sticker.frameY)
                }
                let origin = dragOrigin ?? (x: sticker.frameX, y: sticker.frameY)
                sticker.frameX = origin.x + Double(value.translation.width / zoom)
                sticker.frameY = origin.y + Double(value.translation.height / zoom)
            }
            .onEnded { _ in
                dragOrigin = nil
                onSave()
            }
    }
}

// MARK: - Link anchor

private struct LinkAnchorView: View {
    @Bindable var link: Link
    var scale: CGFloat = 1
    var onNavigate: (UUID) -> Void

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }
    var onSave: () -> Void
    var onRequestDestinationChange: (Link) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var dragOrigin: (x: Double, y: Double)?

    var body: some View {
        Image(systemName: "link.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.blue)
            .background(Circle().fill(.white))
            .frame(width: link.anchorWidth, height: link.anchorHeight)
            .offset(x: link.anchorX, y: link.anchorY)
            .onTapGesture {
                onNavigate(link.destinationPageID)
            }
            .gesture(dragGesture)
            .contextMenu {
                Button {
                    onRequestDestinationChange(link)
                } label: {
                    Label("Change Destination", systemImage: "arrow.triangle.branch")
                }
                Button(role: .destructive) {
                    modelContext.delete(link)
                    onSave()
                } label: {
                    Label("Delete Link", systemImage: "trash")
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = (x: link.anchorX, y: link.anchorY)
                }
                let origin = dragOrigin ?? (x: link.anchorX, y: link.anchorY)
                link.anchorX = origin.x + Double(value.translation.width / zoom)
                link.anchorY = origin.y + Double(value.translation.height / zoom)
            }
            .onEnded { _ in
                dragOrigin = nil
                onSave()
            }
    }
}
