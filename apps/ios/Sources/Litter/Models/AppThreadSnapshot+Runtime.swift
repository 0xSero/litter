import Foundation

struct AppThreadAssistantSnippetSnapshot: Equatable {
    let sourceItemId: String
    let snippet: String
}

extension AppThreadSnapshot {
    var displayTitle: String {
        let explicitTitle = info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitTitle.isEmpty {
            return explicitTitle
        }

        let preview = info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            return preview
        }

        return "Untitled session"
    }

    var hasPreviewOrTitle: Bool {
        let preview = info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !preview.isEmpty || !title.isEmpty
    }

    var hasActiveTurn: Bool {
        if activeTurnId != nil {
            return true
        }
        if case .active = info.status {
            return true
        }
        return false
    }

    var ampReasoningEffortLocked: Bool {
        // The "lock reasoning effort once a thread has started" rule is
        // advertised by the alleycat manifest as a capability flag, so
        // any future agent with the same constraint inherits the
        // behavior without litter changes.
        guard agentRuntimeKind.metadata?.capabilities?.locksReasoningEffortAfterActivity == true
        else { return false }
        return !hydratedConversationItems.isEmpty || activeTurnId != nil
    }

    var resolvedModel: String {
        let direct = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }

        let infoModel = info.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return infoModel
    }

    var displayModelLabel: String {
        let resolved = resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }

        if let providerLabel = Self.modelProviderDisplayLabel(info.modelProvider) {
            return providerLabel
        }

        return Self.agentRuntimeDisplayLabel(agentRuntimeKind)
    }

    var resolvedPreview: String {
        displayTitle
    }

    var contextPercent: Int {
        guard let used = contextTokensUsed,
              let window = modelContextWindow,
              window > 0 else {
            return 0
        }
        return min(100, Int(Double(used) / Double(window) * 100))
    }

    var latestAssistantSnippetSnapshot: AppThreadAssistantSnippetSnapshot? {
        for item in hydratedConversationItems.reversed() {
            switch item.content {
            case .assistant(let data):
                if let snippet = Self.normalizedAssistantSnippet(from: data.text) {
                    return AppThreadAssistantSnippetSnapshot(
                        sourceItemId: item.id,
                        snippet: snippet
                    )
                }
            case .codeReview(let data):
                if let snippet = Self.normalizedAssistantSnippet(from: data.findings.first?.title) {
                    return AppThreadAssistantSnippetSnapshot(
                        sourceItemId: item.id,
                        snippet: snippet
                    )
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func normalizedAssistantSnippet(from text: String?) -> String? {
        guard let text else { return nil }
        let snippet = String(text.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }

    private static func modelProviderDisplayLabel(_ provider: String?) -> String? {
        let normalized = provider?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "anthropic", "claude", "claude-code", "claude_code":
            return "Claude"
        case "opencode", "open-code", "open_code":
            return "opencode"
        case "amp", "ampcode", "amp-code", "amp_code", "amp code":
            return "Amp"
        case "pi", "pi.dev", "pidev":
            return "Pi"
        case "droid", "factory", "factory-droid", "factory_droid", "factory droid":
            return "Droid"
        case "openai", "codex":
            return "Codex"
        default:
            if normalized.hasPrefix("claude") || normalized.contains("anthropic") {
                return "Claude"
            }
            if normalized.hasPrefix("amp")
                || normalized.contains("ampcode")
                || normalized.contains("amp-code")
                || normalized.contains("amp_code") {
                return "Amp"
            }
            return provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func agentRuntimeDisplayLabel(_ runtime: AgentRuntimeKind) -> String {
        runtime.displayLabel
    }
}
