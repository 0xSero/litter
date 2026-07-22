import SwiftUI

/// Compact controller surface backed by Local Studio's signed Alleycat bridge.
/// Conversation, tools, models, and files continue to use Litter's existing Pi runtime views.
struct LocalStudioControllerDashboard: View {
    let serverId: String

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: LocalStudioControllerSnapshot?
    @State private var sessions: [LocalStudioSessionDescriptor] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if loading && snapshot == nil {
                        ProgressView("Connecting to Local Studio")
                            .tint(LitterTheme.accent)
                    }
                    if let error {
                        Text(error)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.warning)
                    }
                    if let snapshot {
                        card("Controller") {
                            row("Name", snapshot.displayName)
                            row("State", String(describing: snapshot.state))
                            row("Revision", String(snapshot.revision))
                            if let status = snapshot.sections.status.value {
                                row("Runtime", status.running ? "Running" : "Stopped")
                                row("Models", status.activeModelIds.isEmpty ? "None running" : status.activeModelIds.joined(separator: ", "))
                            }
                        }
                        if let gpu = snapshot.sections.gpus.value {
                            card("GPUs") {
                                row("Devices", String(gpu.devices.count))
                                ForEach(Array(gpu.devices.enumerated()), id: \.offset) { _, device in
                                    let utilization = device.utilizationPercent.map { "\(Int($0))%" } ?? "Not reported"
                                    let memory = device.memoryUsedBytes.map { "\($0 / 1_048_576) MB" } ?? "Not reported"
                                    row(device.name, "\(utilization) · \(memory)")
                                }
                            }
                        }
                    }
                    if !sessions.isEmpty {
                        card("Pi sessions") {
                            ForEach(sessions, id: \.session.sessionId) { session in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.metadata.title ?? "Untitled session")
                                        .litterFont(.footnote)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    Text(session.metadata.modelId ?? session.metadata.cwd ?? "Local Studio")
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textMuted)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Local Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Refresh") { Task { await refresh() } } }
            }
            .task { await refresh() }
        }
    }

    @ViewBuilder
    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).litterFont(.headline).foregroundColor(LitterTheme.accent)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitterTheme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundColor(LitterTheme.textMuted)
            Spacer()
            Text(value).foregroundColor(LitterTheme.textPrimary).multilineTextAlignment(.trailing)
        }
        .litterFont(.caption)
    }

    @MainActor
    private func refresh() async {
        loading = true
        error = nil
        do {
            switch try await appModel.client.loadLocalStudioController(serverId: serverId) {
            case .loaded(_, let value): snapshot = value
            case .error(let result): error = result.error.message
            }
            switch try await appModel.client.listLocalStudioSessions(serverId: serverId, limit: 20) {
            case .page(let page): sessions = page.sessions
            case .error(let result): error = result.error.message
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
