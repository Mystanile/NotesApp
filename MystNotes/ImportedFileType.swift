import Foundation

/// What a chunk of imported bytes actually is, from its own header.
///
/// Every route into the app now hands over raw bytes - the Photos picker,
/// the Files importer, the pasteboard, a drag from Finder - and none of
/// them can be trusted to say what they are. A pasteboard item declared
/// `public.png` can be a JPEG; a file picked from the image importer can be
/// a PDF. The header is the one thing that can't lie, and it decides both
/// the extension the payload is stored under and whether the import goes
/// down the image path or the PDF one.
nonisolated struct ImportedFileType: Equatable, Sendable {
    var fileExtension: String
    var isPDF: Bool

    static let png = ImportedFileType(fileExtension: "png", isPDF: false)
    static let jpeg = ImportedFileType(fileExtension: "jpg", isPDF: false)
    static let gif = ImportedFileType(fileExtension: "gif", isPDF: false)
    static let tiff = ImportedFileType(fileExtension: "tiff", isPDF: false)
    static let heic = ImportedFileType(fileExtension: "heic", isPDF: false)
    static let webp = ImportedFileType(fileExtension: "webp", isPDF: false)
    static let pdf = ImportedFileType(fileExtension: "pdf", isPDF: true)

    /// The type of `data`, or nil when it is nothing we can put on a page.
    static func of(_ data: Data) -> ImportedFileType? {
        // 12 bytes covers every signature below, including the ISO-BMFF
        // `ftyp` box at offset 4 that HEIC uses.
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))

        func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            guard bytes.count >= offset + signature.count else { return false }
            return Array(bytes[offset..<(offset + signature.count)]) == signature
        }

        if matches([0x25, 0x50, 0x44, 0x46]) { return .pdf }                 // %PDF
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if matches([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if matches([0x47, 0x49, 0x46, 0x38]) { return .gif }                 // GIF8
        if matches([0x49, 0x49, 0x2A, 0x00]) || matches([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if matches([0x52, 0x49, 0x46, 0x46]), matches([0x57, 0x45, 0x42, 0x50], at: 8) { return .webp }
        // ISO base media: HEIC, HEIF and friends all carry `ftyp` at 4 and
        // a brand at 8. `mif1`/`msf1` are the generic HEIF brands.
        if matches([0x66, 0x74, 0x79, 0x70], at: 4) {
            let brand = Array(bytes[8..<12])
            let heicBrands: [[UInt8]] = [
                Array("heic".utf8), Array("heix".utf8), Array("hevc".utf8),
                Array("mif1".utf8), Array("msf1".utf8), Array("heim".utf8), Array("avif".utf8)
            ]
            if heicBrands.contains(brand) { return .heic }
        }
        return nil
    }
}
