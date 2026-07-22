import SwiftUI

struct SSHBridgeAgentContext: Identifiable {
    let id: String
    let server: DiscoveredServer
    let sessionId: String
    let host: String
    let availability: [RemoteAgentAvailability]
    let credentials: SSHCredentials

    init(
        server: DiscoveredServer,
        sessionId: String,
        host: String,
        availability: [RemoteAgentAvailability],
        credentials: SSHCredentials
    ) {
        self.id = sessionId
        self.server = server
        self.sessionId = sessionId
        self.host = host
        self.availability = availability
        self.credentials = credentials
    }
}

struct SSHBridgeAgentResult {
    let serverId: String
    let displayName: String
    let host: String
    let port: UInt16
    let sessionId: String
    let runtimeKinds: [AgentRuntimeKind]
}

struct SSHAgentPickerSheet: View {
    let context: SSHBridgeAgentContext
    let appModel: AppModel
    let onConnected: (SSHBridgeAgentResult) -> Void
    let onUseCodex: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKinds: Set<AgentRuntimeKind>
    @State private var isConnecting = false
    @State private var connectError: String?

    init(
        context: SSHBridgeAgentContext,
        appModel: AppModel,
        onConnected: @escaping (SSHBridgeAgentResult) -> Void,
        onUseCodex: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.context = context
        self.appModel = appModel
        self.onConnected = onConnected
        self.onUseCodex = onUseCodex
        self.onCancel = onCancel
        _selectedKinds = State(initialValue: Set(
            Self.defaultBridgeKinds(in: context.availability)
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    hostSection
                    agentSection
                    connectSection
                    if let connectError {
                        Section {
                            Text(connectError)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.danger)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Remote Agents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                    .foregroundColor(LitterTheme.accent)
                    .disabled(isConnecting)
                }
            }
        }
    }

    private var hostSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .foregroundColor(LitterTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.server.name)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(context.host)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var agentSection: some View {
        Section {
            ForEach(context.availability, id: \.kind) { agent in
                Button {
                    guard isBridgeKind(agent.kind), agent.status == .available else { return }
                    if selectedKinds.contains(agent.kind) {
                        selectedKinds.remove(agent.kind)
                    } else {
                        if agent.kind == "local-studio" { selectedKinds.remove("pi") }
                        if agent.kind == "pi" { selectedKinds.remove("local-studio") }
                        selectedKinds.insert(agent.kind)
                    }
                } label: {
                    HStack(spacing: 10) {
                        AgentIconView(kind: agent.kind, size: 22)
                            .opacity(agent.status == .available ? 1 : 0.45)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(runtimeDisplayName(agent.kind))
                                    .litterFont(.subheadline)
                                    .foregroundColor(agent.status == .available ? LitterTheme.textPrimary : LitterTheme.textMuted)
                                if agent.kind.isBeta {
                                    BetaBadge()
                                }
                            }
                            Text(statusLabel(agent.status, kind: agent.kind))
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if selectedKinds.contains(agent.kind) {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundColor(LitterTheme.accent)
                        } else if isBridgeKind(agent.kind), agent.status == .available {
                            Image(systemName: "square")
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                }
                .disabled(!isBridgeKind(agent.kind) || agent.status != .available || isConnecting)
            }
        } header: {
            HStack {
                Text("Agents")
                Spacer()
                if !availableBridgeKinds.isEmpty {
                    Button(selectedKinds.count == availableBridgeKinds.count ? "None" : "All") {
                        if selectedKinds.count == availableBridgeKinds.count {
                            selectedKinds = []
                        } else {
                            selectedKinds = Set(availableBridgeKinds)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .disabled(isConnecting)
                }
            }
            .foregroundColor(LitterTheme.textSecondary)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var connectSection: some View {
        Section {
            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView().tint(LitterTheme.accent)
                    }
                    Text("Connect")
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                }
            }
            .disabled(isConnecting || selectedKinds.isEmpty)

            Button("Use Codex SSH") {
                onUseCodex()
                dismiss()
            }
            .litterFont(.footnote)
            .foregroundColor(LitterTheme.textSecondary)
            .disabled(isConnecting)
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    private var availableBridgeKinds: [AgentRuntimeKind] {
        Self.availableBridgeKinds(in: context.availability)
    }

    private func connect() {
        isConnecting = true
        connectError = nil
        let runtimeKinds = Array(selectedKinds).sorted { runtimeSortRank($0) < runtimeSortRank($1) }
        Task {
            do {
                let result = try await appModel.ssh.sshConnectBridgeSession(
                    sessionId: context.sessionId,
                    serverId: "ssh-bridge:\(context.host)",
                    displayName: context.server.name,
                    host: context.host,
                    stateRoot: try sshBridgeStateRoot(host: context.host),
                    runtimeKinds: runtimeKinds,
                    transport: .ephemeral
                )
                isConnecting = false
                onConnected(SSHBridgeAgentResult(
                    serverId: result.serverId,
                    displayName: context.server.name,
                    host: context.host,
                    port: context.server.resolvedSSHPort,
                    sessionId: context.sessionId,
                    runtimeKinds: runtimeKinds
                ))
                dismiss()
            } catch {
                isConnecting = false
                connectError = error.localizedDescription
            }
        }
    }

    private static func availableBridgeKinds(in availability: [RemoteAgentAvailability]) -> [AgentRuntimeKind] {
        availability
            .filter { isBridgeKind($0.kind) && $0.status == .available }
            .map(\.kind)
            .sorted { runtimeSortRank($0) < runtimeSortRank($1) }
    }

    private static func defaultBridgeKinds(in availability: [RemoteAgentAvailability]) -> Set<AgentRuntimeKind> {
        let available = availableBridgeKinds(in: availability)
        return Set(available.filter { kind in
            !kind.isBeta && !(kind == "pi" && available.contains("local-studio"))
        })
    }
}

private func isBridgeKind(_ kind: AgentRuntimeKind) -> Bool {
    // Prefer the capability flag from alleycat metadata; fall back to
    // the legacy SSH-bridge-supported allowlist when metadata isn't
    // cached yet (cold start).
    if let supports = kind.metadata?.capabilities?.supportsSshBridge {
        return supports
    }
    switch kind {
    case "codex", "claude", "pi", "opencode", "local-studio":
        return true
    default:
        return false
    }
}

private func runtimeDisplayName(_ kind: AgentRuntimeKind) -> String {
    kind.displayLabel
}

private func runtimeSortRank(_ kind: AgentRuntimeKind) -> Int {
    // SSH-bridge picker keeps its own historical ordering distinct
    // from the general presentation order: Claude leads because it's
    // the most common SSH-bootstrap target.
    switch kind {
    case "claude": return 0
    case "local-studio": return 1
    case "pi": return 2
    case "opencode": return 3
    case "codex": return 4
    case "amp": return 5
    case "droid": return 6
    case "hermes": return 7
    default: return Int.max
    }
}

private func statusLabel(_ status: AgentAvailabilityStatus, kind: AgentRuntimeKind) -> String {
    switch status {
    case .available:
        return "Available"
    case .agentCliMissing:
        return "CLI missing"
    case .windowsNotYetSupported:
        return "Windows not supported"
    }
}

private func sshBridgeStateRoot(host: String) throws -> String {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let safeHost = host
        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "host"
    let dir = base
        .appendingPathComponent("alleycat-bridges", isDirectory: true)
        .appendingPathComponent(safeHost, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}
