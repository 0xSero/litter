import Foundation

#if DEBUG
import SwiftUI

enum LitterPreviewData {
    static let sampleCwd = "/Users/sigkitten/dev/codex-ios"

    static let sampleServer = DiscoveredServer(
        id: "preview-remote",
        name: "Newspaper Solver",
        hostname: "192.168.1.228",
        port: 8390,
        codexPorts: [8390, 9234],
        source: .manual,
        hasCodexServer: true,
        wakeMAC: "12:18:c7:14:74:e3",
        sshPortForwardingEnabled: true,
        preferredConnectionMode: .directCodex,
        preferredCodexPort: 8390
    )

    static let sampleSSHServer = DiscoveredServer(
        id: "preview-ssh",
        name: "Build Mac mini",
        hostname: "mac-mini.local",
        port: nil,
        sshPort: 22,
        source: .ssh,
        hasCodexServer: false,
        wakeMAC: "aa:bb:cc:dd:ee:ff",
        sshPortForwardingEnabled: true,
        preferredConnectionMode: .ssh
    )

    static let sampleModels: [ModelInfo] = [
        ModelInfo(
            id: "gpt-5.4",
            model: "gpt-5.4",
            upgrade: nil, upgradeModel: nil, upgradeCopy: nil, modelLink: nil, migrationMarkdown: nil, availabilityNuxMessage: nil,
            displayName: "gpt-5.4",
            description: "Balanced flagship model",
            hidden: false,
            supportedReasoningEfforts: [
                ReasoningEffortOption(reasoningEffort: .medium, description: "Balanced"),
                ReasoningEffortOption(reasoningEffort: .high, description: "Deeper reasoning"),
                ReasoningEffortOption(reasoningEffort: .xHigh, description: "Maximum reasoning")
            ],
            defaultReasoningEffort: .high,
            inputModalities: [.text, .image],
            supportsPersonality: true,
            isDefault: true,
            agentRuntimeKind: "codex"
        ),
        ModelInfo(
            id: "gpt-5.4-mini",
            model: "gpt-5.4-mini",
            upgrade: nil, upgradeModel: nil, upgradeCopy: nil, modelLink: nil, migrationMarkdown: nil, availabilityNuxMessage: nil,
            displayName: "gpt-5.4-mini",
            description: "Faster lower-cost model",
            hidden: false,
            supportedReasoningEfforts: [
                ReasoningEffortOption(reasoningEffort: .low, description: "Fast"),
                ReasoningEffortOption(reasoningEffort: .medium, description: "Balanced")
            ],
            defaultReasoningEffort: .medium,
            inputModalities: [.text],
            supportsPersonality: true,
            isDefault: false,
            agentRuntimeKind: "codex"
        )
    ]

    static let sampleMessages: [ChatMessage] = [
        ChatMessage(
            role: .user,
            text: "why is repo_q1 pinned while patch repair is maxed out?",
            sourceTurnId: "turn-1",
            sourceTurnIndex: 0,
            isFromUserTurnBoundary: true
        ),
        ChatMessage(
            role: .assistant,
            text: """
            I found the relevant scheduler gate. `repo_jobs_q1` is being held behind the repo-fetch branch, so the patch lane keeps draining while clone/fetch never gets enqueued.

            Next step is to trace the worker split against `patch_repair` and `repo_jobs` thresholds.
            """,
            agentNickname: "Latest",
            agentRole: "explorer"
        ),
        ChatMessage(
            role: .system,
            text: """
            ### Command Execution
            status: completed
            duration: 1.2s

            Command
            ```bash
            rg -n "repo_jobs|patch_repair" scheduler.py
            ```

            Output
            ```text
            42: if repo_jobs_q1 < 100000 { ... }
            ```
            """
        )
    ]

    static let sampleToolCallModel = ToolCallCardModel(
        kind: .commandExecution,
        title: "Command Execution",
        summary: "rg scheduler gate completed",
        status: .completed,
        duration: "1.2s",
        sections: [
            .kv(label: "Metadata", entries: [
                ToolCallKeyValue(key: "Status", value: "completed"),
                ToolCallKeyValue(key: "Directory", value: sampleCwd)
            ]),
            .code(
                label: "Command",
                language: "bash",
                content: #"rg -n "repo_jobs|patch_repair" scheduler.py"#
            ),
            .text(
                label: "Result",
                content: "Found the repo gate that prevents clone/fetch work from being scheduled."
            )
        ]
    )

    static var longConversation: [ChatMessage] {
        var msgs: [ChatMessage] = []
        let questions = [
            "How does the scheduler handle repo_jobs_q1 when patch repair is saturated?",
            "Can you trace the worker split against patch_repair thresholds?",
            "What happens when clone/fetch never gets enqueued?",
            "Is repo-first mode actually enabled in the current config?",
            "Show me the fairness weights for the repo lane.",
            "Why does the gate hold at 100k instead of scaling dynamically?",
            "Can we add a priority override for time-sensitive repo fetches?",
            "What are the queue metrics from the last hour?",
            "How do we test the scheduler changes without affecting production?",
            "Summarize the full patch repair bottleneck analysis.",
            "What is the expected throughput after the fairness fix?",
            "Can you write a migration plan for the scheduler changes?",
        ]
        let answers = [
            "The scheduler gate at line 42 checks `repo_jobs_q1` against a threshold of 100,000. When patch repair is saturated, the gate holds all repo-fetch work behind the branch queue.\n\n```python\nif repo_jobs_q1 < 100000:\n    enqueue(patch_repair_lane)\nelse:\n    defer_to_next_cycle()\n```\n\nThis means clone/fetch never gets scheduled while the patch lane is draining.",
            "The worker split is 70/30 in favor of patch_repair. The `repo_jobs` threshold is checked before any repo work is enqueued, so the split only applies after the gate opens.",
            "When clone/fetch is starved, the repo queue grows unbounded. Eventually the OOM killer steps in, which is how we first noticed the issue in production.",
            "Not from the current scheduler state. The gate is configured but the repo-first flag was never flipped in the deploy config. It's still set to `false`.",
            "Current fairness weights:\n\n```yaml\npatch_repair: 0.7\nrepo_fetch: 0.2\nclone: 0.1\n```\n\nThese haven't been updated since the initial rollout.",
            "The 100k threshold was chosen based on early benchmarks when repo sizes were smaller. With current repo sizes averaging 2.3GB, the threshold should be closer to 500k to avoid premature gating.",
            "Yes, we can add a `priority_override` field to the job struct. When set, it bypasses the gate check and goes directly to the front of the queue.\n\n```python\nif job.priority_override:\n    fast_enqueue(job)\n    return\n```",
            "Queue metrics for the last hour show patch_repair at 94% utilization, repo_fetch at 12%, and clone at 3%. The imbalance is clear.",
            "Best approach is a shadow deployment: run the new scheduler in read-only mode alongside production, compare decisions without actually routing traffic. We did this for the last major scheduler change.",
            "The bottleneck stems from a hard-coded gate threshold that hasn't scaled with repo sizes. The fix involves dynamic thresholds based on queue depth, fairness weights, and a priority override system.",
            "After the fairness fix, we expect repo_fetch utilization to rise from 12% to around 45%, with patch_repair dropping to 60%. Overall throughput should increase by roughly 30%.",
            "Migration plan:\n1. Deploy dynamic threshold config (no behavior change)\n2. Enable shadow mode for new scheduler\n3. Compare metrics for 24h\n4. Gradual rollout: 10% -> 50% -> 100%\n5. Monitor for 48h before removing old code path",
        ]
        for i in 0..<questions.count {
            msgs.append(ChatMessage(
                role: .user,
                text: questions[i],
                sourceTurnId: "turn-\(i * 2)",
                sourceTurnIndex: 0,
                isFromUserTurnBoundary: true
            ))
            msgs.append(ChatMessage(
                role: .assistant,
                text: answers[i]
            ))
        }
        return msgs
    }

    @MainActor
    static func makeAppState(
        selectedModel: String = sampleModels[0].id,
        reasoningEffort: String = "xhigh",
        currentCwd: String = sampleCwd
    ) -> AppState {
        let state = AppState()
        state.selectedModel = selectedModel
        state.reasoningEffort = reasoningEffort
        state.currentCwd = currentCwd
        return state
    }

    @MainActor
    static func makeAppModel(snapshot: AppSnapshotRecord) -> AppModel {
        let model = AppModel()
        model.applySnapshot(snapshot)
        return model
    }

    @MainActor
    static func makeConversationAppModel(messages: [ChatMessage] = sampleMessages) -> AppModel {
        makeAppModel(snapshot: makeConversationSnapshot(messages: messages))
    }

    @MainActor
    static func makeDiscoveryAppModel() -> AppModel {
        makeAppModel(snapshot: makeSnapshot(threads: [], activeThread: nil))
    }

    @MainActor
    static func makeSidebarAppModel() -> AppModel {
        let primaryThread = makeThreadSnapshot(
            threadId: "thread-preview-main",
            preview: "Map the patch repair bottleneck in repo scheduler",
            cwd: sampleCwd,
            model: sampleModels[0].id,
            modelProvider: sampleModels[0].displayName,
            reasoningEffort: "xhigh",
            status: .idle,
            messages: sampleMessages
        )

        let forkThread = makeThreadSnapshot(
            threadId: "thread-preview-fork",
            preview: "Check whether repo-first mode is enabled",
            cwd: sampleCwd + "/shared",
            model: sampleModels[1].id,
            modelProvider: sampleModels[1].displayName,
            reasoningEffort: "medium",
            status: .idle,
            messages: [
                ChatMessage(role: .user, text: "is repo-first mode actually enabled?"),
                ChatMessage(role: .assistant, text: "Not from the current scheduler state. The gate is configured but starved.")
            ],
            parentThreadId: "thread-preview-main",
            agentNickname: "Latest",
            agentRole: "explorer",
            updatedAt: Date().addingTimeInterval(-1800)
        )

        let archivedThread = makeThreadSnapshot(
            threadId: "thread-preview-older",
            preview: "Summarize queue metrics from the last hour",
            cwd: sampleCwd,
            model: sampleModels[0].id,
            modelProvider: sampleModels[0].displayName,
            reasoningEffort: "high",
            status: .idle,
            messages: [ChatMessage(role: .assistant, text: "Queue metrics look stable except for repo_jobs_q1.")],
            updatedAt: Date().addingTimeInterval(-7200)
        )

        return makeAppModel(
            snapshot: makeSnapshot(
                threads: [primaryThread, forkThread, archivedThread],
                activeThread: primaryThread.key
            )
        )
    }

    @MainActor
    static func makeConversationSnapshot(messages: [ChatMessage] = sampleMessages) -> AppSnapshotRecord {
        let thread = makeThreadSnapshot(
            threadId: "thread-preview-main",
            preview: "Map the patch repair bottleneck in repo scheduler",
            cwd: sampleCwd,
            model: sampleModels[0].id,
            modelProvider: sampleModels[0].displayName,
            reasoningEffort: "xhigh",
            status: .idle,
            messages: messages
        )
        return makeSnapshot(threads: [thread], activeThread: thread.key)
    }

    @MainActor
    static func makeThreadSnapshot(
        server: DiscoveredServer = sampleServer,
        threadId: String,
        preview: String,
        cwd: String,
        model: String,
        modelProvider: String,
        reasoningEffort: String,
        status: ThreadSummaryStatus,
        messages: [ChatMessage],
        parentThreadId: String? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        updatedAt: Date = Date().addingTimeInterval(-300)
    ) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: ThreadKey(serverId: server.id, threadId: threadId),
            info: ThreadInfo(
                id: threadId,
                title: nil,
                model: model,
                status: status,
                preview: preview,
                cwd: cwd,
                path: cwd + "/.codex/sessions/\(threadId).jsonl",
                modelProvider: modelProvider,
                agentNickname: agentNickname,
                agentRole: agentRole,
                parentThreadId: parentThreadId,
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: Int64(updatedAt.timeIntervalSince1970)
            ),
            agentRuntimeKind: "codex",
            collaborationMode: .`default`,
            model: model,
            reasoningEffort: reasoningEffort,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: makeHydratedConversationItems(from: messages),
            queuedFollowUps: [],
            activeTurnId: status == .active ? "turn-preview" : nil,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: 156_000,
            modelContextWindow: 200_000,
            rateLimits: nil,
            realtimeSessionId: nil,
            goal: nil,
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
    }

    @MainActor
    static func makeSnapshot(
        threads: [AppThreadSnapshot],
        activeThread: ThreadKey?
    ) -> AppSnapshotRecord {
        let server = AppServerSnapshot(
            serverId: sampleServer.id,
            displayName: sampleServer.name,
            host: sampleServer.hostname,
            port: UInt16(sampleServer.port ?? 8390),
            wakeMac: sampleServer.wakeMAC,
            isLocal: false,
            health: .connected,
            transportState: .connected,
            capabilities: AppServerCapabilities(
                canUseTransportActions: true,
                canBrowseDirectories: true,
                canStartThreads: true,
                canResumeThreads: true,
                supportsTurnPagination: true
            ),
            account: .chatgpt(email: "builder@example.com", planType: .plus),
            requiresOpenaiAuth: false,
            rateLimits: nil,
            rateLimitsByRuntime: [],
            availableModels: sampleModels,
            agentRuntimes: [AgentRuntimeInfo(kind: "codex", name: "codex", displayName: "Codex", available: true)],
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
                forkedFromId: thread.info.forkedFromId,
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
                isFork: thread.info.forkedFromId != nil,
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
            activeThread: activeThread,
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

    private static func makeHydratedConversationItems(from messages: [ChatMessage]) -> [HydratedConversationItem] {
        messages.map { message in
            let content: HydratedConversationItemContent
            switch message.role {
            case .user:
                content = .user(
                    HydratedUserMessageData(
                        text: message.text,
                        imageDataUris: []
                    )
                )
            case .assistant:
                content = .assistant(
                    HydratedAssistantMessageData(
                        text: message.text,
                        agentNickname: message.agentNickname,
                        agentRole: message.agentRole,
                        phase: nil
                    )
                )
            case .system:
                content = .note(HydratedNoteData(title: "System", body: message.text))
            }

            return HydratedConversationItem(
                id: message.id.uuidString,
                content: content,
                sourceTurnId: message.sourceTurnId,
                sourceTurnIndex: message.sourceTurnIndex.map(UInt32.init),
                timestamp: message.timestamp.timeIntervalSince1970,
                isFromUserTurnBoundary: message.isFromUserTurnBoundary
            )
        }
    }

}

@MainActor
struct LitterPreviewScene<Content: View>: View {
    @State private var appModel: AppModel
    @State private var appState: AppState
    // `.shared` is defined identically on both the iOS and Catalyst
    // versions of `VoiceRuntimeController`. Calling the synthesized
    // init directly (`VoiceRuntimeController()`) trips a scope-
    // resolution hiccup on Catalyst 26 + Swift 6 around the
    // `@MainActor @Observable` class — the singleton is the safe path
    // and gives us the same environment object.
    @State private var voiceRuntime = VoiceRuntimeController.shared

    private let includeBackground: Bool
    private let content: Content

    init(
        appModel: AppModel? = nil,
        appState: AppState? = nil,
        includeBackground: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        _appModel = State(initialValue: appModel ?? LitterPreviewData.makeConversationAppModel())
        _appState = State(initialValue: appState ?? LitterPreviewData.makeAppState())
        self.includeBackground = includeBackground
        self.content = content()
    }

    var body: some View {
        ZStack {
            if includeBackground {
                LitterTheme.backgroundGradient.ignoresSafeArea()
            }
            content
        }
        .environment(appModel)
        .environment(voiceRuntime)
        .environment(appState)
        .environment(ThemeManager.shared)
        .environment(WallpaperManager.shared)
    }
}
#endif
