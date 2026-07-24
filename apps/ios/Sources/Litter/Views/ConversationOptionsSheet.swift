import SwiftUI

/// Shared sheet for model + reasoning + plan/fast/permissions options. Used
/// by the home composer's `HomeModelChip` (no thread yet — `threadKey` nil)
/// and by any caller in a thread context (existing conversation).
struct ConversationOptionsSheet: View {
    let models: [ModelInfo]
    let catalogLoaded: Bool
    let catalogError: String?
    let onRetryModels: () -> Void
    @Binding var selectedModel: String
    @Binding var selectedAgentRuntimeKind: AgentRuntimeKind?
    @Binding var reasoningEffort: String
    var threadKey: ThreadKey?
    var collaborationMode: AppModeKind = .default
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Present the inline selector exactly as it appears in the
        // conversation popover — no NavigationStack, no title bar. The
        // sheet drag indicator handles dismissal; a Done row from
        // InlineModelSelectorView itself stays available via `onDismiss`.
        InlineModelSelectorView(
            models: models,
            catalogLoaded: catalogLoaded,
            catalogError: catalogError,
            onRetryModels: onRetryModels,
            selectedModel: $selectedModel,
            selectedAgentRuntimeKind: $selectedAgentRuntimeKind,
            reasoningEffort: $reasoningEffort,
            threadKey: threadKey,
            collaborationMode: collaborationMode,
            effectiveApprovalPolicy: effectiveApprovalPolicy,
            effectiveSandboxPolicy: effectiveSandboxPolicy,
            onDismiss: { dismiss() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LitterTheme.surface.ignoresSafeArea())
    }
}
