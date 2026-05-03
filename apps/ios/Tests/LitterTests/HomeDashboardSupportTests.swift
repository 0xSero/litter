import XCTest
@testable import Litter

@MainActor
final class HomeDashboardSupportTests: XCTestCase {
    func testRecentConnectedSessionsFiltersDisconnectedServersAndLimitsToThreeNewest() {
        let servers = [
            makeServerSnapshot(id: "server-a", name: "Server A"),
            makeServerSnapshot(id: "server-b", name: "Server B")
        ]
        let threads = [
            makeThreadSnapshot(serverId: "server-b", threadId: "b-older", updatedAt: 20),
            makeThreadSnapshot(serverId: "server-a", threadId: "a-newest", updatedAt: 50),
            makeThreadSnapshot(serverId: "server-c", threadId: "c-disconnected", updatedAt: 60),
            makeThreadSnapshot(serverId: "server-a", threadId: "a-mid", updatedAt: 40),
            makeThreadSnapshot(serverId: "server-b", threadId: "b-mid", updatedAt: 30),
            makeThreadSnapshot(serverId: "server-a", threadId: "a-oldest", updatedAt: 10)
        ]
        let snapshot = makeSnapshot(servers: servers, threads: threads, activeThread: nil)

        let connectedServers = HomeDashboardSupport.sortedConnectedServers(
            from: servers,
            activeServerId: nil
        )

        let result = HomeDashboardSupport.recentConnectedSessions(
            from: snapshot.sessionSummaries,
            serversById: Dictionary(uniqueKeysWithValues: connectedServers.map { ($0.id, $0) }),
            limit: 3
        )

        XCTAssertEqual(result.map(\.key.threadId), ["a-newest", "a-mid", "b-mid"])
    }

    func testDefaultConnectedServerIdPrefersPreferredThenActiveThenFirstConnected() {
        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: ThreadKey(serverId: "server-b", threadId: "thread-1"),
                preferredServerId: "server-a"
            ),
            "server-a"
        )

        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: ThreadKey(serverId: "server-b", threadId: "thread-1"),
                preferredServerId: "server-missing"
            ),
            "server-b"
        )

        XCTAssertEqual(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: ["server-a", "server-b"],
                activeThreadKey: nil,
                preferredServerId: nil
            ),
            "server-a"
        )

        XCTAssertNil(
            SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds: [],
                activeThreadKey: nil,
                preferredServerId: nil
            )
        )
    }

    func testSavedServerMigratesLegacySshPortIntoDedicatedField() throws {
        let data = """
        {
          "id": "legacy-ssh",
          "name": "Legacy SSH",
          "hostname": "mac-mini.local",
          "port": 8390,
          "source": "manual",
          "hasCodexServer": false,
          "wakeMAC": null,
          "sshPortForwardingEnabled": true
        }
        """.data(using: .utf8)!

        let saved = try JSONDecoder().decode(SavedServer.self, from: data)
        let discovered = saved.toDiscoveredServer()

        XCTAssertNil(discovered.port)
        XCTAssertEqual(discovered.sshPort, 8390)
        XCTAssertEqual(discovered.resolvedSSHPort, 8390)
        XCTAssertFalse(discovered.hasCodexServer)
    }

    func testHomeDashboardModelRefreshesWhenObservedSnapshotChanges() async {
        let appModel = AppModel()
        let model = HomeDashboardModel()
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [],
                activeThread: nil
            )
        )
        await flushMainQueue()

        XCTAssertEqual(model.connectedServers.map(\.id), ["server-a"])
    }

    func testSortedConnectedServersDeduplicatesEquivalentHostsAndPrefersActiveConnection() {
        let primary = makeServerSnapshot(
            id: "server-a",
            name: "Mac Studio",
            host: "192.168.1.167",
            port: 8390
        )
        let duplicate = makeServerSnapshot(
            id: "server-b",
            name: "Mac Studio",
            host: "192.168.1.167",
            port: 9494
        )

        let result = HomeDashboardSupport.sortedConnectedServers(
            from: [duplicate, primary],
            activeServerId: duplicate.serverId
        )

        XCTAssertEqual(result.map(\.id), [duplicate.serverId])
    }

    func testHomeDashboardModelRefreshesRecentSessionsWhenObservedSnapshotThreadChanges() async {
        let appModel = AppModel()
        let model = HomeDashboardModel()
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-older", updatedAt: 20),
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-newer", updatedAt: 40)
                ],
                activeThread: nil
            )
        )
        await flushMainQueue()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-older", updatedAt: 60),
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-newer", updatedAt: 40)
                ],
                activeThread: nil
            )
        )
        await flushMainQueue()

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-older", "thread-newer"])
    }

    func testHomeDashboardModelRefreshesRecentSessionsWhenThreadsArriveAfterBind() async {
        let appModel = AppModel()
        let model = HomeDashboardModel()
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [makeThreadSnapshot(serverId: "server-a", threadId: "thread-late", updatedAt: 80)],
                activeThread: nil
            )
        )
        await flushMainQueue()

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-late"])
    }

    func testRecentConnectedSessionsPrefersExplicitTitleOverPreview() {
        let server = makeServerSnapshot(id: "server-a", name: "Server A")
        var thread = makeThreadSnapshot(serverId: "server-a", threadId: "thread-renamed", updatedAt: 80)
        thread.info.title = "Renamed thread"
        thread.info.preview = "Original first user message"
        let snapshot = makeSnapshot(servers: [server], threads: [thread], activeThread: nil)

        let connectedServers = HomeDashboardSupport.sortedConnectedServers(
            from: [server],
            activeServerId: nil
        )
        let result = HomeDashboardSupport.recentConnectedSessions(
            from: snapshot.sessionSummaries,
            serversById: Dictionary(uniqueKeysWithValues: connectedServers.map { ($0.id, $0) }),
            limit: nil
        )

        XCTAssertEqual(result.first?.sessionTitle, "Renamed thread")
    }

    func testHomeDashboardModelIgnoresThreadChangesWhileInactiveAndRefreshesOnReactivate() async {
        let appModel = AppModel()
        let model = HomeDashboardModel()
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [makeThreadSnapshot(serverId: "server-a", threadId: "thread-initial", updatedAt: 20)],
                activeThread: nil
            )
        )
        await flushMainQueue()

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-initial"])
        let rebuildCountBeforeDeactivate = model.rebuildCount

        model.deactivate()
        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-initial", updatedAt: 20),
                    makeThreadSnapshot(serverId: "server-a", threadId: "thread-late", updatedAt: 80)
                ],
                activeThread: nil
            )
        )
        await flushMainQueue()

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-initial"])
        XCTAssertEqual(model.rebuildCount, rebuildCountBeforeDeactivate)

        model.activate()
        await flushMainQueue()

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-late", "thread-initial"])
        XCTAssertGreaterThan(model.rebuildCount, rebuildCountBeforeDeactivate)
    }

    private func makeThreadSnapshot(serverId: String, threadId: String, updatedAt: TimeInterval) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            info: ThreadInfo(
                id: threadId,
                title: nil,
                model: nil,
                status: .idle,
                preview: threadId,
                cwd: "/tmp/\(threadId)",
                path: nil,
                modelProvider: nil,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: Int64(updatedAt)
            ),
            agentRuntimeKind: .codex,
            collaborationMode: .default,
            model: nil,
            reasoningEffort: nil,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: [],
            queuedFollowUps: [],
            activeTurnId: nil,
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

    private func makeSnapshot(
        servers: [AppServerSnapshot],
        threads: [AppThreadSnapshot],
        activeThread: ThreadKey?
    ) -> AppSnapshotRecord {
        let serversById = Dictionary(uniqueKeysWithValues: servers.map { ($0.serverId, $0) })
        let sessionSummaries = threads.compactMap { thread -> AppSessionSummary? in
            guard let server = serversById[thread.key.serverId] else { return nil }
            return AppSessionSummary(
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
                agentDisplayLabel: AgentLabelFormatter.format(
                    nickname: thread.info.agentNickname,
                    role: thread.info.agentRole,
                    fallbackIdentifier: thread.key.threadId
                ),
                agentStatus: .unknown,
                updatedAt: thread.info.updatedAt,
                hasActiveTurn: thread.hasActiveTurn,
                isResumed: false,
                isSubagent: thread.info.parentThreadId != nil,
                isFork: thread.info.parentThreadId != nil,
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
            servers: servers,
            threads: threads,
            sessionSummaries: sessionSummaries,
            agentDirectoryVersion: 0,
            activeThread: activeThread,
            pendingApprovals: [],
            pendingUserInputs: [],
            voiceSession: inactiveVoiceSession()
        )
    }

    private func makeServerSnapshot(
        id: String,
        name: String,
        host: String? = nil,
        port: UInt16 = 8390,
        isLocal: Bool = false,
        health: AppServerHealth = .connected
    ) -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: id,
            displayName: name,
            host: host ?? "\(id).local",
            port: port,
            wakeMac: nil,
            isLocal: isLocal,
            supportsIpc: false,
            hasIpc: false,
            health: health,
            transportState: health == .connected ? .connected : .disconnected,
            ipcState: isLocal ? .unsupported : .unsupported,
            capabilities: AppServerCapabilities(
                canUseTransportActions: health == .connected,
                canBrowseDirectories: health == .connected,
                canStartThreads: health == .connected,
                canResumeThreads: health == .connected,
                canUseIpc: false,
                canResumeViaIpc: false,
                supportsTurnPagination: true
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
    }

    private func inactiveVoiceSession() -> AppVoiceSessionSnapshot {
        AppVoiceSessionSnapshot(
            activeThread: nil,
            sessionId: nil,
            phase: nil,
            lastError: nil,
            transcriptEntries: [],
            handoffThreadKey: nil
        )
    }

    private func flushMainQueue() async {
        await Task.yield()
        await Task.yield()
    }
}
