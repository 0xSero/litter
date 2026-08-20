import Foundation

enum MessageContentBridge {
    enum AssistantRenderBlock {
        case markdown(String)
        case codeBlock(language: String?, code: String)
        case inlineImage(Data)
        case localImage(path: String)
    }

    static func assistantRenderBlocks(_ text: String) -> [AssistantRenderBlock] {
        let parsed = assistantRenderBlocks(from: store.extractRenderBlocksTyped(text: text))
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    static func containsMath(_ text: String) -> Bool {
        store.extractSegmentsTyped(text: text).contains { segment in
            switch segment {
            case .inlineMath, .displayMath:
                return true
            default:
                return false
            }
        }
    }

    static func parseToolCalls(text: String) -> [ToolCallCardModel] {
        store.parseToolCallsTyped(text: text).compactMap { $0.toToolCallCardModel() }
    }

    static func parseCodeReview(text: String) -> ConversationCodeReviewData? {
        store.parseCodeReviewTyped(text: text)?.toConversationCodeReviewData()
    }

    private static let store = MessageParser()

    private static func assistantRenderBlocks(from rustBlocks: [AppMessageRenderBlock]) -> [AssistantRenderBlock] {
        rustBlocks.compactMap { block in
            switch block {
            case .markdown(markdown: let markdown):
                return markdown.isEmpty ? nil : .markdown(markdown)
            case .codeBlock(language: let language, code: let code):
                return .codeBlock(language: language, code: code)
            case .inlineImage(data: let data, mimeType: _):
                return .inlineImage(data)
            case .localImage(path: let path):
                return .localImage(path: path)
            }
        }
    }

}

private extension AppToolCallKind {
    func toToolCallKind() -> ToolCallKind? {
        switch self {
        case .commandExecution: return .commandExecution
        case .commandOutput: return .commandOutput
        case .fileChange: return .fileChange
        case .fileDiff: return .fileDiff
        case .mcpToolCall: return .mcpToolCall
        case .mcpToolProgress: return .mcpToolProgress
        case .webSearch: return .webSearch
        case .collaboration: return .collaboration
        case .imageView: return .imageView
        case .widget: return .widget
        case .unknown: return nil
        }
    }
}

private extension AppCodeReviewPayload {
    func toConversationCodeReviewData() -> ConversationCodeReviewData {
        ConversationCodeReviewData(
            findings: findings.map { $0.toConversationCodeReviewFinding() },
            overallCorrectness: overallCorrectness,
            overallExplanation: overallExplanation,
            overallConfidenceScore: overallConfidenceScore
        )
    }
}

private extension AppCodeReviewFinding {
    func toConversationCodeReviewFinding() -> ConversationCodeReviewFinding {
        ConversationCodeReviewFinding(
            title: title,
            body: body,
            confidenceScore: confidenceScore,
            priority: priority.map(Int.init),
            codeLocation: codeLocation?.toConversationCodeReviewLocation()
        )
    }
}

private extension AppCodeReviewCodeLocation {
    func toConversationCodeReviewLocation() -> ConversationCodeReviewLocation {
        ConversationCodeReviewLocation(
            absoluteFilePath: absoluteFilePath,
            lineRange: lineRange?.toConversationCodeReviewLineRange()
        )
    }
}

private extension AppCodeReviewLineRange {
    func toConversationCodeReviewLineRange() -> ConversationCodeReviewLineRange {
        ConversationCodeReviewLineRange(start: Int(start), end: Int(end))
    }
}

private extension AppToolCallSectionContent {
    func toToolCallSection(label: String) -> ToolCallSection {
        switch self {
        case .keyValue(let entries):
            return .kv(
                label: label,
                entries: entries.map { ToolCallKeyValue(key: $0.key, value: $0.value) }
            )
        case .code(let language, let content):
            return .code(label: label, language: language, content: content)
        case .json(let content):
            return .json(label: label, content: content)
        case .diff(let content):
            return .diff(label: label, content: content)
        case .text(let content):
            return .text(label: label, content: content)
        case .itemList(let items):
            return .list(label: label, items: items)
        case .progressList(let items):
            return .progress(label: label, items: items)
        }
    }
}

private extension AppToolCallCard {
    func toToolCallCardModel() -> ToolCallCardModel? {
        guard let kind = kind.toToolCallKind() else { return nil }
        let mappedSections = sections.map { $0.content.toToolCallSection(label: $0.label) }
        let commandContext = synthesizedCommandContext(kind: kind, sections: mappedSections)
        let normalizedSections = normalizedSections(kind: kind, sections: mappedSections)

        let duration: String? = durationMs.map { ms in
            let seconds = Double(ms) / 1000.0
            if seconds < 1.0 {
                return "\(ms)ms"
            } else if seconds < 60.0 {
                return String(format: "%.1fs", seconds)
            } else {
                let minutes = Int(seconds) / 60
                let remainingSeconds = Int(seconds) % 60
                return "\(minutes)m \(remainingSeconds)s"
            }
        }

        return ToolCallCardModel(
            kind: kind,
            title: title,
            summary: summary,
            status: status,
            duration: duration,
            sections: normalizedSections,
            commandContext: commandContext
        )
    }

    private func normalizedSections(kind: ToolCallKind, sections: [ToolCallSection]) -> [ToolCallSection] {
        var normalized = sections

        if kind == .fileChange || kind == .fileDiff {
            let diffIndices = normalized.enumerated().compactMap { index, section -> Int? in
                if case .diff = section { return index }
                return nil
            }

            if !diffIndices.isEmpty {
                normalized.removeAll { section in
                    if case .list(let label, _) = section {
                        return normalizedText(label) == "files"
                    }
                    return false
                }
            }

            if kind == .fileChange,
               diffIndices.count == 1,
               let diffIndex = normalized.enumerated().first(where: { _, section in
                   if case .diff = section { return true }
                   return false
               })?.offset,
               case .diff(_, let content) = normalized[diffIndex] {
                normalized[diffIndex] = .diff(label: "", content: content)
            }
        }

        guard kind.isCommandLike else { return normalized }
        return normalized.filter { section in
            let label = normalizedLabel(for: section)
            return label != "command" && label != "directory" && label != "cwd" && label != "working directory"
        }
    }

    private func synthesizedCommandContext(
        kind: ToolCallKind,
        sections: [ToolCallSection]
    ) -> ToolCallCommandContext? {
        guard kind.isCommandLike else { return nil }

        let command = (
            sectionText(named: ["command"], in: sections)
            ?? summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let directory = sectionText(named: ["directory", "cwd", "working directory"], in: sections)

        guard !command.isEmpty else {
            return nil
        }
        return ToolCallCommandContext(
            command: command,
            directory: directory?.isEmpty == true ? nil : directory
        )
    }

    private func sectionText(named names: Set<String>, in sections: [ToolCallSection]) -> String? {
        for section in sections {
            switch section {
            case .kv(_, let entries):
                for entry in entries {
                    guard names.contains(normalizedText(entry.key)) else { continue }
                    let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            case .text(_, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .code(_, _, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            default:
                break
            }
        }
        return nil
    }

    private func normalizedLabel(for section: ToolCallSection) -> String {
        switch section {
        case .kv(let label, _),
             .code(let label, _, _),
             .json(let label, _),
             .diff(let label, _),
             .text(let label, _),
             .list(let label, _),
             .progress(let label, _):
            return normalizedText(label)
        }
    }

    private func normalizedText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
