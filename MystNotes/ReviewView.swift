import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
import PencilKit

/// One tape waiting for review, as plain values (no model objects), so the
/// region can be rendered off the main thread.
nonisolated struct ReviewItem: Identifiable, Equatable, Sendable {
    var linkID: UUID
    var pageID: UUID
    var pageNumber: Int
    /// The tape's rectangle, page points.
    var anchor: CGRect
    var pageSize: CGSize

    var id: UUID { linkID }
}

/// The part of a page a review card shows: the tape's rectangle plus 40pt
/// of context all round, kept on the page.
nonisolated enum ReviewRegion {
    static func rect(for item: ReviewItem, margin: CGFloat = 40) -> CGRect {
        let page = CGRect(origin: .zero, size: item.pageSize)
        let wanted = item.anchor.insetBy(dx: -margin, dy: -margin)
        let clipped = page.isEmpty ? wanted : wanted.intersection(page)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return wanted }
        return clipped
    }

    /// The page's ink inside `rect(for:)` on a transparent background, drawn
    /// in the light trait (CLAUDE.md: off-screen ink renders black in dark
    /// mode otherwise). The page's record is read on the ink render queue,
    /// never the cooperative pool, and never on the main thread.
    static func render(_ item: ReviewItem) async -> UIImage? {
        await InkRenderQueue.run {
            guard let drawing = DrawingStore.live.load(pageID: item.pageID) else { return nil }
            let region = Self.rect(for: item)
            let scale = min(2, 2400 / max(region.width, region.height, 1))
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: region, scale: scale)
            }
            return image
        }
    }
}

/// Review: the notebook's due tape, one at a time. The ink around the tape is
/// shown with the strip over the covered part; Show peels it, then the grade
/// (Again / Hard / Good / Easy) reschedules it through `ReviewScheduler` and
/// `Links.setReviewState`. Nothing here edits ink.
struct ReviewView: View {
    let notebookTitle: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The session's queue. Again puts the card back at the end.
    @State private var items: [ReviewItem]
    @State private var position = 0
    @State private var revealed = false
    @State private var image: UIImage?
    @State private var loaded = false
    /// Distinct tapes graded this session.
    @State private var reviewed: Set<UUID> = []

    init(notebookTitle: String, queue: [ReviewItem]) {
        self.notebookTitle = notebookTitle
        _items = State(initialValue: queue)
    }

    private var current: ReviewItem? { items.indices.contains(position) ? items[position] : nil }

    private static let tapeFill = Color(red: 1.0, green: 0.93, blue: 0.62)
    private static let tapeEdge = Color(red: 0.80, green: 0.66, blue: 0.20)

    var body: some View {
        NavigationStack {
            Group {
                if let item = current {
                    card(for: item)
                } else {
                    summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if current != nil {
                    ToolbarItem(placement: .principal) {
                        Text("\(min(position + 1, items.count)) of \(items.count)")
                            .font(Typography.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Card

    private func card(for item: ReviewItem) -> some View {
        VStack(spacing: Space.l) {
            Text("\(notebookTitle) \u{00B7} page \(item.pageNumber)")
                .font(Typography.caption)
                .foregroundStyle(.secondary)

            region(for: item)
                .task(id: item.linkID) {
                    image = nil
                    loaded = false
                    let rendered = await ReviewRegion.render(item)
                    if Task.isCancelled { return }
                    image = rendered
                    loaded = true
                }

            if revealed {
                HStack(spacing: Space.s) {
                    ForEach(ReviewScheduler.Grade.allCases, id: \.self) { grade in
                        Button { self.grade(grade, item: item) } label: {
                            Text(grade.title)
                                .font(Typography.label)
                                .frame(maxWidth: .infinity, minHeight: Metrics.minHitTarget)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(gradeColor(grade))
                    }
                }
            } else {
                Button { withAnimation(Motion.snappy) { revealed = true } } label: {
                    Text("Show")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minHitTarget)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: 640)
    }

    /// The page region on white paper, the tape over its rectangle until shown.
    private func region(for item: ReviewItem) -> some View {
        let rect = ReviewRegion.rect(for: item)
        return ZStack {
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.white)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if loaded {
                Text("No ink to show").font(Typography.caption).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(max(rect.width, 1) / max(rect.height, 1), contentMode: .fit)
        .overlay {
            GeometryReader { geometry in
                let k = geometry.size.width / max(rect.width, 1)
                let tape = CGRect(x: (item.anchor.minX - rect.minX) * k, y: (item.anchor.minY - rect.minY) * k,
                                  width: item.anchor.width * k, height: item.anchor.height * k)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.tapeFill)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Self.tapeEdge.opacity(0.7), lineWidth: 1))
                    .frame(width: tape.width, height: tape.height)
                    .offset(x: tape.minX, y: tape.minY)
                    .opacity(revealed ? 0 : 1)
                    .animation(Motion.quick, value: revealed)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
            .strokeBorder(Palette.separator, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(revealed ? "Page region, tape peeled back" : "Page region, covered by tape")
    }

    private func gradeColor(_ grade: ReviewScheduler.Grade) -> Color {
        switch grade {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }

    // MARK: Grading

    private func grade(_ grade: ReviewScheduler.Grade, item: ReviewItem) {
        let id = item.linkID
        let now = Date()
        let link = (try? modelContext.fetch(FetchDescriptor<Link>(predicate: #Predicate { $0.id == id })))?.first
        if let link {
            let next = ReviewScheduler.next(state: ReviewScheduler.decode(link.reviewState), grade: grade, now: now)
            Links.setReviewState(link, next, in: modelContext, now: now)
        }
        reviewed.insert(id)
        if grade == .again { items.append(item) }
        revealed = false
        position += 1
    }

    // MARK: Summary

    private var summary: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(reviewed.isEmpty ? "Nothing due" : "Done for today")
                .font(Typography.title)
            Text(reviewed.isEmpty
                 ? "Cover ink with Tape from the lasso menu, and it comes back here to be recalled."
                 : "\(reviewed.count) tape\(reviewed.count == 1 ? "" : "s") reviewed.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, Space.s)
        }
        .padding(Space.xl)
    }
}
#endif
