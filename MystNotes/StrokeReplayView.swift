import SwiftUI
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
import PencilKit
#endif

// MARK: - Timeline (pure; no UI, no PencilKit)

/// When each stroke of a page appears during a replay. Built once, when the
/// replay is opened, from plain `(creationDate, drawn duration)` pairs, so it
/// is cheap to test and never computed in a view body.
///
/// Strokes play in creation order. Each lasts as long as it took to draw
/// (at least `minimumStrokeDuration`, so a stroke that was dropped in whole,
/// such as a snapped shape, is still seen). The pause between two strokes is
/// kept as it was unless it is longer than `idleThreshold`, in which case it
/// becomes `compressedIdle`: a page written over an hour replays in minutes,
/// not an hour.
nonisolated struct ReplayTimeline: Equatable {
    nonisolated struct Item: Equatable {
        /// Index into the array the timeline was built from.
        var strokeIndex: Int
        /// Seconds in replay time (gaps already compressed).
        var start: Double
        var duration: Double
        var end: Double { start + duration }
    }

    /// What is on screen at one moment: the first `complete` items in full,
    /// and the next one drawn `partialLocalTime` seconds in (nil between strokes).
    nonisolated struct Frame: Equatable {
        var complete: Int
        var partialLocalTime: Double?
    }

    static let idleThreshold: Double = 1.5
    static let compressedIdle: Double = 0.5
    static let minimumStrokeDuration: Double = 0.1

    /// Sorted by creation date; `start` is non-decreasing and items never overlap.
    var items: [Item] = []

    var total: Double { items.last?.end ?? 0 }

    static func build(strokes: [(date: Date, duration: Double)]) -> ReplayTimeline {
        let order = strokes.indices.sorted { a, b in
            strokes[a].date != strokes[b].date ? strokes[a].date < strokes[b].date : a < b
        }
        guard let first = order.first else { return ReplayTimeline() }
        let origin = strokes[first].date
        var items: [Item] = []
        items.reserveCapacity(order.count)
        var realEnd = 0.0   // where the previous stroke ended, in real time
        var cursor = 0.0    // where the previous stroke ended, in replay time
        for index in order {
            let real = strokes[index].date.timeIntervalSince(origin)
            let duration = max(minimumStrokeDuration, strokes[index].duration)
            var gap = real - realEnd
            gap = gap > idleThreshold ? compressedIdle : max(0, gap)
            let start = cursor + gap
            items.append(Item(strokeIndex: index, start: start, duration: duration))
            realEnd = max(realEnd, real + duration)
            cursor = start + duration
        }
        return ReplayTimeline(items: items)
    }

    func frame(at time: Double) -> Frame {
        let t = min(max(time, 0), total)
        // First item whose end is after t (ends are non-decreasing).
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].end <= t { low = mid + 1 } else { high = mid }
        }
        if low < items.count, items[low].start <= t {
            return Frame(complete: low, partialLocalTime: t - items[low].start)
        }
        return Frame(complete: low, partialLocalTime: nil)
    }
}

#if canImport(UIKit)

// MARK: - Truncating a stroke

/// A stroke as it looked `t` seconds after its first point.
nonisolated enum ReplayTruncation {
    /// How many of the path's points were down by `time` (offsets are
    /// non-decreasing, so this is a prefix).
    static func pointCount(in path: PKStrokePath, upTo time: Double) -> Int {
        var count = 0
        for index in 0..<path.count {
            if path[index].timeOffset <= time { count += 1 } else { break }
        }
        return count
    }

    /// The stroke cut to the points with `timeOffset <= time`, or nil when
    /// fewer than two remain (nothing PencilKit would draw).
    static func truncated(_ stroke: PKStroke, upTo time: Double) -> PKStroke? {
        let path = stroke.path
        let count = pointCount(in: path, upTo: time)
        guard count >= 2 else { return nil }
        if count == path.count { return stroke }
        let points = (0..<count).map { path[$0] }
        let cut = PKStrokePath(controlPoints: points, creationDate: path.creationDate)
        return PKStroke(ink: stroke.ink, path: cut, transform: stroke.transform, mask: stroke.mask)
    }

    /// How long a stroke took to draw.
    static func duration(of stroke: PKStroke) -> Double {
        let path = stroke.path
        guard path.count > 0 else { return 0 }
        return max(0, path[path.count - 1].timeOffset - path[0].timeOffset)
    }
}

// MARK: - What the sheet shows

/// Everything the replay needs, computed once at the moment it is opened.
struct ReplaySource: Identifiable {
    let id = UUID()
    /// In replay order.
    let strokes: [PKStroke]
    let timeline: ReplayTimeline
    /// The part of the page coordinate space to fit on screen.
    let contentRect: CGRect

    static func make(drawing: PKDrawing, pageSize: CGSize, isWhiteboard: Bool) -> ReplaySource {
        let source = drawing.strokes
        let timeline = ReplayTimeline.build(strokes: source.map {
            (date: $0.path.creationDate, duration: ReplayTruncation.duration(of: $0))
        })
        let ordered = timeline.items.map { source[$0.strokeIndex] }
        var rect = CGRect(origin: .zero, size: pageSize)
        if isWhiteboard, !drawing.bounds.isEmpty {
            // A 3000pt board: fit the ink, not the board.
            rect = drawing.bounds.insetBy(dx: -40, dy: -40)
            rect = rect.intersection(CGRect(origin: .zero, size: pageSize))
            if rect.isNull || rect.width < 100 || rect.height < 100 { rect = CGRect(origin: .zero, size: pageSize) }
        }
        return ReplaySource(strokes: ordered, timeline: timeline, contentRect: rect)
    }
}

// MARK: - The read-only canvas

/// A canvas nobody can touch, showing the first `complete` strokes and a
/// partly drawn next one. It rebuilds its drawing only when what is visible
/// changes (a stroke finished, or the partial stroke gained points).
final class ReplayCanvasView: PKCanvasView {
    var contentRect: CGRect = .zero {
        didSet { if contentRect != oldValue { setNeedsLayout() } }
    }
    private var base = PKDrawing()
    private var baseCount = 0
    private var lastKey: (complete: Int, partialPoints: Int)?
    private var fittedSize: CGSize = .zero
    private var fittedRect: CGRect = .zero

    func show(strokes: [PKStroke], complete: Int, localTime: Double?) {
        let complete = min(max(complete, 0), strokes.count)
        var partial: PKStroke?
        if let localTime, complete < strokes.count {
            partial = ReplayTruncation.truncated(strokes[complete], upTo: localTime)
        }
        let key = (complete: complete, partialPoints: partial?.path.count ?? 0)
        if let lastKey, lastKey == key { return }
        lastKey = key
        if baseCount != complete {
            if complete == baseCount + 1 {
                base.strokes.append(strokes[complete - 1])
            } else {
                base = PKDrawing(strokes: Array(strokes.prefix(complete)))
            }
            baseCount = complete
        }
        var next = base
        if let partial { next.strokes.append(partial) }
        drawing = next
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, contentRect.width > 0, contentRect.height > 0,
              bounds.size != fittedSize || contentRect != fittedRect else { return }
        fittedSize = bounds.size
        fittedRect = contentRect
        let scale = PageGeometry.fitScale(contentSize: contentRect.size, in: bounds.size)
        contentSize = CGSize(width: contentRect.maxX, height: contentRect.maxY)
        minimumZoomScale = scale
        maximumZoomScale = scale
        zoomScale = scale
        contentOffset = CGPoint(
            x: contentRect.minX * scale - (bounds.width - contentRect.width * scale) / 2,
            y: contentRect.minY * scale - (bounds.height - contentRect.height * scale) / 2)
    }
}

struct ReplayCanvas: UIViewRepresentable {
    var strokes: [PKStroke]
    var contentRect: CGRect
    var frame: ReplayTimeline.Frame

    func makeUIView(context: Context) -> ReplayCanvasView {
        let view = ReplayCanvasView()
        view.drawingPolicy = .anonymous
        view.isUserInteractionEnabled = false
        view.isScrollEnabled = false
        view.overrideUserInterfaceStyle = .light   // ink colours invert in dark mode otherwise
        view.backgroundColor = .white
        view.isOpaque = true
        view.contentRect = contentRect
        return view
    }

    func updateUIView(_ view: ReplayCanvasView, context: Context) {
        if view.contentRect != contentRect { view.contentRect = contentRect }
        view.show(strokes: strokes, complete: frame.complete, localTime: frame.partialLocalTime)
    }
}

// MARK: - The sheet

/// Replays the page's ink stroke by stroke. Read-only: it works on a copy of
/// the strokes and writes nothing to the page.
struct StrokeReplayView: View {
    let source: ReplaySource

    @Environment(\.dismiss) private var dismiss
    /// Replay time at `anchorDate`; while playing, the playhead runs on from there.
    @State private var anchor: Double = 0
    @State private var anchorDate = Date()
    @State private var isPlaying = false
    @State private var speed: Double = 1

    private func playhead(at date: Date) -> Double {
        let value = isPlaying ? anchor + speed * date.timeIntervalSince(anchorDate) : anchor
        return min(max(value, 0), source.timeline.total)
    }

    private func setPlaying(_ playing: Bool, now: Date = Date()) {
        if playing {
            if anchor >= source.timeline.total { anchor = 0 }
        } else {
            anchor = playhead(at: now)
        }
        anchorDate = now
        isPlaying = playing
    }

    private func seek(to time: Double) {
        anchor = min(max(time, 0), source.timeline.total)
        anchorDate = Date()
    }

    private func setSpeed(_ newSpeed: Double) {
        let now = Date()
        anchor = playhead(at: now)
        anchorDate = now
        speed = newSpeed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if source.strokes.isEmpty {
                Text("Nothing has been written on this page yet.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Drawn only while playing; paused, it draws once.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
                    let time = playhead(at: context.date)
                    VStack(spacing: Space.m) {
                        ReplayCanvas(strokes: source.strokes, contentRect: source.contentRect,
                                     frame: source.timeline.frame(at: time))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.s))
                            .padding(.horizontal, Space.l)
                        controls(time: time)
                    }
                    .onChange(of: isPlaying && time >= source.timeline.total) { _, finished in
                        if finished { setPlaying(false, now: context.date) }
                    }
                }
                .padding(.bottom, Space.l)
            }
        }
        .background(Color(uiColor: .systemGray4).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Replay").font(Typography.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(Space.l)
    }

    private func controls(time: Double) -> some View {
        HStack(spacing: Space.m) {
            Button { setPlaying(!isPlaying) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: Metrics.toolButton, height: Metrics.toolButton)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Slider(value: Binding(get: { time }, set: { seek(to: $0) }),
                   in: 0...max(source.timeline.total, 0.01))
                .accessibilityLabel("Replay position")

            Text(Self.clock(time) + " / " + Self.clock(source.timeline.total))
                .font(Typography.mono)
                .foregroundStyle(.secondary)

            Menu {
                ForEach([1.0, 2.0, 4.0], id: \.self) { value in
                    Button {
                        setSpeed(value)
                    } label: {
                        if speed == value {
                            Label("\(Int(value))x", systemImage: "checkmark")
                        } else {
                            Text("\(Int(value))x")
                        }
                    }
                }
            } label: {
                Text("\(Int(speed))x")
                    .font(Typography.label)
                    .frame(minWidth: 36)
            }
            .accessibilityLabel("Speed")
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .surfaceCard()
        .padding(.horizontal, Space.l)
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

#endif
