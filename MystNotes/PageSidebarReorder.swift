import SwiftUI

// Page sidebar reordering.
//
// Design (decided without an iPad to try it on - see the report):
//  * The system drag-and-drop (`.draggable` / `.dropDestination`) is gone. Its
//    long-press is suspected of leaving the touch system stuck until a Pencil
//    touch, and it gives no control over the lift, the gap or auto-scroll.
//  * REORDER MODE is the guaranteed path: a "Reorder" button above the list
//    shows a grip (line.3.horizontal) on every cell, and a drag that starts on
//    a grip lifts the page immediately - no long press.
//  * A long-press lift on the thumbnail itself is NOT implemented: it would
//    share the long press with `.contextMenu`, and SwiftUI offers no reliable
//    way to let both coexist. The context menu keeps the long press.
//  * One gesture on the whole list (not one per cell), because a LazyVStack
//    drops cells that scroll away and a gesture on a dropped cell dies
//    mid-drag during auto-scroll. The lifted page is drawn as an overlay for
//    the same reason; its slot in the stack is a hollow accent outline.
//  * Drop commits through `movePage(withID:to:)`; nothing here touches the
//    model. Cancel (gesture cancelled, mode switched off) changes nothing.

// MARK: - Pure maths

nonisolated enum SidebarReorderModel {
    /// Space between two rows. The gap is a real view (the hover "+").
    static let rowGap: CGFloat = 14

    static func rowStride(rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        max(rowHeight + spacing, 1)
    }

    /// Where a row dragged `dragY` points down from its slot would land: it
    /// passes into the next slot once its centre crosses the midpoint between
    /// them. Rows are treated as one stride tall (the dragged row's own).
    static func targetIndex(dragY: CGFloat, originIndex: Int, rowHeight: CGFloat,
                            spacing: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let origin = min(max(originIndex, 0), count - 1)
        guard dragY.isFinite else { return origin }
        let steps = (dragY / rowStride(rowHeight: rowHeight, spacing: spacing)).rounded()
        let bounded = min(max(steps, -CGFloat(count)), CGFloat(count))
        return min(max(origin + Int(bounded), 0), count - 1)
    }

    /// How far a row sits from its own slot while `origin` hovers over
    /// `target`: neighbours between the two slide one stride toward the slot
    /// the dragged row left. The dragged row itself is 0 (it is drawn lifted).
    static func offset(forRow row: Int, origin: Int, target: Int, rowStride: CGFloat) -> CGFloat {
        if row == origin { return 0 }
        if origin < target, row > origin, row <= target { return -rowStride }
        if target < origin, row >= target, row < origin { return rowStride }
        return 0
    }

    /// Where the hollow slot (the dragged row's placeholder) sits.
    static func slotOffset(origin: Int, target: Int, rowStride: CGFloat) -> CGFloat {
        CGFloat(target - origin) * rowStride
    }

    /// Points to scroll this tick when the pointer is within `edge` of the
    /// top (negative) or bottom (positive) of the viewport; faster the closer.
    static func edgeScrollStep(pointerY: CGFloat, viewportHeight: CGFloat,
                               edge: CGFloat, maxStep: CGFloat) -> CGFloat {
        guard edge > 0, viewportHeight > 0, pointerY.isFinite else { return 0 }
        if pointerY < edge {
            return -maxStep * min(1, (edge - pointerY) / edge)
        }
        if pointerY > viewportHeight - edge {
            return maxStep * min(1, (pointerY - (viewportHeight - edge)) / edge)
        }
        return 0
    }

    static func clampedOffset(_ proposed: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(proposed, lower), Swift.max(lower, upper))
    }
}

/// One reorder in progress.
nonisolated struct SidebarDragState: Equatable, Sendable {
    var pageID: UUID
    var originIndex: Int
    var count: Int
    var rowHeight: CGFloat
    var spacing: CGFloat = SidebarReorderModel.rowGap
    /// The finger's travel in the viewport since the grab.
    var translation: CGFloat = 0
    var pointerY: CGFloat = 0
    var startScrollOffset: CGFloat = 0
    var scrollOffset: CGFloat = 0
    /// Where the row's top was in the viewport at the grab.
    var startViewportTop: CGFloat = 0

    var rowStride: CGFloat { SidebarReorderModel.rowStride(rowHeight: rowHeight, spacing: spacing) }
    /// Travel in content space: the finger's plus whatever auto-scroll added.
    var contentDelta: CGFloat { translation + scrollOffset - startScrollOffset }
    var targetIndex: Int {
        SidebarReorderModel.targetIndex(dragY: contentDelta, originIndex: originIndex,
                                        rowHeight: rowHeight, spacing: spacing, count: count)
    }
    var liftedViewportTop: CGFloat { startViewportTop + translation }
}

nonisolated struct SidebarScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var insetTop: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
}

nonisolated enum SidebarSpace {
    static let content = "pageSidebarContent"
    static let viewport = "pageSidebarViewport"
}

/// Row frames in content space, kept out of observation: they change on
/// every layout and must not re-run the cells.
final class SidebarFrameBox {
    var frames: [UUID: CGRect] = [:]
}

// MARK: - The list

struct PageSidebarReorderList<Cell: View, Footer: View>: View {
    let pages: [Page]
    let currentIndex: Int
    let onMove: (UUID, Int) -> Void
    let onInsertAfter: (Page) -> Void
    let scrollToCurrent: (ScrollViewProxy) -> Void
    let cell: (Int, Page, Bool) -> Cell
    let footer: Footer

    init(pages: [Page], currentIndex: Int,
         onMove: @escaping (UUID, Int) -> Void,
         onInsertAfter: @escaping (Page) -> Void,
         scrollToCurrent: @escaping (ScrollViewProxy) -> Void,
         @ViewBuilder cell: @escaping (Int, Page, Bool) -> Cell,
         @ViewBuilder footer: () -> Footer) {
        self.pages = pages
        self.currentIndex = currentIndex
        self.onMove = onMove
        self.onInsertAfter = onInsertAfter
        self.scrollToCurrent = scrollToCurrent
        self.cell = cell
        self.footer = footer()
    }

    @State private var isReordering = false
    @State private var drag: SidebarDragState?
    @State private var metrics = SidebarScrollMetrics()
    @State private var frameBox = SidebarFrameBox()
    @State private var position = ScrollPosition(edge: .top)
    /// Where auto-scroll last sent the list; the user can't scroll meanwhile.
    @State private var scrollTarget: CGFloat = 0
    @State private var liftCount = 0
    /// Resets to false when the drag ends *or is cancelled*.
    @GestureState private var touching = false

    private let edgeZone: CGFloat = 60
    private let spring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            row(index, page)
                                .id(page.id)
                        }
                        footer
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .coordinateSpace(.named(SidebarSpace.content))
                }
                .scrollPosition($position)
                // The list holds still for a reorder; auto-scroll moves it.
                .scrollDisabled(drag != nil)
                .coordinateSpace(.named(SidebarSpace.viewport))
                .onScrollGeometryChange(for: SidebarScrollMetrics.self) { geo in
                    SidebarScrollMetrics(
                        offset: geo.contentOffset.y,
                        insetTop: geo.contentInsets.top,
                        viewportHeight: geo.containerSize.height,
                        minOffset: -geo.contentInsets.top,
                        maxOffset: max(-geo.contentInsets.top,
                                       geo.contentSize.height + geo.contentInsets.bottom - geo.containerSize.height))
                } action: { _, new in
                    metrics = new
                    if var d = drag { d.scrollOffset = new.offset; drag = d }
                }
                .overlay(alignment: .topLeading) { liftedOverlay }
                .simultaneousGesture(reorderGesture, including: isReordering ? .all : .subviews)
                .onChange(of: touching) { _, now in
                    if !now, drag != nil { cancelDrag() }
                }
                .task(id: drag != nil) { await autoScroll() }
                .onAppear { scrollToCurrent(proxy) }
                .onChange(of: currentIndex) { _, _ in scrollToCurrent(proxy) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: liftCount)
        .sensoryFeedback(.selection, trigger: drag?.targetIndex)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy) {
                    isReordering.toggle()
                    drag = nil
                }
            } label: {
                Text(isReordering ? "Done" : "Reorder")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderless)
            .accessibilityHint(isReordering ? "Stops reordering pages" : "Shows a handle on each page to drag it")
        }
        .padding(.horizontal, 4)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ index: Int, _ page: Page) -> some View {
        let lifted = drag?.pageID == page.id
        VStack(spacing: 0) {
            cell(index, page, isReordering)
                .accessibilityActions {
                    if index > 0 {
                        Button("Move up") { onMove(page.id, index - 1) }
                    }
                    if index < pages.count - 1 {
                        Button("Move down") { onMove(page.id, index + 1) }
                    }
                }
                // Measured before the offset below, so it is the slot.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarSpace.content)) } action: {
                    frameBox.frames[page.id] = $0
                }
                .onDisappear { frameBox.frames[page.id] = nil }
                // The lifted page is drawn in the overlay; here it leaves a
                // hollow accent slot that follows the landing position.
                .opacity(lifted ? 0 : 1)
                .overlay {
                    if lifted {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
                .offset(y: rowOffset(index))
                .zIndex(lifted ? 1 : 0)
                .animation(spring, value: drag?.targetIndex)
            SidebarInsertGap(enabled: !isReordering && drag == nil) { onInsertAfter(page) }
        }
    }

    private func rowOffset(_ index: Int) -> CGFloat {
        guard let d = drag else { return 0 }
        let target = d.targetIndex
        if index == d.originIndex {
            return SidebarReorderModel.slotOffset(origin: d.originIndex, target: target, rowStride: d.rowStride)
        }
        return SidebarReorderModel.offset(forRow: index, origin: d.originIndex, target: target, rowStride: d.rowStride)
    }

    @ViewBuilder
    private var liftedOverlay: some View {
        if let d = drag, let index = pages.firstIndex(where: { $0.id == d.pageID }) {
            cell(index, pages[index], true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .scaleEffect(1.05)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .offset(y: d.liftedViewportTop)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Gesture

    private var reorderGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(SidebarSpace.viewport))
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation) }
                guard var d = drag else { return }
                d.translation = value.translation.height
                d.pointerY = value.location.y
                drag = d
            }
            .onEnded { _ in endDrag() }
    }

    /// A drag lifts a page only when it starts on a grip (the bottom-trailing
    /// corner of a cell); anywhere else it is left to the scroll view.
    private func beginDrag(at start: CGPoint) {
        let visibleTop = metrics.offset + metrics.insetTop
        let point = CGPoint(x: start.x, y: start.y + visibleTop)
        for (id, frame) in frameBox.frames {
            let grip = CGRect(x: frame.maxX - 48, y: frame.maxY - 40, width: 48, height: 40)
            guard grip.contains(point),
                  let index = pages.firstIndex(where: { $0.id == id }) else { continue }
            scrollTarget = metrics.offset
            liftCount += 1
            withAnimation(spring) {
                drag = SidebarDragState(pageID: id, originIndex: index, count: pages.count,
                                        rowHeight: frame.height, translation: 0, pointerY: start.y,
                                        startScrollOffset: metrics.offset, scrollOffset: metrics.offset,
                                        startViewportTop: frame.minY - visibleTop)
            }
            return
        }
    }

    private func endDrag() {
        guard let d = drag else { return }
        let target = d.targetIndex
        // No animation: the neighbours' offsets drop to 0 in the same frame
        // the data order changes, which lands them where they already were.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = nil
            if target != d.originIndex { onMove(d.pageID, target) }
        }
    }

    private func cancelDrag() {
        withAnimation(spring) { drag = nil }
    }

    /// Scrolls while the pointer sits in the top or bottom edge zone. A task
    /// that sleeps, not a Timer: no run-loop mode to be starved by, and it
    /// ends with the drag (`.task(id:)`).
    private func autoScroll() async {
        guard drag != nil else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let d = drag else { return }
            let step = SidebarReorderModel.edgeScrollStep(
                pointerY: d.pointerY, viewportHeight: metrics.viewportHeight, edge: edgeZone, maxStep: 14)
            guard step != 0 else { continue }
            let next = SidebarReorderModel.clampedOffset(scrollTarget + step,
                                                         min: metrics.minOffset, max: metrics.maxOffset)
            guard next != scrollTarget else { continue }
            scrollTarget = next
            position.scrollTo(y: next)
        }
    }
}

/// The strip between two cells: a pointer hovering it shows "+", which
/// inserts a page there. Touch has the Add page button instead.
struct SidebarInsertGap: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering && enabled {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: SidebarReorderModel.rowGap)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Insert page here")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SidebarReorderModel.rowGap)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
