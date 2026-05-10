import SwiftUI
import PhotosUI
import UIKit
import os
import HairballUI

private let conversationViewSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationView"
)

enum ConversationStreamingViewportPolicy {
    static func shouldMaintainBottomAnchor(
        isStreaming: Bool,
        isNearBottom: Bool,
        autoFollowStreaming: Bool,
        userIsDraggingScroll: Bool
    ) -> Bool {
        guard !userIsDraggingScroll else { return false }
        if isStreaming {
            return autoFollowStreaming
        }
        return isNearBottom
    }

    static func isStreaming(_ threadStatus: ConversationStatus) -> Bool {
        if case .thinking = threadStatus {
            return true
        }
        return false
    }
}

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    let activeThreadKey: ThreadKey
    let transcript: ConversationTranscriptSnapshot
    let followScrollToken: Int
    let pinnedContextItems: [ConversationItem]
    let composer: ConversationComposerSnapshot
    @Binding var composerInputText: String
    @Binding var composerAttachedImage: UIImage?
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    var onResumeSessions: ((String) -> Void)? = nil
    var minigameOverlay: MinigameOverlayState = .idle
    var onTypingTap: (() -> Void)? = nil
    var onMinigameDismiss: (() -> Void)? = nil
    var onMinigameRetry: (() -> Void)? = nil
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("conversationTextSizeStep") private var conversationTextSizeStep = ConversationTextSize.large.rawValue
    @AppStorage("fastMode") private var fastMode = false
    @State private var messageActionError: String?
    @State private var hasLoggedFirstRender = false
    @State private var localSendScrollToken = 0

    private var items: [ConversationItem] {
        transcript.items
    }

    private var threadStatus: ConversationStatus {
        transcript.threadStatus
    }

    private var agentDirectoryVersion: UInt64 {
        transcript.agentDirectoryVersion
    }

    private var pendingModelOverride: String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var pendingAgentRuntimeKindOverride: AgentRuntimeKind? {
        pendingModelOverride == nil ? nil : appState.selectedAgentRuntimeKind
    }

    private var pendingReasoningOverride: String? {
        let trimmed = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var supportsTurnPagination: Bool {
        appModel.snapshot?
            .serverSnapshot(for: activeThreadKey.serverId)?
            .capabilities
            .supportsTurnPagination ?? false
    }

    var body: some View {
        ConversationMessageList(
            items: items,
            threadStatus: threadStatus,
            threadHasServerData: thread.hasPreviewOrTitle,
            transcriptRenderDigest: transcript.renderDigest,
            followScrollToken: followScrollToken,
            sendScrollToken: localSendScrollToken,
            activeThreadKey: activeThreadKey,
            agentDirectoryVersion: agentDirectoryVersion,
            topInset: thread.isSubagent ? topInset + 32 : topInset,
            olderTurnsCursor: thread.olderTurnsCursor,
            initialTurnsLoaded: thread.initialTurnsLoaded || !supportsTurnPagination,
            textSizeStep: $conversationTextSizeStep,
            resolveTargetLabel: resolveTargetLabel,
            onWidgetPrompt: sendWidgetPrompt,
            onEditUserItem: editMessage,
            onForkFromUserItem: forkFromMessage,
            onOpenConversation: onOpenConversation,
            onLoadOlderTurns: { key in
                Task { await appModel.loadOlderTurns(threadId: key) }
            }
        )
        .overlay(alignment: .bottomLeading) {
            if let onTypingTap,
               minigameOverlay == .idle,
               ExperimentalFeatures.shared.isEnabled(.thinkingMinigame) {
                MinigameLaunchButton(action: onTypingTap)
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .activeThreadKey(activeThreadKey)
        .background { ChatWallpaperBackground(threadKey: activeThreadKey) }
        .overlay(alignment: .top) {
            if thread.isSubagent {
                SubagentBreadcrumbBar(
                    thread: thread,
                    topInset: topInset,
                    onNavigateToParent: {
                        if let parentId = thread.info.parentThreadId {
                            onOpenConversation?(ThreadKey(serverId: thread.serverId, threadId: parentId))
                        }
                    }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            if DebugSettings.shared.enabled {
                ConversationDebugButton(topInset: topInset, activeThreadKey: activeThreadKey)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if minigameOverlay == .idle {
                ConversationBottomChrome(
                    pinnedContextItems: pinnedContextItems,
                    composer: composer,
                    composerInputText: $composerInputText,
                    composerAttachedImage: $composerAttachedImage,
                    onSend: sendMessage,
                    onFileSearch: searchComposerFiles,
                    bottomInset: bottomInset,
                    onOpenConversation: onOpenConversation,
                    onResumeSessions: onResumeSessions
                )
            } else {
                MinigameOverlayView(
                    state: minigameOverlay,
                    onClose: { onMinigameDismiss?() },
                    onRetry: { onMinigameRetry?() }
                )
                .frame(height: UIScreen.main.bounds.height * 0.4)
                .padding(.horizontal, 8)
                .padding(.bottom, max(bottomInset, 8))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Conversation Action Error", isPresented: Binding(
            get: { messageActionError != nil },
            set: { if !$0 { messageActionError = nil } }
        )) {
            Button("OK", role: .cancel) { messageActionError = nil }
        } message: {
            Text(messageActionError ?? "Unknown error")
        }
        .onAppear {
            guard !hasLoggedFirstRender else { return }
            hasLoggedFirstRender = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "ConversationFirstRender")
            appState.hydratePermissions(from: thread)
        }
        .onChange(of: thread) { _, newThread in
            appState.hydratePermissions(from: newThread)
        }
        .task(id: activeThreadKey) {
            await loadInitialTurnsIfNeeded()
        }
        .onChange(of: thread.initialTurnsLoaded) { _, _ in
            Task { await loadInitialTurnsIfNeeded() }
        }
    }

    private func loadInitialTurnsIfNeeded() async {
        guard !thread.initialTurnsLoaded else { return }
        await appModel.loadInitialTurnsIfNeeded(threadId: activeThreadKey)
    }

    private func sendMessage(
        _ text: String,
        attachmentImage: UIImage?,
        skillMentions: [SkillMentionSelection],
        pluginMentions: [PluginMentionSelection]
    ) {
        localSendScrollToken &+= 1
        Task {
            do {
                NSLog(
                    "[ConversationView] sendMessage start server=%@ thread=%@ textLength=%ld",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId,
                    text.count
                )
                let payload = try makeComposerPayload(
                    text: text,
                    attachmentImage: attachmentImage,
                    skillMentions: skillMentions,
                    pluginMentions: pluginMentions
                )
                try await appModel.startTurn(key: activeThreadKey, payload: payload)
                NSLog(
                    "[ConversationView] sendMessage turnStart returned server=%@ thread=%@",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId
                )
            } catch {
                NSLog(
                    "[ConversationView] sendMessage error server=%@ thread=%@ error=%@",
                    activeThreadKey.serverId,
                    activeThreadKey.threadId,
                    error.localizedDescription
                )
                messageActionError = error.localizedDescription
            }
        }
    }

    private func sendWidgetPrompt(_ text: String) {
        guard !text.isEmpty else { return }
        localSendScrollToken &+= 1
        Task {
            do {
                let payload = try makeComposerPayload(
                    text: text,
                    attachmentImage: nil,
                    skillMentions: [],
                    pluginMentions: []
                )
                try await appModel.startTurn(key: activeThreadKey, payload: payload)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func resolveTargetLabel(_ target: String) -> String? {
        appModel.snapshot?.resolvedAgentTargetLabel(for: target, serverId: activeThreadKey.serverId)
    }

    /// Resolve the user-message position in the currently-loaded transcript.
    /// `forkThreadFromMessage` / `editMessage` on the Rust side expect an
    /// index into `thread.items` filtered to user messages — see
    /// `rollback_depth_for_turn` in `mobile_client/thread_projection.rs`.
    /// Recomputing from the live `items` keeps the index correct under
    /// pagination (older turns can shift positions; cached `sourceTurnIndex`
    /// from a prior hydrate would be stale).
    private func loadedUserItemIndex(for item: ConversationItem) -> Int? {
        var idx = 0
        for candidate in items {
            guard candidate.isUserItem else { continue }
            if candidate.id == item.id { return idx }
            idx += 1
        }
        return nil
    }

    private func editMessage(_ item: ConversationItem) {
        Task {
            do {
                guard item.isUserItem, item.isFromUserTurnBoundary,
                      let selectedTurnIndex = loadedUserItemIndex(for: item) else {
                    throw NSError(
                        domain: "Litter",
                        code: 1020,
                        userInfo: [NSLocalizedDescriptionKey: "Only user messages can be edited"]
                    )
                }
                let result = try await appModel.store.editMessage(
                    key: activeThreadKey,
                    selectedTurnIndex: UInt32(selectedTurnIndex)
                )
                appModel.queueComposerPrefill(threadKey: activeThreadKey, text: result)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func forkFromMessage(_ item: ConversationItem) {
        Task {
            do {
                guard item.isUserItem, item.isFromUserTurnBoundary,
                      let selectedTurnIndex = loadedUserItemIndex(for: item) else {
                    throw NSError(
                        domain: "Litter",
                        code: 1016,
                        userInfo: [NSLocalizedDescriptionKey: "Fork from here is only supported for user messages"]
                    )
                }
                let nextKey = try await appModel.store.forkThreadFromMessage(
                    key: activeThreadKey,
                    selectedTurnIndex: UInt32(selectedTurnIndex),
                    params: launchConfig().forkThreadFromMessageRequest(
                        cwdOverride: thread.info.cwd
                    )
                )
                await appModel.refreshThreadSnapshot(key: nextKey)
                let nextCwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !nextCwd.isEmpty {
                    workDir = nextCwd
                    appState.currentCwd = nextCwd
                }
                onOpenConversation?(nextKey)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func searchComposerFiles(_ query: String) async throws -> [FileSearchResult] {
        let searchRoot = workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : workDir
        return try await appModel.client.searchFiles(
            serverId: activeThreadKey.serverId,
            params: AppSearchFilesRequest(
                query: query,
                roots: [searchRoot],
                cancellationToken: "ios-composer-file-search"
            )
        )
    }

    private func makeComposerPayload(
        text: String,
        attachmentImage: UIImage?,
        skillMentions: [SkillMentionSelection],
        pluginMentions: [PluginMentionSelection]
    ) throws -> AppComposerPayload {
        let preparedAttachment = attachmentImage.flatMap(ConversationAttachmentSupport.prepareImage)
        var additionalInputs = skillMentions.map { mention in
            AppUserInput.skill(name: mention.name, path: AbsolutePath(value: mention.path))
        }
        for mention in pluginMentions {
            additionalInputs.append(
                AppUserInput.mention(name: mention.name, path: mention.path)
            )
        }
        if let preparedAttachment {
            additionalInputs.append(preparedAttachment.userInput)
        }
        return AppComposerPayload(
            text: text,
            additionalInputs: additionalInputs,
            approvalPolicy: appState.launchApprovalPolicy(for: activeThreadKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: activeThreadKey),
            model: pendingModelOverride,
            effort: ReasoningEffort(wireValue: pendingReasoningOverride),
            serviceTier: ServiceTier(wireValue: fastMode ? "fast" : nil)
        )
    }

    private func launchConfig() -> AppThreadLaunchConfig {
        AppThreadLaunchConfig(
            agentRuntimeKind: pendingAgentRuntimeKindOverride,
            model: pendingModelOverride,
            approvalPolicy: appState.launchApprovalPolicy(for: activeThreadKey),
            sandbox: appState.launchSandboxMode(for: activeThreadKey),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }
}

private extension AppThreadSnapshot {
    var serverId: String { key.serverId }
    var isSubagent: Bool {
        info.parentThreadId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && ((info.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (info.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false))
    }

    var agentDisplayLabel: String? {
        let nickname = info.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = info.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nickname, !nickname.isEmpty { return nickname }
        if let role, !role.isEmpty { return role }
        return nil
    }
}

private struct ConversationBottomChrome: View {
    @Environment(AppModel.self) private var appModel
    let pinnedContextItems: [ConversationItem]
    let composer: ConversationComposerSnapshot
    @Binding var composerInputText: String
    @Binding var composerAttachedImage: UIImage?
    let onSend: (String, UIImage?, [SkillMentionSelection], [PluginMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FileSearchResult]
    var bottomInset: CGFloat = 0
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?
    @State private var showCollaborationModeSelector = false
    @State private var collaborationModePresets: [AppCollaborationModePreset] = []
    @State private var collaborationModesLoading = false
    @State private var collaborationModeError: String?

    var body: some View {
        VStack(spacing: 0) {
            ConversationPinnedContextStrip(
                items: pinnedContextItems
            )
            ConversationInputBar(
                snapshot: composer,
                onSend: onSend,
                onFileSearch: onFileSearch,
                bottomInset: bottomInset,
                showModeChip: !hasPinnedDiff,
                onOpenModePicker: openCollaborationModePicker,
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions,
                inputText: $composerInputText,
                attachedImage: $composerAttachedImage
            )
            .background(.clear, ignoresSafeAreaEdges: .bottom)
        }
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: Array(LitterTheme.headerScrim.reversed()),
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -30)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        )
        .sheet(isPresented: $showCollaborationModeSelector) {
            CollaborationModeSelectorSheet(
                presets: collaborationModePresets.isEmpty ? fallbackCollaborationModePresets : collaborationModePresets,
                selectedMode: composer.collaborationMode,
                isLoading: collaborationModesLoading,
                onSelect: { mode in
                    showCollaborationModeSelector = false
                    Task { await setCollaborationMode(mode) }
                }
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
            .task {
                await loadCollaborationModes()
            }
        }
        .alert("Collaboration Mode", isPresented: Binding(
            get: { collaborationModeError != nil },
            set: { if !$0 { collaborationModeError = nil } }
        )) {
            Button("OK", role: .cancel) { collaborationModeError = nil }
        } message: {
            Text(collaborationModeError ?? "Unable to update collaboration mode.")
        }
    }

    private var hasPinnedDiff: Bool {
        pinnedContextItems.contains {
            if case .fileChange(let data) = $0.content {
                return data.changes.contains {
                    !$0.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            if case .turnDiff(let data) = $0.content {
                return !data.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    private var fallbackCollaborationModePresets: [AppCollaborationModePreset] {
        [
            AppCollaborationModePreset(
                kind: .`default`,
                name: "Default",
                model: nil,
                reasoningEffort: nil
            ),
            AppCollaborationModePreset(
                kind: .plan,
                name: "Plan",
                model: nil,
                reasoningEffort: .medium
            )
        ]
    }

    private func openCollaborationModePicker() {
        showCollaborationModeSelector = true
    }

    private func loadCollaborationModes() async {
        guard !collaborationModesLoading else { return }
        collaborationModesLoading = true
        defer { collaborationModesLoading = false }
        do {
            collaborationModePresets = try await appModel.client.listCollaborationModes(
                serverId: composer.threadKey.serverId
            )
        } catch {
            collaborationModePresets = fallbackCollaborationModePresets
        }
    }

    private func setCollaborationMode(_ mode: AppModeKind) async {
        do {
            try await appModel.store.setThreadCollaborationMode(
                key: composer.threadKey,
                mode: mode
            )
        } catch {
            collaborationModeError = error.localizedDescription
        }
    }
}

struct RateLimitBadgeView: View, Equatable {
    let label: String
    let percent: Int

    private var tint: Color {
        if percent <= 10 { return LitterTheme.danger }
        if percent <= 30 { return LitterTheme.warning }
        return LitterTheme.textMuted
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(LitterFont.monospaced(size: 9.5, weight: .semibold))
                .foregroundColor(LitterTheme.textSecondary)
            ContextBadgeView(percent: percent, tint: tint)
        }
    }
}


private struct ConversationMessageList: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let items: [ConversationItem]
    let threadStatus: ConversationStatus
    let threadHasServerData: Bool
    let transcriptRenderDigest: Int
    let followScrollToken: Int
    let sendScrollToken: Int
    let activeThreadKey: ThreadKey
    let agentDirectoryVersion: UInt64
    var topInset: CGFloat = 0
    let olderTurnsCursor: String?
    let initialTurnsLoaded: Bool
    @Binding var textSizeStep: Int
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    let onLoadOlderTurns: (ThreadKey) -> Void
    @State private var isNearBottom = true
    @State private var autoFollowStreaming = true
    @State private var userIsDraggingScroll = false
    @State private var distanceFromBottom: CGFloat = 0
    @State private var waitingForDataExpired = false
    @State private var pinchBaseStep: Int?
    @State private var pinchAppliedDelta = 0
    @State private var transcriptTurns: [TranscriptTurn] = []
    @State private var transcriptBuildKey: Int?
    @State private var renderedTurns: [TranscriptTurn] = []
    @State private var renderedTurnsBuildKey: Int?
    @State private var expandedTurnIDs: Set<String> = []
    @State private var pendingAnimatedTurns: [TranscriptTurn]?
    @State private var turnInsertionAnimationInFlight = false
    @State private var followLayoutScrollScheduled = false
    @State private var initialBottomScrollThreadScopeID: String?
    @State private var programmaticBottomScrollSettling = false
    @State private var programmaticBottomScrollGeneration = 0
    @AppStorage("collapseTurns") private var collapseTurns = false
    private static let latestButtonShowDistance: CGFloat = 48
    private static let nearBottomRestoreDistance: CGFloat = 12
    private static let bottomScrollSettleDuration: TimeInterval = 0.3
    private static let bottomAnchorID = "conversation-message-list-bottom"
    private static let scrollCoordinateSpaceName = "conversation-message-list-scroll"

    private var expandedRecentTurnCount: Int {
        return collapseTurns ? 1 : .max
    }

    private var sourceTurns: [TranscriptTurn] {
        if transcriptTurns.isEmpty {
            return TranscriptTurn.build(
                from: items,
                threadStatus: threadStatus,
                expandedRecentTurnCount: expandedRecentTurnCount
            )
        }
        return transcriptTurns
    }

    private var lastTurnIsUserOnly: Bool {
        guard let lastTurn = sourceTurns.last else { return false }
        return lastTurn.items.allSatisfy { $0.isUserItem }
    }

    private var isStreamingLastTurn: Bool {
        if case .thinking = threadStatus { return true }
        return sourceTurns.last?.isLive == true
    }

    private var messageActionsDisabled: Bool {
        if case .thinking = threadStatus { return true }
        return false
    }

    private var isWaitingForData: Bool {
        items.isEmpty && threadHasServerData && !waitingForDataExpired
    }

    private var shouldShowScrollToBottom: Bool {
        !items.isEmpty && distanceFromBottom > Self.latestButtonShowDistance
    }

    private var activeThreadScopeID: String {
        "\(activeThreadKey.serverId)::\(activeThreadKey.threadId)"
    }

    private var isStreaming: Bool {
        if case .thinking = threadStatus { return true }
        return false
    }

    private var hasOlderTurns: Bool {
        if let cursor = olderTurnsCursor { return !cursor.isEmpty }
        return false
    }

    private var mergedRenderableTurns: [TranscriptTurn] {
        let turns = sourceTurns
        let buildKey = makeRenderedTurnsBuildKey(for: turns)
        if renderedTurnsBuildKey == buildKey { return renderedTurns }
        return TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(turns)
    }

    var body: some View {
        let turns = mergedRenderableTurns
        let lastTurnID = turns.last?.id
        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if !initialTurnsLoaded && hasOlderTurns && !turns.isEmpty {
                                ConversationLoadingIndicator(label: "Loading earlier messages...")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            } else if hasOlderTurns {
                                Button {
                                    onLoadOlderTurns(activeThreadKey)
                                } label: {
                                    Text("Load earlier messages")
                                        .litterFont(.caption, weight: .semibold)
                                        .foregroundColor(LitterTheme.accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(turns) { turn in
                                let isLastTurn = turn.id == lastTurnID
                                ConversationTurnRow(
                                    turn: turn,
                                    isExpanded: isTurnExpanded(turn),
                                    canCollapse: turn.isCollapsedByDefault,
                                    isLastTurn: isLastTurn,
                                    viewportHeight: viewport.size.height,
                                    showTypingIndicator: isLastTurn && {
                                        if case .thinking = threadStatus { return true }
                                        return false
                                    }(),
                                    serverId: activeThreadKey.serverId,
                                    originThreadId: activeThreadKey.threadId,
                                    agentDirectoryVersion: agentDirectoryVersion,
                                    messageActionsDisabled: messageActionsDisabled,
                                    onToggleExpansion: {
                                        toggleTurnExpansion(turn)
                                    },
                                    onStreamingSnapshotRendered: {
                                        requestFollowScrollAfterLayout(proxy)
                                    },
                                    onLiveContentLayoutChanged: {
                                        requestFollowScrollAfterLayout(proxy)
                                    },
                                    resolveTargetLabel: resolveTargetLabel,
                                    onWidgetPrompt: onWidgetPrompt,
                                    onEditUserItem: onEditUserItem,
                                    onForkFromUserItem: onForkFromUserItem,
                                    onOpenConversation: onOpenConversation
                                )
                                .equatable()
                                .turnDebugOverlay(turnId: turn.id)
                            }
                        }
                        .frame(maxWidth: LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass) ? 760 : .infinity)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 16)
                        .padding(.top, topInset + 56)
                        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: textSizeStep)

                        if isWaitingForData {
                            ConversationLoadingIndicator(label: "Loading conversation...")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .id(activeThreadScopeID)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: Self.scrollCoordinateSpaceName)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { _, distance in
                    updateDistanceFromBottom(distance)
                }
                // Keep the chat initially bottom-aligned, but don't let keyboard-driven
                // viewport size changes force a fresh bottom jump with stale lazy heights.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .simultaneousGesture(
                    MagnificationGesture(minimumScaleDelta: 0.03)
                        .onChanged { scale in handlePinchChanged(scale: scale) }
                        .onEnded { scale in finishPinch(scale: scale) }
                )
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        programmaticBottomScrollSettling = false
                        userIsDraggingScroll = true
                        if isStreaming { autoFollowStreaming = false }
                    case .decelerating:
                        userIsDraggingScroll = true
                    default:
                        userIsDraggingScroll = false
                        if isNearBottom { autoFollowStreaming = true }
                    }
                }
                .onAppear {
                    autoFollowStreaming = true
                    syncTranscriptTurns()
                    requestInitialBottomScrollIfNeeded(proxy)
                }
                .onChange(of: activeThreadKey) {
                    autoFollowStreaming = true
                    isNearBottom = true
                    distanceFromBottom = 0
                    initialBottomScrollThreadScopeID = nil
                    waitingForDataExpired = false
                    syncTranscriptTurns(resetExpansion: true)
                    StreamingRendererCoordinator.shared.reset()
                    requestInitialBottomScrollIfNeeded(proxy)
                }
                .task(id: activeThreadKey) {
                    try? await Task.sleep(for: .seconds(1))
                    waitingForDataExpired = true
                }
                .onChange(of: items) { _, _ in
                    syncTranscriptTurns()
                    requestInitialBottomScrollIfNeeded(proxy)
                }
                .onChange(of: collapseTurns) {
                    syncTranscriptTurns(resetExpansion: true)
                }
                .onChange(of: followScrollToken) {
                    guard isStreaming, autoFollowStreaming, !userIsDraggingScroll else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: sendScrollToken) {
                    autoFollowStreaming = true
                    isNearBottom = true
                    distanceFromBottom = 0
                    scrollToBottom(proxy)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9)) {
                            scrollToBottom(proxy)
                        }
                    }
                }
                .onChange(of: threadStatus) { oldStatus, _ in
                    syncTranscriptTurns()
                    // When streaming ends, finish active renderers so they
                    // switch to static rendering (no re-animation on view rebuild).
                    let wasStreaming = { if case .thinking = oldStatus { return true }; return false }()
                    if wasStreaming && !isStreaming {
                        StreamingRendererCoordinator.shared.finishActive()
                    }
                    if wasStreaming && !isStreaming && autoFollowStreaming {
                        scrollToBottom(proxy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollToBottom(proxy)
                        }
                    }
                }

                if shouldShowScrollToBottom {
                    ScrollToBottomIndicator {
                        autoFollowStreaming = true
                        isNearBottom = true
                        distanceFromBottom = 0
                        // Jump without animation first so LazyVStack realizes
                        // content near the bottom, then do an animated corrective
                        // scroll once layout has settled.  This avoids the
                        // overshoot caused by stale estimated heights.
                        scrollToBottom(proxy)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9)) {
                                scrollToBottom(proxy)
                            }
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            }
        }
    }

    private func isTurnExpanded(_ turn: TranscriptTurn) -> Bool {
        !turn.isCollapsedByDefault || expandedTurnIDs.contains(turn.id)
    }

    private func toggleTurnExpansion(_ turn: TranscriptTurn) {
        guard turn.isCollapsedByDefault else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            if expandedTurnIDs.contains(turn.id) {
                expandedTurnIDs.remove(turn.id)
            } else {
                expandedTurnIDs.insert(turn.id)
            }
        }
    }

    private func requestFollowScrollAfterLayout(_ proxy: ScrollViewProxy) {
        guard !followLayoutScrollScheduled else { return }
        followLayoutScrollScheduled = true
        DispatchQueue.main.async {
            followLayoutScrollScheduled = false
            guard isStreaming, autoFollowStreaming, !userIsDraggingScroll else { return }
            scrollToBottom(proxy)
        }
    }

    private func requestInitialBottomScrollIfNeeded(_ proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let threadScopeID = activeThreadScopeID
        guard initialBottomScrollThreadScopeID != threadScopeID else { return }
        initialBottomScrollThreadScopeID = threadScopeID
        DispatchQueue.main.async {
            guard activeThreadScopeID == threadScopeID else { return }
            scrollToBottom(proxy)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard activeThreadScopeID == threadScopeID else { return }
                scrollToBottom(proxy)
            }
        }
    }

    private func updateDistanceFromBottom(_ distance: CGFloat) {
        let clampedDistance = max(0, distance)
        if programmaticBottomScrollSettling {
            if clampedDistance <= Self.nearBottomRestoreDistance {
                programmaticBottomScrollSettling = false
            } else {
                return
            }
        }

        distanceFromBottom = clampedDistance
        let nextIsNearBottom = clampedDistance <= Self.nearBottomRestoreDistance
        if nextIsNearBottom != isNearBottom { isNearBottom = nextIsNearBottom }
        if nextIsNearBottom {
            autoFollowStreaming = true
        } else if isStreaming && userIsDraggingScroll {
            autoFollowStreaming = false
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isNearBottom = true
        distanceFromBottom = 0
        programmaticBottomScrollGeneration &+= 1
        let generation = programmaticBottomScrollGeneration
        programmaticBottomScrollSettling = true
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bottomScrollSettleDuration) {
            guard programmaticBottomScrollGeneration == generation else { return }
            programmaticBottomScrollSettling = false
        }
    }

    private func syncTranscriptTurns(resetExpansion: Bool = false) {
        let nextBuildKey = makeTranscriptBuildKey()
        if transcriptBuildKey == nextBuildKey, !transcriptTurns.isEmpty {
            if resetExpansion { expandedTurnIDs.removeAll() }
            return
        }

        let nextTurns = TranscriptTurn.build(
            from: items,
            threadStatus: threadStatus,
            expandedRecentTurnCount: expandedRecentTurnCount
        )
        transcriptBuildKey = nextBuildKey
        if shouldAnimateNewTurnInsertion(from: transcriptTurns, to: nextTurns, resetExpansion: resetExpansion) {
            pendingAnimatedTurns = nextTurns
            guard !turnInsertionAnimationInFlight else { return }
            startNewTurnInsertionAnimation(from: transcriptTurns)
            return
        }

        if turnInsertionAnimationInFlight {
            pendingAnimatedTurns = nextTurns
            return
        }

        let lastTurnItemCountGrew = {
            guard let currentLast = transcriptTurns.last,
                  let nextLast = nextTurns.last,
                  currentLast.id == nextLast.id,
                  nextLast.items.count > currentLast.items.count else {
                return false
            }
            return true
        }()

        if lastTurnItemCountGrew {
            withAnimation(.spring(duration: 0.4, bounce: 0.08)) {
                applyTranscriptTurns(nextTurns, resetExpansion: resetExpansion)
            }
        } else {
            applyTranscriptTurns(nextTurns, resetExpansion: resetExpansion)
        }
    }

    private func makeTranscriptBuildKey() -> Int {
        var hasher = Hasher()
        hasher.combine(expandedRecentTurnCount)
        hasher.combine(transcriptRenderDigest)
        return hasher.finalize()
    }

    private func makeRenderedTurnsBuildKey(for turns: [TranscriptTurn]) -> Int {
        var hasher = Hasher()
        hasher.combine(turns.count)
        for turn in turns {
            hasher.combine(turn.id)
            hasher.combine(turn.renderDigest)
            hasher.combine(turn.isLive)
            hasher.combine(turn.isCollapsedByDefault)
        }
        return hasher.finalize()
    }

    private func layoutSignature(for turn: TranscriptTurn) -> Int {
        var hasher = Hasher()
        hasher.combine(turn.id)
        hasher.combine(turn.renderDigest)
        hasher.combine(turn.isLive)
        hasher.combine(turn.isCollapsedByDefault)
        return hasher.finalize()
    }

    private func handlePinchChanged(scale: CGFloat) {
        if pinchBaseStep == nil {
            pinchBaseStep = textSizeStep
            pinchAppliedDelta = 0
        }

        let candidateDelta: Int
        if scale >= 1.18 { candidateDelta = 2 }
        else if scale >= 1.03 { candidateDelta = 1 }
        else if scale <= 0.86 { candidateDelta = -2 }
        else if scale <= 0.97 { candidateDelta = -1 }
        else { candidateDelta = 0 }
        guard candidateDelta != 0 else { return }

        if pinchAppliedDelta == 0 {
            pinchAppliedDelta = candidateDelta
            return
        }

        let sameDirection = (pinchAppliedDelta > 0 && candidateDelta > 0) || (pinchAppliedDelta < 0 && candidateDelta < 0)
        if sameDirection {
            if abs(candidateDelta) > abs(pinchAppliedDelta) {
                pinchAppliedDelta = candidateDelta
            }
        } else {
            pinchAppliedDelta = candidateDelta
        }
    }

    private func finishPinch(scale: CGFloat) {
        handlePinchChanged(scale: scale)
        let baseline = pinchBaseStep ?? textSizeStep
        let next = ConversationTextSize.clamped(rawValue: baseline + pinchAppliedDelta).rawValue
        if next != textSizeStep {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                textSizeStep = next
            }
        }
        pinchBaseStep = nil
        pinchAppliedDelta = 0
    }

    private func shouldAnimateNewTurnInsertion(
        from currentTurns: [TranscriptTurn],
        to nextTurns: [TranscriptTurn],
        resetExpansion: Bool
    ) -> Bool {
        guard collapseTurns,
              !resetExpansion,
              !currentTurns.isEmpty,
              nextTurns.count == currentTurns.count + 1,
              currentTurns.last?.id != nextTurns.last?.id,
              let lastTurn = nextTurns.last,
              lastTurn.items.first?.isUserItem == true,
              lastTurn.items.first?.isFromUserTurnBoundary == true else {
            return false
        }

        for (currentTurn, nextTurn) in zip(currentTurns, nextTurns) {
            guard currentTurn.id == nextTurn.id else { return false }
        }

        return true
    }

    private func startNewTurnInsertionAnimation(from currentTurns: [TranscriptTurn]) {
        guard let previousLastTurnID = currentTurns.last?.id else {
            if let pendingAnimatedTurns {
                applyTranscriptTurns(pendingAnimatedTurns)
                self.pendingAnimatedTurns = nil
            }
            return
        }

        turnInsertionAnimationInFlight = true
        let collapsedTurns = currentTurns.map { turn in
            turn.id == previousLastTurnID ? turn.withCollapsedByDefault(true) : turn
        }

        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            applyTranscriptTurns(
                collapsedTurns,
                removeExpandedTurnID: previousLastTurnID
            )
        } completion: {
            let turnsToInsert = pendingAnimatedTurns ?? collapsedTurns
            withAnimation(.smooth(duration: 0.2)) {
                applyTranscriptTurns(turnsToInsert)
            } completion: {
                turnInsertionAnimationInFlight = false
                let latestTurns = pendingAnimatedTurns ?? turnsToInsert
                pendingAnimatedTurns = nil
                if latestTurns.map(layoutSignature(for:)) != transcriptTurns.map(layoutSignature(for:)) {
                    applyTranscriptTurns(latestTurns)
                }
            }
        }
    }

    private func applyTranscriptTurns(
        _ nextTurns: [TranscriptTurn],
        resetExpansion: Bool = false,
        removeExpandedTurnID: String? = nil
    ) {
        let nextTurnIDs = Set(nextTurns.map(\.id))
        let nextRenderedTurns = TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(nextTurns)
        transcriptTurns = nextTurns
        renderedTurns = nextRenderedTurns
        renderedTurnsBuildKey = makeRenderedTurnsBuildKey(for: nextTurns)
        if resetExpansion {
            expandedTurnIDs.removeAll()
        } else {
            expandedTurnIDs.formIntersection(nextTurnIDs)
        }
        if let removeExpandedTurnID {
            expandedTurnIDs.remove(removeExpandedTurnID)
        }
    }

}

private struct ConversationTurnRow: View, Equatable {
    let turn: TranscriptTurn
    let isExpanded: Bool
    let canCollapse: Bool
    let isLastTurn: Bool
    let viewportHeight: CGFloat
    let showTypingIndicator: Bool
    let serverId: String
    let originThreadId: String?
    let agentDirectoryVersion: UInt64
    @Environment(\.textScale) private var textScale
    let messageActionsDisabled: Bool
    let onToggleExpansion: () -> Void
    let onStreamingSnapshotRendered: (() -> Void)?
    let onLiveContentLayoutChanged: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    static func == (lhs: ConversationTurnRow, rhs: ConversationTurnRow) -> Bool {
        lhs.turn.id == rhs.turn.id &&
            lhs.turn.renderDigest == rhs.turn.renderDigest &&
            lhs.turn.isLive == rhs.turn.isLive &&
            lhs.isExpanded == rhs.isExpanded &&
            lhs.canCollapse == rhs.canCollapse &&
            lhs.isLastTurn == rhs.isLastTurn &&
            lhs.viewportHeight == rhs.viewportHeight &&
            lhs.showTypingIndicator == rhs.showTypingIndicator &&
            lhs.serverId == rhs.serverId &&
            lhs.originThreadId == rhs.originThreadId &&
            lhs.agentDirectoryVersion == rhs.agentDirectoryVersion &&
            lhs.messageActionsDisabled == rhs.messageActionsDisabled
    }

    var body: some View {
        if isExpanded {
            expandedContent
        } else {
            collapsedCard
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationTurnTimeline(
                items: turn.items,
                isLive: turn.isLive,
                serverId: serverId,
                originThreadId: originThreadId,
                agentDirectoryVersion: agentDirectoryVersion,
                messageActionsDisabled: messageActionsDisabled,
                onStreamingSnapshotRendered: onStreamingSnapshotRendered,
                onLiveContentLayoutChanged: onLiveContentLayoutChanged,
                resolveTargetLabel: resolveTargetLabel,
                onWidgetPrompt: onWidgetPrompt,
                onEditUserItem: onEditUserItem,
                onForkFromUserItem: onForkFromUserItem,
                onOpenConversation: onOpenConversation
            )

            TypingIndicator()
                .opacity(showTypingIndicator ? 1 : 0)
                .animation(nil)

            if canCollapse {
                Button("Show Less", systemImage: "chevron.up", action: onToggleExpansion)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
        }
    }

    private var collapsedCard: some View {
        Button(action: onToggleExpansion) {
            previewTextBlock
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, collapsedFooterReservedInset)
                .modifier(GlassRectModifier(cornerRadius: 16, tint: LitterTheme.surface.opacity(0.34)))
                .overlay(alignment: .bottomLeading) {
                    footerRow
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var previewTextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: turn.preview.primaryText)
                .litterFont(.body, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: responsePreviewText)
                .litterFont(.body)
                .foregroundColor(LitterTheme.textSecondary.opacity(0.82))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(
                    maxWidth: .infinity,
                    minHeight: collapsedResponseHeight,
                    maxHeight: collapsedResponseHeight,
                    alignment: .topLeading
                )
                .mask(responsePreviewMask)
        }
        .frame(maxWidth: .infinity, minHeight: collapsedPreviewHeight, maxHeight: collapsedPreviewHeight, alignment: .topLeading)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if !footerMetadataItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(footerMetadataItems, id: \.id) { item in
                        CollapsedTurnMetaItem(systemImage: item.systemImage, text: item.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.textMuted)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var collapsedPreviewHeight: CGFloat { collapsedPrimaryLineHeight + collapsedResponseHeight + 4 }
    private var collapsedFooterReservedInset: CGFloat { collapsedFooterHeight + 10 }
    private var collapsedFooterHeight: CGFloat { max(UIFont.preferredFont(forTextStyle: .caption1).lineHeight * textScale, 14) }

    private var responsePreviewMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.55),
                .init(color: .white.opacity(0.58), location: 0.82),
                .init(color: .white.opacity(0.24), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var collapsedPrimaryLineHeight: CGFloat { collapsedPreviewLineHeight }
    private var collapsedResponseHeight: CGFloat { (collapsedPreviewLineHeight * 2) + 2 }
    private var collapsedPreviewLineHeight: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight * textScale }

    private var footerMetadataItems: [CollapsedTurnMeta] {
        var items: [CollapsedTurnMeta] = []
        if let durationText = turn.preview.durationText {
            items.append(CollapsedTurnMeta(id: "duration", systemImage: "clock", text: durationText))
        }
        if turn.preview.toolCallCount > 0 {
            items.append(CollapsedTurnMeta(id: "tools", systemImage: "chevron.left.forwardslash.chevron.right", text: "\(turn.preview.toolCallCount)"))
        }
        if turn.preview.eventCount > 0 {
            items.append(CollapsedTurnMeta(id: "events", systemImage: "sparkles", text: "\(turn.preview.eventCount)"))
        }
        if turn.preview.widgetCount > 0 {
            items.append(CollapsedTurnMeta(id: "widgets", systemImage: "rectangle.3.group", text: "\(turn.preview.widgetCount)"))
        }
        if turn.preview.imageCount > 0 {
            items.append(CollapsedTurnMeta(id: "images", systemImage: "photo", text: "\(turn.preview.imageCount)"))
        }
        return items
    }

    private var secondaryPreviewText: String? {
        guard let secondaryText = turn.preview.secondaryText, secondaryText != turn.preview.primaryText else { return nil }
        return secondaryText
    }

    private var responsePreviewText: String { secondaryPreviewText ?? turn.preview.primaryText }

    private var accessibilitySummary: String {
        var parts = [turn.preview.primaryText]
        if let secondaryPreviewText { parts.append(secondaryPreviewText) }
        if let durationText = turn.preview.durationText { parts.append("Duration \(durationText)") }
        if turn.preview.toolCallCount > 0 { parts.append("\(turn.preview.toolCallCount) tool \(turn.preview.toolCallCount == 1 ? "call" : "calls")") }
        if turn.preview.widgetCount > 0 { parts.append("\(turn.preview.widgetCount) \(turn.preview.widgetCount == 1 ? "widget" : "widgets")") }
        if turn.preview.eventCount > 0 { parts.append("\(turn.preview.eventCount) \(turn.preview.eventCount == 1 ? "event" : "events")") }
        if turn.preview.imageCount > 0 { parts.append("\(turn.preview.imageCount) \(turn.preview.imageCount == 1 ? "image" : "images")") }
        return parts.joined(separator: ". ")
    }
}

private struct CollapsedTurnMeta: Identifiable {
    let id: String
    let systemImage: String
    let text: String
}

private struct CollapsedTurnMetaItem: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .litterFont(size: 9, weight: .medium)
                .foregroundColor(LitterTheme.textMuted)
            Text(verbatim: text)
                .litterMonoFont(size: 10)
                .foregroundColor(LitterTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct ScrollToBottomIndicator: View {
    let action: () -> Void
    @State private var bob = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .litterFont(.caption, weight: .bold)
                    .offset(y: bob ? 1.5 : -1.5)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: bob)
                Text("Latest")
                    .litterFont(.caption, weight: .semibold)
            }
            .foregroundColor(LitterTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(GlassCapsuleModifier())
        }
        .contentShape(Capsule())
        .onAppear {
            bob = true
        }
    }
}

private struct ConversationInputBar: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let snapshot: ConversationComposerSnapshot
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("fastMode") private var fastMode = false

    let onSend: (String, UIImage?, [SkillMentionSelection], [PluginMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FileSearchResult]
    var bottomInset: CGFloat = 0
    let showModeChip: Bool
    let onOpenModePicker: () -> Void
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?

    @Binding var inputText: String
    @Binding var attachedImage: UIImage?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showSlashPopup = false
    @State private var activeSlashToken: ComposerSlashQueryContext?
    @State private var slashSuggestions: [ComposerSlashCommand] = []
    @State private var showFilePopup = false
    @State private var activeAtToken: ComposerTokenContext?
    @State private var showSkillPopup = false
    @State private var activeDollarToken: ComposerTokenContext?
    @State private var fileSearchLoading = false
    @State private var fileSearchError: String?
    @State private var fileSuggestions: [FileSearchResult] = []
    @State private var fileSearchGeneration = 0
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var popupRefreshTask: Task<Void, Never>?
    @State private var showModelSelector = false
    @State private var showPermissionsSheet = false
    @State private var showExperimentalSheet = false
    @State private var showSkillsSheet = false
    @State private var showRenamePrompt = false
    @State private var renameCurrentThreadTitle = ""
    @State private var renameDraft = ""
    @State private var slashErrorMessage: String?
    @State private var experimentalFeatures: [ExperimentalFeature] = []
    @State private var experimentalFeaturesLoading = false
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false
    @State private var mentionSkillPathsByName: [String: String] = [:]
    @State private var hasAttemptedSkillMentionLoad = false
    @State private var pluginCacheByCwd: [String: [PluginSummary]] = [:]
    @State private var pluginUnsupportedCwds: Set<String> = []
    @State private var pluginLoadingCwds: Set<String> = []
    @State private var pluginMentionSelections: [PluginMentionSelection] = []
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var showMicPermissionAlert = false
    @State private var hasLoggedFirstFocus = false
    @State private var hasLoggedKeyboardShown = false
    @State private var isComposerFocused = false
    @State private var composerSelectionRange = NSRange(location: 0, length: 0)
    @State private var dismissedPendingUserInputIds: Set<String> = []

    private var pendingUserInputRequest: PendingUserInputRequest? {
        guard let request = snapshot.pendingUserInputRequest else { return nil }
        return dismissedPendingUserInputIds.contains(request.id) ? nil : request
    }

    private var pendingModelOverride: String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var pendingAgentRuntimeKindOverride: AgentRuntimeKind? {
        pendingModelOverride == nil ? nil : appState.selectedAgentRuntimeKind
    }

    private var isTurnActive: Bool {
        snapshot.isTurnActive
    }

    private var activeTurnId: String? {
        guard let value = snapshot.activeTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private var popupState: ConversationComposerPopupState {
        if showSlashPopup {
            return .slash(slashSuggestions)
        }
        if showFilePopup {
            return .file(
                loading: fileSearchLoading,
                error: fileSearchError,
                suggestions: fileSuggestions,
                plugins: pluginSuggestions
            )
        }
        if showSkillPopup {
            return .skill(loading: skillsLoading, suggestions: skillSuggestions)
        }
        return .none
    }

    var body: some View {
        ConversationComposerModalCoordinator(
            snapshot: snapshot,
            experimentalFeatures: experimentalFeatures,
            experimentalFeaturesLoading: experimentalFeaturesLoading,
            skills: skills,
            skillsLoading: skillsLoading,
            showAttachMenu: $showAttachMenu,
            showPhotoPicker: $showPhotoPicker,
            showCamera: $showCamera,
            showFileImporter: $showFileImporter,
            selectedPhoto: $selectedPhoto,
            attachedImage: $attachedImage,
            showModelSelector: $showModelSelector,
            showPermissionsSheet: $showPermissionsSheet,
            showExperimentalSheet: $showExperimentalSheet,
            showSkillsSheet: $showSkillsSheet,
            showRenamePrompt: $showRenamePrompt,
            renameCurrentThreadTitle: $renameCurrentThreadTitle,
            renameDraft: $renameDraft,
            slashErrorMessage: $slashErrorMessage,
            showMicPermissionAlert: $showMicPermissionAlert,
            onOpenSettings: openAppSettings,
            onLoadSelectedPhoto: loadSelectedPhoto,
            onLoadSelectedFile: { url in
                attachedImage = ConversationAttachmentSupport.loadImageFile(at: url)
            },
            onLoadExperimentalFeatures: loadExperimentalFeatures,
            onIsExperimentalFeatureEnabled: { featureId, fallback in
                isExperimentalFeatureEnabled(featureId, fallback: fallback)
            },
            onSetExperimentalFeature: { featureName, enabled in
                await setExperimentalFeature(named: featureName, enabled: enabled)
            },
            onLoadSkills: { forceReload, showErrors in
                await loadSkills(forceReload: forceReload, showErrors: showErrors)
            },
            onRenameThread: renameThread
        ) {
            composerSurface
        }
        .onChange(of: inputText) { _, next in
            scheduleComposerPopupRefresh(for: next)
        }
        .onChange(of: snapshot.composerPrefillRequest?.id) { _, _ in
            guard let prefill = snapshot.composerPrefillRequest else { return }
            inputText = prefill.text
            composerSelectionRange = NSRange(location: (prefill.text as NSString).length, length: 0)
            attachedImage = nil
            hideComposerPopups()
            appModel.clearComposerPrefill(id: prefill.id)
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                guard !hasLoggedFirstFocus else { return }
                hasLoggedFirstFocus = true
                os_signpost(.event, log: conversationViewSignpostLog, name: "ComposerFirstFocus")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard !hasLoggedKeyboardShown else { return }
            hasLoggedKeyboardShown = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "KeyboardShown")
        }
        #if targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: .litterCommandSendComposer)) { _ in
            handleSend()
        }
        #endif
        .onDisappear {
            if voiceManager.isRecording { voiceManager.cancelRecording() }
            popupRefreshTask?.cancel()
            popupRefreshTask = nil
            fileSearchTask?.cancel()
            fileSearchTask = nil
        }
    }

    private var composerSurface: some View {
        VStack(spacing: 0) {
            ConversationComposerContentView(
                attachedImage: attachedImage,
                collaborationMode: snapshot.collaborationMode,
                activePlanProgress: snapshot.activePlanProgress,
                pendingUserInputRequest: pendingUserInputRequest,
                hasPendingPlanImplementation: snapshot.pendingPlanImplementationPrompt != nil,
                activeTaskSummary: snapshot.activeTaskSummary,
                queuedFollowUps: snapshot.queuedFollowUps,
                pluginMentions: pluginMentionSelections,
                goal: snapshot.goal,
                goalActions: makeGoalCardActions(),
                rateLimits: snapshot.rateLimits,
                contextPercent: contextPercent(),
                isTurnActive: isTurnActive,
                showModeChip: showModeChip,
                voiceManager: voiceManager,
                showAttachMenu: $showAttachMenu,
                onClearAttachment: clearAttachment,
                onRespondToPendingUserInput: respondToPendingUserInput,
                onDismissPendingUserInput: dismissPendingUserInput,
                onImplementPlan: { Task { await implementPlan() } },
                onDismissPlanImplementation: dismissPlanImplementationPrompt,
                onSteerQueuedFollowUp: steerQueuedFollowUp,
                onDeleteQueuedFollowUp: deleteQueuedFollowUp,
                onRemovePluginMention: removePluginMention,
                onPasteImage: { image in attachedImage = image },
                onOpenModePicker: onOpenModePicker,
                onSendText: handleSend,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: interruptActiveTurn,
                inputText: $inputText,
                isComposerFocused: $isComposerFocused,
                composerSelectionRange: $composerSelectionRange
            )
            .overlay(alignment: .bottom) {
                ConversationComposerPopupOverlayView(
                    state: popupState,
                    onApplySlashSuggestion: applySlashSuggestion,
                    onApplyFileSuggestion: applyFileSuggestion,
                    onApplySkillSuggestion: applySkillSuggestion,
                    onApplyPluginSuggestion: applyPluginSuggestion
                )
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let image = urls.lazy.compactMap({ ConversationAttachmentSupport.loadImageFile(at: $0) }).first else {
                return false
            }
            attachedImage = image
            return true
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let image = items.lazy.compactMap({ UIImage(data: $0) }).first else {
                return false
            }
            attachedImage = image
            return true
        }
    }

    private func contextPercent() -> Int64? {
        guard let contextWindow = snapshot.modelContextWindow else { return nil }
        let baseline: Int64 = 12_000
        guard contextWindow > baseline else { return 0 }
        let totalTokens = snapshot.contextTokensUsed ?? baseline
        let effectiveWindow = contextWindow - baseline
        let usedTokens = max(0, totalTokens - baseline)
        let remainingTokens = max(0, effectiveWindow - usedTokens)
        let percent = Int64((Double(remainingTokens) / Double(effectiveWindow) * 100).rounded())
        return min(max(percent, 0), 100)
    }

    private func clearAttachment() {
        attachedImage = nil
    }

    private func respondToPendingUserInput(_ answers: [String: [String]]) {
        guard let pendingUserInputRequest else { return }
        let payload: [PendingUserInputAnswer] = pendingUserInputRequest.questions.compactMap { question in
            guard let selectedAnswers = answers[question.id], !selectedAnswers.isEmpty else { return nil }
            return PendingUserInputAnswer(questionId: question.id, answers: selectedAnswers)
        }
        Task {
            do {
                try await appModel.store.respondToUserInput(
                    requestId: pendingUserInputRequest.id,
                    answers: payload
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func steerQueuedFollowUp(_ preview: AppQueuedFollowUpPreview) {
        Task {
            do {
                try await appModel.store.steerQueuedFollowUp(
                    key: snapshot.threadKey,
                    previewId: preview.id
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func deleteQueuedFollowUp(_ preview: AppQueuedFollowUpPreview) {
        Task {
            do {
                try await appModel.store.deleteQueuedFollowUp(
                    key: snapshot.threadKey,
                    previewId: preview.id
                )
            } catch {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        guard !text.isEmpty || image != nil else { return }
        if let request = snapshot.pendingUserInputRequest {
            dismissedPendingUserInputIds.insert(request.id)
        }
        if image == nil,
           let invocation = parseSlashCommandInvocation(text) {
            inputText = ""
            attachedImage = nil
            hideComposerPopups()
            isComposerFocused = false
            executeSlashCommand(invocation.command, args: invocation.args)
            return
        }
        inputText = ""
        attachedImage = nil
        hideComposerPopups()
        isComposerFocused = false
        let skillMentions = collectSkillMentionsForSubmission(text)
        let pluginMentions = collectPluginMentionsForSubmission(text)
        pluginMentionSelections = []
        onSend(text, image, skillMentions, pluginMentions)
    }

    private func dismissPendingUserInput() {
        guard let request = snapshot.pendingUserInputRequest else { return }
        dismissedPendingUserInputIds.insert(request.id)
    }

    private func collectPluginMentionsForSubmission(_ text: String) -> [PluginMentionSelection] {
        guard !pluginMentionSelections.isEmpty else { return [] }
        let lowered = text.lowercased()
        var seen = Set<String>()
        var resolved: [PluginMentionSelection] = []
        for selection in pluginMentionSelections {
            // Drop selections the user has since deleted from the input text.
            guard lowered.contains("@\(selection.name.lowercased())") else { continue }
            guard seen.insert(selection.path).inserted else { continue }
            resolved.append(selection)
        }
        return resolved
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else {
                showMicPermissionAlert = true
                return
            }
            voiceManager.startRecording()
        }
    }

    private func stopVoiceRecording() {
        Task {
            let auth = try? await appModel.client.authStatus(
                serverId: snapshot.threadKey.serverId,
                params: AuthStatusRequest(includeToken: true, refreshToken: false)
            )
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth?.authMethod,
                authToken: auth?.authToken
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                insertTranscriptAtCursor(text)
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
        }
    }

    private func insertTranscriptAtCursor(_ transcript: String) {
        let insertion = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertion.isEmpty else { return }

        let nsText = inputText as NSString
        let textLength = nsText.length
        let location = min(max(composerSelectionRange.location, 0), textLength)
        let length = min(max(composerSelectionRange.length, 0), textLength - location)
        let range = NSRange(location: location, length: length)
        let replacement = composerInsertionText(insertion, in: nsText, replacing: range)
        let updated = nsText.replacingCharacters(in: range, with: replacement)
        inputText = updated
        let cursor = (updated as NSString).length - ((nsText.length - range.location - range.length))
        composerSelectionRange = NSRange(location: cursor, length: 0)
    }

    private func interruptActiveTurn() {
        guard let activeTurnId else {
            LLog.warn("conversation", "interrupt requested but no activeTurnId")
            return
        }
        let threadKey = snapshot.threadKey
        LLog.info(
            "conversation",
            "interrupt turn",
            fields: ["serverId": threadKey.serverId, "threadId": threadKey.threadId, "turnId": activeTurnId]
        )
        Task {
            do {
                _ = try await appModel.client.interruptTurn(
                    serverId: threadKey.serverId,
                    params: AppInterruptTurnRequest(
                        threadId: threadKey.threadId,
                        turnId: activeTurnId
                    )
                )
                LLog.info("conversation", "interrupt turn rpc ok")
            } catch {
                LLog.warn("conversation", "interrupt turn failed", fields: ["error": String(describing: error)])
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            attachedImage = image
        }
        selectedPhoto = nil
    }

    private func dismissPlanImplementationPrompt() {
        appModel.store.dismissPlanImplementationPrompt(key: snapshot.threadKey)
    }

    private func implementPlan() async {
        do {
            try await appModel.store.implementPlan(key: snapshot.threadKey)
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }


    private func clearFileSearchState(incrementGeneration: Bool = true) {
        let hadTask = fileSearchTask != nil
        fileSearchTask?.cancel()
        fileSearchTask = nil
        if incrementGeneration && (hadTask || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty) {
            fileSearchGeneration += 1
        }
        if fileSearchLoading {
            fileSearchLoading = false
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }
    }

    private func hideComposerPopups() {
        popupRefreshTask?.cancel()
        popupRefreshTask = nil
        if showSlashPopup {
            showSlashPopup = false
        }
        if activeSlashToken != nil {
            activeSlashToken = nil
        }
        if !slashSuggestions.isEmpty {
            slashSuggestions = []
        }
        if showFilePopup {
            showFilePopup = false
        }
        if activeAtToken != nil {
            activeAtToken = nil
        }
        if showSkillPopup {
            showSkillPopup = false
        }
        if activeDollarToken != nil {
            activeDollarToken = nil
        }
        clearFileSearchState()
    }

    private func startFileSearch(_ query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        let requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        if !fileSearchLoading {
            fileSearchLoading = true
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }

        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            guard activeAtToken?.value == query else { return }

            do {
                let matches = try await onFileSearch(query)
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = matches
                fileSearchLoading = false
                fileSearchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = []
                fileSearchLoading = false
                fileSearchError = error.localizedDescription
            }
        }
    }

    private func scheduleComposerPopupRefresh(for nextText: String) {
        popupRefreshTask?.cancel()
        let needsPopupEvaluation =
            showSlashPopup ||
            showFilePopup ||
            showSkillPopup ||
            activeSlashToken != nil ||
            activeAtToken != nil ||
            activeDollarToken != nil ||
            nextText.contains("/") ||
            nextText.contains("@") ||
            nextText.contains("$")

        guard needsPopupEvaluation else {
            hideComposerPopups()
            return
        }

        popupRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            refreshComposerPopups(for: nextText)
        }
    }

    private func refreshComposerPopups(for nextText: String) {
        let cursor = nextText.count
        if let atToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "@",
            allowEmpty: true
        ) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if showSkillPopup {
                showSkillPopup = false
            }
            if activeDollarToken != nil {
                activeDollarToken = nil
            }
            if !showFilePopup {
                showFilePopup = true
            }
            if activeAtToken != atToken {
                activeAtToken = atToken
                startFileSearch(atToken.value)
                loadPluginsIfNeeded()
            }
            return
        }

        if activeAtToken != nil || showFilePopup || fileSearchTask != nil || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty {
            activeAtToken = nil
            if showFilePopup {
                showFilePopup = false
            }
            clearFileSearchState()
        }

        if let dollarToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "$",
            allowEmpty: true
        ), isMentionQueryValid(dollarToken.value) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if !showSkillPopup {
                showSkillPopup = true
            }
            if activeDollarToken != dollarToken {
                activeDollarToken = dollarToken
            }
            if !hasAttemptedSkillMentionLoad && !skillsLoading {
                hasAttemptedSkillMentionLoad = true
                Task { await loadSkills(showErrors: false) }
            }
            return
        }

        if activeDollarToken != nil || showSkillPopup {
            activeDollarToken = nil
            if showSkillPopup {
                showSkillPopup = false
            }
        }

        guard let slashToken = currentSlashQueryContext(text: nextText, cursor: cursor) else {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            return
        }

        if activeSlashToken != slashToken {
            activeSlashToken = slashToken
        }
        let suggestions = filterSlashCommands(slashToken.query)
        if slashSuggestions != suggestions {
            slashSuggestions = suggestions
        }
        let shouldShow = !suggestions.isEmpty
        if showSlashPopup != shouldShow {
            showSlashPopup = shouldShow
        }
    }

    private func applySlashSuggestion(_ command: ComposerSlashCommand) {
        showSlashPopup = false
        activeSlashToken = nil
        slashSuggestions = []
        inputText = ""
        attachedImage = nil
        isComposerFocused = false
        executeSlashCommand(command, args: nil)
    }

    private func executeSlashCommand(_ command: ComposerSlashCommand, args: String?) {
        switch command {
        case .plan:
            onOpenModePicker()
        case .model:
            showModelSelector = true
        case .permissions:
            showPermissionsSheet = true
        case .experimental:
            showExperimentalSheet = true
            Task { await loadExperimentalFeatures() }
        case .skills:
            showSkillsSheet = true
            Task { await loadSkills() }
        case .review:
            Task { await startReview() }
        case .goal:
            Task { await handleGoalCommand(args) }
        case .rename:
            let initialName = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if initialName.isEmpty {
                let currentTitle = snapshot.threadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                renameCurrentThreadTitle = currentTitle.isEmpty ? "Untitled thread" : currentTitle
                renameDraft = ""
                showRenamePrompt = true
            } else {
                Task { await renameThread(initialName) }
            }
        case .new:
            appState.showServerPicker = true
        case .fork:
            Task { await forkConversation() }
        case .resume:
            onResumeSessions?(snapshot.threadKey.serverId)
        }
    }

    private func parseSlashCommandInvocation(_ text: String) -> (command: ComposerSlashCommand, args: String?)? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandAndArgs = trimmed.dropFirst()
        let commandName = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let command = ComposerSlashCommand(rawCommand: commandName) else { return nil }
        let args = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init)
        return (command, args)
    }

    private func startReview() async {
        do {
            _ = try await appModel.client.startReview(
                serverId: snapshot.threadKey.serverId,
                params: AppStartReviewRequest(
                    threadId: snapshot.threadKey.threadId,
                    target: .uncommittedChanges,
                    delivery: "inline"
                )
            )
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func handleGoalCommand(_ args: String?) async {
        let raw = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = raw.lowercased()
        do {
            switch lower {
            case "":
                let goal = try await appModel.client.getThreadGoal(
                    serverId: snapshot.threadKey.serverId,
                    params: AppThreadGoalGetRequest(threadId: snapshot.threadKey.threadId)
                )
                guard let goal else {
                    slashErrorMessage = "No goal is set for this thread."
                    return
                }
                slashErrorMessage = goalSummary(goal)
            case "pause":
                _ = try await appModel.client.setThreadGoal(
                    serverId: snapshot.threadKey.serverId,
                    params: AppThreadGoalSetRequest(
                        threadId: snapshot.threadKey.threadId,
                        objective: nil,
                        status: .paused,
                        tokenBudget: nil
                    )
                )
            case "resume":
                _ = try await appModel.client.setThreadGoal(
                    serverId: snapshot.threadKey.serverId,
                    params: AppThreadGoalSetRequest(
                        threadId: snapshot.threadKey.threadId,
                        objective: nil,
                        status: .active,
                        tokenBudget: nil
                    )
                )
            case "clear":
                _ = try await appModel.client.clearThreadGoal(
                    serverId: snapshot.threadKey.serverId,
                    params: AppThreadGoalClearRequest(threadId: snapshot.threadKey.threadId)
                )
            default:
                _ = try await appModel.client.setThreadGoal(
                    serverId: snapshot.threadKey.serverId,
                    params: AppThreadGoalSetRequest(
                        threadId: snapshot.threadKey.threadId,
                        objective: raw,
                        status: .active,
                        tokenBudget: nil
                    )
                )
            }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func goalSummary(_ goal: AppThreadGoal) -> String {
        var lines = [
            "Goal: \(goal.objective)",
            "Status: \(goalStatusLabel(goal.status))",
            "Tokens used: \(goal.tokensUsed)"
        ]
        if let tokenBudget = goal.tokenBudget {
            lines.append("Token budget: \(tokenBudget)")
        }
        return lines.joined(separator: "\n")
    }

    private func goalStatusLabel(_ status: AppThreadGoalStatus) -> String {
        switch status {
        case .active: return "active"
        case .paused: return "paused"
        case .budgetLimited: return "limited by budget"
        case .complete: return "complete"
        }
    }

    private func makeGoalCardActions() -> GoalCardActions {
        GoalCardActions(
            togglePause: {
                guard let current = snapshot.goal?.status else { return }
                let next: AppThreadGoalStatus
                switch current {
                case .active: next = .paused
                case .paused, .budgetLimited: next = .active
                case .complete: return
                }
                Task { await applyGoalUpdate(status: next) }
            },
            markComplete: {
                Task { await applyGoalUpdate(status: .complete) }
            },
            setObjective: { objective in
                Task { await applyGoalUpdate(objective: objective) }
            },
            setBudget: { value in
                let goal = snapshot.goal
                let resumeFromLimit = goal?.status == .budgetLimited
                    && (value ?? 0) > (goal?.tokensUsed ?? 0)
                Task {
                    await applyGoalUpdate(
                        status: resumeFromLimit ? .active : nil,
                        tokenBudget: value
                    )
                }
            },
            clear: {
                Task { await clearGoal() }
            }
        )
    }

    private func applyGoalUpdate(
        objective: String? = nil,
        status: AppThreadGoalStatus? = nil,
        tokenBudget: Int64? = nil
    ) async {
        do {
            _ = try await appModel.client.setThreadGoal(
                serverId: snapshot.threadKey.serverId,
                params: AppThreadGoalSetRequest(
                    threadId: snapshot.threadKey.threadId,
                    objective: objective,
                    status: status,
                    tokenBudget: tokenBudget
                )
            )
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func clearGoal() async {
        do {
            _ = try await appModel.client.clearThreadGoal(
                serverId: snapshot.threadKey.serverId,
                params: AppThreadGoalClearRequest(threadId: snapshot.threadKey.threadId)
            )
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func renameThread(_ newName: String) async {
        do {
            try await appModel.renameThread(
                serverId: snapshot.threadKey.serverId,
                threadId: snapshot.threadKey.threadId,
                title: newName
            )
            showRenamePrompt = false
            renameCurrentThreadTitle = ""
            renameDraft = ""
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func forkConversation() async {
        do {
            let nextKey = try await appModel.client.forkThread(
                serverId: snapshot.threadKey.serverId,
                params: AppThreadLaunchConfig(
                    agentRuntimeKind: pendingAgentRuntimeKindOverride,
                    model: pendingModelOverride,
                    approvalPolicy: appState.launchApprovalPolicy(for: snapshot.threadKey),
                    sandbox: appState.launchSandboxMode(for: snapshot.threadKey),
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ).threadForkRequest(threadId: snapshot.threadKey.threadId, cwdOverride: workDir)
            )
            appModel.store.setActiveThread(key: nextKey)
            await appModel.refreshThreadSnapshot(key: nextKey)
            let nextCwd = workDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
            onOpenConversation?(nextKey)
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func loadExperimentalFeatures() async {
        guard appModel.snapshot?.servers.first(where: { $0.serverId == snapshot.threadKey.serverId })?.canUseTransportActions == true else {
            experimentalFeatures = []
            slashErrorMessage = "Not connected to a server"
            return
        }
        experimentalFeaturesLoading = true
        defer { experimentalFeaturesLoading = false }
        do {
            let features = try await appModel.client.listExperimentalFeatures(
                serverId: snapshot.threadKey.serverId,
                params: AppListExperimentalFeaturesRequest(cursor: nil, limit: 200)
            )
            experimentalFeatures = features.sorted { lhs, rhs in
                let left = (lhs.displayName?.isEmpty == false ? lhs.displayName! : lhs.name).lowercased()
                let right = (rhs.displayName?.isEmpty == false ? rhs.displayName! : rhs.name).lowercased()
                return left < right
            }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func isExperimentalFeatureEnabled(_ featureId: String, fallback: Bool) -> Bool {
        experimentalFeatures.first(where: { $0.id == featureId })?.enabled ?? fallback
    }

    private func setExperimentalFeature(named featureName: String, enabled: Bool) async {
        guard appModel.snapshot?.servers.first(where: { $0.serverId == snapshot.threadKey.serverId })?.canUseTransportActions == true else {
            slashErrorMessage = "Not connected to a server"
            return
        }
        guard let currentIndex = experimentalFeatures.firstIndex(where: { $0.name == featureName }) else {
            return
        }
        let currentFeature = experimentalFeatures[currentIndex]
        if currentFeature.enabled != enabled {
            experimentalFeatures[currentIndex] = ExperimentalFeature(
                name: currentFeature.name,
                stage: currentFeature.stage,
                displayName: currentFeature.displayName,
                description: currentFeature.description,
                announcement: currentFeature.announcement,
                enabled: enabled,
                defaultEnabled: currentFeature.defaultEnabled
            )
        }
        do {
            _ = try await appModel.client.writeConfigValue(
                serverId: snapshot.threadKey.serverId,
                params: AppWriteConfigValueRequest(
                    keyPath: "features.\(featureName)",
                    valueJson: enabled ? "true" : "false",
                    mergeStrategy: .upsert,
                    filePath: nil,
                    expectedVersion: nil
                )
            )
        } catch {
            slashErrorMessage = error.localizedDescription
            if let rollbackIndex = experimentalFeatures.firstIndex(where: { $0.name == currentFeature.name }) {
                experimentalFeatures[rollbackIndex] = ExperimentalFeature(
                    name: currentFeature.name,
                    stage: currentFeature.stage,
                    displayName: currentFeature.displayName,
                    description: currentFeature.description,
                    announcement: currentFeature.announcement,
                    enabled: currentFeature.enabled,
                    defaultEnabled: currentFeature.defaultEnabled
                )
            }
        }
    }

    private func loadSkills(forceReload: Bool = false) async {
        await loadSkills(forceReload: forceReload, showErrors: true)
    }

    private func loadSkills(forceReload: Bool = false, showErrors: Bool) async {
        guard appModel.snapshot?.servers.first(where: { $0.serverId == snapshot.threadKey.serverId })?.canUseTransportActions == true else {
            skills = []
            mentionSkillPathsByName = [:]
            if showErrors {
                slashErrorMessage = "Not connected to a server"
            }
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let fetchedSkills = try await appModel.client.listSkills(
                serverId: snapshot.threadKey.serverId,
                params: AppListSkillsRequest(
                    cwds: [workDir],
                    forceReload: forceReload
                )
            )
            let loadedSkills = fetchedSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            skills = loadedSkills
            let validPaths = Set(loadedSkills.map { $0.path.value })
            mentionSkillPathsByName = mentionSkillPathsByName.filter { _, path in validPaths.contains(path) }
        } catch {
            if showErrors {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyFileSuggestion(_ match: FileSearchResult) {
        guard let token = activeAtToken else { return }
        let quotedPath = (match.path.contains(" ") && !match.path.contains("\"")) ? "\"\(match.path)\"" : match.path
        let replacement = "\(quotedPath) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }

    private var pluginSuggestions: [PluginSummary] {
        guard let token = activeAtToken else { return [] }
        let plugins = pluginCacheByCwd[workDir] ?? []
        guard !plugins.isEmpty else { return [] }
        let query = token.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return plugins
        }
        return plugins.filter { plugin in
            if plugin.name.lowercased().contains(query) { return true }
            if plugin.displayTitle.lowercased().contains(query) { return true }
            if let desc = plugin.interface?.shortDescription?.lowercased(), desc.contains(query) {
                return true
            }
            return plugin.marketplaceName.lowercased().contains(query)
        }
    }

    private func loadPluginsIfNeeded() {
        let cwd = workDir
        guard !pluginUnsupportedCwds.contains(cwd),
              pluginCacheByCwd[cwd] == nil,
              !pluginLoadingCwds.contains(cwd) else {
            return
        }
        pluginLoadingCwds.insert(cwd)
        Task {
            defer { pluginLoadingCwds.remove(cwd) }
            do {
                let plugins = try await appModel.client.listPlugins(
                    serverId: snapshot.threadKey.serverId,
                    params: AppListPluginsRequest(cwds: [cwd])
                )
                pluginCacheByCwd[cwd] = plugins
            } catch {
                pluginUnsupportedCwds.insert(cwd)
            }
        }
    }

    private func applyPluginSuggestion(_ plugin: PluginSummary) {
        guard let token = activeAtToken else { return }
        let replacement = "@\(plugin.name) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        let selection = PluginMentionSelection(
            name: plugin.name,
            marketplace: plugin.marketplaceName,
            displayName: plugin.interface?.displayName ?? plugin.displayTitle
        )
        if !pluginMentionSelections.contains(selection) {
            pluginMentionSelections.append(selection)
        }
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }

    private func removePluginMention(_ selection: PluginMentionSelection) {
        pluginMentionSelections.removeAll { $0 == selection }
        // Best-effort strip of the inline `@name` token from the input.
        let needle = "@\(selection.name)"
        if let range = inputText.range(of: needle) {
            var replaced = inputText
            replaced.removeSubrange(range)
            // Collapse any double-space artifact left behind.
            inputText = replaced.replacingOccurrences(of: "  ", with: " ")
        }
    }

    private var skillSuggestions: [SkillMetadata] {
        guard let token = activeDollarToken else { return [] }
        return filterSkillSuggestions(token.value)
    }

    private func filterSkillSuggestions(_ query: String) -> [SkillMetadata] {
        guard !skills.isEmpty else { return [] }
        guard !query.isEmpty else { return skills.sorted { lhs, rhs in lhs.name.lowercased() < rhs.name.lowercased() } }
        return skills
            .compactMap { skill -> (SkillMetadata, Int)? in
                let scoreFromName = fuzzyScore(candidate: skill.name, query: query)
                let scoreFromDescription = fuzzyScore(candidate: skill.description, query: query)
                let best = max(scoreFromName ?? Int.min, scoreFromDescription ?? Int.min)
                guard best != Int.min else { return nil }
                return (skill, best)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
            .map(\.0)
    }

    private func applySkillSuggestion(_ skill: SkillMetadata) {
        guard let token = activeDollarToken else { return }
        let replacement = "$\(skill.name) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        mentionSkillPathsByName[skill.name.lowercased()] = skill.path.value
        showSkillPopup = false
        activeDollarToken = nil
    }

    private func collectSkillMentionsForSubmission(_ text: String) -> [SkillMentionSelection] {
        guard !skills.isEmpty else { return [] }
        let mentionNames = extractMentionNames(text)
        guard !mentionNames.isEmpty else { return [] }

        let skillsByName = Dictionary(grouping: skills, by: { $0.name.lowercased() })
        let skillsByPath = Dictionary(grouping: skills, by: \.path.value)
        var seenPaths = Set<String>()
        var resolved: [SkillMentionSelection] = []

        for mentionName in mentionNames {
            let normalizedName = mentionName.lowercased()
            if let selectedPath = mentionSkillPathsByName[normalizedName], !selectedPath.isEmpty {
                if let selectedSkill = skillsByPath[selectedPath]?.first {
                    guard seenPaths.insert(selectedPath).inserted else { continue }
                    resolved.append(SkillMentionSelection(name: selectedSkill.name, path: selectedPath))
                    continue
                }
                mentionSkillPathsByName.removeValue(forKey: normalizedName)
            }

            guard let candidates = skillsByName[normalizedName], candidates.count == 1 else {
                continue
            }
            let match = candidates[0]
            guard seenPaths.insert(match.path.value).inserted else { continue }
            resolved.append(SkillMentionSelection(name: match.name, path: match.path.value))
        }
        return resolved
    }
}

private struct CollaborationModeSelectorSheet: View {
    let presets: [AppCollaborationModePreset]
    let selectedMode: AppModeKind
    let isLoading: Bool
    let onSelect: (AppModeKind) -> Void

    var body: some View {
        NavigationStack {
            List {
                if isLoading && presets.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading modes…")
                            .litterFont(.body)
                            .foregroundStyle(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface)
                }

                ForEach(presets, id: \.kind) { preset in
                    Button(action: { onSelect(preset.kind) }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .litterFont(.body, weight: .semibold)
                                    .foregroundStyle(LitterTheme.textPrimary)
                                if let reasoningEffort = preset.reasoningEffort {
                                    Text(collaborationModeEffortLabel(reasoningEffort))
                                        .litterFont(.caption)
                                        .foregroundStyle(LitterTheme.textSecondary)
                                }
                            }
                            Spacer()
                            if preset.kind == selectedMode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(LitterTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(LitterTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LitterTheme.surface)
            .navigationTitle("Collaboration Mode")
        }
    }
}

private func collaborationModeEffortLabel(_ effort: ReasoningEffort) -> String {
    switch effort {
    case .none:
        return "None"
    case .minimal:
        return "Minimal"
    case .low:
        return "Low"
    case .medium:
        return "Medium"
    case .high:
        return "High"
    case .xHigh:
        return "XHigh"
    }
}

enum ComposerSlashCommand: CaseIterable {
    case plan
    case model
    case permissions
    case experimental
    case skills
    case review
    case goal
    case rename
    case new
    case fork
    case resume

    var rawValue: String {
        switch self {
        case .plan: return "plan"
        case .model: return "model"
        case .permissions: return "permissions"
        case .experimental: return "experimental"
        case .skills: return "skills"
        case .review: return "review"
        case .goal: return "goal"
        case .rename: return "rename"
        case .new: return "new"
        case .fork: return "fork"
        case .resume: return "resume"
        }
    }

    var description: String {
        switch self {
        case .plan: return "switch collaboration mode"
        case .model: return "choose what model and reasoning effort to use"
        case .permissions: return "choose what Codex is allowed to do"
        case .experimental: return "toggle experimental features"
        case .skills: return "use skills to improve how Codex performs specific tasks"
        case .review: return "review my current changes and find issues"
        case .goal: return "set or manage the current thread goal"
        case .rename: return "rename the current thread"
        case .new: return "start a new chat during a conversation"
        case .fork: return "fork the current conversation into a new session"
        case .resume: return "resume a saved chat"
        }
    }

    init?(rawCommand: String) {
        switch rawCommand.lowercased() {
        case "plan", "mode", "collab": self = .plan
        case "model": self = .model
        case "permissions": self = .permissions
        case "experimental": self = .experimental
        case "skills": self = .skills
        case "review": self = .review
        case "goal": self = .goal
        case "rename": self = .rename
        case "new": self = .new
        case "fork": self = .fork
        case "resume": self = .resume
        default: return nil
        }
    }
}

enum ComposerApprovalOption: CaseIterable, Identifiable {
    case `default`
    case untrusted
    case onFailure
    case onRequest
    case never

    var id: String { wireValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .untrusted: return "Untrusted"
        case .onFailure: return "On failure"
        case .onRequest: return "On request"
        case .never: return "Never"
        }
    }

    var description: String {
        switch self {
        case .default: return "Use the thread or server default"
        case .untrusted: return "Always ask before taking action"
        case .onFailure: return "Ask only when a command fails"
        case .onRequest: return "Ask when escalation is requested"
        case .never: return "Run without asking for approval"
        }
    }

    var wireValue: String {
        switch self {
        case .default: return "inherit"
        case .untrusted: return "untrusted"
        case .onFailure: return "on-failure"
        case .onRequest: return "on-request"
        case .never: return "never"
        }
    }
}

enum ComposerSandboxOption: CaseIterable, Identifiable {
    case `default`
    case readOnly
    case workspaceWrite
    case fullAccess

    var id: String { wireValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .readOnly: return "Read only"
        case .workspaceWrite: return "Workspace write"
        case .fullAccess: return "Full access"
        }
    }

    var description: String {
        switch self {
        case .default: return "Use the thread or server default"
        case .readOnly: return "Can read files, but cannot edit them"
        case .workspaceWrite: return "Can edit files, but only in this workspace"
        case .fullAccess: return "Can edit files outside this workspace"
        }
    }

    var wireValue: String {
        switch self {
        case .default: return "inherit"
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }
}

struct ComposerTokenRange: Equatable {
    let start: Int
    let end: Int
}

struct ComposerTokenContext: Equatable {
    let value: String
    let range: ComposerTokenRange
}

private struct ComposerSlashQueryContext: Equatable {
    let query: String
    let range: ComposerTokenRange
}

private func filterSlashCommands(_ query: String) -> [ComposerSlashCommand] {
    guard !query.isEmpty else { return Array(ComposerSlashCommand.allCases) }
    return ComposerSlashCommand.allCases
        .compactMap { command -> (ComposerSlashCommand, Int)? in
            guard let score = fuzzyScore(candidate: command.rawValue, query: query) else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.rawValue < rhs.0.rawValue
        }
        .map(\.0)
}

private func fuzzyScore(candidate: String, query: String) -> Int? {
    let normalizedCandidate = candidate.lowercased()
    let normalizedQuery = query.lowercased()

    if normalizedCandidate == normalizedQuery {
        return 1000
    }
    if normalizedCandidate.hasPrefix(normalizedQuery) {
        return 900 - (normalizedCandidate.count - normalizedQuery.count)
    }
    if normalizedCandidate.contains(normalizedQuery) {
        return 700 - (normalizedCandidate.count - normalizedQuery.count)
    }

    var score = 0
    var queryIndex = normalizedQuery.startIndex
    var candidateIndex = normalizedCandidate.startIndex

    while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
        if normalizedQuery[queryIndex] == normalizedCandidate[candidateIndex] {
            score += 10
            queryIndex = normalizedQuery.index(after: queryIndex)
        }
        candidateIndex = normalizedCandidate.index(after: candidateIndex)
    }

    return queryIndex == normalizedQuery.endIndex ? score : nil
}

private let kDollarSign: UInt8 = 0x24
private let kUnderscore: UInt8 = 0x5F
private let kHyphen: UInt8 = 0x2D

private func isMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x61...0x7A, // a-z
        0x41...0x5A,  // A-Z
        0x30...0x39,  // 0-9
        kUnderscore,
        kHyphen:
        return true
    default:
        return false
    }
}

private func isMentionQueryValid(_ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return query.utf8.allSatisfy(isMentionNameByte)
}

private func extractMentionNames(_ text: String) -> [String] {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty else { return [] }

    var mentions: [String] = []
    var index = 0
    while index < bytes.count {
        guard bytes[index] == kDollarSign else {
            index += 1
            continue
        }

        if index > 0, isMentionNameByte(bytes[index - 1]) {
            index += 1
            continue
        }

        let nameStart = index + 1
        guard nameStart < bytes.count, isMentionNameByte(bytes[nameStart]) else {
            index += 1
            continue
        }

        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }

        if let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) {
            mentions.append(name)
        }
        index = nameEnd
    }

    return mentions
}

func currentPrefixedToken(
    text: String,
    cursor: Int,
    prefix: Character,
    allowEmpty: Bool
) -> ComposerTokenContext? {
    guard let tokenRange = tokenRangeAroundCursor(text: text, cursor: cursor) else { return nil }
    guard let tokenText = substring(text, within: tokenRange), tokenText.first == prefix else { return nil }
    let value = String(tokenText.dropFirst())
    if value.isEmpty && !allowEmpty {
        return nil
    }
    return ComposerTokenContext(value: value, range: tokenRange)
}

private func currentSlashQueryContext(
    text: String,
    cursor: Int
) -> ComposerSlashQueryContext? {
    let safeCursor = max(0, min(cursor, text.count))
    let firstLineEnd = text.firstIndex(of: "\n").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
    if safeCursor > firstLineEnd || firstLineEnd <= 0 {
        return nil
    }

    let firstLine = String(text.prefix(firstLineEnd))
    guard firstLine.hasPrefix("/") else { return nil }

    var commandEnd = 1
    let chars = Array(firstLine)
    while commandEnd < chars.count && !chars[commandEnd].isWhitespace {
        commandEnd += 1
    }
    if safeCursor > commandEnd {
        return nil
    }

    let query = commandEnd > 1 ? String(chars[1..<commandEnd]) : ""
    let rest = commandEnd < chars.count ? String(chars[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

    if query.isEmpty {
        if !rest.isEmpty {
            return nil
        }
    } else if query.contains("/") {
        return nil
    }

    return ComposerSlashQueryContext(query: query, range: ComposerTokenRange(start: 0, end: commandEnd))
}

private func tokenRangeAroundCursor(
    text: String,
    cursor: Int
) -> ComposerTokenRange? {
    guard !text.isEmpty else { return nil }

    let safeCursor = max(0, min(cursor, text.count))
    let chars = Array(text)

    if safeCursor < chars.count, chars[safeCursor].isWhitespace {
        var index = safeCursor
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        if index < chars.count {
            var end = index
            while end < chars.count && !chars[end].isWhitespace {
                end += 1
            }
            return ComposerTokenRange(start: index, end: end)
        }
    }

    var start = safeCursor
    while start > 0 && !chars[start - 1].isWhitespace {
        start -= 1
    }

    var end = safeCursor
    while end < chars.count && !chars[end].isWhitespace {
        end += 1
    }

    if end <= start {
        return nil
    }
    return ComposerTokenRange(start: start, end: end)
}

func replacingRange(
    in text: String,
    with range: ComposerTokenRange,
    replacement: String
) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    var copy = text
    copy.replaceSubrange(lower..<upper, with: replacement)
    return copy
}

private func substring(_ text: String, within range: ComposerTokenRange) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    return String(text[lower..<upper])
}

private func index(in text: String, offset: Int) -> String.Index? {
    guard offset >= 0, offset <= text.count else { return nil }
    return text.index(text.startIndex, offsetBy: offset)
}

struct PendingUserInputPromptView: View {
    let request: PendingUserInputRequest
    let onSubmit: ([String: [String]]) -> Void
    let onDismiss: () -> Void

    @State private var selectedAnswers: [String: String] = [:]
    @State private var otherAnswers: [String: String] = [:]

    private var promptTitle: String {
        let firstQuestion = request.questions.first?.question.lowercased() ?? ""
        if firstQuestion.contains("implement") && firstQuestion.contains("plan") {
            return "Implement Plan"
        }
        return "Input Required"
    }

    private var requesterLabel: String? {
        AgentLabelFormatter.format(
            nickname: request.requesterAgentNickname,
            role: request.requesterAgentRole
        )
    }

    private var unsupportedQuestions: [PendingUserInputQuestion] {
        request.questions.filter { question in
            question.isSecret || (!question.isOtherAllowed && question.options.isEmpty)
        }
    }

    private var canSubmit: Bool {
        unsupportedQuestions.isEmpty &&
        request.questions.allSatisfy { !resolvedAnswer(for: $0).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(LitterTheme.warning)
                Text(promptTitle)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss input request")
            }

            if let requesterLabel {
                Text(requesterLabel)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }

            ForEach(request.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .litterFont(.caption2, weight: .bold)
                            .foregroundColor(LitterTheme.textMuted)
                    }

                    Text(question.question)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textPrimary)

                    if question.isSecret || (!question.isOtherAllowed && question.options.isEmpty) {
                        Text("This prompt type is not fully supported in the current iOS client.")
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !question.options.isEmpty {
                                // ViewThatFits + VStack fallback so long
                                // option labels wrap to a new row instead
                                // of squeezing a short option into a narrow
                                // column with character-by-character wrapping.
                                let optionButtons = ForEach(question.options, id: \.label) { option in
                                    let isSelected =
                                        selectedAnswers[question.id] == option.label &&
                                        trimmedOtherAnswer(for: question).isEmpty
                                    Button {
                                        selectedAnswers[question.id] = option.label
                                        otherAnswers[question.id] = ""
                                    } label: {
                                        Text(option.label)
                                            .litterFont(.caption2, weight: .semibold)
                                            .foregroundColor(isSelected ? Color.black : LitterTheme.textPrimary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(isSelected ? LitterTheme.accent : LitterTheme.surface.opacity(0.8))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { optionButtons }
                                    VStack(alignment: .leading, spacing: 8) { optionButtons }
                                }
                            }

                            if question.isOtherAllowed {
                                TextField(
                                    question.options.isEmpty ? "Enter response" : "Other response",
                                    text: otherAnswerBinding(for: question)
                                )
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(LitterTheme.surface.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }

            if canSubmit {
                Button("Submit") {
                    let answers = request.questions.reduce(into: [String: [String]]()) { result, question in
                        let answer = resolvedAnswer(for: question)
                        guard !answer.isEmpty else { return }
                        result[question.id] = [answer]
                    }
                    onSubmit(answers)
                }
                .litterFont(.caption, weight: .semibold)
                .foregroundColor(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LitterTheme.accent)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }

    private func otherAnswerBinding(for question: PendingUserInputQuestion) -> Binding<String> {
        Binding(
            get: { otherAnswers[question.id, default: ""] },
            set: { newValue in
                otherAnswers[question.id] = newValue
            }
        )
    }

    private func trimmedOtherAnswer(for question: PendingUserInputQuestion) -> String {
        otherAnswers[question.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedAnswer(for question: PendingUserInputQuestion) -> String {
        let other = trimmedOtherAnswer(for: question)
        if !other.isEmpty {
            return other
        }
        return selectedAnswers[question.id, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PlanImplementationPromptView: View {
    let onImplement: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundColor(LitterTheme.accent)
                Text("Implement Plan")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
            }

            Text("Switch to Default mode and implement the plan?")
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSecondary)

            HStack(spacing: 8) {
                Button {
                    onImplement()
                } label: {
                    Text("Implement")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(Color.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(LitterTheme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Text("Stay in Plan")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(LitterTheme.surface.opacity(0.8))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }
}

struct QueuedFollowUpsPreviewView: View {
    let previews: [AppQueuedFollowUpPreview]
    let onSteer: (AppQueuedFollowUpPreview) -> Void
    let onDelete: (AppQueuedFollowUpPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                Text("Queued Next")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
                Text("\(previews.count)")
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LitterTheme.surface.opacity(0.9))
                    .clipShape(Capsule())
            }

            ForEach(previews, id: \.id) { preview in
                let style = QueuedFollowUpPreviewStyle.forKind(preview.kind)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: style.symbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(style.title)
                                .litterFont(.caption2, weight: .semibold)
                        }
                        .foregroundColor(style.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(style.tint.opacity(0.14))
                        .clipShape(Capsule())

                        Text(preview.text)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if preview.kind == .message || preview.kind == .pendingSteer {
                        Button(action: { onSteer(preview) }) {
                            HStack(spacing: 6) {
                                if preview.kind == .pendingSteer {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Steering")
                                        .litterFont(.caption, weight: .semibold)
                                } else {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Steer")
                                        .litterFont(.caption, weight: .semibold)
                                }
                            }
                            .foregroundColor(preview.kind == .pendingSteer ? LitterTheme.accent : LitterTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(LitterTheme.surface.opacity(0.96))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(preview.kind == .pendingSteer)
                    }

                    Button(action: { onDelete(preview) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(style.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(style.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(12)
        .background(LitterTheme.codeBackground.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct QueuedFollowUpPreviewStyle {
    let title: String
    let symbol: String
    let tint: Color
    let background: Color
    let border: Color

    static func forKind(_ kind: AppQueuedFollowUpKind) -> Self {
        switch kind {
        case .message:
            let tint = LitterTheme.accent
            return Self(
                title: "Queued message",
                symbol: "text.bubble.fill",
                tint: tint,
                background: tint.opacity(0.08),
                border: tint.opacity(0.24)
            )
        case .pendingSteer:
            let tint = LitterTheme.accentStrong
            return Self(
                title: "Steer queued",
                symbol: "arrowshape.turn.up.right.fill",
                tint: tint,
                background: tint.opacity(0.10),
                border: tint.opacity(0.28)
            )
        case .retryingSteer:
            let tint = LitterTheme.warning
            return Self(
                title: "Retrying steer",
                symbol: "arrow.clockwise",
                tint: tint,
                background: tint.opacity(0.10),
                border: tint.opacity(0.28)
            )
        }
    }
}

private struct ConversationLoadingIndicator: View {
    let label: String
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Text(label)
            .litterFont(.body, weight: .medium)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        LitterTheme.textSecondary.opacity(0.4),
                        LitterTheme.textSecondary.opacity(0.7),
                        LitterTheme.textSecondary.opacity(0.4),
                    ],
                    startPoint: UnitPoint(x: shimmerOffset - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: shimmerOffset + 0.3, y: 0.5)
                )
            )
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: shimmerOffset)
            .onAppear {
                shimmerOffset = 2
            }
    }
}

private struct MinigameLaunchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitterTheme.accent)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(LitterTheme.surface.opacity(0.9))
                        .overlay(
                            Circle()
                                .stroke(LitterTheme.accent.opacity(0.3), lineWidth: 0.5)
                        )
                )
                .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play a minigame while waiting")
    }
}

struct TypingIndicator: View {
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Text("Thinking")
            .litterFont(.body, weight: .medium)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        LitterTheme.textSecondary.opacity(0.4),
                        LitterTheme.accent,
                        LitterTheme.textSecondary.opacity(0.4),
                    ],
                    startPoint: UnitPoint(x: shimmerOffset - 0.3, y: 0.5),
                    endPoint: UnitPoint(x: shimmerOffset + 0.3, y: 0.5)
                )
            )
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: shimmerOffset)
            .padding(.leading, 12)
            .onAppear {
                shimmerOffset = 2
            }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct SubagentBreadcrumbBar: View {
    let thread: AppThreadSnapshot
    let topInset: CGFloat
    let onNavigateToParent: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateToParent) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .litterFont(size: 10, weight: .semibold)
                    Text("Parent")
                        .litterFont(.caption, weight: .medium)
                }
                .foregroundColor(LitterTheme.accent)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 14)
                .background(LitterTheme.border)

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .litterFont(size: 10, weight: .semibold)
                    .foregroundColor(LitterTheme.success)
                Text(thread.agentDisplayLabel ?? "Agent")
                    .litterFont(.caption, weight: .medium)
                    .foregroundColor(LitterTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, topInset + 8)
        .background(
            LitterTheme.surface.opacity(0.85)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Debug Overlay

private struct ConversationDebugButton: View {
    let topInset: CGFloat
    let activeThreadKey: ThreadKey
    @Environment(AppModel.self) private var appModel
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: "ant")
                    .litterFont(size: 12, weight: .semibold)
                    .foregroundColor(LitterTheme.accent)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(LitterTheme.surface.opacity(0.85))
                            .background(Circle().fill(.ultraThinMaterial))
                    )
            }
            .buttonStyle(.plain)

            if DebugSettings.shared.enabled {
                if MessageRecorder.shared.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .modifier(PulseModifier())
                }
                if MessageRecorder.shared.isReplaying {
                    Image(systemName: "play.fill")
                        .litterFont(size: 8, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.top, topInset + 12)
        .popover(isPresented: $showPopover) {
            DebugPopoverContent(activeThreadKey: activeThreadKey)
                .environment(appModel)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct PulseModifier: ViewModifier {
    @State private var pulse = false
    func body(content: Content) -> some View {
        content
            .opacity(pulse ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

private struct DebugPopoverContent: View {
    @Environment(AppModel.self) private var appModel
    let activeThreadKey: ThreadKey
    @State private var debugSettings = DebugSettings.shared
    @State private var recorder = MessageRecorder.shared
    @State private var recordings: [URL] = []

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug")
                .litterFont(.subheadline, weight: .semibold)
                .foregroundColor(LitterTheme.textPrimary)

            Toggle(isOn: Binding(
                get: { debugSettings.disableMarkdown },
                set: { debugSettings.disableMarkdown = $0 }
            )) {
                Text("Disable Markdown")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textPrimary)
            }
            .tint(LitterTheme.accent)

            Toggle(isOn: Binding(
                get: { debugSettings.showTurnMetrics },
                set: { debugSettings.showTurnMetrics = $0 }
            )) {
                Text("Turn Metrics")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textPrimary)
            }
            .tint(LitterTheme.accent)

            if debugSettings.enabled {
                Divider().background(LitterTheme.border)

                // MARK: Recording controls
                Text("Recording")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)

                HStack(spacing: 8) {
                    if recorder.isRecording {
                        Button {
                            recorder.stopRecording(store: appModel.store)
                            recordings = recorder.listRecordings()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .litterFont(.caption, weight: .medium)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    } else if recorder.isReplaying {
                        Button {
                            recorder.stopReplay()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .litterFont(.caption, weight: .medium)
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            recorder.startRecording(store: appModel.store)
                        } label: {
                            Label("Record", systemImage: "record.circle")
                                .litterFont(.caption, weight: .medium)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !recordings.isEmpty && !recorder.isRecording && !recorder.isReplaying {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recordings, id: \.absoluteString) { url in
                            HStack {
                                Button {
                                    recorder.startReplay(url: url, store: appModel.store, targetKey: activeThreadKey)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill")
                                            .litterFont(size: 9, weight: .semibold)
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .litterFont(.caption2)
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(LitterTheme.accent)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    recorder.deleteRecording(url: url)
                                    recordings = recorder.listRecordings()
                                } label: {
                                    Image(systemName: "xmark")
                                        .litterFont(size: 9, weight: .semibold)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        }
        .frame(width: 260)
        .frame(maxHeight: 500)
        .background(LitterTheme.surface)
        .onAppear { recordings = recorder.listRecordings() }
    }
}

private struct TurnDebugOverlay: ViewModifier {
    let turnId: String

    // Debug is already gated at the call site via `.turnDebugOverlay(turnId:)`,
    // so this modifier only runs when debug overlays should actually render —
    // no inner if/else branch means SwiftUI no longer has to diff a
    // `_ConditionalContent<Modified, Content>` per turn on every body eval.
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    VStack(alignment: .leading) {
                        Text("\(turnId.prefix(8)) h=\(Int(geo.size.height)) y=\(Int(geo.frame(in: .global).minY))")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .padding(2)
                            .background(.black.opacity(0.7))
                        Spacer()
                    }
                }
            )
            .border(Color.red.opacity(0.3), width: 1)
    }
}

extension View {
    /// Applies `TurnDebugOverlay` only when debug settings opt into turn
    /// metrics. Reading the flag here — rather than inside the modifier's
    /// body — means the overlay node doesn't participate in the view tree
    /// at all for the common (debug-off) case, saving per-turn per-diff
    /// modifier evaluation cost.
    @ViewBuilder
    fileprivate func turnDebugOverlay(turnId: String) -> some View {
        if DebugSettings.shared.enabled && DebugSettings.shared.showTurnMetrics {
            self.modifier(TurnDebugOverlay(turnId: turnId))
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Conversation") {
    LitterPreviewScene(appModel: LitterPreviewData.makeConversationAppModel(messages: LitterPreviewData.longConversation)) {
        ContentView()
    }
}
#endif
