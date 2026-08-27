import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit

/// Selection handles for imported artwork placed on a page, modelled on
/// Google Docs / Freeform: the border hugs the image itself, four corner
/// handles resize it proportionally from the opposite corner, and dragging
/// anywhere inside moves it. Tapping off the image finishes.
///
/// `frame` is the artwork's real on-page rect (the image is drawn to fill
/// it exactly), which is what lets the border sit right on the artwork
/// instead of around a larger box.
struct ImageAdjustOverlay: View {
    @Binding var frame: CGRect
    var containerSize: CGSize
    var onDone: () -> Void

    private let minimumSide: CGFloat = 40
    private let handleDiameter: CGFloat = 18

    private enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    @State private var gestureStartFrame: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tapping anywhere off the artwork commits the placement, the
            // way clicking away from an image deselects it elsewhere.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDone() }

            border
            ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                handle(for: corner)
            }

            // Tapping away also finishes, but that has no visible
            // affordance - keep an explicit exit so adjust mode can't feel
            // like a trap. Bottom-trailing stays clear of the drawing
            // toolbar at the top of the canvas.
            Button("Done", action: onDone)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .gesture(moveGesture)
    }

    private func handle(for corner: Corner) -> some View {
        let point = position(of: corner, in: frame)
        return Circle()
            .fill(.white)
            .overlay { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) }
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .frame(width: handleDiameter, height: handleDiameter)
            // Generous hit area so a finger can actually catch the corner.
            .contentShape(Rectangle().inset(by: -12))
            .offset(x: point.x - handleDiameter / 2, y: point.y - handleDiameter / 2)
            .gesture(resizeGesture(from: corner))
    }

    private func position(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeading:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = gestureStartFrame ?? frame
                if gestureStartFrame == nil { gestureStartFrame = frame }
                // Keep a grabbable sliver on the page at all times.
                frame.origin = CGPoint(
                    x: clamp(start.minX + value.translation.width,
                             -start.width + minimumSide, containerSize.width - minimumSide),
                    y: clamp(start.minY + value.translation.height,
                             -start.height + minimumSide, containerSize.height - minimumSide)
                )
            }
            .onEnded { _ in gestureStartFrame = nil }
    }

    /// Proportional resize anchored on the opposite corner, so the artwork
    /// keeps its aspect ratio and the corner you aren't dragging stays put.
    private func resizeGesture(from corner: Corner) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = gestureStartFrame ?? frame
                if gestureStartFrame == nil { gestureStartFrame = frame }
                guard start.width > 0, start.height > 0 else { return }
                let aspect = start.width / start.height

                // Width is the driver; height follows from the aspect ratio.
                let widthDelta: CGFloat
                switch corner {
                case .topTrailing, .bottomTrailing: widthDelta = value.translation.width
                case .topLeading, .bottomLeading:   widthDelta = -value.translation.width
                }
                // Floor the width such that the *height* also clears the
                // minimum - clamping the two independently would break the
                // aspect ratio at the smallest sizes (a 2:1 image squashing
                // to a square as it bottoms out).
                let minWidth = max(minimumSide, minimumSide * aspect)
                let width = max(start.width + widthDelta, minWidth)
                let height = width / aspect

                // Pin the opposite corner.
                let x: CGFloat
                let y: CGFloat
                switch corner {
                case .bottomTrailing: x = start.minX;          y = start.minY
                case .bottomLeading:  x = start.maxX - width;  y = start.minY
                case .topTrailing:    x = start.minX;          y = start.maxY - height
                case .topLeading:     x = start.maxX - width;  y = start.maxY - height
                }
                frame = CGRect(x: x, y: y, width: width, height: height)
            }
            .onEnded { _ in gestureStartFrame = nil }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}
#endif
