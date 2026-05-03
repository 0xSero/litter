import Foundation

/// Pure functions that project iOS `AppSnapshotRecord` slices into the
/// `Watch*` wire-format types consumed by the watchOS target.
enum WatchProjection {
    /// Build the full task list the watch's home shows. Order matches the
    /// iPhone sessions screen — running/needs-approval first, then most
    /// recently updated.
    static func tasks(
        summaries: [AppSessionSummary],
        threads: [AppThreadSnapshot],
        pendingApprovals: [PendingApproval]
    ) -> [WatchTask] {
        let approvalsByThread = Dictionary(
            grouping: pendingApprovals.filter { $0.kind != .mcpElicitation },
            by: { $0.threadId ?? "" }
        )
        let threadsByKey = Dictionary(uniqueKeysWithValues: threads.map { ($0.key, $0) })

        let mapped = summaries.map { summary -> WatchTask in
            let threadApprovals = approvalsByThread[summary.key.threadId] ?? []
            let thread = threadsByKey[summary.key]

            let status: WatchTask.Status
            if !threadApprovals.isEmpty {
                status = .needsApproval
            } else if summary.hasActiveTurn {
                status = .running
            } else {
                status = .idle
            }

            let subtitle: String?
            if status == .needsApproval, let first = threadApprovals.first {
                subtitle = "awaiting approval: \(approvalLabel(first))"
            } else if let lastTool = summary.lastToolLabel, !lastTool.isEmpty {
                subtitle = compact(lastTool, max: 48)
            } else if let lastResp = summary.lastResponsePreview, !lastResp.isEmpty {
                subtitle = compact(lastResp, max: 60)
            } else if let lastUser = summary.lastUserMessage, !lastUser.isEmpty {
                subtitle = compact(lastUser, max: 60)
            } else if !summary.preview.isEmpty {
                subtitle = compact(summary.preview, max: 60)
            } else {
                subtitle = nil
            }

            return WatchTask(
                id: "\(summary.key.serverId):\(summary.key.threadId)",
                threadId: summary.key.threadId,
                serverId: summary.key.serverId,
                serverName: summary.serverDisplayName,
                title: title(for: summary),
                subtitle: subtitle,
                status: status,
                relativeTime: relativeTime(from: summary.updatedAt),
                steps: thread.map { deriveSteps(from: $0.hydratedConversationItems) } ?? [],
                transcript: thread.map { transcript(for: $0) } ?? [],
                pendingApprovalId: threadApprovals.first?.id
            )
        }

        return mapped.sorted { lhs, rhs in
            // Running / needsApproval surfaces to top; tie-break by updated time.
            let lr = rank(lhs.status)
            let rr = rank(rhs.status)
            if lr != rr { return lr < rr }
            return (indexOfUpdatedAt(lhs, in: summaries) ?? Int.max)
                 < (indexOfUpdatedAt(rhs, in: summaries) ?? Int.max)
        }
    }

    static func approval(_ approval: PendingApproval) -> WatchApproval {
        let kind: WatchApproval.Kind
        switch approval.kind {
        case .command:        kind = .command
        case .fileChange:     kind = .fileChange
        case .permissions:    kind = .permissions
        case .mcpElicitation: kind = .mcpElicitation
        }

        let (command, target, diff) = describe(approval)

        return WatchApproval(
            id: approval.id,
            command: command,
            target: target,
            diffSummary: diff,
            kind: kind
        )
    }

    /// Project the live realtime voice session into the watch wire format.
    /// Returns `nil` when there is no active voice session (no
    /// `activeThread` and no `phase`) so the watch can hide the voice screen.
    static func voice(
        from snapshot: AppSnapshotRecord?,
        audioLevel: Double = 0,
        isMuted: Bool = false
    ) -> WatchVoiceState? {
        guard let voice = snapshot?.voiceSession else { return nil }
        // No phase and no active thread means the slot is empty.
        if voice.phase == nil && voice.activeThread == nil && voice.transcriptEntries.isEmpty {
            return nil
        }

        let mode: WatchVoiceState.Mode
        switch voice.phase {
        case .listening:                 mode = .listening
        case .speaking:                  mode = .speaking
        case .thinking, .handoff:        mode = .thinking
        case .error:                     mode = .error
        case .connecting, .none:         mode = .idle
        }

        let recent = voice.transcriptEntries.suffix(4).map { entry in
            let role: WatchTranscriptTurn.Role
            switch entry.speaker {
            case .user:      role = .user
            case .assistant: role = .assistant
            }
            return WatchTranscriptTurn(role: role, text: compact(entry.text), faded: false)
        }

        return WatchVoiceState(
            mode: mode,
            serverId: voice.activeThread?.serverId,
            threadId: voice.activeThread?.threadId,
            recentTurns: Array(recent),
            audioLevel: max(0, min(1, audioLevel)),
            isMuted: isMuted
        )
    }

    static func transcript(for thread: AppThreadSnapshot) -> [WatchTranscriptTurn] {
        let items = thread.hydratedConversationItems
        var turns: [WatchTranscriptTurn] = []
        turns.reserveCapacity(6)

        for item in items.suffix(20) {
            switch item.content {
            case .user(let data) where !data.text.isEmpty:
                turns.append(WatchTranscriptTurn(role: .user, text: compact(data.text), faded: false))
            case .assistant(let data) where !data.text.isEmpty:
                turns.append(WatchTranscriptTurn(role: .assistant, text: compact(data.text), faded: false))
            case .commandExecution(let data):
                let trimmed = data.command.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = trimmed.isEmpty ? "ran command" : "$ " + compact(trimmed, max: 42)
                turns.append(WatchTranscriptTurn(role: .system, text: summary, faded: false))
            default:
                continue
            }
        }

        return Array(turns.suffix(4))
    }

    // MARK: - Helpers

    private static func title(for summary: AppSessionSummary) -> String {
        if !summary.title.isEmpty {
            return compact(summary.title, max: 50)
        }
        if let preview = summary.lastUserMessage, !preview.isEmpty {
            return compact(preview, max: 50)
        }
        if !summary.preview.isEmpty {
            return compact(summary.preview, max: 50)
        }
        return "untitled task"
    }

    private static func rank(_ status: WatchTask.Status) -> Int {
        switch status {
        case .needsApproval: return 0
        case .running:       return 1
        case .error:         return 2
        case .idle:          return 3
        }
    }

    private static func indexOfUpdatedAt(_ task: WatchTask, in summaries: [AppSessionSummary]) -> Int? {
        guard let s = summaries.first(where: { $0.key.threadId == task.threadId && $0.key.serverId == task.serverId })
        else { return nil }
        guard let updated = s.updatedAt else { return Int.max }
        // Invert so larger (more recent) sorts first.
        return -Int(updated)
    }

    private static func relativeTime(from updatedAt: Int64?) -> String {
        guard let updatedAt else { return "" }
        let updatedDate = Date(timeIntervalSince1970: TimeInterval(updatedAt))
        let delta = Date().timeIntervalSince(updatedDate)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta) / 60)m" }
        if delta < 86400 { return "\(Int(delta) / 3600)h" }
        if delta < 7 * 86400 { return "\(Int(delta) / 86400)d" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: updatedDate)
    }

    private static func deriveSteps(from items: [HydratedConversationItem]) -> [WatchTaskStep] {
        var steps: [WatchTaskStep] = []
        for item in items.suffix(12) {
            guard let step = stepFromItem(item) else { continue }
            steps.append(step)
        }
        return Array(steps.suffix(5))
    }

    private static func stepFromItem(_ item: HydratedConversationItem) -> WatchTaskStep? {
        switch item.content {
        case .commandExecution(let data):
            return WatchTaskStep(
                tool: "bash",
                arg: compact(data.command, max: 32),
                state: mapStatus(data.status)
            )

        case .fileChange(let data):
            let primary = data.changes.first?.path ?? "patch"
            let kind = data.changes.first?.kind ?? "edit"
            return WatchTaskStep(
                tool: mapFileChangeKind(kind),
                arg: compact(primary, max: 32),
                state: mapStatus(data.status)
            )

        case .webSearch(let data):
            return WatchTaskStep(
                tool: "web_search",
                arg: compact(data.query, max: 32),
                state: data.isInProgress ? .active : .done
            )

        case .mcpToolCall(let data):
            return WatchTaskStep(
                tool: data.tool,
                arg: compact(data.contentSummary ?? "", max: 28),
                state: mapStatus(data.status)
            )

        case .dynamicToolCall(let data):
            return WatchTaskStep(
                tool: data.tool,
                arg: compact(data.contentSummary ?? "", max: 28),
                state: mapStatus(data.status)
            )

        default:
            return nil
        }
    }

    private static func mapStatus(_ status: AppOperationStatus) -> WatchTaskStep.State {
        switch status {
        case .completed, .failed, .declined: return .done
        case .inProgress: return .active
        case .pending, .unknown: return .pending
        }
    }

    private static func mapFileChangeKind(_ kind: String) -> String {
        let lower = kind.lowercased()
        if lower.contains("add") || lower.contains("create") { return "create_file" }
        if lower.contains("delete") || lower.contains("remove") { return "delete_file" }
        return "edit_file"
    }

    private static func approvalLabel(_ approval: PendingApproval) -> String {
        switch approval.kind {
        case .command:        return compact(approval.command ?? "command", max: 32)
        case .fileChange:     return compact(approval.path ?? "file change", max: 32)
        case .permissions:    return "permissions"
        case .mcpElicitation: return "mcp input"
        }
    }

    private static func describe(_ approval: PendingApproval) -> (command: String, target: String, diff: String) {
        switch approval.kind {
        case .command:
            let cmd = approval.command ?? "command"
            return (
                command: compact(cmd, max: 60),
                target: approval.cwd ?? "",
                diff: approval.reason.map { compact($0, max: 60) } ?? ""
            )

        case .fileChange:
            let path = approval.path ?? "file"
            return (
                command: "edit_file",
                target: compact(path, max: 60),
                diff: approval.grantRoot.map { compact($0, max: 48) } ?? ""
            )

        case .permissions:
            return (
                command: "permissions",
                target: approval.reason ?? "grant access",
                diff: ""
            )

        case .mcpElicitation:
            return (
                command: "mcp",
                target: approval.reason ?? "input requested",
                diff: ""
            )
        }
    }

    private static func compact(_ s: String, max: Int = 60) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max - 1)) + "…"
    }
}
