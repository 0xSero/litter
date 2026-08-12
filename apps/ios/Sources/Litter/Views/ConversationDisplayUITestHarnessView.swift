import SwiftUI

#if DEBUG
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

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-conversation-display")
    }

    static var opensSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-open-settings")
    }

    var body: some View {
        NavigationStack {
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
                        items: Self.seedItems,
                        isLive: false,
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
                    .accessibilityIdentifier("conversationDisplayHarness.timeline")
                }
                .padding(16)
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
                .environment(themeManager)
        }
        .onAppear {
            applyLaunchDisplayModes()
            if Self.opensSettingsOnLaunch {
                DispatchQueue.main.async {
                    showSettings = true
                }
            }
        }
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

    private static let seedItems: [ConversationItem] = [
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
