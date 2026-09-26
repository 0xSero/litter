import XCTest

/// End-to-end QA against a real kittylitter host. Skipped unless
/// `LITTER_E2E_PAIR_JSON_FILE` points at a pairing JSON file (passed with
/// the `TEST_RUNNER_` prefix). Screenshots go to `LITTER_E2E_SHOT_DIR`,
/// timings are printed as `E2E_TIMING <step> <seconds>`.
final class LiveE2EUITests: XCTestCase {
    private var shotDir: String?

    override func setUpWithError() throws {
        continueAfterFailure = true
        shotDir = ProcessInfo.processInfo.environment["LITTER_E2E_SHOT_DIR"]
    }

    @MainActor
    func testLivePairOpenSendBack() throws {
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
        var t = Date()
        app.launch()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
        timing("launch_to_home", since: t)
        shot(app, "01-home-launch")

        // Launchable computers show in the greeting's picker ("on <host>").
        let hostChip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.computerPicker' AND label CONTAINS[c] %@", "seros-macbook"))
            .firstMatch
        if !hostChip.waitForExistence(timeout: 5) {
            pair(app, json: json)
        }
        t = Date()
        XCTAssertTrue(hostChip.waitForExistence(timeout: 45), "computer never connected")
        timing("host_connected", since: t)
        shot(app, "02-home-connected")

        dismissSystemPrompts()

        // ChatGPT flow: type on the home composer, send, land in the new chat.
        let homeComposer = app.textViews.firstMatch
        XCTAssertTrue(homeComposer.waitForExistence(timeout: 10), "home composer missing")
        shot(app, "03-home-composer")
        homeComposer.tap()
        homeComposer.typeText("Reply with exactly the word pong and nothing else.")
        allowPasteIfPrompted()
        t = Date()
        app.buttons["Send"].tap()
        let pong = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'pong' OR label ==[c] 'pong.'")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 120), "no pong reply in new chat")
        timing("home_send_to_reply", since: t)
        dismissSystemPrompts()
        shot(app, "04-new-chat-reply")

        t = Date()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.allSessionsButton"].waitForExistence(timeout: 5))
        timing("back_to_home", since: t)
        shot(app, "05-home-after-back")

        // Existing session: history must load.
        t = Date()
        app.buttons["home.allSessionsButton"].tap()
        let firstRow = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "no sessions listed")
        timing("sessions_list", since: t)
        shot(app, "06-sessions")
        t = Date()
        firstRow.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 20))
        timing("open_session", since: t)
        let transcriptLoaded = NSPredicate(format: "count > 4")
        expectation(for: transcriptLoaded, evaluatedWith: app.staticTexts)
        waitForExpectations(timeout: 20)
        timing("open_session_history", since: t)
        shot(app, "07-existing-session")

        // Edge swipe back.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "edge swipe did not go back")
        shot(app, "08-after-swipe-back")
    }

    private func dismissSystemPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow"] {
            let button = springboard.buttons[label]
            if button.exists { button.tap() }
        }
    }

    private func pair(_ app: XCUIApplication, json: String) {
        // Computers are added from Settings.
        app.buttons["home.settingsButton"].tap()
        let computers = app.buttons["settings.category.computers"]
        XCTAssertTrue(computers.waitForExistence(timeout: 5))
        shot(app, "00-settings-root")
        computers.tap()
        let add = app.buttons["settings.addComputer"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        shot(app, "00-settings-computers")
        add.tap()
        app.buttons["discovery.chooser.kittylitter"].tap()
        sleep(2)
        app.tap() // trigger interruption monitor for the camera prompt
        if app.alerts.buttons["Paste JSON Instead"].waitForExistence(timeout: 3) {
            app.alerts.buttons["Paste JSON Instead"].tap()
        }
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
        shot(app, "00-pair-parsed")
        let connect = app.buttons["alleycat.pair.toolbarConnect"]
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: connect)
        waitForExpectations(timeout: 30)
        connect.tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.computerRow' AND label CONTAINS[c] %@", "seros-macbook"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "computer not listed in Settings")
        shot(app, "00-settings-after-pair")
        app.navigationBars["Computers"].buttons.element(boundBy: 0).tap()
        let done = app.buttons["settings.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 5))
    }

    /// XCUITest types long strings through the pasteboard, which triggers
    /// the system "Allow Paste" prompt owned by SpringBoard.
    private func allowPasteIfPrompted() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    private func timing(_ step: String, since: Date) {
        print(String(format: "E2E_TIMING %@ %.2f", step, Date().timeIntervalSince(since)))
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shotDir {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shotDir).appendingPathComponent("\(name).png"))
        }
    }
}
