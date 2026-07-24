import SwiftUI

/// Small tap-to-open model picker for the home composer bar, styled to
/// match `ProjectChip` so the two sit together above the input. Reads +
/// writes the persisted home defaults (`appState.preferredModel` /
/// `appState.preferredReasoningEffort`) so the choice survives thread
/// switches and app relaunches before the next `startThread` call.
struct HomeModelChip: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false

    /// The server the chip should pull available models from. Typically
    /// the currently-selected project's serverId; when nothing is picked
    /// the chip is disabled.
    let serverId: String?
    let disabled: Bool
    var onSheetStateChange: (Bool) -> Void = { _ in }

    @State private var showSheet = false
    @State private var selectedDetent: PresentationDetent = .large
    @State private var autoSelectedModelKey: String?

    /// Whether the user has escalated the pre-thread launch permissions to
    /// the equivalent of the header's "Full Access" preset.
    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: nil)
        let sandbox = appState.turnSandboxPolicy(for: nil)
        return threadPermissionPreset(
            approvalPolicy: approval,
            sandboxPolicy: sandbox
        ) == .fullAccess
    }

    private var isPlanMode: Bool {
        appState.pendingCollaborationMode == .plan
    }

    private var availableModels: [ModelInfo] {
        server?.availableModels ?? []
    }

    private var server: AppServerSnapshot? {
        guard let serverId else { return nil }
        return appModel.snapshot?.serverSnapshot(for: serverId)
    }

    private var metadataLoadID: String {
        guard let serverId,
              let server = appModel.snapshot?.serverSnapshot(for: serverId) else {
            return serverId ?? "none"
        }
        let runtimes = server.agentRuntimes
            .filter(\.available)
            .map(\.kind)
            .sorted()
            .joined(separator: ",")
        return "\(serverId)|\(runtimes)"
    }

    private var fallbackModel: ModelInfo? {
        availableModels.first { $0.agentRuntimeKind == .codex && $0.isDefault }
            ?? availableModels.first { $0.isDefault }
            ?? availableModels.first
    }

    private var selectedModel: ModelInfo? {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackModel }
        return availableModels.first {
            modelMatchesSelection($0, trimmed, runtime: appState.preferredAgentRuntimeKind)
        } ?? fallbackModel
    }

    private var selectedModelLabel: String {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let match = availableModels.first(where: {
                modelMatchesSelection(
                    $0,
                    trimmed,
                    runtime: appState.preferredAgentRuntimeKind
                )
            }) {
                return modelPickerDisplayName(match)
            }
            return trimmed
        }
        if let selectedModel {
            return modelPickerDisplayName(selectedModel)
        }
        return "model"
    }

    private var reasoningLabel: String {
        let trimmed = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ""
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { appState.preferredModel },
            set: { appState.preferredModel = $0 }
        )
    }

    private var selectedAgentRuntimeKindBinding: Binding<AgentRuntimeKind?> {
        Binding(
            get: { appState.preferredAgentRuntimeKind },
            set: { appState.preferredAgentRuntimeKind = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { appState.preferredReasoningEffort },
            set: { appState.preferredReasoningEffort = $0 }
        )
    }

    var body: some View {
        Button {
            selectedDetent = .large
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                if fastMode {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LitterTheme.warning)
                }
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(disabled ? LitterTheme.textMuted : LitterTheme.accent)
                Text(selectedModelLabel)
                    .litterMonoFont(size: 12, weight: .semibold)
                    .foregroundStyle(disabled ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                    .lineLimit(1)
                if !reasoningLabel.isEmpty {
                    Text(reasoningLabel)
                        .litterMonoFont(size: 11, weight: .regular)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.85))
                        .lineLimit(1)
                }
                if isPlanMode {
                    Text("plan")
                        .litterMonoFont(size: 10, weight: .bold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(LitterTheme.accent, in: Capsule())
                }
                if isFullAccess {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LitterTheme.danger)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitterTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.textMuted.opacity(0.55), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .sheet(isPresented: $showSheet) {
            ConversationOptionsSheet(
                models: availableModels,
                catalogLoaded: server?.availableModels != nil,
                catalogError: serverId.flatMap(appModel.modelCatalogError),
                onRetryModels: {
                    guard let serverId else { return }
                    Task { await appModel.loadAvailableModelsIfNeeded(serverId: serverId, force: true) }
                },
                selectedModel: selectedModelBinding,
                selectedAgentRuntimeKind: selectedAgentRuntimeKindBinding,
                reasoningEffort: reasoningEffortBinding,
                threadKey: nil
            )
            .environment(appModel)
            .environment(appState)
            .presentationDetents([.medium, .large], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationBackground(LitterTheme.surface)
        }
        .onChange(of: showSheet) { _, isPresented in
            onSheetStateChange(isPresented)
        }
        .task(id: metadataLoadID) {
            guard let serverId else { return }
            let shouldReplaceSelection = !selectionMatchesAvailableModels()
                || autoSelectedModelKey == currentSelectionKey
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
            synchronizeSelection(forceFallback: shouldReplaceSelection)
        }
    }

    private var currentSelectionKey: String {
        "\(appState.preferredAgentRuntimeKind ?? ""):\(appState.preferredModel)"
    }

    private func selectionMatchesAvailableModels() -> Bool {
        let current = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return false }
        return availableModels.contains {
            modelMatchesSelection($0, current, runtime: appState.preferredAgentRuntimeKind)
        }
    }

    private func synchronizeSelection(forceFallback: Bool) {
        guard let selectedModel else { return }
        guard forceFallback || !selectionMatchesAvailableModels() else { return }
        appState.preferredModel = selectedModel.id
        appState.preferredAgentRuntimeKind = selectedModel.agentRuntimeKind
        appState.preferredReasoningEffort = ""
        autoSelectedModelKey = "\(selectedModel.agentRuntimeKind):\(selectedModel.id)"
    }
}
