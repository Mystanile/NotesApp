import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit

/// Presents the system share sheet, which is how an exported PDF gets to
/// Files, Mail, another app, or anywhere else the user wants it. Wrapped as
/// a Representable because SwiftUI has no native equivalent that also works
/// on Mac Catalyst.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
