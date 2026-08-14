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
        XCTAssertTrue(app.staticTexts["UITEST_CODE_BLOCK"].exists)
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

    // MARK: - PERF-0a deterministic perf tests

    @MainActor
    func testBodyEvaluationCountAt1500() throws {
        let app = midhistoryHarnessApp()
        app.launch()

        XCTAssertTrue(app.otherElements["conversationDisplayHarness.timeline"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["UITEST_PATTERN_USER_0"].waitForExistence(timeout: 10))

        // Mount liveness: publish once before any reset and assert the
        // timeline mounted at least one row (guards against a vacuous zero).
        app.buttons["harness.publishCounters"].tap()
        var counters = readCounters(in: app)
        let initialEpoch = counters["epoch"] as? Int ?? 0
        let initialTotals = (counters["totals"] as? [String: Int]) ?? [:]
        XCTAssertGreaterThanOrEqual(initialTotals["TimelineRow"] ?? 0, 1, "timeline rows must mount")

        // Phase 1: streaming delta batch. StreamingRendererCoordinator updates
        // the streaming bubble BELOW ConversationTimelineItemRow's Equatable
        // (assistant rows skip renderDigest), so no timeline row body may
        // re-evaluate on a text delta. SessionRow/Header/HomeCard must be 0.
        app.buttons["harness.resetCounters"].tap()
        app.buttons["harness.streamBatch"].tap()
        app.buttons["harness.publishCounters"].tap()

        counters = readCounters(in: app)
        var totals = (counters["totals"] as? [String: Int]) ?? [:]
        var rows = (counters["rows"] as? [String: [String: Int]]) ?? [:]
        let timelineRows = rows["TimelineRow"] ?? [:]
        XCTAssertEqual(counters["epoch"] as? Int ?? 0, initialEpoch + 1, "epoch must advance on reset")
        XCTAssertEqual(totals["TimelineRow"] ?? 0, 0)
        XCTAssertEqual(totals["SessionRow"] ?? 0, 0)
        XCTAssertEqual(totals["Header"] ?? 0, 0)
        XCTAssertEqual(totals["HomeCard"] ?? 0, 0)
        XCTAssertTrue(timelineRows.isEmpty, "no timeline row body may re-evaluate on a streaming delta: \(timelineRows)")

        // Phase 2: mid-history tool completion — positive control. Exactly the
        // tool row (mh-tool-K) re-evaluates (turn-state transition sample):
        // target 1, binding ≤2, all other surfaces 0.
        app.buttons["harness.resetCounters"].tap()
        app.buttons["harness.completeMidhistoryTool"].tap()
        app.buttons["harness.publishCounters"].tap()

        counters = readCounters(in: app)
        totals = (counters["totals"] as? [String: Int]) ?? [:]
        rows = (counters["rows"] as? [String: [String: Int]]) ?? [:]
        let toolTimelineRows = rows["TimelineRow"] ?? [:]
        XCTAssertEqual(counters["epoch"] as? Int ?? 0, initialEpoch + 2, "epoch must advance on second reset")
        XCTAssertEqual(totals["SessionRow"] ?? 0, 0)
        XCTAssertEqual(toolTimelineRows.count, 1, "exactly one key expected: \(toolTimelineRows)")
        let toolHits = toolTimelineRows["mh-tool-K"] ?? 0
        XCTAssertGreaterThanOrEqual(toolHits, 1)
        XCTAssertLessThanOrEqual(toolHits, 2)
        XCTAssertEqual(totals["TimelineRow"] ?? 0, toolHits)
        // Tool-result content visibility is proven by the dedicated 7-item
        // `testMidhistoryToolCompletionRendersResult` (COMMAND_MODE=expanded);
        // keep this 1500-item scale/counter gate free of a text assertion.
    }

    @MainActor
    func testMidhistoryToolCompletionRendersResult() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_SCENARIO"] = "midhistory-tool-result"
        app.launchEnvironment["CODEXIOS_UI_TEST_COMMAND_MODE"] = "expanded"
        app.launch()

        let toolButton = app.buttons["harness.completeMidhistoryTool"]
        XCTAssertTrue(toolButton.waitForExistence(timeout: 10))
        toolButton.tap()

        let resultText = app.staticTexts["ui-test tool result K"]
        if resultText.waitForExistence(timeout: 10) {
            return
        }

        // Fallback: an existing combined command-row accessibility element
        // whose label or value carries the rendered result.
        let labelPredicate = NSPredicate(format: "label CONTAINS %@", "ui-test tool result K")
        let valuePredicate = NSPredicate(format: "value CONTAINS %@", "ui-test tool result K")
        let combined = app.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: [labelPredicate, valuePredicate]))
            .firstMatch
        if combined.waitForExistence(timeout: 5) {
            return
        }

        XCTFail("Mid-history tool completion result is not accessible as a static text or combined command-row element")
    }

    @MainActor
    func testConversationScrollPerformanceAt1500() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_ITEM_COUNT"] = "1500"
        app.launch()

        XCTAssertTrue(app.otherElements["conversationDisplayHarness.timeline"].waitForExistence(timeout: 15))

        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric]) {
            for _ in 0..<6 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
    }

    @MainActor
    func testComposerKeystrokeLatency() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launch()

        let composer = app.textViews["conversation.composerTextView"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        measure(metrics: [XCTClockMetric()]) {
            composer.typeText("PERF0A_TYPING_PROBE")
        }
    }

    @MainActor
    func testBackToListPerformanceAt300Sessions() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_SESSION_COUNT"] = "300"
        app.launchEnvironment["CODEXIOS_UI_TEST_ITEM_COUNT"] = "1500"
        app.launch()

        let firstRow = app.buttons["harness.sessionRow-0"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        firstRow.tap()
        XCTAssertTrue(app.navigationBars["Display Harness"].waitForExistence(timeout: 15))

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<5 {
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(app.buttons["harness.sessionRow-0"].waitForExistence(timeout: 5))
                app.buttons["harness.sessionRow-0"].tap()
                XCTAssertTrue(app.navigationBars["Display Harness"].waitForExistence(timeout: 5))
            }
        }
    }

    @MainActor
    private func midhistoryHarnessApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-conversation-display")
        app.launchEnvironment["CODEXIOS_UI_TEST_SCENARIO"] = "midhistory-tool-result"
        app.launchEnvironment["CODEXIOS_UI_TEST_ITEM_COUNT"] = "1500"
        app.launchEnvironment["CODEXIOS_UI_TEST_COMMAND_MODE"] = "expanded"
        return app
    }

    @MainActor
    private func readCounters(in app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["harness.bodyEvalCounts"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let raw = (element.value as? String) ?? "{}"
        XCTAssertNotEqual(raw, "{}", "published counters JSON must not be the empty stub")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Could not decode counters JSON: \(raw)")
            return [:]
        }
        return object
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
