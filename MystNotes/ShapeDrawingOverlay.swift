import SwiftUI

/// Transparent gesture-capture layer shown only while "shape mode" is
/// armed. Captures one freehand drag as a raw point path, shows a live
/// preview while dragging, and hands the finished path back to the parent
/// for recognition + insertion as a real PKStroke.
struct ShapeDrawingOverlay: View {
    var onShapeComplete: ([CGPoint]) -> Void

    @State private var currentPoints: [CGPoint] = []

    var body: some View {
        Canvas { context, _ in
            guard currentPoints.count > 1 else { return }
            var path = Path()
            path.move(to: currentPoints[0])
            for point in currentPoints.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    currentPoints.append(value.location)
                }
                .onEnded { _ in
                    let finished = currentPoints
                    currentPoints = []
                    onShapeComplete(finished)
                }
        )
    }
}
