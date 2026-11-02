import Foundation
import CoreGraphics

/// The built-in hand: a compact single-stroke (Hershey-simplex-like) face
/// for the whole charset, used when the user's profile has no sample for a
/// character, or no profile exists at all. Rendered through the same
/// pipeline as a captured hand, with a slight slant so it reads as
/// handwriting rather than a plotter.
///
/// Authored on a grid with y up: baseline 0, x-height 10, capitals 15,
/// descenders to -5. Each entry is `advance | stroke / stroke / ...`, a
/// stroke being space-separated `x,y` pairs. Converted once to the profile's
/// own units (x-height 1.0, y down).
nonisolated enum FallbackHand {
    static let slantDegrees: CGFloat = 8

    static func sample(for character: Character) -> GlyphSample? { glyphs[character] }

    static let glyphs: [Character: GlyphSample] = {
        var result: [Character: GlyphSample] = [:]
        for (character, source) in source {
            if let sample = parse(source) { result[character] = sample }
        }
        return result
    }()

    // MARK: - Conversion

    private static func parse(_ source: String) -> GlyphSample? {
        let halves = source.split(separator: "|", maxSplits: 1).map(String.init)
        guard halves.count == 2, let width = Double(halves[0]) else { return nil }
        let shear = tan(slantDegrees * .pi / 180)
        var strokes: [[GlyphPoint]] = []
        var maxX: CGFloat = 0
        var clock: TimeInterval = 0
        for strokeText in halves[1].split(separator: "/") {
            var raw: [CGPoint] = []
            for pair in strokeText.split(separator: " ") {
                let parts = pair.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { continue }
                let x = CGFloat(parts[0]) / 10, up = CGFloat(parts[1]) / 10
                raw.append(CGPoint(x: x + up * shear, y: -up))
            }
            guard raw.count >= 2 else { continue }
            var points: [GlyphPoint] = []
            var t = clock
            for (i, p) in raw.enumerated() {
                if i > 0 { t += TimeInterval(hypot(p.x - raw[i - 1].x, p.y - raw[i - 1].y)) * 0.15 }
                maxX = max(maxX, p.x)
                let point = GlyphPoint(x: p.x, y: p.y, size: 1, force: 0.5, t: t - clock)
                points.append(point)
                // A sharp turn becomes a vertex of multiplicity three, as
                // `ShapeRecognizer` does, so a polyline keeps its corners
                // under the B-spline.
                if i > 0, i < raw.count - 1, turn(raw[i - 1], p, raw[i + 1]) > 55 {
                    points.append(point)
                    points.append(point)
                }
            }
            clock = t + 0.1
            strokes.append(points)
        }
        guard !strokes.isEmpty else { return nil }
        return GlyphSample(strokes: strokes, advance: max(CGFloat(width) / 10 + 0.1, maxX + 0.12))
    }

    /// Turning angle at `b`, degrees.
    private static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y), v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let l1 = hypot(v1.x, v1.y), l2 = hypot(v2.x, v2.y)
        guard l1 > 0, l2 > 0 else { return 0 }
        let cosine = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
        return acos(cosine) * 180 / .pi
    }

    // MARK: - The face

    private static let source: [Character: String] = [
        // Lowercase
        "a": "9|7,7 5,10 3,10 1,7 1,3 3,0 5,0 7,3 / 7,10 7,0",
        "b": "9|1,15 1,0 / 1,7 3,10 5,10 7,7 7,3 5,0 3,0 1,3",
        "c": "8|7,8 5,10 3,10 1,7 1,3 3,0 5,0 7,2",
        "d": "9|7,15 7,0 / 7,7 5,10 3,10 1,7 1,3 3,0 5,0 7,3",
        "e": "8|1,5 7,5 7,7 5,10 3,10 1,7 1,3 3,0 5,0 7,2",
        "f": "7|7,14 5,15 4,14 3,12 3,0 / 0,10 6,10",
        "g": "9|7,10 7,-3 6,-5 4,-5 2,-4 / 7,7 5,10 3,10 1,7 1,3 3,0 5,0 7,3",
        "h": "9|1,15 1,0 / 1,7 3,10 5,10 7,7 7,0",
        "i": "4|2,10 2,0 / 2,13 2,14.5",
        "j": "5|3,10 3,-3 2,-5 0,-5 / 3,13 3,14.5",
        "k": "8|1,15 1,0 / 7,10 1,4 / 3,6 7,0",
        "l": "5|2,15 2,1 3,0 4,0",
        "m": "13|1,10 1,0 / 1,7 3,10 5,10 6,7 6,0 / 6,7 8,10 10,10 11,7 11,0",
        "n": "9|1,10 1,0 / 1,7 3,10 5,10 7,7 7,0",
        "o": "9|4,10 2,10 1,7 1,3 3,0 5,0 7,3 7,7 5,10 4,10",
        "p": "9|1,10 1,-5 / 1,7 3,10 5,10 7,7 7,3 5,0 3,0 1,3",
        "q": "9|7,10 7,-5 / 7,7 5,10 3,10 1,7 1,3 3,0 5,0 7,3",
        "r": "7|1,10 1,0 / 1,6 3,10 5,10 6,9",
        "s": "8|7,9 5,10 3,10 1,8 2,6 6,4 7,2 5,0 3,0 1,1",
        "t": "7|3,14 3,2 4,0 5,0 6,1 / 0,10 6,10",
        "u": "9|1,10 1,3 3,0 5,0 7,3 / 7,10 7,0",
        "v": "8|1,10 4,0 7,10",
        "w": "12|1,10 3,0 6,8 9,0 11,10",
        "x": "8|1,10 7,0 / 7,10 1,0",
        "y": "8|1,10 4,1 / 7,10 3,-3 1,-5",
        "z": "8|1,10 7,10 1,0 7,0",
        // Uppercase
        "A": "11|1,0 5,15 9,0 / 2.5,5 7.5,5",
        "B": "11|1,0 1,15 6,15 8,13 8,10 6,8 1,8 / 6,8 9,6 9,2 7,0 1,0",
        "C": "10|9,12 7,15 4,15 1,12 1,3 4,0 7,0 9,3",
        "D": "11|1,0 1,15 5,15 9,11 9,4 5,0 1,0",
        "E": "10|9,15 1,15 1,0 9,0 / 1,8 7,8",
        "F": "10|9,15 1,15 1,0 / 1,8 7,8",
        "G": "11|9,12 7,15 4,15 1,12 1,3 4,0 7,0 9,3 9,7 5,7",
        "H": "11|1,15 1,0 / 9,15 9,0 / 1,8 9,8",
        "I": "8|1,15 7,15 / 4,15 4,0 / 1,0 7,0",
        "J": "9|7,15 7,3 5,0 3,0 1,3",
        "K": "10|1,15 1,0 / 9,15 1,6 / 4,9 9,0",
        "L": "9|1,15 1,0 8,0",
        "M": "13|1,0 1,15 6,5 11,15 11,0",
        "N": "11|1,0 1,15 9,0 9,15",
        "O": "11|5,15 2,13 1,8 2,2 5,0 8,2 9,8 8,13 5,15",
        "P": "10|1,0 1,15 6,15 9,13 9,10 6,7 1,7",
        "Q": "11|5,15 2,13 1,8 2,2 5,0 8,2 9,8 8,13 5,15 / 6,4 10,-1",
        "R": "11|1,0 1,15 6,15 9,13 9,10 6,7 1,7 / 5,7 9,0",
        "S": "10|9,13 7,15 4,15 1,13 1,10 4,8 7,7 9,5 9,2 6,0 3,0 1,2",
        "T": "10|0,15 10,15 / 5,15 5,0",
        "U": "11|1,15 1,4 3,0 7,0 9,4 9,15",
        "V": "11|0,15 5,0 10,15",
        "W": "15|0,15 3,0 7,12 11,0 14,15",
        "X": "11|1,15 9,0 / 9,15 1,0",
        "Y": "11|0,15 5,8 10,15 / 5,8 5,0",
        "Z": "10|1,15 9,15 1,0 9,0",
        // Digits
        "0": "10|5,14 2,12 1,7 2,2 5,0 8,2 9,7 8,12 5,14",
        "1": "8|2,11 5,14 5,0",
        "2": "10|1,11 3,14 6,14 8,11 7,8 1,0 9,0",
        "3": "10|1,13 3,14 6,14 8,12 8,9 5,7 8,5 8,2 6,0 3,0 1,1",
        "4": "10|7,0 7,14 1,4 9,4",
        "5": "10|8,14 2,14 1,8 4,9 7,8 8,5 7,1 4,0 1,2",
        "6": "10|8,13 6,14 3,13 1,8 1,3 3,0 6,0 8,3 7,7 4,8 1,6",
        "7": "10|1,14 9,14 4,0",
        "8": "10|5,7 2,9 2,12 5,14 8,12 8,9 5,7 1,4 1,2 3,0 7,0 9,2 9,4 5,7",
        "9": "10|8,8 5,6 2,8 2,12 5,14 8,12 8,8 7,3 4,0 2,1",
        // Punctuation
        ".": "4|2,0 2,1.5",
        ",": "4|2,1.5 2,0 1,-2",
        "!": "4|2,15 2,4 / 2,0 2,1.5",
        "?": "8|1,12 2,14 5,14 7,12 7,10 4,7 4,4 / 4,0 4,1.5",
        "'": "4|2,15 2,10",
        "\"": "7|2,15 2,10 / 5,15 5,10",
        "-": "8|1,6 6,6",
        ":": "4|2,8 2,9.5 / 2,0 2,1.5",
        ";": "4|2,8 2,9.5 / 2,1.5 2,0 1,-2",
        "(": "6|5,16 2,10 2,2 5,-3",
        ")": "6|1,16 4,10 4,2 1,-3",
        "/": "8|1,-2 7,15",
        "&": "11|9,0 3,8 2,11 3,14 5,14 7,12 6,9 1,4 1,1 3,0 6,0 9,5",
        "+": "10|1,7 9,7 / 5,2 5,12",
        "=": "10|1,9 9,9 / 1,5 9,5",
        "@": "12|9,5 8,3 5,2 2,4 1,8 3,12 7,13 10,11 10,6 8,4 6,4 5,6 6,9 8,9 9,5",
        "#": "11|3,12 2,2 / 8,12 7,2 / 0,9 10,9 / 0,5 10,5",
    ]
}
