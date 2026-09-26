import SwiftUI

/// Which thread (nil = the next new thread) and runtime the composer's
/// permission chip edits. Set by the home and conversation composers.
struct ComposerPermissionContext: Equatable {
    var threadKey: ThreadKey?
    var runtime: AgentRuntimeKind?
}

private struct ComposerPermissionContextKey: EnvironmentKey {
    static let defaultValue: ComposerPermissionContext? = nil
}

extension EnvironmentValues {
    var composerPermissionContext: ComposerPermissionContext? {
        get { self[ComposerPermissionContextKey.self] }
        set { self[ComposerPermissionContextKey.self] = newValue }
    }
}

/// One permission level, named the way each harness names it. All levels map
/// onto the approval + sandbox pair the bridges already translate into the
/// harness's native flag (Claude `--permission-mode`, Droid `--auto`, …).
struct ComposerPermissionLevel: Identifiable, Equatable {
    enum Kind { case readOnly, auto, fullAccess }
    let kind: Kind
    let title: String
    let subtitle: String

    var id: Kind { kind }
    var approvalPolicy: String {
        switch kind {
        case .readOnly: return "untrusted"
        case .auto: return "on-request"
        case .fullAccess: return "never"
        }
    }
    var sandboxMode: String {
        switch kind {
        case .readOnly: return "read-only"
        case .auto: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }
    var isDanger: Bool { kind == .fullAccess }

    static func levels(for runtime: AgentRuntimeKind?) -> [ComposerPermissionLevel] {
        switch runtime ?? "codex" {
        case "claude":
            return [
                .init(kind: .readOnly, title: "Default", subtitle: "Ask before edits and commands"),
                .init(kind: .auto, title: "Accept edits", subtitle: "Edit files, ask before commands"),
                .init(kind: .fullAccess, title: "Bypass permissions", subtitle: "--dangerously-skip-permissions"),
            ]
        case "droid":
            return [
                .init(kind: .readOnly, title: "Auto low", subtitle: "Read-only and safe commands"),
                .init(kind: .auto, title: "Auto medium", subtitle: "Edits and reversible commands"),
                .init(kind: .fullAccess, title: "Auto high", subtitle: "Everything, no prompts"),
            ]
        case "amp":
            return [
                .init(kind: .readOnly, title: "Ask", subtitle: "Ask before tools run"),
                .init(kind: .auto, title: "Auto", subtitle: "Workspace edits allowed"),
                .init(kind: .fullAccess, title: "Allow all", subtitle: "--dangerously-allow-all"),
            ]
        case "codex":
            return [
                .init(kind: .readOnly, title: "Read only", subtitle: "Can read files, asks to edit"),
                .init(kind: .auto, title: "Auto", subtitle: "Edits in this workspace"),
                .init(kind: .fullAccess, title: "Full access", subtitle: "No sandbox, no prompts"),
            ]
        default:
            return [
                .init(kind: .readOnly, title: "Ask", subtitle: "Ask before edits and commands"),
                .init(kind: .auto, title: "Auto", subtitle: "Edits in this workspace"),
                .init(kind: .fullAccess, title: "YOLO", subtitle: "Everything, no prompts"),
            ]
        }
    }
}

/// ChatGPT/Codex-app style permission chip for the composer's bottom row:
/// the current level as text, orange when it bypasses approvals.
struct ComposerPermissionChip: View {
    let context: ComposerPermissionContext
    var onOpenModePicker: (() -> Void)? = nil
    @Environment(AppState.self) private var appState

    private var levels: [ComposerPermissionLevel] {
        ComposerPermissionLevel.levels(for: context.runtime)
    }

    private var fixedFullAccess: Bool {
        context.runtime.map { AgentRuntimeKind.hasFixedFullAccess($0) } ?? false
    }

    private var current: ComposerPermissionLevel {
        if fixedFullAccess { return levels[2] }
        let preset = threadPermissionPreset(
            approvalPolicy: appState.launchApprovalPolicy(for: context.threadKey),
            sandboxPolicy: appState.turnSandboxPolicy(for: context.threadKey)
        )
        if preset == .fullAccess { return levels[2] }
        let sandbox = appState.turnSandboxPolicy(for: context.threadKey)
        if case .readOnly = sandbox { return levels[0] }
        return levels[1]
    }

    var body: some View {
        let current = current
        Menu {
            if fixedFullAccess {
                Text("This agent always runs with full access")
            } else {
                ForEach(levels) { level in
                    Button {
                        appState.setPermissions(
                            approvalPolicy: level.approvalPolicy,
                            sandboxMode: level.sandboxMode,
                            for: context.threadKey
                        )
                    } label: {
                        if level == current {
                            Label(level.title, systemImage: "checkmark")
                        } else {
                            Text(level.title)
                        }
                        Text(level.subtitle)
                    }
                }
            }
            if let onOpenModePicker {
                Divider()
                Button(action: onOpenModePicker) {
                    Label("Collaboration mode…", systemImage: "list.bullet.clipboard")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current.isDanger ? "exclamationmark.shield" : "lock.shield")
                    .font(.system(size: 13, weight: .medium))
                Text(current.title)
                    .font(.system(size: 14, weight: .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(current.isDanger ? LitterTheme.warning : LitterTheme.textSecondary)
            .padding(.horizontal, LitterSpace.xs)
            .frame(minHeight: LitterSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .fixedSize()
        .layoutPriority(2)
        .accessibilityLabel("Permissions: \(current.title)")
        .accessibilityIdentifier("composer.permissionChip")
    }
}
