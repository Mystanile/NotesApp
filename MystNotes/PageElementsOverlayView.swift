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
                TextBlockView(block: block, onSave: onSave)
            }

            ForEach(page.stickers ?? [], id: \.id) { sticker in
                StickerElementView(sticker: sticker, onSave: onSave)
            }

            ForEach(links, id: \.id) { link in
                LinkAnchorView(
                    link: link,
                    onNavigate: onNavigateToPage,
                    onSave: onSave,
                    onRequestDestinationChange: onRequestLinkDestinationChange
                )
            }
        }
    }
}

// MARK: - Typed text block

private struct TextBlockView: View {
    @Bindable var block: TypedTextBlock
    var onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
    // Plain (Double, Double) rather than CGPoint on purpose: CGPoint's x/y
    // are CGFloat, and CGFloat doesn't implicitly convert to/from Double
    // (our model's storage type) the way Double converts INTO CGFloat.
    // Keeping this as Double avoids that mismatch entirely.
    @State private var dragOrigin: (x: Double, y: Double)?

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
        VStack(alignment: .trailing, spacing: 2) {
            ColorPicker("Text color", selection: textColorBinding)
                .labelsHidden()
                .frame(width: 20, height: 20)

            TextField("Type…", text: $block.content, axis: .vertical)
                .font(.body)
                .foregroundStyle(Color(hex: block.textColorHex))
        }
        .padding(6)
        .frame(width: block.frameWidth, alignment: .topLeading)
        .background(.white.opacity(0.85))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.3)))
        .position(x: block.frameX + block.frameWidth / 2, y: block.frameY + block.frameHeight / 2)
        .gesture(dragGesture)
        .onChange(of: block.content) { _, _ in onSave() }
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(block)
                onSave()
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
                block.frameX = origin.x + Double(value.translation.width)
                block.frameY = origin.y + Double(value.translation.height)
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
    var onSave: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var dragOrigin: (x: Double, y: Double)?

    var body: some View {
        Image(systemName: sticker.assetRef.isEmpty ? "star.fill" : sticker.assetRef)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.yellow)
            .frame(width: sticker.frameWidth, height: sticker.frameHeight)
            .position(x: sticker.frameX + sticker.frameWidth / 2, y: sticker.frameY + sticker.frameHeight / 2)
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
                sticker.frameX = origin.x + Double(value.translation.width)
                sticker.frameY = origin.y + Double(value.translation.height)
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
    var onNavigate: (UUID) -> Void
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
            .position(x: link.anchorX + link.anchorWidth / 2, y: link.anchorY + link.anchorHeight / 2)
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
                link.anchorX = origin.x + Double(value.translation.width)
                link.anchorY = origin.y + Double(value.translation.height)
            }
            .onEnded { _ in
                dragOrigin = nil
                onSave()
            }
    }
}
