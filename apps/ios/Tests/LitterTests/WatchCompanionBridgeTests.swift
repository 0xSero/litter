import XCTest
import UserNotifications
import WatchConnectivity
@testable import Litter

@MainActor
final class WatchCompanionBridgeTests: XCTestCase {

    /// In-memory `WatchTransport` that records `updateApplicationContext`
    /// calls and lets a test pin the WC connection state.
    final class StubWatchTransport: WatchTransport {
        var activationState: WCSessionActivationState
        var isPaired: Bool
        var isWatchAppInstalled: Bool
        var isReachable: Bool
        var sentContexts: [[String: Any]] = []
        var nextSendError: Error?

        init(
            activationState: WCSessionActivationState = .activated,
            isPaired: Bool = true,
            isWatchAppInstalled: Bool = true,
            isReachable: Bool = true
        ) {
            self.activationState = activationState
            self.isPaired = isPaired
            self.isWatchAppInstalled = isWatchAppInstalled
            self.isReachable = isReachable
        }

        func updateApplicationContext(_ context: [String: Any]) throws {
            if let nextSendError {
                self.nextSendError = nil
                throw nextSendError
            }
            sentContexts.append(context)
        }
    }

    // The bridge currently reads `AppModel.shared.snapshot` directly. To
    // keep tests isolated we restore whatever the singleton held at the
    // start of each test in tearDown.
    private var savedSnapshot: AppSnapshotRecord?
    // SavedThreadsStore is file-backed and shared across the whole test
    // process. Snapshot its state in setUp and restore it in tearDown so
    // tests that mutate pinned/hidden don't leak state to each other.
    private var savedPinnedKeys: [PinnedThreadKey] = []
    private var savedHiddenKeys: [PinnedThreadKey] = []

    override func setUp() {
        super.setUp()
        savedSnapshot = AppModel.shared.snapshot
        savedPinnedKeys = SavedThreadsStore.pinnedKeys()
        savedHiddenKeys = SavedThreadsStore.hiddenKeys()
        // Wipe so each test starts from a clean home-visibility state.
        for key in savedPinnedKeys { SavedThreadsStore.remove(key) }
        for key in savedHiddenKeys { SavedThreadsStore.unhide(key) }
        if let pending = AppModel.shared.composerPrefillRequest {
            AppModel.shared.clearComposerPrefill(id: pending.id)
        }
    }

    override func tearDown() {
        AppModel.shared.applySnapshot(savedSnapshot)
        // Wipe whatever the test left behind…
        for key in SavedThreadsStore.pinnedKeys() { SavedThreadsStore.remove(key) }
        for key in SavedThreadsStore.hiddenKeys() { SavedThreadsStore.unhide(key) }
        // …and restore the original state in original order. `add` and
        // `hide` both prepend, so iterate in reverse to preserve order.
        for key in savedPinnedKeys.reversed() { SavedThreadsStore.add(key) }
        for key in savedHiddenKeys.reversed() { SavedThreadsStore.hide(key) }
        if let pending = AppModel.shared.composerPrefillRequest {
            AppModel.shared.clearComposerPrefill(id: pending.id)
        }
        super.tearDown()
    }

    // MARK: - 1. Complication mode = .running with real runtime

    func testComplicationSnapshotEmitsRunningModeWithRealTurnStartAndTaskId() throws {
        let now = Date()
        let startedMs = Int64((now.timeIntervalSince1970 - 90) * 1000)
        let summary = makeSummary(
            serverId: "macbook",
            threadId: "t1",
            updatedAt: Int64(now.timeIntervalSince1970),
            hasActiveTurn: true,
            title: "fix auth",
            lastTurnStartMs: startedMs
        )
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [summary]
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())

        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "running")
        XCTAssertEqual(dict["taskId"] as? String, "macbook:t1")
        XCTAssertEqual(dict["lastTurnStartMsEpoch"] as? Int64, startedMs)
        XCTAssertEqual(dict["serverCount"] as? Int, 1)
    }

    // MARK: - 2. Complication mode = .idle

    func testComplicationSnapshotEmitsIdleModeWhenNoActiveTurnAndPairedTransport() throws {
        let summary = makeSummary(
            serverId: "macbook",
            threadId: "t1",
            updatedAt: 100,
            hasActiveTurn: false
        )
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook"), makeServer(id: "studio")],
            sessionSummaries: [summary]
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: true
        ))

        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "idle")
        XCTAssertEqual(dict["serverCount"] as? Int, 2)
        XCTAssertNil(dict["taskId"])
        XCTAssertNil(dict["lastTurnStartMsEpoch"])
    }

    func testComplicationSnapshotIdleMessageFallsBackWhenNoTasks() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "idle")
        XCTAssertEqual(dict["title"] as? String, "1 servers ready")
    }

    // MARK: - 3. Complication mode = .offline

    func testComplicationSnapshotEmitsOfflineWhenTransportNotPaired() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport(
            activationState: .activated,
            isPaired: false,
            isWatchAppInstalled: true
        ))

        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "offline")
        XCTAssertNil(dict["taskId"])
        XCTAssertEqual(dict["title"] as? String, "phone unreachable")
    }

    func testComplicationSnapshotEmitsOfflineWhenTransportNotActivated() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport(
            activationState: .notActivated,
            isPaired: true,
            isWatchAppInstalled: true
        ))

        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "offline")
    }

    func testComplicationSnapshotEmitsOfflineWhenWatchAppNotInstalled() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: false
        ))

        let data = try XCTUnwrap(bridge.currentComplicationSnapshot())
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["mode"] as? String, "offline")
    }

    // MARK: - 4. Inbound prompt routing

    func testInboundPromptWithKnownThreadQueuesComposerPrefillOnThatThread() async {
        let key = ThreadKey(serverId: "macbook", threadId: "t1")
        let summary = makeSummary(
            serverId: "macbook",
            threadId: "t1",
            updatedAt: 100,
            hasActiveTurn: false
        )
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [summary]
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "prompt.send",
            "text": "hi from watch",
            "serverId": "macbook",
            "threadId": "t1"
        ])

        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["threadId"] as? String, "t1")

        let prefill = AppModel.shared.composerPrefillRequest
        XCTAssertEqual(prefill?.threadKey, key)
        XCTAssertEqual(prefill?.text, "hi from watch")
    }

    func testInboundPromptFallsBackToActiveThreadWhenServerAndThreadAreMissing() async {
        let key = ThreadKey(serverId: "macbook", threadId: "active")
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [makeSummary(
                serverId: "macbook",
                threadId: "active",
                updatedAt: 100,
                hasActiveTurn: false
            )],
            activeThread: key
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "prompt.send",
            "text": "fallback"
        ])

        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["threadId"] as? String, "active")

        let prefill = AppModel.shared.composerPrefillRequest
        XCTAssertEqual(prefill?.threadKey, key)
        XCTAssertEqual(prefill?.text, "fallback")
    }

    func testInboundPromptWithEmptyTextReturnsErrorWithoutPrefill() async {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [],
            activeThread: ThreadKey(serverId: "macbook", threadId: "t1")
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "prompt.send",
            "text": "   "
        ])

        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "empty prompt")
        XCTAssertNil(AppModel.shared.composerPrefillRequest)
    }

    func testInboundPromptWithNoActiveThreadAndNoServerReturnsError() async {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [],
            sessionSummaries: [],
            activeThread: nil
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "prompt.send",
            "text": "hi"
        ])

        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "no active task")
    }

    // MARK: - 5. Inbound approval

    func testInboundApprovalWithMissingFieldsReturnsInvalidPayloadError() async {
        let bridge = WatchCompanionBridge(transport: StubWatchTransport())

        let missingApprove = await bridge.handleInbound([
            "kind": "approval.decision",
            "requestId": "x"
        ])
        XCTAssertEqual(missingApprove?["ok"] as? Bool, false)
        XCTAssertEqual(missingApprove?["error"] as? String, "invalid approval payload")

        let missingId = await bridge.handleInbound([
            "kind": "approval.decision",
            "approve": true
        ])
        XCTAssertEqual(missingId?["ok"] as? Bool, false)
        XCTAssertEqual(missingId?["error"] as? String, "invalid approval payload")
    }

    func testInboundApprovalForwardsToStoreAndRepliesAccordingToOutcome() async {
        // We can't run a real respondToApproval in the test environment
        // (no server to talk to), but we *can* assert the bridge dispatches
        // the call: the reply will be `{ok: false, error: "..."}` because
        // the store has no matching request id. The test verifies the
        // bridge parsed the payload and routed it into the store path
        // (not into the "invalid payload" branch).
        let bridge = WatchCompanionBridge(transport: StubWatchTransport())

        let reply = await bridge.handleInbound([
            "kind": "approval.decision",
            "requestId": "unknown-request",
            "approve": true
        ])

        // Either ok:true (if store accepted) or ok:false with a *non-payload*
        // error (i.e., not "invalid approval payload"). Any other shape means
        // the bridge took the wrong branch.
        XCTAssertNotNil(reply)
        XCTAssertNotEqual(reply?["error"] as? String, "invalid approval payload")
    }

    // MARK: - 6. snapshot.request triggers a fresh push

    func testSnapshotRequestForcesPushThroughTransport() async {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [makeSummary(
                serverId: "macbook",
                threadId: "t1",
                updatedAt: 100,
                hasActiveTurn: false
            )]
        ))

        let stub = StubWatchTransport(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: true
        )
        let bridge = WatchCompanionBridge(transport: stub)

        let reply = await bridge.handleInbound(["kind": "snapshot.request"])
        XCTAssertEqual(reply?["ok"] as? Bool, true)

        // The push goes through a 150ms throttle. Wait for it to fire.
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(stub.sentContexts.isEmpty, "expected at least one context push after snapshot.request")
        let context = stub.sentContexts.last
        XCTAssertNotNil(context?["litter.snapshot"] as? Data)
    }

    func testSnapshotRequestPushesWhenWatchInstallFlagIsStale() async {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let stub = StubWatchTransport(
            activationState: .activated,
            isPaired: true,
            isWatchAppInstalled: false
        )
        let bridge = WatchCompanionBridge(transport: stub)

        let reply = await bridge.handleInbound(["kind": "snapshot.request"])
        XCTAssertEqual(reply?["ok"] as? Bool, true)

        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(
            stub.sentContexts.isEmpty,
            "expected snapshot push even when WCSession has stale isWatchAppInstalled state"
        )
        XCTAssertNotNil(stub.sentContexts.last?["litter.snapshot"] as? Data)
    }

    // MARK: - 7. Unknown kind returns nil

    func testUnknownKindReturnsNilSoDelegateRepliesGenericAck() async {
        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound(["kind": "unsupported.message"])
        XCTAssertNil(reply)
    }

    func testMessageWithoutKindReturnsNil() async {
        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound(["text": "no kind here"])
        XCTAssertNil(reply)
    }

    // MARK: - currentPayload

    func testCurrentPayloadExposesPendingApprovalAndTasks() {
        let approval = PendingApproval(
            id: "approval-1",
            serverId: "macbook",
            kind: .command,
            threadId: "t1",
            turnId: nil,
            itemId: nil,
            command: "git push",
            path: nil,
            grantRoot: nil,
            cwd: nil,
            reason: nil
        )
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [makeSummary(
                serverId: "macbook",
                threadId: "t1",
                updatedAt: 100,
                hasActiveTurn: false
            )],
            pendingApprovals: [approval]
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let payload = bridge.currentPayload()

        XCTAssertEqual(payload.tasks.count, 1)
        XCTAssertEqual(payload.tasks.first?.status, .needsApproval)
        XCTAssertEqual(payload.pendingApproval?.id, "approval-1")
        XCTAssertEqual(payload.pendingApproval?.kind, .command)
        XCTAssertEqual(payload.pendingApproval?.command, "git push")

        // Theme is attached on every push so the watch can mirror the
        // user's selected iPhone palette.
        XCTAssertNotNil(payload.theme)
        XCTAssertTrue(payload.theme?.accent.hasPrefix("#") ?? false)
    }

    // MARK: - Home visibility parity

    func testCurrentPayloadExcludesHiddenThreads() {
        let visibleKey = ThreadKey(serverId: "macbook", threadId: "visible")
        let hiddenKey = ThreadKey(serverId: "macbook", threadId: "hidden")
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [
                makeSummary(serverId: "macbook", threadId: "visible", updatedAt: 200, hasActiveTurn: false),
                makeSummary(serverId: "macbook", threadId: "hidden", updatedAt: 100, hasActiveTurn: false),
            ]
        ))

        SavedThreadsStore.hide(PinnedThreadKey(threadKey: hiddenKey))
        defer { SavedThreadsStore.unhide(PinnedThreadKey(threadKey: hiddenKey)) }

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let payload = bridge.currentPayload()

        XCTAssertEqual(payload.tasks.map(\.threadId), [visibleKey.threadId])
    }

    func testCurrentPayloadIncludesHiddenTasks() {
        let visibleKey = ThreadKey(serverId: "macbook", threadId: "visible")
        let hiddenKey = ThreadKey(serverId: "macbook", threadId: "hidden")
        let otherHiddenKey = ThreadKey(serverId: "studio", threadId: "hidden2")
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook"), makeServer(id: "studio")],
            sessionSummaries: [
                makeSummary(serverId: "macbook", threadId: "visible", updatedAt: 300, hasActiveTurn: false, title: "stays"),
                makeSummary(serverId: "macbook", threadId: "hidden",  updatedAt: 200, hasActiveTurn: false, title: "tucked away"),
                makeSummary(serverId: "studio",  threadId: "hidden2", updatedAt: 100, hasActiveTurn: false, title: "also tucked"),
            ]
        ))

        SavedThreadsStore.hide(PinnedThreadKey(threadKey: hiddenKey))
        SavedThreadsStore.hide(PinnedThreadKey(threadKey: otherHiddenKey))
        defer {
            SavedThreadsStore.unhide(PinnedThreadKey(threadKey: hiddenKey))
            SavedThreadsStore.unhide(PinnedThreadKey(threadKey: otherHiddenKey))
        }

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let payload = bridge.currentPayload()

        // Visible slice excludes the hidden threads (existing behavior).
        XCTAssertEqual(payload.tasks.map(\.threadId), [visibleKey.threadId])

        // Hidden slice contains both hidden threads in some order.
        let hiddenIds = Set((payload.hiddenTasks ?? []).map(\.threadId))
        XCTAssertEqual(hiddenIds, [hiddenKey.threadId, otherHiddenKey.threadId])
    }

    func testCurrentPayloadOmitsHiddenTasksFieldWhenEmpty() {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [
                makeSummary(serverId: "macbook", threadId: "visible", updatedAt: 100, hasActiveTurn: false),
            ]
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let payload = bridge.currentPayload()

        XCTAssertNil(payload.hiddenTasks, "no hidden threads → no hiddenTasks slice")
    }

    func testCurrentPayloadOrdersPinnedThreadsByPinOrder() {
        let pin1 = ThreadKey(serverId: "macbook", threadId: "alpha")
        let pin2 = ThreadKey(serverId: "macbook", threadId: "bravo")
        let other = ThreadKey(serverId: "macbook", threadId: "charlie")
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: [
                // Reverse-recency order so we know pin order is doing the sorting.
                makeSummary(serverId: "macbook", threadId: "alpha",   updatedAt: 100, hasActiveTurn: false),
                makeSummary(serverId: "macbook", threadId: "bravo",   updatedAt: 200, hasActiveTurn: false),
                makeSummary(serverId: "macbook", threadId: "charlie", updatedAt: 300, hasActiveTurn: false),
            ]
        ))

        // `add` prepends — pinning bravo then alpha yields pin order: alpha, bravo.
        SavedThreadsStore.add(PinnedThreadKey(threadKey: pin2))
        SavedThreadsStore.add(PinnedThreadKey(threadKey: pin1))
        defer {
            SavedThreadsStore.remove(PinnedThreadKey(threadKey: pin1))
            SavedThreadsStore.remove(PinnedThreadKey(threadKey: pin2))
        }

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let payload = bridge.currentPayload()

        // Only the two pinned threads show up (charlie is excluded because the
        // iPhone home rule is "pins only when any are pinned"). Order matches
        // pin order, not recency.
        XCTAssertEqual(payload.tasks.map(\.threadId), [pin1.threadId, pin2.threadId])
        XCTAssertFalse(payload.tasks.contains { $0.threadId == other.threadId })
    }

    func testInboundHomeHideAddsThreadToHiddenStore() async {
        let key = ThreadKey(serverId: "macbook", threadId: "tohide")
        let pinned = PinnedThreadKey(threadKey: key)
        // Ensure clean start.
        SavedThreadsStore.unhide(pinned)

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "home.hide",
            "serverId": key.serverId,
            "threadId": key.threadId,
        ])
        defer { SavedThreadsStore.unhide(pinned) }

        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertTrue(SavedThreadsStore.hiddenKeys().contains(pinned))
    }

    func testInboundHomeHideRejectsInvalidPayload() async {
        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let reply = await bridge.handleInbound([
            "kind": "home.hide",
            "threadId": "no-server-id",
        ])
        XCTAssertEqual(reply?["ok"] as? Bool, false)
    }

    func testCurrentPayloadIncludesResolvedThemeForDarkAppearance() {
        ThemeManager.shared.setAppearanceMode(.dark)
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubWatchTransport())
        let theme = bridge.currentPayload().theme
        XCTAssertNotNil(theme)
        XCTAssertEqual(theme?.isDark, true)
        XCTAssertEqual(theme?.appearanceMode, .dark)
        XCTAssertEqual(theme?.accent, ThemeManager.shared.darkTheme.accent)
        XCTAssertEqual(theme?.backgroundTop, ThemeManager.shared.darkTheme.background)
    }

    // MARK: - Approval notification builder

    func testApprovalNotificationRequestSetsCategoryThreadAndUserInfo() {
        let approval = PendingApproval(
            id: "req-42",
            serverId: "macbook",
            kind: .command,
            threadId: "t1",
            turnId: nil,
            itemId: nil,
            command: "git push origin main",
            path: nil,
            grantRoot: nil,
            cwd: nil,
            reason: nil
        )

        let request = WatchCompanionBridge.makeApprovalNotificationRequest(
            approval: approval,
            serverName: "MacBook Pro",
            threadTitle: "fix auth"
        )

        XCTAssertEqual(request.content.categoryIdentifier, WatchApprovalNotification.categoryIdentifier)
        XCTAssertEqual(request.content.threadIdentifier, "macbook")
        XCTAssertEqual(
            request.content.userInfo[WatchApprovalNotification.requestIdKey] as? String,
            "req-42"
        )
        XCTAssertEqual(
            request.content.userInfo[WatchApprovalNotification.serverIdKey] as? String,
            "macbook"
        )
        XCTAssertEqual(
            request.content.userInfo[WatchApprovalNotification.threadIdKey] as? String,
            "t1"
        )
        XCTAssertEqual(request.content.subtitle, "MacBook Pro")
        // Body should weave in the thread title and the command detail.
        XCTAssertTrue(request.content.body.contains("fix auth"))
        XCTAssertTrue(request.content.body.contains("git push origin main"))
        // Identifier is stable so a re-issue replaces the existing banner.
        XCTAssertEqual(request.identifier, "litter.approval.req-42")
    }

    func testApprovalNotificationRequestOmitsThreadIdWhenAbsent() {
        let approval = PendingApproval(
            id: "req-99",
            serverId: "studio",
            kind: .permissions,
            threadId: nil,
            turnId: nil,
            itemId: nil,
            command: nil,
            path: nil,
            grantRoot: nil,
            cwd: nil,
            reason: "Allow workspace write"
        )

        let request = WatchCompanionBridge.makeApprovalNotificationRequest(
            approval: approval,
            serverName: "studio",
            threadTitle: nil
        )

        XCTAssertNil(request.content.userInfo[WatchApprovalNotification.threadIdKey])
        XCTAssertEqual(request.content.threadIdentifier, "studio")
        XCTAssertEqual(request.content.body, "Allow workspace write")
    }

    // MARK: - Factories

    private func makeServer(id: String, connected: Bool = true) -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: id,
            displayName: id,
            host: "\(id).local",
            port: 8390,
            wakeMac: nil,
            isLocal: false,
            health: connected ? .connected : .disconnected,
            transportState: connected ? .connected : .disconnected,
            capabilities: AppServerCapabilities(
                canUseTransportActions: connected,
                canBrowseDirectories: connected,
                canStartThreads: connected,
                canResumeThreads: connected,
                supportsTurnPagination: false
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            rateLimitsByRuntime: [],
            availableModels: nil,
            agentRuntimes: [AgentRuntimeInfo(kind: .codex, name: "codex", displayName: "Codex", available: true)],
            connectionProgress: nil,
            usageStats: nil,
            codexVersion: nil
        )
    }

    private func makeSummary(
        serverId: String,
        threadId: String,
        updatedAt: Int64?,
        hasActiveTurn: Bool,
        title: String = "",
        preview: String = "",
        lastResponsePreview: String? = nil,
        lastUserMessage: String? = nil,
        lastToolLabel: String? = nil,
        lastTurnStartMs: Int64? = nil
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            agentRuntimeKind: .codex,
            serverDisplayName: serverId,
            serverHost: "\(serverId).local",
            title: title,
            preview: preview,
            cwd: "/tmp",
            model: "",
            modelProvider: "",
            parentThreadId: nil,
            forkedFromId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: updatedAt,
            hasActiveTurn: hasActiveTurn,
            isResumed: false,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: lastResponsePreview,
            lastResponseTurnId: nil,
            lastUserMessage: lastUserMessage,
            lastToolLabel: lastToolLabel,
            recentToolLog: [],
            lastTurnStartMs: lastTurnStartMs,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil,
            goal: nil
        )
    }

    private func makeRecord(
        servers: [AppServerSnapshot],
        sessionSummaries: [AppSessionSummary],
        activeThread: ThreadKey? = nil,
        pendingApprovals: [PendingApproval] = []
    ) -> AppSnapshotRecord {
        AppSnapshotRecord(
            servers: servers,
            threads: [],
            sessionSummaries: sessionSummaries,
            agentDirectoryVersion: 0,
            activeThread: activeThread,
            pendingApprovals: pendingApprovals,
            pendingUserInputs: [],
            voiceSession: AppVoiceSessionSnapshot(
                activeThread: nil,
                sessionId: nil,
                phase: nil,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            ),
            terminalSessions: [],
            activeTerminalId: nil
        )
    }
}
