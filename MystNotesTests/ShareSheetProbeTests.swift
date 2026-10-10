import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Mystnotes

/// Spike, Oct 10, 2026: the iPad hung 4 s presenting the share sheet for an
/// exported PDF (`-[NSExtensionURLResult wait:]` on main, BACKLOG). Times
/// presentation with a bare file URL against an item provider that declares
/// its type. Prints numbers; asserts nothing about speed.
final class ShareSheetProbeTests: XCTestCase {
    private func pdfURL() throws -> URL {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            .pdfData { $0.beginPage() }
        return try PageRenderer.writeTemporaryPDF(data, named: "Probe")
    }

    private func timePresentation(_ items: [Any], label: String) throws -> TimeInterval {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = window.rootViewController!.view
        let shown = expectation(description: "presented")
        let start = Date()
        window.rootViewController!.present(sheet, animated: false) { shown.fulfill() }
        let mainBlocked = Date().timeIntervalSince(start)
        wait(for: [shown], timeout: 30)
        let total = Date().timeIntervalSince(start)
        print("[probe] \(label): present() blocked main \(String(format: "%.3f", mainBlocked)) s, presented after \(String(format: "%.3f", total)) s")
        sheet.dismiss(animated: false)
        return mainBlocked
    }

    func testShareSheetPresentation_bareURL_vsTypedItemProvider() throws {
        print("[probe] container: \(NSHomeDirectory()) bundle: \(Bundle.main.bundleIdentifier ?? "?")")
        XCTAssertEqual(Bundle.main.bundleIdentifier?.hasSuffix(".agenttest") ?? false || ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil, true, "device probes run only in the agenttest copy")
        let url = try pdfURL()
        _ = try timePresentation([url], label: "warm-up URL")
        for round in 1...3 {
            _ = try timePresentation([url], label: "bare URL \(round)")
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            provider.suggestedName = url.deletingPathExtension().lastPathComponent
            _ = try timePresentation([provider], label: "item provider \(round)")
        }
    }
}
