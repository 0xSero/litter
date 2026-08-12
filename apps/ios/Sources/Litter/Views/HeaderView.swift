import SafariServices
import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let thread: AppThreadSnapshot
    @State private var pulsing = false
    @AppStorage("fastMode") private var fastMode = false

    private var isRegularSurface: Bool {
        LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass)
    }

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    private var headerPermissionPreset: AppThreadPermissionPreset {
        let approval = appState.launchApprovalPolicy(for: thread.key) ?? thread.effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: thread.key) ?? thread.effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox)
    }

    var body: some View {
        Button {
            appState.showModelSelector.toggle()
        } label: {
            expandedHeaderLabel
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: isRegularSurface ? 320 : 240, alignment: .center)
        }
        .layoutPriority(-1)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("header.modelPickerButton")
        .popover(
            isPresented: Binding(
                get: { appState.showModelSelector },
                set: { appState.showModelSelector = $0 }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ConversationModelPickerPanel(thread: thread)
                .environment(appModel)
                .environment(appState)
                .presentationCompactAdaptation(.popover)
        }
        .task(id: thread.key) {
            await loadModelsIfNeeded()
        }
    }

    private var expandedHeaderLabel: some View {
        Group {
            if isRegularSurface {
                VStack(spacing: 2) {
                    primaryHeaderRow
                    secondaryHeaderRow
                }
            } else {
                compactHeaderRow
            }
        }
    }

    /// An iPhone toolbar cannot comfortably hold a back button, two action
    /// buttons, model picker, reasoning effort, and working directory. Keep
    /// the tappable picker to one calm, readable row; its popover still has
    /// the full set of choices.
    private var compactHeaderRow: some View {
        HStack(spacing: 5) {
            statusDot
            Text(sessionModelLabel)
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if sessionReasoningLabel != "default" {
                Text(sessionReasoningLabel)
                    .foregroundColor(LitterTheme.textSecondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(LitterFont.styled(size: 9, weight: .semibold))
                .foregroundColor(LitterTheme.textSecondary)
                .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
        }
        .font(LitterFont.styled(size: 13, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var primaryHeaderRow: some View {
        HStack(spacing: 6) {
            statusDot

            if fastMode {
                Image(systemName: "bolt.fill")
                    .font(LitterFont.styled(size: 10, weight: .semibold))
                    .foregroundColor(LitterTheme.warning)
            }

            Text(sessionModelLabel)
                .foregroundColor(LitterTheme.textPrimary)
                .allowsTightening(true)
            Text(sessionReasoningLabel)
                .foregroundColor(LitterTheme.textSecondary)
                .allowsTightening(true)
            Image(systemName: "chevron.down")
                .font(LitterFont.styled(size: 10, weight: .semibold))
                .foregroundColor(LitterTheme.textSecondary)
                .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
        }
        .font(LitterFont.styled(size: 14, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(isRegularSurface ? 1.0 : 0.75)
    }

    private var secondaryHeaderRow: some View {
        HStack(spacing: 6) {
            Text(sessionDirectoryLabel)
                .font(LitterFont.styled(size: 11, weight: .semibold))
                .foregroundColor(LitterTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if thread.collaborationMode == .plan {
                Text("plan")
                    .font(LitterFont.styled(size: 11, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(LitterTheme.accent)
                    .clipShape(Capsule())
            }

            if headerPermissionPreset == .fullAccess {
                Image(systemName: "lock.open.fill")
                    .font(LitterFont.styled(size: 10, weight: .semibold))
                    .foregroundColor(LitterTheme.danger)
            }

        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: 6, height: 6)
            .opacity(shouldPulse ? (pulsing ? 0.3 : 1.0) : 1.0)
            .animation(
                shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: pulsing
            )
            .onChange(of: shouldPulse) { _, pulse in
                pulsing = pulse
            }
    }

    private var shouldPulse: Bool {
        guard let transportState = server?.transportState else { return false }
        return transportState == .connecting || transportState == .unresponsive
    }

    private var statusDotColor: Color {
        guard let server else {
            return LitterTheme.textMuted
        }
        switch server.transportState {
        case .connecting, .unresponsive:
            return .orange
        case .connected:
            if server.isLocal {
                switch server.account {
                case .chatgpt?, .apiKey?:
                    return LitterTheme.success
                case nil:
                    return LitterTheme.danger
                }
            }
            return server.requiresOpenaiAuth && server.account == nil ? .orange : LitterTheme.success
        case .disconnected:
            return LitterTheme.danger
        case .unknown:
            return LitterTheme.textMuted
        }
    }

    private var sessionModelLabel: String {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingModel.isEmpty {
            if let model = availableModels.first(where: {
                modelMatchesSelection(
                    $0,
                    pendingModel,
                    runtime: appState.selectedAgentRuntimeKind
                )
            }) {
                return modelPickerDisplayName(model)
            }
            return pendingModel
        }

        let threadModel = thread.displayModelLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty { return threadModel }

        return "litter"
    }

    private var sessionReasoningLabel: String {
        let pendingReasoning = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingReasoning.isEmpty { return pendingReasoning }

        let threadReasoning = thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty { return threadReasoning }

        // Fall back to the model's default reasoning effort from the loaded model list.
        let currentModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = availableModels.first(where: {
            modelMatchesSelection(
                $0,
                currentModel,
                runtime: thread.agentRuntimeKind
            )
        }),
           !model.supportedReasoningEfforts.isEmpty,
           !model.defaultReasoningEffort.wireValue.isEmpty {
            return model.defaultReasoningEffort.wireValue
        }

        return "default"
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = (thread.info.cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentDirectory.isEmpty {
            let isLocal = appModel.isLocalServer(serverId: thread.key.serverId)
            return PathDisplay.display(currentDirectory, isLocal: isLocal)
        }

        return "~"
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return currentThreadModelSelectionId
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var selectedAgentRuntimeKindBinding: Binding<AgentRuntimeKind?> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return appState.selectedAgentRuntimeKind }
                return currentThreadAgentRuntimeKind
            },
            set: { appState.selectedAgentRuntimeKind = $0 }
        )
    }

    private var currentThreadModelSelectionId: String {
        let currentModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentModel.isEmpty else { return "" }
        return currentModel
    }

    private var currentThreadAgentRuntimeKind: AgentRuntimeKind? {
        thread.agentRuntimeKind
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }

    private func loadModelsIfNeeded() async {
        await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
    }
}

struct ConversationModelPickerPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    var body: some View {
        InlineModelSelectorView(
            models: availableModels,
            catalogLoaded: server?.availableModels != nil,
            catalogError: appModel.modelCatalogError(for: thread.key.serverId),
            onRetryModels: {
                Task {
                    await appModel.loadAvailableModelsIfNeeded(
                        serverId: thread.key.serverId,
                        force: true
                    )
                }
            },
            selectedModel: selectedModelBinding,
            selectedAgentRuntimeKind: selectedAgentRuntimeKindBinding,
            reasoningEffort: reasoningEffortBinding,
            threadKey: thread.key,
            collaborationMode: thread.collaborationMode,
            effectiveApprovalPolicy: thread.effectiveApprovalPolicy,
            effectiveSandboxPolicy: thread.effectiveSandboxPolicy,
            isReasoningEffortLocked: thread.ampReasoningEffortLocked,
            showsBackground: false,
            onDismiss: {
                appState.showModelSelector = false
            }
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .task(id: thread.key) {
            await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var selectedAgentRuntimeKindBinding: Binding<AgentRuntimeKind?> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return appState.selectedAgentRuntimeKind }
                return thread.agentRuntimeKind
            },
            set: { appState.selectedAgentRuntimeKind = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }
}

struct ConversationToolbarControls: View {
    enum Control {
        case reload
        case info
    }

    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    let control: Control
    var onInfo: (() -> Void)?
    @State private var isReloading = false
    @State private var remoteAuthSession: RemoteAuthSession?

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    var body: some View {
        Group {
            switch control {
            case .reload:
                reloadButton
            case .info:
                infoButton
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .sheet(item: $remoteAuthSession) { session in
            InAppSafariView(url: session.url)
                .ignoresSafeArea()
        }
        .onChange(of: server?.account != nil) { _, isLoggedIn in
            if isLoggedIn {
                remoteAuthSession = nil
            }
        }
    }

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                defer { isReloading = false }
                if await handleRemoteLoginIfNeeded() {
                    return
                }
                if server?.requiresOpenaiAuth == true, server?.account == nil {
                    appState.showSettings = true
                } else {
                    do {
                        let nextKey = try await appModel.refreshThreadIncludingTurns(key: thread.key)
                        appModel.store.setActiveThread(
                            key: nextKey
                        )
                    } catch {
                        // `AppModel` records the failure; keep the toolbar interaction quiet.
                    }
                }
            }
        } label: {
            reloadButtonLabel
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || server?.isConnected != true)
    }

    @ViewBuilder
    private var reloadButtonLabel: some View {
        if isReloading {
            ProgressView()
                .scaleEffect(0.7)
                .tint(LitterTheme.accent)
        } else {
            Image(systemName: "arrow.clockwise")
                .font(LitterFont.styled(size: 16, weight: .semibold))
                .foregroundColor(server?.isConnected == true ? LitterTheme.accent : LitterTheme.textMuted)
        }
    }

    private var infoButton: some View {
        Button {
            onInfo?()
        } label: {
            Image(systemName: "info.circle")
                .font(LitterFont.styled(size: 16, weight: .semibold))
                .foregroundColor(LitterTheme.accent)
        }
        .accessibilityIdentifier("header.infoButton")
    }

    private func handleRemoteLoginIfNeeded() async -> Bool {
        guard let server, !server.isLocal else {
            return false
        }
        guard server.requiresOpenaiAuth, server.account == nil else {
            return false
        }
        do {
            let authURL = try await appModel.client.startRemoteSshOauthLogin(
                serverId: server.serverId
            )
            if let url = URL(string: authURL) {
                await MainActor.run {
                    remoteAuthSession = RemoteAuthSession(url: url)
                }
            }
        } catch {}
        return true
    }
}

private struct RemoteAuthSession: Identifiable {
    let id = UUID()
    let url: URL
}

func modelMatchesSelection(
    _ model: ModelInfo,
    _ selection: String,
    runtime: AgentRuntimeKind? = nil
) -> Bool {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if let runtime, model.agentRuntimeKind != runtime { return false }
    return model.id == trimmed || model.model == trimmed
}

private func defaultReasoningEffortSelection(for model: ModelInfo) -> String {
    model.supportedReasoningEfforts.isEmpty ? "" : model.defaultReasoningEffort.wireValue
}

/// Allowlist of model "mode" names the runtime advertises (e.g. Amp's
/// `smart` / `rush` / `deep`). Pulled from `capabilities.visible_modes`
/// in the alleycat manifest so the rule is per-agent, not Amp-hardcoded.
private func visibleModeNames(for kind: AgentRuntimeKind) -> Set<String>? {
    kind.metadata?.capabilities?.visibleModes.map(Set.init)
}

/// Strip the optional agent-name prefix (`<kind>/` or `<kind>:`) the
/// remote sometimes adds when reporting modes, so the bare mode name
/// matches the allowlist.
private func normalizedModeName(_ value: String, kind: AgentRuntimeKind) -> String {
    var out = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let prefixes = ["\(kind)/", "\(kind):", "\(kind)\\"]
    for prefix in prefixes where out.hasPrefix(prefix) {
        out = String(out.dropFirst(prefix.count))
    }
    return out
}

private func modeName(for model: ModelInfo) -> String {
    let kind = model.agentRuntimeKind
    let idMode = normalizedModeName(model.id, kind: kind)
    if !idMode.isEmpty { return idMode }
    return normalizedModeName(model.model, kind: kind)
}

func modelPickerDisplayName(_ model: ModelInfo) -> String {
    if visibleModeNames(for: model.agentRuntimeKind) != nil {
        let mode = modeName(for: model)
        if !mode.isEmpty { return mode }
    }
    return model.displayName.isEmpty ? model.id : model.displayName
}

private struct ModelProviderGroup: Identifiable {
    let key: String
    let name: String
    let models: [ModelInfo]

    var id: String { key }
}

private func modelProviderName(_ model: ModelInfo) -> String {
    guard let provider = model.providerId else { return model.agentRuntimeKind.titleDisplayLabel }
    return provider.split(whereSeparator: { $0 == "-" || $0 == "_" })
        .map { $0.capitalized }.joined(separator: " ")
}

private func modelNameWithinProvider(_ model: ModelInfo) -> String {
    var name = modelPickerDisplayName(model)
    if model.id.contains("/"), let catalog = model.id.split(separator: "/", maxSplits: 1).first {
        let suffix = " (\(catalog))"
        if name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
        }
    }
    if let providerId = model.providerId, name.hasPrefix("\(providerId)/") {
        name = String(name.dropFirst(providerId.count + 1))
    }
    return name
}

private func modelProviderGroups(for models: [ModelInfo]) -> [ModelProviderGroup] {
    Dictionary(grouping: models) {
        let provider = $0.providerId.flatMap { $0.isEmpty ? nil : "provider:\($0)" } ?? "runtime"
        return "\($0.agentRuntimeKind):\(provider)"
    }
        .map { key, groupModels in
            let model = groupModels[0]
            return ModelProviderGroup(
                key: key,
                name: model.providerId?.isEmpty != false
                    ? model.agentRuntimeKind.titleDisplayLabel
                    : "\(model.agentRuntimeKind.titleDisplayLabel) · \(modelProviderName(model))",
                models: groupModels
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

@ViewBuilder
private func modelCatalogNotice(
    loaded: Bool,
    error: String?,
    hasModels: Bool,
    horizontalPadding: CGFloat,
    onRetry: @escaping () -> Void
) -> some View {
    let message = error ?? (!loaded ? "Loading models..." : (hasModels ? nil : "No models available"))
    if let message {
        VStack(spacing: 8) {
            Text(message)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if error != nil {
                Button("Retry", action: onRetry)
                    .litterFont(.caption, weight: .semibold)
                    .foregroundColor(LitterTheme.accent)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 16)
    }
}

private func isVisibleModelOption(_ model: ModelInfo) -> Bool {
    guard let modes = visibleModeNames(for: model.agentRuntimeKind) else {
        return true
    }
    return modes.contains(modeName(for: model))
}

struct InlineModelSelectorView: View {
    let models: [ModelInfo]
    var catalogLoaded = false
    var catalogError: String?
    var onRetryModels: () -> Void = {}
    @Binding var selectedModel: String
    @Binding var selectedAgentRuntimeKind: AgentRuntimeKind?
    @Binding var reasoningEffort: String
    /// `nil` indicates the view is being used before a thread exists (home
    /// composer). In that case, plan-mode selection is stored as a pending
    /// app-state preference that the caller applies after `startThread`.
    var threadKey: ThreadKey?
    var collaborationMode: AppModeKind = .default
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
    var isReasoningEffortLocked = false
    var showsBackground = true
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false
    @State private var modelSearchQuery = ""
    @State private var modelSearchIndex = ModelSearchIndex()
    @State private var selectedRuntimeFilter: AgentRuntimeKind?
    @State private var initializedRuntimeFilter = false
    var onDismiss: () -> Void

    private var activeModelSearchIndex: ModelSearchIndex {
        if modelSearchIndex.isEmpty, !runtimeScopedModels.isEmpty {
            return ModelSearchIndex(models: runtimeScopedModels)
        }
        return modelSearchIndex
    }

    private var visibleModels: [ModelInfo] {
        models.filter(isVisibleModelOption)
    }

    private var runtimeBuckets: [RuntimeModelBucket] {
        runtimeModelBuckets(for: visibleModels)
    }

    private var activeRuntimeFilter: AgentRuntimeKind? {
        guard let selectedRuntimeFilter,
              runtimeBuckets.contains(where: { $0.kind == selectedRuntimeFilter }) else {
            return nil
        }
        return selectedRuntimeFilter
    }

    private var runtimeScopedModels: [ModelInfo] {
        guard let activeRuntimeFilter else { return visibleModels }
        return visibleModels.filter { $0.agentRuntimeKind == activeRuntimeFilter }
    }

    private var currentModel: ModelInfo? {
        if let match = visibleModels.first(where: {
            modelMatchesSelection(
                $0,
                selectedModel,
                runtime: selectedAgentRuntimeKind
            )
        }) {
            return match
        }
        // When shown from the home composer, `selectedModel` may be empty
        // because the user hasn't picked yet. Fall back to the default
        // model so the reasoning effort row has something to render.
        return visibleModels.first(where: { $0.isDefault }) ?? visibleModels.first
    }

    /// Effective collaboration mode: live thread value when we have one,
    /// otherwise the pre-thread pending selection tracked on `appState`.
    private var effectiveCollaborationMode: AppModeKind {
        threadKey == nil ? appState.pendingCollaborationMode : collaborationMode
    }

    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: threadKey) ?? effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: threadKey) ?? effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox) == .fullAccess
    }

    private var selectedRuntimeSupportsPermissionOverrides: Bool {
        let runtime = selectedAgentRuntimeKind ?? currentModel?.agentRuntimeKind
        return runtime?.supportsThreadPermissionOverrides ?? true
    }

    var body: some View {
        let visibleModels = activeModelSearchIndex.results(matching: modelSearchQuery)
        let selectedModelIsAmp: Bool = {
            guard let model = currentModel else { return false }
            return visibleModeNames(for: model.agentRuntimeKind) != nil
        }()
        let effectiveReasoningEfforts = isReasoningEffortLocked ? [] : (currentModel?.supportedReasoningEfforts ?? [])

        VStack(spacing: 0) {
            modelSearchField
            runtimeFilterRow

            ScrollView {
                LazyVStack(spacing: 0) {
                    modelCatalogNotice(
                        loaded: catalogLoaded,
                        error: catalogError,
                        hasModels: !self.visibleModels.isEmpty,
                        horizontalPadding: 16,
                        onRetry: onRetryModels
                    )

                    if !self.visibleModels.isEmpty && visibleModels.isEmpty {
                        Text("No matching models")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                    }

                    ForEach(modelProviderGroups(for: visibleModels)) { group in
                        Text(group.name.uppercased())
                            .litterFont(.caption2, weight: .semibold)
                            .foregroundColor(LitterTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(group.models, id: \.runtimeScopedID) { model in
                            Button {
                                selectedModel = model.id
                                selectedAgentRuntimeKind = model.agentRuntimeKind
                                if isReasoningEffortLocked && visibleModeNames(for: model.agentRuntimeKind) != nil {
                                    reasoningEffort = ""
                                } else {
                                    reasoningEffort = defaultReasoningEffortSelection(for: model)
                                }
                                if threadKey != nil { onDismiss() }
                            } label: {
                                HStack {
                                    ModelRuntimeIcon(kind: model.agentRuntimeKind)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(modelNameWithinProvider(model))
                                                .litterFont(.footnote)
                                                .foregroundColor(LitterTheme.textPrimary)
                                            if model.isDefault {
                                                Text("default")
                                                    .litterFont(.caption2, weight: .medium)
                                                    .foregroundColor(LitterTheme.accent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(LitterTheme.accent.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(model.description)
                                            .litterFont(.caption2)
                                            .foregroundColor(LitterTheme.textSecondary)
                                    }
                                    Spacer()
                                    if modelMatchesSelection(
                                        model,
                                        selectedModel,
                                        runtime: selectedAgentRuntimeKind
                                    ) {
                                        Image(systemName: "checkmark")
                                            .litterFont(size: 12, weight: .medium)
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            if model.id != group.models.last?.id {
                                Divider().background(LitterTheme.separator).padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if isReasoningEffortLocked && selectedModelIsAmp {
                Divider().background(LitterTheme.separator).padding(.horizontal, 12)

                Text("Reasoning effort is locked after the first message.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else if !effectiveReasoningEfforts.isEmpty {
                Divider().background(LitterTheme.separator).padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(effectiveReasoningEfforts) { effort in
                            Button {
                                reasoningEffort = effort.reasoningEffort.wireValue
                                onDismiss()
                            } label: {
                                Text(effort.reasoningEffort.wireValue)
                                    .litterFont(.caption2, weight: .medium)
                                    .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            Divider().background(LitterTheme.separator).padding(.horizontal, 12)

            HStack(spacing: 6) {
                Button {
                    let current = effectiveCollaborationMode
                    let next: AppModeKind = current == .plan ? .default : .plan
                    if let threadKey {
                        Task {
                            try? await appModel.store.setThreadCollaborationMode(
                                key: threadKey, mode: next
                            )
                        }
                    } else {
                        appState.pendingCollaborationMode = next
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Plan")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(effectiveCollaborationMode == .plan ? .black : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(effectiveCollaborationMode == .plan ? LitterTheme.accent : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                Button {
                    fastMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Fast")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(fastMode ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fastMode ? LitterTheme.warning : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                if selectedRuntimeSupportsPermissionOverrides {
                    Button {
                        if isFullAccess {
                            appState.setPermissions(approvalPolicy: "on-request", sandboxMode: "workspace-write", for: threadKey)
                        } else {
                            appState.setPermissions(approvalPolicy: "never", sandboxMode: "danger-full-access", for: threadKey)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isFullAccess ? "lock.open.fill" : "lock.fill")
                                .litterFont(size: 9, weight: .semibold)
                            Text(isFullAccess ? "Full Access" : "Supervised")
                                .litterFont(.caption2, weight: .medium)
                        }
                        .foregroundColor(isFullAccess ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isFullAccess ? LitterTheme.danger : LitterTheme.surfaceLight)
                        .clipShape(Capsule())
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(showsBackground ? LitterTheme.surface : Color.clear)
        .onAppear {
            synchronizeRuntimeFilter()
            resetModelSearchIndex()
        }
        .onChange(of: models) { _, newModels in
            synchronizeRuntimeFilter()
            modelSearchIndex = ModelSearchIndex(models: newModels.filter(isVisibleModelOption).filtered(by: activeRuntimeFilter))
        }
        .onChange(of: selectedRuntimeFilter) { _, _ in
            resetModelSearchIndex()
        }
        .onChange(of: selectedAgentRuntimeKind) { _, _ in
            synchronizeRuntimeFilter()
        }
    }

    private var modelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LitterTheme.textMuted)
            TextField("Search models", text: $modelSearchQuery)
                .litterFont(.caption)
                .foregroundStyle(LitterTheme.textPrimary)
                .tint(LitterTheme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !modelSearchQuery.isEmpty {
                Button { modelSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var runtimeFilterRow: some View {
        if runtimeBuckets.count > 1 {
            RuntimeFilterRow(
                buckets: runtimeBuckets,
                totalCount: visibleModels.count,
                selectedRuntime: activeRuntimeFilter,
                onSelect: { selectedRuntimeFilter = $0 }
            )
            .padding(.bottom, 6)
        }
    }

    private func resetModelSearchIndex() {
        modelSearchIndex = ModelSearchIndex(models: runtimeScopedModels)
    }

    private func synchronizeRuntimeFilter() {
        if !initializedRuntimeFilter {
            let initial = selectedAgentRuntimeKind ?? currentModel?.agentRuntimeKind
            if let initial, runtimeBuckets.contains(where: { $0.kind == initial }) {
                selectedRuntimeFilter = initial
            }
            initializedRuntimeFilter = true
            return
        }
        if let selectedRuntimeFilter,
           !runtimeBuckets.contains(where: { $0.kind == selectedRuntimeFilter }) {
            self.selectedRuntimeFilter = nil
        }
    }
}

private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct ModelSelectorSheet: View {
    let models: [ModelInfo]
    var catalogLoaded = false
    var catalogError: String?
    var onRetryModels: () -> Void = {}
    @Binding var selectedModel: String
    @Binding var selectedAgentRuntimeKind: AgentRuntimeKind?
    @Binding var reasoningEffort: String
    var isReasoningEffortLocked = false
    @AppStorage("fastMode") private var fastMode = false
    @State private var modelSearchQuery = ""
    @State private var modelSearchIndex = ModelSearchIndex()
    @State private var selectedRuntimeFilter: AgentRuntimeKind?
    @State private var initializedRuntimeFilter = false

    private var currentModel: ModelInfo? {
        visibleModels.first {
            modelMatchesSelection(
                $0,
                selectedModel,
                runtime: selectedAgentRuntimeKind
            )
        }
    }

    private var visibleModels: [ModelInfo] {
        models.filter(isVisibleModelOption)
    }

    private var runtimeBuckets: [RuntimeModelBucket] {
        runtimeModelBuckets(for: visibleModels)
    }

    private var activeRuntimeFilter: AgentRuntimeKind? {
        guard let selectedRuntimeFilter,
              runtimeBuckets.contains(where: { $0.kind == selectedRuntimeFilter }) else {
            return nil
        }
        return selectedRuntimeFilter
    }

    private var runtimeScopedModels: [ModelInfo] {
        guard let activeRuntimeFilter else { return visibleModels }
        return visibleModels.filter { $0.agentRuntimeKind == activeRuntimeFilter }
    }

    private var activeModelSearchIndex: ModelSearchIndex {
        if modelSearchIndex.isEmpty, !runtimeScopedModels.isEmpty {
            return ModelSearchIndex(models: runtimeScopedModels)
        }
        return modelSearchIndex
    }

    var body: some View {
        let visibleModels = activeModelSearchIndex.results(matching: modelSearchQuery)
        let selectedModelIsAmp: Bool = {
            guard let model = currentModel else { return false }
            return visibleModeNames(for: model.agentRuntimeKind) != nil
        }()
        let effectiveReasoningEfforts = isReasoningEffortLocked ? [] : (currentModel?.supportedReasoningEfforts ?? [])

        ScrollView {
            LazyVStack(spacing: 0) {
                modelSearchField
                runtimeFilterRow

                modelCatalogNotice(
                    loaded: catalogLoaded,
                    error: catalogError,
                    hasModels: !self.visibleModels.isEmpty,
                    horizontalPadding: 20,
                    onRetry: onRetryModels
                )

                if !self.visibleModels.isEmpty && visibleModels.isEmpty {
                    Text("No matching models")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                }

                ForEach(modelProviderGroups(for: visibleModels)) { group in
                    Text(group.name.uppercased())
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(group.models, id: \.runtimeScopedID) { model in
                        Button {
                            selectedModel = model.id
                            selectedAgentRuntimeKind = model.agentRuntimeKind
                            let usesModes = visibleModeNames(for: model.agentRuntimeKind) != nil
                            if isReasoningEffortLocked && usesModes {
                                reasoningEffort = ""
                            } else {
                                reasoningEffort = defaultReasoningEffortSelection(for: model)
                            }
                        } label: {
                            HStack {
                                ModelRuntimeIcon(kind: model.agentRuntimeKind)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(modelNameWithinProvider(model))
                                            .litterFont(.footnote)
                                            .foregroundColor(LitterTheme.textPrimary)
                                        if model.isDefault {
                                            Text("default")
                                                .litterFont(.caption2, weight: .medium)
                                                .foregroundColor(LitterTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(LitterTheme.accent.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(model.description)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                if modelMatchesSelection(
                                    model,
                                    selectedModel,
                                    runtime: selectedAgentRuntimeKind
                                ) {
                                    Image(systemName: "checkmark")
                                        .litterFont(size: 12, weight: .medium)
                                        .foregroundColor(LitterTheme.accent)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        }
                        if model.id != group.models.last?.id {
                            Divider().background(LitterTheme.separator).padding(.leading, 20)
                        }
                    }
                }

                if isReasoningEffortLocked && selectedModelIsAmp {
                    Text("Reasoning effort is locked after the first message.")
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else if !effectiveReasoningEfforts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(effectiveReasoningEfforts) { effort in
                                Button {
                                    reasoningEffort = effort.reasoningEffort.wireValue
                                } label: {
                                    Text(effort.reasoningEffort.wireValue)
                                        .litterFont(.caption2, weight: .medium)
                                        .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }

                Divider().background(LitterTheme.separator).padding(.leading, 20)

                HStack(spacing: 6) {
                    Button {
                        fastMode.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .litterFont(size: 9, weight: .semibold)
                            Text("Fast")
                                .litterFont(.caption2, weight: .medium)
                        }
                        .foregroundColor(fastMode ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(fastMode ? LitterTheme.warning : LitterTheme.surfaceLight)
                        .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            }
        }
        .padding(.top, 20)
        .background(.ultraThinMaterial)
        .onAppear {
            synchronizeRuntimeFilter()
            resetModelSearchIndex()
        }
        .onChange(of: models) { _, newModels in
            synchronizeRuntimeFilter()
            modelSearchIndex = ModelSearchIndex(models: newModels.filter(isVisibleModelOption).filtered(by: activeRuntimeFilter))
        }
        .onChange(of: selectedRuntimeFilter) { _, _ in
            resetModelSearchIndex()
        }
        .onChange(of: selectedAgentRuntimeKind) { _, _ in
            synchronizeRuntimeFilter()
        }
    }

    private var modelSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LitterTheme.textMuted)
            TextField("Search models", text: $modelSearchQuery)
                .litterFont(.body)
                .foregroundStyle(LitterTheme.textPrimary)
                .tint(LitterTheme.accent)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !modelSearchQuery.isEmpty {
                Button { modelSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LitterTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var runtimeFilterRow: some View {
        if runtimeBuckets.count > 1 {
            RuntimeFilterRow(
                buckets: runtimeBuckets,
                totalCount: visibleModels.count,
                selectedRuntime: activeRuntimeFilter,
                onSelect: { selectedRuntimeFilter = $0 }
            )
            .padding(.bottom, 10)
        }
    }

    private func resetModelSearchIndex() {
        modelSearchIndex = ModelSearchIndex(models: runtimeScopedModels)
    }

    private func synchronizeRuntimeFilter() {
        if !initializedRuntimeFilter {
            let initial = selectedAgentRuntimeKind ?? currentModel?.agentRuntimeKind
            if let initial, runtimeBuckets.contains(where: { $0.kind == initial }) {
                selectedRuntimeFilter = initial
            }
            initializedRuntimeFilter = true
            return
        }
        if let selectedRuntimeFilter,
           !runtimeBuckets.contains(where: { $0.kind == selectedRuntimeFilter }) {
            self.selectedRuntimeFilter = nil
        }
    }
}

private struct RuntimeModelBucket: Identifiable {
    let kind: AgentRuntimeKind
    let count: Int

    var id: AgentRuntimeKind { kind }
}

private func runtimeModelBuckets(for models: [ModelInfo]) -> [RuntimeModelBucket] {
    let grouped = Dictionary(grouping: models, by: \.agentRuntimeKind)
    return AgentRuntimeKind.presentationOrder.compactMap { kind in
        guard let models = grouped[kind], !models.isEmpty else { return nil }
        return RuntimeModelBucket(kind: kind, count: models.count)
    }
}

private extension [ModelInfo] {
    func filtered(by runtime: AgentRuntimeKind?) -> [ModelInfo] {
        guard let runtime else { return self }
        return filter { $0.agentRuntimeKind == runtime }
    }
}

private struct RuntimeFilterRow: View {
    let buckets: [RuntimeModelBucket]
    let totalCount: Int
    let selectedRuntime: AgentRuntimeKind?
    let onSelect: (AgentRuntimeKind?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                RuntimeFilterPill(
                    label: "All",
                    count: totalCount,
                    selected: selectedRuntime == nil,
                    onTap: { onSelect(nil) }
                )
                ForEach(buckets) { bucket in
                    RuntimeFilterPill(
                        label: bucket.kind.titleDisplayLabel,
                        count: bucket.count,
                        kind: bucket.kind,
                        selected: selectedRuntime == bucket.kind,
                        onTap: { onSelect(bucket.kind) }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct RuntimeFilterPill: View {
    let label: String
    let count: Int
    var kind: AgentRuntimeKind? = nil
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if let kind {
                    AgentIconView(kind: kind, size: 12)
                }
                Text("\(label) \(count)")
                    .lineLimit(1)
            }
            .litterFont(.caption2, weight: .medium)
            .foregroundColor(selected ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? LitterTheme.accent : LitterTheme.surfaceLight)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ModelSearchIndex {
    private struct Row {
        let model: ModelInfo
        let searchableText: String
    }

    private static let maxResults = 80

    private var rows: [Row] = []

    var isEmpty: Bool {
        rows.isEmpty
    }

    init() {}

    init(models: [ModelInfo]) {
        rows = models.map { model in
            Row(
                model: model,
                searchableText: [
                    model.id,
                    model.model,
                    model.agentRuntimeKind.displayLabel,
                    model.agentRuntimeKind.titleDisplayLabel,
                    modelPickerDisplayName(model),
                    model.description
                ]
                .joined(separator: "\n")
                .lowercased()
            )
        }
    }

    func results(matching query: String) -> [ModelInfo] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return Array(rows.prefix(Self.maxResults).map(\.model))
        }

        var matches: [ModelInfo] = []
        matches.reserveCapacity(min(Self.maxResults, rows.count))
        for row in rows where row.searchableText.contains(normalizedQuery) {
            matches.append(row.model)
            if matches.count == Self.maxResults {
                break
            }
        }
        return matches
    }
}

private struct ModelRuntimeIcon: View {
    let kind: AgentRuntimeKind

    var body: some View {
        AgentIconView(kind: kind, size: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(kind.displayLabel)
    }
}

#if DEBUG
#Preview("Header") {
    let appModel = LitterPreviewData.makeConversationAppModel()
    LitterPreviewScene(appModel: appModel) {
        HeaderView(thread: appModel.snapshot!.threads[0])
    }
}
#endif
