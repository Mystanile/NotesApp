import SwiftUI
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

/// Small preview image of a page's saved drawing, rendered on-demand from
/// the PKDrawing data on disk (no separate thumbnail cache/store yet).
struct PageThumbnailView: View {
    let page: Page
    var isSelected: Bool = false

    #if canImport(UIKit)
    @State private var thumbnail: UIImage?
    #else
    @State private var thumbnail: Any? = nil
    #endif

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
        #if canImport(UIKit)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        #else
            // On macOS without UIKit, show a placeholder or implement alternative
            if thumbnail != nil {
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 52, height: 72) // inner padding of 4
            }
        #endif
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .frame(width: 60, height: 80)
        .task(id: page.drawingFileRef) {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard let ref = page.drawingFileRef else {
        #if canImport(UIKit)
            thumbnail = nil
        #else
            thumbnail = nil
        #endif
            return
        }
        let directory = FileStore.baseDirectory()
        let url = directory.appendingPathComponent(ref)
        guard let data = try? Data(contentsOf: url), let drawing = try? PKDrawing(data: data) else {
        #if canImport(UIKit)
            thumbnail = nil
        #else
            thumbnail = nil
        #endif
            return
        }
        let bounds = drawing.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: 300, height: 400)
            : drawing.bounds.insetBy(dx: -10, dy: -10)
    #if canImport(UIKit)
        thumbnail = drawing.image(from: bounds, scale: 0.5)
    #else
        // On macOS without UIKit, we can't create UIImage from PKDrawing
        // For now, we'll set thumbnail to nil or implement an alternative approach
        thumbnail = nil
    #endif
    }
}