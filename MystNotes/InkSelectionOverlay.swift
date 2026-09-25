import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)

/// What the lasso shows: the loop as it's drawn, and the selection's box
/// once there is one. Drawn in page space inside a `PageViewportLayer`,
/// like the shape preview, and never hit-tested - the gestures live on the
/// canvas host (`InkSelectionController`), where they can share touches
/// with the Pencil.
struct InkSelectionOverlay: View {
    var display: InkSelectionDisplay
    /// The canvas zoom the overlay is drawn through, so line widths and
    /// dashes stay the same size on screen at any magnification.
    var scale: CGFloat

    private var zoom: CGFloat { scale > 0.0001 ? scale : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if display.lasso.count > 1 {
                Path { path in path.addLines(display.lasso) }
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 1.5 / zoom, lineCap: .round, lineJoin: .round,
                                               dash: [6 / zoom, 4 / zoom]))
            }
            if let corners = display.corners, corners.count == 4 {
                let box = Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                box.fill(Color.accentColor.opacity(0.08))
                box.stroke(Color.accentColor,
                           style: StrokeStyle(lineWidth: 1.5 / zoom, lineJoin: .round, dash: [6 / zoom, 4 / zoom]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The controls that appear while ink is selected. Styled like
/// `ImageAdjustToolbar` so the two read as the same family of UI.
struct InkSelectionToolbar: View {
    var canPaste: Bool
    var onCut: () -> Void
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onRecolor: (Color) -> Void = { _ in }
    var onCopyAsImage: () -> Void = {}
    var onConvertToText: () -> Void = {}
    var onDone: () -> Void

    private let colors: [Color] = [.black, .red, .orange, .yellow, .green, .blue, .purple, .brown]

    var body: some View {
        HStack(spacing: 4) {
            iconButton("scissors", help: "Cut", action: onCut)
            iconButton("doc.on.doc", help: "Copy", action: onCopy)
            iconButton("doc.on.clipboard", help: "Paste", action: onPaste)
                .disabled(!canPaste)
                .opacity(canPaste ? 1 : 0.4)
            iconButton("plus.square.on.square", help: "Duplicate", action: onDuplicate)
            Divider().frame(height: 24)
            Menu {
                ForEach(colors, id: \.self) { color in
                    Button { onRecolor(color) } label: {
                        Label { Text(color.description.capitalized) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(color)
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette").font(.system(size: 17)).frame(width: 36, height: 34)
            }
            .help("Colour")
            iconButton("photo", help: "Copy as Image", action: onCopyAsImage)
            iconButton("character.textbox", help: "Convert to Text", action: onConvertToText)
            Divider().frame(height: 24)
            iconButton("trash", help: "Delete", isDestructive: true, action: onDelete)
            Divider().frame(height: 24)
            Button(action: onDone) {
                Label("Done", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .frame(width: 34, height: 34)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
