import SwiftUI
import UIKit
import XCTest
@testable import Litter

final class HexColorTests: XCTestCase {
    func testAlphaLastCssHexPreservesAlpha() throws {
        let rgba = try XCTUnwrap(litterHexRGBA("#45858880"))
        XCTAssertEqual(rgba.red, 0x45 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgba.green, 0x85 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgba.blue, 0x88 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, 0x80 / 255, accuracy: 0.0001)
    }

    func testOpaqueAndShorthandForms() throws {
        let opaque = try XCTUnwrap(litterHexRGBA("#458588"))
        XCTAssertEqual(opaque.alpha, 1, accuracy: 0.0001)
        XCTAssertEqual(opaque.red, 0x45 / 255, accuracy: 0.0001)

        // #RGB and #RGBA shorthand expand each nibble.
        let rgb = try XCTUnwrap(litterHexRGBA("#f0a"))
        XCTAssertEqual(rgb.red, 0xFF / 255, accuracy: 0.0001)
        XCTAssertEqual(rgb.green, 0x00 / 255, accuracy: 0.0001)
        XCTAssertEqual(rgb.blue, 0xAA / 255, accuracy: 0.0001)
        let rgba = try XCTUnwrap(litterHexRGBA("#f0a5"))
        XCTAssertEqual(rgba.blue, 0xAA / 255, accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, 0x55 / 255, accuracy: 0.0001)
    }

    func testUppercaseAndPaddedInput() throws {
        let rgba = try XCTUnwrap(litterHexRGBA(" #4585AA80 "))
        XCTAssertEqual(rgba.blue, 0xAA / 255, accuracy: 0.0001)
        XCTAssertEqual(rgba.alpha, 0x80 / 255, accuracy: 0.0001)
    }

    func testInvalidInputReturnsNil() {
        XCTAssertNil(litterHexRGBA("#invalid"))
        XCTAssertNil(litterHexRGBA("#1234567"))
        XCTAssertNil(litterHexRGBA(""))
        XCTAssertNil(litterHexRGBA("#zzzzzz"))
        // A leading sign is not a hex digit and must not parse.
        XCTAssertNil(litterHexRGBA("#-12345"))
        XCTAssertNil(litterHexRGBA("#+12345"))
    }

    func testThemeDecodeStripsAlphaFromTokens() throws {
        // Theme tokens must stay opaque so they match Android's
        // tokenColorFromHex and the generated Material schemes.
        let json = """
        {"name":"T","type":"dark","colors":{
          "button.background":"#45858880",
          "editorGroup.border":"#0000",
          "editor.background":"#111111"
        }}
        """
        let theme = try JSONDecoder().decode(ThemeDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(theme.colors["button.background"], "#458588")
        XCTAssertEqual(theme.colors["editorGroup.border"], "#000000")
    }

    func testUIColorInitializerCarriesAlpha() {
        let color = UIColor(hex: "#45858880")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(alpha, 0x80 / 255, accuracy: 0.0001)
        XCTAssertEqual(red, 0x45 / 255, accuracy: 0.0001)
    }

    func testLitterPaletteColorFromHexKeepsAlpha() {
        let color = LitterPalette.Pair.colorFromHex("#45858880")
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(alpha, 0x80 / 255, accuracy: 0.0001)
        XCTAssertEqual(red, 0x45 / 255, accuracy: 0.0001)
    }
}
