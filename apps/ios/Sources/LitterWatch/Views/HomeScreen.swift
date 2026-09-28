import SwiftUI
import WatchKit

/// 1 · Task pages — the watch's home is one full-screen page per task plus a
/// trailing "new task" page. Crown rotation switches tasks; each page has
/// glance-sized status + content and Open/Hide CTAs at the bottom. Falls back
/// to centered empty states when there are no tasks (or no data yet).
struct HomeScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        Group {
            if !store.hasData {
                skeletonPages
            } else if store.tasks.isEmpty {
                WatchEmptyState(
                    icon: "sparkles",
                    title: "no tasks yet",
                    subtitle: "start a conversation on iphone."
                )
            } else {
                pagedTasks
            }
        }
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }

    /// Cold-launch placeholder: three pulsing skeleton pages plus a final
    /// hint page so the user knows the watch is waiting on iPhone.
    private var skeletonPages: some View {
        TabView {
            ForEach(0..<3, id: \.self) { _ in
                SkeletonTaskPlaceholder()
            }
            WatchEmptyState(
                icon: store.isReachable ? "iphone.gen3" : "iphone.slash",
                title: store.isReachable ? "syncing…" : "open litter on iphone",
                subtitle: store.isReachable ? nil : "the watch shows what the phone knows."
            )
        }
        .tabViewStyle(.verticalPage)
    }

    private var pagedTasks: some View {
        TabView(selection: tabSelection) {
            ForEach(store.tasks) { task in
                TaskPage(task: task)
                    .tag(Selection.task(task.id))
            }
            NewTaskPage()
                .tag(Selection.newTask)
            if !store.hiddenTasks.isEmpty {
                HiddenFooterPage(count: store.hiddenTasks.count)
                    .tag(Selection.hidden)
            }
        }
        .tabViewStyle(.verticalPage)
    }

    // MARK: - Selection binding

    /// Backs the `TabView`'s selection. Folded through a local enum so the
    /// trailing "new task" page can coexist with task ids without collisions,
    /// while still writing the focused-task id back to the store.
    private enum Selection: Hashable {
        case task(String)
        case newTask
        case hidden
    }

    private var tabSelection: Binding<Selection> {
        Binding(
            get: {
                if let id = store.focusedTaskId,
                   store.tasks.contains(where: { $0.id == id }) {
                    return .task(id)
                }
                return store.tasks.first.map { .task($0.id) } ?? .newTask
            },
            set: { new in
                switch new {
                case .task(let id): store.focusedTaskId = id
                case .newTask, .hidden: break
                }
            }
        )
    }
}

/// Trailing footer page shown only when there are hidden threads. A single
/// large NavigationLink keeps the gesture target obvious on the small face.
private struct HiddenFooterPage: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            NavigationLink {
                HiddenThreadsScreen()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 18 * watchSize.fontScale, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(theme.surfaceLight)
                                .overlay(Circle().stroke(theme.borderHi, lineWidth: 1))
                        )
                    Text("\(count) hidden")
                        .font(WatchTheme.scaled(12, for: watchSize, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("tap to manage")
                        .font(WatchTheme.scaled(10, for: watchSize))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}

// MARK: - Per-task page

/// One full-screen page of task content. Larger fonts than the prior row,
/// with status/header chip up top, identity strip + subtitle in the middle,
/// and Open / Hide CTAs pinned to the bottom.
private struct TaskPage: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.isLuminanceReduced) private var isAOD
    @Environment(\.watchSize) private var watchSize
    let task: WatchTask

    var body: some View {
        NavigationLink {
            TaskDetailScreen(task: task)
        } label: {
            content
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                WKInterfaceDevice.current().play(.click)
                WatchSessionBridge.shared.sendHomeHide(
                    serverId: task.serverId,
                    threadId: task.threadId
                )
            } label: {
                Label("Hide", systemImage: "eye.slash")
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusChip(status: task.status, isAOD: isAOD)
                Spacer(minLength: 4)
                if !isAOD, store.lastSyncIsStale && !store.isReachable {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textMuted)
                }
                if !isAOD {
                    HeaderBadges()
                }
                if !task.relativeTime.isEmpty {
                    Text(task.relativeTime)
                        .font(WatchTheme.scaled(10, for: watchSize))
                        .foregroundStyle(theme.textMuted)
                        .fixedSize()
                }
            }

            Text(task.title)
                .font(WatchTheme.scaled(15, for: watchSize, weight: .bold))
                .foregroundStyle(titleColor)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !isAOD {
                identityStrip

                if let subtitle = task.subtitle, !subtitle.isEmpty {
                    // Assistant message gets the prime real estate — no CTA
                    // row competes with it now. Allow up to 6 lines before
                    // truncation since the page has no other content below.
                    Text(subtitle)
                        .font(WatchTheme.scaled(12, for: watchSize))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(6)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let tool = task.lastTool, !tool.isEmpty {
                    toolChip(tool)
                }

                if task.status == .running, let line = telemetryLine {
                    Text(line)
                        .font(WatchTheme.scaled(10, for: watchSize))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var titleColor: Color {
        if isAOD { return theme.textSecondary }
        return task.status == .running ? theme.accent : theme.textPrimary
    }

    // MARK: - Pieces

    private var identityStrip: some View {
        HStack(spacing: 4) {
            Text(task.serverName)
                .foregroundStyle(theme.accent.opacity(0.7))
                .lineLimit(1)
            if let model = task.model, !model.isEmpty {
                dot
                Text(model)
                    .foregroundStyle(theme.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }
            if let basename = cwdBasename {
                dot
                Text(basename)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(WatchTheme.scaled(10, for: watchSize))
    }

    /// Small live-tool chip rendered below the assistant subtitle when the
    /// task is currently running. Shows what tool the AI is using right now
    /// without stealing the subtitle slot from the assistant text.
    private func toolChip(_ tool: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 8, weight: .bold))
            Text(tool)
                .font(WatchTheme.scaled(9, for: watchSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(theme.accent.opacity(0.12))
                .overlay(Capsule().stroke(theme.accent.opacity(0.3), lineWidth: 0.5))
        )
    }

    private var dot: some View {
        Text("·").foregroundStyle(theme.textMuted.opacity(0.6))
    }

    private var cwdBasename: String? {
        guard let cwd = task.cwd, !cwd.isEmpty else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    private var subtitleColor: Color {
        switch task.status {
        case .running:       return theme.accent
        case .needsApproval: return theme.warning
        case .idle:          return theme.textMuted
        case .error:         return theme.danger
        }
    }

    private var telemetryLine: String? {
        var parts: [String] = []
        if let t = task.turnCount, t > 0 { parts.append("\(t) turns") }
        let adds = task.diffAdditions ?? 0
        let rems = task.diffDeletions ?? 0
        if adds > 0 || rems > 0 { parts.append("+\(adds) −\(rems)") }
        if let pct = task.contextPercent, pct > 0 { parts.append("\(pct)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Trailing "new task" page

private struct NewTaskPage: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            NavigationLink {
                VoiceScreen()
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22 * watchSize.fontScale, weight: .bold))
                        .foregroundStyle(theme.textOnAccent)
                        .frame(width: micDiameter, height: micDiameter)
                        .background(
                            Circle().fill(
                                LinearGradient(colors: [theme.accentSoft, theme.accent],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        )
                    Text("new task")
                        .font(WatchTheme.scaled(13, for: watchSize, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("dictate a prompt")
                        .font(WatchTheme.scaled(10, for: watchSize))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }

    private var micDiameter: CGFloat {
        switch watchSize {
        case .compact:  return 50
        case .regular:  return 56
        case .expanded: return 64
        }
    }
}

// MARK: - Reused chips

private struct StatusChip: View {
    @EnvironmentObject var theme: WatchThemeStore
    let status: WatchTask.Status
    var isAOD: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            bullet
            Text(label)
                .font(WatchTheme.mono(10, weight: .bold))
                .foregroundStyle(isAOD ? theme.textSecondary : color)
        }
    }

    @ViewBuilder private var bullet: some View {
        switch status {
        case .running:
            if isAOD {
                Circle().fill(theme.textSecondary).frame(width: 5, height: 5)
            } else {
                PulsingDot(color: theme.accent, size: 6)
            }
        case .needsApproval:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(isAOD ? theme.textSecondary : theme.warning)
        case .idle:
            Circle().fill(theme.textSecondary).frame(width: 5, height: 5)
        case .error:
            Circle().fill(isAOD ? theme.textSecondary : theme.danger).frame(width: 5, height: 5)
        }
    }

    private var label: String {
        switch status {
        case .running:       return "running"
        case .needsApproval: return "approval"
        case .idle:          return "idle"
        case .error:         return "error"
        }
    }

    private var color: Color {
        switch status {
        case .running:       return theme.accent
        case .needsApproval: return theme.warning
        case .idle:          return theme.textSecondary
        case .error:         return theme.danger
        }
    }
}

private struct HeaderBadges: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        HStack(spacing: 6) {
            if store.approvalsTaskCount > 0 {
                Badge(color: theme.warning, count: store.approvalsTaskCount)
            }
            if store.runningTaskCount > 0 {
                Badge(color: theme.success, count: store.runningTaskCount)
            }
        }
    }
}

private struct Badge: View {
    @EnvironmentObject var theme: WatchThemeStore
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(WatchTheme.mono(10))
                .foregroundStyle(theme.textSecondary)
        }
    }
}
