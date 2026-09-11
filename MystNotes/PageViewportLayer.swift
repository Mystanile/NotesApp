import SwiftUI

/// Draws its content in *page* coordinates and then puts it through the
/// canvas's current pan/zoom, so background paper, imported artwork, text
/// blocks, stickers, links and the placement handles all sit exactly where
/// the ink does at every zoom level.
///
/// Only this view reads the observable viewport, so a pinch or a pan
/// re-evaluates this layer rather than the whole (large) detail view.
struct PageViewportLayer<Content: View>: View {
    var viewport: CanvasViewport
    var pageSize: CGSize
    /// Handed the live zoom scale, because gesture translations inside the
    /// layer arrive in screen points and have to be divided by it.
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        content(viewport.zoomScale)
            .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
            .scaleEffect(viewport.zoomScale, anchor: .topLeading)
            .offset(x: -viewport.contentOffset.x, y: -viewport.contentOffset.y)
            // minWidth/minHeight 0 matters: without them this frame inherits
            // the page-sized child's minimum, and the VStack around the
            // canvas hands it the whole screen - shoving the page-thumbnail
            // strip off the bottom.
            .frame(minWidth: 0, maxWidth: .infinity,
                   minHeight: 0, maxHeight: .infinity,
                   alignment: .topLeading)
            .opacity(viewport.hasSynced ? 1 : 0)
            .allowsHitTesting(viewport.hasSynced)
    }
}
