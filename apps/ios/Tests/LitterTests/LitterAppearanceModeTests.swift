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
