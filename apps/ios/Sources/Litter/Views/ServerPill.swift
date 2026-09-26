import SwiftUI

struct ServerPill: View {
    let server: HomeDashboardServer
    let isSelected: Bool
    let onTap: () -> Void
    let onReconnect: () -> Void
    let onRestartAppServer: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    let onShowMountedFolders: () -> Void

    /// Healthy servers show only their name. A server that needs attention
    /// (or is still connecting) adds one mono word.
    private var problemWord: (String, Color)? {
        server.connectionWord.map { ($0.text, $0.color) }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(server.displayName)
                    .litterMonoFont(size: 13, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? LitterTheme.textPrimary : LitterTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let problemWord {
                    Text(problemWord.0)
                        .litterMonoFont(size: 13)
                        .foregroundStyle(problemWord.1)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, LitterSpace.m)
            .frame(minHeight: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(RaisedCapsuleModifier())
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button {
                onReconnect()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            Button {
                onRestartAppServer()
            } label: {
                Label("Restart app server", systemImage: "arrow.triangle.2.circlepath")
            }
            if server.isLocal {
                Button {
                    onShowMountedFolders()
                } label: {
                    Label("Mounted folders", systemImage: "externaldrive.badge.icloud")
                }
            }
            if !server.isLocal {
                Button {
                    onRename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

extension ServerPill {
    fileprivate var accessibilityText: String {
        var parts = [server.displayName]
        if let problemWord { parts.append(problemWord.0) }
        let agents = server.agentRuntimes.filter(\.available).map(\.displayName)
        if !agents.isEmpty { parts.append(agents.joined(separator: ", ")) }
        return parts.joined(separator: ", ")
    }
}

struct AddServerPill: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("server")
                    .litterMonoFont(size: 13)
            }
            .foregroundStyle(LitterTheme.textPrimary)
            .padding(.horizontal, LitterSpace.m)
            .frame(minHeight: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(RaisedCapsuleModifier())
        .accessibilityLabel("Add server")
        .coachmarkAnchor(.addServer)
    }
}
