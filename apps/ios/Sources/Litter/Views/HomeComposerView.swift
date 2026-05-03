import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import os

/// Composer variant for the home screen. When a project is selected, typing
/// and hitting send creates a new thread on (project.serverId, project.cwd)
/// and submits the initial turn. User stays on home — the new thread appears
/// in the task list and streams in place.
struct HomeComposerView: View {
    let project: AppProject?
    let transcriptionServerId: String?
    let onThreadCreated: (ThreadKey) -> Void
    /// Fires when the composer becomes "active" (keyboard up, text/image
    /// entered, or voice recording/transcribing) or returns to idle.
    var onActiveChange: ((Bool) -> Void)? = nil
    /// When true, the composer requests keyboard focus the moment it
    /// appears. Used when the view is revealed by tapping `+`.
    var autoFocus: Bool = false

    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var inputText = ""
    @State private var attachedImage: UIImage?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var pluginCacheByCwd: [String: [PluginSummary]] = [:]
    @State private var pluginUnsupportedCwds: Set<String> = []
    @State private var pluginLoadingCwds: Set<String> = []
    @State private var pluginMentionSelections: [PluginMentionSelection] = []
    @State private var activeAtToken: ComposerTokenContext?
    @State private var showPluginPopup = false
    @State private var popupRefreshTask: Task<Void, Never>?
    /// Plain `@State`, not `@FocusState`: the composer's text view is a
    /// UIKit `UITextView` wrapped in a UIViewRepresentable, not a SwiftUI
    /// focusable view. Using `@FocusState` without a matching `.focused()`
    /// modifier causes SwiftUI's focus manager to immediately revert any
    /// programmatic `true` back to `false`, which made the keyboard close
    /// the moment it opened.
    @State private var isComposerFocused: Bool = false
    @State private var composerSelectionRange = NSRange(location: 0, length: 0)

    private var isDisabled: Bool { project == nil }
    private var resolvedTranscriptionServerId: String? {
        project?.serverId ?? transcriptionServerId
    }

    private var attachSheetDetentHeight: CGFloat {
        let showsFile = LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass)
        let showsCamera = !LitterPlatform.isCatalyst
        let count = 1 + (showsFile ? 1 : 0) + (showsCamera ? 1 : 0)
        return count >= 3 ? 260 : 210
    }

    private var isActive: Bool {
        isComposerFocused
            || !inputText.isEmpty
            || attachedImage != nil
            || voiceManager.isRecording
            || voiceManager.isTranscribing
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitterTheme.warning)
                    Text(errorMessage)
                        .litterFont(.caption)
                        .foregroundStyle(LitterTheme.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        self.errorMessage = nil
                        isComposerFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            ConversationComposerContentView(
                attachedImage: attachedImage,
                collaborationMode: .default,
                activePlanProgress: nil,
                pendingUserInputRequest: nil,
                hasPendingPlanImplementation: false,
                activeTaskSummary: nil,
                queuedFollowUps: [],
                pluginMentions: pluginMentionSelections,
                rateLimits: nil,
                contextPercent: nil,
                isTurnActive: isSubmitting,
                showModeChip: false,
                voiceManager: voiceManager,
                allowsVoiceInput: project != nil,
                showAttachMenu: $showAttachMenu,
                onClearAttachment: { attachedImage = nil },
                onRespondToPendingUserInput: { _ in },
                onSteerQueuedFollowUp: { _ in },
                onDeleteQueuedFollowUp: { _ in },
                onRemovePluginMention: removePluginMention,
                onPasteImage: { image in attachedImage = image },
                onOpenModePicker: {},
                onSendText: handleSend,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: {},
                inputText: $inputText,
                isComposerFocused: Binding(
                    get: { isComposerFocused },
                    set: { isComposerFocused = $0 }
                ),
                composerSelectionRange: $composerSelectionRange
            )
            .overlay(alignment: .bottom) {
                if showPluginPopup, project != nil {
                    HomePluginAutocompletePopup(
                        plugins: filteredPluginSuggestions,
                        onSelect: applyPluginSuggestion
                    )
                }
            }
        }
        .onChange(of: inputText) { _, newValue in
            scheduleHomePopupRefresh(for: newValue)
        }
        .onChange(of: isActive) { _, active in
            onActiveChange?(active)
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
        .sheet(isPresented: $showAttachMenu) {
            ConversationComposerAttachSheet(
                onPickPhotoLibrary: {
                    showAttachMenu = false
                    showPhotoPicker = true
                },
                onChooseFile: LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass) ? {
                    showAttachMenu = false
                    showFileImporter = true
                } : nil,
                onTakePhoto: LitterPlatform.isCatalyst ? nil : {
                    showAttachMenu = false
                    showCamera = true
                }
            )
            .presentationDetents([.height(attachSheetDetentHeight)])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let url = urls.first else { return }
            attachedImage = ConversationAttachmentSupport.loadImageFile(at: url)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadSelectedPhoto(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $attachedImage)
                .ignoresSafeArea()
        }
        .task {
            // Focus as early as possible so the keyboard rises in parallel
            // with the glass-morph spring — the two animations then feel
            // like one fluid motion. A tiny 40ms yield lets the view land
            // in the window tree; the UIViewRepresentable picks up focus on
            // its next `updateUIView` pass. Re-issue once after the spring
            // settles as a safety net for edge cases where the first pass
            // fired before the window attachment.
            guard autoFocus else { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
            isComposerFocused = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !isComposerFocused {
                isComposerFocused = true
            }
        }
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        guard !text.isEmpty || image != nil else { return }
        guard !isSubmitting else { return }
        guard let project else {
            errorMessage = "Pick a project before sending."
            return
        }

        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                guard try await appModel.ensureLocalAuthForThreadStart(serverId: project.serverId) else {
                    return
                }
                inputText = ""
                attachedImage = nil
                composerSelectionRange = NSRange(location: 0, length: 0)
                isComposerFocused = false

                let pendingModel = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelOverride = pendingModel.isEmpty ? nil : pendingModel
                let agentRuntimeOverride = modelOverride == nil ? nil : appState.preferredAgentRuntimeKind
                let pendingEffort = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                let effortOverride = ReasoningEffort(wireValue: pendingEffort.isEmpty ? nil : pendingEffort)
                let launchConfig = AppThreadLaunchConfig(
                    agentRuntimeKind: agentRuntimeOverride,
                    model: modelOverride,
                    approvalPolicy: appState.launchApprovalPolicy(for: nil),
                    sandbox: appState.launchSandboxMode(for: nil),
                    developerInstructions: nil,
                    persistExtendedHistory: true
                )
                let threadKey = try await appModel.client.startThread(
                    serverId: project.serverId,
                    params: launchConfig.threadStartRequest(
                        cwd: project.cwd,
                        dynamicTools: appModel.localGenerativeUiToolSpecs(for: project.serverId)
                    )
                )
                RecentDirectoryStore.shared.record(path: project.cwd, for: project.serverId)
                let preparedAttachment = image.flatMap(ConversationAttachmentSupport.prepareImage)
                var additionalInputs: [AppUserInput] = []
                let mentionsToSend = collectPluginMentionsForSubmission(text)
                pluginMentionSelections = []
                showPluginPopup = false
                activeAtToken = nil
                for mention in mentionsToSend {
                    additionalInputs.append(
                        AppUserInput.mention(name: mention.name, path: mention.path)
                    )
                }
                if let preparedAttachment {
                    additionalInputs.append(preparedAttachment.userInput)
                }
                let payload = AppComposerPayload(
                    text: text,
                    additionalInputs: additionalInputs,
                    approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
                    sandboxPolicy: appState.turnSandboxPolicy(for: threadKey),
                    model: modelOverride,
                    effort: effortOverride,
                    serviceTier: nil
                )
                try await appModel.startTurn(key: threadKey, payload: payload)
                await appModel.refreshThreadSnapshot(key: threadKey)
                onThreadCreated(threadKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else { return }
            voiceManager.startRecording()
        }
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            attachedImage = image
        }
        selectedPhoto = nil
    }

    private func stopVoiceRecording() {
        guard let serverId = resolvedTranscriptionServerId else {
            voiceManager.cancelRecording()
            return
        }
        Task {
            let auth = try? await appModel.client.authStatus(
                serverId: serverId,
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

    // MARK: - Plugin autocomplete

    private var filteredPluginSuggestions: [PluginSummary] {
        guard let project else { return [] }
        let plugins = pluginCacheByCwd[project.cwd] ?? []
        guard !plugins.isEmpty else { return [] }
        let query = (activeAtToken?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return plugins }
        return plugins.filter { plugin in
            if plugin.name.lowercased().contains(query) { return true }
            if plugin.displayTitle.lowercased().contains(query) { return true }
            if let desc = plugin.interface?.shortDescription?.lowercased(), desc.contains(query) {
                return true
            }
            return plugin.marketplaceName.lowercased().contains(query)
        }
    }

    private func scheduleHomePopupRefresh(for nextText: String) {
        popupRefreshTask?.cancel()
        popupRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            refreshHomePopup(for: nextText)
        }
    }

    private func refreshHomePopup(for nextText: String) {
        guard project != nil else {
            showPluginPopup = false
            activeAtToken = nil
            return
        }
        let cursor = nextText.count
        if let atToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "@",
            allowEmpty: true
        ) {
            if activeAtToken != atToken {
                activeAtToken = atToken
                loadPluginsIfNeeded()
            }
            showPluginPopup = true
        } else if showPluginPopup || activeAtToken != nil {
            showPluginPopup = false
            activeAtToken = nil
        }
    }

    private func loadPluginsIfNeeded() {
        guard let project else { return }
        let cwd = project.cwd
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
                    serverId: project.serverId,
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
        if let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) {
            inputText = updated
        }
        let selection = PluginMentionSelection(
            name: plugin.name,
            marketplace: plugin.marketplaceName,
            displayName: plugin.interface?.displayName ?? plugin.displayTitle
        )
        if !pluginMentionSelections.contains(selection) {
            pluginMentionSelections.append(selection)
        }
        showPluginPopup = false
        activeAtToken = nil
    }

    private func removePluginMention(_ selection: PluginMentionSelection) {
        pluginMentionSelections.removeAll { $0 == selection }
        let needle = "@\(selection.name)"
        if let range = inputText.range(of: needle) {
            var replaced = inputText
            replaced.removeSubrange(range)
            inputText = replaced.replacingOccurrences(of: "  ", with: " ")
        }
    }

    private func collectPluginMentionsForSubmission(_ text: String) -> [PluginMentionSelection] {
        guard !pluginMentionSelections.isEmpty else { return [] }
        let lowered = text.lowercased()
        var seen = Set<String>()
        var resolved: [PluginMentionSelection] = []
        for selection in pluginMentionSelections {
            guard lowered.contains("@\(selection.name.lowercased())") else { continue }
            guard seen.insert(selection.path).inserted else { continue }
            resolved.append(selection)
        }
        return resolved
    }
}

private struct HomePluginAutocompletePopup: View {
    let plugins: [PluginSummary]
    let onSelect: (PluginSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if plugins.isEmpty {
                Text("No plugins")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                let visible = Array(plugins.prefix(8))
                ForEach(Array(visible.enumerated()), id: \.element.id) { item in
                    let plugin = item.element
                    VStack(spacing: 0) {
                        Button {
                            onSelect(plugin)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.displayTitle)
                                        .litterFont(.footnote, weight: .semibold)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    if let subtitle = plugin.interface?.shortDescription, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .litterFont(.caption)
                                            .foregroundColor(LitterTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .background(LitterTheme.border)
                            .opacity(item.offset < visible.count - 1 ? 1 : 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(LitterTheme.surface.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitterTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 56)
    }
}
