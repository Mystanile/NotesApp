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
    var onMention: (UUID, UUID, String) -> Void = { _, _, _ in }
    /// A text box lost focus: its text is settled.
    var onTextCommit: (TypedTextBlock) -> Void = { _ in }
    var onSave: () -> Void
    var onRequestLinkDestinationChange: (Link) -> Void
    /// Undoable delete of a text box; without it the box deletes itself.
    var onDeleteTextBlock: ((TypedTextBlock) -> Void)? = nil
    /// Nodes on this page whose ink is gone: their badge is grey.
    var goneNodeIDs: Set<UUID> = []
    var onRenameNode: (Link) -> Void = { _ in }
    var onShowPageMap: () -> Void = {}
    /// Undoable delete; the detail view owns the undo stack.
    var onDeleteNode: (Link) -> Void = { _ in }

    private var links: [Link] {
        allLinks.filter { $0.sourcePageID == page.id }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(page.textBlocks ?? [], id: \.id) { block in
                TextBlockView(block: block, page: page, scale: scale, onMention: onMention, onTextCommit: onTextCommit, onSave: onSave,
                              onDelete: onDeleteTextBlock)
            }

            ForEach(page.stickers ?? [], id: \.id) { sticker in
                StickerElementView(sticker: sticker, scale: scale, onSave: onSave)
            }

            ForEach(links.filter { $0.kind == nil }, id: \.id) { link in
                LinkAnchorView(
                    link: link,
                    scale: scale,
                    onNavigate: onNavigateToPage,
                    onSave: onSave,
                    onRequestDestinationChange: onRequestLinkDestinationChange
                )
            }

            ForEach(links.filter(Links.isNode), id: \.id) { node in
                NodeBadgeView(node: node, isGone: goneNodeIDs.contains(node.id),
                              onRename: onRenameNode, onShowPageMap: onShowPageMap, onDelete: onDeleteNode)
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
    var page: Page
    var scale: CGFloat = 1
    /// (destination page id, this block's id, the label inserted between the brackets)
    var onMention: (UUID, UUID, String) -> Void = { _, _, _ in }
    /// The box lost focus: its text is settled (prunes mentions it no longer holds).
    var onTextCommit: (TypedTextBlock) -> Void = { _ in }
    var onSave: () -> Void
    var onDelete: ((TypedTextBlock) -> Void)? = nil

    /// Fetches pages only while a `[[` query is pending, never per cell.
    private var suggestions: [PageMentions.Suggestion] {
        guard isFocused, let q = PageMentions.pendingQuery(in: block.content) else { return [] }
        let all = (try? modelContext.fetch(FetchDescriptor<Page>())) ?? []
        let candidates: [PageMentions.Candidate] = all.compactMap { other in
            guard other.id != page.id, let notebook = other.notebook else { return nil }
            return (other.id, other.title ?? "", notebook.title, notebook.id, other.index + 1)
        }
        return PageMentions.suggestions(query: q, current: page.notebook, pages: candidates)
    }

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }

    @Environment(\.modelContext) private var modelContext
    @FocusState private var isFocused: Bool
    // Plain (Double, Double) rather than CGPoint on purpose: CGPoint's x/y
    // are CGFloat, and CGFloat doesn't implicitly convert to/from Double
    // (our model's storage type) the way Double converts INTO CGFloat.
    // Keeping this as Double avoids that mismatch entirely.
    @State private var dragOrigin: (x: Double, y: Double)?
    @State private var resizeOrigin: (width: Double, height: Double)?
    /// Where the cursor is, for ticking the checklist item it's on.
    @State private var selection: TextSelection?

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

    @ViewBuilder private var mentionList: some View {
        let hits = suggestions
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hits, id: \.pageID) { hit in
                    Button(hit.label) {
                        block.content = PageMentions.completing(block.content, with: hit.label)
                        onMention(hit.pageID, block.id, hit.label)
                        onSave()
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .alignmentGuide(.bottom) { $0[.top] }
        }
    }

    var body: some View {
        TextField("Type…", text: $block.content, selection: $selection, axis: .vertical)
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
            .overlay(alignment: .topTrailing) {
                if isFocused { moveHandle }
            }
            .overlay(alignment: .topLeading) {
                if isFocused { formattingBar }
            }
            .overlay(alignment: .bottomLeading) {
                mentionList
            }
            // .offset in the parent's topLeading ZStack, NOT .position: this
            // view's height is intrinsic (it grows as you type), while
            // block.frameHeight is a stored floor. Centring on that stale
            // height made the block drift away from where it was placed, and
            // the drift changed with every line of text. frameX/frameY are
            // top-left coordinates, which is exactly what offset applies here.
            .offset(x: block.frameX, y: block.frameY)
            // While editing, a drag in the text selects it or moves the
            // caret, as in GoodNotes and Notability; the box moves by its
            // handle instead. It used to slide the whole box.
            .gesture(dragGesture, isEnabled: !isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused { onTextCommit(block) }
            }
            .onChange(of: block.content) { old, new in
                // Return at the end of a list item starts the next one; on
                // an empty item it ends the list (`TextList`).
                if let continued = TextList.continuing(from: old, to: new) {
                    block.content = continued
                    return
                }
                onSave()
            }
            .contextMenu {
                Button(role: .destructive) { deleteBlock() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    // MARK: Chrome

    private func setContent(_ content: String) {
        guard content != block.content else { return }
        block.content = content
        onSave()
    }

    /// The cursor's offset in the text, or its end.
    private var cursorOffset: Int {
        let text = block.content
        if case .selection(let range)? = selection?.indices,
           range.lowerBound >= text.startIndex, range.lowerBound <= text.endIndex {
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        return text.count
    }

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

            barButton("list.bullet") { setContent(TextList.toggle(.bullets, in: block.content)) }
            barButton("checklist") { setContent(TextList.toggle(.checklist, in: block.content)) }
            barButton("checkmark.square", disabled: !block.content.contains(TextList.unchecked)
                      && !block.content.contains(TextList.checked)) {
                setContent(TextList.toggleCheck(atOffset: cursorOffset, in: block.content))
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

    /// Moves the box while it is being edited, when a drag in the text
    /// selects instead.
    private var moveHandle: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .scaleEffect(1 / zoom)
            .offset(x: Self.handleSize / (2 * zoom), y: -Self.handleSize / (2 * zoom))
            .contentShape(Rectangle())
            // Screen space, like the resize handle: the handle moves with
            // the box, so its own coordinates would chase the finger.
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = (x: block.frameX, y: block.frameY) }
                        let origin = dragOrigin ?? (x: block.frameX, y: block.frameY)
                        block.frameX = origin.x + Double(value.translation.width / zoom)
                        block.frameY = origin.y + Double(value.translation.height / zoom)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        onSave()
                    }
            )
            .accessibilityLabel("Move text box")
    }

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
        if let onDelete {
            onDelete(block)
        } else {
            modelContext.delete(block)
            onSave()
        }
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
    /// The sticker as it was when a pinch/rotate began; every step is
    /// applied to this, so steps don't compound.
    @State private var gestureBase: (frame: CGRect, rotation: Double)?

    private static let sideRange: ClosedRange<Double> = 20...600

    var body: some View {
        Image(systemName: sticker.assetRef.isEmpty ? "star.fill" : sticker.assetRef)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.yellow)
            .frame(width: sticker.frameWidth, height: sticker.frameHeight)
            .rotationEffect(.degrees(sticker.rotationDegrees ?? 0))
            .offset(x: sticker.frameX, y: sticker.frameY)
            .gesture(dragGesture)
            .simultaneousGesture(pinchAndRotate)
            .contextMenu {
                // A Mac has no pinch: the same, a step at a time.
                Button { resize(by: 1.25); onSave() } label: { Label("Larger", systemImage: "plus.magnifyingglass") }
                Button { resize(by: 0.8); onSave() } label: { Label("Smaller", systemImage: "minus.magnifyingglass") }
                Button {
                    sticker.rotationDegrees = ((sticker.rotationDegrees ?? 0) + 90).truncatingRemainder(dividingBy: 360)
                    onSave()
                } label: { Label("Rotate", systemImage: "rotate.right") }
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

    /// Two fingers on the sticker: pinch resizes it and twisting turns it,
    /// both about its centre.
    private var pinchAndRotate: some Gesture {
        MagnifyGesture().simultaneously(with: RotateGesture())
            .onChanged { value in
                let base = gestureBase ?? (frame: currentFrame, rotation: sticker.rotationDegrees ?? 0)
                if gestureBase == nil { gestureBase = base }
                resize(from: base.frame, by: Double(value.first?.magnification ?? 1))
                sticker.rotationDegrees = base.rotation + (value.second?.rotation.degrees ?? 0)
            }
            .onEnded { _ in
                gestureBase = nil
                onSave()
            }
    }

    private var currentFrame: CGRect {
        CGRect(x: sticker.frameX, y: sticker.frameY, width: sticker.frameWidth, height: sticker.frameHeight)
    }

    private func resize(by factor: Double) { resize(from: currentFrame, by: factor) }

    /// Scales `frame` about its centre, keeping its shape, within
    /// `sideRange`.
    private func resize(from frame: CGRect, by factor: Double) {
        let width = min(max(frame.width * factor, Self.sideRange.lowerBound), Self.sideRange.upperBound)
        let height = frame.height * width / max(frame.width, 1)
        sticker.frameX = frame.midX - width / 2
        sticker.frameY = frame.midY - height / 2
        sticker.frameWidth = width
        sticker.frameHeight = height
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

// MARK: - Node badge

/// A node's amber pill at the top-left of its region. Tap for Rename, Show
/// in Page Map and Delete Node; grey when the ink it names is gone. Drawn
/// in page space like every other element, so it scales with the page.
private struct NodeBadgeView: View {
    let node: Link
    let isGone: Bool
    var onRename: (Link) -> Void
    var onShowPageMap: () -> Void
    var onDelete: (Link) -> Void

    var body: some View {
        Menu {
            Button { onRename(node) } label: { Label("Rename", systemImage: "pencil") }
            Button { onShowPageMap() } label: { Label("Show in Page Map", systemImage: "point.3.connected.trianglepath.dotted") }
            Button(role: .destructive) { onDelete(node) } label: { Label("Delete Node", systemImage: "trash") }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: isGone ? "scribble.variable" : "scribble").imageScale(.small)
                Text(node.title ?? "Node").lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isGone ? Color.secondary : Color.black.opacity(0.82))
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(Capsule().fill(isGone ? Color.secondary.opacity(0.18) : Palette.node))
            .overlay(Capsule().strokeBorder(isGone ? Color.secondary.opacity(0.4) : Color.black.opacity(0.12),
                                            style: StrokeStyle(lineWidth: 1, dash: isGone ? [3, 3] : [])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .offset(x: node.anchorX, y: node.anchorY)
        .accessibilityLabel("Node \(node.title ?? "")")
    }
}
