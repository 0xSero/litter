import SwiftUI

/// Transcript for the currently-focused task. Each task carries its own
/// transcript inline (see `WatchTask.transcript`), so this always reflects
/// the task the user drilled into — no round-trip to the phone.
struct TranscriptScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        let task = store.focusedTask
        let turns = task?.transcript ?? []

        Group {
            if turns.isEmpty {
                WatchEmptyState(
                    icon: "text.bubble",
                    title: "no recent turns",
                    subtitle: task.map { "\($0.title) has no recent turns." }
                        ?? "start a conversation on iphone."
                )
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let task {
                            HStack(spacing: 6) {
                                WatchEyebrow(text: task.serverName, size: 9)
                                Spacer()
                                if !task.relativeTime.isEmpty {
                                    Text(task.relativeTime)
                                        .font(WatchTheme.mono(9))
                                        .foregroundStyle(theme.textMuted)
                                }
                            }
                            .padding(.horizontal, 4)
                        }

                        ForEach(turns) { turn in
                            TranscriptBubble(turn: turn)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                NavigationLink { VoiceScreen() } label: {
                    Label("reply", systemImage: "mic.fill")
                        .font(WatchTheme.mono(11, weight: .bold))
                }
                .tint(theme.accent)
            }
        }
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }
}

private struct TranscriptBubble: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    let turn: WatchTranscriptTurn

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            switch turn.role {
            case .user:
                Spacer(minLength: 20)
                Text(turn.text)
                    .font(WatchTheme.scaled(11, for: watchSize))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 12
                        )
                        .fill(WatchTheme.userBubble)
                    )
                    .opacity(turn.faded ? 0.5 : 1)

            case .system:
                Text(turn.text)
                    .font(WatchTheme.scaled(10, for: watchSize))
                    .foregroundStyle(theme.textSecondary)
                    .italic()
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: 2)
                    }
                Spacer(minLength: 0)

            case .assistant:
                Text(turn.text)
                    .font(WatchTheme.scaled(11, for: watchSize))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 0)
            }
        }
    }
}
