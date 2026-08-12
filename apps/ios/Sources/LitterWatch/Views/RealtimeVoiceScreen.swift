import SwiftUI
import WatchKit

/// 2 · Realtime voice — controls the iPhone's realtime voice session and
/// renders live transcript + audio level. Falls back to text dictation
/// (`VoiceScreen`) via a secondary action.
struct RealtimeVoiceScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        Group {
            if let voice = store.voice {
                ActiveBody(voice: voice)
            } else {
                IdleBody()
            }
        }
        .containerBackground(
            RadialGradient(
                colors: [theme.accent.opacity(0.18), theme.backgroundBottom],
                center: .init(x: 0.5, y: 0.7),
                startRadius: 6, endRadius: 200
            ),
            for: .navigation
        )
    }
}

// MARK: - Active

private struct ActiveBody: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore
    let voice: WatchVoiceState

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                header

                MicRing(
                    audioLevel: voice.audioLevel,
                    isMuted: voice.isMuted,
                    mode: voice.mode
                ) {
                    WatchSessionBridge.shared.sendVoiceToggleMute()
                    WKInterfaceDevice.current().play(.click)
                }
                .handGestureShortcut(.primaryAction)

                turns

                controls
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            WatchEyebrow(text: eyebrow, size: 9)
            Spacer(minLength: 0)
            StatusPill(mode: voice.mode)
        }
    }

    private var eyebrow: String {
        if let serverName = store.tasks.first(where: {
            $0.serverId == voice.serverId
        })?.serverName {
            return "voice · \(serverName)"
        }
        return voice.serverId.map { "voice · \($0)" } ?? "voice"
    }

    private var turns: some View {
        let recent = Array(voice.recentTurns.suffix(3))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(recent) { turn in
                VoiceTurnRow(turn: turn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 6) {
            Button {
                WKInterfaceDevice.current().play(.failure)
                WatchSessionBridge.shared.sendVoiceStop()
            } label: {
                Text("stop")
                    .font(WatchTheme.mono(11, weight: .bold))
                    .foregroundStyle(theme.danger)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        Capsule().fill(theme.surfaceLight)
                            .overlay(Capsule().stroke(theme.danger.opacity(0.4), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)

            NavigationLink {
                VoiceScreen()
            } label: {
                Label("type instead", systemImage: "keyboard")
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }
}

private struct VoiceTurnRow: View {
    @EnvironmentObject var theme: WatchThemeStore
    let turn: WatchTranscriptTurn

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            switch turn.role {
            case .user:
                Spacer(minLength: 16)
                Text(turn.text)
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10,
                            bottomLeadingRadius: 10,
                            bottomTrailingRadius: 4,
                            topTrailingRadius: 10
                        )
                        .fill(WatchTheme.userBubble)
                    )
                    .opacity(turn.faded ? 0.55 : 1)
            case .assistant:
                Text(turn.text)
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(theme.textPrimary)
                    .opacity(turn.faded ? 0.6 : 1)
                Spacer(minLength: 0)
            case .system:
                Text(turn.text)
                    .font(WatchTheme.mono(9))
                    .foregroundStyle(theme.textSecondary)
                    .italic()
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Mic ring

private struct MicRing: View {
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    let audioLevel: Double
    let isMuted: Bool
    let mode: WatchVoiceState.Mode
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(theme.accent.opacity(0.35), lineWidth: 2)
                    .frame(width: outerDiameter, height: outerDiameter)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.18), value: scale)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: ringColors,
                            center: .init(x: 0.35, y: 0.3),
                            startRadius: 2,
                            endRadius: 50
                        )
                    )
                    .frame(width: innerDiameter, height: innerDiameter)
                    .shadow(color: theme.accent.opacity(isMuted ? 0.0 : 0.45), radius: 12)
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 30 * watchSize.fontScale, weight: .heavy))
                    .foregroundStyle(theme.textOnAccent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }

    private var outerDiameter: CGFloat { 96 * watchSize.fontScale }
    private var innerDiameter: CGFloat { 80 * watchSize.fontScale }

    private var scale: CGFloat {
        let clamped = max(0, min(1, audioLevel))
        return 1.0 + 0.3 * CGFloat(clamped)
    }

    private var ringColors: [Color] {
        if isMuted {
            return [theme.textSecondary, theme.surfaceLight]
        }
        switch mode {
        case .listening, .idle:
            return [theme.accentSoft, theme.accent, theme.accentStrong]
        case .speaking:
            return [theme.success, theme.successSoft, theme.accentStrong]
        case .thinking:
            return [theme.accentSoft, theme.accentStrong, theme.surfaceLight]
        case .error:
            return [theme.danger, theme.accentStrong, theme.backgroundBottom]
        }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    @EnvironmentObject var theme: WatchThemeStore
    let mode: WatchVoiceState.Mode

    var body: some View {
        Text(label)
            .font(WatchTheme.mono(9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.18))
                    .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
            )
    }

    private var label: String {
        switch mode {
        case .idle:      return "idle"
        case .listening: return "listening"
        case .speaking:  return "speaking"
        case .thinking:  return "thinking"
        case .error:     return "error"
        }
    }

    private var color: Color {
        switch mode {
        case .idle:      return theme.textSecondary
        case .listening: return theme.accent
        case .speaking:  return theme.success
        case .thinking:  return theme.warning
        case .error:     return theme.danger
        }
    }
}

// MARK: - Idle

private struct IdleBody: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        VStack(spacing: 10) {
            WatchEmptyState(
                icon: "waveform",
                title: "voice off",
                subtitle: store.focusedTask.map { "tap to start on \($0.serverName)." }
                    ?? "focus a task to start voice."
            )

            if let task = store.focusedTask {
                Button {
                    WKInterfaceDevice.current().play(.start)
                    WatchSessionBridge.shared.sendVoiceStart(
                        serverId: task.serverId,
                        threadId: task.threadId
                    )
                } label: {
                    Label("start voice", systemImage: "mic.fill")
                        .font(WatchTheme.mono(12, weight: .bold))
                        .foregroundStyle(theme.textOnAccent)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }

            NavigationLink {
                VoiceScreen()
            } label: {
                Label("type instead", systemImage: "keyboard")
                    .font(WatchTheme.mono(10))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
#Preview("active") {
    NavigationStack {
        RealtimeVoiceScreen()
            .environmentObject(WatchAppStore.previewStore())
            .environmentObject(WatchThemeStore.shared)
    }
}

#Preview("idle") {
    NavigationStack {
        RealtimeVoiceScreen()
            .environmentObject({
                let s = WatchAppStore()
                s.tasks = WatchPreviewFixtures.tasks
                s.focusedTaskId = WatchPreviewFixtures.tasks.first?.id
                s.lastSyncDate = .now
                return s
            }())
            .environmentObject(WatchThemeStore.shared)
    }
}
#endif
