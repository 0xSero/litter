import XCTest
@testable import Litter

@MainActor
final class HomeDashboardSupportTests: XCTestCase {
    func testLocalStudioOnlyCatalogsDeferToServerConfiguredDefault() {
        XCTAssertTrue(usesServerConfiguredModelDefault([.localStudio]))
        XCTAssertTrue(
            usesServerConfiguredModelDefault([.localStudio, .localStudio])
        )
        XCTAssertFalse(usesServerConfiguredModelDefault([]))
        XCTAssertFalse(
            usesServerConfiguredModelDefault([.localStudio, .codex])
        )
    }

    func testLocalStudioPinsKeepNewlySyncedSessionsVisible() async {
        let appModel = AppModel()
        let pinnedKey = SavedThreadsStore.PinnedKey(
            threadKey: ThreadKey(serverId: "studio", threadId: "pinned")
        )
        let model = HomeDashboardModel(
            persistence: persistence(pinned: [pinnedKey]),
            observedRefreshDelayNanoseconds: 0
        )
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [
                    makeServerSnapshot(
                        id: "studio",
                        name: "Local Studio",
                        runtimeKind: .localStudio
                    )
                ],
                threads: [
                    makeThreadSnapshot(
                        serverId: "studio",
                        threadId: "pinned",
                        updatedAt: 20,
                        runtimeKind: .localStudio
                    ),
                    makeThreadSnapshot(
                        serverId: "studio",
                        threadId: "recent",
                        updatedAt: 40,
                        runtimeKind: .localStudio
                    )
                ],
                activeThread: nil
            )
        )
        await waitUntil("Local Studio keeps its pinned and recent sessions") {
            model.recentSessions.map(\.key.threadId) == ["pinned", "recent"]
        }

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["pinned", "recent"])
    }

    func testCodexPinsKeepExistingPinsOnlyBehavior() async {
        let appModel = AppModel()
        let pinnedKey = SavedThreadsStore.PinnedKey(
            threadKey: ThreadKey(serverId: "codex", threadId: "pinned")
        )
        let model = HomeDashboardModel(
            persistence: persistence(pinned: [pinnedKey]),
            observedRefreshDelayNanoseconds: 0
        )
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "codex", name: "Codex")],
                threads: [
                    makeThreadSnapshot(serverId: "codex", threadId: "pinned", updatedAt: 20),
                    makeThreadSnapshot(serverId: "codex", threadId: "recent", updatedAt: 40)
                ],
                activeThread: nil
            )
        )
        await waitUntil("Codex keeps its existing pins-only home list") {
            model.recentSessions.map(\.key.threadId) == ["pinned"]
        }

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["pinned"])
    }

    func testLocalStudioDoesNotShowFalseOpenAISignInWarning() {
        let studio = makeServerSnapshot(
            id: "studio",
            name: "Local Studio",
            runtimeKind: .localStudio
        )
        let codex = makeServerSnapshot(
            id: "codex",
            name: "Codex",
            requiresOpenaiAuth: true
        )

        XCTAssertEqual(studio.statusLabel, "Connected")
        XCTAssertEqual(studio.statusDotState, .ok)
        XCTAssertEqual(codex.statusLabel, "Sign in required")
        XCTAssertEqual(codex.statusDotState, .pending)
    }

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
        let model = HomeDashboardModel(persistence: .empty, observedRefreshDelayNanoseconds: 0)
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [],
                activeThread: nil
            )
        )
        await waitUntil("dashboard observes the connected server") {
            model.connectedServers.map(\.id) == ["server-a"]
        }

        XCTAssertEqual(model.connectedServers.map(\.id), ["server-a"])
    }

    func testSortedConnectedServersPreservesDistinctLiveEndpointsAndPrefersActiveConnection() {
        let primary = makeServerSnapshot(
            id: "server-a",
            name: "Mac Studio",
            host: "192.168.1.167",
            port: 8390
        )
        let active = makeServerSnapshot(
            id: "server-b",
            name: "Mac Studio",
            host: "192.168.1.167",
            port: 9494
        )

        let result = HomeDashboardSupport.sortedConnectedServers(
            from: [active, primary],
            activeServerId: active.serverId
        )

        XCTAssertEqual(result.map(\.id), [active.serverId, primary.serverId])
    }

    func testHomeDashboardModelRefreshesRecentSessionsWhenObservedSnapshotThreadChanges() async {
        let appModel = AppModel()
        let model = HomeDashboardModel(persistence: .empty, observedRefreshDelayNanoseconds: 0)
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
        await waitUntil("dashboard observes the initial thread ordering") {
            model.recentSessions.map(\.key.threadId) == ["thread-newer", "thread-older"]
        }

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
        await waitUntil("dashboard observes the updated thread ordering") {
            model.recentSessions.map(\.key.threadId) == ["thread-older", "thread-newer"]
        }

        XCTAssertEqual(model.recentSessions.map(\.key.threadId), ["thread-older", "thread-newer"])
    }

    func testHomeDashboardModelRefreshesRecentSessionsWhenThreadsArriveAfterBind() async {
        let appModel = AppModel()
        let model = HomeDashboardModel(persistence: .empty, observedRefreshDelayNanoseconds: 0)
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [makeThreadSnapshot(serverId: "server-a", threadId: "thread-late", updatedAt: 80)],
                activeThread: nil
            )
        )
        await waitUntil("dashboard observes threads arriving after binding") {
            model.recentSessions.map(\.key.threadId) == ["thread-late"]
        }

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

    func testOfflineAlleycatServerShowsSavedDroidRuntime() {
        let saved = SavedServer(
            id: "alleycat:node-abc",
            name: "Factory Host",
            hostname: "node-abc",
            port: 0,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            wakeMAC: nil,
            preferredConnectionMode: nil,
            preferredCodexPort: nil,
            sshPortForwardingEnabled: nil,
            websocketURL: nil,
            rememberedByUser: true,
            alleycatNodeId: "node-abc",
            alleycatRelay: nil,
            alleycatAgentName: "codex,droid",
            alleycatAgentWire: "jsonl"
        )

        let result = HomeDashboardSupport.sortedConnectedServers(
            from: [],
            savedServers: [saved],
            activeServerId: nil
        )

        XCTAssertEqual(result.first?.sourceLabel, "alleycat")
        XCTAssertEqual(result.first?.agentRuntimes.map(\.kind), [.codex, .droid])
    }

    func testHomeDashboardModelIgnoresThreadChangesWhileInactiveAndRefreshesOnReactivate() async {
        let appModel = AppModel()
        let model = HomeDashboardModel(persistence: .empty, observedRefreshDelayNanoseconds: 0)
        model.bind(appModel: appModel)
        model.activate()

        appModel.applySnapshot(
            makeSnapshot(
                servers: [makeServerSnapshot(id: "server-a", name: "Server A")],
                threads: [makeThreadSnapshot(serverId: "server-a", threadId: "thread-initial", updatedAt: 20)],
                activeThread: nil
            )
        )
        await waitUntil("dashboard observes the initial thread") {
            model.recentSessions.map(\.key.threadId) == ["thread-initial"]
        }

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

    private func makeThreadSnapshot(
        serverId: String,
        threadId: String,
        updatedAt: TimeInterval,
        runtimeKind: AgentRuntimeKind = .codex
    ) -> AppThreadSnapshot {
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
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: Int64(updatedAt)
            ),
            agentRuntimeKind: runtimeKind,
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
            goal: nil,
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
                forkedFromId: nil,
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
                tokenUsage: nil,
                goal: nil
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
            voiceSession: inactiveVoiceSession(),
            terminalSessions: [],
            activeTerminalId: nil
        )
    }

    private func makeServerSnapshot(
        id: String,
        name: String,
        host: String? = nil,
        port: UInt16 = 8390,
        isLocal: Bool = false,
        health: AppServerHealth = .connected,
        runtimeKind: AgentRuntimeKind = .codex,
        requiresOpenaiAuth: Bool = false
    ) -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: id,
            displayName: name,
            host: host ?? "\(id).local",
            port: port,
            wakeMac: nil,
            isLocal: isLocal,
            health: health,
            transportState: health == .connected ? .connected : .disconnected,
            capabilities: AppServerCapabilities(
                canUseTransportActions: health == .connected,
                canBrowseDirectories: health == .connected,
                canStartThreads: health == .connected,
                canResumeThreads: health == .connected,
                supportsTurnPagination: true
            ),
            account: nil,
            requiresOpenaiAuth: requiresOpenaiAuth,
            rateLimits: nil,
            rateLimitsByRuntime: [],
            availableModels: nil,
            agentRuntimes: [
                AgentRuntimeInfo(
                    kind: runtimeKind,
                    name: runtimeKind,
                    displayName: runtimeKind.displayLabel,
                    available: true
                )
            ],
            connectionProgress: nil,
            usageStats: nil,
            sessionListHasMore: false
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

    private func persistence(
        pinned: [SavedThreadsStore.PinnedKey]
    ) -> HomeDashboardPersistence {
        var pinnedKeys = pinned
        return HomeDashboardPersistence(
            rememberedServers: { [] },
            pinnedKeys: { pinnedKeys },
            hiddenKeys: { [] },
            addPinned: { key in
                if !pinnedKeys.contains(key) {
                    pinnedKeys.append(key)
                }
            },
            removePinned: { key in pinnedKeys.removeAll { $0 == key } },
            hide: { _ in },
            unhide: { _ in },
            selectedServerId: { nil },
            setSelectedServerId: { _ in },
            selectedProjectId: { nil },
            setSelectedProjectId: { _ in }
        )
    }

    private func flushMainQueue() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func waitUntil(_ description: String, condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
