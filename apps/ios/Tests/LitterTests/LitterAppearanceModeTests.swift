import SwiftUI
import UIKit
import XCTest
@testable import Litter

final class LitterAppearanceModeTests: XCTestCase {
    func testPreferredColorSchemeMapping() {
        XCTAssertNil(LitterAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(LitterAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(LitterAppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testResolvedColorSchemeUsesSystemOnlyForSystemMode() {
        XCTAssertEqual(LitterAppearanceMode.system.resolvedColorScheme(systemColorScheme: .light), .light)
        XCTAssertEqual(LitterAppearanceMode.system.resolvedColorScheme(systemColorScheme: .dark), .dark)
        XCTAssertEqual(LitterAppearanceMode.light.resolvedColorScheme(systemColorScheme: .dark), .light)
        XCTAssertEqual(LitterAppearanceMode.dark.resolvedColorScheme(systemColorScheme: .light), .dark)
    }

    func testUserInterfaceStyleMapping() {
        XCTAssertEqual(LitterAppearanceMode.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(LitterAppearanceMode.light.userInterfaceStyle, .light)
        XCTAssertEqual(LitterAppearanceMode.dark.userInterfaceStyle, .dark)
    }
}

final class FontFamilyOptionTests: XCTestCase {
    func testFontChoicesKeepStableStorageValues() {
        XCTAssertEqual(FontFamilyOption.allCases.map(\.rawValue), [
            "mono",
            "system",
            "system-mono",
            "serif",
        ])
    }

    func testChatGPTAndReaderChoicesUseProportionalFamilies() {
        XCTAssertFalse(FontFamilyOption.system.isMono)
        XCTAssertFalse(FontFamilyOption.serif.isMono)
        XCTAssertTrue(FontFamilyOption.mono.isMono)
        XCTAssertTrue(FontFamilyOption.systemMono.isMono)
        XCTAssertEqual(FontFamilyOption.system.displayName, "ChatGPT (System)")
    }
}
