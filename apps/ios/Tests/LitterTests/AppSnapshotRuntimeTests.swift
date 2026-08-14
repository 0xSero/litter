import XCTest
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

        XCTAssertEqual(claude.resolvedModel, "")
        XCTAssertEqual(claude.displayModelLabel, "Claude")
        XCTAssertEqual(opencode.displayModelLabel, "Opencode")
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
    func testR1SameThreadRebindOnStreamingDelta() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a")
        let item = makeAssistantItem(id: "item-1", text: "hello")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshotWithItem(key: keyA, item: item)]))
        let baseline = appModel.threadRebindSignal(for: keyA).revision
        await appModel._testHandleStoreUpdate(.threadStreamingDelta(key: keyA, itemId: "item-1", kind: .assistantText, text: " world"))
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baseline + 1)
    }
    @MainActor
    func testR2ForeignThreadIsolationOnStreamingDelta() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a"), keyB = ThreadKey(serverId: "srv", threadId: "b")
        let item = makeAssistantItem(id: "item-1", text: "hello")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshotWithItem(key: keyA, item: item), makeThreadSnapshotWithItem(key: keyB, item: item)]))
        let baselineA = appModel.threadRebindSignal(for: keyA).revision, baselineGlobal = appModel.conversationGlobalRevision, baselineRevision = appModel.snapshotRevision
        await appModel._testHandleStoreUpdate(.threadStreamingDelta(key: keyB, itemId: "item-1", kind: .assistantText, text: " world"))
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baselineA)
        XCTAssertEqual(appModel.conversationGlobalRevision, baselineGlobal)
        XCTAssertGreaterThan(appModel.snapshotRevision, baselineRevision)
    }
    @MainActor
    func testR3UnkeyedGlobalBumpOnPendingApprovals() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a"), keyB = ThreadKey(serverId: "srv", threadId: "b")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshot(key: keyA), makeThreadSnapshot(key: keyB)]))
        let baselineGlobal = appModel.conversationGlobalRevision, baselineA = appModel.threadRebindSignal(for: keyA).revision, baselineB = appModel.threadRebindSignal(for: keyB).revision
        var snap = appModel.snapshot!
        snap.pendingApprovals = [PendingApproval(id: "appr-1", serverId: "srv", kind: .command, threadId: nil, turnId: nil, itemId: nil, command: "ls", path: nil, grantRoot: nil, cwd: nil, reason: "test")]
        appModel.applySnapshot(snap)
        XCTAssertEqual(appModel.conversationGlobalRevision, baselineGlobal + 1)
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baselineA)
        XCTAssertEqual(appModel.threadRebindSignal(for: keyB).revision, baselineB)
    }
    @MainActor
    func testR4SummaryOnlyWriteBumpsNothing() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a")
        let item = makeAssistantItem(id: "item-1", text: "hello")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshotWithItem(key: keyA, item: item)]))
        let baselineSignal = appModel.threadRebindSignal(for: keyA).revision, baselineGlobal = appModel.conversationGlobalRevision, baselineRevision = appModel.snapshotRevision
        var summary = appModel.snapshot!.sessionSummaries.first { $0.key == keyA }!
        summary.title = "Updated"
        await appModel._testHandleStoreUpdate(.threadItemChanged(key: keyA, item: item, sessionSummary: summary))
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baselineSignal)
        XCTAssertEqual(appModel.conversationGlobalRevision, baselineGlobal)
        XCTAssertGreaterThan(appModel.snapshotRevision, baselineRevision)
    }
    @MainActor
    func testR5RemovalRetainsSignalEntryAndMonotonicCount() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a"), keyB = ThreadKey(serverId: "srv", threadId: "b")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshot(key: keyA), makeThreadSnapshot(key: keyB)]))
        let signalB = appModel.threadRebindSignal(for: keyB)
        let baselineA = appModel.threadRebindSignal(for: keyA).revision
        await appModel._testHandleStoreUpdate(.threadRemoved(key: keyB, agentDirectoryVersion: 1))
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baselineA)
        XCTAssertTrue(appModel.threadRebindSignal(for: keyB) === signalB)
        let afterRemoval = appModel.threadRebindSignal(for: keyB).revision
        let reborn = makeThreadSnapshot(key: keyB)
        var summary = appModel.snapshot!.sessionSummaries.first { $0.key == keyB } ?? makeSnapshot(threads: [reborn]).sessionSummaries[0]
        summary.title = "Reborn"
        await appModel._testHandleStoreUpdate(.threadUpserted(thread: reborn, sessionSummary: summary, agentDirectoryVersion: 1))
        XCTAssertEqual(appModel.threadRebindSignal(for: keyB).revision, afterRemoval + 1)
        XCTAssertTrue(appModel.threadRebindSignal(for: keyB) === signalB)
    }
    @MainActor
    func testR6ActiveThreadNilBumpsGlobalNotScoped() async {
        let appModel = AppModel()
        let keyA = ThreadKey(serverId: "srv", threadId: "a")
        appModel.applySnapshot(makeSnapshot(threads: [makeThreadSnapshot(key: keyA)]))
        let baselineGlobal = appModel.conversationGlobalRevision, baselineA = appModel.threadRebindSignal(for: keyA).revision
        await appModel._testHandleStoreUpdate(.activeThreadChanged(key: nil))
        XCTAssertEqual(appModel.conversationGlobalRevision, baselineGlobal + 1)
        XCTAssertEqual(appModel.threadRebindSignal(for: keyA).revision, baselineA)
    }
    private func makeAssistantItem(id: String, text: String) -> HydratedConversationItem {
        HydratedConversationItem(id: id, content: .assistant(HydratedAssistantMessageData(text: text, agentNickname: nil, agentRole: nil, phase: nil)), sourceTurnId: nil, sourceTurnIndex: nil, timestamp: nil, isFromUserTurnBoundary: false)
    }
    private func makeThreadSnapshotWithItem(key: ThreadKey, item: HydratedConversationItem) -> AppThreadSnapshot {
        var thread = makeThreadSnapshot(key: key)
        thread.hydratedConversationItems = [item]
        return thread
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

#if DEBUG
extension AppSnapshotRuntimeTests {
    private func grammarEnv(_ input: String) -> [String: String] { ["CODEXIOS_UI_TEST_BURST_FOLLOWUPS": "1", "CODEXIOS_UI_TEST_BURST_NONCE": input] }
    @MainActor
    func testDebugProductionFixtureShapeIsExactAndDeterministic() {
        let snapshot = DebugProductionFixture.makeSnapshot(sessions: 300, items: 1500)
        XCTAssertEqual(snapshot, DebugProductionFixture.makeSnapshot(sessions: 300, items: 1500), "independent construction must be identical")
        XCTAssertEqual(snapshot.threads.count, 300); XCTAssertEqual(snapshot.sessionSummaries.count, 300)
        XCTAssertEqual(Set(snapshot.threads.compactMap(\.info.cwd)), Set((0..<12).map { "/Projects/Workspace-\($0)" }))
        XCTAssertEqual(snapshot.threads[9].info.parentThreadId, "fixture-thread-0")
        let items = snapshot.threads[0].hydratedConversationItems
        XCTAssertEqual(items.count, 1500)
        XCTAssertEqual(items[749], DebugProductionFixture.item(at: 749), "thread-0 items must follow the 6-case pattern")
        XCTAssertEqual(items[1].id, "fixture-item-1")
        XCTAssertEqual(snapshot.threads[1].key, DebugProductionFixture.liveThreadKey)
    }
    @MainActor
    func testBurstInputGrammarVectorsAndFullRejectionTable() throws {
        let vectors: [(input: String, trial: String, attempt: String, steer: Bool, f2: String)] = [
            ("B7.1-PLAIN-9af3c2", "7", "1", false, "Follow-up two B7.1-F2-9af3c2: reply with exactly BRAVO."),
            ("B12.2-STEER-00ffee", "12", "2", true, "Follow-up two B12.2-F2-00ffee: reply with exactly BRAVO-STEERED."),
            ("B901.1-STEER-0c0ffe", "901", "1", true, "Follow-up two B901.1-F2-0c0ffe: reply with exactly BRAVO-STEERED."),
            ("B15.1-PLAIN-abc123", "15", "1", false, "Follow-up two B15.1-F2-abc123: reply with exactly BRAVO.")
        ]
        for v in vectors {
            let config = try XCTUnwrap(DebugBurstDriver.configuration(environment: grammarEnv(v.input)))
            XCTAssertEqual(config.trial, v.trial); XCTAssertEqual(config.attempt, v.attempt); XCTAssertEqual(config.mode, v.steer ? .steer : .plain)
            XCTAssertEqual(DebugBurstDriver.wireNonce(config, fire: 2), "B\(v.trial).\(v.attempt)-F2-\(v.input.suffix(6))")
            XCTAssertEqual(DebugBurstDriver.followUpTexts(configuration: config)[1], v.f2)
        }
        let v1 = try XCTUnwrap(DebugBurstDriver.configuration(environment: grammarEnv("B7.1-PLAIN-9af3c2")))
        XCTAssertEqual(DebugBurstDriver.followUpTexts(configuration: v1), [
            "Follow-up one B7.1-F1-9af3c2: reply with exactly ALPHA.",
            "Follow-up two B7.1-F2-9af3c2: reply with exactly BRAVO.",
            "Follow-up three B7.1-F3-9af3c2: reply with exactly CHARLIE."
        ])
        let v2 = try XCTUnwrap(DebugBurstDriver.configuration(environment: grammarEnv("B12.2-STEER-00ffee")))
        XCTAssertEqual((1...3).map { DebugBurstDriver.wireNonce(v2, fire: $0) }, ["B12.2-F1-00ffee", "B12.2-F2-00ffee", "B12.2-F3-00ffee"])
        XCTAssertEqual(DebugBurstDriver.followUpTexts(configuration: v2), ["Follow-up one B12.2-F1-00ffee: reply with exactly ALPHA.", "Follow-up two B12.2-F2-00ffee: reply with exactly BRAVO-STEERED.", "Follow-up three B12.2-F3-00ffee: reply with exactly CHARLIE."])
        XCTAssertEqual(DebugBurstDriver.followUpTexts(configuration: try XCTUnwrap(DebugBurstDriver.configuration(environment: grammarEnv("B12.2-STEER-00ffee")))), DebugBurstDriver.followUpTexts(configuration: v2), "V5: fresh parse yields byte-identical texts")
        let rejections = ["B7.1-F2-9af3c2", "B7.1-9af3c2", "B7.1-plain-9af3c2", "B7.1-Steer-9af3c2", "B7.1-PLAIN-9AF3C2", "b7.1-PLAIN-9af3c2", "B07.1-PLAIN-9af3c2", "B7.0-PLAIN-9af3c2", "B7.1-PLAIN-9af3c", "B7.1-PLAIN-9af3c2d", "B7.1-PLAIN-9af3g2", "B7.1-PLAIN-STEER-9af3c2", " B7.1-PLAIN-9af3c2", "B7.1-PLAIN-9af3c2\t"]
        for input in rejections {
            XCTAssertNil(DebugBurstDriver.configuration(environment: grammarEnv(input)))
            XCTAssertEqual(DebugBurstDriver.rejectLine("malformed-nonce", value: input), "burst.driver reject reason=malformed-nonce value=\"\(input)\"")
        }
        XCTAssertEqual(DebugBurstDriver.rejectLine("missing-nonce"), "burst.driver reject reason=missing-nonce")
        XCTAssertNil(DebugBurstDriver.configuration(environment: ["CODEXIOS_UI_TEST_BURST_FOLLOWUPS": "1"]), "followups armed + absent nonce: exactly one missing-nonce reject")
        XCTAssertNil(DebugBurstDriver.configuration(environment: grammarEnv("")), "followups armed + empty nonce: exactly one missing-nonce reject")
    }

    @MainActor
    func testBurstTimingParsingIsPositionalAndAlwaysReturnsThreeOffsets() {
        XCTAssertEqual(DebugBurstDriver.parseTimings(nil), DebugBurstDriver.defaultOffsetsMs)
        XCTAssertEqual(DebugBurstDriver.parseTimings(" 250 "), [250, 400, 700])
        XCTAssertEqual(DebugBurstDriver.parseTimings("0,-5"), [10, 10, 700])
        XCTAssertEqual(DebugBurstDriver.parseTimings("5,3000,100"), [10, 2000, 100])
        XCTAssertEqual(DebugBurstDriver.parseTimings("100,200,300,400"), [100, 200, 300])
        XCTAssertEqual(DebugBurstDriver.parseTimings("200,abc,700"), [200, 400, 700], "malformed slot keeps its position and defaults")
        XCTAssertEqual(DebugBurstDriver.parseTimings("200,,700"), [200, 400, 700], "empty slot keeps its position and defaults")
        XCTAssertEqual(DebugBurstDriver.parseTimings(",250,"), [200, 250, 700])
        XCTAssertEqual(DebugBurstDriver.checkpointDelayMs(lastFireOffsetMs: 700, commandWindowMs: 8_000), 16_000)
        XCTAssertEqual(DebugBurstDriver.checkpointDelayMs(lastFireOffsetMs: 700, commandWindowMs: 20_000), 28_000)
        XCTAssertEqual(DebugBurstDriver.burstPlan(offsetsMs: [200, 400, 700], anchorMs: 10_000).map(\.intendedMs), [10_200, 10_400, 10_700])
    }
    @MainActor
    func testBurstDriverArmLatchIsOneShotAndRecursionGuarded() throws {
        let appModel = AppModel(); let driver = DebugBurstDriver()
        driver.armIfRequested(environment: [:], appModel: appModel)
        XCTAssertEqual(driver.phase, .idle)
        driver.armIfRequested(environment: grammarEnv("B1.1-PLAIN-abc123"), appModel: appModel)
        XCTAssertEqual(driver.phase, .armed)
        let key = DebugProductionFixture.liveThreadKey
        driver.noteStartTurnEntered(key: key, text: DebugBurstDriver.anchorPrompt + " ")
        XCTAssertEqual(driver.phase, .armed, "near-miss anchor text must not fire")
        XCTAssertFalse(driver.noteStartTurnEntered(key: key, text: DebugBurstDriver.anchorPrompt), "live anchor never short-circuits startTurn; the real pipeline runs")
        XCTAssertEqual(driver.phase, .fired)
        XCTAssertEqual(driver.scheduledFireCount, 3, "default offsets schedule exactly F1/F2/F3")
        driver.armIfRequested(environment: grammarEnv("B2.1-PLAIN-def456"), appModel: appModel)
        XCTAssertEqual(driver.phase, .fired, "one-shot latch must never re-arm")
        var longEnv = grammarEnv("B29.1-PLAIN-feed42"); longEnv["CODEXIOS_UI_TEST_PRODUCTION_FIXTURE"] = "1"
        let long = DebugBurstDriver(); long.armIfRequested(environment: longEnv, appModel: appModel); XCTAssertTrue(long.noteStartTurnEntered(key: key, text: DebugBurstDriver.anchorPromptLong), "fixture T0-LONG anchor short-circuits"); XCTAssertEqual(long.phase, .fired)
        let texts = DebugBurstDriver.followUpTexts(configuration: try XCTUnwrap(DebugBurstDriver.configuration(environment: grammarEnv("B1.1-PLAIN-abc123"))))
        for text in texts { driver.noteStartTurnEntered(key: key, text: text) }
        XCTAssertEqual(driver.scheduledFireCount, 3, "driver-fired follow-ups never recursively schedule more fires")
    }
    @MainActor
    func testIngressLedgerCapDropHeaderAndResetAccounting() {
        let model = AppModel()
        for i in 0..<520 { model.debugAppendLedger("e\(i)") }
        XCTAssertEqual(model.debugIngressLedger.count, 512); XCTAssertEqual(model.debugIngressDropped, 8)
        XCTAssertEqual(model.debugFlushIngressLedger(reason: "test"), "burst.ledger flush reason=test entries=512 dropped=8")
        XCTAssertEqual(model.debugIngressLedger.count, 0); XCTAssertEqual(model.debugIngressDropped, 0)
        XCTAssertNil(model.debugFlushIngressLedger(reason: "empty"))
    }
    @MainActor
    func testFixtureAnchorShortCircuitsStartTurnAndRoutesBurstStreamToThread0Item1() async throws {
        let model = AppModel()
        model.applySnapshot(DebugProductionFixture.makeSnapshot(sessions: 300, items: 1500))
        var env = grammarEnv("B1.1-PLAIN-abc123")
        env["CODEXIOS_UI_TEST_BURST_TIMINGS_MS"] = "30,60,90"
        env["CODEXIOS_UI_TEST_PRODUCTION_FIXTURE"] = "1"
        XCTAssertTrue(model.debugArmBurstDriverIfRequested(environment: env))
        let key = ThreadKey(serverId: DebugProductionFixture.serverId, threadId: "fixture-thread-0")
        let foreignBefore = model.threadSnapshot(for: DebugProductionFixture.liveThreadKey)?.hydratedConversationItems.first { $0.id == DebugProductionFixture.liveAssistantItemId }
        try await model.startTurn(key: key, payload: AppComposerPayload(text: DebugBurstDriver.anchorPrompt, additionalInputs: []))
        try? await Task.sleep(nanoseconds: 800_000_000) // 30/60/90 ms fires land; the 1 s drain stays out
        let thread0 = model.threadSnapshot(for: key)
        XCTAssertEqual(thread0?.activeTurnId, "fixture-burst-turn")
        XCTAssertEqual(thread0?.queuedFollowUps.count, 3)
        guard case .assistant(let displayed)? = thread0?.hydratedConversationItems.first(where: { $0.id == "fixture-item-1" })?.content else { return XCTFail("thread-0 displayed stream item missing") }
        XCTAssertTrue(displayed.text.contains("burst"), "thread-0 fixture-item-1 carries the displayed burst stream on the 1500-item route")
        let foreignAfter = model.threadSnapshot(for: DebugProductionFixture.liveThreadKey)?.hydratedConversationItems.first { $0.id == DebugProductionFixture.liveAssistantItemId }
        XCTAssertEqual(foreignAfter, foreignBefore, "foreign streaming stays distinct on thread-1's live assistant, untouched")
    }
}
#endif
