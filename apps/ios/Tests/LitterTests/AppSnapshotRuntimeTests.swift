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
        XCTAssertEqual(opencode.displayModelLabel, "opencode")
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

    private func makeSnapshot(threads: [AppThreadSnapshot]) -> AppSnapshotRecord {
        let server = AppServerSnapshot(
            serverId: "srv",
            displayName: "Server",
            host: "srv.local",
            port: 8390,
            wakeMac: nil,
            isLocal: false,
            supportsIpc: false,
            hasIpc: false,
            health: .connected,
            transportState: .connected,
            ipcState: .unsupported,
            capabilities: AppServerCapabilities(
                canUseTransportActions: true,
                canBrowseDirectories: true,
                canStartThreads: true,
                canResumeThreads: true,
                canUseIpc: false,
                canResumeViaIpc: false,
                supportsTurnPagination: false
            ),
            account: nil,
            requiresOpenaiAuth: false,
            rateLimits: nil,
            availableModels: nil,
            agentRuntimes: [AgentRuntimeInfo(kind: .codex, name: "codex", displayName: "Codex", available: true)],
            connectionProgress: nil,
            usageStats: nil,
            codexVersion: nil
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
                tokenUsage: nil
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
            )
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
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
    }
}
