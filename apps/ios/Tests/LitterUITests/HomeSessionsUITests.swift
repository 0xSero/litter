import XCTest

/// Component acceptance only: synthetic sessions, production viewport/rows,
/// local NavigationStack detail. Real host transport is exercised separately.
final class HomeSessionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeSessionsDeepScrollAndBackAtEveryZoom() {
        let app = launchHarness()
        for level in 1...4 {
            app.buttons["homeHarness.zoom.\(level)"].tap()
            waitForValue(String(level), element: app.staticTexts["homeHarness.zoom"])
            app.buttons["homeHarness.deep"].tap()
            let row = app.staticTexts["Session 0900"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            assertBoundedMounts(app)
            row.tap()
            XCTAssertTrue(app.staticTexts["homeHarness.detail"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["homeHarness.detail"].label, "Session 0900")
            app.navigationBars["Session detail"].buttons["Sessions"].tap()
            XCTAssertTrue(app.buttons["homeHarness.deep"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["homeHarness.actions"].label.contains("Opened \(level)"))
            assertBoundedMounts(app)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testHomeSessionsPinchSwipeAndScrollStayResponsive() {
        let app = launchHarness()
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.pinch(withScale: 1.8, velocity: 1)
        let zoomChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "2"),
            object: app.staticTexts["homeHarness.zoom"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [zoomChanged], timeout: 5), .completed)
        assertBoundedMounts(app)

        app.buttons["homeHarness.zoom.2"].tap()
        app.buttons["homeHarness.top"].tap()
        let row = app.staticTexts["Session 0000"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: list.frame.minX + 35, dy: row.frame.midY))
        let end = origin.withOffset(CGVector(dx: list.frame.maxX - 35, dy: row.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: end)
        let replied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "replies 1"),
            object: app.staticTexts["homeHarness.actions"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [replied], timeout: 5), .completed)
        let firstVisible = app.staticTexts["homeHarness.visible"].value as? String
        list.swipeUp()
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", firstVisible ?? "none"),
            object: app.staticTexts["homeHarness.visible"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        assertBoundedMounts(app)
    }

    @MainActor
    func testRichHomeSessionsKeepDeepSessionThroughTextScalePinchAndBack() {
        let app = launchHarness(richContent: true)
        defer { app.terminate() }
        waitForValue("150", element: app.staticTexts["homeHarness.textScale"])
        app.buttons["homeHarness.zoom.4"].tap()
        waitForValue("4", element: app.staticTexts["homeHarness.zoom"])
        app.buttons["homeHarness.deep"].tap()
        waitForValue("session-900", element: app.staticTexts["homeHarness.visible"])
        for scale in [100, 150] {
            app.buttons["homeHarness.textScale.\(scale)"].tap()
            waitForValue(String(scale), element: app.staticTexts["homeHarness.textScale"])
            waitForValue("session-900", element: app.staticTexts["homeHarness.visible"])
            assertBoundedMounts(app)
        }

        // Page-fit starts with session 900 filling the viewport, so the real
        // pinch midpoint belongs to that key. At smaller zoom it need not be
        // the first visible row, but must stay visible and remain openable.
        // Zoom snaps to {1, 2, 4}: at 1.4 levels/octave, 0.7 reaches
        // 3.28 and correctly snaps back to 4. Halving crosses the 3.0 boundary.
        app.scrollViews.firstMatch.pinch(withScale: 0.5, velocity: -1)
        let trace = app.staticTexts["homeHarness.pinchTrace"].value as? String ?? "missing"
        print("RICH_PINCH_TRACE \(trace)")
        let afterPinch = XCTAttachment(string: trace)
        afterPinch.name = "Rich fixture after pinch"
        afterPinch.lifetime = .keepAlways
        add(afterPinch)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "4"),
            object: app.staticTexts["homeHarness.zoom"]
        )], timeout: 5), .completed)
        let row = app.staticTexts["Session 0900"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable)
        assertBoundedMounts(app)
        row.tap()
        XCTAssertTrue(app.staticTexts["homeHarness.detail"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["homeHarness.detail"].label, "Session 0900")
        app.navigationBars["Session detail"].buttons["Sessions"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable)
        XCTAssertEqual(app.staticTexts["homeHarness.lastAction"].label, "opened session-900")
        assertBoundedMounts(app)
    }

    @MainActor
    private func launchHarness(richContent: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-home-sessions"]
        if richContent {
            app.launchEnvironment["LITTER_UI_TEST_RICH_HOME"] = "1"
            app.launchEnvironment["LITTER_UI_TEST_HOME_TEXT_SCALE"] = "1.5"
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["homeHarness.total"].waitForExistence(timeout: 15))
        waitForValue("1000", element: app.staticTexts["homeHarness.total"])
        return app
    }

    @MainActor
    private func assertBoundedMounts(_ app: XCUIApplication) {
        let mounted = Int(app.staticTexts["homeHarness.mounted"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(mounted, 0)
        XCTAssertLessThan(mounted, 160, "Only viewport plus overscan should be mounted, never all 1,000 rows")
    }

    private func waitForValue(_ value: String, element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element
        )], timeout: 5), .completed)
    }
}
