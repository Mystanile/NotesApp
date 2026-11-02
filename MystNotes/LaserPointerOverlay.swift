import SwiftUI

/// Laser pointer for Present mode (Nov 2, 2026). A transparent layer over
/// the page that follows a finger or the Pencil with a glowing red trail
/// fading over `LaserTrail.lifetime`. It is a view-only effect: nothing is
/// added to the drawing, nothing is saved, and because it sits above the
/// canvas and takes every touch, the canvas cannot be drawn on while it is
/// on. The timeline only runs while there are points to fade, so an idle
/// laser costs nothing.
struct LaserPointerOverlay: View {
    @State private var trail = LaserTrail()
    @State private var cleanup: Task<Void, Never>?

    var body: some View {
        ZStack {
            // The hit-testing surface: always present, so touches never
            // fall through to the canvas.
            Color.clear.contentShape(Rectangle())

            if !trail.points.isEmpty {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        LaserTrail.draw(trail.points, now: timeline.date.timeIntervalSinceReferenceDate,
                                        in: &context)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    trail.add(value.location, at: Date().timeIntervalSinceReferenceDate)
                    scheduleCleanup()
                }
                .onEnded { _ in
                    trail.endStroke()
                    scheduleCleanup()
                }
        )
        .accessibilityLabel("Laser pointer")
        .onDisappear { cleanup?.cancel() }
    }

    /// Empties the trail once it has faded, which stops the timeline. A
    /// newer touch replaces the pending cleanup.
    private func scheduleCleanup() {
        cleanup?.cancel()
        cleanup = Task {
            try? await Task.sleep(nanoseconds: UInt64((LaserTrail.lifetime + 0.1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            trail.removeAll()
        }
    }
}

/// The points of a laser trail and how they are drawn. Plain values; the
/// time is passed in, so it can be tested.
struct LaserTrail: Equatable {
    static let lifetime: TimeInterval = 0.8

    struct Point: Equatable {
        var location: CGPoint
        var time: TimeInterval
        /// True for the first point after a lift, so no line joins two touches.
        var startsStroke: Bool
    }

    private(set) var points: [Point] = []
    private var nextStartsStroke = true

    mutating func add(_ location: CGPoint, at time: TimeInterval) {
        points.removeAll { time - $0.time > Self.lifetime }
        points.append(Point(location: location, time: time, startsStroke: nextStartsStroke))
        nextStartsStroke = false
    }

    mutating func endStroke() { nextStartsStroke = true }

    mutating func removeAll() {
        points.removeAll()
        nextStartsStroke = true
    }

    /// 1 for a point just made, 0 once it is `lifetime` old.
    static func opacity(age: TimeInterval) -> Double {
        max(0, min(1, 1 - age / lifetime))
    }

    static func draw(_ points: [Point], now: TimeInterval, in context: inout GraphicsContext) {
        guard let last = points.last else { return }
        for (previous, point) in zip(points, points.dropFirst()) where !point.startsStroke {
            let alpha = opacity(age: now - point.time)
            guard alpha > 0 else { continue }
            var path = Path()
            path.move(to: previous.location)
            path.addLine(to: point.location)
            context.stroke(path, with: .color(.red.opacity(alpha * 0.25)),
                           style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.red.opacity(alpha * 0.55)),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(alpha * 0.9)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        // The dot at the head of the trail.
        let alpha = opacity(age: now - last.time)
        guard alpha > 0 else { return }
        for (radius, color) in [(11.0, Color.red.opacity(alpha * 0.35)), (6.0, Color.red.opacity(alpha))] {
            let rect = CGRect(x: last.location.x - radius, y: last.location.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }
}
