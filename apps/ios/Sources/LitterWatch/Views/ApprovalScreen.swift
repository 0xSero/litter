import SwiftUI
import WatchKit

/// 3 · Approve — real pending approval from the phone. Deny on the left,
/// allow on the right. `handGestureShortcut(.primaryAction)` maps the
/// watchOS 11 double-tap gesture to "allow".
struct ApprovalScreen: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore

    var body: some View {
        Group {
            if let approval = store.pendingApproval {
                ApprovalBody(approval: approval)
            } else {
                WatchEmptyState(
                    icon: "checkmark.shield",
                    title: "no pending approvals",
                    subtitle: "codex will ping you when it needs a yes/no."
                )
            }
        }
        .containerBackground(theme.backgroundGradient, for: .navigation)
    }
}

private struct ApprovalBody: View {
    @EnvironmentObject var store: WatchAppStore
    @EnvironmentObject var theme: WatchThemeStore
    @Environment(\.watchSize) private var watchSize
    let approval: WatchApproval

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.warning)
                    WatchEyebrow(text: approvalLabel, size: 9)
                }

                Text(approval.command)
                    .font(WatchTheme.scaled(14, for: watchSize, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !approval.target.isEmpty {
                    Text(approval.target)
                        .font(WatchTheme.mono(10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                if !approval.diffSummary.isEmpty {
                    Text(approval.diffSummary)
                        .font(WatchTheme.mono(10))
                        .foregroundStyle(theme.successSoft)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.border, lineWidth: 1)
                                )
                        )
                }

                HStack(spacing: 4) {
                    Button { tap(approve: false) } label: {
                        Text("deny")
                            .font(WatchTheme.scaled(12, for: watchSize, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: approvalButtonHeight)
                            .background(
                                Capsule().fill(theme.surfaceLight)
                                    .overlay(Capsule().stroke(theme.borderHi, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.approvalInFlight)

                    Button { tap(approve: true) } label: {
                        Text(store.approvalInFlight ? "sending…" : "allow")
                            .font(WatchTheme.scaled(12, for: watchSize, weight: .bold))
                            .foregroundStyle(theme.textOnAccent)
                            .frame(maxWidth: .infinity, minHeight: approvalButtonHeight)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [theme.accent, theme.accentStrong],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .shadow(color: theme.accent.opacity(0.5), radius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1.3)
                    .handGestureShortcut(.primaryAction)
                    .disabled(store.approvalInFlight)
                }
                .padding(.top, 4)

                if let error = store.approvalError {
                    Text(error)
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                        .onAppear {
                            WKInterfaceDevice.current().play(.notification)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                if store.approvalError == error {
                                    store.approvalError = nil
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private func tap(approve: Bool) {
        WKInterfaceDevice.current().play(approve ? .success : .failure)
        store.respond(approve: approve)
    }

    private var approvalButtonHeight: CGFloat {
        switch watchSize {
        case .compact:  return 30
        case .regular:  return 34
        case .expanded: return 38
        }
    }

    private var approvalLabel: String {
        switch approval.kind {
        case .command:        return "run command"
        case .fileChange:     return "file change"
        case .permissions:    return "permissions"
        case .mcpElicitation: return "mcp input"
        }
    }
}
