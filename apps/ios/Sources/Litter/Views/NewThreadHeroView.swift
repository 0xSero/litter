import SwiftUI

/// Centered "new thread" landing used as the detail pane when the user taps
/// "+" from the sidebar on regular-width surfaces.
///
/// Layout is intentionally simple — the composer lives in a flex VStack that
/// pushes it toward the vertical center pre-send and toward the bottom
/// post-send. Title, chips, and suggestions fade out on send so the eye
/// follows the composer's motion.
///
/// On iOS 26 the composer's background is already a liquid-glass pill
/// (courtesy of `ConversationComposerContentView`); when the layout
/// animates, iOS tracks the glass as it moves so no explicit
/// `GlassEffectContainer` is needed here.
struct NewThreadHeroView: View {
    let project: AppProject?
    let connectedServers: [HomeDashboardServer]
    let selectedServerId: String?
    var serverSnapshotsById: [String: AppServerSnapshot] = [:]
    let onSelectServer: (String) -> Void
    let onOpenProjectPicker: () -> Void
    let onThreadCreated: (ThreadKey) -> Void
    /// When nil, no Cancel button is shown (used for the split-view detail
    /// pane root where there's nothing to cancel back to).
    var onCancel: (() -> Void)? = nil
    /// When false, the composer doesn't steal focus on appear. Used when
    /// the hero is the ambient detail-pane root so popping back from a
    /// conversation doesn't rudely summon the keyboard.
    var autoFocus: Bool = true

    @State private var isSending = false

    /// Delay between the composer firing `onThreadCreated` and the parent
    /// replacing the route with `.conversation(key)`. Long enough for the
    /// spring to settle visually so the handoff doesn't feel cut short,
    /// short enough that the user isn't staring at an empty hero after
    /// their message goes out.
    private static let morphSettleSeconds: UInt64 = 360_000_000

    private var launchableServers: [HomeDashboardServer] {
        connectedServers.filter(\.canLaunchSessions)
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer(minLength: 0)

                if !isSending {
                    Text("What should we build in litter?")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(LitterTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HomeComposerView(
                    project: project,
                    transcriptionServerId: project?.serverId ?? selectedServerId,
                    onThreadCreated: { key in
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                            isSending = true
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: Self.morphSettleSeconds)
                            onThreadCreated(key)
                        }
                    },
                    autoFocus: autoFocus
                )
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)

                if !isSending {
                    chipRow
                        .transition(.opacity)

                    suggestionsList
                        .transition(.opacity)

                    Spacer(minLength: 0)
                } else {
                    Spacer()
                        .frame(height: 12)
                }
            }
            .padding(.vertical, 24)
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: isSending)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                // The trailing "Cancel" was the only way out of this screen,
                // and with an empty `navigationTitle` the system chevron is
                // near-invisible against the themed background — so the new
                // thread page read as a dead end (#305). Mirrors the
                // conversation screen's leading chevron.
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) {
                        Image(systemName: "chevron.left")
                            .font(LitterFont.styled(size: 17, weight: .semibold))
                            .foregroundColor(LitterTheme.textPrimary)
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(LitterTheme.textSecondary)
                }
            }
        }
    }

    // MARK: - Chips

    private var chipRow: some View {
        HStack(spacing: 8) {
            serverChip
            ProjectChip(
                project: project,
                disabled: launchableServers.isEmpty,
                onTap: onOpenProjectPicker
            )
            HomeModelChip(
                serverId: project?.serverId ?? selectedServerId,
                disabled: selectedLaunchableServer == nil,
                server: (project?.serverId ?? selectedServerId).flatMap { serverSnapshotsById[$0] }
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var serverChip: some View {
        let activeServerId = project?.serverId ?? selectedServerId
        let server = launchableServers.first { $0.id == activeServerId }
        Menu {
            if launchableServers.isEmpty {
                Text("No servers connected")
            } else {
                ForEach(launchableServers, id: \.id) { s in
                    Button(s.displayName) {
                        onSelectServer(s.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .semibold))
                Text(server?.displayName ?? "Server")
                    .litterMonoFont(size: 12, weight: .regular)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(server == nil ? LitterTheme.textMuted : LitterTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(LitterTheme.surfaceLight.opacity(0.6))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(LitterTheme.textMuted.opacity(0.2), lineWidth: 0.6)
            )
        }
        .disabled(launchableServers.isEmpty)
    }

    private var selectedLaunchableServer: HomeDashboardServer? {
        let activeServerId = project?.serverId ?? selectedServerId
        guard let activeServerId else { return nil }
        return launchableServers.first { $0.id == activeServerId }
    }

    // MARK: - Suggestions

    /// Placeholder suggestion rows. Data source TBD — for now these are
    /// static prompts so the layout can be dialed in. When the real source
    /// is wired, swap the array contents and make tapping prefill the
    /// composer with the row's text.
    private static let placeholderSuggestions: [String] = [
        "Make local iPhone command failures self-diagnosing",
        "Fix the real home feed item cap",
        "Fix subagent metadata across conversation rows",
        "Connect your favorite apps to Codex"
    ]

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.placeholderSuggestions.enumerated()), id: \.offset) { idx, text in
                if idx > 0 {
                    Divider()
                        .background(LitterTheme.textMuted.opacity(0.15))
                }
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(LitterTheme.textMuted)
                    Text(text)
                        .litterFont(size: 13)
                        .foregroundStyle(LitterTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
    }
}
