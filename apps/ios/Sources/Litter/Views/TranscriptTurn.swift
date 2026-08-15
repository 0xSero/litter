import Foundation

enum ConversationTurnCollapsePolicy {
    /// Rendering every message/tool view in a large restored page can exhaust
    /// SwiftUI's layout budget and leave the conversation surface blank.
    static let automaticItemThreshold = 200

    static func shouldCollapse(
        preferenceEnabled: Bool,
        itemCount: Int
    ) -> Bool {
        preferenceEnabled || itemCount >= automaticItemThreshold
    }

    static func expandedRecentTurnCount(
        preferenceEnabled: Bool,
        itemCount: Int
    ) -> Int {
        shouldCollapse(preferenceEnabled: preferenceEnabled, itemCount: itemCount) ? 1 : .max
    }
}

enum ConversationInfiniteScrollPolicy {
    static let olderPrefetchDistance = 6

    static func earliestVisibleIndex(
        visibleIDs: [String],
        orderedIDs: [String]
    ) -> Int? {
        guard !visibleIDs.isEmpty else { return nil }
        let indicesByID = Dictionary(
            uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) }
        )
        return visibleIDs.compactMap { indicesByID[$0] }.min()
    }
}

struct TranscriptTurn: Identifiable, Equatable {
    private static let collapsedExcerptLimit = 180

    struct Preview: Equatable {
        let primaryText: String
        let secondaryText: String?
        let durationText: String?
        let imageCount: Int
        let toolCallCount: Int
        let eventCount: Int
        let widgetCount: Int
    }

    let id: String
    let items: [ConversationItem]
    let preview: Preview
    let isLive: Bool
    let isCollapsedByDefault: Bool
    let renderDigest: Int

    static func build(
        from items: [ConversationItem],
        threadStatus: ConversationStatus,
        expandedRecentTurnCount: Int = 3
    ) -> [TranscriptTurn] {
        let isStreaming: Bool
        if case .thinking = threadStatus {
            isStreaming = true
        } else {
            isStreaming = false
        }
        let groupedItems = mergeTrailingStreamingGroups(in: group(items), isStreaming: isStreaming)
        guard !groupedItems.isEmpty else { return [] }

        let lastIndex = groupedItems.index(before: groupedItems.endIndex)

        let collapseBoundary = max(0, groupedItems.count - expandedRecentTurnCount)

        return groupedItems.enumerated().map { index, turnItems in
            let isLive = isStreaming && index == lastIndex
            return TranscriptTurn(
                id: turnIdentifier(for: turnItems, ordinal: index),
                items: turnItems,
                preview: makePreview(from: turnItems),
                isLive: isLive,
                isCollapsedByDefault: index < collapseBoundary,
                renderDigest: makeRenderDigest(from: turnItems, isLive: isLive)
            )
        }
    }

    func withCollapsedByDefault(_ isCollapsedByDefault: Bool) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            items: items,
            preview: preview,
            isLive: isLive,
            isCollapsedByDefault: isCollapsedByDefault,
            renderDigest: renderDigest
        )
    }

    func replacingItems(_ items: [ConversationItem]) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            items: items,
            preview: Self.makePreview(from: items),
            isLive: isLive,
            isCollapsedByDefault: isCollapsedByDefault,
            renderDigest: Self.makeRenderDigest(from: items, isLive: isLive)
        )
    }

    func replacingRenderableItems(_ items: [ConversationItem]) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            items: items,
            preview: preview,
            isLive: isLive,
            isCollapsedByDefault: isCollapsedByDefault,
            renderDigest: Self.makeRenderDigest(from: items, isLive: isLive)
        )
    }

    static func mergeConsecutiveExplorationTurnsForRendering(
        _ turns: [TranscriptTurn]
    ) -> [TranscriptTurn] {
        var merged: [TranscriptTurn] = []
        var explorationBuffer: [TranscriptTurn] = []

        func flushExplorationBuffer() {
            guard !explorationBuffer.isEmpty else { return }
            if explorationBuffer.count == 1, let single = explorationBuffer.first {
                merged.append(single)
            } else if let mergedTurn = mergedExplorationTurn(from: explorationBuffer) {
                merged.append(mergedTurn)
            }
            explorationBuffer.removeAll(keepingCapacity: true)
        }

        for turn in turns {
            guard let renderableTurn = renderableTurn(from: turn) else { continue }
            if renderableTurn.items.allSatisfy(\.isExplorationCommandItem) {
                explorationBuffer.append(renderableTurn)
            } else {
                flushExplorationBuffer()
                merged.append(renderableTurn)
            }
        }

        flushExplorationBuffer()
        return merged
    }

    private static func group(_ items: [ConversationItem]) -> [[ConversationItem]] {
        var groups: [[ConversationItem]] = []
        var current: [ConversationItem] = []
        var currentSourceTurnId: String?

        for item in items {
            let startsNewTurn =
                !current.isEmpty &&
                (
                    item.isFromUserTurnBoundary ||
                    (
                        item.sourceTurnId != nil &&
                        currentSourceTurnId != nil &&
                        item.sourceTurnId != currentSourceTurnId
                    )
                )

            if startsNewTurn {
                groups.append(current)
                current = [item]
            } else {
                current.append(item)
            }

            // Adopt the first non-nil sourceTurnId in the group so that
            // assistant items following a user-boundary item (which has
            // sourceTurnId == nil) stay in the same turn.
            if currentSourceTurnId == nil {
                currentSourceTurnId = item.sourceTurnId
            } else if current.count == 1 {
                currentSourceTurnId = current.first?.sourceTurnId
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups
    }

    private static func mergeTrailingStreamingGroups(
        in groups: [[ConversationItem]],
        isStreaming: Bool
    ) -> [[ConversationItem]] {
        guard isStreaming, groups.count > 1 else { return groups }
        guard let liveTurnStartIndex = groups.lastIndex(where: containsLiveTurnBoundary) else {
            return groups
        }
        guard liveTurnStartIndex < groups.index(before: groups.endIndex) else {
            return groups
        }

        let mergedLiveTurn = groups[liveTurnStartIndex...].flatMap { $0 }
        return Array(groups[..<liveTurnStartIndex]) + [mergedLiveTurn]
    }

    private static func containsLiveTurnBoundary(_ items: [ConversationItem]) -> Bool {
        items.contains { item in
            item.isFromUserTurnBoundary || item.isUserItem
        }
    }

    private static func renderableTurn(from turn: TranscriptTurn) -> TranscriptTurn? {
        let visibleItems = turn.items.filter { !$0.isVisuallyEmptyNeutralItem }
        guard !visibleItems.isEmpty else { return nil }
        guard visibleItems.count != turn.items.count else { return turn }
        return turn.replacingRenderableItems(visibleItems)
    }

    private static func mergedExplorationTurn(from turns: [TranscriptTurn]) -> TranscriptTurn? {
        guard let last = turns.last else { return nil }
        let items = turns.flatMap(\.items)
        let isLive = turns.contains(where: \.isLive)
        return TranscriptTurn(
            // Anchor the merged row to its newest constituent turn. Older
            // pages prepend to this run, so its identity remains stable and
            // SwiftUI can preserve the visible scroll position.
            id: "exploration-turn-\(last.id)",
            items: items,
            preview: makePreview(from: items),
            isLive: isLive,
            isCollapsedByDefault: turns.allSatisfy(\.isCollapsedByDefault),
            renderDigest: makeRenderDigest(from: items, isLive: isLive)
        )
    }

    private static func turnIdentifier(for items: [ConversationItem], ordinal: Int) -> String {
        if let first = items.first {
            if let sourceTurnId = items.first(where: { $0.sourceTurnId != nil })?.sourceTurnId {
                return "turn-\(sourceTurnId)-\(first.id)"
            }
            return "turn-\(first.id)"
        }
        return "turn-\(ordinal)"
    }

    private static func makeRenderDigest(from items: [ConversationItem], isLive: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(isLive)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.renderDigest)
        }
        return hasher.finalize()
    }

    private static func makePreview(from items: [ConversationItem]) -> Preview {
        let previewItems = items.filter { !$0.isVisuallyEmptyNeutralItem }
        let sourceItems = previewItems.isEmpty ? items : previewItems
        let previewMetrics = collectPreviewMetrics(from: sourceItems)
        let primaryItem = previewMetrics.userItem ?? previewMetrics.finalAnswerItem ?? sourceItems.first
        let preferredAssistantItem = previewMetrics.finalAnswerItem ?? previewMetrics.assistantItem
        let secondaryItem = secondaryPreviewItem(
            in: sourceItems,
            primaryItem: primaryItem,
            preferredAssistantItem: preferredAssistantItem
        )

        return Preview(
            primaryText: previewText(for: primaryItem),
            secondaryText: secondaryItem.map(previewText(for:)),
            durationText: formattedDuration(from: previewMetrics),
            imageCount: previewMetrics.imageCount,
            toolCallCount: previewMetrics.toolCallCount,
            eventCount: previewMetrics.eventCount,
            widgetCount: previewMetrics.widgetCount
        )
    }

    private struct PreviewMetrics {
        var userItem: ConversationItem?
        var finalAnswerItem: ConversationItem?
        var assistantItem: ConversationItem?
        var imageCount = 0
        var toolCallCount = 0
        var eventCount = 0
        var widgetCount = 0
        var boundaryUserTimestamp: Date?
        var userTimestamp: Date?
        var assistantTimestamp: Date?
        var explicitDurationMillis = 0
        var hasExplicitDuration = false
    }

    private static func collectPreviewMetrics(from items: [ConversationItem]) -> PreviewMetrics {
        var metrics = PreviewMetrics()

        for item in items {
            if metrics.userItem == nil, item.isUserItem {
                metrics.userItem = item
            }
            if metrics.finalAnswerItem == nil, item.isFinalAnswerAssistantItem {
                metrics.finalAnswerItem = item
            }
            if metrics.assistantItem == nil, item.isAssistantItem {
                metrics.assistantItem = item
            }
            if metrics.boundaryUserTimestamp == nil, item.isUserItem && item.isFromUserTurnBoundary {
                metrics.boundaryUserTimestamp = item.timestamp
            }
            if metrics.userTimestamp == nil, item.isUserItem {
                metrics.userTimestamp = item.timestamp
            }
            if item.isAssistantItem || {
                if case .codeReview = item.content { return true }
                return false
            }() {
                metrics.assistantTimestamp = item.timestamp
            }

            metrics.imageCount += item.userImages.count
            if item.widgetState != nil {
                metrics.widgetCount += 1
            }

            switch item.content {
            case .commandExecution(let data):
                metrics.toolCallCount += 1
                if let durationMs = data.durationMs {
                    metrics.explicitDurationMillis += durationMs
                    metrics.hasExplicitDuration = true
                }
            case .fileChange, .turnDiff, .multiAgentAction, .webSearch, .imageView, .imageGeneration:
                metrics.toolCallCount += 1
            case .mcpToolCall(let data):
                metrics.toolCallCount += 1
                if let durationMs = data.durationMs {
                    metrics.explicitDurationMillis += durationMs
                    metrics.hasExplicitDuration = true
                }
            case .dynamicToolCall(let data):
                metrics.toolCallCount += 1
                if let durationMs = data.durationMs {
                    metrics.explicitDurationMillis += durationMs
                    metrics.hasExplicitDuration = true
                }
            case .codeReview:
                metrics.eventCount += 1
            case .divider, .error, .note, .userInputResponse:
                metrics.eventCount += 1
            default:
                break
            }
        }

        return metrics
    }

    private static func secondaryPreviewItem(
        in items: [ConversationItem],
        primaryItem: ConversationItem?,
        preferredAssistantItem: ConversationItem?
    ) -> ConversationItem? {
        if let primaryItem, let preferredAssistantItem, preferredAssistantItem.id != primaryItem.id {
            return preferredAssistantItem
        }

        return items.first { item in
            guard let primaryItem else { return true }
            return item.id != primaryItem.id && (item.isAssistantItem || isPreviewSecondary(item))
        }
    }

    private static func isPreviewSecondary(_ item: ConversationItem) -> Bool {
        switch item.content {
        case .codeReview, .note, .divider, .error, .reasoning:
            return true
        default:
            return false
        }
    }

    private static func previewText(for item: ConversationItem?) -> String {
        guard let item else { return "Conversation turn" }

        switch item.content {
        case .user(let data):
            let trimmed = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return collapsedExcerpt(from: trimmed) }
            if !data.images.isEmpty {
                return data.images.count == 1 ? "Shared 1 image" : "Shared \(data.images.count) images"
            }
            return "Conversation turn"
        case .assistant(let data):
            let trimmed = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Assistant response" : collapsedExcerpt(from: trimmed)
        case .codeReview(let data):
            if let first = data.findings.first {
                return "Review: \(collapsedExcerpt(from: first.title))"
            }
            return "Code review"
        case .reasoning(let data):
            let body = (data.summary + data.content)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "Reasoning" : "Reasoning: \(collapsedExcerpt(from: body))"
        case .todoList(let data):
            if data.steps.isEmpty {
                return "To do list"
            }
            let completed = data.completedCount
            let total = data.steps.count
            if completed == 0 {
                return "To do list: \(total) tasks"
            }
            return "To do list: \(completed) of \(total) done"
        case .proposedPlan(let data):
            let trimmed = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Plan" : "Plan: \(collapsedExcerpt(from: trimmed))"
        case .commandExecution(let data):
            if let action = data.actions.first {
                switch action.kind {
                case .read:
                    return action.path.map { "Read \(workspaceTitle(for: $0))" } ?? "Read file"
                case .search:
                    if let query = action.query, let path = action.path {
                        return "Searched for \(query) in \(workspaceTitle(for: path))"
                    }
                    if let query = action.query {
                        return "Searched for \(query)"
                    }
                    return "Searched files"
                case .listFiles:
                    return action.path.map { "Listed files in \(workspaceTitle(for: $0))" } ?? "Listed files"
                case .unknown:
                    break
                }
            }
            return data.command.isEmpty ? "Ran command" : collapsedExcerpt(from: "Ran \(data.command)")
        case .fileChange(let data):
            if let first = data.changes.first {
                return "Changed \(workspaceTitle(for: first.path))"
            }
            return "File changes"
        case .turnDiff:
            return "Turn diff"
        case .mcpToolCall(let data):
            return data.server.isEmpty ? "Called \(data.tool)" : "Called \(data.tool) from \(data.server)"
        case .dynamicToolCall(let data):
            return "Called \(data.tool)"
        case .multiAgentAction(let data):
            let count = max(data.targets.count, data.agentStates.count)
            return count == 1 ? "\(data.tool) 1 agent" : "\(data.tool) \(count) agents"
        case .webSearch(let data):
            return data.query.isEmpty ? "Searched web" : "Searched web for \(data.query)"
        case .imageView(let data):
            return "Viewed image: \(workspaceTitle(for: data.path))"
        case .imageGeneration(let data):
            switch data.status {
            case .completed: return "Generated image"
            case .failed: return "Image generation failed"
            default: return "Generating image"
            }
        case .widget(let data):
            return "Widget: \(data.widgetState.title)"
        case .userInputResponse(let data):
            let count = data.questions.count
            return count == 1 ? "Asked 1 question" : "Asked \(count) questions"
        case .divider(let divider):
            switch divider {
            case .contextCompaction(let isComplete):
                return isComplete ? "Context compacted" : "Compacting context"
            case .modelRerouted(_, let toModel, _):
                return "Routed to \(toModel)"
            case .reviewEntered(let review):
                return "Entered review: \(review)"
            case .reviewExited(let review):
                return "Exited review: \(review)"
            case .workedFor(let duration):
                return duration
            case .generic(let title, let detail):
                return detail.map { "\(title): \(collapsedExcerpt(from: $0))" } ?? title
            }
        case .error(let data):
            return data.title.isEmpty ? collapsedExcerpt(from: data.message) : "\(data.title): \(collapsedExcerpt(from: data.message))"
        case .note(let data):
            return data.body.isEmpty ? data.title : "\(data.title): \(collapsedExcerpt(from: data.body))"
        }
    }

    private static func formattedDuration(from metrics: PreviewMetrics) -> String? {
        let userTimestamp = metrics.boundaryUserTimestamp ?? metrics.userTimestamp

        if let userTimestamp,
           let assistantTimestamp = metrics.assistantTimestamp {
            let interval = max(0, assistantTimestamp.timeIntervalSince(userTimestamp))
            if interval >= 0.05 {
                return formatDuration(seconds: interval)
            }
        }

        if metrics.hasExplicitDuration {
            return formatDuration(milliseconds: metrics.explicitDurationMillis)
        }

        return nil
    }

    private static func formatDuration(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds)ms"
        }
        return formatDuration(seconds: Double(milliseconds) / 1000)
    }

    private static func formatDuration(seconds interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded()))ms"
        }

        if interval < 10 {
            let totalTenths = Int((interval * 10).rounded())
            if totalTenths.isMultiple(of: 10) {
                return "\(totalTenths / 10)s"
            }
            return "\(totalTenths / 10).\(totalTenths % 10)s"
        }

        if interval < 60 {
            return "\(Int(interval.rounded()))s"
        }

        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalSeconds < 3600 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }

        let hours = totalSeconds / 3600
        let remainingMinutes = (totalSeconds % 3600) / 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static func collapsedExcerpt(from text: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(min(text.count, collapsedExcerptLimit))
        var hitLimit = false

        text.enumerateLines { line, stop in
            let trimmed = trimWhitespace(in: line[...])
            guard !trimmed.isEmpty, trimmed != "```" else { return }

            if !normalized.isEmpty {
                appendExcerptChunk(" ", to: &normalized, hitLimit: &hitLimit)
                if hitLimit {
                    stop = true
                    return
                }
            }

            appendExcerptChunk(String(trimmed), to: &normalized, hitLimit: &hitLimit)
            if hitLimit {
                stop = true
            }
        }

        if normalized.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= collapsedExcerptLimit {
                return trimmed
            }
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: collapsedExcerptLimit)
            return String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return hitLimit ? normalized.trimmingCharacters(in: .whitespacesAndNewlines) + "..." : normalized
    }

    private static func trimWhitespace(in substring: Substring) -> Substring {
        var start = substring.startIndex
        var end = substring.endIndex

        while start < end, substring[start].isWhitespace {
            start = substring.index(after: start)
        }
        while start < end {
            let previous = substring.index(before: end)
            guard substring[previous].isWhitespace else { break }
            end = previous
        }

        return substring[start..<end]
    }

    private static func appendExcerptChunk(
        _ chunk: String,
        to result: inout String,
        hitLimit: inout Bool
    ) {
        let remaining = collapsedExcerptLimit - result.count
        guard remaining > 0 else {
            hitLimit = true
            return
        }

        if chunk.count <= remaining {
            result.append(contentsOf: chunk)
            return
        }

        let endIndex = chunk.index(chunk.startIndex, offsetBy: remaining)
        result.append(contentsOf: chunk[..<endIndex])
        hitLimit = true
    }
}

private extension ConversationItem {
    var isFinalAnswerAssistantItem: Bool {
        switch content {
        case .assistant(let data):
            return data.phase == .finalAnswer
        case .codeReview:
            return true
        default:
            return false
        }
    }
}
