import Foundation
import CoreGraphics

struct ConversationPlanStep: Equatable {
    let step: String
    let status: HydratedPlanStepStatus
}

struct ConversationCommandAction: Equatable {
    let kind: HydratedCommandActionKind
    let command: String
    let name: String?
    let path: String?
    let query: String?
}

struct ConversationUserMessageData: Equatable {
    var text: String
    var images: [ChatImage]
}

struct ConversationAssistantMessageData: Equatable {
    var text: String
    var agentNickname: String?
    var agentRole: String?
    var phase: AppMessagePhase?
}

struct ConversationCodeReviewLineRange: Equatable {
    var start: Int
    var end: Int
}

struct ConversationCodeReviewLocation: Equatable {
    var absoluteFilePath: String
    var lineRange: ConversationCodeReviewLineRange?
}

struct ConversationCodeReviewFinding: Equatable {
    var title: String
    var body: String
    var confidenceScore: Double
    var priority: Int?
    var codeLocation: ConversationCodeReviewLocation?
}

struct ConversationCodeReviewData: Equatable {
    var findings: [ConversationCodeReviewFinding]
    var overallCorrectness: String?
    var overallExplanation: String?
    var overallConfidenceScore: Double?
}

struct ConversationReasoningData: Equatable {
    var summary: [String]
    var content: [String]
}

struct ConversationTodoListData: Equatable {
    var steps: [ConversationPlanStep]

    var completedCount: Int {
        steps.filter { $0.status == .completed }.count
    }

    var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == .completed }
    }
}

struct ConversationProposedPlanData: Equatable {
    var content: String
}

struct ConversationCommandExecutionData: Equatable {
    var command: String
    var cwd: String
    var status: AppOperationStatus
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var processId: String?
    var actions: [ConversationCommandAction]

    var isInProgress: Bool {
        status == .pending || status == .inProgress
    }

    var isPureExploration: Bool {
        guard !actions.isEmpty else { return false }
        return actions.allSatisfy {
            switch $0.kind {
            case .read, .search, .listFiles:
                return true
            case .unknown:
                return false
            }
        }
    }
}

struct ConversationFileChangeEntry: Equatable {
    var path: String
    var kind: String
    var diff: String
    var additions: Int
    var deletions: Int
}

struct ConversationFileChangeData: Equatable {
    var status: AppOperationStatus
    var changes: [ConversationFileChangeEntry]
    var outputDelta: String?
}

struct ConversationTurnDiffData: Equatable {
    var diff: String
    var additions: Int
    var deletions: Int
}

struct ConversationMcpToolCallData: Equatable {
    var server: String
    var tool: String
    var status: AppOperationStatus
    var durationMs: Int?
    var argumentsJSON: String?
    var contentSummary: String?
    var structuredContentJSON: String?
    var rawOutputJSON: String?
    var errorMessage: String?
    var progressMessages: [String]
    var computerUse: ComputerUseView?

    var isInProgress: Bool {
        status == .pending || status == .inProgress
    }
}

struct ConversationDynamicToolCallData: Equatable {
    struct Metadata: Equatable {
        var key: String
        var value: String
    }

    struct Display: Equatable {
        var title: String
        var summary: String
        var metadata: [Metadata]
    }

    var namespace: String?
    var tool: String
    var status: AppOperationStatus
    var durationMs: Int?
    var success: Bool?
    var argumentsJSON: String?
    var contentSummary: String?
    var display: Display?

    var isInProgress: Bool {
        status == .pending || status == .inProgress
    }
}

struct ConversationMultiAgentState: Equatable {
    var targetId: String
    var status: AppSubagentStatus
    var message: String?
}

struct ConversationMultiAgentActionData: Equatable {
    var tool: String
    var status: AppOperationStatus
    var prompt: String?
    var targets: [String]
    var receiverThreadIds: [String]
    var agentStates: [ConversationMultiAgentState]
    /// Per-agent prompts when multiple spawn items are merged into one group.
    /// Index-aligned with `targets`/`receiverThreadIds`. Empty for non-merged items.
    var perAgentPrompts: [String] = []

    var isInProgress: Bool {
        status == .pending || status == .inProgress
    }
}

struct ConversationWebSearchData: Equatable {
    var query: String
    var actionJSON: String?
    var isInProgress: Bool
}

struct ConversationImageViewData: Equatable {
    var path: String
}

struct ConversationImageGenerationData: Equatable {
    var status: AppOperationStatus
    var revisedPrompt: String?
    var imagePNG: Data?
    var savedPath: String?

    var isInProgress: Bool {
        status == .pending || status == .inProgress
    }
}

struct ConversationWidgetData: Equatable {
    var widgetState: WidgetState
    var status: String
}

struct ConversationUserInputOptionData: Equatable {
    var label: String
    var description: String?
}

struct ConversationUserInputQuestionData: Equatable {
    var id: String
    var header: String?
    var question: String
    var answer: String
    var options: [ConversationUserInputOptionData]
}

struct ConversationUserInputResponseData: Equatable {
    var questions: [ConversationUserInputQuestionData]
}

enum ConversationDividerKind: Equatable {
    case contextCompaction(isComplete: Bool)
    case modelRerouted(fromModel: String?, toModel: String, reason: String?)
    case reviewEntered(String)
    case reviewExited(String)
    case workedFor(String)
    case generic(title: String, detail: String?)
}

struct ConversationSystemErrorData: Equatable {
    var title: String
    var message: String
    var details: String?
}

struct ConversationNoteData: Equatable {
    var title: String
    var body: String
}

enum ConversationItemContent: Equatable {
    case user(ConversationUserMessageData)
    case assistant(ConversationAssistantMessageData)
    case codeReview(ConversationCodeReviewData)
    case reasoning(ConversationReasoningData)
    case todoList(ConversationTodoListData)
    case proposedPlan(ConversationProposedPlanData)
    case commandExecution(ConversationCommandExecutionData)
    case fileChange(ConversationFileChangeData)
    case turnDiff(ConversationTurnDiffData)
    case mcpToolCall(ConversationMcpToolCallData)
    case dynamicToolCall(ConversationDynamicToolCallData)
    case multiAgentAction(ConversationMultiAgentActionData)
    case webSearch(ConversationWebSearchData)
    case imageView(ConversationImageViewData)
    case imageGeneration(ConversationImageGenerationData)
    case widget(ConversationWidgetData)
    case userInputResponse(ConversationUserInputResponseData)
    case divider(ConversationDividerKind)
    case error(ConversationSystemErrorData)
    case note(ConversationNoteData)
}

struct ConversationItem: Identifiable, Equatable {
    let id: String
    var content: ConversationItemContent {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnId: String? {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnIndex: Int? {
        didSet { refreshRenderDigest() }
    }
    var timestamp: Date {
        didSet { refreshRenderDigest() }
    }
    var isFromUserTurnBoundary: Bool {
        didSet { refreshRenderDigest() }
    }
    private(set) var renderDigest: Int

    init(
        id: String,
        content: ConversationItemContent,
        sourceTurnId: String? = nil,
        sourceTurnIndex: Int? = nil,
        timestamp: Date = Date(),
        isFromUserTurnBoundary: Bool = false
    ) {
        self.id = id
        self.content = content
        self.sourceTurnId = sourceTurnId
        self.sourceTurnIndex = sourceTurnIndex
        self.timestamp = timestamp
        self.isFromUserTurnBoundary = isFromUserTurnBoundary
        self.renderDigest = Self.computeRenderDigest(
            id: id,
            content: content,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }

    var isUserItem: Bool {
        if case .user = content { return true }
        return false
    }

    var isAssistantItem: Bool {
        if case .assistant = content { return true }
        return false
    }

    var agentNickname: String? {
        if case .assistant(let data) = content {
            return data.agentNickname
        }
        return nil
    }

    var agentRole: String? {
        if case .assistant(let data) = content {
            return data.agentRole
        }
        return nil
    }

    var userText: String? {
        if case .user(let data) = content {
            return data.text
        }
        return nil
    }

    var userImages: [ChatImage] {
        if case .user(let data) = content {
            return data.images
        }
        return []
    }

    var assistantText: String? {
        if case .assistant(let data) = content {
            return data.text
        }
        return nil
    }

    var isExplorationCommandItem: Bool {
        guard case .commandExecution(let data) = content else { return false }
        return data.isPureExploration
    }

    var isVisuallyEmptyNeutralItem: Bool {
        switch content {
        case .assistant(let data):
            let textIsEmpty = data.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let nicknameIsEmpty = data.agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            let roleIsEmpty = data.agentRole?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return textIsEmpty && nicknameIsEmpty && roleIsEmpty
        case .codeReview(let data):
            return data.findings.isEmpty
        case .reasoning(let data):
            return (data.summary + data.content).allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        default:
            return false
        }
    }

    var widgetState: WidgetState? {
        if case .widget(let data) = content {
            return data.widgetState
        }
        return nil
    }

    mutating func refreshRenderDigest() {
        renderDigest = Self.computeRenderDigest(
            id: id,
            content: content,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }

    private static func computeRenderDigest(
        id: String,
        content: ConversationItemContent,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        timestamp: Date,
        isFromUserTurnBoundary: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(sourceTurnId)
        hasher.combine(sourceTurnIndex)
        hasher.combine(timestamp.timeIntervalSince1970)
        hasher.combine(isFromUserTurnBoundary)
        combine(content: content, into: &hasher)
        return hasher.finalize()
    }

    private static func combine(content: ConversationItemContent, into hasher: inout Hasher) {
        switch content {
        case .user(let data):
            hasher.combine("user")
            hasher.combine(data.text)
            hasher.combine(data.images.count)
            for image in data.images {
                hasher.combine(image.cacheKey)
            }
        case .assistant(let data):
            hasher.combine("assistant")
            hasher.combine(data.text)
            hasher.combine(data.agentNickname)
            hasher.combine(data.agentRole)
            hasher.combine(data.phase)
        case .codeReview(let data):
            hasher.combine("codeReview")
            hasher.combine(data.overallCorrectness)
            hasher.combine(data.overallExplanation)
            hasher.combine(data.overallConfidenceScore)
            for finding in data.findings {
                hasher.combine(finding.title)
                hasher.combine(finding.body)
                hasher.combine(finding.confidenceScore)
                hasher.combine(finding.priority)
                hasher.combine(finding.codeLocation?.absoluteFilePath)
                hasher.combine(finding.codeLocation?.lineRange?.start)
                hasher.combine(finding.codeLocation?.lineRange?.end)
            }
        case .reasoning(let data):
            hasher.combine("reasoning")
            hasher.combine(data.summary)
            hasher.combine(data.content)
        case .todoList(let data):
            hasher.combine("todoList")
            for step in data.steps {
                hasher.combine(step.step)
                hasher.combine(String(describing: step.status))
            }
        case .proposedPlan(let data):
            hasher.combine("proposedPlan")
            hasher.combine(data.content)
        case .commandExecution(let data):
            hasher.combine("commandExecution")
            hasher.combine(data.command)
            hasher.combine(data.cwd)
            hasher.combine(String(describing: data.status))
            hasher.combine(data.output)
            hasher.combine(data.exitCode)
            hasher.combine(data.durationMs)
            hasher.combine(data.processId)
            for action in data.actions {
                hasher.combine(String(describing: action.kind))
                hasher.combine(action.command)
                hasher.combine(action.name)
                hasher.combine(action.path)
                hasher.combine(action.query)
            }
        case .fileChange(let data):
            hasher.combine("fileChange")
            hasher.combine(String(describing: data.status))
            hasher.combine(data.outputDelta)
            for change in data.changes {
                hasher.combine(change.path)
                hasher.combine(change.kind)
                hasher.combine(change.diff)
            }
        case .turnDiff(let data):
            hasher.combine("turnDiff")
            hasher.combine(data.diff)
        case .mcpToolCall(let data):
            hasher.combine("mcpToolCall")
            hasher.combine(data.server)
            hasher.combine(data.tool)
            hasher.combine(String(describing: data.status))
            hasher.combine(data.durationMs)
            hasher.combine(data.argumentsJSON)
            hasher.combine(data.contentSummary)
            hasher.combine(data.structuredContentJSON)
            hasher.combine(data.rawOutputJSON)
            hasher.combine(data.errorMessage)
            hasher.combine(data.progressMessages)
        case .dynamicToolCall(let data):
            hasher.combine("dynamicToolCall")
            hasher.combine(data.tool)
            hasher.combine(String(describing: data.status))
            hasher.combine(data.durationMs)
            hasher.combine(data.success)
            hasher.combine(data.argumentsJSON)
            hasher.combine(data.contentSummary)
        case .multiAgentAction(let data):
            hasher.combine("multiAgentAction")
            hasher.combine(data.tool)
            hasher.combine(String(describing: data.status))
            hasher.combine(data.prompt)
            hasher.combine(data.targets)
            hasher.combine(data.receiverThreadIds)
            hasher.combine(data.perAgentPrompts)
            for state in data.agentStates {
                hasher.combine(state.targetId)
                hasher.combine(state.status)
                hasher.combine(state.message)
            }
        case .webSearch(let data):
            hasher.combine("webSearch")
            hasher.combine(data.query)
            hasher.combine(data.actionJSON)
            hasher.combine(data.isInProgress)
        case .imageView(let data):
            hasher.combine("imageView")
            hasher.combine(data.path)
        case .imageGeneration(let data):
            hasher.combine("imageGeneration")
            hasher.combine(String(describing: data.status))
            hasher.combine(data.revisedPrompt)
            hasher.combine(data.imagePNG?.count)
            hasher.combine(data.savedPath)
        case .widget(let data):
            hasher.combine("widget")
            hasher.combine(data.status)
            hasher.combine(data.widgetState.callId)
            hasher.combine(data.widgetState.title)
            hasher.combine(data.widgetState.widgetHTML)
            hasher.combine(data.widgetState.width)
            hasher.combine(data.widgetState.height)
            hasher.combine(data.widgetState.isFinalized)
        case .userInputResponse(let data):
            hasher.combine("userInputResponse")
            for question in data.questions {
                hasher.combine(question.id)
                hasher.combine(question.header)
                hasher.combine(question.question)
                hasher.combine(question.answer)
                for option in question.options {
                    hasher.combine(option.label)
                    hasher.combine(option.description)
                }
            }
        case .divider(let divider):
            hasher.combine("divider")
            switch divider {
            case .contextCompaction(let isComplete):
                hasher.combine("contextCompaction")
                hasher.combine(isComplete)
            case .modelRerouted(let fromModel, let toModel, let reason):
                hasher.combine("modelRerouted")
                hasher.combine(fromModel)
                hasher.combine(toModel)
                hasher.combine(reason)
            case .reviewEntered(let review):
                hasher.combine("reviewEntered")
                hasher.combine(review)
            case .reviewExited(let review):
                hasher.combine("reviewExited")
                hasher.combine(review)
            case .workedFor(let duration):
                hasher.combine("workedFor")
                hasher.combine(duration)
            case .generic(let title, let detail):
                hasher.combine("genericDivider")
                hasher.combine(title)
                hasher.combine(detail)
            }
        case .error(let data):
            hasher.combine("error")
            hasher.combine(data.title)
            hasher.combine(data.message)
            hasher.combine(data.details)
        case .note(let data):
            hasher.combine("note")
            hasher.combine(data.title)
            hasher.combine(data.body)
        }
    }
}

extension HydratedConversationItem {
    var conversationItem: ConversationItem {
        ConversationItem(
            id: id,
            content: content.conversationItemContent(itemId: id),
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex.map(Int.init),
            timestamp: timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date(),
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }
}

private extension HydratedConversationItemContent {
    func conversationItemContent(itemId: String) -> ConversationItemContent {
        switch self {
        case .user(let data):
            let images = data.imageDataUris.map(ChatImage.init(source:))
            return .user(ConversationUserMessageData(text: data.text, images: images))
        case .assistant(let data):
            return .assistant(
                ConversationAssistantMessageData(
                    text: data.text,
                    agentNickname: data.agentNickname,
                    agentRole: data.agentRole,
                    phase: data.phase
                )
            )
        case .codeReview(let data):
            return .codeReview(
                ConversationCodeReviewData(
                    findings: data.findings.map {
                        ConversationCodeReviewFinding(
                            title: $0.title,
                            body: $0.body,
                            confidenceScore: $0.confidenceScore,
                            priority: $0.priority.map(Int.init),
                            codeLocation: $0.codeLocation.map {
                                ConversationCodeReviewLocation(
                                    absoluteFilePath: $0.absoluteFilePath,
                                    lineRange: $0.lineRange.map {
                                        ConversationCodeReviewLineRange(
                                            start: Int($0.start),
                                            end: Int($0.end)
                                        )
                                    }
                                )
                            }
                        )
                    },
                    overallCorrectness: data.overallCorrectness,
                    overallExplanation: data.overallExplanation,
                    overallConfidenceScore: data.overallConfidenceScore
                )
            )
        case .reasoning(let data):
            return .reasoning(ConversationReasoningData(summary: data.summary, content: data.content))
        case .todoList(let data):
            return .todoList(
                ConversationTodoListData(
                    steps: data.steps.map {
                        ConversationPlanStep(step: $0.step, status: $0.status)
                    }
                )
            )
        case .proposedPlan(let data):
            return .proposedPlan(ConversationProposedPlanData(content: data.content))
        case .commandExecution(let data):
            return .commandExecution(
                ConversationCommandExecutionData(
                    command: data.command,
                    cwd: data.cwd,
                    status: data.status,
                    output: data.output,
                    exitCode: data.exitCode.map(Int.init),
                    durationMs: data.durationMs.map(Int.init),
                    processId: data.processId,
                    actions: data.actions.map {
                        ConversationCommandAction(
                            kind: $0.kind,
                            command: $0.command,
                            name: $0.name,
                            path: $0.path,
                            query: $0.query
                        )
                    }
                )
            )
        case .fileChange(let data):
            return .fileChange(
                ConversationFileChangeData(
                    status: data.status,
                    changes: data.changes.map {
                        ConversationFileChangeEntry(
                            path: $0.path,
                            kind: $0.kind,
                            diff: $0.diff,
                            additions: Int($0.additions),
                            deletions: Int($0.deletions)
                        )
                    },
                    outputDelta: nil
                )
            )
        case .turnDiff(let data):
            let stats = DiffStats(diff: data.diff)
            return .turnDiff(
                ConversationTurnDiffData(
                    diff: data.diff,
                    additions: stats.additions,
                    deletions: stats.deletions
                )
            )
        case .mcpToolCall(let data):
            return .mcpToolCall(
                ConversationMcpToolCallData(
                    server: data.server,
                    tool: data.tool,
                    status: data.status,
                    durationMs: data.durationMs.map(Int.init),
                    argumentsJSON: data.argumentsJson,
                    contentSummary: data.contentSummary,
                    structuredContentJSON: data.structuredContentJson,
                    rawOutputJSON: data.rawOutputJson,
                    errorMessage: data.errorMessage,
                    progressMessages: data.progressMessages,
                    computerUse: data.computerUse
                )
            )
        case .dynamicToolCall(let data):
            return .dynamicToolCall(
                ConversationDynamicToolCallData(
                    namespace: data.namespace,
                    tool: data.tool,
                    status: data.status,
                    durationMs: data.durationMs.map(Int.init),
                    success: data.success,
                    argumentsJSON: data.argumentsJson,
                    contentSummary: data.contentSummary,
                    display: data.display.map {
                        ConversationDynamicToolCallData.Display(
                            title: $0.title,
                            summary: $0.summary,
                            metadata: $0.metadata.map {
                                ConversationDynamicToolCallData.Metadata(
                                    key: $0.key,
                                    value: $0.value
                                )
                            }
                        )
                    }
                )
            )
        case .multiAgentAction(let data):
            return .multiAgentAction(
                ConversationMultiAgentActionData(
                    tool: data.tool,
                    status: data.status,
                    prompt: data.prompt,
                    targets: data.targets,
                    receiverThreadIds: data.receiverThreadIds,
                    agentStates: data.agentStates.map {
                        ConversationMultiAgentState(
                            targetId: $0.targetId,
                            status: $0.status,
                            message: $0.message
                        )
                    }
                )
            )
        case .webSearch(let data):
            return .webSearch(
                ConversationWebSearchData(
                    query: data.query,
                    actionJSON: data.actionJson,
                    isInProgress: data.isInProgress
                )
            )
        case .imageView(let data):
            return .imageView(
                ConversationImageViewData(
                    path: data.path
                )
            )
        case .imageGeneration(let data):
            return .imageGeneration(
                ConversationImageGenerationData(
                    status: data.status,
                    revisedPrompt: data.revisedPrompt,
                    imagePNG: data.imagePng,
                    savedPath: data.savedPath
                )
            )
        case .widget(let data):
            return .widget(
                ConversationWidgetData(
                    widgetState: WidgetState(
                        callId: itemId,
                        title: data.title,
                        widgetHTML: data.widgetHtml,
                        width: CGFloat(data.width),
                        height: CGFloat(data.height),
                        isFinalized: data.isFinalized,
                        appId: data.appId.flatMap { $0.isEmpty ? nil : $0 }
                    ),
                    status: data.status
                )
            )
        case .userInputResponse(let data):
            return .userInputResponse(
                ConversationUserInputResponseData(
                    questions: data.questions.map {
                        ConversationUserInputQuestionData(
                            id: $0.id,
                            header: $0.header,
                            question: $0.question,
                            answer: $0.answer,
                            options: $0.options.map {
                                ConversationUserInputOptionData(
                                    label: $0.label,
                                    description: $0.description
                                )
                            }
                        )
                    }
                )
            )
        case .divider(let data):
            switch data {
            case .contextCompaction(let isComplete):
                return .divider(.contextCompaction(isComplete: isComplete))
            case .modelRerouted(let fromModel, let toModel, let reason):
                return .divider(
                    .modelRerouted(
                        fromModel: fromModel,
                        toModel: toModel,
                        reason: reason
                    )
                )
            case .reviewEntered(let review):
                return .divider(.reviewEntered(review))
            case .reviewExited(let review):
                return .divider(.reviewExited(review))
            }
        case .error(let data):
            return .error(
                ConversationSystemErrorData(
                    title: data.title,
                    message: data.message,
                    details: data.details
                )
            )
        case .note(let data):
            return .note(ConversationNoteData(title: data.title, body: data.body))
        }
    }
}
