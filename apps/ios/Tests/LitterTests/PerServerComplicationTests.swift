import XCTest
import WatchConnectivity
@testable import Litter

/// Tests for the per-server complication slice + `servers.v1` picker
/// payload (Task #7). The shared types live in the LitterWatchComplications
/// target and are also compiled into Litter via `project.yml` so the bridge
/// writer and the widget reader speak the same shape.
@MainActor
final class PerServerComplicationTests: XCTestCase {

    final class StubTransport: WatchTransport {
        var activationState: WCSessionActivationState
        var isPaired: Bool
        var isWatchAppInstalled: Bool
        var isReachable: Bool
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
        func updateApplicationContext(_ context: [String: Any]) throws {}
    }

    private var savedSnapshot: AppSnapshotRecord?
    private var savedPinnedKeys: [PinnedThreadKey] = []
    private var savedHiddenKeys: [PinnedThreadKey] = []

    override func setUp() {
        super.setUp()
        savedSnapshot = AppModel.shared.snapshot
        savedPinnedKeys = SavedThreadsStore.pinnedKeys()
        savedHiddenKeys = SavedThreadsStore.hiddenKeys()
        for key in savedPinnedKeys { SavedThreadsStore.remove(key) }
        for key in savedHiddenKeys { SavedThreadsStore.unhide(key) }
    }

    override func tearDown() {
        AppModel.shared.applySnapshot(savedSnapshot)
        for key in SavedThreadsStore.pinnedKeys() { SavedThreadsStore.remove(key) }
        for key in SavedThreadsStore.hiddenKeys() { SavedThreadsStore.unhide(key) }
        for key in savedPinnedKeys.reversed() { SavedThreadsStore.add(key) }
        for key in savedHiddenKeys.reversed() { SavedThreadsStore.hide(key) }
        super.tearDown()
    }

    // MARK: - servers.v1 Codable round trip

    func testServerListPayloadRoundTripsThroughJSON() throws {
        let payload = LitterServerListPayload(servers: [
            .init(id: "macbook", displayName: "MacBook Pro"),
            .init(id: "studio", displayName: "Mac Studio"),
        ])

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LitterServerListPayload.self, from: data)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.servers.map(\.id), ["macbook", "studio"])
        XCTAssertEqual(decoded.servers.map(\.displayName), ["MacBook Pro", "Mac Studio"])
    }

    func testServerListPayloadAcceptsEmptyServers() throws {
        let payload = LitterServerListPayload(servers: [])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LitterServerListPayload.self, from: data)
        XCTAssertEqual(decoded.servers, [])
    }

    // MARK: - bridge populates server list

    func testBridgeServerListIncludesAllKnownServersRegardlessOfTransportState() {
        AppModel.shared.applySnapshot(makeRecord(servers: [
            makeServer(id: "macbook", displayName: "MacBook Pro", connected: true),
            makeServer(id: "studio", displayName: "Mac Studio", connected: false),
        ]))

        let bridge = WatchCompanionBridge(transport: StubTransport())
        let payload = bridge.currentServerListPayload()

        // Both servers surface — disconnected included so the picker can
        // reserve a slot for a known-but-currently-offline server.
        XCTAssertEqual(payload.servers.map(\.id), ["macbook", "studio"])
        XCTAssertEqual(payload.servers.map(\.displayName), ["MacBook Pro", "Mac Studio"])
    }

    // MARK: - per-server complication slices

    func testPerServerSnapshotsFilterRunningTaskToOwningServer() throws {
        let now = Date()
        let startedMs = Int64((now.timeIntervalSince1970 - 30) * 1000)
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook"), makeServer(id: "studio")],
            sessionSummaries: [
                // Active turn on macbook only.
                makeSummary(
                    serverId: "macbook",
                    threadId: "t1",
                    updatedAt: Int64(now.timeIntervalSince1970),
                    hasActiveTurn: true,
                    title: "fix auth",
                    lastTurnStartMs: startedMs
                ),
                makeSummary(
                    serverId: "studio",
                    threadId: "t9",
                    updatedAt: Int64(now.timeIntervalSince1970),
                    hasActiveTurn: false
                ),
            ]
        ))

        let bridge = WatchCompanionBridge(transport: StubTransport())
        let map = bridge.currentPerServerComplicationSnapshots()
        XCTAssertEqual(Set(map.keys), ["macbook", "studio"])

        let macbookData = try XCTUnwrap(map["macbook"])
        let macbook = try JSONDecoder().decode(LitterComplicationPayload.self, from: macbookData)
        XCTAssertEqual(macbook.mode, .running)
        XCTAssertEqual(macbook.taskId, "macbook:t1")
        XCTAssertEqual(macbook.lastTurnStartMsEpoch, startedMs)

        let studioData = try XCTUnwrap(map["studio"])
        let studio = try JSONDecoder().decode(LitterComplicationPayload.self, from: studioData)
        // Studio has only an idle thread — running task on macbook must
        // not bleed across the picker boundary.
        XCTAssertEqual(studio.mode, .idle)
        XCTAssertNil(studio.taskId)
    }

    func testPerServerSnapshotsEmitOfflineWhenWatchUnreachable() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubTransport(isPaired: false))
        let map = bridge.currentPerServerComplicationSnapshots()
        let data = try XCTUnwrap(map["macbook"])
        let decoded = try JSONDecoder().decode(LitterComplicationPayload.self, from: data)
        XCTAssertEqual(decoded.mode, .offline)
    }

    func testPerServerSnapshotIdleTitleUsesServerDisplayName() throws {
        AppModel.shared.applySnapshot(makeRecord(
            servers: [makeServer(id: "macbook", displayName: "MacBook Pro")],
            sessionSummaries: []
        ))

        let bridge = WatchCompanionBridge(transport: StubTransport())
        let map = bridge.currentPerServerComplicationSnapshots()
        let data = try XCTUnwrap(map["macbook"])
        let decoded = try JSONDecoder().decode(LitterComplicationPayload.self, from: data)
        XCTAssertEqual(decoded.mode, .idle)
        XCTAssertEqual(decoded.title, "MacBook Pro ready")
    }

    // MARK: - Factories (kept local to avoid coupling with WatchCompanionBridgeTests)

    private func makeServer(
        id: String,
        displayName: String? = nil,
        connected: Bool = true
    ) -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: id,
            displayName: displayName ?? id,
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
        lastTurnStartMs: Int64? = nil
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            agentRuntimeKind: .codex,
            serverDisplayName: serverId,
            serverHost: "\(serverId).local",
            title: title,
            preview: "",
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
            lastResponsePreview: nil,
            lastResponseTurnId: nil,
            lastUserMessage: nil,
            lastToolLabel: nil,
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
        sessionSummaries: [AppSessionSummary] = []
    ) -> AppSnapshotRecord {
        AppSnapshotRecord(
            servers: servers,
            threads: [],
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
}
