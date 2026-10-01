import XCTest

/// Screenshot tour of the real app against a paired kittylitter host, for
/// design and history audits. Skipped unless `LITTER_E2E_TOUR` is set (pass
/// it with the `TEST_RUNNER_` prefix). Screenshots are kept as attachments.
final class LiveTourUITests: XCTestCase {
    @MainActor
    func testTour() throws {
        guard ProcessInfo.processInfo.environment["LITTER_E2E_TOUR"] != nil else {
            throw XCTSkip("LITTER_E2E_TOUR not set")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Don’t Allow", "Don't Allow", "Allow Paste"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
        sleep(4)
        dismissWebSheet(app)
        shot(app, "01-home")

        let picker = app.descendants(matching: .any)["home.computerPicker"].firstMatch
        if picker.waitForExistence(timeout: 5) {
            picker.tap()
            sleep(1)
            shot(app, "02-computer-picker")
            let mac = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'macbook'")).firstMatch
            if mac.waitForExistence(timeout: 3) {
                mac.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
                if let path = ProcessInfo.processInfo.environment["LITTER_E2E_PAIR_JSON_FILE"],
                   let json = try? String(contentsOfFile: path, encoding: .utf8) {
                    pair(app, json: json)
                    sleep(8)
                    picker.tap()
                    sleep(1)
                    shot(app, "02b-picker-after-pair")
                    if mac.waitForExistence(timeout: 20) { mac.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap() }
                }
            }
            sleep(2)
            dismissWebSheet(app)
            shot(app, "03-home-mac")
        }

        let model = app.descendants(matching: .any)["conversation.modelPickerButton"].firstMatch
        if model.waitForExistence(timeout: 5) {
            model.tap()
            sleep(2)
            shot(app, "04-model-picker")
            app.swipeUp()
            sleep(1)
            shot(app, "05-model-picker-scrolled")
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
            sleep(3)
            dismissWebSheet(app)
        }

        let allSessions = app.buttons["home.allSessionsButton"]
        if allSessions.waitForExistence(timeout: 10) { allSessions.tap() }
        let rows = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow")
        _ = rows.firstMatch.waitForExistence(timeout: 20)
        sleep(2)
        shot(app, "06-sessions")
        let count = min(rows.count, 4)
        for index in 0..<count {
            let row = rows.element(boundBy: index)
            guard row.exists, row.isHittable else { continue }
            let label = row.label
            row.tap()
            sleep(10)
            shot(app, "07-session-\(index)-\(label.prefix(30))")
            app.swipeDown()
            sleep(2)
            shot(app, "07-session-\(index)-scrolled")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(2)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)

        guard app.buttons["home.settingsButton"].waitForExistence(timeout: 10) else { return }
        app.buttons["home.settingsButton"].tap()
        sleep(1)
        shot(app, "08-settings")
        let categories = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.category.'"))
        let ids = (0..<categories.count).map { categories.element(boundBy: $0).identifier }
        for id in ids {
            let item = app.descendants(matching: .any)[id].firstMatch
            guard item.waitForExistence(timeout: 3) else { continue }
            if !item.isHittable { app.swipeUp() }
            guard item.isHittable else { continue }
            item.tap()
            sleep(2)
            shot(app, "09-\(id)")
            app.swipeUp()
            sleep(1)
            shot(app, "09-\(id)-scrolled")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
    }

    /// Opens the first session whose row label contains `LITTER_E2E_OPEN_MATCH`
    /// and holds it open, printing markers for an external sampler.
    @MainActor
    func testOpenSession() throws {
        guard let match = ProcessInfo.processInfo.environment["LITTER_E2E_OPEN_MATCH"] else {
            throw XCTSkip("LITTER_E2E_OPEN_MATCH not set")
        }
        let app = XCUIApplication()
        // LITTER_E2E_ATTACH drives an app already started with
        // `simctl launch --console-pty`, so its Rust stderr log is captured.
        if ProcessInfo.processInfo.environment["LITTER_E2E_ATTACH"] != nil {
            app.activate()
        } else {
            app.launch()
        }
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
        sleep(3)
        dismissWebSheet(app)
        let allSessions = app.buttons["home.allSessionsButton"]
        XCTAssertTrue(allSessions.waitForExistence(timeout: 20))
        allSessions.tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'sessions.sessionRow' AND label CONTAINS[c] %@", match))
            .firstMatch
        // Older sessions sit below the fold; scroll until the row appears.
        var found = row.waitForExistence(timeout: 30)
        var swipes = 0
        while !(found && row.isHittable), swipes < 80 {
            let loadMore = app.buttons["sessions.loadMore"]
            if loadMore.exists && loadMore.isHittable { loadMore.tap() } else { app.swipeUp() }
            swipes += 1
            found = row.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "no session matching \(match)")
        sleep(2)
        print("E2E_MARK open_start \(Date().timeIntervalSince1970)")
        let start = Date()
        row.tap()
        let composer = app.textViews.firstMatch
        _ = composer.waitForExistence(timeout: 60)
        print(String(format: "E2E_TIMING open_to_composer %.2f", Date().timeIntervalSince(start)))
        // Huge bridge transcripts can take minutes to arrive from the host.
        let hold = UInt32(ProcessInfo.processInfo.environment["LITTER_E2E_HOLD_SECS"] ?? "") ?? 15
        sleep(hold)
        shot(app, "open-\(match)")
        var t = Date()
        composer.tap()
        composer.typeText("hello there quick typing test")
        print(String(format: "E2E_TIMING type_in_opened %.2f", Date().timeIntervalSince(t)))

        guard ProcessInfo.processInfo.environment["LITTER_E2E_SEND"] != nil else { return }
        composer.typeText(" - reply with just ok")
        let send = app.buttons["conversation.sendButton"].firstMatch
        send.tap()
        let stop = app.buttons["conversation.cancel-responseButton"]
        _ = stop.waitForExistence(timeout: 60)
        t = Date()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        waitForExpectations(timeout: 300)
        print(String(format: "E2E_TIMING turn_duration %.2f", Date().timeIntervalSince(t)))
        sleep(5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
        }
        composer.tap()
        print("E2E_MARK typing_start \(Date().timeIntervalSince1970)")
        t = Date()
        composer.typeText(String(repeating: "the quick brown fox jumps ", count: 4))
        print(String(format: "E2E_TIMING type_after_settle %.2f", Date().timeIntervalSince(t)))
        shot(app, "after-settle-\(match)")
    }

    private func pair(_ app: XCUIApplication, json: String) {
        app.buttons["home.settingsButton"].tap()
        let computers = app.buttons["settings.category.computers"]
        XCTAssertTrue(computers.waitForExistence(timeout: 5))
        computers.tap()
        let add = app.buttons["settings.addComputer"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        shot(app, "P1-computers")
        add.tap()
        sleep(1)
        shot(app, "P2-chooser")
        app.buttons["discovery.chooser.kittylitter"].tap()
        sleep(2)
        app.tap()
        if app.alerts.buttons["Paste JSON Instead"].waitForExistence(timeout: 3) {
            app.alerts.buttons["Paste JSON Instead"].tap()
        }
        shot(app, "P3-scanner")
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
        app.buttons["Parse JSON"].tap()
        sleep(2)
        shot(app, "P4-parsed")
        let connect = app.buttons["alleycat.pair.toolbarConnect"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: connect)
        waitForExpectations(timeout: 45)
        shot(app, "P5-ready")
        connect.tap()
        sleep(10)
        shot(app, "P6-after-connect")
        let row = app.descendants(matching: .any)["settings.computerRow"].firstMatch
        _ = row.waitForExistence(timeout: 30)
        shot(app, "P7-computers-after")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// The phone's own runtime can open an OpenAI sign-in web sheet.
    private func dismissWebSheet(_ app: XCUIApplication) {
        for label in ["Close", "Cancel", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                sleep(1)
                return
            }
        }
    }

    private func dismissSheet(_ app: XCUIApplication) {
        app.swipeDown(velocity: .fast)
        sleep(1)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
