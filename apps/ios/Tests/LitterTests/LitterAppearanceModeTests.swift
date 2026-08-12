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

    func testSystemAndReaderChoicesUseProportionalFamilies() {
        XCTAssertFalse(FontFamilyOption.system.isMono)
        XCTAssertFalse(FontFamilyOption.serif.isMono)
        XCTAssertTrue(FontFamilyOption.mono.isMono)
        XCTAssertTrue(FontFamilyOption.systemMono.isMono)
        XCTAssertEqual(FontFamilyOption.system.displayName, "System UI")
    }

    func testFontPreferenceObserverAdvancesRevision() {
        let observer = FontPreferenceObserver()

        observer.didChange()
        observer.didChange()

        XCTAssertEqual(observer.revision, 2)
    }
}

final class ConversationTextSizeTests: XCTestCase {
    func testStoredValueIsBoundedToSupportedSteps() {
        XCTAssertEqual(ConversationTextSize.clamped(rawValue: -42), .tiny)
        XCTAssertEqual(ConversationTextSize.clamped(rawValue: 42), .huge)
    }

    func testMediumIsTheUnscaledReadingDefault() {
        XCTAssertEqual(ConversationTextSize.medium.scale, 1.0)
    }
}

final class LitterPlatformLayoutTests: XCTestCase {
    func testPhoneDoesNotCreateSplitNavigationFromRegularSizeClass() {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return
        }

        XCTAssertFalse(LitterPlatform.isRegularSurface(horizontalSizeClass: .regular))
    }
}
