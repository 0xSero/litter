import XCTest

final class SkillMentionPillUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSkillPillRendersAndOpensDetailSheet() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launch()

        let pill = app.buttons["Skill cad"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Skill mujoco"].exists)

        saveScreenshot(app, name: "skill-pills-in-chat")

        pill.tap()

        XCTAssertTrue(app.staticTexts["CAD"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$cad"].exists)
        XCTAssertTrue(app.staticTexts["Default prompt"].exists)
        XCTAssertTrue(app.staticTexts["User"].exists)

        saveScreenshot(app, name: "skill-detail-sheet")

        app.buttons["Done"].tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/litter-ui-\(name).png"))
    }
}
