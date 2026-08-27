import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit

/// Crop handles drawn over the artwork's on-page rect. The crop rect is
/// always kept inside the artwork, and reported back as fractions of the
/// artwork so it can be stored independently of how the image is placed or
/// what size it's rendered at.
///
/// Unlike the placement handles, cropping is deliberately free-form (no
/// aspect lock) - that's the point of a crop.
struct ImageCropOverlay: View {
    /// The artwork's rect on the page, which the crop can't escape.
    var artworkRect: CGRect
    /// Crop rect in page coordinates.
    @Binding var cropRect: CGRect

    private let handleLength: CGFloat = 22
    private let handleThickness: CGFloat = 4
    private let minimumSide: CGFloat = 32

    private enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    @State private var startRect: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimmedOutside
            grid
            ForEach(Array(Corner.allCases.enumerated()), id: \.offset) { _, corner in
                handle(for: corner)
            }
        }
    }

    /// Darkens what the crop is about to discard, which is the main signal
    /// for what cropping will actually do.
    private var dimmedOutside: some View {
        Color.black.opacity(0.45)
            .frame(width: artworkRect.width, height: artworkRect.height)
            .offset(x: artworkRect.minX, y: artworkRect.minY)
            .mask {
                ZStack {
                    Rectangle()
                        .frame(width: artworkRect.width, height: artworkRect.height)
                        .offset(x: artworkRect.minX, y: artworkRect.minY)
                    Rectangle()
                        .frame(width: cropRect.width, height: cropRect.height)
                        .offset(x: cropRect.minX, y: cropRect.minY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .allowsHitTesting(false)
    }

    private var grid: some View {
        ZStack {
            Rectangle().strokeBorder(.white, lineWidth: 1)
            // Rule-of-thirds guides, the familiar cue that this is a crop.
            ForEach(1..<3) { i in
                Rectangle()
                    .fill(.white.opacity(0.5))
                    .frame(width: 0.5)
                    .offset(x: cropRect.width * (CGFloat(i) / 3) - cropRect.width / 2)
                Rectangle()
                    .fill(.white.opacity(0.5))
                    .frame(height: 0.5)
                    .offset(y: cropRect.height * (CGFloat(i) / 3) - cropRect.height / 2)
            }
        }
        .frame(width: cropRect.width, height: cropRect.height)
        .offset(x: cropRect.minX, y: cropRect.minY)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private func handle(for corner: Corner) -> some View {
        let point = position(of: corner)
        return CornerBracket(corner: corner, length: handleLength, thickness: handleThickness)
            .frame(width: handleLength, height: handleLength)
            .contentShape(Rectangle().inset(by: -14))
            .offset(x: point.x - handleLength / 2, y: point.y - handleLength / 2)
            .gesture(resizeGesture(from: corner))
    }

    private func position(of corner: Corner) -> CGPoint {
        switch corner {
        case .topLeading:     return CGPoint(x: cropRect.minX, y: cropRect.minY)
        case .topTrailing:    return CGPoint(x: cropRect.maxX, y: cropRect.minY)
        case .bottomLeading:  return CGPoint(x: cropRect.minX, y: cropRect.maxY)
        case .bottomTrailing: return CGPoint(x: cropRect.maxX, y: cropRect.maxY)
        }
    }

    // MARK: - Gestures

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = startRect ?? cropRect
                if startRect == nil { startRect = cropRect }
                let x = clamp(start.minX + value.translation.width,
                              artworkRect.minX, artworkRect.maxX - start.width)
                let y = clamp(start.minY + value.translation.height,
                              artworkRect.minY, artworkRect.maxY - start.height)
                cropRect = CGRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in startRect = nil }
    }

    private func resizeGesture(from corner: Corner) -> some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                let start = startRect ?? cropRect
                if startRect == nil { startRect = cropRect }

                var minX = start.minX, maxX = start.maxX
                var minY = start.minY, maxY = start.maxY
                switch corner {
                case .topLeading:
                    minX = clamp(start.minX + value.translation.width, artworkRect.minX, maxX - minimumSide)
                    minY = clamp(start.minY + value.translation.height, artworkRect.minY, maxY - minimumSide)
                case .topTrailing:
                    maxX = clamp(start.maxX + value.translation.width, minX + minimumSide, artworkRect.maxX)
                    minY = clamp(start.minY + value.translation.height, artworkRect.minY, maxY - minimumSide)
                case .bottomLeading:
                    minX = clamp(start.minX + value.translation.width, artworkRect.minX, maxX - minimumSide)
                    maxY = clamp(start.maxY + value.translation.height, minY + minimumSide, artworkRect.maxY)
                case .bottomTrailing:
                    maxX = clamp(start.maxX + value.translation.width, minX + minimumSide, artworkRect.maxX)
                    maxY = clamp(start.maxY + value.translation.height, minY + minimumSide, artworkRect.maxY)
                }
                cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in startRect = nil }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), Swift.max(upper, lower))
    }

    /// The two-legged bracket shape used at photo-crop corners.
    private struct CornerBracket: View {
        let corner: Corner
        let length: CGFloat
        let thickness: CGFloat

        var body: some View {
            ZStack(alignment: alignment) {
                Color.clear
                Rectangle().fill(.white).frame(width: length, height: thickness)
                Rectangle().fill(.white).frame(width: thickness, height: length)
            }
            .shadow(color: .black.opacity(0.3), radius: 1)
        }

        private var alignment: Alignment {
            switch corner {
            case .topLeading:     return .topLeading
            case .topTrailing:    return .topTrailing
            case .bottomLeading:  return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            }
        }
    }
}
#endif
