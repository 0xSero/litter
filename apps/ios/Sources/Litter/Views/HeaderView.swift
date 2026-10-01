import SafariServices
import SwiftUI

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
    var server: AppServerSnapshot?
    /// Inside a navigation bar the system supplies sizing and chrome.
    var inToolbar: Bool = false
    @State private var isReloading = false
    @State private var remoteAuthSession: RemoteAuthSession?

    @ViewBuilder
    private var control_: some View {
        switch control {
        case .reload:
            reloadButton
        case .info:
            infoButton
        }
    }

    var body: some View {
        Group {
            if inToolbar {
                control_
            } else {
                control_
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .buttonStyle(.plain)
                    .modifier(GlassCircleModifier())
                    .hoverEffect(.highlight)
            }
        }
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
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(server?.isConnected == true ? LitterTheme.textPrimary : LitterTheme.textMuted)
        }
    }

    private var infoButton: some View {
        Button {
            onInfo?()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(LitterTheme.textPrimary)
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

/// Chip and header label for a catalog entry: the mode name for mode
/// entries (Amp `high`), otherwise the model's display name.
func modelPickerDisplayName(_ model: ModelInfo) -> String {
    if model.isModeEntry, !model.pickerName.isEmpty { return model.pickerName }
    return model.displayName.isEmpty ? model.id : model.displayName
}

/// Model picker opened from the home composer chip or a thread's options
/// sheet. Adds plan-mode and permission toggles to the shared picker.
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
    var onDismiss: () -> Void

    var body: some View {
        ModelPickerView(
            models: models,
            catalogLoaded: catalogLoaded,
            catalogError: catalogError,
            onRetryModels: onRetryModels,
            selectedModel: $selectedModel,
            selectedAgentRuntimeKind: $selectedAgentRuntimeKind,
            reasoningEffort: $reasoningEffort,
            isReasoningEffortLocked: isReasoningEffortLocked,
            fallsBackToDefaultModel: true,
            dismissOnSelect: threadKey != nil,
            session: ModelPickerSessionControls(
                threadKey: threadKey,
                collaborationMode: collaborationMode,
                effectiveApprovalPolicy: effectiveApprovalPolicy,
                effectiveSandboxPolicy: effectiveSandboxPolicy
            ),
            onDone: onDismiss
        )
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

/// Model picker opened from the conversation composer.
struct ModelSelectorSheet: View {
    let models: [ModelInfo]
    var catalogLoaded = false
    var catalogError: String?
    var onRetryModels: () -> Void = {}
    @Binding var selectedModel: String
    @Binding var selectedAgentRuntimeKind: AgentRuntimeKind?
    @Binding var reasoningEffort: String
    var isReasoningEffortLocked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ModelPickerView(
            models: models,
            catalogLoaded: catalogLoaded,
            catalogError: catalogError,
            onRetryModels: onRetryModels,
            selectedModel: $selectedModel,
            selectedAgentRuntimeKind: $selectedAgentRuntimeKind,
            reasoningEffort: $reasoningEffort,
            isReasoningEffortLocked: isReasoningEffortLocked,
            onDone: { dismiss() }
        )
    }
}
