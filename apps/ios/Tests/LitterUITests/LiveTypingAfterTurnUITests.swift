import XCTest

/// Regression check for "typing freezes after the first turn settles".
/// Runs against a real kittylitter host, like `LiveE2EUITests`, and is
/// skipped unless `LITTER_E2E_PAIR_JSON_FILE` is set (pass it with the
/// `TEST_RUNNER_` prefix). Prints `E2E_TIMING <step> <seconds>`.
final class LiveTypingAfterTurnUITests: XCTestCase {
    private let draft = String(repeating: "the quick brown fox jumps ", count: 4)

    @MainActor
    func testTypingStaysResponsiveAfterTurnSettles() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LITTER_E2E_PAIR_JSON_FILE"],
              let json = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("LITTER_E2E_PAIR_JSON_FILE not set")
        }
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Allow Paste", "Paste JSON Instead"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
        sleep(3)
        // The phone's own runtime can open an OpenAI sign-in web sheet.
        for label in ["Close", "Cancel"] where app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
            sleep(1)
        }

        // The phone's own runtime is also a "computer"; pick the paired Mac.
        let picker = app.descendants(matching: .any)["home.computerPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "computer picker missing")
        if !selectMac(app, picker: picker) {
            pair(app, json: json)
            XCTAssertTrue(picker.waitForExistence(timeout: 20))
            let deadline = Date().addingTimeInterval(45)
            var selected = false
            while !selected && Date() < deadline {
                selected = selectMac(app, picker: picker)
                if !selected { sleep(3) }
            }
            XCTAssertTrue(selected, "paired Mac never became selectable")
        }

        // Baseline: the same draft on the home composer, before any turn.
        let homeComposer = app.textViews.firstMatch
        XCTAssertTrue(homeComposer.waitForExistence(timeout: 10))
        homeComposer.tap()
        var t = Date()
        homeComposer.typeText(draft)
        timing("type_home_baseline", since: t)
        clear(homeComposer)

        homeComposer.typeText(
            "Write a markdown answer with a heading, three short paragraphs, "
                + "a bullet list of eight items, and a 20-line Swift code block. "
                + "Do not run any tools."
        )
        let send = app.buttons["conversation.sendButton"].firstMatch
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 10)
        send.tap()

        let stop = app.buttons["conversation.cancel-responseButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 60), "turn never started")
        t = Date()
        let settled = NSPredicate(format: "exists == false")
        expectation(for: settled, evaluatedWith: stop)
        waitForExpectations(timeout: 240)
        timing("turn_duration", since: t)
        sleep(3)
        dismissSpringboardAlerts()

        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        print("E2E_MARK typing_start \(Date().timeIntervalSince1970)")
        t = Date()
        composer.typeText(draft)
        timing("type_after_settle", since: t)
        t = Date()
        composer.typeText(draft)
        timing("type_after_settle_2", since: t)
        print("E2E_MARK typing_end \(Date().timeIntervalSince1970)")
    }

    /// Opens the computer picker and selects the paired Mac. Returns false
    /// (with the menu dismissed) when no Mac is listed.
    private func selectMac(_ app: XCUIApplication, picker: XCUIElement) -> Bool {
        if (picker.label as NSString).range(of: "macbook", options: .caseInsensitive).location != NSNotFound {
            return true
        }
        picker.tap()
        let mac = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'macbook'")).firstMatch
        if mac.waitForExistence(timeout: 3) {
            mac.tap()
            sleep(1)
            return true
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        return false
    }

    /// The notification permission prompt appears after the first turn.
    private func dismissSpringboardAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
            sleep(1)
        }
    }

    private func clear(_ element: XCUIElement) {
        guard let value = element.value as? String, !value.isEmpty else { return }
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }

    private func pair(_ app: XCUIApplication, json: String) {
        app.buttons["home.settingsButton"].tap()
        let computers = app.buttons["settings.category.computers"]
        XCTAssertTrue(computers.waitForExistence(timeout: 5))
        computers.tap()
        let add = app.buttons["settings.addComputer"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        app.buttons["discovery.chooser.kittylitter"].tap()
        sleep(2)
        app.tap() // trigger the interruption monitor for the camera prompt
        if app.alerts.buttons["Paste JSON Instead"].waitForExistence(timeout: 3) {
            app.alerts.buttons["Paste JSON Instead"].tap()
        }
        // The QR scanner opens as a full-screen cover over the paste button.
        let cancelScanner = app.buttons["Cancel"].firstMatch
        if cancelScanner.waitForExistence(timeout: 3) { cancelScanner.tap(); sleep(1) }
        let paste = app.buttons["Paste Pairing JSON"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let field = app.textViews["alleycat.pair.jsonField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(json.trimmingCharacters(in: .whitespacesAndNewlines))
        allowPasteIfPrompted()
        app.buttons["Parse JSON"].tap()
        allowPasteIfPrompted()
        let connect = app.buttons["alleycat.pair.toolbarConnect"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: connect)
        waitForExpectations(timeout: 30)
        connect.tap()
        let row = app.descendants(matching: .any)["settings.computerRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "computer not listed in Settings")
        app.navigationBars["Computers"].buttons.element(boundBy: 0).tap()
        let done = app.buttons["settings.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    private func allowPasteIfPrompted() {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    private func timing(_ step: String, since: Date) {
        print(String(format: "E2E_TIMING %@ %.2f", step, Date().timeIntervalSince(since)))
    }
}
