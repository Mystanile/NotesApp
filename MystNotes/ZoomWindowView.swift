import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
import PencilKit
#endif

/// The Zoom Window (competitor gap #7, Nov 2, 2026): a docked writing pad
/// that shows a magnified view of a small rectangle of the page. You write
/// big in the pad; each finished stroke is shrunk back into page space and
/// appended to the page's own drawing, and the rectangle slides along as you
/// reach its right edge - the way GoodNotes does it.
///
/// Ink path, because it is the whole risk of this feature:
/// - The pad is a second `PKCanvasView` that is kept EMPTY. A finished
///   stroke is handed to the page (`ZoomWindowMath.forward`), then the pad is
///   cleared. The page canvas stays the only owner of ink (invariants 1, 5);
///   nothing here saves anything - the detail view's `scheduleAutosave()`
///   does, with its `canvasIsDirty` / `canvasPageID` guards.
/// - What the pad shows of the page is a rendered image (paper ruling plus
///   ink, on white) behind it, drawn on `InkRenderQueue`, never on the
///   cooperative pool, and only when the target or the ink changes.

// MARK: - Pure logic (tested in ZoomWindowTests)

nonisolated enum ZoomWindowMath {
    static let minimumMagnification: CGFloat = 1.5
    static let maximumMagnification: CGFloat = 4
    static let defaultMagnification: CGFloat = 2.5
    /// PencilKit draws nothing for a stroke under ~2 pt (CLAUDE.md), so a
    /// shrunk stroke never goes below this. A thin pen at high magnification
    /// therefore comes out a touch heavier than size / magnification.
    static let minimumPageStrokeSize: CGFloat = 2.2
    /// Where a wrapped line starts and where a line ends, in page points.
    static let pageMargin: CGFloat = 24
    /// A stroke that ends in the right 15% of the target slides it along.
    static let advanceZone: CGFloat = 0.15
    /// How far it slides, as a fraction of the target's width.
    static let slideFraction: CGFloat = 0.7

    static func clampMagnification(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return defaultMagnification }
        return min(max(value, minimumMagnification), maximumMagnification)
    }

    /// The page area the pad shows: the pad's size divided by the zoom.
    static func targetSize(padSize: CGSize, magnification: CGFloat) -> CGSize {
        let m = clampMagnification(magnification)
        guard padSize.width > 0, padSize.height > 0 else { return .zero }
        return CGSize(width: padSize.width / m, height: padSize.height / m)
    }

    /// Keeps a target of `targetSize` entirely on the page. A target larger
    /// than the page pins to the top-left.
    static func clamp(_ origin: CGPoint, targetSize: CGSize, pageSize: CGSize) -> CGPoint {
        let maxX = max(0, pageSize.width - targetSize.width)
        let maxY = max(0, pageSize.height - targetSize.height)
        return CGPoint(x: min(max(origin.x, 0), maxX), y: min(max(origin.y, 0), maxY))
    }

    /// A point in the pad (points from its top-left) as a point on the page.
    static func pagePoint(fromPad point: CGPoint, magnification: CGFloat, targetOrigin: CGPoint) -> CGPoint {
        let m = clampMagnification(magnification)
        return CGPoint(x: targetOrigin.x + point.x / m, y: targetOrigin.y + point.y / m)
    }

    /// A stroke point's size on the page: divided by the zoom, never under
    /// `minimumPageStrokeSize`. `inkScale` is the stroke transform's own
    /// scale (a scale in `PKStroke.transform` scales the width too).
    static func pageStrokeSize(fromPad size: CGSize, magnification: CGFloat, inkScale: CGFloat = 1) -> CGSize {
        let m = clampMagnification(magnification)
        let k = (inkScale.isFinite && inkScale > 0) ? inkScale : 1
        return CGSize(width: max(size.width * k / m, minimumPageStrokeSize),
                      height: max(size.height * k / m, minimumPageStrokeSize))
    }

    /// Whether a stroke ending at `end` (page space) should slide the target.
    static func shouldAdvance(strokeEnd end: CGPoint, target: CGRect) -> Bool {
        guard target.width > 0 else { return false }
        return end.x >= target.minX + target.width * (1 - advanceZone)
    }

    /// The origin the target slides to after a stroke ending in its right
    /// zone: right by 70% of its width; at the right margin, back to the
    /// left margin one target-height down (clamped at the page bottom).
    static func advancedOrigin(of target: CGRect, pageSize: CGSize) -> CGPoint {
        let rightMost = pageSize.width - pageMargin - target.width
        guard rightMost > pageMargin else { return newLineOrigin(of: target, pageSize: pageSize) }
        if target.minX >= rightMost - 0.5 { return newLineOrigin(of: target, pageSize: pageSize) }
        let x = min(target.minX + target.width * slideFraction, rightMost)
        return clamp(CGPoint(x: x, y: target.minY), targetSize: target.size, pageSize: pageSize)
    }

    /// The "↵" button: left margin, one target-height down.
    static func newLineOrigin(of target: CGRect, pageSize: CGSize) -> CGPoint {
        let x = min(pageMargin, max(0, (pageSize.width - target.width) / 2))
        return clamp(CGPoint(x: x, y: target.minY + target.height), targetSize: target.size, pageSize: pageSize)
    }

    /// The "←" button: left by 70%; at the left margin, to the end of the
    /// line above. At the top-left it stays where it is.
    static func steppedBackOrigin(of target: CGRect, pageSize: CGSize) -> CGPoint {
        let rightMost = max(pageMargin, pageSize.width - pageMargin - target.width)
        if target.minX <= pageMargin + 0.5 {
            guard target.minY > 0.5 else { return target.origin }
            return clamp(CGPoint(x: rightMost, y: target.minY - target.height),
                         targetSize: target.size, pageSize: pageSize)
        }
        let x = max(pageMargin, target.minX - target.width * slideFraction)
        return clamp(CGPoint(x: x, y: target.minY), targetSize: target.size, pageSize: pageSize)
    }

    // MARK: Forwarding (PencilKit)

    #if canImport(UIKit)
    /// A stroke is identified on the page by its path's creation date and
    /// its random seed (CLAUDE.md, invariant 6 notes). Millisecond buckets,
    /// as the codec writes them.
    static func strokeKey(_ stroke: PKStroke) -> String {
        "\(Int64((stroke.path.creationDate.timeIntervalSinceReferenceDate * 1000).rounded()))/\(stroke.randomSeed)"
    }

    /// One pad stroke as a page stroke: every point's location mapped,
    /// every point's size shrunk (clamped), ink and seed kept, mask dropped
    /// (the pad's strokes are never erased into). `taken` holds the keys of
    /// strokes already on the page; a collision moves the creation date on a
    /// millisecond so the new stroke's identity stays unique.
    static func pageStroke(from stroke: PKStroke, magnification: CGFloat, targetOrigin: CGPoint,
                           taken: inout Set<String>) -> (stroke: PKStroke, end: CGPoint)? {
        let t = stroke.transform
        let inkScale = CGFloat(abs(Double(t.a) * Double(t.d) - Double(t.b) * Double(t.c)).squareRoot())
        var points: [PKStrokePoint] = []
        points.reserveCapacity(stroke.path.count)
        for point in stroke.path {
            let padLocation = t.isIdentity ? point.location : point.location.applying(t)
            points.append(PKStrokePoint(
                location: pagePoint(fromPad: padLocation, magnification: magnification, targetOrigin: targetOrigin),
                timeOffset: point.timeOffset,
                size: pageStrokeSize(fromPad: point.size, magnification: magnification,
                                     inkScale: t.isIdentity ? 1 : inkScale),
                opacity: point.opacity, force: point.force,
                azimuth: point.azimuth, altitude: point.altitude,
                secondaryScale: point.secondaryScale, threshold: point.threshold))
        }
        guard let end = points.last?.location else { return nil }
        var date = stroke.path.creationDate
        func key(_ d: Date) -> String {
            "\(Int64((d.timeIntervalSinceReferenceDate * 1000).rounded()))/\(stroke.randomSeed)"
        }
        while taken.contains(key(date)) { date = date.addingTimeInterval(0.001) }
        taken.insert(key(date))
        let path = PKStrokePath(controlPoints: points, creationDate: date)
        return (PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil,
                         randomSeed: stroke.randomSeed), end)
    }

    /// All of the pad's new strokes, appended to `drawing`. Returns the new
    /// drawing and where the last stroke ended (page space).
    static func forward(_ padStrokes: [PKStroke], into drawing: PKDrawing, magnification: CGFloat,
                        targetOrigin: CGPoint) -> (drawing: PKDrawing, end: CGPoint)? {
        var taken = Set(drawing.strokes.map(strokeKey))
        var mapped: [PKStroke] = []
        var end: CGPoint?
        for stroke in padStrokes {
            guard let result = pageStroke(from: stroke, magnification: magnification,
                                          targetOrigin: targetOrigin, taken: &taken) else { continue }
            mapped.append(result.stroke)
            end = result.end
        }
        guard let end, !mapped.isEmpty else { return nil }
        var out = drawing
        out.strokes.append(contentsOf: mapped)
        return (out, end)
    }
    #endif
}

#if canImport(UIKit)

// MARK: - State

/// The Zoom Window's state, one per notebook screen. Not part of the page.
@Observable
final class ZoomWindowModel {
    var isOn = false
    var magnification: CGFloat = ZoomWindowMath.defaultMagnification {
        didSet {
            let clamped = ZoomWindowMath.clampMagnification(magnification)
            if clamped != magnification { magnification = clamped }
            reclamp()
        }
    }
    /// Top-left of the target in page points.
    var targetOrigin: CGPoint = CGPoint(x: ZoomWindowMath.pageMargin, y: ZoomWindowMath.pageMargin)
    var padSize: CGSize = .zero { didSet { reclamp() } }
    var pageSize: CGSize = .zero { didSet { reclamp() } }
    /// The page region as the pad shows it, paper and ink on white.
    var reference: UIImage?
    /// Bumped whenever the page's ink may have changed under the reference.
    var inkRevision = 0
    var isDragging = false
    /// The page the target was last placed for.
    var placedPageID: UUID?

    var targetSize: CGSize { ZoomWindowMath.targetSize(padSize: padSize, magnification: magnification) }
    var targetRect: CGRect { CGRect(origin: targetOrigin, size: targetSize) }

    func moveTarget(to origin: CGPoint) {
        let clamped = ZoomWindowMath.clamp(origin, targetSize: targetSize, pageSize: pageSize)
        if clamped != targetOrigin { targetOrigin = clamped }
    }

    private func reclamp() {
        guard pageSize.width > 0, targetSize.width > 0 else { return }
        moveTarget(to: targetOrigin)
    }

    func resetPlacement(at origin: CGPoint? = nil) {
        reference = nil
        moveTarget(to: origin ?? CGPoint(x: ZoomWindowMath.pageMargin, y: ZoomWindowMath.pageMargin))
        inkRevision &+= 1
    }
}

// MARK: - Reference rendering

nonisolated enum ZoomWindowRenderer {
    private struct DrawingBox: @unchecked Sendable { let drawing: PKDrawing }

    /// `rect` of the page - paper ruling, then ink - on white, at
    /// `magnification` (times the screen scale). Ink goes through the light
    /// trait so a dark-mode iPad doesn't draw white ink on white.
    static func reference(of drawing: PKDrawing, template: String, pageSize: CGSize, rect: CGRect,
                          magnification: CGFloat, screenScale: CGFloat) async -> UIImage? {
        let outSize = CGSize(width: rect.width * magnification, height: rect.height * magnification)
        guard outSize.width >= 1, outSize.height >= 1 else { return nil }
        let box = DrawingBox(drawing: drawing)
        return await InkRenderQueue.run {
            let format = UIGraphicsImageRendererFormat()
            format.scale = screenScale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: outSize, format: format)
            return renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: outSize))
                let cg = context.cgContext
                cg.saveGState()
                cg.scaleBy(x: magnification, y: magnification)
                cg.translateBy(x: -rect.minX, y: -rect.minY)
                PageTemplate.draw(template, in: pageSize, context: cg)
                cg.restoreGState()
                guard !box.drawing.strokes.isEmpty, box.drawing.bounds.intersects(rect) else { return }
                var ink: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = box.drawing.image(from: rect, scale: magnification * screenScale)
                }
                ink?.draw(in: CGRect(origin: .zero, size: outSize))
            }
        }
    }
}

// MARK: - The pad

/// The pad's own undo manager, discarded after every forwarded stroke: the
/// page canvas's undo stack is the only one that matters.
final class ZoomPadCanvasView: PKCanvasView {
    private let padUndoManager = UndoManager()
    override var undoManager: UndoManager? { padUndoManager }
}

/// What the pad inks with: the page canvas's tool, except that lasso and
/// fill (which are not ink) fall back to the pen.
func zoomPadTool(for state: DrawingToolState) -> PKTool {
    switch state.activeKind {
    case .lasso, .fill:
        return PKInkingTool(state.penInkType, color: state.penColor.fixedUIColor, width: state.penWidth)
    default:
        return state.pkTool
    }
}

struct ZoomPadCanvas: UIViewRepresentable {
    var toolState: DrawingToolState
    var fingerDrawing: Bool
    var onStrokes: ([PKStroke]) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onStrokes: onStrokes) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = ZoomPadCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // The pad is white paper whatever the system appearance.
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.drawingPolicy = PKCanvasViewDrawingPolicy.policy(fingerDrawing: fingerDrawing, isMac: CanvasInput.isMac)
        canvas.tool = zoomPadTool(for: toolState)
        context.coordinator.lastTool = toolState
        canvas.delegate = context.coordinator
        return canvas
    }

    /// Runs on every update of the detail view: write only what differs.
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onStrokes = onStrokes
        let policy = PKCanvasViewDrawingPolicy.policy(fingerDrawing: fingerDrawing, isMac: CanvasInput.isMac)
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        if context.coordinator.lastTool != toolState {
            context.coordinator.lastTool = toolState
            canvas.tool = zoomPadTool(for: toolState)
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onStrokes: ([PKStroke]) -> Bool
        var lastTool: DrawingToolState?
        init(onStrokes: @escaping ([PKStroke]) -> Bool) { self.onStrokes = onStrokes }

        /// Strokes already handed to the page whose removal from the pad is
        /// still queued. A second stroke ending before that clear runs must
        /// not hand the first one over again (review, Nov 2, 2026).
        private var pendingDrop = 0

        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            // Only strokes not already handed over are new.
            let strokes = Array(canvas.drawing.strokes.dropFirst(pendingDrop))
            guard !strokes.isEmpty else { return }
            // Not taken (the page changed under the pad): keep the ink in
            // the pad rather than lose it.
            guard onStrokes(strokes) else { return }
            pendingDrop += strokes.count
            // Next turn of the run loop, not inside PencilKit's callback.
            // Only what was handed over is dropped, so a stroke begun in the
            // meantime survives. Assigning `drawing` is not an undo step.
            DispatchQueue.main.async { [weak self, weak canvas] in
                guard let self else { return }
                let drop = self.pendingDrop
                self.pendingDrop = 0
                guard let canvas else { return }
                canvas.drawing = PKDrawing(strokes: Array(canvas.drawing.strokes.dropFirst(drop)))
                canvas.undoManager?.removeAllActions()
            }
        }
    }
}

// MARK: - The docked panel

struct ZoomWindowPanel: View {
    static let height: CGFloat = 220

    @Bindable var model: ZoomWindowModel
    let pageID: UUID
    let pageSize: CGSize
    let template: String
    let toolState: DrawingToolState
    let fingerDrawing: Bool
    let canUndo: Bool
    let canRedo: Bool
    /// The page canvas's current ink, read when a reference render starts.
    let currentDrawing: () -> PKDrawing
    /// Appends the strokes to the page; the page point where the last one
    /// ended, or nil when the page was not in a state to take them.
    let onForward: ([PKStroke], CGPoint, CGFloat) -> CGPoint?
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onClose: () -> Void

    private struct RenderKey: Hashable {
        var pageID: UUID
        var x: Int, y: Int
        var width: Int, height: Int
        var magnification: Int
        var revision: Int
        var dragging: Bool
        var template: String
    }

    private var renderKey: RenderKey {
        RenderKey(pageID: pageID,
                  x: Int(model.targetOrigin.x.rounded()), y: Int(model.targetOrigin.y.rounded()),
                  width: Int(model.padSize.width.rounded()), height: Int(model.padSize.height.rounded()),
                  magnification: Int((model.magnification * 10).rounded()),
                  revision: model.inkRevision, dragging: model.isDragging, template: template)
    }

    var body: some View {
        VStack(spacing: Space.s) {
            GeometryReader { geo in
                ZStack {
                    Color.white
                    if let reference = model.reference {
                        Image(uiImage: reference)
                            .resizable()
                            .interpolation(.high)
                    }
                    ZoomPadCanvas(toolState: toolState, fingerDrawing: fingerDrawing) { strokes in
                        handle(strokes)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
                )
                .onChange(of: geo.size, initial: true) { _, size in model.padSize = size }
            }
            controls
        }
        .padding(Space.m)
        .frame(height: Self.height)
        .surfaceCard()
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.s)
        .task(id: renderKey) { await renderReference() }
        .onChange(of: pageSize, initial: true) { _, size in model.pageSize = size }
        .onAppear {
            // A fresh pad per page (`.id(pageID)`); a new page starts the
            // target at the top-left again.
            if model.placedPageID != pageID {
                model.placedPageID = pageID
                model.resetPlacement()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Space.xs) {
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ToolIconButtonStyle())
                .disabled(!canUndo)
                .accessibilityLabel("Undo")
            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ToolIconButtonStyle())
                .disabled(!canRedo)
                .accessibilityLabel("Redo")

            Divider().frame(height: Metrics.toolButton)

            Button { stepBack() } label: { Image(systemName: "arrow.left") }
                .buttonStyle(ToolIconButtonStyle())
                .accessibilityLabel("Step back")
            Button { newLine() } label: { Image(systemName: "return") }
                .buttonStyle(ToolIconButtonStyle())
                .accessibilityLabel("New line")

            Divider().frame(height: Metrics.toolButton)

            Slider(value: $model.magnification,
                   in: ZoomWindowMath.minimumMagnification...ZoomWindowMath.maximumMagnification, step: 0.1)
                .frame(minWidth: 120, maxWidth: 260)
                .accessibilityLabel("Magnification")
            Text(String(format: "%.1f\u{00D7}", Double(model.magnification)))
                .font(Typography.mono)
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)

            Spacer(minLength: 0)

            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(ToolIconButtonStyle())
                .accessibilityLabel("Close Zoom Window")
        }
        .frame(height: Metrics.minHitTarget)
    }

    private func handle(_ strokes: [PKStroke]) -> Bool {
        let target = model.targetRect
        guard let end = onForward(strokes, target.origin, model.magnification) else { return false }
        if ZoomWindowMath.shouldAdvance(strokeEnd: end, target: target) {
            withAnimation(Motion.quick) {
                model.moveTarget(to: ZoomWindowMath.advancedOrigin(of: target, pageSize: model.pageSize))
            }
        }
        model.inkRevision &+= 1
        return true
    }

    private func stepBack() {
        withAnimation(Motion.quick) {
            model.moveTarget(to: ZoomWindowMath.steppedBackOrigin(of: model.targetRect, pageSize: model.pageSize))
        }
    }

    private func newLine() {
        withAnimation(Motion.quick) {
            model.moveTarget(to: ZoomWindowMath.newLineOrigin(of: model.targetRect, pageSize: model.pageSize))
        }
    }

    /// Debounced and cancelled by `.task(id:)`: a drag, a slider sweep or a
    /// burst of strokes renders once, after it settles.
    private func renderReference() async {
        guard !model.isDragging else { return }
        let rect = model.targetRect
        guard rect.width > 0, model.pageSize.width > 0 else { return }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        let image = await ZoomWindowRenderer.reference(
            of: currentDrawing(), template: template, pageSize: model.pageSize, rect: rect,
            magnification: model.magnification, screenScale: max(UITraitCollection.current.displayScale, 2))
        guard !Task.isCancelled, let image else { return }
        model.reference = image
    }
}

// MARK: - The target on the page

/// Drawn in page space inside a `PageViewportLayer`. Only the grip takes
/// touches, so the Pencil can still ink inside the outline.
struct ZoomTargetOverlay: View {
    @Bindable var model: ZoomWindowModel
    /// Screen points per page point; sizes below are divided by it so the
    /// outline and grip stay the same size on screen at any zoom.
    let scale: CGFloat

    @State private var dragStart: CGPoint?

    var body: some View {
        let rect = model.targetRect
        let z = max(scale, 0.0001)
        ZStack(alignment: .topLeading) {
            if rect.width > 0 {
                Rectangle()
                    .fill(Palette.ink.opacity(0.07))
                    .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 2 / z))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                Capsule()
                    .fill(Palette.ink)
                    .overlay(
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 13 / z, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .frame(width: 44 / z, height: 22 / z)
                    .frame(width: Metrics.minHitTarget / z * 1.4, height: Metrics.minHitTarget / z)
                    .contentShape(Rectangle())
                    .offset(x: rect.midX - Metrics.minHitTarget / z * 0.7, y: rect.minY - 4 / z)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil { dragStart = model.targetOrigin; model.isDragging = true }
                                guard let start = dragStart else { return }
                                model.moveTarget(to: CGPoint(x: start.x + value.translation.width / z,
                                                             y: start.y + value.translation.height / z))
                            }
                            .onEnded { _ in
                                dragStart = nil
                                model.isDragging = false
                            }
                    )
                    .accessibilityLabel("Move zoom window target")
            }
        }
    }
}

#endif
