import SwiftUI
import HairballUI

struct SubagentCardView: View {
    @Environment(AppModel.self) private var appModel
    let data: ConversationMultiAgentActionData
    let serverId: String
    let resolveTargetLabel: (String) -> String?
    let resolveThreadKey: (String) -> ThreadKey?
    let resolveLiveStatus: (ThreadKey) -> AppSubagentStatus?
    @State private var expanded: Bool
    @State private var sheetThreadKey: ThreadKey?
    @State private var sheetAgentLabel: String?

    init(
        data: ConversationMultiAgentActionData,
        serverId: String,
        resolveTargetLabel: @escaping (String) -> String?,
        resolveThreadKey: @escaping (String) -> ThreadKey?,
        resolveLiveStatus: @escaping (ThreadKey) -> AppSubagentStatus?
    ) {
        self.data = data
        self.serverId = serverId
        self.resolveTargetLabel = resolveTargetLabel
        self.resolveThreadKey = resolveThreadKey
        self.resolveLiveStatus = resolveLiveStatus
        _expanded = State(initialValue: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(agentRows.enumerated()), id: \.offset) { _, row in
                        agentRowView(row)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $sheetThreadKey) { key in
            // `resolveThreadKey` is precomputed by `ConversationScreenModel`
            // from a captured snapshot and mirrors
            // `AppSnapshotRecord.resolvedThreadKey(for:serverId:)`, so this
            // closure no longer reads `appModel.snapshot`.
            let resolvedKey = resolveThreadKey(key.threadId) ?? key
            SubagentDetailSheet(threadKey: resolvedKey, agentLabel: sheetAgentLabel)
                .environment(appModel)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(actionLabel)
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textSystem)
                .lineLimit(1)

            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .litterFont(size: 11, weight: .medium)
                .foregroundColor(LitterTheme.textMuted)

            Spacer()
        }
    }

    private var actionLabel: String {
        let agentCount = max(data.targets.count, data.agentStates.count)
        let suffix = agentCount == 1 ? "1 agent" : "\(agentCount) agents"
        switch data.tool.lowercased() {
        case "spawnagent", "spawn_agent":
            return "Spawning \(suffix)"
        case "sendinput", "send_input":
            return "Sending input to \(suffix)"
        case "resumeagent", "resume_agent":
            return "Resuming \(suffix)"
        case "wait":
            return "Waiting for \(suffix)"
        case "closeagent", "close_agent":
            return "Closing \(suffix)"
        default:
            return "\(data.tool) \(suffix)"
        }
    }

    // MARK: - Agent Rows

    private var agentRows: [AgentRowData] {
        let statesByTarget = Dictionary(
            data.agentStates.map { ($0.targetId, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var rows: [AgentRowData] = []
        for (index, target) in data.targets.enumerated() {
            let threadId = index < data.receiverThreadIds.count ? data.receiverThreadIds[index] : nil
            let state = threadId.flatMap { statesByTarget[$0] }
                ?? statesByTarget[target]
            let agentPrompt = index < data.perAgentPrompts.count ? data.perAgentPrompts[index] : nil
            rows.append(AgentRowData(
                label: target,
                threadId: threadId,
                status: state?.status,
                statusMessage: state?.message,
                prompt: agentPrompt
            ))
        }

        for state in data.agentStates where !rows.contains(where: { $0.threadId == state.targetId }) {
            if !rows.contains(where: { $0.label == state.targetId }) {
                rows.append(AgentRowData(
                    label: state.targetId,
                    threadId: state.targetId,
                    status: state.status,
                    statusMessage: state.message,
                    prompt: nil
                ))
            }
        }

        return rows
    }

    // MARK: - Resolve

    private func resolvedLabel(for row: AgentRowData) -> String {
        if !row.label.isEmpty && !looksLikeRawId(row.label) {
            return row.label
        }
        if let resolved = resolveTargetLabel(row.label) {
            return resolved
        }
        if let threadId = row.threadId,
           let resolved = resolveTargetLabel(threadId) {
            return resolved
        }
        return row.label
    }

    private func resolvedThreadKey(for row: AgentRowData) -> ThreadKey? {
        if let threadId = row.threadId {
            return resolveThreadKey(threadId)
        }
        return nil
    }

    private func liveStatus(for row: AgentRowData) -> AppSubagentStatus? {
        if let key = resolvedThreadKey(for: row),
           let status = resolveLiveStatus(key) {
            return status
        }
        return row.status
    }

    private func looksLikeRawId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        return trimmed.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Row View

    private func agentRowView(_ row: AgentRowData) -> some View {
        let resolvedKey = resolvedThreadKey(for: row)
        let displayLabel = resolvedLabel(for: row)
        let status = liveStatus(for: row)
        let parts = parseAgentLabel(displayLabel)

        return VStack(alignment: .leading, spacing: 2) {
            // Line 1: Name + status + Open
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                let statusStr = readableStatus(status)
                let isActive = status == .running

                (
                    Text(parts.nickname)
                        .foregroundColor(nicknameColor(for: parts.nickname))
                    + Text(parts.roleSuffix)
                        .foregroundColor(LitterTheme.textSystem)
                    + Text(" \(statusStr)")
                        .foregroundColor(LitterTheme.textSecondary)
                )
                .litterFont(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(ShimmerText(active: isActive))

                Spacer(minLength: 8)

                if row.threadId != nil {
                    Button {
                        sheetAgentLabel = displayLabel
                        if let key = resolvedKey {
                            sheetThreadKey = key
                        } else if let threadId = row.threadId {
                            sheetThreadKey = ThreadKey(serverId: serverId, threadId: threadId)
                        }
                    } label: {
                        Text("Open")
                            .litterFont(.caption)
                            .foregroundColor(resolvedKey != nil ? LitterTheme.textSecondary : LitterTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Line 2: Per-agent prompt if available, else shared prompt
            if let prompt = row.prompt, !prompt.isEmpty {
                Text(prompt)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else if let prompt = data.prompt, !prompt.isEmpty {
                Text(prompt)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    private func readableStatus(_ status: AppSubagentStatus?) -> String {
        switch status ?? .unknown {
        case .running: return "is thinking"
        case .pendingInit: return "is awaiting instruction"
        case .completed: return "has completed"
        case .errored: return "encountered an error"
        case .interrupted: return "was interrupted"
        case .shutdown: return "was shut down"
        case .unknown: return ""
        }
    }

    private func parseAgentLabel(_ label: String) -> (nickname: String, roleSuffix: String) {
        guard label.hasSuffix("]"),
              let openBracket = label.lastIndex(of: "[") else {
            return (label, "")
        }
        let nickname = String(label[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = label.index(after: openBracket)
        let roleEnd = label.index(before: label.endIndex)
        let role = String(label[roleStart..<roleEnd])
        return (nickname, " (\(role))")
    }

    private static let nicknameColors: [Color] = [
        Color(red: 0.90, green: 0.30, blue: 0.30), // red
        Color(red: 0.30, green: 0.75, blue: 0.55), // green
        Color(red: 0.40, green: 0.55, blue: 0.95), // blue
        Color(red: 0.85, green: 0.60, blue: 0.25), // orange
        Color(red: 0.70, green: 0.45, blue: 0.85), // purple
        Color(red: 0.25, green: 0.78, blue: 0.82), // teal
        Color(red: 0.90, green: 0.50, blue: 0.60), // pink
        Color(red: 0.65, green: 0.75, blue: 0.30), // lime
    ]

    private func nicknameColor(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Self.nicknameColors[Int(hash % UInt64(Self.nicknameColors.count))]
    }
}

// MARK: - Shimmer

private struct ShimmerText: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 2.0) / 2.0)

                content
                    .overlay {
                        GeometryReader { geo in
                            let w = geo.size.width
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: max(0, phase - 0.2)),
                                    .init(color: .white.opacity(0.35), location: phase),
                                    .init(color: .white.opacity(0), location: min(1, phase + 0.2))
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: w, height: geo.size.height)
                        }
                        .blendMode(.sourceAtop)
                    }
                    .compositingGroup()
            }
        } else {
            content
        }
    }
}

// MARK: - Detail Sheet

private struct SubagentDetailSheet: View {
    @Environment(AppModel.self) private var appModel
    let threadKey: ThreadKey
    var agentLabel: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    /// Live thread + title, mirrored out of `appModel.snapshot` by
    /// `snapshotObserver`. Both used to be computed in `body`, which meant the
    /// sheet re-rendered its whole timeline on every snapshot revision
    /// (~8 fps) rather than only when this thread changed.
    @State private var threadSnapshot: AppThreadSnapshot?
    /// Title resolved in the same precedence order the body used to compute
    /// inline. Seeded from the caller's already-resolved `agentLabel` so the
    /// first frame is correct, then kept current by `snapshotObserver`.
    @State private var title: String
    @State private var snapshotObserver = AppSnapshotObserver()

    init(threadKey: ThreadKey, agentLabel: String? = nil) {
        self.threadKey = threadKey
        self.agentLabel = agentLabel
        let seed = agentLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _title = State(initialValue: seed.isEmpty ? "Agent" : seed)
        _threadSnapshot = State<AppThreadSnapshot?>(initialValue: nil)
    }

    /// Called from `snapshotObserver`, never from `body`. Preserves the
    /// original resolution order: live summary for the resolved key, summary
    /// for the requested key, the caller's label, then the directory lookup.
    private func refreshSnapshotProjections(_ appModel: AppModel) {
        let snapshot = appModel.snapshot
        let nextThread = snapshot?.threadSnapshot(for: threadKey)
        if threadSnapshot != nextThread {
            threadSnapshot = nextThread
        }

        var nextTitle = nextThread.flatMap { snapshot?.sessionSummary(for: $0.key)?.agentDisplayLabel }
            ?? snapshot?.sessionSummary(for: threadKey)?.agentDisplayLabel
        if nextTitle == nil, let label = agentLabel, !label.isEmpty, !looksLikeId(label) {
            nextTitle = label
        }
        if nextTitle == nil {
            nextTitle = snapshot?.resolvedAgentTargetLabel(
                for: threadKey.threadId,
                serverId: threadKey.serverId
            )
        }
        let resolved = nextTitle ?? agentLabel ?? "Agent"
        if title != resolved {
            title = resolved
        }
    }

    private func looksLikeId(_ value: String) -> Bool {
        value.count >= 16 && value.range(of: #"^[0-9a-fA-F-]+$"#, options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let threadSnapshot {
                    let items = threadSnapshot.hydratedConversationItems.map(\.conversationItem)
                    ScrollView {
                        if items.isEmpty {
                            VStack(spacing: 12) {
                                Spacer().frame(height: 40)
                                ProgressView()
                                    .tint(LitterTheme.accent)
                                Text(isLoading ? "Loading thread..." : "Waiting for agent output...")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textMuted)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            ConversationTurnTimeline(
                                items: items,
                                isLive: threadSnapshot.activeTurnId != nil || threadSnapshot.info.status == .active,
                                serverId: threadKey.serverId,
                                originThreadId: threadKey.threadId,
                                agentDirectoryVersion: 0,
                                messageActionsDisabled: true,
                                onStreamingSnapshotRendered: nil,
                                onLiveContentLayoutChanged: nil,
                                resolveTargetLabel: { _ in nil },
                                resolveThreadKey: { _ in nil },
                                resolveLiveStatus: { _ in nil },
                                onWidgetPrompt: { _ in },
                                onEditUserItem: { _ in },
                                onForkFromUserItem: { _ in }
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "person.fill.questionmark")
                            .litterFont(size: 32)
                            .foregroundColor(LitterTheme.textMuted)
                        Text("Thread not available yet")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textSecondary)
                        Text("The agent may still be initializing.")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textMuted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    let parts = parseLabel(title)
                    (
                        Text(parts.nickname)
                            .foregroundColor(titleColor(for: parts.nickname))
                        + Text(parts.roleSuffix)
                            .foregroundColor(LitterTheme.textSecondary)
                    )
                    .litterFont(.callout, weight: .semibold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: threadKey.id) {
            // Start (or re-target) the projection before the load so
            // `loadThreadIfNeeded` sees the current thread state, and so the
            // sheet keeps streaming while it is open.
            let model = appModel
            snapshotObserver.start(appModel: model) { refreshSnapshotProjections(model) }
            await loadThreadIfNeeded()
        }
        .onDisappear { snapshotObserver.stop() }
    }

    private func parseLabel(_ label: String) -> (nickname: String, roleSuffix: String) {
        guard label.hasSuffix("]"), let openBracket = label.lastIndex(of: "[") else {
            return (label, "")
        }
        let nickname = String(label[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        let role = String(label[label.index(after: openBracket)..<label.index(before: label.endIndex)])
        return (nickname, " (\(role))")
    }

    private static let colors: [Color] = [
        Color(red: 0.90, green: 0.30, blue: 0.30),
        Color(red: 0.30, green: 0.75, blue: 0.55),
        Color(red: 0.40, green: 0.55, blue: 0.95),
        Color(red: 0.85, green: 0.60, blue: 0.25),
        Color(red: 0.70, green: 0.45, blue: 0.85),
        Color(red: 0.25, green: 0.78, blue: 0.82),
        Color(red: 0.90, green: 0.50, blue: 0.60),
        Color(red: 0.65, green: 0.75, blue: 0.30),
    ]

    private func titleColor(for name: String) -> Color {
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
        return Self.colors[Int(hash % UInt64(Self.colors.count))]
    }

    private func loadThreadIfNeeded() async {
        guard threadSnapshot == nil, !isLoading else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await appModel.resumeThread(
                key: threadKey,
                launchConfig: AppThreadLaunchConfig(
                    model: nil,
                    approvalPolicy: nil,
                    sandbox: nil,
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ),
                cwdOverride: nil
            )
            await appModel.refreshThreadSnapshot(key: threadKey)
        } catch {}
    }
}

extension ThreadKey: Identifiable {
    public var id: String { "\(serverId)/\(threadId)" }
}

private struct AgentRowData {
    let label: String
    let threadId: String?
    let status: AppSubagentStatus?
    let statusMessage: String?
    let prompt: String?
}

#if DEBUG
#Preview("Subagent Card") {
    ZStack {
        LitterTheme.backgroundGradient.ignoresSafeArea()
        VStack(spacing: 20) {
            SubagentCardView(
                data: ConversationMultiAgentActionData(
                    tool: "spawnAgent",
                    status: .inProgress,
                    prompt: "Explore /Users/sigkitten/dev/codex-app with a repo-orientation focus. Scan the top-level directories and identify the main modules.",
                    targets: ["Locke [explorer]", "Dalton [explorer]"],
                    receiverThreadIds: ["thread-abc-123", "thread-def-456"],
                    agentStates: [
                        ConversationMultiAgentState(targetId: "thread-abc-123", status: .running, message: nil),
                        ConversationMultiAgentState(targetId: "thread-def-456", status: .running, message: nil)
                    ]
                ),
                serverId: "preview-server",
                resolveTargetLabel: { _ in nil },
                resolveThreadKey: { ThreadKey(serverId: "preview-server", threadId: $0) },
                resolveLiveStatus: { _ in nil }
            )

            SubagentCardView(
                data: ConversationMultiAgentActionData(
                    tool: "wait",
                    status: .completed,
                    prompt: nil,
                    targets: ["Locke [explorer]", "Dalton [explorer]"],
                    receiverThreadIds: ["thread-abc-123", "thread-def-456"],
                    agentStates: [
                        ConversationMultiAgentState(targetId: "thread-abc-123", status: .completed, message: nil),
                        ConversationMultiAgentState(targetId: "thread-def-456", status: .errored, message: "context limit")
                    ]
                ),
                serverId: "preview-server",
                resolveTargetLabel: { _ in nil },
                resolveThreadKey: { ThreadKey(serverId: "preview-server", threadId: $0) },
                resolveLiveStatus: { _ in nil }
            )
        }
        .padding(16)
    }
}
#endif
