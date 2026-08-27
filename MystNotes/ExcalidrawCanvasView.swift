import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// A second, switchable drawing engine alongside PencilKit (see
/// `PencilCanvasView`/`WhiteboardCanvasView`, both left untouched). Excalidraw
/// has no native Swift equivalent, so this embeds its web build (vendored
/// into `ExcalidrawWeb/`, rebuilt via `excalidraw-build/build.sh`) in a
/// WKWebView and bridges scene data to/from Swift as JSON. Apple Pencil
/// input here is real, but a WKWebView's pointer events are noticeably
/// behind PencilKit's hardware-optimized ink - that tradeoff is inherent to
/// embedding a web-based engine, not a bug in this wrapper.
///
/// `ExcalidrawController` owns the single long-lived WKWebView reference
/// (mirroring the shared `canvasView`/`toolPicker` pattern in
/// `NotebookDetailView`, which is never recreated so it survives view
/// updates) and exposes an async load/export API. All Swift-initiated calls
/// use `callAsyncJavaScript`/`takeSnapshot`'s native async overloads.
@MainActor
final class ExcalidrawController {
    /// A brand-new page has nothing on disk yet, so callers can load this
    /// directly instead of round-tripping through a nonexistent file.
    static let emptyScene = "{\"elements\":[],\"appState\":{}}"

    fileprivate weak var webView: WKWebView?
    private var isReady = false
    private var readyContinuations: [CheckedContinuation<Void, Never>] = []
    private var attachContinuations: [CheckedContinuation<WKWebView, Never>] = []

    /// Called from `ExcalidrawCanvasView.makeUIView` once the WKWebView
    /// exists. Switching to a page whose Excalidraw view is mounting for
    /// the first time can race a call like `loadScene` arriving before
    /// SwiftUI has actually run `makeUIView` yet - resolving pending
    /// `waitUntilAttached()` waiters here (instead of every caller just
    /// silently no-op'ing on a nil webView) is what closes that race.
    fileprivate func attach(_ webView: WKWebView) {
        self.webView = webView
        let continuations = attachContinuations
        attachContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: webView)
        }
    }

    fileprivate func markReady() {
        isReady = true
        let continuations = readyContinuations
        readyContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitUntilAttached() async -> WKWebView {
        if let webView { return webView }
        return await withCheckedContinuation { continuation in
            attachContinuations.append(continuation)
        }
    }

    /// Excalidraw's React tree mounts asynchronously after the page loads
    /// (`WKNavigationDelegate.didFinish` fires on script-load, not on React
    /// mount), so every call below waits for the explicit "ready" message
    /// the bundled JS posts once its imperative API is available.
    private func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    func loadScene(_ json: String) async {
        let webView = await waitUntilAttached()
        await waitUntilReady()
        _ = try? await webView.callAsyncJavaScript(
            "window.mystnotesLoadScene(sceneJSON);",
            arguments: ["sceneJSON": json],
            in: nil,
            contentWorld: .page
        )
    }

    func exportSceneJSON() async -> String? {
        let webView = await waitUntilAttached()
        await waitUntilReady()
        let result = try? await webView.callAsyncJavaScript(
            "return window.mystnotesExportScene();",
            in: nil,
            contentWorld: .page
        )
        return result as? String
    }

    func exportPlainText() async -> String? {
        let webView = await waitUntilAttached()
        await waitUntilReady()
        let result = try? await webView.callAsyncJavaScript(
            "return window.mystnotesExtractText();",
            in: nil,
            contentWorld: .page
        )
        return result as? String
    }

    #if canImport(UIKit)
    func snapshotThumbnail() async -> UIImage? {
        let webView = await waitUntilAttached()
        await waitUntilReady()
        return try? await webView.takeSnapshot(configuration: nil)
    }
    #endif
}

#if targetEnvironment(macCatalyst) || canImport(UIKit)
struct ExcalidrawCanvasView: UIViewRepresentable {
    var controller: ExcalidrawController
    var onSceneChanged: () -> Void = {}

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "excalidrawBridge")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        controller.attach(webView)

        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The scene is loaded/exported explicitly by the parent view (via
        // `controller`) when switching pages - nothing to sync here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onSceneChanged: onSceneChanged)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let controller: ExcalidrawController
        let onSceneChanged: () -> Void

        init(controller: ExcalidrawController, onSceneChanged: @escaping () -> Void) {
            self.controller = controller
            self.onSceneChanged = onSceneChanged
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                controller.markReady()
            case "changed":
                onSceneChanged()
            default:
                break
            }
        }
    }
}
#else
// Native macOS AppKit - matches the placeholder shape used elsewhere in this
// file family (WhiteboardCanvasView, PencilCanvasView), even though WKWebView
// is actually available on native macOS; kept out of scope for v1 per plan.
struct ExcalidrawCanvasView: NSViewRepresentable {
    var controller: ExcalidrawController

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Not available on native macOS in v1.
    }
}
#endif
