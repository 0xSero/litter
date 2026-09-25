import SwiftUI

struct ServerPillRow: View {
    let servers: [HomeDashboardServer]
    let selectedServerId: String?
    let onTap: (HomeDashboardServer) -> Void
    let onReconnect: (HomeDashboardServer) -> Void
    let onRestartAppServer: (HomeDashboardServer) -> Void
    let onRename: (HomeDashboardServer) -> Void
    let onRemove: (HomeDashboardServer) -> Void
    let onShowMountedFolders: (HomeDashboardServer) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(servers) { server in
                    ServerPill(
                        server: server,
                        isSelected: server.id == selectedServerId,
                        onTap: { onTap(server) },
                        onReconnect: { onReconnect(server) },
                        onRestartAppServer: { onRestartAppServer(server) },
                        onRename: { onRename(server) },
                        onRemove: { onRemove(server) },
                        onShowMountedFolders: { onShowMountedFolders(server) }
                    )
                }
                AddServerPill(onTap: onAdd)
            }
            .padding(.horizontal, LitterSpace.margin)
            .padding(.vertical, LitterSpace.xs)
        }
    }
}
