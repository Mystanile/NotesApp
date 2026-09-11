import Foundation
import CoreGraphics
import Observation

/// One notebook page's own coordinate space.
///
/// A paged page is a *document page*, not "whatever rectangle the screen
/// happens to be": ink, element frames and imported-artwork fractions are
/// all expressed against a fixed page-sized space, and the view scales that
/// space to fit the screen (and lets you pinch past the fit). That's what
/// keeps a portrait PDF a portrait page on a landscape iPad instead of a
/// letterboxed strip inside a landscape canvas, and it's the same space
/// `PageRenderer` already composited exports through - so what you draw,
/// what the thumbnail shows and what you export finally agree.
enum PageGeometry {
    /// Every page is this tall in page points; width follows from the
    /// aspect ratio. Chosen so the default page is exactly the 780x1040
    /// space exports and thumbnails were already assuming.
    static let nominalHeight: CGFloat = 1040
    static let defaultAspectRatio: CGFloat = 780.0 / 1040.0

    /// How far past "fit the screen" a pinch can go.
    static let maximumZoomFactor: CGFloat = 5

    /// Sanitised width÷height. Nil (never imported anything with a shape of
    /// its own) and nonsense values both fall back to the default page.
    static func aspectRatio(_ raw: Double?) -> CGFloat {
        guard let raw, raw.isFinite, raw > 0.05, raw < 20 else { return defaultAspectRatio }
        return CGFloat(raw)
    }

    static func contentSize(aspectRatio: CGFloat) -> CGSize {
        CGSize(width: (nominalHeight * aspectRatio).rounded(), height: nominalHeight)
    }

    static func contentSize(for page: Page) -> CGSize {
        contentSize(aspectRatio: aspectRatio(page.aspectRatio))
    }

    /// The scale at which a page of `contentSize` exactly fits `container`.
    static func fitScale(contentSize: CGSize, in container: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0,
              container.width > 0, container.height > 0 else { return 1 }
        return min(container.width / contentSize.width, container.height / contentSize.height)
    }
}

/// The live pan/zoom of the page canvas, published so the layers that sit
/// behind and on top of the ink (paper/PDF background, text blocks,
/// stickers, links, placement handles) can be drawn through exactly the
/// same transform.
///
/// The zoom itself is driven by the `PKCanvasView`'s own scroll view rather
/// than a SwiftUI `MagnificationGesture`: PencilKit re-renders the drawing
/// at the new scale that way, so zoomed-in ink stays crisp instead of being
/// a magnified bitmap.
@Observable
final class CanvasViewport {
    /// Points on screen per page point.
    var zoomScale: CGFloat = 1
    /// The scroll view's content offset, in already-zoomed points.
    var contentOffset: CGPoint = .zero
    /// False until the canvas has laid out once, so the dependent layers
    /// don't flash at the wrong size on the first frame.
    var hasSynced: Bool = false
    /// The page whose fit the layers are waiting on. Only a publish for
    /// *this* page flips `hasSynced` back on - a late callback from the
    /// outgoing page's layout can't reveal the new page at the old zoom.
    @ObservationIgnored var expectedPage: UUID?
    /// The canvas host currently publishing into this viewport. `reset()`
    /// asks it for a fresh layout pass, so the layers come back even when
    /// nothing else would have laid the canvas out again (the page was
    /// already fitted before the reset landed - which is how the paper went
    /// missing behind the ink until a pinch nudged the scroll view).
    @ObservationIgnored weak var host: CanvasViewportHost?

    /// A point in the canvas's own view coordinates, expressed in page
    /// coordinates - what the shape and fill overlays capture taps in.
    func pagePoint(from viewPoint: CGPoint) -> CGPoint {
        let scale = max(zoomScale, 0.0001)
        return CGPoint(
            x: (viewPoint.x + contentOffset.x) / scale,
            y: (viewPoint.y + contentOffset.y) / scale
        )
    }

    /// Hide the layers until the canvas has fitted `page`.
    func reset(for page: UUID?) {
        zoomScale = 1
        contentOffset = .zero
        hasSynced = false
        expectedPage = page
        host?.requestViewportSync()
    }
}

/// Whatever owns the canvas's scroll view and can lay the page out again.
protocol CanvasViewportHost: AnyObject {
    func requestViewportSync()
}
