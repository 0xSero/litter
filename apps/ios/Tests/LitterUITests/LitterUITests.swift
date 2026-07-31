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
        XCTAssertTrue(app.staticTexts["Internal Thinking"].exists)
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

        let composer = app.textViews["conversation.composerTextView"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("SIMULATOR_INPUT_OK")
        XCTAssertEqual(composer.value as? String, "SIMULATOR_INPUT_OK")
    }

    @MainActor
    func testConversationDisplayCollapsedModeKeepsRowsAndRetainsRecentDetails() throws {
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
        XCTAssertTrue(app.staticTexts["UITEST_TOOL_DETAIL"].exists)
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
    func testCaptureScreenshots() throws {
        guard ProcessInfo.processInfo.environment["CODEXIOS_CAPTURE_LIVE_SCREENSHOTS"] == "enabled" else {
            throw XCTSkip("Live discovery screenshots require CODEXIOS_CAPTURE_LIVE_SCREENSHOTS=enabled")
        }
        let app = XCUIApplication()
        app.launchEnvironment["CODEXIOS_UI_TEST_FORCE_DISCOVERY"] = "1"
        setupSnapshot(app)
        app.launch()

        XCTAssertTrue(presentDiscovery(in: app), "Unable to open discovery")
        XCTAssertTrue(waitForDiscoveryServers(in: app, timeout: 20), "No discovery servers found")
        _ = waitForDiscoveryListToPopulate(in: app, timeout: 12, minimumRows: 3)
        snapshot("01DiscoveryLoaded")

        XCTAssertTrue(
            selectPreferredDiscoveryServer(in: app, preferredHostFragment: ".203"),
            "Unable to tap the .203 server"
        )
        _ = waitForDiscoveryDismissed(in: app, timeout: 20)
        XCTAssertTrue(waitForHomeContentReady(in: app, timeout: 12), "Home dashboard did not load")
        sleep(1)
        snapshot("02HomeLoaded")

        XCTAssertTrue(openFirstConnectedServer(in: app), "Unable to open sessions screen")
        XCTAssertTrue(waitForSessionsScreen(in: app, timeout: 8), "Sessions screen did not appear")
        XCTAssertTrue(waitForAnySession(in: app, timeout: 12), "No sessions to select")
        sleep(1)
        snapshot("03SessionsLoaded")

        XCTAssertTrue(selectFirstSession(in: app), "Unable to open a session")
        XCTAssertTrue(waitForConversationLoaded(in: app, timeout: 10), "Conversation view did not load")
        sleep(2)
        snapshot("04ConversationLoaded")

        let backButton = app.buttons["header.homeButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), "Conversation header back button missing")
        backButton.tap()
        XCTAssertTrue(waitForSessionsScreen(in: app, timeout: 8), "Back did not return to sessions")
        sleep(1)
        snapshot("05ReturnedToSessions")
    }

    private func presentDiscovery(in app: XCUIApplication) -> Bool {
        if isDiscoveryVisible(in: app) {
            return true
        }

        let primaryConnectButton = app.buttons["Connect Server"]
        if primaryConnectButton.waitForExistence(timeout: 2), primaryConnectButton.isHittable {
            primaryConnectButton.tap()
            return waitForDiscoveryVisible(in: app, timeout: 8)
        }

        let legacyConnectButton = app.buttons["Connect to Server"]
        if legacyConnectButton.waitForExistence(timeout: 2), legacyConnectButton.isHittable {
            legacyConnectButton.tap()
            return waitForDiscoveryVisible(in: app, timeout: 8)
        }

        return waitForDiscoveryVisible(in: app, timeout: 5)
    }

    private func waitForDiscoveryServers(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let codexRows = codexDiscoveryRows(in: app)
        let sshRows = sshDiscoveryRows(in: app)
        let preferredHost = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", ".203"))

        return waitUntil(timeout: timeout) {
            preferredHost.firstMatch.exists || codexRows.firstMatch.exists || sshRows.firstMatch.exists
        }
    }

    private func waitForDiscoveryListToPopulate(
        in app: XCUIApplication,
        timeout: TimeInterval,
        minimumRows: Int
    ) -> Bool {
        let codexRows = codexDiscoveryRows(in: app)
        let sshRows = sshDiscoveryRows(in: app)
        let preferredHost = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", ".203"))
        let scanningLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Scanning")
        )

        return waitUntil(timeout: timeout) {
            let totalRows = codexRows.count + sshRows.count
            if totalRows >= minimumRows {
                return true
            }
            if preferredHost.firstMatch.exists && totalRows > 0 && !scanningLabel.firstMatch.exists {
                return true
            }
            return false
        }
    }

    private func selectPreferredDiscoveryServer(in app: XCUIApplication, preferredHostFragment: String) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        guard discoveryList.waitForExistence(timeout: 8) else { return false }

        for _ in 0..<5 {
            if tapPreferredDiscoveryRow(in: app, hostFragment: preferredHostFragment) ||
                tapPreferredHostText(in: app, hostFragment: preferredHostFragment) {
                return true
            }
            discoveryList.swipeUp()
        }

        for _ in 0..<5 {
            if tapPreferredDiscoveryRow(in: app, hostFragment: preferredHostFragment) ||
                tapPreferredHostText(in: app, hostFragment: preferredHostFragment) {
                return true
            }
            discoveryList.swipeDown()
        }

        let codexRows = codexDiscoveryRows(in: app)
        if codexRows.firstMatch.waitForExistence(timeout: 4), codexRows.firstMatch.isHittable {
            codexRows.firstMatch.tap()
            return true
        }

        return false
    }

    private func tapPreferredDiscoveryRow(in app: XCUIApplication, hostFragment: String) -> Bool {
        let normalized = hostFragment
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        let query = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@",
                "discovery.server.codex.",
                normalized
            )
        )
        let row = query.firstMatch
        guard row.waitForExistence(timeout: 1), row.isHittable else { return false }
        row.tap()
        return true
    }

    private func tapPreferredHostText(in app: XCUIApplication, hostFragment: String) -> Bool {
        let hostTexts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", hostFragment))
        let first = hostTexts.firstMatch
        guard first.waitForExistence(timeout: 1), first.isHittable else { return false }
        first.tap()
        return true
    }

    private func waitForDiscoveryVisible(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { isDiscoveryVisible(in: app) }
    }

    private func waitForDiscoveryDismissed(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        return waitUntil(timeout: timeout) { !discoveryList.exists || !discoveryList.isHittable }
    }

    private func isDiscoveryVisible(in app: XCUIApplication) -> Bool {
        let discoveryList = identifiedElement("discovery.list", in: app)
        return discoveryList.exists && discoveryList.isHittable
    }

    private func waitForHomeContentReady(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let connectedServerRow = app.descendants(matching: .any).matching(identifier: "home.connectedServerRow")
        let connectButton = app.buttons["Connect Server"]
        return waitUntil(timeout: timeout) {
            (connectedServerRow.firstMatch.exists && connectedServerRow.firstMatch.isHittable) ||
                (connectButton.exists && connectButton.isHittable)
        }
    }

    private func openFirstConnectedServer(in app: XCUIApplication) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: "home.connectedServerRow")
        let firstRow = rows.firstMatch
        guard firstRow.waitForExistence(timeout: 8), firstRow.isHittable else { return false }
        firstRow.tap()
        return true
    }

    private func waitForSessionsScreen(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        return waitUntil(timeout: timeout) {
            sessionsContainer.exists && sessionsContainer.isHittable
        }
    }

    private func waitForAnySession(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow")
        return waitUntil(timeout: timeout) { rows.firstMatch.exists }
    }

    private func selectFirstSession(in app: XCUIApplication) -> Bool {
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        let rowQuery = app.descendants(matching: .any).matching(identifier: "sessions.sessionRow")

        for _ in 0..<8 {
            let count = min(rowQuery.count, 12)
            if count > 0 {
                for index in 0..<count {
                    let row = rowQuery.element(boundBy: index)
                    if row.exists && row.isHittable {
                        row.tap()
                        return true
                    }
                }
            }
            if sessionsContainer.exists {
                sessionsContainer.swipeUp()
            } else {
                break
            }
        }

        let titles = app.staticTexts.matching(identifier: "sessions.sessionTitle")
        let titleCount = min(titles.count, 12)
        for index in 0..<titleCount {
            let title = titles.element(boundBy: index)
            if title.exists && title.isHittable {
                title.tap()
                return true
            }
        }

        return false
    }

    private func waitForConversationLoaded(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let backButton = app.buttons["header.homeButton"]
        let sessionsContainer = identifiedElement("sessions.container", in: app)
        return waitUntil(timeout: timeout) {
            backButton.exists && backButton.isHittable && (!sessionsContainer.exists || !sessionsContainer.isHittable)
        }
    }

    private func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.2, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
        return condition()
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func codexDiscoveryRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.server.codex."))
    }

    private func sshDiscoveryRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.server.ssh."))
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
