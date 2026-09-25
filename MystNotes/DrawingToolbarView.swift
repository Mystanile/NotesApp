import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit

/// Which drawing tool is currently active. Distinct from `PKInkingTool`'s
/// own `InkType` - Pen encompasses all of PencilKit's inking types (pen,
/// pencil, marker, fountain pen, monoline, picked via the Pen options
/// popover), while Highlighter is its own slot with a fixed translucent
/// marker ink, since PencilKit has no dedicated highlighter ink type.
enum DrawingToolKind: Equatable {
    case pen, highlighter, eraser, lasso, fill
}

/// A saved pen - ink, colour, width - one tap away in the pen's options.
/// Kept in `AppSettings.penPresets`; ink types this build doesn't know (a
/// newer build's) come back as the plain pen.
struct PenPreset: Codable, Equatable, Hashable {
    var inkType: String
    var colorHex: String
    var width: Double

    init(inkType: String, colorHex: String, width: Double) {
        self.inkType = inkType; self.colorHex = colorHex; self.width = width
    }

    init(_ state: DrawingToolState) {
        self.init(inkType: state.penInkType.rawValue, colorHex: state.penColor.toHex(), width: state.penWidth)
    }

    var pkInkType: PKInkingTool.InkType {
        let known: [PKInkingTool.InkType] = [.pen, .pencil, .marker, .fountainPen, .monoline]
        return known.first { $0.rawValue == inkType } ?? .pen
    }

    var color: Color { Color(hex: colorHex) }

    func apply(to state: inout DrawingToolState) {
        state.penInkType = pkInkType
        state.penColor = color
        state.penWidth = width
    }

    static let limit = 8

    static func encode(_ presets: [PenPreset]) -> Data { (try? JSONEncoder().encode(presets)) ?? Data() }
    static func decode(_ data: Data) -> [PenPreset] { (try? JSONDecoder().decode([PenPreset].self, from: data)) ?? [] }
}

/// Everything needed to build the live `PKTool` PencilKit should be using,
/// plus each tool's own remembered settings - switching to the eraser and
/// back to the pen doesn't forget the pen's color/width.
struct DrawingToolState: Equatable {
    var activeKind: DrawingToolKind = .pen
    var penInkType: PKInkingTool.InkType = .pen
    /// Picking a pen colour picks the fill's too; the fill's own colour
    /// row can still choose another until the pen's changes again.
    var penColor: Color = .black {
        didSet { if penColor != oldValue { fillColor = penColor } }
    }
    var penWidth: Double = 4
    var highlighterColor: Color = .yellow
    var highlighterWidth: Double = 20
    var eraserType: PKEraserTool.EraserType = .vector
    var eraserWidth: Double = 20
    var fillColor: Color = .black
    /// Solid / dashed / dotted, for shapes made by holding a stroke still
    /// (`ShapeHoldRecognizer`). Freehand ink is always solid - PencilKit
    /// has no dashed ink, and a dashed shape is many short strokes.
    var shapeLineStyle: ShapeLineStyle = .solid

    var pkTool: PKTool {
        switch activeKind {
        case .pen:
            return PKInkingTool(penInkType, color: penColor.fixedUIColor, width: penWidth)
        case .highlighter:
            // PencilKit has no dedicated highlighter ink type - a wide,
            // translucent marker is the standard way apps fake one.
            return PKInkingTool(.marker, color: highlighterColor.fixedUIColor.withAlphaComponent(0.4), width: highlighterWidth)
        case .eraser:
            return PKEraserTool(eraserType, width: eraserWidth)
        case .fill:
            // Fill isn't a real PKTool - NotebookDetailView stands the
            // canvas's drawing gesture down while it's active and a tap on
            // the host goes to FillTool instead (`onFillTap`). This is just
            // an inert fallback so canvasView.tool always has a valid value.
            return PKLassoTool()
        case .lasso:
            return PKLassoTool()
        }
    }
}

/// The GoodNotes/Notability-style drawing toolbar - our own custom UI in
/// place of Apple's system `PKToolPicker`. Tapping a tool selects it;
/// tapping the already-selected Pen/Highlighter/Eraser tool again opens a
/// popover with that tool's options. Undo/redo and the text-box button live
/// here too, since they're all part of the same "drawing controls" cluster
/// GoodNotes/Notability keep together.
///
/// Two presentations of the same controls:
/// - `.inline` sits in the navigation bar's principal slot, on the row with
///   Play / Pages / + / Save, the way GoodNotes lays its bar out. No
///   background, no drag handle - the bar is the chrome.
/// - `.floating` is the capsule over the canvas, draggable out of the way.
///   Used where the navigation bar has no room for it (compact width).
struct DrawingToolbarView: View {
    enum Style { case inline, floating }

    var style: Style = .floating
    @Binding var toolState: DrawingToolState
    @AppStorage(AppSettings.Keys.penPresets) private var presetData = Data()
    /// Which tool's options popover is open. Owned by the parent so a
    /// Pencil squeeze can open it from the canvas.
    @Binding var openPopover: DrawingToolKind?
    var canUndo: Bool
    var canRedo: Bool
    var isFillToolAvailable: Bool
    /// Text boxes only render on paged pages, not the whiteboard.
    var isTextBoxAvailable: Bool
    /// The area the bar is allowed to be dragged around inside.
    var containerSize: CGSize
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onAddTextBox: () -> Void
    var onAddSticker: () -> Void
    var onAddLink: () -> Void

    // Lets the whole bar be dragged out of the way instead of sitting fixed
    // over the canvas. Session-only (resets to the default top-center spot
    // next time a page opens) rather than persisted - repositioning is a
    // "get it out of my way right now" action, not a settings-level choice.
    @State private var position: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var barSize: CGSize = .zero

    private let presetColors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .brown]

    var body: some View {
        switch style {
        case .inline:
            controls
        case .floating:
            HStack(spacing: 4) {
                dragHandle
                Divider().frame(height: 24)
                controls
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { barSize = geo.size }
                        .onChange(of: geo.size) { _, new in barSize = new }
                }
            )
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .offset(x: position.width, y: position.height)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", disabled: !canUndo, action: onUndo)
            iconButton("arrow.uturn.forward", disabled: !canRedo, action: onRedo)

            Divider().frame(height: 24)

            toolButton(.pen, systemImage: "pencil.tip")
            toolButton(.highlighter, systemImage: "highlighter")
            toolButton(.eraser, systemImage: "eraser")
            toolButton(.lasso, systemImage: "lasso")
            toolButton(.fill, systemImage: "paintbrush.fill", disabled: !isFillToolAvailable)

            Divider().frame(height: 24)

            // Shapes have no button: draw one and hold the pencil still at
            // the end, and it snaps (see ShapeHoldRecognizer).
            // Stickers and links share the text box's rule: paged pages only.
            iconButton("character.textbox", disabled: !isTextBoxAvailable, action: onAddTextBox)
            iconButton("face.smiling", disabled: !isTextBoxAvailable, action: onAddSticker)
            iconButton("link", disabled: !isTextBoxAvailable, action: onAddLink)
        }
    }

    private var dragHandle: some View {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 34)
                .contentShape(Rectangle())
                .gesture(
                    // .global is essential: a DragGesture in the default
                    // (local) space measures translation against the bar's
                    // own frame, which this gesture is simultaneously
                    // moving - that feedback loop is what made dragging
                    // jitter and lag behind the finger.
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? position
                            if dragStart == nil { dragStart = position }
                            position = clampedPosition(CGSize(
                                width: start.width + value.translation.width,
                                height: start.height + value.translation.height
                            ))
                        }
                        .onEnded { _ in dragStart = nil }
                )
    }

    /// Keeps the bar fully inside the area it was given, so it can't be
    /// dragged off-screen or down underneath the page-thumbnail strip.
    private func clampedPosition(_ proposed: CGSize) -> CGSize {
        guard containerSize.width > 0, barSize.width > 0 else { return proposed }
        // It starts horizontally centered, so x is free to travel half the
        // leftover width in either direction.
        let maxX = max((containerSize.width - barSize.width) / 2, 0)
        // ...and vertically it starts at the top, so it can only travel down.
        let maxY = max(containerSize.height - barSize.height, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, 0), maxY)
        )
    }

    @ViewBuilder
    private func toolButton(_ kind: DrawingToolKind, systemImage: String, disabled: Bool = false) -> some View {
        Button {
            if toolState.activeKind == kind {
                openPopover = kind
            } else {
                toolState.activeKind = kind
            }
        } label: {
            toolIcon(systemImage, isOn: toolState.activeKind == kind)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .popover(isPresented: Binding(
            get: { openPopover == kind },
            set: { if !$0 { openPopover = nil } }
        )) {
            optionsView(for: kind)
                .padding()
                .frame(minWidth: 260)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemImage: String, isOn: Bool = false, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            toolIcon(systemImage, isOn: isOn)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func toolIcon(_ systemImage: String, isOn: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18))
            .frame(width: 34, height: 34)
            .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
    }

    /// Saved pens: tap to use, + to save the pen as it is, long-press to
    /// remove one.
    private var presetRow: some View {
        HStack(spacing: 10) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    preset.apply(to: &toolState)
                } label: {
                    Circle()
                        .fill(preset.color)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().fill(Color.white).frame(width: min(max(preset.width, 2), 18) * 0.9)
                                .opacity(0.35)
                        }
                        .overlay {
                            if PenPreset(toolState) == preset {
                                Circle().strokeBorder(Color.primary, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        presets.removeAll { $0 == preset }
                    } label: { Label("Remove Preset", systemImage: "trash") }
                }
                .accessibilityLabel("Pen preset")
            }
            if presets.count < PenPreset.limit, !presets.contains(PenPreset(toolState)) {
                Button {
                    presets.append(PenPreset(toolState))
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .help("Save this pen as a preset")
            }
        }
    }

    private var presets: [PenPreset] {
        get { PenPreset.decode(presetData) }
        nonmutating set { presetData = PenPreset.encode(newValue) }
    }

    @ViewBuilder
    private func optionsView(for kind: DrawingToolKind) -> some View {
        switch kind {
        case .pen:
            VStack(alignment: .leading, spacing: 16) {
                Picker("Ink", selection: $toolState.penInkType) {
                    Text("Pen").tag(PKInkingTool.InkType.pen)
                    Text("Pencil").tag(PKInkingTool.InkType.pencil)
                    Text("Marker").tag(PKInkingTool.InkType.marker)
                    Text("Fountain").tag(PKInkingTool.InkType.fountainPen)
                    Text("Monoline").tag(PKInkingTool.InkType.monoline)
                }
                .pickerStyle(.segmented)

                presetRow
                colorRow(selection: $toolState.penColor)
                widthSlider(label: "Width", value: $toolState.penWidth, range: 1...20)
                shapeStyleRow
            }
        case .highlighter:
            VStack(alignment: .leading, spacing: 16) {
                colorRow(selection: $toolState.highlighterColor)
                widthSlider(label: "Width", value: $toolState.highlighterWidth, range: 8...40)
            }
        case .eraser:
            VStack(alignment: .leading, spacing: 16) {
                Picker("Type", selection: $toolState.eraserType) {
                    Text("Precise").tag(PKEraserTool.EraserType.vector)
                    Text("Area").tag(PKEraserTool.EraserType.bitmap)
                }
                .pickerStyle(.segmented)
                widthSlider(label: "Width", value: $toolState.eraserWidth, range: 5...60)
            }
        case .fill:
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap an enclosed area to fill it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                colorRow(selection: $toolState.fillColor)
            }
        case .lasso:
            EmptyView()
        }
    }

    /// The line style snapped shapes are drawn in. It lives in the pen
    /// options because that's where the rest of "what my mark looks like"
    /// is, and it's labelled for shapes because freehand ink can't be
    /// dashed - see `ShapeLineStyle`.
    @ViewBuilder
    private var shapeStyleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shapes (hold a stroke to snap)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Shape line", selection: $toolState.shapeLineStyle) {
                ForEach(ShapeLineStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func colorRow(selection: Binding<Color>) -> some View {
        HStack(spacing: 10) {
            ForEach(presetColors, id: \.self) { color in
                Button {
                    selection.wrappedValue = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay {
                            if selection.wrappedValue == color {
                                Circle().strokeBorder(Color.primary, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: selection)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func widthSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(value.wrappedValue, specifier: "%.1f") pt")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }
}
#endif
