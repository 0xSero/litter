import XCTest

final class LitterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConversationDisplaySettingsRowsAreReachable() throws {
        let app = conversationDisplayHarnessApp()
        app.launchArguments.append("--ui-test-open-settings")
        app.launch()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conversation"].waitForExistence(timeout: 5))
        XCTAssertTrue(findStaticText("Internal Thinking", in: app))
        XCTAssertTrue(findStaticText("Commands", in: app))
        XCTAssertTrue(findStaticText("Tools", in: app))
    }

    @MainActor
    func testConversationDisplayExpandedModeShowsAllDetails() throws {
        let app = conversationDisplayHarnessApp(reasoning: "expanded", commands: "expanded", tools: "expanded")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
    }

    @MainActor
    func testConversationComposerAcceptsSimulatorKeyboardInput() throws {
        let app = conversationDisplayHarnessApp()
        app.launch()

        XCTAssertTrue(app.buttons["conversation.modelPickerButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Attach"].exists)
        XCTAssertTrue(app.buttons["Default"].exists)
        let composer = app.textViews["conversation.composerTextView"]
        XCTAssertTrue(composer.exists)
        composer.tap()
        composer.typeText("SIMULATOR_INPUT_OK")
        XCTAssertEqual(composer.value as? String, "SIMULATOR_INPUT_OK")
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testConversationComposerKeepsDictationVisibleWithLongModelName() throws {
        let app = conversationDisplayHarnessApp()
        app.launchEnvironment["CODEXIOS_UI_TEST_MODEL_LABEL"] = "HomeLab DeepSeek V4 Flash 0731 Experimental"
        app.launch()

        let dictate = app.buttons["conversation.dictateButton"]
        XCTAssertTrue(dictate.waitForExistence(timeout: 10))
        XCTAssertTrue(dictate.isHittable)
    }

    @MainActor
    func testConversationComposerPreservesRapidKeyboardInput() throws {
        let app = conversationDisplayHarnessApp()
        app.launch()

        let composer = app.textViews["conversation.composerTextView"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let prompt = "Rapid typing keeps every character in the correct order."
        composer.typeText(prompt)
        XCTAssertEqual(composer.value as? String, prompt)
    }

    @MainActor
    func testConversationLaunchPerformance() throws {
        let app = conversationDisplayHarnessApp()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            XCTAssertTrue(
                app.staticTexts["Conversation Display Test"].waitForExistence(timeout: 5),
                "Conversation surface did not become interactive after launch"
            )
            app.terminate()
        }
    }

    @MainActor
    func testConversationDisplayCollapsedModeKeepsCompletedDetailsCollapsed() throws {
        let app = conversationDisplayHarnessApp(reasoning: "collapsed", commands: "collapsed", tools: "collapsed")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertTrue(app.staticTexts["Thinking"].exists)
        XCTAssertTrue(app.staticTexts["Internal reasoning"].exists)
        XCTAssertTrue(app.staticTexts["printf UITEST_COMMAND_HEADER"].exists)
        XCTAssertTrue(app.staticTexts["uiTest.fixtureTool"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
        XCTAssertTrue(app.staticTexts["UITEST_LIVE_COMMAND_OUTPUT"].exists)
    }

    @MainActor
    func testConversationDisplayHiddenModeRemovesDetailRows() throws {
        let app = conversationDisplayHarnessApp(reasoning: "hidden", commands: "hidden", tools: "hidden")
        app.launch()

        XCTAssertTrue(app.staticTexts["UITEST_USER_MESSAGE"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_ASSISTANT_MESSAGE"].exists)
        XCTAssertFalse(app.staticTexts["Thinking"].exists)
        XCTAssertFalse(app.staticTexts["Internal reasoning"].exists)
        XCTAssertFalse(app.staticTexts["printf UITEST_COMMAND_HEADER"].exists)
        XCTAssertFalse(app.staticTexts["uiTest.fixtureTool"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_REASONING_DETAIL"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_COMMAND_OUTPUT"].exists)
        XCTAssertFalse(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        // Wait for splash to dismiss
        sleep(4)

        // 01 - Home (empty state)
        snapshot("01_Home")

        // 02 - Settings
        let settingsButton = app.buttons["header.settingsButton"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
            sleep(1)
            snapshot("02_Settings")

            // Dismiss settings
            app.swipeDown()
            sleep(1)
        }

        // 03 - Discovery
        let connectButton = app.buttons["Connect Server"]
        if connectButton.waitForExistence(timeout: 3), connectButton.isHittable {
            connectButton.tap()
            sleep(2)
            snapshot("03_Discovery")

            // Dismiss discovery
            app.swipeDown()
            sleep(1)
        }
    }

    @MainActor
    private func conversationDisplayHarnessApp(
        reasoning: String = "collapsed",
        commands: String = "collapsed",
        tools: String = "collapsed"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_REASONING_MODE"] = reasoning
        app.launchEnvironment["CODEXIOS_UI_TEST_COMMAND_MODE"] = commands
        app.launchEnvironment["CODEXIOS_UI_TEST_TOOL_MODE"] = tools
        return app
    }

    private func findStaticText(_ label: String, in app: XCUIApplication) -> Bool {
        let text = app.staticTexts[label]
        if text.exists {
            return true
        }

        for _ in 0..<4 {
            app.swipeUp()
            if text.waitForExistence(timeout: 1) {
                return true
            }
        }

        return false
    }
}
