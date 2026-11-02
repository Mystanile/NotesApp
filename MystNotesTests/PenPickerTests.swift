import XCTest
import SwiftUI
@testable import Mystnotes

/// The pen picker's pure rules: which swatch is selected (by hex, so a
/// custom colour that equals a swatch shows it selected), the recent-colours
/// list, and the quick sizes.
@MainActor
final class PenPickerTests: XCTestCase {

    func testSwatchSelection_comparesByHex_notByColorEquality() {
        let current = Color(hex: "#ff3b30").toHex()
        let selected = InkPalette.swatches.filter { InkPalette.isSelected(swatchHex: $0.hex, currentHex: current) }
        XCTAssertEqual(selected.map(\.name), ["Red"], "a colour built from hex must select the matching swatch")
        XCTAssertTrue(InkPalette.isSelected(swatchHex: "#000000", currentHex: Color.black.toHex()))
        XCTAssertTrue(InkPalette.isSelected(swatchHex: "8e8e93", currentHex: "#8E8E93"), "case and # are ignored")
        let custom = Color(hex: "#123456").toHex()
        XCTAssertFalse(InkPalette.swatches.contains { InkPalette.isSelected(swatchHex: $0.hex, currentHex: custom) })
    }

    func testSwatches_areTenDistinctValidColours() {
        let hexes = InkPalette.swatches.map { InkPalette.normalized($0.hex) }
        XCTAssertEqual(hexes.count, 10)
        XCTAssertEqual(Set(hexes).count, 10)
        for hex in hexes { XCTAssertEqual(Color(hex: hex).toHex(), hex, "\(hex) must survive a round trip") }
    }

    func testRecents_dedupe_moveToFront_andCapAtFive() {
        var list: [String] = []
        for hex in ["#111111", "#222222", "#333333", "#444444", "#555555", "#666666"] {
            list = InkPalette.addingRecent(hex, to: list)
        }
        XCTAssertEqual(list, ["#666666", "#555555", "#444444", "#333333", "#222222"], "capped at five, newest first")

        list = InkPalette.addingRecent("#333333", to: list)
        XCTAssertEqual(list.first, "#333333")
        XCTAssertEqual(list.count, 5, "re-adding does not duplicate")
        XCTAssertEqual(Set(list).count, 5)

        list = InkPalette.addingRecent("#aabbcc", to: ["#AABBCC"])
        XCTAssertEqual(list, ["#AABBCC"], "case-insensitive dedupe")
    }

    func testRecents_ignoreSwatchColours_andGarbage() {
        XCTAssertEqual(InkPalette.addingRecent("#FF3B30", to: ["#123456"]), ["#123456"], "a swatch is not a custom colour")
        XCTAssertEqual(InkPalette.addingRecent("nonsense", to: []), [])
    }

    func testRecents_roundTripThroughStorage_andTolerateBadData() {
        let list = ["#111111", "#222222"]
        XCTAssertEqual(InkPalette.decodeRecents(InkPalette.encodeRecents(list)), list)
        XCTAssertEqual(InkPalette.decodeRecents(""), [])
        XCTAssertEqual(InkPalette.decodeRecents("#111111,zzz,#111111,#22222"), ["#111111"])
        let long = (1...9).map { "#00000\($0)" }.joined(separator: ",")
        XCTAssertEqual(InkPalette.decodeRecents(long).count, InkPalette.recentLimit)
    }

    func testQuickWidths_stayInsideEachToolsRange_andAscend() {
        for range in [1.0...20.0, 8.0...40.0, 5.0...60.0] {
            let values = QuickWidth.values(in: range)
            XCTAssertEqual(values.count, 3)
            XCTAssertEqual(values, values.sorted())
            for v in values { XCTAssertTrue(range.contains(v), "\(v) outside \(range)") }
            XCTAssertEqual(Set(values).count, 3, "thin, medium and thick differ in \(range)")
        }
    }

    func testQuickWidth_indexFindsTheMatchingSize() {
        let range = 1.0...20.0
        let values = QuickWidth.values(in: range)
        XCTAssertEqual(QuickWidth.index(of: values[1], in: range), 1)
        XCTAssertEqual(QuickWidth.index(of: values[2] + 0.2, in: range), 2)
        XCTAssertNil(QuickWidth.index(of: range.lowerBound, in: range), "the thinnest possible width is not a quick size")
    }
}
