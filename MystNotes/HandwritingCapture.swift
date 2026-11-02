import SwiftUI
import PencilKit
import Observation

// MARK: - Geometry

/// The guided writing box. Everything is in points inside a `width x height`
/// box; the canvas is exactly this size with no scrolling, so a drawing's
/// coordinates are box coordinates.
nonisolated enum CaptureGeometry {
    static let width: CGFloat = 360
    static let height: CGFloat = 280
    static let xHeight: CGFloat = 56
    static let baselineY: CGFloat = 180
    static var xHeightY: CGFloat { baselineY - xHeight }
    static var capHeightY: CGFloat { baselineY - xHeight * HandwritingSynth.capHeight }
    static var descenderY: CGFloat { baselineY + xHeight * 0.5 }
    static let penWidth: CGFloat = 3
    /// Space either side of the ink, in x-heights.
    static let sideBearing: CGFloat = 0.08
}

// MARK: - Drawing to sample

nonisolated enum GlyphNormalizer {
    /// Converts what was written in the guide box into a baseline-relative,
    /// x-height-normalized sample, or nil if there is no ink.
    /// Points are taken along the drawn curve (`interpolatedPoints`), not
    /// from the raw B-spline control points, so the sample is the shape the
    /// user actually saw.
    static func sample(from drawing: PKDrawing) -> GlyphSample? {
        var raw: [[(point: PKStrokePoint, x: CGFloat, y: CGFloat)]] = []
        for stroke in drawing.strokes {
            let transform = stroke.transform
            let points = stroke.path.interpolatedPoints(by: .distance(4)).map { p -> (point: PKStrokePoint, x: CGFloat, y: CGFloat) in
                let loc = p.location.applying(transform)
                return (point: p, x: loc.x, y: loc.y)
            }
            if points.count >= 2 { raw.append(points) }
        }
        let xs = raw.flatMap { $0.map { $0.x } }
        guard let minX = xs.min(), let maxX = xs.max() else { return nil }

        let xh = CaptureGeometry.xHeight
        let bearing = CaptureGeometry.sideBearing
        func round3(_ v: CGFloat) -> CGFloat { (v * 1000).rounded() / 1000 }

        let strokes = raw.map { stroke in
            stroke.map { item in
                GlyphPoint(
                    x: round3((item.x - minX) / xh + bearing),
                    y: round3((item.y - CaptureGeometry.baselineY) / xh),
                    size: round3(item.point.size.width / CaptureGeometry.penWidth),
                    force: round3(item.point.force > 0 ? item.point.force : 0.5),
                    t: (item.point.timeOffset * 1000).rounded() / 1000
                )
            }
        }
        return GlyphSample(strokes: strokes, advance: round3((maxX - minX) / xh + 2 * bearing))
    }
}

// MARK: - Model

@MainActor
@Observable
final class HandwritingCaptureModel {
    enum Group: CaseIterable {
        case lowercase, uppercase, digits, punctuation
        var title: String {
            switch self {
            case .lowercase: "Lowercase"
            case .uppercase: "Uppercase"
            case .digits: "Digits"
            case .punctuation: "Punctuation"
            }
        }
    }

    struct Step: Equatable {
        let character: Character
        /// Which variation of this character: 0, or 0 and 1 for lowercase.
        let pass: Int
        let passes: Int
        let group: Group
    }

    let steps: [Step]
    private(set) var profile: HandwritingProfile
    /// `steps.count` means the preview.
    private(set) var index: Int
    /// Bumped to give the canvas a fresh page (Clear, or a new step).
    private(set) var canvasToken = 0
    /// What is on the canvas now. Per-step drawings are kept for this
    /// session so Back shows what was written.
    var currentDrawing = PKDrawing()
    private var drawings: [Int: PKDrawing] = [:]
    private let storeURL: URL

    init(profile: HandwritingProfile? = HandwritingProfileStore.load(),
         storeURL: URL = HandwritingProfileStore.fileURL) {
        var steps: [Step] = []
        for c in HandwritingCharset.lowercase { for p in 0..<2 { steps.append(Step(character: c, pass: p, passes: 2, group: .lowercase)) } }
        for c in HandwritingCharset.uppercase { steps.append(Step(character: c, pass: 0, passes: 1, group: .uppercase)) }
        for c in HandwritingCharset.digits { steps.append(Step(character: c, pass: 0, passes: 1, group: .digits)) }
        for c in HandwritingCharset.punctuation { steps.append(Step(character: c, pass: 0, passes: 1, group: .punctuation)) }
        self.steps = steps
        self.storeURL = storeURL
        let loaded = profile ?? HandwritingProfile()
        self.profile = loaded
        // Resume at the first step with no saved sample.
        self.index = steps.firstIndex { (loaded.glyphs[String($0.character)]?.count ?? 0) <= $0.pass } ?? steps.count
    }

    var isPreview: Bool { index >= steps.count }
    var step: Step? { isPreview ? nil : steps[index] }
    var completedCount: Int {
        steps.filter { (profile.glyphs[String($0.character)]?.count ?? 0) > $0.pass }.count
    }
    var progressText: String { isPreview ? "\(steps.count) of \(steps.count)" : "\(index + 1) of \(steps.count)" }
    var currentIsDone: Bool {
        guard let step else { return false }
        return (profile.glyphs[String(step.character)]?.count ?? 0) > step.pass
    }

    func next() { commit(); go(to: min(index + 1, steps.count)) }
    func back() { commit(); go(to: max(index - 1, 0)) }
    func skip() { go(to: min(index + 1, steps.count)) }

    func clear() {
        currentDrawing = PKDrawing()
        drawings[index] = nil
        canvasToken += 1
    }

    /// Moves the old profile to trash and starts again from step one.
    func startOver() {
        HandwritingProfileStore.reset(at: storeURL)
        profile = HandwritingProfile()
        drawings = [:]
        go(to: 0)
    }

    private func go(to newIndex: Int) {
        index = newIndex
        currentDrawing = drawings[newIndex] ?? PKDrawing()
        canvasToken += 1
    }

    /// Stores what is on the canvas as this step's sample and saves. An
    /// empty canvas keeps whatever was saved before.
    private func commit() {
        guard let step else { return }
        drawings[index] = currentDrawing
        guard let sample = GlyphNormalizer.sample(from: currentDrawing) else { return }
        profile.setSample(sample, for: step.character, pass: step.pass)
        HandwritingProfileStore.saveInBackground(profile, to: storeURL)
    }
}

// MARK: - Views

struct HandwritingCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = HandwritingCaptureModel()
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.l) {
                header
                if model.isPreview {
                    HandwritingPreview(profile: model.profile)
                } else if let step = model.step {
                    prompt(for: step)
                    CaptureBox(model: model, step: step)
                }
                controls
            }
            .padding(Space.l)
            .navigationTitle("Teach Linework your handwriting")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Start Over", role: .destructive) { confirmReset = true }
                }
            }
            .confirmationDialog("Start over?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Start Over", role: .destructive) { model.startOver() }
            } message: {
                Text("Your current handwriting is moved to the trash folder, not deleted.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                SectionLabel(model.step?.group.title ?? "Preview")
                Text(model.progressText).font(Typography.label).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.isPreview ? model.steps.count : model.index),
                         total: Double(model.steps.count))
        }
    }

    private func prompt(for step: HandwritingCaptureModel.Step) -> some View {
        VStack(spacing: Space.xs) {
            Text("Write \u{201C}\(String(step.character))\u{201D}")
                .font(Typography.title)
            if step.passes > 1 {
                Text("Time \(step.pass + 1) of \(step.passes), for a little variety")
                    .font(Typography.caption).foregroundStyle(.secondary)
            } else if model.currentIsDone {
                Text("Already saved. Write again to replace it.")
                    .font(Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Space.m) {
            Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.index == 0)
            Spacer()
            if model.isPreview {
                Button("Finish") { dismiss() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Clear") { model.clear() }
                Button("Skip") { model.skip() }
                Button { model.next() } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .minimumHitTarget()
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Guide lines, the faint example and the canvas, stacked.
private struct CaptureBox: View {
    @Bindable var model: HandwritingCaptureModel
    let step: HandwritingCaptureModel.Step

    var body: some View {
        ZStack(alignment: .top) {
            GuideLines()
            // Baseline-aligned example: the text's first baseline is made its
            // top alignment guide, then offset to the guide box's baseline.
            // Approximate; check the alignment on the device.
            Text(String(step.character))
                .font(.system(size: exampleFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.gray.opacity(0.22))
                .frame(width: CaptureGeometry.width)
                .alignmentGuide(.top) { $0[.firstTextBaseline] }
                .offset(y: CaptureGeometry.baselineY)
                .allowsHitTesting(false)
            CaptureCanvas(drawing: $model.currentDrawing)
                .id(model.canvasToken)
        }
        .frame(width: CaptureGeometry.width, height: CaptureGeometry.height)
        .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
        )
    }

    /// A system face's x-height is about 0.52 em, a capital 0.70 em.
    private var exampleFontSize: CGFloat {
        step.character.isLowercase
            ? CaptureGeometry.xHeight / 0.52
            : CaptureGeometry.xHeight * HandwritingSynth.capHeight / 0.70
    }
}

private struct GuideLines: View {
    var body: some View {
        Canvas { context, size in
            func line(_ y: CGFloat, _ opacity: Double, dashed: Bool) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(.accentColor.opacity(opacity)),
                               style: StrokeStyle(lineWidth: 1, dash: dashed ? [6, 5] : []))
            }
            line(CaptureGeometry.capHeightY, 0.35, dashed: true)
            line(CaptureGeometry.xHeightY, 0.35, dashed: true)
            line(CaptureGeometry.baselineY, 0.7, dashed: false)
            line(CaptureGeometry.descenderY, 0.18, dashed: true)
        }
        .allowsHitTesting(false)
    }
}

/// The writing surface. `.anyInput` so a finger or mouse works too (Mac).
/// Always light, so the black pen is black in dark mode. A fresh canvas is
/// made per step through `.id`, so there is no update logic to keep in sync.
private struct CaptureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: CaptureGeometry.penWidth)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: CaptureCanvas
        init(_ parent: CaptureCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}

/// "The quick brown fox..." in the captured hand, drawn by a non-interactive
/// canvas (a view render, not `PKDrawing.image`).
private struct HandwritingPreview: View {
    let profile: HandwritingProfile
    private static let sentence = "The quick brown fox jumps over the lazy dog"
    @State private var seed: UInt64 = 1

    var body: some View {
        VStack(spacing: Space.m) {
            Text("Here is how it looks").font(Typography.title)
            GeometryReader { proxy in
                PreviewCanvas(drawing: drawing(width: proxy.size.width))
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                            .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
                    )
            }
            .frame(height: 220)
            Button { seed &+= 1 } label: { Label("Write it again", systemImage: "arrow.clockwise") }
            Text("Letters you skipped are filled in with a plain hand.")
                .font(Typography.caption).foregroundStyle(.secondary)
        }
    }

    private func drawing(width: CGFloat) -> PKDrawing {
        let padding = Space.l
        let strokes = HandwritingSynth.layout(
            text: Self.sentence, profile: profile,
            origin: CGPoint(x: padding, y: padding), maxWidth: max(width - 2 * padding, 100),
            xHeight: 20, ink: PKInk(.pen, color: .black), width: 2.4,
            baseDate: Date(timeIntervalSinceReferenceDate: 0), seed: seed
        )
        return PKDrawing(strokes: strokes)
    }
}

private struct PreviewCanvas: UIViewRepresentable {
    let drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Not `==`: PKDrawing compares an identity, not content.
        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            canvas.drawing = drawing
        }
    }
}
