import SwiftUI
import WatchKit

/// Lists threads the user has hidden from home. Each row exposes an Unhide
/// action that round-trips back to the phone via
/// `WatchSessionBridge.shared.sendHomeUnhide(...)`. When the iPhone applies
/// the unhide, the next snapshot push drops the row from this list.
struct HiddenThreadsScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize

    var body: some View {
        Group {
            if store.hiddenTasks.isEmpty {
                WatchEmptyState(
                    icon: "eye",
                    title: "nothing hidden",
                    subtitle: "swipe a task on home to hide it."
                )
            } else {
                List {
                    Section {
                        ForEach(store.hiddenTasks) { task in
                            HiddenRow(task: task)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            WatchEyebrow(text: "hidden", color: theme.textSecondary, size: 10)
                            Spacer()
                            Text("\(store.hiddenTasks.count)")
                                .font(WatchTheme.scaled(10, for: watchSize))
                                .foregroundStyle(theme.textMuted)
                        }
                    }
                }
                .listStyle(.carousel)
            }
        }
        .navigationTitle("hidden")
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }
}

private struct HiddenRow: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    let task: WatchTask

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(WatchTheme.scaled(12, for: watchSize, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(task.serverName)
                        .foregroundStyle(theme.accent.opacity(0.7))
                    if !task.relativeTime.isEmpty {
                        Text("·").foregroundStyle(theme.textMuted.opacity(0.6))
                        Text(task.relativeTime)
                            .foregroundStyle(theme.textMuted)
                    }
                }
                .font(WatchTheme.scaled(10, for: watchSize))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                WKInterfaceDevice.current().play(.click)
                WatchSessionBridge.shared.sendHomeUnhide(
                    serverId: task.serverId,
                    threadId: task.threadId
                )
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textOnAccent)
                    .frame(width: 36, height: 28)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [theme.accentSoft, theme.accent],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unhide task")
        }
        .padding(.vertical, 2)
    }
}
