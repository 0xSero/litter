import SwiftUI

/// 1 · Task list — the watch's equivalent of the iPhone sessions screen.
/// Each row is a thread Codex is running (or has run) across any server.
/// Tap a row to see its live status and transcript.
struct HomeScreen: View {
    @EnvironmentObject var store: WatchAppStore

    var body: some View {
        Group {
            if !store.hasData {
                WatchEmptyState(
                    icon: "iphone.gen3",
                    title: store.isReachable ? "syncing…" : "open litter on iphone",
                    subtitle: store.isReachable ? nil : "the watch shows what the phone knows."
                )
            } else if store.tasks.isEmpty {
                WatchEmptyState(
                    icon: "sparkles",
                    title: "no tasks yet",
                    subtitle: "start a conversation on iphone."
                )
            } else {
                List {
                    if store.lastSyncIsStale && !store.isReachable {
                        Section {
                            HStack(spacing: 6) {
                                Image(systemName: "iphone.slash")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(WatchTheme.dim)
                                Text("phone unreachable · last-known")
                                    .font(WatchTheme.mono(9))
                                    .foregroundStyle(WatchTheme.dim)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }

                    Section {
                        ForEach(store.tasks) { task in
                            NavigationLink {
                                TaskDetailScreen(task: task)
                            } label: {
                                TaskRow(task: task)
                            }
                            .listItemTint(task.status == .running
                                          ? WatchTheme.ginger
                                          : WatchTheme.borderHi)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            WatchEyebrow(text: "tasks", size: 10)
                            Spacer()
                            HeaderBadges()
                        }
                    }

                    Section {
                        NavigationLink {
                            VoiceScreen()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(WatchTheme.ginger)
                                Text("new task")
                                    .font(WatchTheme.mono(12, weight: .bold))
                                    .foregroundStyle(WatchTheme.text)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .containerBackground(WatchTheme.bg.gradient, for: .navigation)
    }
}

private struct HeaderBadges: View {
    @EnvironmentObject var store: WatchAppStore

    var body: some View {
        HStack(spacing: 6) {
            if store.approvalsTaskCount > 0 {
                Badge(color: WatchTheme.ginger, count: store.approvalsTaskCount)
            }
            if store.runningTaskCount > 0 {
                Badge(color: WatchTheme.success, count: store.runningTaskCount)
            }
        }
    }
}

private struct Badge: View {
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(WatchTheme.mono(10))
                .foregroundStyle(WatchTheme.dim)
        }
    }
}

private struct TaskRow: View {
    let task: WatchTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusBullet(status: task.status)
                .frame(width: 10, height: 10)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(WatchTheme.mono(12, weight: .bold))
                    .foregroundStyle(WatchTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Text(task.serverName)
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(WatchTheme.dim)
                        .lineLimit(1)
                    if !task.relativeTime.isEmpty {
                        Text("·")
                            .font(WatchTheme.mono(9))
                            .foregroundStyle(WatchTheme.dimMore)
                        Text(task.relativeTime)
                            .font(WatchTheme.mono(9))
                            .foregroundStyle(WatchTheme.dim)
                    }
                }

                if let subtitle = task.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(WatchTheme.mono(10))
                        .foregroundStyle(subtitleColor(for: task.status))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitleColor(for status: WatchTask.Status) -> Color {
        switch status {
        case .running:       return WatchTheme.gingerLight
        case .needsApproval: return WatchTheme.ginger
        case .idle:          return WatchTheme.dim
        case .error:         return WatchTheme.danger
        }
    }
}

private struct StatusBullet: View {
    let status: WatchTask.Status

    var body: some View {
        switch status {
        case .running:
            PulsingDot(color: WatchTheme.ginger, size: 8)
        case .needsApproval:
            ZStack {
                Circle().fill(WatchTheme.ginger.opacity(0.25))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(WatchTheme.ginger)
            }
        case .idle:
            Circle().fill(WatchTheme.dim).frame(width: 6, height: 6)
        case .error:
            Circle().fill(WatchTheme.danger).frame(width: 6, height: 6)
        }
    }
}

#if DEBUG
#Preview("tasks") {
    NavigationStack {
        HomeScreen()
            .environmentObject(WatchAppStore.previewStore())
    }
}

#Preview("empty") {
    NavigationStack {
        HomeScreen()
            .environmentObject(WatchAppStore())
    }
}
#endif
