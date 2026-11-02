import SwiftUI
#if canImport(UIKit)
import UIKit
import PencilKit
#endif

/// What a search result tells the page it opens: which page, what was
/// searched for, and (when known) where the match is in page coordinates.
struct SearchHighlight: Hashable, Sendable {
    let pageID: UUID
    let query: String
    /// Page (drawing) coordinates, top-left origin. Nil when the match has no
    /// known position (PDF text, a title or tag match).
    let rect: CGRect?
    /// The result row's snippet, shown when there is no ink to magnify.
    let snippet: String
}

/// Pure layout helpers, kept out of the view so they can be tested.
nonisolated enum SearchLensLayout {
    /// The part of the page the lens magnifies: the match with some context
    /// around it, never smaller than `minimum` and never larger than
    /// `maximum`, centred on the match.
    static func region(for rect: CGRect,
                       minimum: CGSize = CGSize(width: 120, height: 60),
                       maximum: CGSize = CGSize(width: 240, height: 120)) -> CGRect {
        let padded = rect.insetBy(dx: -24, dy: -18)
        let width = min(max(padded.width, minimum.width), maximum.width)
        let height = min(max(padded.height, minimum.height), maximum.height)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// A Quick Look / dictionary-style callout for a search hit: a floating card
/// that pops in over the page it opened on, showing the matched region of the
/// ink magnified with the match highlighted, the query, and the page number.
///
/// It appears once the page has laid out (`viewport.hasSynced`), fades after
/// 8 seconds or from its close button, and stays gone if
/// you turn the page away and back.
///
/// Placement: the card is centred in the detail view. The detail view's
/// canvas sits beside the page sidebar and under the navigation bar, and this
/// overlay is attached to the whole view, so the page-to-screen mapping
/// (`CanvasViewport`) is offset by an amount this overlay cannot know; a
/// card "near the match" could land on the wrong spot. Centring is always
/// right. `SearchHighlightPulse` below is the on-page marker, ready to be
/// attached to `canvasSection(for:)` where the viewport's origin is the
/// canvas's own; it is not wired in because that code was out of scope.
///
/// No tap-outside catcher (removed Nov 2, 2026): one would swallow the first
/// Pencil touch on the page. The card goes on its own after 8 s or from its
/// close button, and only the card itself takes touches.
struct SearchHighlightLens: View {
    let highlight: SearchHighlight
    let currentPageID: UUID
    let pageNumber: Int
    var viewport: CanvasViewport

    private enum Phase { case waiting, shown, dismissed }

    @State private var phase: Phase = .waiting
    @State private var region: CGRect?
    @State private var matchRect: CGRect?
#if canImport(UIKit)
    @State private var image: UIImage?
#endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cardWidth: CGFloat = 340
    private let autoDismiss: Duration = .seconds(8)

    /// The target page is on screen and has laid out.
    private var isReady: Bool {
        currentPageID == highlight.pageID && viewport.hasSynced && phase != .dismissed
    }

    var body: some View {
        ZStack {
            if phase != .waiting {
                card
                    .opacity(phase == .shown ? 1 : 0)
                    .scaleEffect(phase == .shown || reduceMotion ? 1 : 0.9)
                    .allowsHitTesting(phase == .shown)
                    .accessibilityHidden(phase != .shown)
            }
        }
        .task(id: isReady) {
            guard isReady else { return }
            if phase == .waiting { await prepare() }
            guard !Task.isCancelled, phase != .dismissed else { return }
            withAnimation(Motion.snappy) { phase = .shown }
            try? await Task.sleep(for: autoDismiss)
            guard !Task.isCancelled else { return }
            dismiss()
        }
        .onChange(of: currentPageID) { old, new in
            if old == highlight.pageID, new != highlight.pageID { phase = .dismissed }
        }
    }

    private func dismiss() {
        withAnimation(Motion.gentle) { phase = .dismissed }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(highlight.query)
                        .font(Typography.headline)
                        .lineLimit(1)
                    Text("Page \(pageNumber)")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .minimumHitTarget()
                }
                .buttonStyle(.plain)
                .padding(-Space.s)
                .accessibilityLabel("Close")
            }
            magnified
        }
        .padding(Space.m)
        .frame(width: cardWidth)
        .surfaceCard()
    }

    @ViewBuilder
    private var magnified: some View {
#if canImport(UIKit)
        if let image, let region {
            let inner = cardWidth - 2 * Space.m
            let mag = min(2, inner / region.width)
            let size = CGSize(width: region.width * mag, height: region.height * mag)
            ZStack(alignment: .topLeading) {
                Color.white
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                if let matchRect {
                    let local = matchRect.offsetBy(dx: -region.minX, dy: -region.minY)
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .fill(Color(red: 1.0, green: 0.92, blue: 0.2).opacity(0.5))
                        .blendMode(.multiply)
                        .frame(width: local.width * mag, height: local.height * mag)
                        .offset(x: local.minX * mag, y: local.minY * mag)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        } else if !highlight.snippet.isEmpty {
            snippetText
        }
#else
        if !highlight.snippet.isEmpty { snippetText }
#endif
    }

    private var snippetText: some View {
        Text(highlight.snippet)
            .font(Typography.body)
            .foregroundStyle(.primary)
            .lineLimit(4)
    }

    // MARK: - Resolving the match

    /// Finds where the match is (the result's rect, else the cached or
    /// freshly recognized handwriting line) and renders the region around it.
    /// All file and Vision work is off the main actor.
    private func prepare() async {
        var rect = highlight.rect
#if canImport(UIKit)
        if rect == nil,
           let lines = await RecognizedLinesStore.lines(forPageID: highlight.pageID) {
            rect = RecognizedGeometry.line(matching: highlight.query, in: lines)?.rect
        }
        guard !Task.isCancelled else { return }
        matchRect = rect
        if let rect {
            let area = SearchLensLayout.region(for: rect)
            let rendered = await Self.renderInk(pageID: highlight.pageID, region: area)
            guard !Task.isCancelled else { return }
            region = area
            image = rendered
        }
#else
        matchRect = rect
#endif
    }

#if canImport(UIKit)
    /// The page's ink in `region`, rendered at 4x (the card shows it at up to
    /// 2x on a 2x screen). Nil when there is no ink there. On the ink render
    /// queue and under the light trait, as every off-screen ink render is.
    nonisolated private static func renderInk(pageID: UUID, region: CGRect) async -> UIImage? {
        // Load and decode first, on the pool: only the render itself goes
        // through the queue (a decode inside it would hold it up).
        let loaded = await Task.detached(priority: .userInitiated) {
            DrawingStore.live.load(pageID: pageID)
        }.value
        guard let drawing = loaded,
              drawing.strokes.contains(where: { $0.renderBounds.intersects(region) }) else { return nil }
        return await InkRenderQueue.run {
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: region, scale: 4)
            }
            return image
        }
    }
#endif
}

/// The soft pulsing rectangle over the match on the page itself, drawn in page
/// coordinates through the canvas's live pan/zoom (`PageViewportLayer`).
/// Attach as an overlay on the canvas section, where the viewport's origin is
/// the canvas's own. Not attached yet - see `SearchHighlightLens`.
struct SearchHighlightPulse: View {
    let rect: CGRect
    let pageSize: CGSize
    var viewport: CanvasViewport

    @State private var bright = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(Color(red: 1.0, green: 0.92, blue: 0.2).opacity(bright ? 0.5 : 0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(bright ? 0.8 : 0.3), lineWidth: 2)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { bright = true; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

extension NotebookDetailView {
    /// The search-hit lens for the page this view was opened on. Empty when
    /// the view wasn't opened from a search result.
    @ViewBuilder
    var searchHighlightOverlay: some View {
        if let highlight, let page = currentPage {
            SearchHighlightLens(highlight: highlight, currentPageID: page.id,
                                pageNumber: currentPageIndex + 1, viewport: viewport)
        }
    }
}
