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
///    landing re-evaluates every view reading that key, and `generation`
///    changes on a purge so their `.task(id:)` runs again. No path leaves a
///    view showing nothing when a bitmap exists or could be made.
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
    /// Oldest first. Insertion order, not use order: bumping an entry on
    /// read would mean mutating observable state from inside a view body.
    private var order: [Request] = []
    private var bytes = 0
    private var inFlight: Set<Request> = []

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
    /// a view body is what subscribes that body to the store.
    func image(for request: Request) -> UIImage? {
        cache[request]
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
        cache[request] = image
        order.removeAll { $0 == request }
        order.append(request)
        bytes += cost(of: image)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        var dropped = false
        while bytes > byteLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let image = cache.removeValue(forKey: oldest) { bytes -= cost(of: image) }
            dropped = true
        }
        if dropped { generation &+= 1 }
    }

    private func purge() {
        guard !cache.isEmpty else { return }
        cache.removeAll()
        order.removeAll()
        bytes = 0
        generation &+= 1
    }

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

    /// Page-strip thumbnails: ~80 KB each, so this holds a long notebook's
    /// worth. Without it, every page turn and every scroll of the strip
    /// decoded each page's ink record again.
    static let thumbnails = BitmapStore<PageThumbnailRequest>(byteLimit: 8 * 1024 * 1024) { request in
        await PageThumbnailRenderer.render(request)
    }
}
#endif
