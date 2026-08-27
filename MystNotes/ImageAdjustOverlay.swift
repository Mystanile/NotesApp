import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit

/// Move/resize handles for an imported PDF page or photo placed on a page.
/// Shown while "adjust image" mode is active - right after importing onto
/// an existing page, and again whenever the artwork is long-pressed. The
/// page's ink is untouched underneath; only the artwork's frame changes.
///
/// The canvas has its own touch handling, so this sits above it and the
/// parent disables canvas interaction while it's up (the same approach
/// ShapeDrawingOverlay and the fill tool already use).
struct ImageAdjustOverlay: View {
    @Binding var frame: CGRect
    var containerSize: CGSize
    var onDone: () -> Void

    private let minimumSide: CGFloat = 60
    private let handleSize: CGFloat = 28

    @State private var dragStartFrame: CGRect?
    @State private var resizeStartFrame: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim everything outside the artwork so what's being adjusted
            // reads clearly against the rest of the page.
            Color.black.opacity(0.25)
                .allowsHitTesting(false)
                .mask {
                    ZStack {
                        Rectangle()
                        Rectangle()
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }

            selectionRectangle
            doneButton
        }
        .contentShape(Rectangle())
    }

    private var selectionRectangle: some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .gesture(moveGesture)
            .overlay(alignment: .topLeading) {
                resizeHandle
                    .offset(
                        x: frame.minX + frame.width - handleSize / 2,
                        y: frame.minY + frame.height - handleSize / 2
                    )
            }
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartFrame ?? frame
                if dragStartFrame == nil { dragStartFrame = frame }
                // Keep at least a corner on the page so artwork can't be
                // dragged somewhere it can't be grabbed again.
                let x = clamp(start.minX + value.translation.width,
                              min: -start.width + minimumSide,
                              max: containerSize.width - minimumSide)
                let y = clamp(start.minY + value.translation.height,
                              min: -start.height + minimumSide,
                              max: containerSize.height - minimumSide)
                frame.origin = CGPoint(x: x, y: y)
            }
            .onEnded { _ in dragStartFrame = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = resizeStartFrame ?? frame
                if resizeStartFrame == nil { resizeStartFrame = frame }
                frame.size = CGSize(
                    width: max(start.width + value.translation.width, minimumSide),
                    height: max(start.height + value.translation.height, minimumSide)
                )
            }
            .onEnded { _ in resizeStartFrame = nil }
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}
#endif
