import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit

/// A bounded, shared cache of rendered bitmaps, keyed by a value that
/// describes exactly what the bitmap is.
///
/// Both of the app's on-demand bitmaps - a page's imported artwork and a
/// page's strip thumbnail - had the same three problems, so they share this:
///
///  - **a finished render could be dropped.** Each view rendered into its
///    own `@State`, and a load that no longer matched the view that started
///    it threw the bitmap away. Here a render is always kept, because a
///    correct bitmap for a key is valid no matter who asked for it.
///  - **the same bitmap was rendered repeatedly**, once per view that
///    wanted it and again every time a view was rebuilt. `inFlight` collapses
///    concurrent requests and the cache serves the rest.
///  - **nothing could re-fire a load.** The store is `@Observable`: a render
///    landing re-evaluates every view reading that key, `generation`
///    changes on a purge so their `.task(id:)` runs again, and a body that
///    reads a bitmap the store doesn't have asks for it there and then. No
///    path leaves a view showing nothing when a bitmap exists or could be
///    made.
///
/// Eviction is least-recently-*read*, and never touches anything read in
/// the last moment. Those are the bitmaps on screen. The first version
/// evicted oldest-inserted and told the views: with a strip that needed
/// more than the budget, dropping A to land B re-fired A's view, which
/// dropped B, which re-fired B's view - and the strip cycled forever,
/// one thumbnail visible at a time (seen on the iPad, Sept 19, 2026).
/// Going over budget by what is on screen is the lesser evil.
///
/// Rendering itself happens off the main actor - it decodes ink records and
/// rasterizes PDF pages, neither of which may sit on the drawing path
/// (invariant 10).
@MainActor
@Observable
final class BitmapStore<Request: Hashable & Sendable> {
    /// Runs off the main actor. Returning nil means "nothing to show" and
    /// is not cached, so a file that arrives later can still be rendered.
    typealias Renderer = @Sendable (Request) async -> UIImage?

    /// Changes whenever entries are dropped. Views put it in their `.task`
    /// id so a purge makes them ask again rather than sit on an empty cache.
    private(set) var generation = 0

    private var cache: [Request: UIImage] = [:]
    private var bytes = 0
    /// When each entry was last read (or, until then, inserted). Not
    /// observed: a read from a view body updates it, and observable state
    /// must not change during a body.
    @ObservationIgnored private var lastRead: [Request: TimeInterval] = [:]
    @ObservationIgnored private var inFlight: Set<Request> = []
    /// An entry read this recently is on screen and is never evicted.
    @ObservationIgnored var recentWindow: TimeInterval = 1

    private let byteLimit: Int
    private let render: Renderer

    init(byteLimit: Int, render: @escaping Renderer) {
        self.byteLimit = byteLimit
        self.render = render
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.purge() }
        }
    }

    /// The bitmap for `request`, if it has been rendered. Reading this from
    /// a view body is what subscribes that body to the store - and, if the
    /// bitmap isn't there, what asks for it: a view whose entry was evicted
    /// gets it back the next time it draws, with no task to re-fire.
    func image(for request: Request) -> UIImage? {
        if let image = cache[request] {
            lastRead[request] = Self.now
            return image
        }
        self.request(request)
        return nil
    }

    /// Makes sure `request` is rendered, now or shortly. Idempotent: a
    /// cached or already-running request does nothing, so a view may call
    /// this as often as its task re-runs.
    func request(_ request: Request) {
        guard cache[request] == nil, !inFlight.contains(request) else { return }
        inFlight.insert(request)
        Task { [weak self] in
            guard let render = self?.render else { return }
            let image = await render(request)
            self?.finish(request, image: image)
        }
    }

    /// Cache-only lookup, for a caller that wants to render it itself.
    func contains(_ request: Request) -> Bool { cache[request] != nil }

    private func finish(_ request: Request, image: UIImage?) {
        inFlight.remove(request)
        guard let image else { return }
        if let previous = cache[request] { bytes -= cost(of: previous) }
        cache[request] = image
        lastRead[request] = Self.now
        bytes += cost(of: image)
        evictIfNeeded(keeping: request)
    }

    /// Drops the least recently read entries until the budget is met -
    /// except the one that just landed, and entries read within
    /// `recentWindow`, which are on screen. If everything is on screen,
    /// the budget is exceeded and nothing is dropped: dropping one would
    /// only have it asked for again.
    private func evictIfNeeded(keeping landed: Request) {
        guard bytes > byteLimit else { return }
        let cutoff = Self.now - recentWindow
        let evictable = lastRead
            .filter { $0.key != landed && $0.value < cutoff && cache[$0.key] != nil }
            .sorted { $0.value < $1.value }
            .map(\.key)
        var dropped = false
        for request in evictable where bytes > byteLimit {
            if let image = cache.removeValue(forKey: request) { bytes -= cost(of: image) }
            lastRead.removeValue(forKey: request)
            dropped = true
        }
        if dropped { generation &+= 1 }
    }

    private func purge() {
        guard !cache.isEmpty else { return }
        cache.removeAll()
        lastRead.removeAll()
        bytes = 0
        generation &+= 1
    }

    /// How many bytes are cached right now - the tests watch it.
    var cachedBytes: Int { bytes }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }
}

/// The app's two bitmap stores. A generic type can't hold static stored
/// properties, so they live here.
enum PageBitmaps {
    /// Full-page imported artwork, oversampled for zoom. A page at 2.5x is
    /// roughly 20 MB, so this holds a few pages either side of the one
    /// you're on.
    static let artwork = BitmapStore<ArtworkRequest>(byteLimit: 64 * 1024 * 1024) { request in
        await ArtworkRenderer.render(request)
    }

    /// Page-strip thumbnails: ~300 KB each at the default strip height,
    /// ~2.8 MB at its tallest, so this holds a notebook's worth of the
    /// former and a screenful of the latter. Without it, every page turn
    /// and every scroll of the strip decoded each page's ink record again.
    static let thumbnails = BitmapStore<PageThumbnailRequest>(byteLimit: 24 * 1024 * 1024) { request in
        await PageThumbnailRenderer.render(request)
    }
}
#endif
