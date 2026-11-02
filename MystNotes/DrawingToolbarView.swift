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

/// The toolbar's optional tools, which Settings can hide. The pen and the
/// eraser are always there.
enum ToolbarItemChoice: String, CaseIterable, Identifiable {
    case highlighter, lasso, fill, textBox, sticker, image, link
    var id: String { rawValue }

    var label: String {
        switch self {
        case .highlighter: return "Highlighter"
        case .lasso: return "Lasso"
        case .fill: return "Fill"
        case .textBox: return "Text Box"
        case .sticker: return "Stickers"
        case .image: return "Images"
        case .link: return "Links"
        }
    }

    /// Stored as a comma-separated list of the hidden ones, so a tool a
    /// later build adds shows by default.
    static func hidden(in stored: String) -> Set<ToolbarItemChoice> {
        Set(stored.split(separator: ",").compactMap { ToolbarItemChoice(rawValue: String($0)) })
    }

    static func stored(_ hidden: Set<ToolbarItemChoice>) -> String {
        allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }
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
    /// PencilKit's on-canvas ruler. Session only: never persisted, so a
    /// fresh launch starts without a ruler in the way.
    var rulerActive: Bool = false

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


// MARK: - Palette, recents and quick sizes (pure, tested)

/// One named colour in the pen's swatch grid.
nonisolated struct InkSwatch: Identifiable, Equatable, Sendable {
    let hex: String
    let name: String
    var id: String { hex }
}

/// The swatch colours, and the rules for "which one is selected" and "which
/// custom colours were used lately". Everything here works on hex strings,
/// the same form `Color.toHex()` and `PenPreset` persist, so a custom colour
/// that happens to equal a swatch shows that swatch selected - `Color`
/// equality never matched across a round trip through hex.
nonisolated enum InkPalette {
    /// The first eight are the toolbar's original swatches (system colours
    /// in their light appearance, as hex so they are fixed), then a grey
    /// and a teal.
    static let swatches: [InkSwatch] = [
        InkSwatch(hex: "#000000", name: "Black"),
        InkSwatch(hex: "#8E8E93", name: "Grey"),
        InkSwatch(hex: "#FF3B30", name: "Red"),
        InkSwatch(hex: "#FF9500", name: "Orange"),
        InkSwatch(hex: "#FFCC00", name: "Yellow"),
        InkSwatch(hex: "#34C759", name: "Green"),
        InkSwatch(hex: "#30B0C7", name: "Teal"),
        InkSwatch(hex: "#007AFF", name: "Blue"),
        InkSwatch(hex: "#AF52DE", name: "Purple"),
        InkSwatch(hex: "#A2845E", name: "Brown"),
    ]

    static let recentLimit = 5

    /// "#rrggbb", upper case, whatever form it came in.
    static func normalized(_ hex: String) -> String {
        "#" + hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
    }

    static func isSelected(swatchHex: String, currentHex: String) -> Bool {
        normalized(swatchHex) == normalized(currentHex)
    }

    static func isSwatch(_ hex: String) -> Bool {
        swatches.contains { isSelected(swatchHex: $0.hex, currentHex: hex) }
    }

    static func name(for hex: String) -> String? {
        swatches.first { isSelected(swatchHex: $0.hex, currentHex: hex) }?.name
    }

    private static func isValid(_ hex: String) -> Bool {
        let h = normalized(hex)
        return h.count == 7 && h.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// `list` with `hex` moved to the front: no duplicates, capped. A colour
    /// that is one of the swatches is not "custom" and is left out.
    static func addingRecent(_ hex: String, to list: [String], limit: Int = recentLimit) -> [String] {
        let h = normalized(hex)
        guard isValid(h), !isSwatch(h) else { return Array(list.prefix(limit)) }
        var out = list.map(normalized).filter { $0 != h }
        out.insert(h, at: 0)
        return Array(out.prefix(limit))
    }

    /// Stored in `@AppStorage` as a comma-separated list, newest first.
    static func decodeRecents(_ stored: String, limit: Int = recentLimit) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in stored.split(separator: ",") {
            let h = normalized(String(part))
            if isValid(h), seen.insert(h).inserted { out.append(h) }
        }
        return Array(out.prefix(limit))
    }

    static func encodeRecents(_ list: [String]) -> String {
        list.map(normalized).joined(separator: ",")
    }

    static let recentsKey = "recentInkColors"
}

/// Thin / medium / thick shortcuts, derived from the tool's own slider range
/// so they can never fall outside it.
nonisolated enum QuickWidth {
    static let fractions: [Double] = [0.15, 0.4, 0.75]
    static let names = ["Thin", "Medium", "Thick"]

    static func values(in range: ClosedRange<Double>) -> [Double] {
        let span = range.upperBound - range.lowerBound
        return fractions.map { fraction in
            let raw = range.lowerBound + span * fraction
            let halfPoints = (raw * 2).rounded() / 2
            return min(max(halfPoints, range.lowerBound), range.upperBound)
        }
    }

    /// Index of the quick size `width` is at (within half a point), if any.
    static func index(of width: Double, in range: ClosedRange<Double>) -> Int? {
        values(in: range).firstIndex { abs($0 - width) < 0.5 }
    }
}

// MARK: - Option building blocks

/// A sample stroke - a gentle S - at the width and colour about to be
/// drawn with. Used big in the preview and small in preset chips.
private struct SampleStroke: View {
    var color: Color
    var lineWidth: CGFloat
    var opacity: Double = 1

    var body: some View {
        Canvas { context, size in
            let inset = max(lineWidth / 2, 2) + 6
            let w = size.width - inset * 2
            let h = size.height
            guard w > 0 else { return }
            var path = Path()
            path.move(to: CGPoint(x: inset, y: h * 0.5))
            path.addCurve(to: CGPoint(x: inset + w * 0.5, y: h * 0.5),
                          control1: CGPoint(x: inset + w * 0.15, y: h * 0.12),
                          control2: CGPoint(x: inset + w * 0.35, y: h * 0.12))
            path.addCurve(to: CGPoint(x: inset + w, y: h * 0.5),
                          control1: CGPoint(x: inset + w * 0.65, y: h * 0.88),
                          control2: CGPoint(x: inset + w * 0.85, y: h * 0.88))
            context.stroke(path, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: min(lineWidth, h * 0.6), lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The paper-coloured well the preview and preset chips sit on. Pages are
/// white whatever the system appearance, so the sample is too.
private struct PaperWell<Content: View>: View {
    var height: CGFloat
    var radius: CGFloat = Radius.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Color.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: Metrics.hairline))
    }
}

/// An icon tile with a caption; the selected one has an accent ring.
private struct OptionTile: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Palette.selectionRing : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s)
            .frame(minHeight: Metrics.minHitTarget)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(isSelected ? Palette.selectionRing.opacity(0.12) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(isSelected ? Palette.selectionRing : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Width: three quick sizes, a slider and the value.
private struct WidthSection: View {
    var title: String = "Width"
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        let quick = QuickWidth.values(in: range)
        let selected = QuickWidth.index(of: value, in: range)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                SectionLabel(title)
                Text("\(value, specifier: "%.1f") pt")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Space.s) {
                ForEach(Array(quick.enumerated()), id: \.offset) { index, size in
                    Button {
                        withAnimation(Motion.quick) { value = size }
                    } label: {
                        let diameter = 8 + CGFloat(index) * 6
                        Circle()
                            .fill(Color.primary)
                            .frame(width: diameter, height: diameter)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Metrics.minHitTarget)
                            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .fill(selected == index ? Palette.selectionRing.opacity(0.14) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .strokeBorder(selected == index ? Palette.selectionRing : Color.clear, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(QuickWidth.names[index]) \(title.lowercased()), \(size.formatted(.number.precision(.fractionLength(0...1)))) points")
                    .accessibilityAddTraits(selected == index ? .isSelected : [])
                }
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(0...1)))) points")
        }
    }
}

/// Colour: the swatch grid, a rainbow "+" for any other colour, and the
/// last few custom colours.
private struct ColorSection: View {
    var title: String = "Colour"
    @Binding var selection: Color
    @AppStorage(InkPalette.recentsKey) private var recentStored = ""
    /// A custom colour picked but not yet remembered: ColorPicker reports
    /// every step of a drag, so it is committed once it settles.
    @State private var pendingHex: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        let currentHex = selection.toHex()
        let recents = InkPalette.decodeRecents(recentStored)
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(InkPalette.swatches) { swatch in
                    swatchButton(hex: swatch.hex, name: swatch.name, currentHex: currentHex)
                }
                customPicker(currentHex: currentHex, recents: recents)
            }
            if !recents.isEmpty {
                Text("Recent")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    ForEach(recents, id: \.self) { hex in
                        swatchButton(hex: hex, name: "Recent colour \(hex)", currentHex: currentHex)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: pendingHex) {
            guard let hex = pendingHex else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commit(hex)
        }
        .onDisappear { if let hex = pendingHex { commit(hex) } }
    }

    private func commit(_ hex: String) {
        recentStored = InkPalette.encodeRecents(
            InkPalette.addingRecent(hex, to: InkPalette.decodeRecents(recentStored)))
        pendingHex = nil
    }

    private func swatchButton(hex: String, name: String, currentHex: String) -> some View {
        let isSelected = InkPalette.isSelected(swatchHex: hex, currentHex: currentHex)
        return Button {
            selection = Color(hex: hex)
        } label: {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: Metrics.hairline))
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Palette.selectionRing, lineWidth: 2.5).padding(-5)
                    }
                }
                .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The system colour picker, dressed as a rainbow swatch: the real
    /// control sits on top at near-zero opacity so it still takes the tap.
    private func customPicker(currentHex: String, recents: [String]) -> some View {
        let isCustomSelected = !InkPalette.isSwatch(currentHex) && !recents.contains(InkPalette.normalized(currentHex))
        let binding = Binding<Color>(
            get: { selection },
            set: { selection = $0; pendingHex = $0.toHex() }
        )
        return ZStack {
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 1))
                .overlay {
                    if isCustomSelected {
                        Circle().strokeBorder(Palette.selectionRing, lineWidth: 2.5).padding(-5)
                    }
                }
            ColorPicker("Custom colour", selection: binding, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.6)
                .opacity(0.02)
        }
        .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
        .clipShape(Circle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom colour")
    }
}

private extension Color {
    /// Near-white ink would vanish as an icon tint.
    var isNearWhite: Bool {
        let c = resolve(in: EnvironmentValues())
        return 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.9
    }
}

// MARK: - The toolbar

/// The GoodNotes/Notability-style drawing toolbar - our own custom UI in
/// place of Apple's system `PKToolPicker`. Tapping a tool selects it;
/// tapping the already-selected Pen/Highlighter/Eraser/Fill tool again opens
/// a popover with that tool's options. Undo/redo and the Insert menu live
/// here too, since they're all part of the same "drawing controls" cluster
/// GoodNotes/Notability keep together.
///
/// Two presentations of the same controls:
/// - `.inline` sits in the navigation bar's principal slot, on the row with
///   Play / Pages / + / Save, the way GoodNotes lays its bar out. No
///   background, no drag handle - the bar is the chrome.
/// - `.floating` is the card over the canvas, draggable out of the way.
///   Used where the navigation bar has no room for it (compact width).
struct DrawingToolbarView: View {
    enum Style { case inline, floating }

    var style: Style = .floating
    @Binding var toolState: DrawingToolState
    @AppStorage(AppSettings.Keys.penPresets) private var presetData = Data()
    @AppStorage(AppSettings.Keys.hiddenToolbarItems) private var hiddenItems = ""

    private func shows(_ item: ToolbarItemChoice) -> Bool {
        !ToolbarItemChoice.hidden(in: hiddenItems).contains(item)
    }
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
    /// One tap to Photos, onto the open page.
    var onAddImage: () -> Void = {}
    /// The rest of the Insert menu. nil leaves the row out.
    var onImportFile: (() -> Void)?
    var onPasteImage: (() -> Void)?
    var canPasteImage = false
    var onNewPagesFromFiles: (() -> Void)?
    var onNewPagesFromPhotos: (() -> Void)?
    var onNewPagesScan: (() -> Void)?
    /// Insert > Node...: show a node's ink on this page. nil leaves the row out.
    var onAddNode: (() -> Void)? = nil

    // Lets the whole bar be dragged out of the way instead of sitting fixed
    // over the canvas. Session-only (resets to the default top-center spot
    // next time a page opens) rather than persisted - repositioning is a
    // "get it out of my way right now" action, not a settings-level choice.
    @State private var position: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var barSize: CGSize = .zero

    private static let penWidthRange: ClosedRange<Double> = 1...20
    private static let highlighterWidthRange: ClosedRange<Double> = 8...40
    private static let eraserWidthRange: ClosedRange<Double> = 5...60
    private static let popoverWidth: CGFloat = 320

    var body: some View {
        switch style {
        case .inline:
            controls
        case .floating:
            HStack(spacing: Space.xs) {
                dragHandle
                Divider().frame(height: 24)
                controls
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .surfaceCard(radius: Radius.l)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { barSize = geo.size }
                        .onChange(of: geo.size) { _, new in barSize = new }
                }
            )
            .offset(x: position.width, y: position.height)
            .onChange(of: containerSize) { _, _ in
                // A rotation or a resized window can leave the bar outside
                // the new area; ease it back in.
                let clamped = clampedPosition(position)
                if clamped != position { withAnimation(Motion.snappy) { position = clamped } }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Space.xxs) {
            iconButton("arrow.uturn.backward", label: "Undo", disabled: !canUndo, action: onUndo)
            iconButton("arrow.uturn.forward", label: "Redo", disabled: !canRedo, action: onRedo)

            Divider().frame(height: 24)

            toolButton(.pen, systemImage: "pencil.tip", label: "Pen", tint: toolState.penColor)
            if shows(.highlighter) { toolButton(.highlighter, systemImage: "highlighter", label: "Highlighter", tint: toolState.highlighterColor) }
            toolButton(.eraser, systemImage: "eraser", label: "Eraser")
            if shows(.lasso) { toolButton(.lasso, systemImage: "lasso", label: "Lasso") }
            if shows(.fill) { toolButton(.fill, systemImage: "paintbrush.fill", label: "Fill", disabled: !isFillToolAvailable) }
            // PencilKit's ruler is wired on paged pages only.
            if isTextBoxAvailable { rulerButton }

            if hasInsertMenu {
                Divider().frame(height: 24)
                insertMenu
            }
        }
    }

    /// Imports and scanning live only in this menu, so it stays while
    /// they exist, even with all four page items hidden in Settings.
    private var hasInsertMenu: Bool {
        shows(.textBox) || shows(.sticker) || shows(.image) || shows(.link)
            || onImportFile != nil || onNewPagesFromFiles != nil
    }

    /// One Insert button in place of four icons. Shapes have no button:
    /// draw one and hold the pencil still at the end, and it snaps (see
    /// ShapeHoldRecognizer). Stickers, links, photos and text boxes share
    /// the paged-pages-only rule. The same control in both styles; the
    /// floating card has less room, so it drops the word.
    private var insertMenu: some View {
        Menu {
            Section {
                if shows(.textBox) { Button { onAddTextBox() } label: { Label("Text Box", systemImage: "character.textbox") }.disabled(!isTextBoxAvailable) }
                if shows(.image) { Button { onAddImage() } label: { Label("Photo", systemImage: "photo") }.disabled(!isTextBoxAvailable) }
                if shows(.sticker) { Button { onAddSticker() } label: { Label("Sticker", systemImage: "face.smiling") }.disabled(!isTextBoxAvailable) }
                if shows(.link) { Button { onAddLink() } label: { Label("Link to a Page", systemImage: "link") }.disabled(!isTextBoxAvailable) }
                if let onAddNode { Button { onAddNode() } label: { Label("Node…", systemImage: "scribble") }.disabled(!isTextBoxAvailable) }
                // Not tied to the Photo item: the old Import menu always offered it.
                if let onPasteImage {
                    Button { onPasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                        .disabled(!isTextBoxAvailable || !canPasteImage)
                }
            }
            if onImportFile != nil {
                Divider()
                if let onImportFile { Button { onImportFile() } label: { Label("PDF or Image File", systemImage: "doc") }.disabled(!isTextBoxAvailable) }
            }
            if onNewPagesFromFiles != nil || onNewPagesFromPhotos != nil || onNewPagesScan != nil {
                Section("New Pages") {
                    if let f = onNewPagesFromFiles { Button("From Files", action: f) }
                    if let f = onNewPagesFromPhotos { Button("From Photos", action: f) }
                    if let f = onNewPagesScan { Button("Scan Document", action: f) }
                }
            }
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                if style == .inline {
                    Text("Insert").font(Typography.label)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, style == .inline ? Space.m : 0)
            .frame(minWidth: Metrics.toolButton, minHeight: Metrics.toolButton)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.ink.opacity(0.12)))
            .minimumHitTarget()
        }
        .accessibilityLabel("Insert")
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: Metrics.minHitTarget)
            .contentShape(Rectangle())
            .accessibilityLabel("Move toolbar")
            .accessibilityHint("Drag to reposition the toolbar")
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
    private func toolButton(_ kind: DrawingToolKind, systemImage: String, label: String, tint: Color? = nil, disabled: Bool = false) -> some View {
        let isActive = toolState.activeKind == kind
        Button {
            if isActive {
                // The lasso has no options; an empty popover is worse than none.
                if kind != .lasso { openPopover = kind }
            } else {
                toolState.activeKind = kind
            }
        } label: {
            Image(systemName: systemImage)
                // The colour the tool will draw in, from the same state
                // that builds its PKInkingTool.
                .foregroundStyle(iconColor(tint: tint, isActive: isActive))
                .overlay(alignment: .bottom) {
                    if let tint {
                        Circle().fill(tint).frame(width: 6, height: 6)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.4), lineWidth: Metrics.hairline))
                            .offset(y: 9)
                    }
                }
        }
        .buttonStyle(ToolIconButtonStyle(isSelected: isActive))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .disabled(disabled)
        .popover(isPresented: Binding(
            get: { openPopover == kind },
            set: { if !$0 { openPopover = nil } }
        )) {
            popoverContent(for: kind)
        }
    }

    private func iconColor(tint: Color?, isActive: Bool) -> Color {
        if let tint, !tint.isNearWhite { return tint }
        return isActive ? Color.accentColor : Color.primary
    }

    @ViewBuilder
    /// Toggles PencilKit's ruler. It is not a tool: it stays on while the
    /// pen, highlighter or lasso changes. Hidden on whiteboards
    /// (`isTextBoxAvailable` is false there), whose canvas doesn't apply it.
    private var rulerButton: some View {
        Button {
            toolState.rulerActive.toggle()
        } label: {
            Image(systemName: "ruler")
                .foregroundStyle(toolState.rulerActive ? Palette.ink : Color.primary)
        }
        .buttonStyle(ToolIconButtonStyle(isSelected: toolState.rulerActive))
        .accessibilityLabel("Ruler")
        .accessibilityAddTraits(toolState.rulerActive ? .isSelected : [])
    }

    private func iconButton(_ systemImage: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(ToolIconButtonStyle())
        .accessibilityLabel(label)
        .disabled(disabled)
    }

    // MARK: Popovers

    /// Short content sits at its natural height; tall content scrolls.
    private func popoverContent(for kind: DrawingToolKind) -> some View {
        ViewThatFits(in: .vertical) {
            optionsView(for: kind)
                .padding(Space.l)
                .frame(width: Self.popoverWidth)
            ScrollView {
                optionsView(for: kind)
                    .padding(Space.l)
                    .frame(width: Self.popoverWidth)
            }
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: 560)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func optionsView(for kind: DrawingToolKind) -> some View {
        switch kind {
        case .pen:
            VStack(alignment: .leading, spacing: Space.l) {
                section("Ink") { inkGrid }
                PaperWell(height: 72) {
                    SampleStroke(color: toolState.penColor, lineWidth: toolState.penWidth)
                }
                .accessibilityElement()
                .accessibilityLabel("Preview of the pen at the current width and colour")
                WidthSection(value: $toolState.penWidth, range: Self.penWidthRange)
                ColorSection(selection: $toolState.penColor)
                section("Presets") { presetRow }
                section("Shapes") { shapeStyleRow }
            }
        case .highlighter:
            VStack(alignment: .leading, spacing: Space.l) {
                PaperWell(height: 72) {
                    SampleStroke(color: toolState.highlighterColor, lineWidth: toolState.highlighterWidth, opacity: 0.4)
                }
                .accessibilityElement()
                .accessibilityLabel("Preview of the highlighter at the current width and colour")
                WidthSection(value: $toolState.highlighterWidth, range: Self.highlighterWidthRange)
                ColorSection(selection: $toolState.highlighterColor)
            }
        case .eraser:
            VStack(alignment: .leading, spacing: Space.l) {
                section("Type") {
                    HStack(spacing: Space.s) {
                        OptionTile(symbol: "eraser.line.dashed", title: "Precise",
                                   isSelected: toolState.eraserType == .vector) { toolState.eraserType = .vector }
                        OptionTile(symbol: "eraser", title: "Area",
                                   isSelected: toolState.eraserType == .bitmap) { toolState.eraserType = .bitmap }
                    }
                }
                PaperWell(height: 72) {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
                        .background(Circle().fill(Color.black.opacity(0.06)))
                        .frame(width: min(toolState.eraserWidth, 60), height: min(toolState.eraserWidth, 60))
                }
                .accessibilityElement()
                .accessibilityLabel("Preview of the eraser size")
                WidthSection(value: $toolState.eraserWidth, range: Self.eraserWidthRange)
            }
        case .fill:
            VStack(alignment: .leading, spacing: Space.l) {
                Text("Tap an enclosed area to fill it.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                ColorSection(selection: $toolState.fillColor)
            }
        case .lasso:
            EmptyView()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title)
            content()
        }
    }

    private static let inkOptions: [(type: PKInkingTool.InkType, name: String, symbol: String)] = [
        (.pen, "Pen", "pencil.tip"),
        (.pencil, "Pencil", "pencil"),
        (.marker, "Marker", "paintbrush.pointed"),
        (.fountainPen, "Fountain", "signature"),
        (.monoline, "Monoline", "line.diagonal"),
    ]

    private var inkGrid: some View {
        HStack(spacing: Space.xs) {
            ForEach(Self.inkOptions, id: \.name) { option in
                OptionTile(symbol: option.symbol, title: option.name,
                           isSelected: toolState.penInkType == option.type) {
                    toolState.penInkType = option.type
                }
            }
        }
    }

    // MARK: Presets

    /// Saved pens: tap to use, "Save" to keep the pen as it is, long-press
    /// to remove one.
    private var presetRow: some View {
        let current = PenPreset(toolState)
        return HStack(spacing: Space.s) {
            if presets.count < PenPreset.limit, !presets.contains(current) {
                Button {
                    presets.append(current)
                } label: {
                    Chip(title: "Save", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .frame(minHeight: Metrics.minHitTarget)
                .accessibilityLabel("Save current pen as preset")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(presets, id: \.self) { preset in
                        let isSelected = current == preset
                        Button {
                            preset.apply(to: &toolState)
                        } label: {
                            PaperWell(height: 32, radius: Radius.s) {
                                SampleStroke(color: preset.color, lineWidth: min(max(preset.width * 0.45, 1.5), 8))
                            }
                            .frame(width: 56)
                            .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                                .strokeBorder(isSelected ? Palette.selectionRing : Color.clear, lineWidth: 2))
                            .frame(minHeight: Metrics.minHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                presets.removeAll { $0 == preset }
                            } label: { Label("Remove Preset", systemImage: "trash") }
                        }
                        .accessibilityLabel(presetDescription(preset))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityAction(named: "Remove Preset") {
                            presets.removeAll { $0 == preset }
                        }
                    }
                }
                .padding(.vertical, Space.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presetDescription(_ preset: PenPreset) -> String {
        let ink = Self.inkOptions.first { $0.type.rawValue == preset.inkType }?.name ?? "Pen"
        let colour = InkPalette.name(for: preset.colorHex) ?? preset.colorHex
        return "Pen preset, \(ink), \(colour), \(preset.width.formatted(.number.precision(.fractionLength(0...1)))) points"
    }

    private var presets: [PenPreset] {
        get { PenPreset.decode(presetData) }
        nonmutating set { presetData = PenPreset.encode(newValue) }
    }

    // MARK: Shapes

    /// The line style snapped shapes are drawn in. It lives in the pen
    /// options because that's where the rest of "what my mark looks like"
    /// is, and it's labelled for shapes because freehand ink can't be
    /// dashed - see `ShapeLineStyle`.
    @ViewBuilder
    private var shapeStyleRow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                ForEach(ShapeLineStyle.allCases, id: \.self) { style in
                    let isSelected = toolState.shapeLineStyle == style
                    Button {
                        toolState.shapeLineStyle = style
                    } label: {
                        Canvas { context, size in
                            var path = Path()
                            path.move(to: CGPoint(x: 12, y: size.height / 2))
                            path.addLine(to: CGPoint(x: size.width - 12, y: size.height / 2))
                            context.stroke(path, with: .color(isSelected ? Palette.selectionRing : Color.primary),
                                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: Self.dash(for: style)))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.minHitTarget)
                        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .fill(isSelected ? Palette.selectionRing.opacity(0.12) : Color.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .strokeBorder(isSelected ? Palette.selectionRing : Color.clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(style.label) shape line")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Text("Hold at the end of a stroke to snap a shape.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func dash(for style: ShapeLineStyle) -> [CGFloat] {
        switch style {
        case .solid: return []
        case .dashed: return [7, 6]
        case .dotted: return [0.5, 6]
        }
    }
}
#endif
