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

            // Prefer the assistant's last reply over the current tool label —
            // on a small screen the user wants to see what the AI *said*
            // more than which tool is executing. Tool name is still
            // exposed separately as `lastTool` so the UI can render it as
            // a small secondary chip.
            let subtitle: String?
            if status == .needsApproval, let first = threadApprovals.first {
                subtitle = "awaiting approval: \(approvalLabel(first))"
            } else if let lastResp = summary.lastResponsePreview, !lastResp.isEmpty {
                subtitle = compact(lastResp, max: 100)
            } else if let lastTool = summary.lastToolLabel, !lastTool.isEmpty {
                subtitle = compact(lastTool, max: 48)
            } else if let lastUser = summary.lastUserMessage, !lastUser.isEmpty {
                subtitle = compact(lastUser, max: 60)
            } else if !summary.preview.isEmpty {
                subtitle = compact(summary.preview, max: 60)
            } else {
                subtitle = nil
            }

            // Separate field for the active tool. Only set when an assistant
            // reply is the subtitle (otherwise the tool *is* the subtitle and
            // duplicating it would be noisy).
            let lastTool: String? = {
                guard let tool = summary.lastToolLabel, !tool.isEmpty else { return nil }
                guard summary.lastResponsePreview?.isEmpty == false else { return nil }
                return compact(tool, max: 36)
            }()

            let stats = summary.stats
            let pct: Int? = {
                guard let tu = summary.tokenUsage,
                      let window = tu.contextWindow,
                      window > 0
                else { return nil }
                return Int(min(100, max(0, (Double(tu.totalTokens) / Double(window)) * 100)))
            }()

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
                pendingApprovalId: threadApprovals.first?.id,
                model: summary.model.isEmpty ? nil : summary.model,
                cwd: summary.cwd.isEmpty ? nil : summary.cwd,
                turnCount: stats.map { Int($0.turnCount) },
                toolCallCount: stats.map { Int($0.toolCallCount) },
                diffAdditions: stats.map { Int($0.diffAdditions) },
                diffDeletions: stats.map { Int($0.diffDeletions) },
                contextPercent: pct,
                hasTurnActive: summary.hasActiveTurn,
                lastTool: lastTool,
                diffs: thread
                    .map { deriveDiffs(from: $0.hydratedConversationItems) }
                    .flatMap { $0.isEmpty ? nil : $0 }
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

    /// Re-sort an already-projected task list so that, within each status
    /// group, threads appear in the iPhone home's pin order. Use this on
    /// top of `tasks(...)` when pinned mode is active. Tasks not in
    /// `pinned` sort to the end of their group, ordered by their existing
    /// position (stable).
    static func applyPinOrder(
        _ tasks: [WatchTask],
        pinned: [PinnedThreadKey]
    ) -> [WatchTask] {
        guard !pinned.isEmpty else { return tasks }
        let pinIndex: [PinnedThreadKey: Int] = Dictionary(
            uniqueKeysWithValues: pinned.enumerated().map { ($1, $0) }
        )
        // Pair each task with its (statusRank, pinOrder, originalIndex) so a
        // stable sort preserves intra-group ordering for unpinned trailers.
        let decorated = tasks.enumerated().map { idx, task -> (key: (Int, Int, Int), task: WatchTask) in
            let pin = PinnedThreadKey(serverId: task.serverId, threadId: task.threadId)
            return ((rank(task.status), pinIndex[pin] ?? Int.max, idx), task)
        }
        return decorated
            .sorted { lhs, rhs in
                if lhs.key.0 != rhs.key.0 { return lhs.key.0 < rhs.key.0 }
                if lhs.key.1 != rhs.key.1 { return lhs.key.1 < rhs.key.1 }
                return lhs.key.2 < rhs.key.2
            }
            .map(\.task)
    }

    /// Apply the iPhone home's visibility rules to a summary list so the
    /// watch shows exactly what the phone home shows.
    ///
    /// - Hidden threads are excluded.
    /// - If any threads are pinned, show only those (in pin order). Pinned
    ///   entries not yet in `summaries` are skipped (the iPhone uses a
    ///   "Loading thread" placeholder; the watch just waits for the next push).
    /// - Otherwise show the 10 most-recent summaries.
    ///
    /// Mirrors `HomeDashboardModel.mergedHomeSessions` in
    /// `apps/ios/Sources/Litter/Views/HomeDashboardModel.swift`.
    static func homeFilteredSummaries(
        summaries: [AppSessionSummary],
        pinned: [PinnedThreadKey],
        hidden: [PinnedThreadKey]
    ) -> [AppSessionSummary] {
        let hiddenSet = Set(hidden)
        let candidates = summaries.filter {
            !hiddenSet.contains(PinnedThreadKey(threadKey: $0.key))
        }
        if !pinned.isEmpty {
            let byKey = Dictionary(uniqueKeysWithValues: candidates.map {
                (PinnedThreadKey(threadKey: $0.key), $0)
            })
            return pinned.compactMap { byKey[$0] }
        }
        return Array(
            candidates
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                .prefix(10)
        )
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

    // MARK: - Diff projection

    /// Max number of per-file diffs we ship per task. Bounds the watch
    /// payload so a turn that touches dozens of files doesn't blow the
    /// WatchConnectivity application-context size cap.
    static let maxDiffFilesPerTask = 6
    /// Per-file diff text budget, in characters. Anything longer is
    /// tail-truncated with a "…" sentinel and `truncated = true` so the
    /// watch can render a hint instead of silently lying.
    static let maxDiffCharsPerFile = 1200

    /// Walk the hydrated conversation items and produce one `WatchFileDiff`
    /// per distinct file path — collapsing repeated edits to the most recent
    /// diff. Ordered most-recent-first, capped to `maxDiffFilesPerTask`,
    /// each diff truncated to `maxDiffCharsPerFile`.
    static func deriveDiffs(from items: [HydratedConversationItem]) -> [WatchFileDiff] {
        // Scan newest → oldest so the first time we see a path wins (most
        // recent edit for that file). Skip empty diffs — they carry no
        // information and would just waste a slot.
        var seenPaths = Set<String>()
        var diffs: [WatchFileDiff] = []
        for item in items.reversed() {
            guard case .fileChange(let data) = item.content else { continue }
            for change in data.changes {
                let path = change.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, !seenPaths.contains(path) else { continue }
                let rawDiff = change.diff
                guard !rawDiff.isEmpty else { continue }
                seenPaths.insert(path)
                let (text, truncated) = truncateDiff(rawDiff, max: maxDiffCharsPerFile)
                diffs.append(
                    WatchFileDiff(
                        path: path,
                        kind: change.kind,
                        additions: Int(change.additions),
                        deletions: Int(change.deletions),
                        diff: text,
                        truncated: truncated
                    )
                )
                if diffs.count >= maxDiffFilesPerTask { return diffs }
            }
        }
        return diffs
    }

    private static func truncateDiff(_ s: String, max: Int) -> (String, Bool) {
        if s.count <= max { return (s, false) }
        let head = String(s.prefix(max))
        // Drop the partial trailing line so the truncation marker sits on
        // its own row instead of fusing onto a half-rendered diff line.
        let lastNewline = head.lastIndex(of: "\n")
        let body = lastNewline.map { String(head[..<$0]) } ?? head
        return (body + "\n… (truncated)", true)
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
        case .completed, .failed, .declined, .interrupted: return .done
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

    // MARK: - Theme projection

    /// Build a resolved palette the watch can apply directly. Honors
    /// `ThemeManager.appearanceMode` plus `ThemeStore.colorScheme` (which
    /// already resolves `.system` against the live trait collection).
    @MainActor
    static func theme(from manager: ThemeManager) -> WatchThemePayload {
        let mode: WatchThemePayload.AppearanceMode = {
            switch manager.appearanceMode {
            case .system: return .system
            case .light:  return .light
            case .dark:   return .dark
            }
        }()
        let cs = ThemeStore.shared.colorScheme
        let t = cs == .dark ? manager.darkTheme : manager.lightTheme
        let bottom = ResolvedTheme.adjustBrightness(
            t.background,
            by: cs == .dark ? -0.02 : 0.01
        )
        return WatchThemePayload(
            appearanceMode: mode,
            isDark: cs == .dark,
            accent: t.accent,
            accentStrong: t.accentStrong,
            textPrimary: t.textPrimary,
            textSecondary: t.textSecondary,
            textMuted: t.textMuted,
            surface: t.surface,
            surfaceLight: t.surfaceLight,
            border: t.border,
            danger: t.danger,
            success: t.success,
            warning: t.warning,
            textOnAccent: t.textOnAccent,
            backgroundTop: t.background,
            backgroundBottom: bottom
        )
    }
}
