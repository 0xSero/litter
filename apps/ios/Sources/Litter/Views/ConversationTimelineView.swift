import SwiftUI
import HairballUI
import UIKit

enum ConversationLiveDetailRetentionPolicy {
    static func retainedRichDetailItemIDs(for items: [ConversationItem]) -> Set<String> {
        var retained = Set<String>()

        if let active = items.last(where: { $0.liveDetailStatus == .inProgress }) {
            retained.insert(active.id)
        }

        if let latestCompleted = items.reversed().first(where: { item in
            guard let status = item.liveDetailStatus else { return false }
            return status != .inProgress
        }) {
            retained.insert(latestCompleted.id)
        }

        return retained
    }
}

struct ConversationTurnTimeline: View {
    let items: [ConversationItem]
    let isLive: Bool
    let serverId: String
    let originThreadId: String?
    let agentDirectoryVersion: UInt64
    let messageActionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let onLiveContentLayoutChanged: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    var body: some View {
        timelineContent
    }

    private var timelineContent: some View {
        let rows = rowDescriptors
        let retainedRichDetailItemIDs = ConversationLiveDetailRetentionPolicy.retainedRichDetailItemIDs(for: items)
        let latestCommandExecutionItemId = rows.reversed().compactMap { row -> String? in
            guard case .item(let item) = row,
                  case .commandExecution(let data) = item.content,
                  !data.isPureExploration else { return nil }
            return item.id
        }.first

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(
                    row,
                    isLastRow: index == rows.indices.last,
                    isPreferredExpandedCommandRow: row.preferredExpandedCommandRow(
                        latestCommandExecutionItemId: latestCommandExecutionItemId
                    ),
                    retainedRichDetailItemIDs: retainedRichDetailItemIDs
                )
                    .id(row.id)
                    .modifier(RowEntranceModifier(isAssistantRow: row.isAssistantRow))
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { oldHeight, newHeight in
                        guard isLive, abs(newHeight - oldHeight) > 0.5 else { return }
                        onLiveContentLayoutChanged?()
                    }
            }
        }
    }

    private var rowDescriptors: [ConversationTimelineRowDescriptor] {
        ConversationTimelineRowDescriptor.mergeConsecutiveExplorationRows(
            ConversationTimelineRowDescriptor.build(from: items)
        )
    }

    private var streamingAssistantItemId: String? {
        guard isLive else { return nil }
        return items.last(where: \.isAssistantItem)?.id
    }

    // Returns AnyView rather than `some View` with @ViewBuilder so the result
    // type doesn't fan out to Group<_ConditionalContent<_ConditionalContent<…>, …>>.
    // Time Profiler showed 44% of main-thread CPU in `outlined destroy` of that
    // nested union; AnyView's per-node diff overhead is cheaper than destroying
    // the union every SwiftUI pass.
    private func rowView(
        _ row: ConversationTimelineRowDescriptor,
        isLastRow: Bool,
        isPreferredExpandedCommandRow: Bool,
        retainedRichDetailItemIDs: Set<String>
    ) -> AnyView {
        switch row {
        case .item(let item):
            return AnyView(
                ConversationTimelineItemRow(
                    item: item,
                    serverId: serverId,
                    originThreadId: originThreadId,
                    agentDirectoryVersion: agentDirectoryVersion,
                    isPreferredExpandedCommandRow: isPreferredExpandedCommandRow,
                    isLiveTurn: isLive,
                    isStreamingMessage: item.id == streamingAssistantItemId,
                    shouldPreserveRichDetail: retainedRichDetailItemIDs.contains(item.id),
                    messageActionsDisabled: messageActionsDisabled,
                    onStreamingSnapshotRendered: item.id == streamingAssistantItemId ? onStreamingSnapshotRendered : nil,
                    onLiveContentLayoutChanged: onLiveContentLayoutChanged,
                    resolveTargetLabel: resolveTargetLabel,
                    onWidgetPrompt: onWidgetPrompt,
                    onEditUserItem: onEditUserItem,
                    onForkFromUserItem: onForkFromUserItem,
                    onOpenConversation: onOpenConversation
                )
                .equatable()
            )
        case .exploration(let id, let items):
            return AnyView(
                ConversationExplorationGroupRow(
                    id: id,
                    items: items,
                    showsCollapsedPreview: isLastRow
                )
            )
        case .subagentGroup(_, let merged, _):
            return AnyView(
                SubagentCardView(
                    data: merged,
                    serverId: serverId
                )
            )
        }
    }
}

private enum ConversationTimelineRowDescriptor: Identifiable, Equatable {
    case item(ConversationItem)
    case exploration(id: String, items: [ConversationItem])
    case subagentGroup(id: String, merged: ConversationMultiAgentActionData, sourceItems: [ConversationItem])

    var id: String {
        switch self {
        case .item(let item):
            return item.id
        case .exploration(let id, _):
            return id
        case .subagentGroup(let id, _, _):
            return id
        }
    }

    var isAssistantRow: Bool {
        guard case .item(let item) = self else { return false }
        return item.isAssistantItem
    }

    func preferredExpandedCommandRow(latestCommandExecutionItemId: String?) -> Bool {
        guard case .item(let item) = self,
              case .commandExecution(let data) = item.content,
              !data.isPureExploration else {
            return false
        }
        return item.id == latestCommandExecutionItemId
    }

    static func build(from items: [ConversationItem]) -> [ConversationTimelineRowDescriptor] {
        var rows: [ConversationTimelineRowDescriptor] = []
        var explorationBuffer: [ConversationItem] = []
        var subagentBuffer: [(item: ConversationItem, data: ConversationMultiAgentActionData)] = []
        var subagentTool: String?

        func flushExplorationBuffer() {
            guard !explorationBuffer.isEmpty else { return }
            let seed = explorationBuffer.first?.id ?? UUID().uuidString
            rows.append(.exploration(id: "exploration-\(seed)", items: explorationBuffer))
            explorationBuffer.removeAll(keepingCapacity: true)
        }

        func flushSubagentBuffer() {
            guard !subagentBuffer.isEmpty else { return }
            if subagentBuffer.count == 1 {
                rows.append(.item(subagentBuffer[0].item))
            } else {
                let seed = subagentBuffer.first?.item.id ?? UUID().uuidString
                // Merge all targets, threadIds, states, pick the latest status
                var mergedTargets: [String] = []
                var mergedThreadIds: [String] = []
                var mergedStates: [ConversationMultiAgentState] = []
                var mergedPrompts: [String] = []
                var latestStatus: AppOperationStatus = .completed
                let tool = subagentBuffer.first?.data.tool ?? "spawnAgent"

                for entry in subagentBuffer {
                    mergedTargets.append(contentsOf: entry.data.targets)
                    mergedThreadIds.append(contentsOf: entry.data.receiverThreadIds)
                    mergedStates.append(contentsOf: entry.data.agentStates)
                    if let p = entry.data.prompt, !p.isEmpty {
                        mergedPrompts.append(p)
                    }
                    if entry.data.isInProgress {
                        latestStatus = .inProgress
                    }
                }

                let merged = ConversationMultiAgentActionData(
                    tool: tool,
                    status: latestStatus,
                    prompt: nil,
                    targets: mergedTargets,
                    receiverThreadIds: mergedThreadIds,
                    agentStates: mergedStates,
                    perAgentPrompts: mergedPrompts
                )
                rows.append(.subagentGroup(
                    id: "subagent-group-\(seed)",
                    merged: merged,
                    sourceItems: subagentBuffer.map(\.item)
                ))
            }
            subagentBuffer.removeAll(keepingCapacity: true)
            subagentTool = nil
        }

        for item in items {
            if item.isVisuallyEmptyNeutralItem {
                continue
            } else if case .multiAgentAction(let data) = item.content {
                let tool = data.tool.lowercased()
                if let currentTool = subagentTool, currentTool == tool {
                    subagentBuffer.append((item, data))
                } else {
                    flushExplorationBuffer()
                    flushSubagentBuffer()
                    subagentBuffer.append((item, data))
                    subagentTool = tool
                }
            } else if case .commandExecution(let data) = item.content, data.isPureExploration {
                flushSubagentBuffer()
                explorationBuffer.append(item)
            } else {
                flushExplorationBuffer()
                flushSubagentBuffer()
                rows.append(.item(item))
            }
        }

        flushExplorationBuffer()
        flushSubagentBuffer()
        return rows
    }

    static func mergeConsecutiveExplorationRows(
        _ rows: [ConversationTimelineRowDescriptor]
    ) -> [ConversationTimelineRowDescriptor] {
        var mergedRows: [ConversationTimelineRowDescriptor] = []
        var explorationAccumulator: (id: String, items: [ConversationItem])?

        func flushAccumulator() {
            guard let accumulator = explorationAccumulator else { return }
            mergedRows.append(
                .exploration(
                    id: accumulator.id,
                    items: accumulator.items
                )
            )
            explorationAccumulator = nil
        }

        for row in rows {
            switch row {
            case .exploration(let id, let items):
                if var existing = explorationAccumulator {
                    existing.items.append(contentsOf: items)
                    explorationAccumulator = existing
                } else {
                    explorationAccumulator = (id: id, items: items)
                }
            case .item(let item) where item.isExplorationCommandItem:
                if var existing = explorationAccumulator {
                    existing.items.append(item)
                    explorationAccumulator = existing
                } else {
                    explorationAccumulator = (id: "exploration-\(item.id)", items: [item])
                }
            default:
                flushAccumulator()
                mergedRows.append(row)
            }
        }

        flushAccumulator()
        return mergedRows
    }
}

private struct RowEntranceModifier: ViewModifier {
    let isAssistantRow: Bool

    func body(content: Content) -> some View {
        if isAssistantRow {
            // The streaming markdown renderer scopes its own
            // `transaction { $0.animation = nil }` internally so that token
            // reveals don't replay on every snapshot. Leaving the row itself
            // unscoped lets sibling layout changes (e.g. a tool card collapse)
            // animate this row's position.
            content
        } else {
            content
                .transition(.asymmetric(
                    insertion: .rowEntranceReveal,
                    removal: .opacity
                ))
        }
    }
}

struct RowEntranceEffect: ViewModifier, Animatable {
    var progress: CGFloat
    var yOffset: CGFloat
    var minScale: CGFloat
    var maxBlur: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clampedProgress = min(max(progress, 0), 1)
        let revealProgress = max(clampedProgress, 0.001)

        content
            .compositingGroup()
            .scaleEffect(
                x: 1,
                y: minScale + ((1 - minScale) * clampedProgress),
                anchor: .topLeading
            )
            .offset(y: yOffset * (1 - clampedProgress))
            .opacity(clampedProgress)
            .blur(radius: maxBlur * (1 - clampedProgress))
            .mask(alignment: .topLeading) {
                Rectangle()
                    .scaleEffect(x: 1, y: revealProgress, anchor: .topLeading)
            }
    }
}

extension AnyTransition {
    static var rowEntranceReveal: AnyTransition {
        .modifier(
            active: RowEntranceEffect(progress: 0, yOffset: 10, minScale: 0.965, maxBlur: 2.5),
            identity: RowEntranceEffect(progress: 1, yOffset: 0, minScale: 1, maxBlur: 0)
        )
    }

    static var sectionReveal: AnyTransition {
        .modifier(
            active: RowEntranceEffect(progress: 0, yOffset: 6, minScale: 0.985, maxBlur: 1.2),
            identity: RowEntranceEffect(progress: 1, yOffset: 0, minScale: 1, maxBlur: 0)
        )
    }
}

private struct ConversationTimelineItemRow: View, Equatable {
    private let renderCache = MessageRenderCache.shared
    @Environment(ThemeManager.self) private var themeManager

    let item: ConversationItem
    let serverId: String
    let originThreadId: String?
    let agentDirectoryVersion: UInt64
    let isPreferredExpandedCommandRow: Bool
    let isLiveTurn: Bool
    let isStreamingMessage: Bool
    let shouldPreserveRichDetail: Bool
    let messageActionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let onLiveContentLayoutChanged: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    static func == (lhs: ConversationTimelineItemRow, rhs: ConversationTimelineItemRow) -> Bool {
        let isAssistant = lhs.item.isAssistantItem
        // For assistant rows: the StreamingRendererCoordinator owns the
        // streaming→finished lifecycle.  Skip digest, richDetail, AND
        // isStreamingMessage so the bubble body never re-evaluates when
        // a tool call arrives and a new assistant message takes over as
        // the "streaming" item.  Re-rendering the bubble would recreate
        // StreamingMarkdownContentView and replay the token reveal.
        let result = lhs.item.id == rhs.item.id &&
            (isAssistant || lhs.item.renderDigest == rhs.item.renderDigest) &&
            (isAssistant || lhs.shouldPreserveRichDetail == rhs.shouldPreserveRichDetail) &&
            (isAssistant || lhs.isStreamingMessage == rhs.isStreamingMessage) &&
            lhs.serverId == rhs.serverId &&
            lhs.originThreadId == rhs.originThreadId &&
            lhs.agentDirectoryVersion == rhs.agentDirectoryVersion &&
            lhs.isPreferredExpandedCommandRow == rhs.isPreferredExpandedCommandRow &&
            lhs.isLiveTurn == rhs.isLiveTurn &&
            lhs.messageActionsDisabled == rhs.messageActionsDisabled
        return result
    }

    // 16-case switch returns AnyView rather than `some View` so the body type
    // doesn't resolve to a 4-deep `Group<_ConditionalContent<…>>` nested union.
    // Time Profiler on 2026-04-18 showed that union's `outlined destroy` +
    // witness-table accessor accounting for ~49% of main-thread CPU on device.
    var body: AnyView {
        switch item.content {
        case .user(let data):
            return AnyView(userRow(data))
        case .assistant(let data):
            return AnyView(assistantRow(data))
        case .codeReview(let data):
            return AnyView(ConversationCodeReviewRow(data: data))
        case .reasoning(let data):
            return AnyView(ConversationReasoningRow(data: data))
        case .todoList(let data):
            return AnyView(ConversationTodoListRow(data: data))
        case .proposedPlan(let data):
            return AnyView(ConversationProposedPlanRow(data: data))
        case .commandExecution(let data):
            return AnyView(commandExecutionRow(data))
        case .fileChange(let data):
            return AnyView(toolCallRow(makeFileChangeModel(data)))
        case .turnDiff(let data):
            return AnyView(ConversationTurnDiffRow(data: data))
        case .mcpToolCall(let data):
            if let view = data.computerUse {
                return AnyView(
                    ComputerUseToolCallView(
                        data: data,
                        view: view,
                        externalExpanded: !isLiveTurn && shouldPreserveRichDetail
                    )
                )
            } else {
                return AnyView(toolCallRow(makeMcpModel(data)))
            }
        case .dynamicToolCall(let data):
            if CrossServerTools.isRichTool(data.tool) {
                return AnyView(CrossServerToolResultView(data: data))
            } else {
                return AnyView(toolCallRow(makeDynamicToolModel(data)))
            }
        case .multiAgentAction(let data):
            return AnyView(
                SubagentCardView(
                    data: data,
                    serverId: serverId
                )
            )
        case .webSearch(let data):
            return AnyView(toolCallRow(makeWebSearchModel(data)))
        case .imageView(let data):
            return AnyView(toolCallRow(makeImageViewModel(data)))
        case .imageGeneration(let data):
            return AnyView(
                ImageGenerationToolCallView(
                    data: data,
                    externalExpanded: !isLiveTurn && shouldPreserveRichDetail
                )
            )
        case .widget(let data):
            return AnyView(
                WidgetContainerView(
                    widget: data.widgetState,
                    originThreadId: originThreadId,
                    onMessage: handleWidgetMessage
                )
            )
        case .userInputResponse(let data):
            return AnyView(ConversationUserInputResponseRow(data: data))
        case .divider(let kind):
            return AnyView(ConversationDividerRow(kind: kind, isLiveTurn: isLiveTurn))
        case .error(let data):
            return AnyView(
                ConversationSystemCardRow(
                    title: data.title.isEmpty ? "Error" : data.title,
                    content: [data.message, data.details].compactMap { $0 }.joined(separator: "\n\n"),
                    accent: LitterTheme.danger,
                    iconName: "exclamationmark.triangle.fill",
                )
            )
        case .note(let data):
            return AnyView(
                ConversationSystemCardRow(
                    title: data.title,
                    content: data.body,
                    accent: LitterTheme.accent,
                    iconName: "info.circle.fill"
                )
            )
        }
    }

    @ViewBuilder
    private func commandExecutionRow(_ data: ConversationCommandExecutionData) -> some View {
        ConversationCommandExecutionRow(
            data: data,
            isPreferredExpanded: isPreferredExpandedCommandRow
                || data.isInProgress
                || (!isLiveTurn && shouldPreserveRichDetail)
        )
    }

    @ViewBuilder
    private func toolCallRow(_ model: ToolCallCardModel) -> some View {
        ToolCallCardView(
            model: model,
            serverId: serverId,
            externalExpanded: !isLiveTurn && shouldPreserveRichDetail
        )
    }

    private func userRow(_ data: ConversationUserMessageData) -> some View {
        UserBubble(text: data.text, images: data.images)
            .contextMenu {
                if !data.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Copy") {
                        UIPasteboard.general.string = data.text
                    }
                }

                if item.isFromUserTurnBoundary {
                    Button("Edit Message") {
                        onEditUserItem(item)
                    }
                    .disabled(messageActionsDisabled)

                    Button("Fork From Here") {
                        onForkFromUserItem(item)
                    }
                    .disabled(messageActionsDisabled)
                }
            }
    }

    @ViewBuilder
    private func assistantRow(_ data: ConversationAssistantMessageData) -> some View {
        let assistantLabel = AgentLabelFormatter.format(
            nickname: data.agentNickname,
            role: data.agentRole
        )

        StreamingAssistantBubble(
            itemId: item.id,
            text: data.text,
            isStreaming: isStreamingMessage,
            label: assistantLabel,
            themeVersion: themeManager.themeVersion,
            onSnapshotRendered: isStreamingMessage ? onStreamingSnapshotRendered : nil
        )
    }

    private func handleWidgetMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["_type"] as? String else { return }
        switch type {
        case "sendPrompt":
            if let text = dict["text"] as? String, !text.isEmpty {
                onWidgetPrompt(text)
            }
        case "openLink":
            if let urlString = dict["url"] as? String, let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }

    private func makeFileChangeModel(_ data: ConversationFileChangeData) -> ToolCallCardModel {
        let changedPaths = data.changes.map(\.path)
        let summary = fileChangeSummary(for: data)

        let diffSections = data.changes.compactMap { change -> ToolCallSection? in
            guard !change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let label = data.changes.count > 1 ? workspaceTitle(for: change.path) : ""
            return .diff(label: label, content: change.diff)
        }

        var sections: [ToolCallSection] = []
        if diffSections.isEmpty, !changedPaths.isEmpty {
            sections.append(.list(label: "Files", items: changedPaths.map(workspaceTitle(for:))))
        }
        sections.append(contentsOf: diffSections)
        if let outputDelta = data.outputDelta?.trimmingCharacters(in: .whitespacesAndNewlines), !outputDelta.isEmpty {
            sections.append(.text(label: "Output", content: outputDelta))
        }

        return ToolCallCardModel(
            kind: .fileChange,
            title: "File Change",
            summary: summary.plainText,
            attributedSummary: summary.attributedText,
            status: data.status.toolCallStatus,
            duration: nil,
            sections: sections
        )
    }

    private func fileChangeSummary(for data: ConversationFileChangeData) -> (plainText: String, attributedText: AttributedString?) {
        guard !data.changes.isEmpty else {
            return ("File changes", nil)
        }

        let additions = data.changes.reduce(0) { $0 + $1.additions }
        let deletions = data.changes.reduce(0) { $0 + $1.deletions }
        let hasCountSummary = additions > 0 || deletions > 0

        if data.changes.count == 1, let change = data.changes.first {
            let verb = fileChangeVerb(for: change.kind)
            let filename = workspaceTitle(for: change.path)
            guard hasCountSummary else {
                return ("\(verb) \(filename)", nil)
            }

            let plainText = "\(verb) \(filename) +\(additions) -\(deletions)"

            var attributed = AttributedString()

            var verbText = AttributedString("\(verb) ")
            verbText.foregroundColor = LitterTheme.textSecondary
            attributed.append(verbText)

            var fileText = AttributedString(filename)
            fileText.foregroundColor = LitterTheme.accent
            attributed.append(fileText)

            var additionsText = AttributedString(" +\(additions)")
            additionsText.foregroundColor = LitterTheme.success
            attributed.append(additionsText)

            var deletionsText = AttributedString(" -\(deletions)")
            deletionsText.foregroundColor = LitterTheme.danger
            attributed.append(deletionsText)

            return (plainText, attributed)
        }

        guard hasCountSummary else {
            return ("Changed \(data.changes.count) files", nil)
        }

        let plainText = "Changed \(data.changes.count) files +\(additions) -\(deletions)"
        var attributed = AttributedString("Changed \(data.changes.count) files")
        attributed.foregroundColor = LitterTheme.textSystem

        var additionsText = AttributedString(" +\(additions)")
        additionsText.foregroundColor = LitterTheme.success
        attributed.append(additionsText)

        var deletionsText = AttributedString(" -\(deletions)")
        deletionsText.foregroundColor = LitterTheme.danger
        attributed.append(deletionsText)

        return (plainText, attributed)
    }

    private func fileChangeVerb(for kind: String) -> String {
        switch kind.lowercased() {
        case "add":
            return "Added"
        case "delete":
            return "Deleted"
        case "update":
            return "Edited"
        default:
            return "Changed"
        }
    }

    private func makeMcpModel(_ data: ConversationMcpToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            sections.append(.text(label: "Result", content: contentSummary))
        }
        if let structured = data.structuredContentJSON, !structured.isEmpty {
            sections.append(.json(label: "Structured", content: structured))
        }
        if let raw = data.rawOutputJSON, !raw.isEmpty {
            sections.append(.json(label: "Raw Output", content: raw))
        }
        if !data.progressMessages.isEmpty {
            sections.append(.progress(label: "Progress", items: data.progressMessages))
        }
        if let error = data.errorMessage, !error.isEmpty {
            sections.append(.text(label: "Error", content: error))
        }

        let summary = data.server.isEmpty
            ? data.tool
            : "\(data.server).\(data.tool)"

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: "MCP Tool Call",
            summary: summary,
            status: data.status.toolCallStatus,
            duration: formatDuration(data.durationMs),
            sections: sections
        )
    }

    private func makeDynamicToolModel(_ data: ConversationDynamicToolCallData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        var metadata: [ToolCallKeyValue] = []
        if let display = data.display {
            metadata.append(contentsOf: display.metadata.map {
                ToolCallKeyValue(key: $0.key, value: $0.value)
            })
        }
        if let namespace = data.namespace, !namespace.isEmpty {
            metadata.append(ToolCallKeyValue(key: "Namespace", value: namespace))
        }
        if let success = data.success {
            metadata.append(ToolCallKeyValue(key: "Success", value: success ? "true" : "false"))
        }
        if !metadata.isEmpty {
            sections.append(.kv(label: "Metadata", entries: metadata))
        }
        if let arguments = data.argumentsJSON, !arguments.isEmpty {
            sections.append(.json(label: "Arguments", content: arguments))
        }
        if let contentSummary = data.contentSummary, !contentSummary.isEmpty {
            sections.append(.text(label: "Result", content: contentSummary))
        }
        let title = data.display?.title ?? "Dynamic Tool Call"
        let summary = data.display?.summary
            ?? data.namespace.map { "\($0).\(data.tool)" }
            ?? data.tool

        return ToolCallCardModel(
            kind: .mcpToolCall,
            title: title,
            summary: summary,
            status: data.status.toolCallStatus,
            duration: formatDuration(data.durationMs),
            sections: sections
        )
    }

    private func makeWebSearchModel(_ data: ConversationWebSearchData) -> ToolCallCardModel {
        var sections: [ToolCallSection] = []
        if !data.query.isEmpty {
            sections.append(.text(label: "Query", content: data.query))
        }
        if let action = data.actionJSON, !action.isEmpty {
            sections.append(.json(label: "Action", content: action))
        }
        return ToolCallCardModel(
            kind: .webSearch,
            title: "Web Search",
            summary: data.query.isEmpty ? "Web search" : "Web search for \(data.query)",
            status: data.isInProgress ? .inProgress : .completed,
            duration: nil,
            sections: sections
        )
    }

    private func makeImageViewModel(_ data: ConversationImageViewData) -> ToolCallCardModel {
        let trimmedPath = data.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = workspaceTitle(for: trimmedPath)
        return ToolCallCardModel(
            kind: .imageView,
            title: "Image View",
            summary: displayName.isEmpty ? "Image" : displayName,
            status: .completed,
            duration: nil,
            sections: [
                .kv(
                    label: "Metadata",
                    entries: [ToolCallKeyValue(key: "Path", value: trimmedPath)]
                )
            ],
            initiallyExpanded: true
        )
    }
}

private struct ConversationExplorationGroupRow: View {
    @Environment(\.textScale) private var textScale

    let id: String
    let items: [ConversationItem]
    let showsCollapsedPreview: Bool

    @State private var expanded = false

    var body: some View {
        let entries = explorationEntries

        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .litterFont(size: 12, weight: .semibold)
                        .foregroundColor(isActive ? LitterTheme.warning : LitterTheme.textSecondary)
                    Text(verbatim: summaryText)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSystem)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .litterFont(size: 11, weight: .medium)
                        .foregroundColor(LitterTheme.textMuted)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(entry.isInProgress ? LitterTheme.warning : LitterTheme.textMuted)
                                .frame(width: explorationBulletSize, height: explorationBulletSize)
                                .padding(.top, explorationBulletTopPadding)
                            Text(verbatim: entry.label)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else if showsCollapsedPreview && !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(entry.isInProgress ? LitterTheme.warning : LitterTheme.textMuted)
                                        .frame(width: explorationBulletSize, height: explorationBulletSize)
                                        .padding(.top, explorationBulletTopPadding)
                                    Text(verbatim: displayedCollapsedLabel(for: entry))
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorId)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: collapsedPreviewHeight)
                    .background(LitterTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [LitterTheme.surface.opacity(0.92), LitterTheme.surface.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                    }
                    .onAppear {
                        scrollToBottom(proxy)
                    }
                    .onChange(of: collapsedPreviewScrollSignature) { _, _ in
                        scrollToBottom(proxy, animated: true)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: showsCollapsedPreview) { _, newValue in
            guard !newValue else { return }
            expanded = false
        }
    }

    private var summaryText: String {
        let prefix = isActive ? "Exploring" : "Explored"
        return explorationSummaryText(prefix: prefix)
    }

    private var explorationBulletSize: CGFloat {
        6 * textScale
    }

    private var explorationBulletTopPadding: CGFloat {
        5 * textScale
    }

    private var collapsedPreviewHeight: CGFloat {
        (LitterFont.uiMonoFont(size: 12 * textScale).lineHeight * 3) + 18
    }

    private var bottomAnchorId: String {
        "\(id)-exploration-bottom"
    }

    private var collapsedPreviewScrollSignature: String {
        explorationEntries
            .map { "\($0.id)|\($0.label)|\($0.isInProgress)" }
            .joined(separator: "\n")
    }

    private var isActive: Bool {
        explorationEntries.contains(where: \.isInProgress)
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.2)) {
            expanded.toggle()
        }
    }

    private func displayedCollapsedLabel(for entry: ExplorationDisplayEntry) -> String {
        let collapsed = entry.label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 140 {
            return collapsed
        }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 140)
        return "\(collapsed[..<cutoff])..."
    }

    private var explorationEntries: [ExplorationDisplayEntry] {
        items.flatMap { item -> [ExplorationDisplayEntry] in
            guard case .commandExecution(let data) = item.content else { return [] }
            if data.actions.isEmpty {
                return [
                    ExplorationDisplayEntry(
                        id: "\(item.id)-command",
                        label: data.command,
                        isInProgress: data.isInProgress
                    )
                ]
            }
            return data.actions.enumerated().map { index, action in
                ExplorationDisplayEntry(
                    id: "\(item.id)-\(index)",
                    label: explorationLabel(for: action, fallback: data.command),
                    isInProgress: data.isInProgress
                )
            }
        }
    }

    private func explorationSummaryText(prefix: String) -> String {
        var readCount = 0
        var searchCount = 0
        var listingCount = 0
        var fallbackCount = 0

        for item in items {
            guard case .commandExecution(let data) = item.content else { continue }
            if data.actions.isEmpty {
                fallbackCount += 1
                continue
            }
            for action in data.actions {
                switch action.kind {
                case .read:
                    readCount += 1
                case .search:
                    searchCount += 1
                case .listFiles:
                    listingCount += 1
                case .unknown:
                    fallbackCount += 1
                }
            }
        }

        var parts: [String] = []
        if readCount > 0 {
            parts.append("\(readCount) \(readCount == 1 ? "file" : "files")")
        }
        if searchCount > 0 {
            parts.append("\(searchCount) \(searchCount == 1 ? "search" : "searches")")
        }
        if listingCount > 0 {
            parts.append("\(listingCount) \(listingCount == 1 ? "listing" : "listings")")
        }
        if fallbackCount > 0 {
            parts.append("\(fallbackCount) \(fallbackCount == 1 ? "step" : "steps")")
        }
        if parts.isEmpty {
            let count = explorationEntries.count
            return count == 1 ? "\(prefix) 1 exploration step" : "\(prefix) \(count) exploration steps"
        }
        return "\(prefix) \(parts.joined(separator: ", "))"
    }

    private func explorationLabel(for action: ConversationCommandAction, fallback: String) -> String {
        let suffix = explorationCommandSuffix(for: action)
        switch action.kind {
        case .read:
            return action.path.map { "Read \(workspaceTitle(for: $0))\(suffix)" } ?? fallback
        case .search:
            if let query = action.query, let path = action.path {
                return "Searched for \(query) in \(workspaceTitle(for: path))\(suffix)"
            }
            if let query = action.query {
                return "Searched for \(query)\(suffix)"
            }
            return fallback
        case .listFiles:
            return action.path.map { "Listed files in \(workspaceTitle(for: $0))\(suffix)" } ?? fallback
        case .unknown:
            return fallback
        }
    }

    private func explorationCommandSuffix(for action: ConversationCommandAction) -> String {
        let command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.hasSuffix(")"),
              let start = command.range(of: " (", options: .backwards)?.lowerBound else {
            return ""
        }
        return String(command[start...])
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }
}

private struct ExplorationDisplayEntry: Identifiable {
    let id: String
    let label: String
    let isInProgress: Bool
}

private struct ConversationReasoningRow: View {
    let data: ConversationReasoningData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(reasoningText)
                .litterFont(.footnote)
                .italic()
                .foregroundColor(LitterTheme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 20)
        }
    }

    private var reasoningText: String {
        (data.summary + data.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

private struct ConversationTodoListRow: View {
    let data: ConversationTodoListData
    private let bodySize: CGFloat = 13
    private let codeSize: CGFloat = 12
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: headerIconName)
                        .litterFont(size: 12, weight: .semibold)
                        .foregroundColor(headerTint)
                    Text("To Do")
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(summaryText)
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(progressTint)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .litterFont(size: 11, weight: .medium)
                        .foregroundColor(LitterTheme.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(data.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                todoStatusView(for: step.status)
                                    .padding(.top, 2)
                                Text("\(index + 1).")
                                    .litterFont(.caption, weight: .semibold)
                                    .foregroundColor(LitterTheme.textMuted)
                                    .padding(.top, 1)
                                LitterMarkdownView(
                                    markdown: step.step,
                                    style: .content,
                                    bodySize: bodySize,
                                    codeSize: codeSize
                                )
                                    .strikethrough(step.status == .completed, color: LitterTheme.textMuted)
                                    .opacity(step.status == .completed ? 0.78 : 1.0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 160)
                .background(LitterTheme.surface.opacity(0.45))
                .mask {
                    VStack(spacing: 0) {
                        Rectangle().fill(.black)
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.sectionReveal)
            }
        }
    }

    private var completedCount: Int {
        data.completedCount
    }

    private var hasInProgressStep: Bool {
        data.steps.contains { $0.status == .inProgress }
    }

    private var headerIconName: String {
        if data.isComplete { return "checkmark.circle.fill" }
        if hasInProgressStep { return "checklist.checked" }
        return "checklist"
    }

    private var headerTint: Color {
        if data.isComplete { return LitterTheme.success }
        if hasInProgressStep { return LitterTheme.warning }
        return LitterTheme.accent
    }

    private var summaryText: String {
        "\(completedCount) out of \(data.steps.count) task\(data.steps.count == 1 ? "" : "s") completed"
    }

    private var progressTint: Color {
        data.isComplete ? LitterTheme.success : (hasInProgressStep ? LitterTheme.warning : LitterTheme.textSecondary)
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.2)) {
            expanded.toggle()
        }
    }

    @ViewBuilder
    private func todoStatusView(for status: HydratedPlanStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.textMuted)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .tint(LitterTheme.warning)
                .frame(width: 11, height: 11)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.success)
        }
    }
}

private struct ConversationProposedPlanRow: View {
    let data: ConversationProposedPlanData

    private var trimmedContent: String? {
        let trimmed = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        if let trimmedContent {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .litterFont(size: 12, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                    Text("Plan")
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                }

                LitterMarkdownView(
                    markdown: trimmedContent,
                    style: .system
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

private struct ConversationTurnDiffRow: View {
    let data: ConversationTurnDiffData
    @State private var presented: PresentedDiff?

    var body: some View {
        Button {
            presented = PresentedDiff(
                id: "turn-diff",
                title: "Turn Diff",
                diff: data.diff,
                stats: DiffStats(additions: data.additions, deletions: data.deletions),
                sections: presentedDiffSections(from: data.diff)
            )
        } label: {
            DiffIndicatorLabel(additions: data.additions, deletions: data.deletions)
        }
        .buttonStyle(.plain)
        .sheet(item: $presented) { sheet in
            ConversationDiffDetailSheet(
                title: sheet.title,
                diff: sheet.diff ?? "",
                sections: sheet.sections
            )
        }
    }
}

private struct ConversationCommandExecutionRow: View {
    let data: ConversationCommandExecutionData
    let isPreferredExpanded: Bool

    @State private var expanded: Bool

    init(data: ConversationCommandExecutionData, isPreferredExpanded: Bool) {
        self.data = data
        self.isPreferredExpanded = isPreferredExpanded
        _expanded = State(initialValue: isPreferredExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 8 : 0) {
            shellHeader
            if expanded {
                ConversationCommandOutputViewport(
                    output: renderedOutput,
                    status: data.status.toolCallStatus,
                    durationText: nil
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LitterTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LitterTheme.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(duration: 0.35, bounce: 0.15), value: expanded)
        .onChange(of: isPreferredExpanded) { _, newValue in
            expanded = newValue
        }
    }

    private var shellHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("$")
                .litterMonoFont(size: 12, weight: .semibold)
                .foregroundColor(LitterTheme.warning)

            Text(expanded ? displayedCommand : collapsedCommand)
                .litterMonoFont(size: 12)
                .foregroundColor(LitterTheme.textSystem)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let durationText = formatDuration(data.durationMs), !durationText.isEmpty {
                Text(durationText)
                    .litterFont(.caption2)
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(statusColor.opacity(0.10))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(statusColor.opacity(0.22), lineWidth: 0.5)
                    )
                    .accessibilityLabel(durationAccessibilityLabel(durationText))
            }

            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .litterFont(size: 11, weight: .medium)
                .foregroundColor(LitterTheme.textMuted)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expanded.toggle()
            }
        }
    }

    private var renderedOutput: String {
        let trimmed = data.output?.trimmingCharacters(in: .newlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return data.isInProgress ? "Waiting for output…" : "No output"
    }

    private var displayedCommand: String {
        let trimmed = data.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "command" : trimmed
    }

    private var collapsedCommand: String {
        let collapsed = displayedCommand
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "command" : collapsed
    }

    private var statusColor: Color { data.status.toolCallStatus.themeColor }

    private func durationAccessibilityLabel(_ duration: String) -> String {
        switch data.status.toolCallStatus {
        case .completed:
            return "\(duration), completed"
        case .inProgress:
            return "\(duration), in progress"
        case .failed:
            return "\(duration), failed"
        case .unknown:
            return duration
        }
    }
}

private struct ConversationCommandOutputViewport: View {
    let output: String
    let status: ToolCallStatus
    let durationText: String?
    @Environment(\.textScale) private var textScale
    @State private var expandedLongOutput = false

    private let bottomAnchorId = "command-output-bottom"
    private let maxVisibleTextCharacters = 2_000

    private var lineFontSize: CGFloat {
        11 * textScale
    }

    private var maxViewportHeight: CGFloat {
        (LitterFont.uiMonoFont(size: lineFontSize).lineHeight * 3) + 16
    }

    private var viewportHeight: CGFloat {
        let lh = LitterFont.uiMonoFont(size: lineFontSize).lineHeight
        let lines = max(1, visibleOutput.split(separator: "\n", omittingEmptySubsequences: false).count)
        let natural = (lh * CGFloat(min(lines, 3))) + 16
        return min(natural, maxViewportHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: visibleOutput)
                            .litterMonoFont(size: 12)
                            .foregroundColor(LitterTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorId)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .frame(height: viewportHeight)
                .background(LitterTheme.codeBackground.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [LitterTheme.codeBackground.opacity(0.96), LitterTheme.codeBackground.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomTrailing) {
                    if let durationText, !durationText.isEmpty {
                        Text(durationText)
                            .foregroundColor(statusColor)
                            .accessibilityLabel(durationAccessibilityLabel(durationText))
                            .litterFont(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(alignment: .bottom) {
                                LinearGradient(
                                    colors: [.clear, LitterTheme.codeBackground.opacity(0.94)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        }
                    }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(LitterTheme.border.opacity(0.35), lineWidth: 1)
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: output) { _, _ in
                    expandedLongOutput = false
                    scrollToBottom(proxy, animated: true)
                }
                .onChange(of: expandedLongOutput) { _, _ in
                    scrollToBottom(proxy, animated: true)
                }

                if shouldLimitOutput {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedLongOutput.toggle()
                        }
                    } label: {
                        Text(expandedLongOutput ? "Show less" : "Show more")
                            .litterFont(.caption2, weight: .semibold)
                            .foregroundColor(LitterTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedLongOutput ? "Show less command output" : "Show more command output")
                }
            }
        }
    }

    private var visibleOutput: String {
        guard shouldLimitOutput, !expandedLongOutput else {
            return output
        }
        if usesTailPreview {
            return String(output.suffix(maxVisibleTextCharacters))
        }
        return String(output.prefix(maxVisibleTextCharacters))
    }

    private var shouldLimitOutput: Bool {
        output.count > maxVisibleTextCharacters
    }

    private var usesTailPreview: Bool {
        switch status {
        case .inProgress:
            return true
        case .completed, .failed, .unknown:
            return false
        }
    }

    private var statusColor: Color { status.themeColor }

    private func durationAccessibilityLabel(_ duration: String) -> String {
        switch status {
        case .completed:
            return "\(duration), completed"
        case .inProgress:
            return "\(duration), in progress"
        case .failed:
            return "\(duration), failed"
        case .unknown:
            return duration
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(bottomAnchorId, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorId, anchor: .bottom)
            }
        }
    }
}

private struct ConversationUserInputResponseRow: View {
    let data: ConversationUserInputResponseData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(data.questions.enumerated()), id: \.element.id) { _, question in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .litterFont(size: 10, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.header ?? question.question)
                            .litterFont(.caption, weight: .semibold)
                            .foregroundColor(LitterTheme.textSecondary)
                        Text(question.answer)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ConversationDividerRow: View {
    let kind: ConversationDividerKind
    let isLiveTurn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(LitterTheme.border)
                .frame(minWidth: 16, maxHeight: 1)
            dividerContent
                .layoutPriority(1)
            Capsule()
                .fill(LitterTheme.border)
                .frame(minWidth: 16, maxHeight: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var dividerContent: some View {
        switch kind {
        case .contextCompaction:
            HStack(spacing: 6) {
                if effectiveContextCompactionComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .litterFont(size: 10, weight: .semibold)
                        .foregroundColor(LitterTheme.success)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LitterTheme.warning)
                }

                Text(title)
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(
                        effectiveContextCompactionComplete ? LitterTheme.textMuted : LitterTheme.warning
                    )
                    .lineLimit(1)
            }
        default:
            Text(title)
                .litterFont(.caption2, weight: .semibold)
                .foregroundColor(LitterTheme.textMuted)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch kind {
        case .contextCompaction:
            return effectiveContextCompactionComplete ? "Context compacted" : "Compacting context"
        case .modelRerouted(let fromModel, let toModel, let reason):
            let base = fromModel.map { "\($0) -> \(toModel)" } ?? "Routed to \(toModel)"
            if let reason, !reason.isEmpty {
                return "\(base) · \(reason)"
            }
            return base
        case .reviewEntered(let review):
            return review.isEmpty ? "Entered review" : "Entered review: \(review)"
        case .reviewExited(let review):
            return review.isEmpty ? "Exited review" : "Exited review: \(review)"
        case .workedFor(let duration):
            return duration
        case .generic(let title, let detail):
            if let detail, !detail.isEmpty {
                return "\(title): \(detail)"
            }
            return title
        }
    }

    private var effectiveContextCompactionComplete: Bool {
        guard case .contextCompaction(let isComplete) = kind else { return true }
        return isComplete && !isLiveTurn
    }
}

private struct ConversationCodeReviewRow: View {
    let data: ConversationCodeReviewData
    @State private var dismissedFindingIndices: Set<Int> = []

    private var visibleFindings: [(index: Int, finding: ConversationCodeReviewFinding)] {
        data.findings.enumerated().compactMap { index, finding in
            dismissedFindingIndices.contains(index) ? nil : (index, finding)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleFindings, id: \.index) { entry in
                ConversationCodeReviewFindingCard(
                    finding: entry.finding,
                    onDismiss: { dismissedFindingIndices.insert(entry.index) }
                )
            }
        }
    }
}

private struct ConversationCodeReviewFindingCard: View {
    let finding: ConversationCodeReviewFinding
    let onDismiss: () -> Void

    private var priorityLabel: String? {
        finding.priority.map { "P\($0)" }
    }

    private var priorityTint: Color {
        switch finding.priority {
        case 0?, 1?:
            return LitterTheme.danger
        case 2?:
            return LitterTheme.warning
        case 3?:
            return LitterTheme.textSecondary
        default:
            return LitterTheme.textSecondary
        }
    }

    private var locationText: String? {
        guard let location = finding.codeLocation else { return nil }
        guard let lineRange = location.lineRange else { return location.absoluteFilePath }
        if lineRange.start == lineRange.end {
            return "\(location.absoluteFilePath):\(lineRange.start)"
        }
        return "\(location.absoluteFilePath):\(lineRange.start)-\(lineRange.end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                if let priorityLabel {
                    Text(priorityLabel)
                        .litterFont(.caption2, weight: .bold)
                        .foregroundColor(priorityTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(priorityTint.opacity(0.12), in: Capsule())
                }

                Text(finding.title)
                    .litterFont(.headline, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .litterFont(.callout, weight: .medium)
                    .foregroundColor(LitterTheme.textSecondary)
            }

            LitterMarkdownView(markdown: finding.body, style: .content, selectionEnabled: true)

            if let locationText, !locationText.isEmpty {
                Text(locationText)
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(LitterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(LitterTheme.border.opacity(0.7), lineWidth: 1)
        )
    }
}

private struct ConversationSystemCardRow: View {
    let title: String
    let content: String
    let accent: Color
    let iconName: String

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .litterFont(size: 11, weight: .semibold)
                    .foregroundColor(accent)
                Text(title.uppercased())
                    .litterFont(.caption2, weight: .bold)
                    .foregroundColor(accent)
            }
            if !content.isEmpty {
                LitterMarkdownView(
                    markdown: content,
                    style: .system
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View { bodyView }
}

struct ConversationPinnedContextStrip: View {
    let items: [ConversationItem]
    @State private var todoExpanded = false
    @State private var selectedDiff: PresentedDiff?
    @State private var cachedCombinedPinnedDiff: PresentedDiff?

    init(items: [ConversationItem]) {
        self.items = items
        _cachedCombinedPinnedDiff = State(
            initialValue: Self.buildCombinedPinnedDiff(from: items)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pinnedPlan != nil || cachedCombinedPinnedDiff != nil {
                if let plan = pinnedPlan, let diff = cachedCombinedPinnedDiff {
                    HStack(alignment: .top, spacing: 10) {
                        compactTodoAccordion(for: plan)
                            .layoutPriority(1)
                        diffIndicatorButton(for: diff)
                    }
                } else {
                    if let plan = pinnedPlan {
                        compactTodoAccordion(for: plan)
                    }

                    if let diff = cachedCombinedPinnedDiff {
                        diffIndicatorButton(for: diff)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .sheet(item: $selectedDiff) { presentedDiff in
            ConversationDiffDetailSheet(
                title: presentedDiff.title,
                diff: presentedDiff.diff ?? "",
                sections: presentedDiff.sections
            )
        }
        .onChange(of: pinnedDiffTaskKey, initial: false) { _, _ in
            cachedCombinedPinnedDiff = Self.buildCombinedPinnedDiff(from: items)
        }
    }

    private var pinnedPlan: ConversationItem? {
        items.last(where: {
            if case .todoList(let data) = $0.content {
                return !data.steps.isEmpty
            }
            return false
        })
    }

    private var pinnedDiffTaskKey: [Int] {
        items.map(\.renderDigest)
    }

    private static func buildCombinedPinnedDiff(from items: [ConversationItem]) -> PresentedDiff? {
        let rawSections = items.flatMap { item -> [PresentedDiffSection] in
            switch item.content {
            case .fileChange(let data):
                return data.changes.compactMap { change in
                    let diff = change.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !diff.isEmpty else { return nil }
                    return PresentedDiffSection(
                        title: workspaceTitle(for: change.path),
                        diff: diff
                    )
                }
            case .turnDiff(let data):
                let diff = data.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                return diff.isEmpty ? [] : presentedDiffSections(from: diff)
            default:
                return []
            }
        }

        let sections = mergePresentedDiffSections(rawSections)
        guard !sections.isEmpty else { return nil }
        let stats = sections.reduce(into: DiffStats(additions: 0, deletions: 0)) { partial, section in
            let sectionStats = DiffStats(diff: section.diff)
            partial = DiffStats(
                additions: partial.additions + sectionStats.additions,
                deletions: partial.deletions + sectionStats.deletions
            )
        }
        return PresentedDiff(
            id: "session-diff",
            title: "Session Diff",
            diff: nil,
            stats: stats,
            sections: sections
        )
    }

    @ViewBuilder
    private func compactTodoAccordion(for item: ConversationItem) -> some View {
        if case .todoList(let data) = item.content {
            let completed = data.completedCount
            let total = data.steps.count
            let summary: String = {
                if completed == 0 {
                    return "To do list created with \(total) tasks"
                }
                return "\(completed) out of \(total) tasks completed"
            }()

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        todoExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: completed == total && total > 0 ? "checkmark.circle.fill" : "checklist")
                            .litterFont(size: 11, weight: .semibold)
                            .foregroundColor(completed == total && total > 0 ? LitterTheme.success : LitterTheme.accent)
                        Text(summary)
                            .litterFont(.caption, weight: .semibold)
                            .foregroundColor(LitterTheme.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .litterFont(size: 11, weight: .medium)
                            .foregroundColor(LitterTheme.textMuted)
                            .rotationEffect(.degrees(todoExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if todoExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(data.steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 8) {
                                compactTodoStatusView(for: step.status)
                                    .padding(.top, 2)
                                LitterMarkdownView(
                                    markdown: step.step,
                                    style: .content,
                                    bodySize: 12,
                                    codeSize: 11
                                )
                                    .strikethrough(step.status == .completed, color: LitterTheme.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.sectionReveal)
                }
            }
        }
    }

    @ViewBuilder
    private func compactTodoStatusView(for status: HydratedPlanStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .litterFont(size: 10, weight: .semibold)
                .foregroundColor(LitterTheme.textMuted)
        case .inProgress:
            ProgressView()
                .controlSize(.mini)
                .tint(LitterTheme.warning)
                .frame(width: 10, height: 10)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .litterFont(size: 10, weight: .semibold)
                .foregroundColor(LitterTheme.success)
        }
    }

    private func diffIndicatorButton(for presented: PresentedDiff) -> some View {
        Button {
            selectedDiff = presented
        } label: {
            DiffIndicatorLabel(
                additions: presented.stats.additions,
                deletions: presented.stats.deletions
            )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

}


private struct PresentedDiff: Identifiable {
    let id: String
    let title: String
    let diff: String?
    let stats: DiffStats
    let sections: [PresentedDiffSection]
}

private struct PresentedDiffSection: Identifiable {
    let id: String
    let title: String
    let diff: String

    init(title: String, diff: String) {
        self.title = title
        self.diff = diff
        self.id = "\(title)|\(diff.hashValue)"
    }
}

struct DiffStats: Equatable {
    let additions: Int
    let deletions: Int

    var hasChanges: Bool {
        additions > 0 || deletions > 0
    }

    init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }

    /// Cheap stats-only parse — no per-line allocation.
    init(diff: String) {
        var adds = 0
        var dels = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { adds += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { dels += 1 }
        }
        self.additions = adds
        self.deletions = dels
    }
}

private struct DiffIndicatorLabel: View {
    private let stats: DiffStats

    init(diff: String) {
        self.stats = DiffStats(diff: diff)
    }

    init(additions: Int, deletions: Int) {
        self.stats = DiffStats(additions: additions, deletions: deletions)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.accent)

            if stats.hasChanges {
                HStack(spacing: 6) {
                    Text("+\(stats.additions)")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.success)
                    Text("-\(stats.deletions)")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.danger)
                }
            } else {
                Text("Diff")
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(LitterTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LitterTheme.surface.opacity(0.72), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if stats.hasChanges {
            return "Show diff details. \(stats.additions) additions, \(stats.deletions) deletions."
        }
        return "Show diff details."
    }
}

private struct DiffLine: Identifiable {
    enum Kind {
        case addition, deletion, hunk, context

        var foregroundColor: Color {
            switch self {
            case .addition: LitterTheme.success
            case .deletion: LitterTheme.danger
            case .hunk: LitterTheme.accentStrong
            case .context: LitterTheme.textBody
            }
        }

        var backgroundColor: Color {
            switch self {
            case .addition: LitterTheme.success.opacity(0.12)
            case .deletion: LitterTheme.danger.opacity(0.12)
            case .hunk: LitterTheme.accentStrong.opacity(0.12)
            case .context: LitterTheme.codeBackground.opacity(0.72)
            }
        }
    }

    let id: Int
    let text: String
    let kind: Kind
}

private struct ConversationDiffDetailSheet: View {
    let title: String
    let stats: DiffStats
    let sections: [PresentedDiffSectionModel]
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var collapsedSectionIDs: Set<String> = []
    private let fullDiffFontSize = LitterFont.conversationDiffPointSize
    private let maxStickyDiffSections = 8
    private let maxStickyDiffCharacters = 20_000

    init(title: String, diff: String, sections: [PresentedDiffSection]) {
        self.title = title
        let sectionModels = sections.isEmpty
            ? [PresentedDiffSectionModel(PresentedDiffSection(title: "", diff: diff))]
            : sections.map(PresentedDiffSectionModel.init)
        self.stats = DiffStats(
            additions: sectionModels.reduce(0) { $0 + $1.stats.additions },
            deletions: sectionModels.reduce(0) { $0 + $1.stats.deletions }
        )
        self.sections = sectionModels
        _collapsedSectionIDs = State(
            initialValue: Set(
                sectionModels
                    .filter { !$0.title.isEmpty }
                    .map(\.id)
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("+\(stats.additions)")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.success)
                    Text("-\(stats.deletions)")
                        .litterFont(.caption2, weight: .semibold)
                        .foregroundColor(LitterTheme.danger)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView(.vertical) {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 8,
                        pinnedViews: usesStickyHeaders ? [.sectionHeaders] : []
                    ) {
                        ForEach(sections) { section in
                            if section.title.isEmpty {
                                diffSectionBody(section)
                            } else {
                                Section {
                                    diffSectionBody(section)
                                } header: {
                                    diffSectionHeader(section)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .id(themeManager.themeVersion)
    }

    private var usesStickyHeaders: Bool {
        guard sections.count <= maxStickyDiffSections else { return false }
        return sections.reduce(0) { $0 + $1.diff.count } <= maxStickyDiffCharacters
    }

    @ViewBuilder
    private func diffSection(_ section: PresentedDiffSectionModel) -> some View {
        let isExpanded = !collapsedSectionIDs.contains(section.id)

        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    SyntaxHighlightedDiffText(
                        diff: section.diff,
                        titleHint: section.title.isEmpty ? nil : section.title,
                        fontSize: fullDiffFontSize
                    )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .background(LitterTheme.codeBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func diffSectionHeader(_ section: PresentedDiffSectionModel) -> some View {
        let isExpanded = !collapsedSectionIDs.contains(section.id)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSection(section.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(section.title)
                    .litterFont(.caption2, weight: .bold)
                    .foregroundColor(LitterTheme.textSecondary)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("+\(section.stats.additions)")
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(LitterTheme.success)
                Text("-\(section.stats.deletions)")
                    .litterFont(.caption2, weight: .semibold)
                    .foregroundColor(LitterTheme.danger)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .litterFont(size: 10, weight: .medium)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(LitterTheme.backgroundGradient)
        }
        .buttonStyle(.plain)
    }

    private func diffSectionBody(_ section: PresentedDiffSectionModel) -> some View {
        diffSection(section)
    }

    private func toggleSection(_ id: String) {
        if collapsedSectionIDs.contains(id) {
            collapsedSectionIDs.remove(id)
        } else {
            collapsedSectionIDs.insert(id)
        }
    }
}

private struct PresentedDiffSectionModel: Identifiable {
    let id: String
    let title: String
    let diff: String
    let stats: DiffStats

    init(_ section: PresentedDiffSection) {
        self.id = section.id
        self.title = section.title
        self.diff = section.diff
        self.stats = DiffStats(diff: section.diff)
    }
}

private func presentedDiffSections(from diff: String) -> [PresentedDiffSection] {
    let normalized = diff.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }

    let lines = normalized.components(separatedBy: .newlines)
    let splitIndices = lines.enumerated().compactMap { index, line -> Int? in
        line.hasPrefix("diff --git ") ? index : nil
    }

    if !splitIndices.isEmpty {
        return splitIndices.enumerated().compactMap { offset, start in
            let end = offset + 1 < splitIndices.count ? splitIndices[offset + 1] : lines.count
            let chunk = Array(lines[start..<end]).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { return nil }
            return PresentedDiffSection(title: diffSectionTitle(from: chunk), diff: chunk)
        }
    }

    return [PresentedDiffSection(title: diffSectionTitle(from: normalized), diff: normalized)]
}

private func mergePresentedDiffSections(_ sections: [PresentedDiffSection]) -> [PresentedDiffSection] {
    var orderedTitles: [String] = []
    var mergedByTitle: [String: String] = [:]
    var passthrough: [PresentedDiffSection] = []

    for section in sections {
        let normalizedTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            passthrough.append(section)
            continue
        }

        if let existing = mergedByTitle[normalizedTitle] {
            mergedByTitle[normalizedTitle] = existing + "\n\n" + section.diff
        } else {
            orderedTitles.append(normalizedTitle)
            mergedByTitle[normalizedTitle] = section.diff
        }
    }

    let merged = orderedTitles.compactMap { title -> PresentedDiffSection? in
        guard let diff = mergedByTitle[title] else { return nil }
        return PresentedDiffSection(title: title, diff: diff)
    }

    return merged + passthrough
}

private func diffSectionTitle(from diff: String) -> String {
    for line in diff.components(separatedBy: .newlines) {
        if line.hasPrefix("diff --git ") {
            let parts = line.split(separator: " ")
            if let candidate = parts.last {
                return stripDiffPathPrefix(String(candidate))
            }
        }
        if line.hasPrefix("+++ ") {
            let candidate = String(line.dropFirst(4))
            if candidate != "/dev/null" {
                return stripDiffPathPrefix(candidate)
            }
        }
        if line.hasPrefix("--- ") {
            let candidate = String(line.dropFirst(4))
            if candidate != "/dev/null" {
                return stripDiffPathPrefix(candidate)
            }
        }
    }
    return ""
}

private func stripDiffPathPrefix(_ path: String) -> String {
    if path.hasPrefix("a/") || path.hasPrefix("b/") {
        return String(path.dropFirst(2))
    }
    return path
}

private func formatDuration(_ durationMs: Int?) -> String? {
    guard let durationMs, durationMs >= 0 else { return nil }
    if durationMs >= 1_000 {
        return String(format: "%.1fs", Double(durationMs) / 1_000.0)
    }
    return "\(durationMs)ms"
}

private extension ToolCallStatus {
    var themeColor: Color {
        switch self {
        case .completed:
            return LitterTheme.success
        case .inProgress:
            return LitterTheme.warning
        case .failed:
            return LitterTheme.danger
        case .unknown:
            return LitterTheme.textSecondary
        }
    }
}

private extension ConversationItem {
    var liveDetailStatus: ToolCallStatus? {
        switch content {
        case .commandExecution(let data):
            return data.status.toolCallStatus
        case .fileChange(let data):
            return data.status.toolCallStatus
        case .mcpToolCall(let data):
            return data.status.toolCallStatus
        case .dynamicToolCall(let data):
            return data.status.toolCallStatus
        case .webSearch(let data):
            return data.isInProgress ? .inProgress : .completed
        case .imageView:
            return .completed
        case .imageGeneration(let data):
            return data.status.toolCallStatus
        default:
            return nil
        }
    }
}
