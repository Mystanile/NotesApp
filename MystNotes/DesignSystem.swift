import SwiftUI

/// Linework's design tokens and the handful of shared components built on
/// them (Nov 2, 2026). Before this, every view picked its own sizes: 34 pt
/// buttons here, 26 pt swatches there, three different corner radii for the
/// same kind of card. New UI uses these; old UI moves over as it is touched.
///
/// The rules, kept short on purpose:
/// - Spacing is a 4 pt grid. Pick from `Space`, never a literal.
/// - One radius per size class (`Radius`). Nested shapes use the smaller one.
/// - Colour comes from the asset catalog's accent (indigo) and from `Palette`.
///   Amber is reserved for graph nodes, so a node always reads as a node.
/// - Text uses Dynamic Type styles from `Typography`, never a fixed point size,
///   except glyphs drawn as icons.
/// - Hit targets are at least 44 pt (`Metrics.minHitTarget`), whatever the
///   visible size of the control.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// Swatches, chips, small badges.
    static let s: CGFloat = 8
    /// Buttons, thumbnails, list cells.
    static let m: CGFloat = 12
    /// Cards, popovers, floating bars.
    static let l: CGFloat = 18
    /// Sheets and large panels.
    static let xl: CGFloat = 26
}

enum Metrics {
    static let minHitTarget: CGFloat = 44
    /// Visible size of an icon button in a toolbar.
    static let toolButton: CGFloat = 36
    static let swatch: CGFloat = 28
    static let hairline: CGFloat = 0.5
}

enum Palette {
    /// The brand accent. Same as `Color.accentColor`, named for clarity.
    static let ink = Color.accentColor
    /// Graph nodes and anything that represents a node.
    static let node = Color(red: 1.0, green: 0.71, blue: 0.28)
    /// Paper white from the logo, for marks drawn on the accent.
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.906)
    /// Hairline separators on materials.
    static let separator = Color.primary.opacity(0.08)
    /// Selection ring around a chosen swatch or card.
    static let selectionRing = Color.accentColor
    /// Edge colours in the graph, by link kind.
    static let edgeExplicit = Color.accentColor
    static let edgeMention = Color.accentColor.opacity(0.55)
    static let edgeTag = Color.secondary.opacity(0.5)
}

enum Typography {
    static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title = Font.system(.title2, design: .rounded).weight(.semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let caption = Font.caption
    static let label = Font.subheadline.weight(.medium)
    static let mono = Font.system(.caption, design: .monospaced)
}

enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.15)
}

// MARK: - Shared components

/// A raised surface: a material fill, a hairline edge and a soft shadow.
/// Use for floating bars, popovers' inner groups and graph cards.
struct SurfaceCard: ViewModifier {
    var radius: CGFloat = Radius.l
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
            )
            .shadow(color: .black.opacity(elevated ? 0.12 : 0), radius: elevated ? 14 : 0, y: elevated ? 6 : 0)
    }
}

extension View {
    func surfaceCard(radius: CGFloat = Radius.l, elevated: Bool = true) -> some View {
        modifier(SurfaceCard(radius: radius, elevated: elevated))
    }

    /// Grows the tappable area to the 44 pt minimum without changing layout.
    func minimumHitTarget() -> some View {
        frame(minWidth: Metrics.minHitTarget, minHeight: Metrics.minHitTarget)
            .contentShape(Rectangle())
    }
}

/// A toolbar icon button: a fixed visible size, a tinted fill when selected,
/// a 44 pt hit target, and the system's disabled look (no hand-rolled
/// opacity).
struct ToolIconButtonStyle: ButtonStyle {
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ToolIconButtonBody(configuration: configuration, isSelected: isSelected)
    }

    private struct ToolIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: Metrics.toolButton, height: Metrics.toolButton)
                .background(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? 1 : 0.3)
                .animation(Motion.quick, value: configuration.isPressed)
                .minimumHitTarget()
        }
    }
}

/// A rounded pill used for filters, presets and tags.
struct Chip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: Space.xs) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title).lineLimit(1)
        }
        .font(Typography.label)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs + 2)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? tint : Color.primary.opacity(0.06))
        )
        .contentShape(Capsule())
    }
}

/// A section label in popovers and panels: small caps, secondary colour.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Linework mark drawn in SwiftUI, for places where the bitmap asset
/// would blur (large onboarding art) or needs to follow the accent colour.
/// Same geometry as `Docs/brand/logo.svg`, in a 1024 pt box.
struct BrandMarkShape: View {
    var lineColor: Color = Palette.paper
    var nodeColor: Color = Palette.node

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height) / 1024
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 742 * s, y: 372 * s))
                    p.addLine(to: CGPoint(x: 768 * s, y: 700 * s))
                    p.move(to: CGPoint(x: 292 * s, y: 702 * s))
                    p.addLine(to: CGPoint(x: 768 * s, y: 700 * s))
                }
                .stroke(lineColor.opacity(0.38), style: StrokeStyle(lineWidth: 14 * s, lineCap: .round))

                Path { p in
                    p.move(to: CGPoint(x: 292 * s, y: 702 * s))
                    p.addCurve(to: CGPoint(x: 532 * s, y: 470 * s),
                               control1: CGPoint(x: 392 * s, y: 668 * s), control2: CGPoint(x: 478 * s, y: 590 * s))
                    p.addCurve(to: CGPoint(x: 500 * s, y: 268 * s),
                               control1: CGPoint(x: 578 * s, y: 368 * s), control2: CGPoint(x: 566 * s, y: 262 * s))
                    p.addCurve(to: CGPoint(x: 506 * s, y: 482 * s),
                               control1: CGPoint(x: 432 * s, y: 274 * s), control2: CGPoint(x: 436 * s, y: 398 * s))
                    p.addCurve(to: CGPoint(x: 742 * s, y: 372 * s),
                               control1: CGPoint(x: 576 * s, y: 566 * s), control2: CGPoint(x: 664 * s, y: 476 * s))
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 46 * s, lineCap: .round, lineJoin: .round))

                Circle().fill(nodeColor).frame(width: 104 * s, height: 104 * s).position(x: 292 * s, y: 702 * s)
                Circle().fill(nodeColor).frame(width: 104 * s, height: 104 * s).position(x: 742 * s, y: 372 * s)
                Circle().fill(lineColor).frame(width: 68 * s, height: 68 * s).position(x: 768 * s, y: 700 * s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
