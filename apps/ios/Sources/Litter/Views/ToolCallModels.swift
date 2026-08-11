import Foundation

enum ConversationDetailDisplayMode: String, CaseIterable, Identifiable, Equatable {
    case expanded
    case collapsed
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .expanded: return "Show"
        case .collapsed: return "Collapse"
        case .hidden: return "Hide"
        }
    }

    var detailText: String {
        switch self {
        case .expanded: return "Details are open by default"
        case .collapsed: return "Details stay behind a disclosure"
        case .hidden: return "Details are removed from the transcript"
        }
    }

    var rendersRows: Bool { self != .hidden }

    static func resolve(_ rawValue: String) -> ConversationDetailDisplayMode {
        ConversationDetailDisplayMode(rawValue: rawValue) ?? .collapsed
    }

    /// Commands and tool results are part of the durable conversation record,
    /// not optional decoration. Older builds allowed persisting `hidden` for
    /// those rows; migrate that value to collapsed so reconnecting to a thread
    /// can never make its work disappear from the transcript.
    static func resolveRequiredActivity(_ rawValue: String) -> ConversationDetailDisplayMode {
        let mode = resolve(rawValue)
        return mode == .hidden ? .collapsed : mode
    }

    static let requiredActivityCases: [ConversationDetailDisplayMode] = [
        .expanded,
        .collapsed
    ]

    func defaultExpanded(isFailed: Bool = false) -> Bool {
        switch self {
        case .expanded:
            return true
        case .collapsed:
            return isFailed
        case .hidden:
            return false
        }
    }
}

enum ConversationDisplayPreferenceKey {
    static let reasoning = "conversationReasoningDisplayMode"
    static let commands = "conversationCommandDisplayMode"
    static let tools = "conversationToolDisplayMode"
}

enum ToolCallKind: String, Equatable {
    case commandExecution
    case commandOutput
    case fileChange
    case fileDiff
    case mcpToolCall
    case mcpToolProgress
    case webSearch
    case collaboration
    case imageView
    case widget

    var title: String {
        switch self {
        case .commandExecution: return "Command Execution"
        case .commandOutput: return "Command Output"
        case .fileChange: return "File Change"
        case .fileDiff: return "File Diff"
        case .mcpToolCall: return "MCP Tool Call"
        case .mcpToolProgress: return "MCP Tool Progress"
        case .webSearch: return "Web Search"
        case .collaboration: return "Collaboration"
        case .imageView: return "Image View"
        case .widget: return "Widget"
        }
    }

    var iconName: String {
        switch self {
        case .commandExecution, .commandOutput:
            return "terminal.fill"
        case .fileChange:
            return "doc.text.fill"
        case .fileDiff:
            return "arrow.left.arrow.right.square.fill"
        case .mcpToolCall:
            return "wrench.and.screwdriver.fill"
        case .mcpToolProgress:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .webSearch:
            return "globe"
        case .collaboration:
            return "person.2.fill"
        case .imageView:
            return "photo.fill"
        case .widget:
            return "sparkles"
        }
    }

    static func from(title: String) -> ToolCallKind? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("command output") { return .commandOutput }
        if normalized.contains("command execution") || normalized == "command" { return .commandExecution }
        if normalized.contains("file change") { return .fileChange }
        if normalized.contains("file diff") || normalized == "diff" { return .fileDiff }
        if normalized.contains("mcp tool progress") { return .mcpToolProgress }
        if normalized.contains("mcp tool call") || normalized == "mcp" { return .mcpToolCall }
        if normalized.contains("web search") { return .webSearch }
        if normalized.contains("collaboration") || normalized.contains("collab") { return .collaboration }
        if normalized.contains("image view") || normalized == "image" { return .imageView }
        if normalized.contains("widget") || normalized.contains("show widget") { return .widget }
        if normalized.contains("dynamic tool call") { return .mcpToolCall }
        return nil
    }

    var isCommandLike: Bool {
        switch self {
        case .commandExecution, .commandOutput:
            return true
        default:
            return false
        }
    }
}

extension ToolCallStatus {
    var label: String {
        switch self {
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }
}

extension AppOperationStatus {
    var toolCallStatus: ToolCallStatus {
        switch self {
        case .pending, .inProgress:
            return .inProgress
        case .completed:
            return .completed
        case .failed, .declined:
            return .failed
        case .unknown:
            return .unknown
        }
    }

    var displayLabel: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .pending:
            return "Pending"
        case .inProgress:
            return "In Progress"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .declined:
            return "Declined"
        }
    }
}

struct ToolCallKeyValue: Equatable {
    let key: String
    let value: String
}

struct ToolCallCommandContext: Equatable {
    let command: String
    let directory: String?
}

enum ToolCallSection: Equatable {
    case kv(label: String, entries: [ToolCallKeyValue])
    case code(label: String, language: String, content: String)
    case json(label: String, content: String)
    case diff(label: String, content: String)
    case text(label: String, content: String)
    case list(label: String, items: [String])
    case progress(label: String, items: [String])
}

struct ToolCallCardModel: Equatable {
    let kind: ToolCallKind
    let title: String
    let summary: String
    let attributedSummary: AttributedString?
    let status: ToolCallStatus
    let duration: String?
    let sections: [ToolCallSection]
    let initiallyExpanded: Bool
    let commandContext: ToolCallCommandContext?

    init(
        kind: ToolCallKind,
        title: String,
        summary: String,
        attributedSummary: AttributedString? = nil,
        status: ToolCallStatus,
        duration: String?,
        sections: [ToolCallSection],
        initiallyExpanded: Bool = false,
        commandContext: ToolCallCommandContext? = nil
    ) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.attributedSummary = attributedSummary
        self.status = status
        self.duration = duration
        self.sections = sections
        self.initiallyExpanded = initiallyExpanded
        self.commandContext = commandContext
    }

    var defaultExpanded: Bool { initiallyExpanded || status == .failed }
}

enum ToolCallParseResult: Equatable {
    case recognized(ToolCallCardModel)
    case unrecognized
}
