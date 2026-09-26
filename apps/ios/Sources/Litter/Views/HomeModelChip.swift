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
    /// Precomputed server snapshot, passed by the parent to avoid reading
    /// `appModel.snapshot` in body.
    var server: AppServerSnapshot?
    var onSheetStateChange: (Bool) -> Void = { _ in }
    /// False: render nothing visible and only host the picker sheet plus
    /// the model-selection sync. The home composer shows the model as a
    /// pill inside its own bottom row and opens the sheet via
    /// `presentation`.
    var showsLabel: Bool = true
    /// External control of the picker sheet (used with `showsLabel: false`).
    var presentation: Binding<Bool>? = nil

    @State private var showSheet = false

    private var sheetBinding: Binding<Bool> {
        presentation ?? $showSheet
    }
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

    private var metadataLoadID: String {
        guard let serverId,
              let server else {
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

    private var usesServerConfiguredDefault: Bool {
        usesServerConfiguredModelDefault(
            availableModels.map(\.agentRuntimeKind)
        )
    }

    private var selectedModel: ModelInfo? {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return usesServerConfiguredDefault ? nil : fallbackModel
        }
        if let selected = availableModels.first(where: {
            modelMatchesSelection($0, trimmed, runtime: appState.preferredAgentRuntimeKind)
        }) {
            return selected
        }
        return usesServerConfiguredDefault ? nil : fallbackModel
    }

    private var selectedModelLabel: String {
        Self.modelLabel(appState: appState, models: availableModels)
    }

    /// Display name for the home model selection ("gpt-5.4",
    /// "server default"), shared by this chip and the composer pill.
    static func modelLabel(appState: AppState, models: [ModelInfo]) -> String {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let match = models.first(where: {
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
        if usesServerConfiguredModelDefault(models.map(\.agentRuntimeKind)) {
            return "server default"
        }
        let fallback = models.first { $0.agentRuntimeKind == .codex && $0.isDefault }
            ?? models.first { $0.isDefault }
            ?? models.first
        if let fallback {
            return modelPickerDisplayName(fallback)
        }
        return "model"
    }

    /// Secondary words shown after the model in the composer pill:
    /// "high · fast · plan · full access".
    static func modelDetail(appState: AppState, fastMode: Bool) -> String? {
        var parts: [String] = []
        let effort = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { parts.append(effort) }
        if fastMode { parts.append("fast") }
        if appState.pendingCollaborationMode == .plan { parts.append("plan") }
        let fullAccess = threadPermissionPreset(
            approvalPolicy: appState.launchApprovalPolicy(for: nil),
            sandboxPolicy: appState.turnSandboxPolicy(for: nil)
        ) == .fullAccess
        if fullAccess { parts.append("full access") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var reasoningLabel: String {
        let trimmed = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ""
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { appState.preferredModel },
            set: {
                appState.preferredModel = $0
                rememberSelectionForServer()
            }
        )
    }

    private var selectedAgentRuntimeKindBinding: Binding<AgentRuntimeKind?> {
        Binding(
            get: { appState.preferredAgentRuntimeKind },
            set: {
                appState.preferredAgentRuntimeKind = $0
                rememberSelectionForServer()
            }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { appState.preferredReasoningEffort },
            set: {
                appState.preferredReasoningEffort = $0
                rememberSelectionForServer()
            }
        )
    }

    var body: some View {
        chipLabel
        .sheet(isPresented: sheetBinding) {
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
        .onChange(of: sheetBinding.wrappedValue) { _, isPresented in
            if isPresented { selectedDetent = .large }
            onSheetStateChange(isPresented)
            if isPresented, let serverId {
                Task { await appModel.loadAvailableModelsIfNeeded(serverId: serverId) }
            }
        }
        .task(id: metadataLoadID) {
            guard let serverId else { return }
            let shouldReplaceSelection = !selectionMatchesAvailableModels()
                || autoSelectedModelKey == currentSelectionKey
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
            synchronizeSelection(forceFallback: shouldReplaceSelection)
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        if showsLabel {
            visibleChip
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var visibleChip: some View {
        Button {
            selectedDetent = .large
            sheetBinding.wrappedValue = true
        } label: {
            // "model effort · fast · plan · full access" as one mono line.
            HStack(spacing: 6) {
                Text(selectedModelLabel)
                    .litterMonoFont(size: 13)
                    .foregroundStyle(disabled ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                    .lineLimit(1)
                if !reasoningLabel.isEmpty {
                    Text(reasoningLabel)
                        .litterMeta()
                        .lineLimit(1)
                }
                if fastMode {
                    Text("fast").litterMeta()
                }
                if isPlanMode {
                    Text("plan").litterMeta(LitterTheme.textPrimary)
                }
                if isFullAccess {
                    Text("full access").litterMeta(LitterTheme.danger)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitterTheme.meta)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, LitterSpace.m)
            .frame(minHeight: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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

    /// Records the user's explicit pick for the current server so switching
    /// to another server (whose catalog lacks that model) and back restores
    /// it instead of the server default.
    private func rememberSelectionForServer() {
        guard let serverId else { return }
        HomeModelSelectionMemory.remember(
            serverId: serverId,
            selection: .init(
                model: appState.preferredModel,
                runtime: appState.preferredAgentRuntimeKind ?? "",
                effort: appState.preferredReasoningEffort
            )
        )
        autoSelectedModelKey = nil
    }

    private func synchronizeSelection(forceFallback: Bool) {
        // Last pick made on this server wins over the fallback when the
        // global last-used model is not offered here.
        if !selectionMatchesAvailableModels(),
           let serverId,
           let remembered = HomeModelSelectionMemory.selection(for: serverId),
           let match = availableModels.first(where: {
               modelMatchesSelection($0, remembered.model, runtime: remembered.runtime.isEmpty ? nil : remembered.runtime)
           }) {
            appState.preferredModel = match.id
            appState.preferredAgentRuntimeKind = match.agentRuntimeKind
            appState.preferredReasoningEffort = remembered.effort
            autoSelectedModelKey = nil
            return
        }
        if usesServerConfiguredDefault && !selectionMatchesAvailableModels() {
            appState.preferredModel = ""
            appState.preferredAgentRuntimeKind = nil
            appState.preferredReasoningEffort = ""
            autoSelectedModelKey = nil
            return
        }
        guard let selectedModel else { return }
        guard forceFallback || !selectionMatchesAvailableModels() else { return }
        // Already the persisted pick: keep it (and its reasoning effort)
        // rather than re-stamping it as an auto-selected fallback.
        if selectionMatchesAvailableModels(),
           modelMatchesSelection(
               selectedModel,
               appState.preferredModel,
               runtime: appState.preferredAgentRuntimeKind
           ),
           autoSelectedModelKey != currentSelectionKey {
            return
        }
        appState.preferredModel = selectedModel.id
        appState.preferredAgentRuntimeKind = selectedModel.agentRuntimeKind
        appState.preferredReasoningEffort = ""
        autoSelectedModelKey = "\(selectedModel.agentRuntimeKind):\(selectedModel.id)"
    }
}

func usesServerConfiguredModelDefault(_ runtimeKinds: [AgentRuntimeKind]) -> Bool {
    !runtimeKinds.isEmpty && runtimeKinds.allSatisfy { $0 == .localStudio }
}

/// Per-server memory of the last model the user explicitly picked on the
/// home composer. The global `AppState.preferredModel` stays the primary
/// default; this only fills in when that model is not offered by the
/// selected server.
enum HomeModelSelectionMemory {
    struct Selection: Codable, Equatable {
        var model: String
        var runtime: String
        var effort: String
    }

    private static let key = "litter.preferredModelByServer"

    static func selection(for serverId: String) -> Selection? {
        load()[serverId]
    }

    static func remember(serverId: String, selection: Selection) {
        var all = load()
        if selection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            all.removeValue(forKey: serverId)
        } else {
            all[serverId] = selection
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load() -> [String: Selection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Selection].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
