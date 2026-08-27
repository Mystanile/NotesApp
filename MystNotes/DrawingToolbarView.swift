import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit

/// Which drawing tool is currently active. Distinct from `PKInkingTool`'s
/// own `InkType` - Pen encompasses all of PencilKit's inking types (pen,
/// pencil, marker, fountain pen, monoline, picked via the Pen options
/// popover), while Highlighter is its own slot with a fixed translucent
/// marker ink, since PencilKit has no dedicated highlighter ink type.
enum DrawingToolKind: Equatable {
    case pen, highlighter, eraser, lasso
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

    var pkTool: PKTool {
        switch activeKind {
        case .pen:
            return PKInkingTool(penInkType, color: UIColor(penColor), width: penWidth)
        case .highlighter:
            // PencilKit has no dedicated highlighter ink type - a wide,
            // translucent marker is the standard way apps fake one.
            return PKInkingTool(.marker, color: UIColor(highlighterColor).withAlphaComponent(0.4), width: highlighterWidth)
        case .eraser:
            return PKEraserTool(eraserType, width: eraserWidth)
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
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onToggleShapeMode: () -> Void

    @State private var openPopover: DrawingToolKind?

    private let presetColors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .brown]

    var body: some View {
        HStack(spacing: 4) {
            iconButton("arrow.uturn.backward", disabled: !canUndo, action: onUndo)
            iconButton("arrow.uturn.forward", disabled: !canRedo, action: onRedo)

            Divider().frame(height: 24)

            toolButton(.pen, systemImage: "pencil.tip")
            toolButton(.highlighter, systemImage: "highlighter")
            toolButton(.eraser, systemImage: "eraser")
            toolButton(.lasso, systemImage: "lasso")

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
    }

    @ViewBuilder
    private func toolButton(_ kind: DrawingToolKind, systemImage: String) -> some View {
        Button {
            if toolState.activeKind == kind {
                openPopover = kind
            } else {
                toolState.activeKind = kind
            }
        } label: {
            toolIcon(systemImage, isOn: toolState.activeKind == kind)
        }
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
