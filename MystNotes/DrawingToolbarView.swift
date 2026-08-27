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

/// Everything needed to build the live `PKTool` PencilKit should be using,
/// plus each tool's own remembered settings - switching to the eraser and
/// back to the pen doesn't forget the pen's color/width.
struct DrawingToolState: Equatable {
    var activeKind: DrawingToolKind = .pen
    var penInkType: PKInkingTool.InkType = .pen
    var penColor: Color = .black
    var penWidth: Double = 4
    var highlighterColor: Color = .yellow
    var highlighterWidth: Double = 20
    var eraserType: PKEraserTool.EraserType = .vector
    var eraserWidth: Double = 20
    var fillColor: Color = .yellow

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
            // Fill isn't a real PKTool - NotebookDetailView disables canvas
            // interaction while it's active and taps go to FillTool instead
            // (see canvasSection's fill-tap overlay). This is just an inert
            // fallback so canvasView.tool always has a valid value.
            return PKLassoTool()
        case .lasso:
            return PKLassoTool()
        }
    }
}

/// A floating, GoodNotes/Notability-style drawing toolbar - our own custom
/// UI in place of Apple's system `PKToolPicker`. Tapping a tool selects it;
/// tapping the already-selected Pen/Highlighter/Eraser tool again opens a
/// popover with that tool's options. Undo/redo and the shape tool live here
/// too rather than in the navigation bar, since they're all part of the
/// same "drawing controls" cluster GoodNotes/Notability keep together.
struct DrawingToolbarView: View {
    @Binding var toolState: DrawingToolState
    var canUndo: Bool
    var canRedo: Bool
    var isShapeModeArmed: Bool
    var isShapeToolAvailable: Bool
    var isFillToolAvailable: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onToggleShapeMode: () -> Void

    @State private var openPopover: DrawingToolKind?

    // Lets the whole bar be dragged out of the way instead of sitting fixed
    // over the canvas. Session-only (resets to the default top-center spot
    // next time a page opens) rather than persisted - repositioning is a
    // "get it out of my way right now" action, not a settings-level choice.
    @State private var position: CGSize = .zero
    @GestureState private var activeDrag: CGSize = .zero

    private let presetColors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .brown]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 34)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($activeDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            position.width += value.translation.width
                            position.height += value.translation.height
                        }
                )

            Divider().frame(height: 24)

            iconButton("arrow.uturn.backward", disabled: !canUndo, action: onUndo)
            iconButton("arrow.uturn.forward", disabled: !canRedo, action: onRedo)

            Divider().frame(height: 24)

            toolButton(.pen, systemImage: "pencil.tip")
            toolButton(.highlighter, systemImage: "highlighter")
            toolButton(.eraser, systemImage: "eraser")
            toolButton(.lasso, systemImage: "lasso")
            toolButton(.fill, systemImage: "paintbrush.fill", disabled: !isFillToolAvailable)

            Divider().frame(height: 24)

            iconButton(
                "square.on.circle",
                isOn: isShapeModeArmed,
                disabled: !isShapeToolAvailable,
                action: onToggleShapeMode
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .offset(x: position.width + activeDrag.width, y: position.height + activeDrag.height)
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

                colorRow(selection: $toolState.penColor)
                widthSlider(label: "Width", value: $toolState.penWidth, range: 1...20)
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
