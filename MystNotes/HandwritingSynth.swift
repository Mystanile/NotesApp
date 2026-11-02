import Foundation
import CoreGraphics
import PencilKit

/// Deterministic generator (SplitMix64). The same seed gives the same
/// handwriting, which keeps tests stable and makes a regenerated page match.
nonisolated struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in [-amount, amount].
    mutating func spread(_ amount: Double) -> Double { (unit() * 2 - 1) * amount }
}

/// Turns text into ink strokes in the user's hand (or the built-in one).
///
/// Pure and `nonisolated`: no UIKit rendering, no `PKDrawing.image`, so it
/// is safe off the main thread. Strokes are built the way
/// `ShapeRecognizer` builds them: B-spline control points with the ends
/// tripled so the curve reaches them, a distinct `creationDate` per stroke
/// (1 ms apart, so the codec and the timeline can tell them apart), and a
/// rendered width never below `minimumWidth` (PencilKit draws nothing under
/// ~2 pt).
nonisolated enum HandwritingSynth {
    static let minimumWidth: CGFloat = 2.2
    static let lineHeightFactor: CGFloat = 3.2
    static let wordSpacingFactor: CGFloat = 0.6
    /// Capital height in x-heights; the first baseline sits this far below
    /// `origin.y`, so the top of a capital touches the block's top edge.
    static let capHeight: CGFloat = 1.5

    private struct Placed {
        var sample: GlyphSample
        var rotation: CGFloat
        var scale: CGFloat
        var wobble: CGFloat
        /// Distance to the next glyph, x-heights, with spacing jitter.
        var stride: CGFloat
        /// How far this glyph reaches to the right of its origin.
        var extent: CGFloat { max(stride, sample.advance * scale) }
    }

    /// `origin` is the top-left of the text block; lines are
    /// `3.2 * xHeight` apart; nothing is placed right of
    /// `origin.x + maxWidth` except a single glyph wider than the line, and
    /// rotation and the fallback hand's slant by a fraction of an x-height.
    /// `width` is the nominal pen width the profile's relative sizes scale.
    static func layout(text: String, profile: HandwritingProfile?, origin: CGPoint, maxWidth: CGFloat,
                       xHeight: CGFloat, ink: PKInk, width: CGFloat, baseDate: Date,
                       seed: UInt64) -> [PKStroke] {
        guard xHeight > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        let lineHeight = lineHeightFactor * xHeight
        let limit = max(maxWidth, xHeight)

        var placements: [(glyph: Placed, x: CGFloat, line: Int)] = []
        var cursor: CGFloat = 0
        var line = 0
        func newLine() { cursor = 0; line += 1 }

        let paragraphs = text.components(separatedBy: "\n")
        for (pIndex, paragraph) in paragraphs.enumerated() {
            if pIndex > 0 { newLine() }
            for word in paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let glyphs = word.map { placed(for: $0, profile: profile, rng: &rng) }
                let wordWidth = glyphs.dropLast().reduce(0) { $0 + $1.stride * xHeight }
                    + (glyphs.last.map { $0.extent * xHeight } ?? 0)
                if cursor > 0, cursor + wordWidth > limit { newLine() }
                for glyph in glyphs {
                    // A word longer than a whole line breaks between glyphs.
                    if cursor > 0, cursor + glyph.extent * xHeight > limit { newLine() }
                    placements.append((glyph, cursor, line))
                    cursor += glyph.stride * xHeight
                }
                cursor += wordSpacingFactor * xHeight * CGFloat(1 + rng.spread(0.08))
            }
        }

        var strokes: [PKStroke] = []
        for placement in placements {
            let glyph = placement.glyph
            let advance = glyph.sample.advance
            let centerX = origin.x + placement.x + advance * glyph.scale * xHeight / 2
            let baselineY = origin.y + (capHeight + CGFloat(placement.line) * lineHeightFactor) * xHeight
                + glyph.wobble * xHeight
            let cosine = cos(glyph.rotation), sine = sin(glyph.rotation)

            for source in glyph.sample.strokes where source.count >= 2 {
                var clock: TimeInterval = 0
                var points: [PKStrokePoint] = []
                points.reserveCapacity(source.count + 4)
                for p in source {
                    let lx = (p.x - advance / 2) * glyph.scale * xHeight
                    let ly = p.y * glyph.scale * xHeight
                    let location = CGPoint(x: centerX + lx * cosine - ly * sine,
                                           y: baselineY + lx * sine + ly * cosine)
                    clock = max(clock, p.t)
                    let w = max(minimumWidth, p.size * width)
                    points.append(PKStrokePoint(
                        location: location, timeOffset: clock,
                        size: CGSize(width: w, height: w),
                        opacity: 1, force: max(p.force, 0.05), azimuth: 0, altitude: .pi / 2
                    ))
                }
                // Triple the ends so the B-spline reaches them.
                points.insert(contentsOf: [points[0], points[0]], at: 0)
                points.append(contentsOf: [points[points.count - 1], points[points.count - 1]])

                let created = baseDate.addingTimeInterval(Double(strokes.count) * 0.001)
                let path = PKStrokePath(controlPoints: points, creationDate: created)
                strokes.append(PKStroke(ink: ink, path: path))
            }
        }
        return strokes
    }

    /// Picks a sample for `character` and rolls its jitter. Always draws the
    /// same number of random values per glyph so a profile gaining a sample
    /// for one letter doesn't reshuffle the rest of the text.
    private static func placed(for character: Character, profile: HandwritingProfile?,
                               rng: inout SplitMix64) -> Placed {
        let pick = rng.next()
        let rotation = CGFloat(rng.spread(2)) * .pi / 180
        let scale = CGFloat(1 + rng.spread(0.04))
        let wobble = CGFloat(rng.spread(0.06))
        let spacing = CGFloat(1 + rng.spread(0.08))

        let own = profile?.samples(for: character).filter { !$0.strokes.isEmpty } ?? []
        let sample: GlyphSample
        if !own.isEmpty {
            sample = own[Int(pick % UInt64(own.count))]
        } else if let fallback = FallbackHand.sample(for: character) {
            sample = fallback
        } else {
            // Not in either hand: leave a gap rather than a hole in the line.
            sample = GlyphSample(strokes: [], advance: 0.5)
        }
        return Placed(sample: sample, rotation: rotation, scale: scale, wobble: wobble,
                      stride: sample.advance * spacing)
    }
}
