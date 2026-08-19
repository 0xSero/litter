import XCTest

final class MessageLinkUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBareUrlsRenderAsTappableLinks() throws {
        let app = launchDisplayHarness()

        let link = app.links["https://example.com/releases/latest"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(app.links["https://docs.example.com/setup"].exists)
    }

    @MainActor
    func testLongPressOffersCopyLink() throws {
        let app = launchDisplayHarness()

        let message = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Deployed the preview build")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 1.2)

        let copyLink = app.buttons["Copy example.com/releases/latest"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy docs.example.com/setup"].exists)

        saveScreenshot(app, name: "litter-ui-copy-link-menu")

        copyLink.tap()
        XCTAssertTrue(app.staticTexts["Conversation Display Test"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchDisplayHarness() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launch()
        return app
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let data = app.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }
}
