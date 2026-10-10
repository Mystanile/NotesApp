import XCTest
import SwiftUI
@testable import Mystnotes

/// Draws every cover style at the library grid size and at the small
/// "Recent" size, for a look. Fails only if nothing renders.
@MainActor
final class NotebookCoverTests: XCTestCase {
    func testCovers_renderAtBothSizes() throws {
        let styles = ["default", "sunset", "ocean", "forest", "mono", "berry"]
        let notebooks = styles.map { style -> Notebook in
            let notebook = Notebook(title: style == "default" ? "Calculus II — Lecture Notes" : style.capitalized)
            notebook.coverStyle = style
            return notebook
        }
        let sheet = VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) { ForEach(notebooks, id: \.id) { NotebookCellView(notebook: $0).frame(width: 150) } }
            HStack(spacing: 16) { ForEach(notebooks, id: \.id) { RecentNotebookCellView(notebook: $0) } }
        }
        .padding(24)
        .background(Color(white: 0.95))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("covers.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }
}
