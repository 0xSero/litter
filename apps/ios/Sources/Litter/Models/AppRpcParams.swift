import Foundation

struct AppThreadLaunchSelection: Equatable, Sendable {
    let agentRuntimeKind: AgentRuntimeKind?
    let model: String?

    init(agentRuntimeKind: AgentRuntimeKind?, model: String?) {
        self.agentRuntimeKind = agentRuntimeKind
        self.model = model?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

struct AppThreadLaunchConfig: Equatable, Sendable {
    var agentRuntimeKind: AgentRuntimeKind? = nil
    var model: String? = nil
    var approvalPolicy: AppAskForApproval?
    var sandbox: AppSandboxMode?
    var developerInstructions: String?
    var persistExtendedHistory: Bool = true

    func threadStartRequest(cwd: String, dynamicTools: [AppDynamicToolSpec]? = nil) -> AppStartThreadRequest {
        AppStartThreadRequest(
            agentRuntimeKind: agentRuntimeKind,
            model: model,
            cwd: cwd,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory,
            dynamicTools: dynamicTools
        )
    }

    func threadResumeRequest(threadId: String, cwdOverride: String?) -> AppResumeThreadRequest {
        AppResumeThreadRequest(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func threadForkRequest(threadId: String, cwdOverride: String?) -> AppForkThreadRequest {
        AppForkThreadRequest(
            threadId: threadId,
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }

    func forkThreadFromMessageRequest(cwdOverride: String?) -> AppForkThreadFromMessageRequest {
        AppForkThreadFromMessageRequest(
            model: model,
            cwd: cwdOverride,
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            developerInstructions: developerInstructions,
            persistExtendedHistory: persistExtendedHistory
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct ComposerFileAttachment: Identifiable, Equatable, Sendable {
    var label: String
    var path: String

    var id: String { "\(label)\u{0}\(path)" }
}

struct AppComposerPayload: Equatable, Sendable {
    var text: String
    var additionalInputs: [AppUserInput]
    var fileAttachments: [ComposerFileAttachment] = []
    var approvalPolicy: AppAskForApproval?
    var sandboxPolicy: AppSandboxPolicy?
    var model: String?
    var effort: ReasoningEffort?
    var serviceTier: ServiceTier?

    func turnStartRequest(threadId: String) -> AppStartTurnRequest {
        var inputs = additionalInputs
        let composedText = desktopStylePromptText(text: text, fileAttachments: fileAttachments)
        if !composedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs.insert(.text(text: composedText, textElements: []), at: 0)
        }
        return AppStartTurnRequest(
            threadId: threadId,
            input: inputs,
            approvalPolicy: approvalPolicy,
            sandboxPolicy: sandboxPolicy,
            model: model,
            serviceTier: serviceTier,
            effort: effort
        )
    }
}

private func desktopStylePromptText(
    text: String,
    fileAttachments: [ComposerFileAttachment]
) -> String {
    let validAttachments = fileAttachments.compactMap { attachment -> ComposerFileAttachment? in
        let label = sanitizeFileContextValue(attachment.label)
        let path = sanitizeFileContextValue(attachment.path)
        guard !path.isEmpty else { return nil }
        return ComposerFileAttachment(label: label.isEmpty ? path : label, path: path)
    }
    guard !validAttachments.isEmpty else { return text }

    let files = validAttachments
        .map { "## \($0.label): \($0.path)" }
        .joined(separator: "\n\n")
    return """
    # Files mentioned by the user:

    \(files)

    ## My request for Codex:
    \(text)
    """
}

private func sanitizeFileContextValue(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
