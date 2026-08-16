import SwiftUI
import PhotosUI
import UIKit
import os

/// Attachment + attachment-presentation state for the home composer.
///
/// Lifted off `@State` and onto one reference object so the presentation
/// modifier stack can live in a view whose only stored property is a stable
/// class reference (see `HomeComposerPresentationHost`). `inputText` sits above
/// those modifiers, so previously every keystroke rebuilt the sheet,
/// photosPicker, fileImporter, fullScreenCover and onChange chain.
@Observable
final class HomeComposerAttachmentState {
    var attachedImages: [UIImage] = []
    var attachedFiles: [ComposerFileAttachment] = []
    var showAttachMenu = false
    var showPhotoPicker = false
    var showCamera = false
    var showFileImporter = false
    var selectedPhotos: [PhotosPickerItem] = []

    var hasAttachment: Bool {
        !attachedImages.isEmpty || !attachedFiles.isEmpty
    }

    func clearAttachments() {
        attachedImages = []
        attachedFiles = []
    }

    /// Appends up to `ComposerAttachmentLimits.maxImages`; extra images are
    /// dropped rather than replacing what is already attached.
    func appendImage(_ image: UIImage) {
        guard attachedImages.count < ComposerAttachmentLimits.maxImages else { return }
        attachedImages.append(image)
    }

    func removeImage(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        attachedImages.remove(at: index)
    }

    func apply(_ picked: PickedComposerFile) {
        switch picked {
        case .image(let image):
            appendImage(image)
        case .file(let file):
            if !attachedFiles.contains(file) {
                attachedFiles.append(file)
            }
        }
    }

    /// Bridge for `CameraView`, which hands back a single optional `UIImage`.
    /// Appends rather than replacing so a camera capture stacks onto whatever
    /// is already attached.
    @MainActor
    var cameraImageBinding: Binding<UIImage?> {
        Binding(
            get: { [weak self] in self?.attachedImages.last },
            set: { [weak self] newImage in
                guard let self, let newImage else { return }
                self.appendImage(newImage)
            }
        )
    }

    @MainActor
    func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if attachedImages.count >= ComposerAttachmentLimits.maxImages { break }
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                attachedImages.append(image)
            }
        }
        selectedPhotos = []
    }
}

/// Carries every presentation modifier the home composer needs. Split out of
/// `HomeComposerView.body` so the modifier chain is not re-evaluated whenever
/// the draft text changes: this struct stores only a stable object reference,
/// which SwiftUI compares pointer-wise and then skips the update entirely.
private struct HomeComposerPresentationHost: View {
    @Bindable var attach: HomeComposerAttachmentState

    private var attachSheetDetentHeight: CGFloat {
        let showsCamera = !LitterPlatform.isCatalyst
        let count = 2 + (showsCamera ? 1 : 0)
        return count >= 3 ? 260 : 210
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: $attach.showAttachMenu) {
                ConversationComposerAttachSheet(
                    onPickPhotoLibrary: {
                        attach.showAttachMenu = false
                        attach.showPhotoPicker = true
                    },
                    onChooseFile: {
                        attach.showAttachMenu = false
                        attach.showFileImporter = true
                    },
                    onTakePhoto: LitterPlatform.isCatalyst ? nil : {
                        attach.showAttachMenu = false
                        attach.showCamera = true
                    }
                )
                .presentationDetents([.height(attachSheetDetentHeight)])
                .presentationDragIndicator(.visible)
            }
            .photosPicker(
                isPresented: $attach.showPhotoPicker,
                selection: $attach.selectedPhotos,
                maxSelectionCount: ComposerAttachmentLimits.maxImages,
                matching: .images
            )
            .fileImporter(
                isPresented: $attach.showFileImporter,
                allowedContentTypes: ConversationAttachmentSupport.supportedFileContentTypes,
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result,
                      let url = urls.first else { return }
                guard let picked = ConversationAttachmentSupport.loadPickedFile(at: url) else { return }
                attach.apply(picked)
            }
            .onChange(of: attach.selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task { await attach.loadSelectedPhotos(items) }
            }
            .fullScreenCover(isPresented: $attach.showCamera) {
                CameraView(image: attach.cameraImageBinding)
                    .ignoresSafeArea()
            }
    }
}


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

    @State private var inputText = ""
    @State private var attach = HomeComposerAttachmentState()
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
    // Skill ($prefix) autocomplete state — mirrors ConversationView's pattern
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false
    @State private var skillUnsupportedCwds: Set<String> = []
    @State private var skillLoadingCwds: Set<String> = []
    @State private var mentionSkillPathsByName: [String: String] = [:]
    @State private var activeDollarToken: ComposerTokenContext?
    @State private var showSkillPopup = false
    @State private var hasAttemptedSkillLoad = false
    /// Plain `@State`, not `@FocusState`: the composer's text view is a
    /// UIKit `UITextView` wrapped in a UIViewRepresentable, not a SwiftUI
    /// focusable view. Using `@FocusState` without a matching `.focused()`
    /// modifier causes SwiftUI's focus manager to immediately revert any
    /// programmatic `true` back to `false`, which made the keyboard close
    /// the moment it opened.
    @State private var isComposerFocused: Bool = false
    @State private var composerSelectionRange = NSRange(location: 0, length: 0)

    private var resolvedTranscriptionServerId: String? {
        project?.serverId ?? transcriptionServerId
    }

    private var isActive: Bool {
        isComposerFocused
            || !inputText.isEmpty
            || attach.hasAttachment
            || voiceManager.isRecording
            || voiceManager.isTranscribing
    }

    var body: some View {
        @Bindable var attach = attach
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
                attachedImages: attach.attachedImages,
                attachedFiles: attach.attachedFiles,
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
                showAttachMenu: $attach.showAttachMenu,
                onClearAttachment: { attach.clearAttachments() },
                onRemoveImage: { index in attach.removeImage(at: index) },
                onRemoveFileAttachment: { file in
                    attach.attachedFiles.removeAll { $0 == file }
                },
                onRespondToPendingUserInput: { _ in },
                onSteerQueuedFollowUp: { _ in },
                onDeleteQueuedFollowUp: { _ in },
                onRemovePluginMention: removePluginMention,
                onPasteImage: { image in attach.appendImage(image) },
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
                if showSkillPopup, project != nil {
                    HomeSkillAutocompletePopup(
                        skills: skillSuggestions,
                        isLoading: skillsLoading,
                        onSelect: applySkillSuggestion
                    )
                } else if showPluginPopup, project != nil {
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
            guard let picked = urls.lazy.compactMap({ ConversationAttachmentSupport.loadPickedFile(at: $0) }).first else {
                return false
            }
            attach.apply(picked)
            return true
        }
        .dropDestination(for: Data.self) { items, _ in
            let images = items.compactMap { UIImage(data: $0) }
            guard !images.isEmpty else { return false }
            for image in images {
                attach.appendImage(image)
            }
            return true
        }
        // All attachment presentation lives behind a stable object reference so
        // the sheet/picker/importer/cover chain is not rebuilt per keystroke.
        .background {
            HomeComposerPresentationHost(attach: attach)
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
        let images = attach.attachedImages
        let files = attach.attachedFiles
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else { return }

        guard !isSubmitting else { return }
        guard let project else {
            errorMessage = "Pick a project before sending."
            return
        }

        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            var createdThreadKey: ThreadKey?
            do {
                guard try await appModel.ensureLocalAuthForThreadStart(serverId: project.serverId) else {
                    return
                }
                inputText = ""
                attach.clearAttachments()
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
                createdThreadKey = threadKey
                onThreadCreated(threadKey)
                RecentDirectoryStore.shared.record(path: project.cwd, for: project.serverId)
                let preparedAttachments = images.compactMap(ConversationAttachmentSupport.prepareImage)
                var additionalInputs: [AppUserInput] = []
                let mentionsToSend = collectPluginMentionsForSubmission(text)
                let skillMentions = collectSkillMentionsForSubmission(text)
                pluginMentionSelections = []
                showPluginPopup = false
                activeAtToken = nil
                showSkillPopup = false
                activeDollarToken = nil
                for skill in skillMentions {
                    additionalInputs.append(
                        AppUserInput.skill(name: skill.name, path: AbsolutePath(value: skill.path))
                    )
                }
                for mention in mentionsToSend {
                    additionalInputs.append(
                        AppUserInput.mention(name: mention.name, path: mention.path)
                    )
                }
                for prepared in preparedAttachments {
                    additionalInputs.append(prepared.userInput)
                }
                let payload = AppComposerPayload(
                    text: text,
                    additionalInputs: additionalInputs,
                    fileAttachments: files,
                    approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
                    sandboxPolicy: appState.turnSandboxPolicy(for: threadKey),
                    model: modelOverride,
                    effort: effortOverride,
                    serviceTier: nil
                )
                try await appModel.startTurn(key: threadKey, payload: payload)
                await appModel.refreshThreadSnapshot(key: threadKey)
            } catch {
                if let createdThreadKey {
                    appModel.reportHandoffTurnError(
                        key: createdThreadKey,
                        message: error.localizedDescription
                    )
                } else {
                    errorMessage = error.localizedDescription
                }
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
            showSkillPopup = false
            activeDollarToken = nil
            return
        }
        let cursor = nextText.count

        // $skill token
        if let dollarToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "$",
            allowEmpty: true
        ), isMentionQueryValid(dollarToken.value) {
            // Suppress @plugin popup if both are somehow active
            if showPluginPopup { showPluginPopup = false }
            if activeAtToken != nil { activeAtToken = nil }
            if !showSkillPopup { showSkillPopup = true }
            if activeDollarToken != dollarToken {
                activeDollarToken = dollarToken
            }
            if !hasAttemptedSkillLoad && !skillsLoading {
                hasAttemptedSkillLoad = true
                Task { await loadSkills(showErrors: false) }
            }
            return
        }

        if activeDollarToken != nil || showSkillPopup {
            activeDollarToken = nil
            if showSkillPopup { showSkillPopup = false }
        }

        // @plugin token
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

    // MARK: - Skill autocomplete

    private func loadSkills(forceReload: Bool = false, showErrors: Bool = false) async {
        guard let project else { return }
        let cwd = project.cwd
        guard !skillUnsupportedCwds.contains(cwd) else {
            skills = []
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let fetched = try await appModel.client.listSkills(
                serverId: project.serverId,
                params: AppListSkillsRequest(cwds: [cwd], forceReload: forceReload)
            )
            let loaded = fetched.sorted { $0.name.lowercased() < $1.name.lowercased() }
            skills = loaded
            let validPaths = Set(loaded.map { $0.path.value })
            mentionSkillPathsByName = mentionSkillPathsByName.filter { _, path in validPaths.contains(path) }
        } catch {
            if showErrors {
                errorMessage = error.localizedDescription
            }
            skillUnsupportedCwds.insert(cwd)
        }
    }

    private var skillSuggestions: [SkillMetadata] {
        guard let token = activeDollarToken else { return [] }
        return filterSkillSuggestions(token.value)
    }

    private func filterSkillSuggestions(_ query: String) -> [SkillMetadata] {
        guard !skills.isEmpty else { return [] }
        guard !query.isEmpty else {
            return skills.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
        return skills
            .compactMap { skill -> (SkillMetadata, Int)? in
                let scoreFromName = fuzzyScore(candidate: skill.name, query: query)
                let scoreFromDescription = fuzzyScore(candidate: skill.description, query: query)
                let best = max(scoreFromName ?? Int.min, scoreFromDescription ?? Int.min)
                guard best != Int.min else { return nil }
                return (skill, best)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
            .map(\.0)
    }

    private func applySkillSuggestion(_ skill: SkillMetadata) {
        guard let token = activeDollarToken else { return }
        let replacement = "$\(skill.name) "
        if let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) {
            inputText = updated
        }
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
            guard let candidates = skillsByName[normalizedName], candidates.count == 1 else { continue }
            let match = candidates[0]
            guard seenPaths.insert(match.path.value).inserted else { continue }
            resolved.append(SkillMentionSelection(name: match.name, path: match.path.value))
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

private struct HomeSkillAutocompletePopup: View {
    let skills: [SkillMetadata]
    let isLoading: Bool
    let onSelect: (SkillMetadata) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && skills.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(LitterTheme.accent)
                    Text("Loading skills…")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if skills.isEmpty {
                Text("No matching skills")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                let visible = Array(skills.prefix(8))
                ForEach(Array(visible.enumerated()), id: \.element) { item in
                    let skill = item.element
                    VStack(spacing: 0) {
                        Button {
                            onSelect(skill)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "wand.and.stars")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("$\(skill.name)")
                                        .litterFont(.footnote, weight: .semibold)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    if let desc = skill.shortDescription, !desc.isEmpty {
                                        Text(desc)
                                            .litterFont(.caption)
                                            .foregroundColor(LitterTheme.textSecondary)
                                            .lineLimit(1)
                                    } else if !skill.description.isEmpty {
                                        Text(skill.description)
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
