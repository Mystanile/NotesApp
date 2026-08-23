import SwiftUI

/// Renders the paper background pattern (blank/lined/grid/dotted) behind the
/// PencilKit canvas. PencilKit has no concept of "paper" itself, so this sits
/// underneath a transparent PKCanvasView in a ZStack.
struct PageBackgroundView: View {
    let template: String  // "blank" | "lined" | "grid" | "dotted"

    private let lineSpacing: CGFloat = 32
    private let dotSpacing: CGFloat = 24
    private let patternColor = Color.gray.opacity(0.25)

    var body: some View {
        Canvas { context, size in
            switch template {
            case "lined":
                drawRows(context: context, size: size)
            case "grid":
                drawRows(context: context, size: size)
                drawColumns(context: context, size: size)
            case "dotted":
                drawDots(context: context, size: size)
            default:
                break // blank: nothing to draw
            }
        }
        .background(Color.white)
    }

    private func drawRows(context: GraphicsContext, size: CGSize) {
        var y: CGFloat = lineSpacing
        while y < size.height {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(patternColor), lineWidth: 1)
            y += lineSpacing
        }
    }

    private func drawColumns(context: GraphicsContext, size: CGSize) {
        var x: CGFloat = lineSpacing
        while x < size.width {
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(patternColor), lineWidth: 1)
            x += lineSpacing
        }
    }

    private func drawDots(context: GraphicsContext, size: CGSize) {
        var y: CGFloat = dotSpacing
        while y < size.height {
            var x: CGFloat = dotSpacing
            while x < size.width {
                let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                context.fill(Path(ellipseIn: rect), with: .color(patternColor))
                x += dotSpacing
            }
            y += dotSpacing
        }
    }
}
