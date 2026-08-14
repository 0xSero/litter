import SwiftUI
import os
import Foundation

#if DEBUG
/// PERF-0a render-isolation counters (DEBUG-only). The four production
/// signpost sites call `trace(site, rowID:)` so the DEBUG harness can assert
/// which surfaces/rows re-evaluate under a deterministic delta.
/// Preserve through PERF-1.
@MainActor
enum RenderIsolationCounters {
    enum Site {
        static let timelineRow = "TimelineRow"
        static let sessionRow = "SessionRow"
        static let header = "Header"
        static let homeCard = "HomeCard"
    }

    static let signpostLog = OSLog(
        subsystem: "com.sigkitten.litter",
        category: "RenderIsolation"
    )

    private(set) static var totals: [String: Int] = [:]
    private(set) static var rows: [String: [String: Int]] = [:]
    private(set) static var epoch: Int = 0

    @discardableResult
    static func trace(_ site: String, rowID: String? = nil) -> Int {
        os_signpost(.event, log: signpostLog, name: "BodyEval", "%{public}s|%{public}s", site, rowID ?? "-")
        totals[site, default: 0] += 1
        if let rowID {
            rows[site, default: [:]][rowID, default: 0] += 1
        }
        return totals[site] ?? 0
    }

    static func reset() {
        totals = [:]
        rows = [:]
        epoch += 1
    }

    static var json: String {
        let payload: [String: Any] = ["epoch": epoch, "totals": totals, "rows": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct ConversationDisplayUITestHarnessView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage(ConversationDisplayPreferenceKey.reasoning) private var reasoningDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.commands) private var commandDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.tools) private var toolDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @State private var showSettings = false
    @State private var composerText = ""
    @State private var composerFocused = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var showAttachMenu = false
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var fixtureItems: [ConversationItem] = []
    @State private var fixtureSessions: [AppSessionSummary] = []
    @State private var fixturesLoaded = false
    @State private var publishedCountersJSON = "{}"
    @State private var navigationPath: [String] = []

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-conversation-display")
    }

    static var opensSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-open-settings")
    }

    private static var fixtureTimestamp: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    private static var isMidhistoryScenario: Bool {
        (ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_SCENARIO"] ?? "") == "midhistory-tool-result"
    }

    var body: some View {
        let environment = ProcessInfo.processInfo.environment
        let sessionCount = Self.sessionCount(from: environment)
        NavigationStack(path: $navigationPath) {
            if sessionCount > 0 {
                sessionsRoot
                    .navigationDestination(for: String.self) { _ in
                        conversationDetail
                    }
            } else {
                conversationDetail
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
                .environment(themeManager)
        }
        .onAppear {
            applyLaunchDisplayModes()
            if !fixturesLoaded {
                fixtureItems = Self.generatedItems(environment: environment)
                fixtureSessions = Self.generatedSessionSummaries(environment: environment)
                fixturesLoaded = true
            }
            if Self.opensSettingsOnLaunch {
                DispatchQueue.main.async {
                    showSettings = true
                }
            }
        }
    }

    private var sessionsRoot: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(fixtureSessions.enumerated()), id: \.element.key) { index, session in
                    SessionRowView(
                        thread: session,
                        isActive: false,
                        parent: nil,
                        hasTurnActive: false,
                        updatedAtText: "2d ago",
                        isResuming: false,
                        depth: 0,
                        hasChildren: false,
                        isCollapsed: false,
                        lineage: nil,
                        onToggleNode: {},
                        onSelectSession: {
                            navigationPath.append(session.key.threadId)
                        }
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("harness.sessionRow-\(index)")
                }
            }
            .accessibilityIdentifier("harness.sessionsList")
        }
        .navigationTitle("Sessions Harness")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { harnessControls }
    }

    private var conversationDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Conversation Display Test")
                    .litterFont(.title3, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                    .accessibilityIdentifier("conversationDisplayHarness.title")

                ConversationComposerEntryRowView(
                    showAttachMenu: $showAttachMenu,
                    inputText: $composerText,
                    isComposerFocused: $composerFocused,
                    composerSelectionRange: $composerSelection,
                    voiceManager: voiceManager,
                    isTurnActive: false,
                    hasAttachment: false,
                    modelLabel: ProcessInfo.processInfo.environment["CODEXIOS_UI_TEST_MODEL_LABEL"] ?? "GPT-5",
                    reasoningLabel: "high",
                    collaborationMode: .default,
                    showModeChip: true,
                    onPasteImage: { _ in },
                    onSendText: {},
                    onStopRecording: {},
                    onStartRecording: {},
                    onInterrupt: {}
                )

                ConversationTurnTimeline(
                    items: fixtureItems,
                    isLive: Self.isMidhistoryScenario,
                    serverId: "ui-test-server",
                    originThreadId: nil,
                    agentDirectoryVersion: 0,
                    messageActionsDisabled: true,
                    onStreamingSnapshotRendered: nil,
                    onLiveContentLayoutChanged: nil,
                    resolveTargetLabel: { _ in nil },
                    onWidgetPrompt: { _ in },
                    onEditUserItem: { _ in },
                    onForkFromUserItem: { _ in }
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversationDisplayHarness.timeline")
            }
            .padding(16)
        }
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .overlay(alignment: .bottom) { harnessControls }
        .navigationTitle("Display Harness")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("conversationDisplayHarness.settingsButton")
            }
        }
    }

    private var harnessControls: some View {
        HStack(spacing: 4) {
            Text("render counters")
                .font(.system(size: 1))
                .accessibilityIdentifier("harness.bodyEvalCounts")
                .accessibilityValue(Text(publishedCountersJSON))

            Button("reset") {
                RenderIsolationCounters.reset()
                publishedCountersJSON = "{}"
            }
            .accessibilityIdentifier("harness.resetCounters")
            .font(.system(size: 8))
            .frame(width: 20, height: 20)

            Button("publish") {
                publishedCountersJSON = RenderIsolationCounters.json
            }
            .accessibilityIdentifier("harness.publishCounters")
            .font(.system(size: 8))
            .frame(width: 20, height: 20)

            Button("stream") {
                streamBatch()
            }
            .accessibilityIdentifier("harness.streamBatch")
            .font(.system(size: 8))
            .frame(width: 20, height: 20)

            Button("tool") {
                completeMidhistoryTool()
            }
            .accessibilityIdentifier("harness.completeMidhistoryTool")
            .font(.system(size: 8))
            .frame(width: 20, height: 20)
        }
        .padding(4)
        .background(LitterTheme.surface.opacity(0.4))
    }

    private func streamBatch() {
        guard let idx = fixtureItems.lastIndex(where: \.isAssistantItem) else { return }
        guard case .assistant(var data) = fixtureItems[idx].content else { return }
        for i in 0..<20 {
            data.text += " delta-\(i)"
        }
        fixtureItems[idx].content = .assistant(data)
    }

    private func completeMidhistoryTool() {
        guard let idx = fixtureItems.firstIndex(where: { $0.id == "mh-tool-K" }) else { return }
        guard case .commandExecution(var data) = fixtureItems[idx].content else { return }
        data.status = .completed
        data.output = "ui-test tool result K"
        data.exitCode = 0
        fixtureItems[idx].content = .commandExecution(data)
    }

    private func applyLaunchDisplayModes() {
        let environment = ProcessInfo.processInfo.environment
        reasoningDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_REASONING_MODE"])
        commandDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_COMMAND_MODE"])
        toolDisplayMode = validatedMode(environment["CODEXIOS_UI_TEST_TOOL_MODE"])
    }

    private func validatedMode(_ rawValue: String?) -> String {
        guard let rawValue,
              ConversationDetailDisplayMode(rawValue: rawValue) != nil else {
            return ConversationDetailDisplayMode.collapsed.rawValue
        }
        return rawValue
    }

    // MARK: - Deterministic fixture generation (no Date()/random)

    private static func sessionCount(from environment: [String: String]) -> Int {
        guard let raw = environment["CODEXIOS_UI_TEST_SESSION_COUNT"],
              let count = Int(raw), count > 0 else {
            return 0
        }
        return count
    }

    /// ITEM_COUNT applies only when explicitly set; unset env returns the
    /// canonical six items byte-for-byte. Scenario overrides everything.
    private static func generatedItems(environment: [String: String]) -> [ConversationItem] {
        let scenario = environment["CODEXIOS_UI_TEST_SCENARIO"] ?? ""
        let itemCount = environment["CODEXIOS_UI_TEST_ITEM_COUNT"].flatMap { Int($0) }
        if scenario == "midhistory-tool-result" {
            guard let count = itemCount, count > 7 else {
                return midhistoryItems()
            }
            let canonical = midhistoryItems()
            let pattern = (0..<(count - canonical.count)).map { patternItem(at: $0) }
            return pattern + canonical
        }
        guard let count = itemCount, count > 0 else {
            return canonicalSeedItems
        }
        return (0..<count).map { patternItem(at: $0) }
    }

    private static func generatedSessionSummaries(environment: [String: String]) -> [AppSessionSummary] {
        let count = sessionCount(from: environment)
        guard count > 0 else { return [] }
        var sessions: [AppSessionSummary] = []
        sessions.reserveCapacity(count)
        for i in 0..<count {
            sessions.append(sessionSummary(at: i))
        }
        return sessions
    }

    private static func sessionSummary(at index: Int) -> AppSessionSummary {
        let threadId = "ui-test-session-\(index)"
        return AppSessionSummary(
            key: ThreadKey(serverId: "ui-test-server", threadId: threadId),
            agentRuntimeKind: .codex,
            serverDisplayName: "UI Test Server",
            serverHost: "ui-test.local",
            title: "UI Test Session \(index)",
            preview: "ui-test preview \(index)",
            cwd: "/tmp/ui-test-\(index)",
            model: "",
            modelProvider: "",
            parentThreadId: nil,
            forkedFromId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: threadId,
            agentStatus: .unknown,
            updatedAt: Int64(1_700_000_000 - index),
            hasActiveTurn: false,
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

    /// Mid-history tool-result scenario (corpus-derived shapes, deterministic).
    /// T1 done, T2 done + tool `mh-tool-K` running, T3 streaming. Corpus:
    /// `…/v2.0.1/perf-0a/corpus/05-tool-file-order.json`
    /// (sha256 c126251a51590d29b0c39530e5899d27a63160ef0d31a87ea0feff2b4c93556a).
    private static func midhistoryItems() -> [ConversationItem] {
        let t = fixtureTimestamp
        return [
            ConversationItem(id: "mh-u1", content: .user(ConversationUserMessageData(text: "MIDHISTORY_USER_T1", images: [])), timestamp: t, isFromUserTurnBoundary: true),
            ConversationItem(id: "mh-a1", content: .assistant(ConversationAssistantMessageData(text: "MIDHISTORY_ASSISTANT_T1", agentNickname: nil, agentRole: nil, phase: nil)), timestamp: t),
            ConversationItem(id: "mh-u2", content: .user(ConversationUserMessageData(text: "MIDHISTORY_USER_T2", images: [])), timestamp: t, isFromUserTurnBoundary: true),
            ConversationItem(id: "mh-a2", content: .assistant(ConversationAssistantMessageData(text: "MIDHISTORY_ASSISTANT_T2", agentNickname: nil, agentRole: nil, phase: nil)), timestamp: t),
            ConversationItem(id: "mh-tool-K", content: .commandExecution(ConversationCommandExecutionData(command: "ui-test command K", cwd: "/tmp", status: .inProgress, output: nil, exitCode: nil, durationMs: nil, processId: nil, actions: [])), timestamp: t),
            ConversationItem(id: "mh-u3", content: .user(ConversationUserMessageData(text: "MIDHISTORY_USER_T3", images: [])), timestamp: t, isFromUserTurnBoundary: true),
            ConversationItem(id: "mh-a3", content: .assistant(ConversationAssistantMessageData(text: "MIDHISTORY_ASSISTANT_T3_STREAM", agentNickname: nil, agentRole: nil, phase: nil)), timestamp: t)
        ]
    }

    /// Deterministic pattern item for large fixtures (generic id `ui-test-item-{i}`).
    private static func patternItem(at index: Int) -> ConversationItem {
        let t = fixtureTimestamp
        switch index % 6 {
        case 0:
            return ConversationItem(id: "ui-test-item-\(index)", content: .user(ConversationUserMessageData(text: "UITEST_PATTERN_USER_\(index)", images: [])), timestamp: t, isFromUserTurnBoundary: true)
        case 1:
            return ConversationItem(id: "ui-test-item-\(index)", content: .assistant(ConversationAssistantMessageData(text: "UITEST_PATTERN_ASSISTANT_\(index)", agentNickname: nil, agentRole: nil, phase: nil)), timestamp: t)
        case 2:
            return ConversationItem(id: "ui-test-item-\(index)", content: .reasoning(ConversationReasoningData(summary: ["UITEST_PATTERN_REASONING_\(index)"], content: [])), timestamp: t)
        case 3:
            return ConversationItem(id: "ui-test-item-\(index)", content: .commandExecution(ConversationCommandExecutionData(command: "printf UITEST_PATTERN_COMMAND_\(index)", cwd: "/tmp", status: .completed, output: "UITEST_PATTERN_OUTPUT_\(index)", exitCode: 0, durationMs: 25, processId: nil, actions: [])), timestamp: t)
        case 4:
            return ConversationItem(id: "ui-test-item-\(index)", content: .mcpToolCall(ConversationMcpToolCallData(server: "uiTest", tool: "fixtureTool\(index)", status: .completed, durationMs: 30, argumentsJSON: "{\"fixture\":\"UITEST_PATTERN_TOOL_\(index)\"}", contentSummary: "UITEST_PATTERN_TOOL_DETAIL_\(index)", structuredContentJSON: nil, rawOutputJSON: nil, errorMessage: nil, progressMessages: [], computerUse: nil)), timestamp: t)
        default:
            return ConversationItem(id: "ui-test-item-\(index)", content: .commandExecution(ConversationCommandExecutionData(command: "sleep 10 && echo UITEST_PATTERN_LIVE_\(index)", cwd: "/tmp", status: .inProgress, output: "UITEST_PATTERN_LIVE_OUTPUT_\(index)", exitCode: nil, durationMs: nil, processId: nil, actions: [])), timestamp: t)
        }
    }

    /// Canonical six-item seed — byte-for-byte identical to the pre-PERF-0a
    /// `seedItems` (existing display UITests depend on the exact items).
    private static let canonicalSeedItems: [ConversationItem] = [
        ConversationItem(
            id: "ui-test-user",
            content: .user(ConversationUserMessageData(
                text: "UITEST_USER_MESSAGE",
                images: []
            ))
        ),
        ConversationItem(
            id: "ui-test-assistant",
            content: .assistant(ConversationAssistantMessageData(
                text: """
                ## UITEST_ASSISTANT_MESSAGE

                Here is a short answer with `inline code`, readable prose, and a second paragraph so typography and spacing are visible in screenshots.

                ```swift
                let greeting = "UITEST_CODE_BLOCK"
                print(greeting)
                ```
                """,
                agentNickname: nil,
                agentRole: nil,
                phase: nil
            ))
        ),
        ConversationItem(
            id: "ui-test-reasoning",
            content: .reasoning(ConversationReasoningData(
                summary: ["UITEST_REASONING_DETAIL"],
                content: []
            ))
        ),
        ConversationItem(
            id: "ui-test-command",
            content: .commandExecution(ConversationCommandExecutionData(
                command: "printf UITEST_COMMAND_HEADER",
                cwd: "/tmp",
                status: .completed,
                output: "UITEST_COMMAND_OUTPUT",
                exitCode: 0,
                durationMs: 25,
                processId: nil,
                actions: []
            ))
        ),
        ConversationItem(
            id: "ui-test-tool",
            content: .mcpToolCall(ConversationMcpToolCallData(
                server: "uiTest",
                tool: "fixtureTool",
                status: .completed,
                durationMs: 30,
                argumentsJSON: "{\"fixture\":\"UITEST_TOOL_ARGUMENT\"}",
                contentSummary: "UITEST_TOOL_DETAIL",
                structuredContentJSON: nil,
                rawOutputJSON: nil,
                errorMessage: nil,
                progressMessages: [],
                computerUse: nil
            ))
        ),
        ConversationItem(
            id: "ui-test-live-command",
            content: .commandExecution(ConversationCommandExecutionData(
                command: "sleep 10 && echo UITEST_LIVE_COMMAND_HEADER",
                cwd: "/tmp",
                status: .inProgress,
                output: "UITEST_LIVE_COMMAND_OUTPUT",
                exitCode: nil,
                durationMs: nil,
                processId: nil,
                actions: []
            ))
        )
    ]
}
#endif
