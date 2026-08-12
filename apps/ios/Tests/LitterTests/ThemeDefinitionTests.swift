import XCTest
@testable import Litter

final class ThemeDefinitionTests: XCTestCase {
    func testThemeDefinitionIgnoresNullAndNonStringColorEntries() throws {
        let data = Data(
            """
            {
              "name": "night-owl",
              "type": "dark",
              "colors": {
                "editor.background": "#011627",
                "editor.findRangeHighlightBackground": null,
                "editor.foreground": "#d6deeb",
                "symbolIcon.constantForeground": ["#79c0ff", "#d2a8ff"]
              }
            }
            """.utf8
        )

        let theme = try JSONDecoder().decode(ThemeDefinition.self, from: data)

        XCTAssertEqual(theme.colors["editor.background"], "#011627")
        XCTAssertEqual(theme.colors["editor.foreground"], "#d6deeb")
        XCTAssertNil(theme.colors["editor.findRangeHighlightBackground"])
        XCTAssertNil(theme.colors["symbolIcon.constantForeground"])
    }

    func testThemeDefinitionStripsAlphaFromEightDigitHex() throws {
        let data = Data(
            """
            {
              "name": "alpha-theme",
              "type": "dark",
              "colors": {
                "button.background": "#7e57c2cc",
                "editor.background": "#011627"
              }
            }
            """.utf8
        )

        let theme = try JSONDecoder().decode(ThemeDefinition.self, from: data)

        // 8-digit #RRGGBBAA is sanitized to 6-digit #RRGGBB at decode time
        // so downstream color helpers see a well-formed RGB string.
        XCTAssertEqual(theme.colors["button.background"], "#7e57c2")
        XCTAssertEqual(theme.colors["editor.background"], "#011627")
    }

    func testChatGPTDarkPaletteMatchesLocalStudioReferenceTokens() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = sourceDirectory
            .appendingPathComponent("Sources/Litter/Resources/Themes/chatgpt-dark.json")
        let definition = try JSONDecoder().decode(ThemeDefinition.self, from: Data(contentsOf: url))
        let theme = ResolvedTheme(slug: "chatgpt-dark", definition: definition)

        XCTAssertEqual(theme.background, "#191919")
        XCTAssertEqual(theme.surface, "#202020")
        XCTAssertEqual(theme.surfaceLight, "#212121")
        XCTAssertEqual(theme.textPrimary, "#d9d9d8")
        XCTAssertEqual(theme.textSecondary, "#a0a09f")
        XCTAssertEqual(theme.textMuted, "#626262")
        XCTAssertEqual(theme.border, "#2a2a2a")
        XCTAssertEqual(theme.separator, "#202020")
    }
}
