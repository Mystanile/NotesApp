import XCTest
import SwiftUI
import PencilKit
@testable import Mystnotes

/// Pen presets: a saved ink, colour and width, one tap away.
final class PenPresetTests: XCTestCase {

    func testPreset_capturesAndRestoresThePen() {
        var state = DrawingToolState()
        state.penInkType = .fountainPen
        state.penColor = Color(hex: "#FF0000")
        state.penWidth = 7
        let preset = PenPreset(state)

        var other = DrawingToolState()
        preset.apply(to: &other)
        XCTAssertEqual(other.penInkType, .fountainPen)
        XCTAssertEqual(other.penColor.toHex(), "#FF0000")
        XCTAssertEqual(other.penWidth, 7)
        XCTAssertEqual(other.fillColor.toHex(), "#FF0000", "the fill follows the pen's colour, as when picking one")
    }

    func testPresets_surviveEncoding_andUnknownInksFallBackToPen() throws {
        let presets = [PenPreset(inkType: "com.apple.ink.marker", colorHex: "#0000FF", width: 12)]
        XCTAssertEqual(PenPreset.decode(PenPreset.encode(presets)), presets)
        XCTAssertEqual(PenPreset(inkType: "com.example.future", colorHex: "#000000", width: 3).pkInkType, .pen)
        XCTAssertEqual(PenPreset.decode(Data("garbage".utf8)), [])
    }
}
