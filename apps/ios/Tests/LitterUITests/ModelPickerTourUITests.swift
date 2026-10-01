import XCTest

/// Screenshot walk through the composer model picker against a paired host
/// with a large catalog. Skipped unless `LITTER_E2E_PICKER` is set (pass it
/// with the `TEST_RUNNER_` prefix). Screenshots are kept as attachments.
final class ModelPickerTourUITests: XCTestCase {
    @MainActor
    func testModelPickerTour() throws {
        guard ProcessInfo.processInfo.environment["LITTER_E2E_PICKER"] != nil else {
            throw XCTSkip("LITTER_E2E_PICKER not set")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home.settingsButton"].waitForExistence(timeout: 20))
        sleep(4)
        dismissWebSheet(app)

        let button = app.descendants(matching: .any)["conversation.modelPickerButton"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        // Wait for the host catalog (any harness row, or the legacy pills).
        let anyHarness = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'modelPicker.harness.' OR label BEGINSWITH 'Codex '"))
            .firstMatch
        _ = anyHarness.waitForExistence(timeout: 90)
        sleep(2)
        shot(app, "picker-01-root")

        // Search across everything.
        let search = searchField(app)
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("sonnet")
            sleep(2)
            shot(app, "picker-02-search-sonnet")
            clear(search, app)
        }

        // A harness with a large multi-provider catalog.
        if openHarness(app, kind: "pi", legacyLabel: "Pi") {
            sleep(2)
            shot(app, "picker-03-pi")
            var header = app.descendants(matching: .any)["modelPicker.provider.pi|provider:anthropic"].firstMatch
            if !header.exists {
                header = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'modelPicker.provider.'"))
                    .firstMatch
            }
            if header.waitForExistence(timeout: 3) {
                header.tap()
                sleep(1)
                shot(app, "picker-04-pi-provider-expanded")
            }
            goBack(app)
        }

        // The largest catalog on the test host.
        if openHarness(app, kind: "opencode", legacyLabel: "Opencode") {
            sleep(2)
            shot(app, "picker-04b-opencode")
            goBack(app)
        }

        // Amp lists modes, not models.
        if openHarness(app, kind: "amp", legacyLabel: "Amp") {
            sleep(2)
            shot(app, "picker-05-amp")
            goBack(app)
        }

        // Harness list with the options section at the bottom.
        app.swipeUp()
        sleep(1)
        shot(app, "picker-06-root-scrolled")
    }

    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let native = app.searchFields.firstMatch
        if native.waitForExistence(timeout: 2) { return native }
        return app.textFields["Search models"].firstMatch
    }

    private func clear(_ field: XCUIElement, _ app: XCUIApplication) {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
        sleep(1)
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        sleep(1)
    }

    private func openHarness(_ app: XCUIApplication, kind: String, legacyLabel: String) -> Bool {
        let row = app.descendants(matching: .any)["modelPicker.harness.\(kind)"].firstMatch
        if row.waitForExistence(timeout: 3) {
            if !row.isHittable { app.swipeUp() }
            row.tap()
            return true
        }
        let pill = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(legacyLabel) "))
            .firstMatch
        if pill.waitForExistence(timeout: 2) {
            pill.tap()
            return true
        }
        return false
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.buttons["modelPicker.back"].firstMatch
        if back.exists && back.isHittable {
            back.tap()
            sleep(1)
            return
        }
        let nav = app.navigationBars.buttons.element(boundBy: 0)
        if nav.exists && nav.isHittable && nav.label != "Done" {
            nav.tap()
        } else {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        sleep(1)
    }

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

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
