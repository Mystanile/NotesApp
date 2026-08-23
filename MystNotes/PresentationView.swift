import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Distraction-free fullscreen view of the current page — no toolbar, no
/// page strip, no navigation chrome. Reuses the SAME canvasView/toolPicker
/// instances as the normal editing view (passed in as a binding), so
/// drawing state carries over seamlessly when entering/exiting.
///
/// This pairs with standard iPadOS screen mirroring (Control Center >
/// Screen Mirroring) as the "present to an audience" story — since there's
/// no app chrome here, mirroring this view IS a clean presentation. A true
/// dual-display presenter view (different content on your screen vs. the
/// external display) is a meaningfully bigger feature, not built here.
struct PresentationView: View {
    let page: Page
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    @Binding var canvasView: PKCanvasView
    var toolPicker: PKToolPicker
#else
    // Placeholder for macOS native - PencilKit not available
    @Binding var canvasView: Any?
    var toolPicker: Any?
#endif
    var onDrawingChanged: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            if page.type == "whiteboard" {
                WhiteboardCanvasView(
                    canvasView: $canvasView,
                    toolPicker: toolPicker,
                    onDrawingChanged: onDrawingChanged
                )
            } else {
                ZStack {
                    if page.backgroundRef != nil {
                        ImportedPageBackgroundView(page: page)
                    } else {
                        PageBackgroundView(template: page.template)
                    }
                    PencilCanvasView(
                        canvasView: $canvasView,
                        toolPicker: toolPicker,
                        onDrawingChanged: onDrawingChanged
                    )
                }
            }
#else
            // Placeholder for macOS native
            ZStack {
                Color.gray.opacity(0.2)
                Text("Presentation view not available on native macOS")
                    .foregroundColor(.white)
            }
#endif

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .ignoresSafeArea()
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .statusBarHidden()
        #endif
    }
}