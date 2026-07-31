import XCTest
@testable import Litter

@MainActor
final class RunningTurnSnapshotTests: XCTestCase {

    // MARK: - Codable round-trip

    func testRunningTurnSnapshotRoundTripsThroughJsonEncoder() throws {
        let snapshot = RunningTurnSnapshot(
            taskId: "macbook:t1",
            title: "fix auth token expiry",
            serverName: "macbook-pro",
            model: "gpt-5-codex",
            startedAtMs: 1_700_000_000_000,
            lastTool: "edit_file src/auth.go"
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RunningTurnSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
    }

    func testRunningTurnSnapshotEncodesOptionalsAsNullWhenAbsent() throws {
        let snapshot = RunningTurnSnapshot(
            taskId: "studio:t9",
            title: "refactor session store",
            serverName: "studio",
            model: nil,
            startedAtMs: 1,
            lastTool: nil
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RunningTurnSnapshot.self, from: data)

        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.lastTool)
        XCTAssertEqual(decoded.taskId, "studio:t9")
    }

    // MARK: - Staleness

    func testRunningTurnSnapshotIsStaleAfter30Minutes() {
        let startedAtMs: Int64 = 1_700_000_000_000
        let snapshot = RunningTurnSnapshot(
            taskId: "x",
            title: "x",
            serverName: "x",
            model: nil,
            startedAtMs: startedAtMs,
            lastTool: nil
        )
        let startedDate = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)

        XCTAssertFalse(RunningTurnStore.isStale(snapshot, now: startedDate.addingTimeInterval(60)))
        XCTAssertFalse(RunningTurnStore.isStale(snapshot, now: startedDate.addingTimeInterval(29 * 60)))
        XCTAssertTrue(RunningTurnStore.isStale(snapshot, now: startedDate.addingTimeInterval(31 * 60)))
    }

    // MARK: - Projection from AppThreadSnapshot

    func testMakeRunningTurnSnapshotUsesSessionSummaryTitleAndToolLabel() {
        let key = ThreadKey(serverId: "macbook", threadId: "t1")
        let server = makeServer(id: "macbook", displayName: "MacBook Pro")
        let summary = makeSummary(
            key: key,
            serverDisplayName: "MacBook Pro",
            title: "Fix auth",
            lastToolLabel: "edit_file src/auth.go"
        )
        let thread = makeThread(key: key, model: "gpt-5-codex")
        let record = makeRecord(servers: [server], summaries: [summary], threads: [thread])

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = TurnLiveActivityController.makeRunningTurnSnapshot(
            for: thread,
            startDate: started,
            snapshot: record
        )

        XCTAssertEqual(payload.taskId, "macbook:t1")
        XCTAssertEqual(payload.title, "Fix auth")
        XCTAssertEqual(payload.serverName, "MacBook Pro")
        XCTAssertEqual(payload.model, "gpt-5-codex")
        XCTAssertEqual(payload.startedAtMs, Int64(1_700_000_000 * 1000))
        XCTAssertEqual(payload.lastTool, "edit_file src/auth.go")
    }

    func testMakeRunningTurnSnapshotFallsBackWhenServerOrSummaryMissing() {
        let key = ThreadKey(serverId: "studio", threadId: "t2")
        let thread = makeThread(key: key, model: "")
        let record = makeRecord(servers: [], summaries: [], threads: [thread])

        let payload = TurnLiveActivityController.makeRunningTurnSnapshot(
            for: thread,
            startDate: Date(timeIntervalSince1970: 100),
            snapshot: record
        )

        XCTAssertEqual(payload.serverName, "studio")
        XCTAssertNil(payload.model)
        XCTAssertNil(payload.lastTool)
        // Default title fallback when summary/preview are empty.
        XCTAssertEqual(payload.title, "Untitled session")
    }

    // MARK: - Factories

    private func makeServer(id: String, displayName: String) -> AppServerSnapshot {
        AppServerSnapshot(
            serverId: id,
            displayName: displayName,
            host: "\(id).local",
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
            usageStats: nil,
            codexVersion: nil
        )
    }

    private func makeSummary(
        key: ThreadKey,
        serverDisplayName: String,
        title: String,
        lastToolLabel: String?
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: key,
            agentRuntimeKind: .codex,
            serverDisplayName: serverDisplayName,
            serverHost: "\(key.serverId).local",
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
            updatedAt: 100,
            hasActiveTurn: true,
            isResumed: false,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: nil,
            lastResponseTurnId: nil,
            lastUserMessage: nil,
            lastToolLabel: lastToolLabel,
            recentToolLog: [],
            lastTurnStartMs: nil,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil,
            goal: nil
        )
    }

    private func makeThread(key: ThreadKey, model: String) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: key,
            info: ThreadInfo(
                id: key.threadId,
                title: nil,
                model: model.isEmpty ? nil : model,
                status: .idle,
                preview: nil,
                cwd: "/tmp",
                path: nil,
                modelProvider: nil,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: nil,
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: nil
            ),
            agentRuntimeKind: .codex,
            collaborationMode: .default,
            model: model.isEmpty ? nil : model,
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

    private func makeRecord(
        servers: [AppServerSnapshot],
        summaries: [AppSessionSummary],
        threads: [AppThreadSnapshot]
    ) -> AppSnapshotRecord {
        AppSnapshotRecord(
            servers: servers,
            threads: threads,
            sessionSummaries: summaries,
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
