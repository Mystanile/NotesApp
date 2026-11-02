import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit

/// Insert ▸ Node…: the library's nodes, one tap to pick. A thin wrapper over
/// `LinkDestinationPickerView` in nodes-only mode that fetches its own
/// notebooks and links (it is a sheet, shown once). `onPick` gets the node
/// `Link`; the caller places it with `Links.addTransclusion`.
struct NodePickerSheet: View {
    var onPick: (Link) -> Void

    @Query private var notebooks: [Notebook]
    @Query private var links: [Link]

    var body: some View {
        LinkDestinationPickerView(pages: [], notebooks: notebooks, links: links, nodesOnly: true) { _, nodeID in
            guard let nodeID, let node = links.first(where: { $0.id == nodeID && Links.isNode($0) }) else { return }
            onPick(node)
        }
    }
}

/// A node's ink on the page it is transcluded onto, drawn in page space like
/// every other element (so it scales with the canvas zoom). Drag to move, the
/// corner handle to resize (both divided by the zoom), tap for Open Source or
/// Remove. The bitmap comes from `PageBitmaps.transclusions`; when the ink is
/// gone it is a dashed box reading "title - ink removed", and nothing is
/// deleted because of that.
///
/// It re-keys on the owner page's `modifiedAt` and ink file (a scoped
/// `@Query` for that one page), so editing the owner, here or after a pull,
/// refreshes the bitmap. It never reloads the canvas.
struct TransclusionElementView: View {
    let link: Link
    var scale: CGFloat = 1
    var onOpenSource: (UUID) -> Void = { _ in }
    /// Remove; the detail view makes it undoable.
    var onRemove: (Link) -> Void = { _ in }

    @Query private var nodes: [Link]
    @Query private var owners: [Page]
    @Environment(\.modelContext) private var modelContext

    /// nil until the owner's record has been looked at.
    @State private var inkIsGone: Bool?
    /// The frame while a drag is under way; written to the link once, on end.
    @State private var liveFrame: CGRect?
    @State private var gestureBase: CGRect?
    @State private var showMenu = false

    private var store: BitmapStore<TransclusionRequest> { PageBitmaps.transclusions }
    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }
    private static let handleSize: CGFloat = 22
    private static let minimumSide: CGFloat = 40
    private static let maximumSide: CGFloat = 2000

    init(link: Link, scale: CGFloat = 1, onOpenSource: @escaping (UUID) -> Void = { _ in },
         onRemove: @escaping (Link) -> Void = { _ in }) {
        self.link = link
        self.scale = scale
        self.onOpenSource = onOpenSource
        self.onRemove = onRemove
        let nodeKey = UUID(uuidString: link.destinationID ?? "") ?? UUID()
        let ownerID = link.destinationPageID
        _nodes = Query(filter: #Predicate<Link> { $0.id == nodeKey })
        _owners = Query(filter: #Predicate<Page> { $0.id == ownerID })
    }

    private var node: Link? { nodes.first { Links.isNode($0) } }
    private var title: String { node?.title ?? "Node" }

    private var storedFrame: CGRect {
        CGRect(x: link.anchorX, y: link.anchorY, width: link.anchorWidth, height: link.anchorHeight)
    }

    private var request: TransclusionRequest {
        let owner = owners.first
        return TransclusionRequest(ownerPageID: link.destinationPageID,
                                   ownerModifiedAt: owner?.modifiedAt,
                                   ownerDrawingFileRef: owner?.drawingFileRef,
                                   strokeIDs: (node?.strokeIDs ?? []).sorted())
    }

    private struct LoadID: Equatable {
        var request: TransclusionRequest
        var generation: Int
    }

    var body: some View {
        let frame = liveFrame ?? storedFrame
        let current = request
        ZStack {
            if let image = store.image(for: current) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if inkIsGone == true || current.strokeIDs.isEmpty {
                placeholder
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomTrailing) { resizeHandle(from: frame) }
        .offset(x: frame.minX, y: frame.minY)
        .gesture(dragGesture)
        .onTapGesture { showMenu = true }
        .contextMenu {
            Button { onOpenSource(link.destinationPageID) } label: { Label("Open Source", systemImage: "arrow.up.right.square") }
            Button { resize(by: 1.25) } label: { Label("Larger", systemImage: "plus.magnifyingglass") }
            Button { resize(by: 0.8) } label: { Label("Smaller", systemImage: "minus.magnifyingglass") }
            Button(role: .destructive) { onRemove(link) } label: { Label("Remove", systemImage: "trash") }
        }
        .confirmationDialog(title, isPresented: $showMenu, titleVisibility: .visible) {
            Button("Open Source") { onOpenSource(link.destinationPageID) }
            Button("Remove", role: .destructive) { onRemove(link) }
        }
        .task(id: LoadID(request: current, generation: store.generation)) {
            guard !current.strokeIDs.isEmpty else { inkIsGone = true; return }
            store.request(current)
            // Is the ink there at all? Decides placeholder over blank while
            // loading. Off the main thread (`NodeInk.goneDetached`).
            let probe = NodeProbe(id: link.id, pageID: current.ownerPageID, strokeIDs: current.strokeIDs)
            let gone = await NodeInk.goneDetached([probe]).value
            if !Task.isCancelled { inkIsGone = !gone.isEmpty }
        }
        .accessibilityLabel("Transcluded \(title)")
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .overlay {
                Text("\u{2039}\(title)\u{203A} \u{00B7} ink removed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(Space.s)
            }
    }

    // MARK: Move and resize

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = gestureBase ?? storedFrame
                if gestureBase == nil { gestureBase = base }
                liveFrame = base.offsetBy(dx: value.translation.width / zoom, dy: value.translation.height / zoom)
            }
            .onEnded { _ in
                commit()
            }
    }

    private func resizeHandle(from frame: CGRect) -> some View {
        Circle()
            .fill(Color.accentColor.opacity(0.85))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .scaleEffect(1 / zoom)
            .offset(x: Self.handleSize / (2 * zoom), y: Self.handleSize / (2 * zoom))
            .contentShape(Rectangle())
            // Screen space, like the text box's handle: the handle moves
            // with the frame, so its own coordinates would chase the finger.
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let base = gestureBase ?? storedFrame
                        if gestureBase == nil { gestureBase = base }
                        liveFrame = Self.scaled(base, toWidth: base.width + value.translation.width / zoom)
                    }
                    .onEnded { _ in commit() }
            )
            .accessibilityLabel("Resize")
    }

    /// `frame` at a new width, same top-left, same shape.
    private static func scaled(_ frame: CGRect, toWidth width: CGFloat) -> CGRect {
        let aspect = frame.height / max(frame.width, 1)
        var w = min(max(width, minimumSide), maximumSide)
        if w * aspect < minimumSide { w = minimumSide / max(aspect, 0.01) }
        return CGRect(x: frame.minX, y: frame.minY, width: w, height: w * aspect)
    }

    private func resize(by factor: CGFloat) {
        let base = storedFrame
        let grown = Self.scaled(base, toWidth: base.width * factor)
        // About the centre, like a sticker's step.
        let moved = grown.offsetBy(dx: (base.width - grown.width) / 2, dy: (base.height - grown.height) / 2)
        Links.moveTransclusion(link, to: moved, in: modelContext)
    }

    private func commit() {
        if let frame = liveFrame, frame != storedFrame {
            Links.moveTransclusion(link, to: frame, in: modelContext)
        }
        liveFrame = nil
        gestureBase = nil
    }
}
#endif
