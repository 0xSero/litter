import XCTest
import Observation
@testable import Litter

final class AppSnapshotRuntimeTests: XCTestCase {
    func testThreadHasTrackedTurnWhenThreadHasActiveTurn() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        let snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: key, status: .active, activeTurnId: "turn-1")]
        )

        XCTAssertTrue(snapshot.threadHasTrackedTurn(for: key))
        XCTAssertEqual(snapshot.threadsWithTrackedTurns.map(\.key), [key])
    }

    func testThreadHasTrackedTurnWhenApprovalIsPending() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        var snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: key)]
        )
        snapshot.pendingApprovals = [
            PendingApproval(
                id: "approval-1",
                serverId: key.serverId,
                kind: .command,
                threadId: key.threadId,
                turnId: "turn-1",
                itemId: "item-1",
                command: "ls",
                path: nil,
                grantRoot: nil,
                cwd: "/tmp",
                reason: nil
            )
        ]

        XCTAssertTrue(snapshot.threadHasTrackedTurn(for: key))
        XCTAssertEqual(snapshot.threadsWithTrackedTurns.map(\.key), [key])
    }

    func testThreadHasTrackedTurnWhenUserInputIsPending() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        var snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: key)]
        )
        snapshot.pendingUserInputs = [
            PendingUserInputRequest(
                id: "input-1",
                serverId: key.serverId,
                threadId: key.threadId,
                turnId: "turn-1",
                itemId: "item-1",
                questions: [],
                requesterAgentNickname: nil,
                requesterAgentRole: nil
            )
        ]

        XCTAssertTrue(snapshot.threadHasTrackedTurn(for: key))
        XCTAssertEqual(snapshot.threadsWithTrackedTurns.map(\.key), [key])
    }

    func testThreadHasTrackedTurnWhenServerScopedUserInputIsPending() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        var snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: key)]
        )
        snapshot.pendingUserInputs = [
            PendingUserInputRequest(
                id: "input-1",
                serverId: key.serverId,
                threadId: "",
                turnId: "turn-1",
                itemId: "item-1",
                questions: [],
                requesterAgentNickname: nil,
                requesterAgentRole: nil
            )
        ]

        XCTAssertTrue(snapshot.threadHasTrackedTurn(for: key))
        XCTAssertEqual(snapshot.threadsWithTrackedTurns.map(\.key), [key])
    }

    func testThreadHasTrackedTurnIgnoresOtherThreadsPendingState() {
        let trackedKey = ThreadKey(serverId: "srv", threadId: "thread-1")
        let otherKey = ThreadKey(serverId: "srv", threadId: "thread-2")
        var snapshot = makeSnapshot(
            threads: [
                makeThreadSnapshot(key: trackedKey),
                makeThreadSnapshot(key: otherKey)
            ]
        )
        snapshot.pendingApprovals = [
            PendingApproval(
                id: "approval-1",
                serverId: otherKey.serverId,
                kind: .command,
                threadId: otherKey.threadId,
                turnId: "turn-2",
                itemId: "item-2",
                command: "pwd",
                path: nil,
                grantRoot: nil,
                cwd: "/tmp",
                reason: nil
            )
        ]

        XCTAssertFalse(snapshot.threadHasTrackedTurn(for: trackedKey))
        XCTAssertTrue(snapshot.threadHasTrackedTurn(for: otherKey))
        XCTAssertEqual(snapshot.threadsWithTrackedTurns.map(\.key), [otherKey])
    }

    func testDisplayModelLabelUsesConcreteThreadModelFirst() {
        let thread = makeThreadSnapshot(
            key: ThreadKey(serverId: "srv", threadId: "thread-1"),
            model: "gpt-5.4",
            modelProvider: "anthropic",
            agentRuntimeKind: .claude
        )

        XCTAssertEqual(thread.displayModelLabel, "gpt-5.4")
    }

    func testDisplayModelLabelFallsBackToProviderRuntimeLabel() {
        let claude = makeThreadSnapshot(
            key: ThreadKey(serverId: "srv", threadId: "thread-claude"),
            modelProvider: "anthropic",
            agentRuntimeKind: .claude
        )
        let opencode = makeThreadSnapshot(
            key: ThreadKey(serverId: "srv", threadId: "thread-opencode"),
            modelProvider: nil,
            agentRuntimeKind: .opencode
        )

        // A runtime the built-in agent catalog knows about now gets its
        // label from the catalog's `display_name`, which mirrors the
        // upstream alleycat manifest. opencode brands itself lowercase, so
        // the seeded label deliberately differs from the titlecase the bare
        // fallback would produce.
        let unknown = makeThreadSnapshot(
            key: ThreadKey(serverId: "srv", threadId: "thread-unknown"),
            modelProvider: nil,
            agentRuntimeKind: "some-unshipped-agent"
        )

        XCTAssertEqual(claude.resolvedModel, "")
        XCTAssertEqual(claude.displayModelLabel, "Claude")
        XCTAssertEqual(opencode.displayModelLabel, "opencode")
        // The titlecase fallback still applies to runtimes the catalog has
        // never heard of — that path is what keeps a brand-new alleycat
        // agent renderable without a litter release.
        XCTAssertEqual(unknown.displayModelLabel, "Some-unshipped-agent")
    }

    func testApplyLocalThreadTitleUpdatesThreadAndSessionSummary() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        var snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: key)]
        )

        XCTAssertTrue(snapshot.applyLocalThreadTitle("Renamed Thread", for: key))

        XCTAssertEqual(snapshot.threadSnapshot(for: key)?.info.title, "Renamed Thread")
        XCTAssertEqual(snapshot.sessionSummaries.first { $0.key == key }?.title, "Renamed Thread")
    }

    @MainActor
    func testReconcileBackgroundedTurnsWaitsForAllTrackedThreadsToFinishBeforeNotifying() {
        let rootKey = ThreadKey(serverId: "srv", threadId: "thread-root")
        let childKey = ThreadKey(serverId: "srv", threadId: "thread-child")
        let snapshot = makeSnapshot(
            threads: [
                makeThreadSnapshot(
                    key: rootKey,
                    status: .active,
                    activeTurnId: "turn-root"
                ),
                makeThreadSnapshot(
                    key: childKey,
                    parentThreadId: rootKey.threadId
                )
            ]
        )

        let controller = AppLifecycleController()
        let reconciliation = controller.reconcileBackgroundedTurns(
            snapshot: snapshot,
            trackedKeys: [rootKey, childKey]
        )

        XCTAssertEqual(reconciliation.remainingKeys, [rootKey])
        XCTAssertEqual(reconciliation.activeThreads.map(\.key), [rootKey])
        XCTAssertNil(reconciliation.completedNotificationThread)
    }

    @MainActor
    func testReconcileBackgroundedTurnsPrefersRootThreadForCompletionNotification() {
        let rootKey = ThreadKey(serverId: "srv", threadId: "thread-root")
        let childKey = ThreadKey(serverId: "srv", threadId: "thread-child")
        let snapshot = makeSnapshot(
            threads: [
                makeThreadSnapshot(key: rootKey),
                makeThreadSnapshot(
                    key: childKey,
                    parentThreadId: rootKey.threadId
                )
            ]
        )

        let controller = AppLifecycleController()
        let reconciliation = controller.reconcileBackgroundedTurns(
            snapshot: snapshot,
            trackedKeys: [rootKey, childKey]
        )

        XCTAssertTrue(reconciliation.remainingKeys.isEmpty)
        XCTAssertEqual(reconciliation.completedNotificationThread?.key, rootKey)
    }

    @MainActor
    func testReconcileBackgroundedTurnsKeepsMissingThreadsTracked() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        let snapshot = makeSnapshot(threads: [])

        let controller = AppLifecycleController()
        let reconciliation = controller.reconcileBackgroundedTurns(
            snapshot: snapshot,
            trackedKeys: [key]
        )

        XCTAssertEqual(reconciliation.remainingKeys, [key])
        XCTAssertTrue(reconciliation.activeThreads.isEmpty)
        XCTAssertNil(reconciliation.completedNotificationThread)
    }

    @MainActor
    func testReconcileBackgroundedTurnsKeepsTrustedLiveKeyTrackedDespiteIdleSnapshot() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        let snapshot = makeSnapshot(threads: [makeThreadSnapshot(key: key)])

        let controller = AppLifecycleController()
        let reconciliation = controller.reconcileBackgroundedTurns(
            snapshot: snapshot,
            trackedKeys: [key],
            trustedLiveKeys: [key]
        )

        XCTAssertEqual(reconciliation.remainingKeys, [key])
        XCTAssertEqual(reconciliation.activeThreads.map(\.key), [key])
        XCTAssertNil(reconciliation.completedNotificationThread)
    }

    @MainActor
    func testForegroundRecoveryKeysPreferActuallyBackgroundedThreadsPlusActiveThread() {
        let activeKey = ThreadKey(serverId: "srv", threadId: "thread-active")
        let staleTrackedKey = ThreadKey(serverId: "srv", threadId: "thread-stale")
        var snapshot = makeSnapshot(
            threads: [
                makeThreadSnapshot(key: activeKey, status: .active, activeTurnId: "turn-1"),
                makeThreadSnapshot(key: staleTrackedKey, status: .active, activeTurnId: "turn-2")
            ]
        )
        snapshot.activeThread = activeKey

        let controller = AppLifecycleController()
        let keys = controller.foregroundRecoveryKeys(
            snapshot: snapshot,
            backgroundedKeys: [activeKey]
        )

        XCTAssertEqual(keys, [activeKey])
        XCTAssertFalse(keys.contains(staleTrackedKey))
    }

    @MainActor
    func testForegroundRecoveryKeysIncludeActiveThreadEvenWithoutBackgroundedTrackedTurns() {
        let activeKey = ThreadKey(serverId: "srv", threadId: "thread-active")
        var snapshot = makeSnapshot(
            threads: [makeThreadSnapshot(key: activeKey)]
        )
        snapshot.activeThread = activeKey

        let controller = AppLifecycleController()
        let keys = controller.foregroundRecoveryKeys(
            snapshot: snapshot,
            backgroundedKeys: []
        )

        XCTAssertEqual(keys, [activeKey])
    }

    @MainActor
    func testForegroundRecoveryKeysNeedingReloadSkipsTrustedActiveThread() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-active")
        let controller = AppLifecycleController()

        let reloadKeys = controller.foregroundRecoveryKeysNeedingReload(
            [key],
            activeThread: key,
            trustedLiveKeys: [key],
            notificationActivatedKey: nil,
            notificationActivationAge: nil
        )

        XCTAssertTrue(reloadKeys.isEmpty)
    }

    @MainActor
    func testForegroundRecoveryKeysNeedingReloadSkipsRecentlyNotificationActivatedTrustedThread() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        let controller = AppLifecycleController()

        let reloadKeys = controller.foregroundRecoveryKeysNeedingReload(
            [key],
            activeThread: nil,
            trustedLiveKeys: [key],
            notificationActivatedKey: key,
            notificationActivationAge: 2
        )

        XCTAssertTrue(reloadKeys.isEmpty)
    }

    @MainActor
    func testForegroundRecoveryKeysNeedingReloadStillReloadsStaleNotificationActivation() {
        let key = ThreadKey(serverId: "srv", threadId: "thread-1")
        let controller = AppLifecycleController()

        let reloadKeys = controller.foregroundRecoveryKeysNeedingReload(
            [key],
            activeThread: nil,
            trustedLiveKeys: [key],
            notificationActivatedKey: key,
            notificationActivationAge: 10
        )

        XCTAssertEqual(reloadKeys, [key])
    }

    @MainActor
    func testNotificationThreadKeyParsesThreadMetadata() {
        let key = AppLifecycleController.notificationThreadKey(from: [
            AppLifecycleController.notificationServerIdKey: "srv",
            AppLifecycleController.notificationThreadIdKey: "thread-1"
        ])

        XCTAssertEqual(key, ThreadKey(serverId: "srv", threadId: "thread-1"))
    }

    @MainActor
    func testStaleRefreshPreservesNewThreadAndTrailingRefreshEventuallyApplies() async {
        let first = expectation(description: "First capture")
        let trailing = expectation(description: "Coalesced trailing capture")
        let store = ControlledSnapshotStore { index in
            if index == 0 { first.fulfill() }
            if index == 1 { trailing.fulfill() }
        }
        let model = AppModel(store: store)
        defer { model.stop() }
        let empty = makeSnapshot(threads: [])
        let key = ThreadKey(serverId: "srv", threadId: "arrived-during-refresh")
        let newer = makeSnapshot(threads: [makeThreadSnapshot(key: key)])
        model.applySnapshot(empty)
        let request = Task { await model.refreshSnapshot() }
        await fulfillment(of: [first], timeout: 2)
        model.applySnapshot(newer)
        await store.reply(to: 0, with: empty)
        _ = await request.value
        XCTAssertNotNil(model.threadSnapshot(for: key), "A stale capture must not evict a newer cache entry")
        await fulfillment(of: [trailing], timeout: 2)
        let publishedRevision = model.snapshotRevision
        let published = expectation(description: "Trailing capture published")
        withObservationTracking {
            _ = model.snapshotRevision
        } onChange: {
            published.fulfill()
        }
        await store.reply(to: 1, with: newer)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertGreaterThan(model.snapshotRevision, publishedRevision)
        XCTAssertNotNil(model.threadSnapshot(for: key))
    }

    @MainActor
    func testOverlappingRefreshPublishesNewestCaptureOnly() async {
        let first = expectation(description: "Older capture")
        let second = expectation(description: "Newer capture")
        let store = ControlledSnapshotStore { index in
            if index == 0 { first.fulfill() }
            if index == 1 { second.fulfill() }
        }
        let model = AppModel(store: store)
        defer { model.stop() }
        let key = ThreadKey(serverId: "srv", threadId: "newer")
        let empty = makeSnapshot(threads: [])
        let newer = makeSnapshot(threads: [makeThreadSnapshot(key: key)])
        model.applySnapshot(empty)
        let oldRequest = Task { await model.refreshSnapshot() }
        await fulfillment(of: [first], timeout: 2)
        let newRequest = Task { await model.refreshSnapshot() }
        await fulfillment(of: [second], timeout: 2)
        await store.reply(to: 1, with: newer)
        _ = await newRequest.value
        await store.reply(to: 0, with: empty)
        _ = await oldRequest.value
        XCTAssertNotNil(model.threadSnapshot(for: key))
    }

    @MainActor
    func testCancelledRefreshDoesNotPublishOrReportAnError() async {
        let requested = expectation(description: "Capture started")
        let store = ControlledSnapshotStore { _ in requested.fulfill() }
        let model = AppModel(store: store)
        defer { model.stop() }
        model.applySnapshot(makeSnapshot(threads: []))
        let revision = model.snapshotRevision
        let request = Task { await model.refreshSnapshot() }
        await fulfillment(of: [requested], timeout: 2)
        request.cancel()
        await store.reply(to: 0, with: makeSnapshot(threads: []))
        _ = await request.value
        XCTAssertEqual(model.snapshotRevision, revision)
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testFullResyncDropsCachedThreadsMissingFromAuthoritativeSnapshot() {
        let key = ThreadKey(serverId: "srv", threadId: "removed-with-missed-event")
        let model = AppModel()
        model.applySnapshot(makeSnapshot(threads: [makeThreadSnapshot(key: key)]))
        XCTAssertNotNil(model.threadSnapshot(for: key))

        // The remove event was missed; a full snapshot must still release its cache.
        model.applySnapshot(makeSnapshot(threads: []))
        XCTAssertNil(model.threadSnapshot(for: key))
    }

    @MainActor
    func testFullResyncPreservesCachedOfflineThreadReferencedBySummary() {
        let key = ThreadKey(serverId: "srv", threadId: "offline-history")
        let model = AppModel()
        var snapshot = makeSnapshot(threads: [makeThreadSnapshot(key: key)])
        model.applySnapshot(snapshot)
        snapshot.threads = []
        snapshot.servers[0].health = .disconnected
        snapshot.servers[0].transportState = .disconnected

        model.applySnapshot(snapshot)
        XCTAssertEqual(model.snapshot?.threads.map(\.key), [key])
        XCTAssertNotNil(model.threadSnapshot(for: key))
    }

    @MainActor
    func testFullResyncPreservesCachedActiveThreadBeforeItsSummaryArrives() {
        let key = ThreadKey(serverId: "srv", threadId: "active")
        let model = AppModel()
        model.applySnapshot(makeSnapshot(threads: [makeThreadSnapshot(key: key)]))
        var snapshot = makeSnapshot(threads: [])
        snapshot.activeThread = key

        model.applySnapshot(snapshot)
        XCTAssertEqual(model.snapshot?.threads.map(\.key), [key])
        XCTAssertNotNil(model.threadSnapshot(for: key))
    }

    private func makeSnapshot(threads: [AppThreadSnapshot]) -> AppSnapshotRecord {
        let server = AppServerSnapshot(
            serverId: "srv",
            displayName: "Server",
            host: "srv.local",
            port: 8390,
            wakeMac: nil,
            isLocal: false,
            health: .connected,
            transportState: .connected,
            capabilities: AppServerCapabilities(
                canUseTransportActions: true,
                canBrowseDirectories: true,
                canStartThreads: true,
                canResumeThreads: true,
                supportsTurnPagination: false
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            rateLimitsByRuntime: [],
            availableModels: nil,
            agentRuntimes: [AgentRuntimeInfo(kind: .codex, name: "codex", displayName: "Codex", available: true)],
            connectionProgress: nil,
            usageStats: nil
        )
        let sessionSummaries = threads.map { thread in
            AppSessionSummary(
                key: thread.key,
                agentRuntimeKind: thread.agentRuntimeKind,
                serverDisplayName: server.displayName,
                serverHost: server.host,
                title: thread.info.title ?? "",
                preview: thread.info.preview ?? "",
                cwd: thread.info.cwd ?? "",
                model: thread.model ?? "",
                modelProvider: thread.info.modelProvider ?? "",
                parentThreadId: thread.info.parentThreadId,
                forkedFromId: nil,
                agentNickname: thread.info.agentNickname,
                agentRole: thread.info.agentRole,
                agentDisplayLabel: thread.key.threadId,
                agentStatus: .unknown,
                updatedAt: thread.info.updatedAt,
                hasActiveTurn: thread.hasActiveTurn,
                isResumed: false,
                isSubagent: false,
                isFork: false,
                lastResponsePreview: nil,
                lastResponseTurnId: nil,
                lastUserMessage: nil,
                lastToolLabel: nil,
                recentToolLog: [],
                lastTurnStartMs: nil,
                lastTurnEndMs: nil,
                stats: nil,
                tokenUsage: nil,
                goal: nil
            )
        }

        return AppSnapshotRecord(
            servers: [server],
            threads: threads,
            sessionSummaries: sessionSummaries,
            agentDirectoryVersion: 0,
            activeThread: nil,
            pendingApprovals: [],
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

    private func makeThreadSnapshot(
        key: ThreadKey,
        status: ThreadSummaryStatus = .idle,
        activeTurnId: String? = nil,
        parentThreadId: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        agentRuntimeKind: AgentRuntimeKind = .codex
    ) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: key,
            info: ThreadInfo(
                id: key.threadId,
                title: "Thread",
                model: nil,
                status: status,
                preview: "Preview",
                cwd: "/tmp",
                path: nil,
                modelProvider: modelProvider,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: parentThreadId,
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: nil
            ),
            agentRuntimeKind: agentRuntimeKind,
            collaborationMode: .default,
            model: model,
            reasoningEffort: nil,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: [],
            queuedFollowUps: [],
            activeTurnId: activeTurnId,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: nil,
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil,
            goal: nil,
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
    }
}

private actor SnapshotResponses {
    private var nextIndex = 0
    private var pending: [Int: CheckedContinuation<AppSnapshotRecord, Error>] = [:]
    private var earlyReplies: [Int: AppSnapshotRecord] = [:]
    let onRequest: @Sendable (Int) -> Void

    init(onRequest: @escaping @Sendable (Int) -> Void) { self.onRequest = onRequest }
    func capture() async throws -> AppSnapshotRecord {
        try await withCheckedThrowingContinuation { continuation in
            let index = nextIndex
            nextIndex += 1
            if let reply = earlyReplies.removeValue(forKey: index) {
                continuation.resume(returning: reply)
            } else {
                pending[index] = continuation
            }
            onRequest(index)
        }
    }
    func reply(to index: Int, with snapshot: AppSnapshotRecord) {
        if let continuation = pending.removeValue(forKey: index) {
            continuation.resume(returning: snapshot)
        } else {
            earlyReplies[index] = snapshot
        }
    }
}

private final class ControlledSnapshotStore: AppStore, @unchecked Sendable {
    private let responses: SnapshotResponses
    init(onRequest: @escaping @Sendable (Int) -> Void) {
        responses = SnapshotResponses(onRequest: onRequest)
        super.init(noHandle: NoHandle())
    }
    required init(unsafeFromHandle handle: UInt64) {
        responses = SnapshotResponses(onRequest: { _ in })
        super.init(unsafeFromHandle: handle)
    }
    override func snapshot() async throws -> AppSnapshotRecord { try await responses.capture() }
    func reply(to index: Int, with snapshot: AppSnapshotRecord) async {
        await responses.reply(to: index, with: snapshot)
    }
}
