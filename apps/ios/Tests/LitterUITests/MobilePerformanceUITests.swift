import XCTest

/// Run on a dedicated simulator. These tests never clear app data, edit saved
/// servers, or override persistent preferences. Save the xcresult and device/OS
/// identity with each run; no portable timing threshold is asserted here.
final class MobilePerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainHomeLaunchPerformance() {
        let app = XCUIApplication()
        // Deliberately no --ui-test-* flag: run AppModel/Rust bootstrap and the
        // standard ContentView/HomeNavigationView, not the conversation fixture.
        // The dedicated simulator must have no restored conversation route.
        let options = measurementOptions()
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true), XCTClockMetric()], options: options) {
            app.terminate()
            startMeasuring()
            app.launch()
            let settings = app.buttons["home.settingsButton"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 20), "Expected the normal Home route; use an isolated simulator without a restored conversation")
            waitUntilHittable(settings)
            stopMeasuring()
        }
        app.terminate()
    }

    @MainActor
    func testHomeSessionsOpenBackResourcesZoom1() { measureOpenBack(zoom: 1) }

    @MainActor
    func testHomeSessionsOpenBackResourcesZoom2() { measureOpenBack(zoom: 2) }

    @MainActor
    func testHomeSessionsOpenBackResourcesZoom3() { measureOpenBack(zoom: 3) }

    @MainActor
    func testHomeSessionsOpenBackResourcesZoom4() { measureOpenBack(zoom: 4) }

    @MainActor
    private func measureOpenBack(zoom: Int) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-home-sessions"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["homeHarness.total"].waitForExistence(timeout: 20))
        app.buttons["homeHarness.zoom.\(zoom)"].tap()
        XCTAssertEqual(app.staticTexts["homeHarness.zoom"].value as? String, String(zoom))
        app.buttons["homeHarness.deep"].tap()
        let row = app.staticTexts["Session 0900"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        waitUntilHittable(row)

        // Target the app process, not the UI-test runner. Every sample is two
        // open/Back cycles at one fixed zoom. Setup, launch and deep scrolling
        // are excluded. Keep the same process alive across samples so repeated
        // allocations remain observable; this alone is not a leak test.
        // Wall time includes XCTest event injection, idle waits and assertions;
        // it must not be reported as touch-to-frame or production navigation.
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: measurementOptions()) {
            startMeasuring()
            for _ in 0..<2 {
                row.tap()
                XCTAssertTrue(app.staticTexts["homeHarness.detail"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.staticTexts["homeHarness.detail"].label, "Session 0900")
                app.navigationBars["Session detail"].buttons["Sessions"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                waitUntilHittable(row)
            }
            stopMeasuring()
            let mounted = Int(app.staticTexts["homeHarness.mounted"].value as? String ?? "") ?? 0
            XCTAssertGreaterThan(mounted, 0)
            XCTAssertLessThan(mounted, 160, "Repeated navigation must retain bounded viewport mounts")
        }
    }

    private func measurementOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        // XCTest additionally runs one discarded warm-up iteration. Repeated
        // launches retain OS caches and are not cold-install launch samples.
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
