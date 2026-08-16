import SwiftUI
import Charts

struct ConversationInfoView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.dismiss) private var dismiss

    /// When nil, the screen shows server-only info (no session-specific sections).
    let threadKey: ThreadKey?
    /// Server ID used when threadKey is nil (server-only mode).
    let serverId: String?
    var onOpenWallpaper: (() -> Void)?
    var onOpenConversation: ((ThreadKey) -> Void)?
    var onOpenShell: (() -> Void)?

    /// Whether we're in server-only mode (no specific thread).
    private var isServerOnly: Bool { threadKey == nil }

    private var resolvedServerId: String? {
        threadKey?.serverId ?? serverId
    }

    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var stats: AppConversationStats?
    @State private var serverUsage: AppServerUsageStats?
    @State private var isShowingMountedFolders = false

    /// Resolved snapshot of the thread for this screen. Stored in `@State`
    /// and refreshed from `.onAppear`/`.onChange` (closure context), NOT read
    /// from `appModel.snapshot` in `body`. Reading `appModel.snapshot` in
    /// `body` would create a per-token observation edge that re-renders the
    /// entire info screen on every streaming delta.
    @State private var resolvedThread: AppThreadSnapshot?

    /// Resolved snapshot of the server. Same pattern as `resolvedThread`.
    @State private var resolvedServer: AppServerSnapshot?

    private var thread: AppThreadSnapshot? { resolvedThread }

    private var server: AppServerSnapshot? { resolvedServer }

    private func refreshResolvedSnapshot() {
        guard let snapshot = appModel.snapshot else {
            resolvedThread = nil
            resolvedServer = nil
            return
        }
        if let threadKey {
            resolvedThread = snapshot.threads.first { $0.key == threadKey }
        }
        if let sid = resolvedServerId {
            resolvedServer = snapshot.servers.first { $0.serverId == sid }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !isServerOnly {
                    // Hero header
                    heroSection
                        .padding(.bottom, 20)

                    // Action buttons row (Telegram-style)
                    actionButtonsRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)

                    // Thin divider
                    Rectangle()
                        .fill(LitterTheme.separator.opacity(0.4))
                        .frame(height: 0.5)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                }

                // Content sections
                VStack(spacing: 16) {
                    if isServerOnly {
                        // Server-only mode: just wallpaper button at top
                        serverOnlyActionRow
                            .padding(.top, 8)
                    }
                    if !isServerOnly {
                        contextWindowSection
                        conversationStatsSection
                    }
                    serverChartsSection
                    serverInfoSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .background(LitterTheme.backgroundGradient)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(isServerOnly ? "Server Info" : "Info")
                    .litterFont(size: 16, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
        }
        .onAppear {
            refreshResolvedSnapshot()
            computeData()
        }
        .onChange(of: appModel.snapshotRevision) {
            refreshResolvedSnapshot()
            computeData()
        }
        .alert("Rename Thread", isPresented: $isRenaming) {
            TextField("Thread name", text: $renameText)
            Button("Save") { saveRename() }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $isShowingMountedFolders) {
            MountedFoldersView()
        }
    }

    // MARK: - Server-Only Action Row

    private var serverOnlyActionRow: some View {
        HStack(spacing: 0) {
            actionCircle(icon: "paintbrush", label: "Appearance") {
                onOpenWallpaper?()
            }
            if let onOpenShell {
                actionCircle(icon: "terminal", label: "Shell") {
                    onOpenShell()
                }
            }
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 12) {
            // Status dot + title
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(thread?.displayTitle ?? "Untitled session")
                    .litterFont(size: 22, weight: .bold)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(2)
            }

            // Model + reasoning badges
            HStack(spacing: 8) {
                if let model = thread?.displayModelLabel,
                   !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(model)
                        .litterFont(size: 13, weight: .medium)
                        .foregroundStyle(LitterTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .modifier(GlassRectModifier(cornerRadius: 8))
                }
                if let effort = thread?.reasoningEffort {
                    Text(effort)
                        .litterFont(size: 12, weight: .regular)
                        .foregroundStyle(LitterTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .modifier(GlassRectModifier(cornerRadius: 8))
                }
            }

            // Metadata row: cwd + timestamps
            VStack(spacing: 6) {
                if let cwd = thread?.info.cwd {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(LitterTheme.textMuted)
                        Text(abbreviatePath(cwd))
                            .litterFont(size: 12)
                            .foregroundStyle(LitterTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let tid = threadKey?.threadId {
                    HStack(spacing: 5) {
                        Image(systemName: "number")
                            .font(.system(size: 10))
                            .foregroundStyle(LitterTheme.textMuted)
                        Text(tid)
                            .litterFont(size: 11)
                            .foregroundStyle(LitterTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 12) {
                    if let created = thread?.info.createdAt {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                                .foregroundStyle(LitterTheme.textMuted)
                            Text(relativeDate(created))
                                .litterFont(size: 11)
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                    if let updated = thread?.info.updatedAt {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(LitterTheme.textMuted)
                            Text(relativeDate(updated))
                                .litterFont(size: 11)
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                }
            }
        }
        .padding(.top, 16)
    }

    private func abbreviatePath(_ path: String) -> String {
        PathDisplay.display(path, isLocal: server?.isLocal == true)
    }

    // MARK: - Action Buttons Row (Telegram-style)

    private var actionButtonsRow: some View {
        HStack(spacing: 0) {
            actionCircle(icon: "paintbrush", label: "Appearance") {
                onOpenWallpaper?()
            }
            actionCircle(icon: "arrow.branch", label: "Fork") {
                Task { await forkConversation() }
            }
            actionCircle(icon: "pencil", label: "Rename") {
                renameText = thread?.info.title ?? ""
                isRenaming = true
            }
        }
    }

    private func actionCircle(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LitterTheme.accent)
                    .frame(width: 52, height: 52)
                    .modifier(GlassRectModifier(cornerRadius: 14))
                Text(label)
                    .litterFont(size: 11, weight: .medium)
                    .foregroundStyle(LitterTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func timestampLabel(_ label: String, timestamp: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .litterFont(size: 10, weight: .medium)
                .foregroundStyle(LitterTheme.textMuted)
            Text(relativeDate(timestamp))
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textSecondary)
        }
    }

    private var statusColor: Color {
        switch thread?.info.status {
        case .active: return LitterTheme.success
        case .idle: return LitterTheme.textMuted
        case .systemError: return LitterTheme.danger
        case .notLoaded: return LitterTheme.textMuted
        default: return LitterTheme.textMuted
        }
    }

    // MARK: - Context Window

    private var contextWindowSection: some View {
        Group {
            if let used = thread?.contextTokensUsed, let window = thread?.modelContextWindow, window > 0 {
                let percent = Double(used) / Double(window)
                VStack(spacing: 8) {
                    HStack {
                        Text("Context Window")
                            .litterFont(size: 14, weight: .semibold)
                            .foregroundStyle(LitterTheme.textPrimary)
                        Spacer()
                        Text("\(Int(percent * 100))%")
                            .litterFont(size: 14, weight: .bold)
                            .foregroundStyle(contextColor(percent: percent))
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LitterTheme.border)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(contextColor(percent: percent))
                                .frame(width: geo.size.width * min(1, percent), height: 8)
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(formatTokens(used))
                            .litterFont(size: 11)
                            .foregroundStyle(LitterTheme.textMuted)
                        Spacer()
                        Text(formatTokens(window))
                            .litterFont(size: 11)
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                }
                .padding(16)
                .modifier(GlassRectModifier(cornerRadius: 12))
            }
        }
    }

    private func contextColor(percent: Double) -> Color {
        if percent >= 0.8 { return LitterTheme.danger }
        if percent >= 0.6 { return LitterTheme.warning }
        return LitterTheme.accent
    }

    private func formatTokens(_ tokens: UInt64) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    // MARK: - Per-Conversation Stats

    private var conversationStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversation Stats")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                statCard("Messages", value: "\(stats?.totalMessages ?? 0)", detail: "\(stats?.userMessageCount ?? 0) user · \(stats?.assistantMessageCount ?? 0) assistant")
                statCard("Turns", value: "\(stats?.turnCount ?? 0)")
                statCard("Commands", value: "\(stats?.commandsExecuted ?? 0)", detail: "\(stats?.commandsSucceeded ?? 0) ok · \(stats?.commandsFailed ?? 0) fail")
                statCard("Files Changed", value: "\(stats?.filesChanged ?? 0)", detail: "+\(stats?.diffAdditions ?? 0) / -\(stats?.diffDeletions ?? 0)")
                statCard("MCP Calls", value: "\(stats?.mcpToolCallCount ?? 0)")
                statCard("Exec Time", value: formatDuration(Int64(stats?.totalCommandDurationMs ?? 0)))
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func statCard(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .litterFont(size: 20, weight: .bold)
                .foregroundStyle(LitterTheme.accent)
            Text(title)
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)
            if let detail {
                Text(detail)
                    .litterFont(size: 10)
                    .foregroundStyle(LitterTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(GlassRectModifier(cornerRadius: 8))
    }

    private func formatDuration(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let secs = Double(ms) / 1000
        if secs < 60 { return String(format: "%.1fs", secs) }
        let mins = Int(secs / 60)
        let remainSecs = Int(secs) % 60
        return "\(mins)m \(remainSecs)s"
    }

    // MARK: - Section B: Server-Wide Charts

    private var serverChartsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Usage")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            if let usage = serverUsage {
                if !usage.tokensByThread.isEmpty {
                    tokenUsageChart(usage)
                }

                if !usage.activityByDay.isEmpty {
                    activityChart(usage)
                }

                if !usage.modelUsage.isEmpty {
                    modelBreakdownChart(usage)
                }
            }

            if let rateLimits = server?.rateLimits {
                rateLimitGauge(rateLimits)
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func tokenUsageChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage by Conversation")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(Array(usage.tokensByThread.enumerated()), id: \.offset) { _, entry in
                AreaMark(
                    x: .value("Thread", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.3))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Thread", entry.threadTitle),
                    y: .value("Tokens", entry.tokens)
                )
                .foregroundStyle(LitterTheme.accent)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .frame(height: 160)
        }
    }

    private func activityChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity Timeline")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(Array(usage.activityByDay.enumerated()), id: \.offset) { _, entry in
                BarMark(
                    x: .value("Date", Date(timeIntervalSince1970: TimeInterval(entry.dateEpoch)), unit: .day),
                    y: .value("Activity", entry.turnCount)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .frame(height: 140)
        }
    }

    private func modelBreakdownChart(_ usage: AppServerUsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Usage")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            Chart(Array(usage.modelUsage.enumerated()), id: \.offset) { _, entry in
                BarMark(
                    x: .value("Count", entry.threadCount),
                    y: .value("Model", entry.model)
                )
                .foregroundStyle(LitterTheme.accent.opacity(0.7))
                .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(LitterTheme.border)
                    AxisValueLabel()
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LitterTheme.textSecondary)
                }
            }
            .frame(height: CGFloat(max(usage.modelUsage.count * 32, 60)))
        }
    }

    private func rateLimitGauge(_ rateLimits: RateLimitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rate Limits")
                .litterFont(size: 12, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)

            HStack(spacing: 16) {
                if let primary = rateLimits.primary {
                    rateLimitRing(label: "Primary", window: primary)
                }
                if let secondary = rateLimits.secondary {
                    rateLimitRing(label: "Secondary", window: secondary)
                }
            }
        }
    }

    private func rateLimitRing(label: String, window: RateLimitWindow) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(LitterTheme.border, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: Double(window.usedPercent) / 100)
                    .stroke(rateLimitColor(percent: Int(window.usedPercent)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(window.usedPercent)%")
                    .litterFont(size: 12, weight: .bold)
                    .foregroundStyle(LitterTheme.textPrimary)
            }
            .frame(width: 56, height: 56)

            Text(label)
                .litterFont(size: 10)
                .foregroundStyle(LitterTheme.textMuted)
        }
    }

    private func rateLimitColor(percent: Int) -> Color {
        if percent >= 80 { return LitterTheme.danger }
        if percent >= 60 { return LitterTheme.warning }
        return LitterTheme.accent
    }

    // MARK: - Section C: Server Info

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server")
                .litterFont(size: 14, weight: .semibold)
                .foregroundStyle(LitterTheme.textPrimary)

            if let server {
                infoRow("Name", value: server.displayName)
                infoRow("Address", value: "\(server.host):\(server.port)")
                infoRow("Mode", value: server.connectionModeLabel)

                HStack(spacing: 6) {
                    Text("Health")
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textMuted)
                    Spacer()
                    Circle()
                        .fill(healthColor(server.health))
                        .frame(width: 8, height: 8)
                    Text(healthLabel(server.health))
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textSecondary)
                }

                if let account = server.account {
                    accountRow(account)
                }

                if let models = server.availableModels, !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available Models")
                            .litterFont(size: 12)
                            .foregroundStyle(LitterTheme.textMuted)
                        ForEach(models.prefix(8), id: \.id) { model in
                            Text(model.displayName)
                                .litterFont(size: 12)
                                .foregroundStyle(LitterTheme.textSecondary)
                        }
                        if models.count > 8 {
                            Text("+\(models.count - 8) more")
                                .litterFont(size: 11)
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                }

                if server.isLocal {
                    Button {
                        isShowingMountedFolders = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.badge.icloud")
                                .litterFont(size: 12)
                                .foregroundStyle(LitterTheme.accent)
                            Text("Mounted folders")
                                .litterFont(size: 12)
                                .foregroundStyle(LitterTheme.textSecondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .litterFont(size: 11, weight: .semibold)
                                .foregroundStyle(LitterTheme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textMuted)
            Spacer()
            Text(value)
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textSecondary)
        }
    }

    private func healthColor(_ health: AppServerHealth) -> Color {
        switch health {
        case .connected: return LitterTheme.success
        case .connecting: return LitterTheme.warning
        case .disconnected, .unresponsive: return LitterTheme.danger
        case .unknown: return LitterTheme.textMuted
        }
    }

    private func healthLabel(_ health: AppServerHealth) -> String {
        switch health {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .unresponsive: return "Unresponsive"
        case .unknown: return "Unknown"
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack {
            Text("Account")
                .litterFont(size: 12)
                .foregroundStyle(LitterTheme.textMuted)
            Spacer()
            switch account {
            case .apiKey:
                Text("API Key")
                    .litterFont(size: 12)
                    .foregroundStyle(LitterTheme.textSecondary)
            case .chatgpt(let email, let planType):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(email)
                        .litterFont(size: 12)
                        .foregroundStyle(LitterTheme.textSecondary)
                    Text(planTypeLabel(planType))
                        .litterFont(size: 10)
                        .foregroundStyle(LitterTheme.textMuted)
                }
            }
        }
    }

    private func planTypeLabel(_ planType: PlanType) -> String {
        switch planType {
        case .free: return "Free"
        case .go: return "Go"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .team: return "Team"
        case .business: return "Business"
        case .enterprise: return "Enterprise"
        case .edu: return "Edu"
        case .unknown: return "Unknown"
        }
    }

    // (Actions are now in the hero section's actionButtonsRow)

    // MARK: - Actions

    private func forkConversation() async {
        guard let threadKey else { return }
        do {
            let sourceKey = await appModel.hydrateThreadPermissions(for: threadKey, appState: appState)
                ?? threadKey
            let newKey = try await appModel.client.forkThread(
                serverId: sourceKey.serverId,
                params: AppThreadLaunchConfig(
                    model: thread?.model,
                    approvalPolicy: appState.launchApprovalPolicy(for: sourceKey),
                    sandbox: appState.launchSandboxMode(for: sourceKey),
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ).threadForkRequest(threadId: sourceKey.threadId, cwdOverride: thread?.info.cwd)
            )
            appModel.store.setActiveThread(key: newKey)
            await appModel.refreshThreadSnapshot(key: newKey)
            onOpenConversation?(newKey)
        } catch {
            LLog.error("info", "failed to fork thread", error: error)
        }
    }

    private func saveRename() {
        guard let threadKey else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        isRenaming = false
        Task {
            do {
                try await appModel.renameThread(
                    serverId: threadKey.serverId,
                    threadId: threadKey.threadId,
                    title: title
                )
            } catch {
                LLog.error("info", "failed to rename thread", error: error)
            }
        }
    }

    private func computeData() {
        if let thread {
            stats = thread.stats
        }
        if let server {
            serverUsage = server.usageStats
        }
    }
}
