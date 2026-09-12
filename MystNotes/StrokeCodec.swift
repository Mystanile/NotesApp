import Foundation
#if canImport(UIKit)
import UIKit
import PencilKit

/// The neutral stroke format, `MYSK` version 1. Everything a `PKDrawing`
/// holds, written out so a reader with no PencilKit - a web renderer, an
/// Android client, a future version of this app - can rebuild the ink
/// exactly, plus a stable id per stroke that PencilKit does not provide
/// (see `StrokeIDMap`).
///
/// Binary, little-endian. Numbers are stored at the precision PencilKit
/// gives them (`CGFloat` is 64-bit): halving a coordinate's precision is
/// a way to lose ink, just a subtle one.
///
///     header (never compressed)
///       magic        4 bytes   "MYSK"
///       version      u16       1
///       flags        u32       bit 0: the body is LZFSE-compressed
///       strokeCount  u32
///     body: per stroke
///       id           16 bytes  UUID
///       inkType      string    PKInk.InkType.rawValue, u16 length + UTF-8
///       color        4 × f64   red, green, blue, alpha as UIColor reports them
///       randomSeed   u32       PKStroke.randomSeed - seeds pencil, watercolor and
///                              crayon texture; without it a round trip can't be
///                              pixel-identical
///       transform    6 × f64   a b c d tx ty
///       creationDate f64       seconds since 2001-01-01 (PKStrokePath.creationDate)
///       mask         u32 element count, 0 = no mask; then per element
///                    u8 kind (0 move, 1 line, 2 quad, 3 cubic, 4 close) and
///                    0/1/2/3 points as f64 pairs - PKStroke.mask, the lasso-
///                    erase clip, as CGPath elements rather than an archived
///                    UIBezierPath so it stays platform-neutral
///       pointCount   u32
///       points       pointCount × 11 × f64: x, y, timeOffset, size.width,
///                    size.height, opacity, force, azimuth, altitude,
///                    secondaryScale, threshold - the B-spline control points
///                    PKStrokePath exposes, never resampled
///
/// Ink type strings, for readers without PencilKit: pen, pencil, marker,
/// monoline, fountainPen, watercolor, crayon. Unknown strings decode as pen.
///
/// The body is LZFSE-compressed by default (flag bit 0): eleven float64s
/// per control point are ~6× PencilKit's own encoding uncompressed, and
/// this file is what syncs per page per edit. LZFSE decompresses in well
/// under a millisecond for a dense page. A file written without the flag
/// reads the same.
enum StrokeCodec {
    static let magic: [UInt8] = Array("MYSK".utf8)
    static let version: UInt16 = 1
    static let compressedBodyFlag: UInt32 = 1 << 0

    enum CodecError: Error, Equatable {
        case notAStrokesFile
        case unsupportedVersion(UInt16)
        case truncated
    }

    // MARK: Encode

    /// Writes `drawing`. `ids` is consulted for every stroke - a stroke seen
    /// before keeps its id, a new one is assigned - and updated to exactly
    /// the strokes in `drawing`, so the map never accumulates ids for
    /// strokes that no longer exist.
    static func encode(_ drawing: PKDrawing, ids: inout StrokeIDMap, compress: Bool = true) -> Data {
        var body = ByteWriter()
        var next = StrokeIDMap()
        for stroke in drawing.strokes {
            let w = encodeStroke(stroke, ids: &ids, next: &next)
            body.bytes(Array(w.data))
        }
        ids = next

        var flags: UInt32 = 0
        var bodyData = body.data
        if compress, let compressed = try? (bodyData as NSData).compressed(using: .lzfse) as Data {
            flags |= compressedBodyFlag
            bodyData = compressed
        }

        var w = ByteWriter()
        w.bytes(magic)
        w.u16(version)
        w.u32(flags)
        w.u32(UInt32(drawing.strokes.count))
        w.bytes(Array(bodyData))
        return w.data
    }

    private static func encodeStroke(_ stroke: PKStroke, ids: inout StrokeIDMap, next: inout StrokeIDMap) -> ByteWriter {
        var w = ByteWriter()
        let id = ids.id(for: stroke)
        next.assign(id, to: stroke)
        w.uuid(id)
        w.string(stroke.ink.inkType.rawValue)
        let (r, g, b, a) = components(of: stroke.ink.color)
        w.f64(r); w.f64(g); w.f64(b); w.f64(a)
        w.u32(stroke.randomSeed)
        let t = stroke.transform
        w.f64(t.a); w.f64(t.b); w.f64(t.c); w.f64(t.d); w.f64(t.tx); w.f64(t.ty)
        w.f64(stroke.path.creationDate.timeIntervalSinceReferenceDate)
        writeMask(stroke.mask, to: &w)
        w.u32(UInt32(stroke.path.count))
        for point in stroke.path {
            w.f64(point.location.x); w.f64(point.location.y)
            w.f64(point.timeOffset)
            w.f64(point.size.width); w.f64(point.size.height)
            w.f64(point.opacity); w.f64(point.force)
            w.f64(point.azimuth); w.f64(point.altitude)
            w.f64(point.secondaryScale); w.f64(point.threshold)
        }
        return w
    }

    // MARK: Decode

    /// Rebuilds the drawing and the id map that goes with it.
    static func decode(_ data: Data) throws -> (drawing: PKDrawing, ids: StrokeIDMap) {
        var header = ByteReader(data)
        guard try header.bytes(4) == magic else { throw CodecError.notAStrokesFile }
        let fileVersion = try header.u16()
        guard fileVersion <= version else { throw CodecError.unsupportedVersion(fileVersion) }
        let flags = try header.u32()
        let count = try header.u32()

        var bodyData = data.suffix(from: data.startIndex + header.offset)
        if flags & compressedBodyFlag != 0 {
            guard let expanded = try? (Data(bodyData) as NSData).decompressed(using: .lzfse) as Data else {
                throw CodecError.truncated
            }
            bodyData = expanded
        }
        var r = ByteReader(Data(bodyData))

        var strokes: [PKStroke] = []
        var ids = StrokeIDMap()
        for _ in 0..<count {
            let id = try r.uuid()
            let inkType = PKInk.InkType(rawValue: try r.string()) ?? .pen
            let color = UIColor(red: try r.f64(), green: try r.f64(), blue: try r.f64(), alpha: try r.f64())
            let seed = try r.u32()
            let transform = CGAffineTransform(a: try r.f64(), b: try r.f64(), c: try r.f64(),
                                              d: try r.f64(), tx: try r.f64(), ty: try r.f64())
            let creationDate = Date(timeIntervalSinceReferenceDate: try r.f64())
            let mask = try readMask(from: &r)
            let pointCount = try r.u32()
            var points: [PKStrokePoint] = []
            points.reserveCapacity(Int(pointCount))
            for _ in 0..<pointCount {
                points.append(PKStrokePoint(
                    location: CGPoint(x: try r.f64(), y: try r.f64()),
                    timeOffset: try r.f64(),
                    size: CGSize(width: try r.f64(), height: try r.f64()),
                    opacity: try r.f64(), force: try r.f64(),
                    azimuth: try r.f64(), altitude: try r.f64(),
                    secondaryScale: try r.f64(), threshold: try r.f64()
                ))
            }
            let path = PKStrokePath(controlPoints: points, creationDate: creationDate)
            let stroke = PKStroke(ink: PKInk(inkType, color: color), path: path,
                                  transform: transform, mask: mask, randomSeed: seed)
            strokes.append(stroke)
            ids.assign(id, to: stroke)
        }
        return (PKDrawing(strokes: strokes), ids)
    }

    // MARK: Pieces

    private static func components(of color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) { return (r, g, b, a) }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &a) { return (white, white, white, a) }
        return (0, 0, 0, 1)
    }

    private static func writeMask(_ mask: UIBezierPath?, to w: inout ByteWriter) {
        guard let mask else { w.u32(0); return }
        var elements: [(UInt8, [CGPoint])] = []
        mask.cgPath.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: elements.append((0, [e.points[0]]))
            case .addLineToPoint: elements.append((1, [e.points[0]]))
            case .addQuadCurveToPoint: elements.append((2, [e.points[0], e.points[1]]))
            case .addCurveToPoint: elements.append((3, [e.points[0], e.points[1], e.points[2]]))
            case .closeSubpath: elements.append((4, []))
            @unknown default: break
            }
        }
        w.u32(UInt32(elements.count))
        for (kind, points) in elements {
            w.u8(kind)
            for p in points { w.f64(p.x); w.f64(p.y) }
        }
    }

    private static func readMask(from r: inout ByteReader) throws -> UIBezierPath? {
        let count = try r.u32()
        guard count > 0 else { return nil }
        let path = CGMutablePath()
        for _ in 0..<count {
            switch try r.u8() {
            case 0: path.move(to: CGPoint(x: try r.f64(), y: try r.f64()))
            case 1: path.addLine(to: CGPoint(x: try r.f64(), y: try r.f64()))
            case 2:
                let control = CGPoint(x: try r.f64(), y: try r.f64())
                let end = CGPoint(x: try r.f64(), y: try r.f64())
                path.addQuadCurve(to: end, control: control)
            case 3:
                let c1 = CGPoint(x: try r.f64(), y: try r.f64())
                let c2 = CGPoint(x: try r.f64(), y: try r.f64())
                let end = CGPoint(x: try r.f64(), y: try r.f64())
                path.addCurve(to: end, control1: c1, control2: c2)
            case 4: path.closeSubpath()
            default: throw CodecError.notAStrokesFile
            }
        }
        return UIBezierPath(cgPath: path)
    }
}

// MARK: - Stroke identity

/// PencilKit has no stroke id, so the neutral file assigns one and this
/// map keeps it attached to the right stroke across the canvas's edits.
///
/// A stroke is recognised by what survives every operation the canvas
/// performs on it: when it was drawn, its texture seed, how many control
/// points it has, and where it starts and ends. Deliberately *not* its
/// transform (a lasso move) or its mask (a partial erase) - those change
/// without the stroke becoming a different stroke. Strokes a shape tool
/// creates in the same instant differ by their points.
struct StrokeIDMap: Equatable {
    struct Fingerprint: Hashable {
        var creationDate: TimeInterval
        var randomSeed: UInt32
        var pointCount: Int
        var first: CGPoint
        var last: CGPoint

        init(_ stroke: PKStroke) {
            creationDate = stroke.path.creationDate.timeIntervalSinceReferenceDate
            randomSeed = stroke.randomSeed
            pointCount = stroke.path.count
            first = stroke.path.first?.location ?? .zero
            last = stroke.path.last?.location ?? .zero
        }
    }

    private var byFingerprint: [Fingerprint: UUID] = [:]

    init() {}

    var count: Int { byFingerprint.count }

    /// The id this map already holds for `stroke`, if any.
    func existingID(for stroke: PKStroke) -> UUID? {
        byFingerprint[Fingerprint(stroke)]
    }

    /// The stroke's id, assigning a fresh one if it's new.
    mutating func id(for stroke: PKStroke) -> UUID {
        let key = Fingerprint(stroke)
        if let id = byFingerprint[key] { return id }
        let id = UUID()
        byFingerprint[key] = id
        return id
    }

    mutating func assign(_ id: UUID, to stroke: PKStroke) {
        byFingerprint[Fingerprint(stroke)] = id
    }
}

// MARK: - Little-endian byte I/O

struct ByteWriter {
    private(set) var data = Data()

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    mutating func uuid(_ id: UUID) { withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) } }
    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        u16(UInt16(utf8.count))
        bytes(utf8)
    }
}

struct ByteReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard offset + n <= data.count else { throw StrokeCodec.CodecError.truncated }
        defer { offset += n }
        return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
    }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { UInt16(littleEndian: try bytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
    mutating func f64() throws -> Double {
        Double(bitPattern: UInt64(littleEndian: try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))
    }
    mutating func uuid() throws -> UUID {
        let b = try bytes(16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
    mutating func string() throws -> String {
        let n = Int(try u16())
        return String(decoding: try bytes(n), as: UTF8.self)
    }
}
#endif
