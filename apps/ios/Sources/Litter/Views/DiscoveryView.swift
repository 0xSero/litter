import SwiftUI
import Network

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @Environment(AppModel.self) private var appModel
    @State private var discovery: NetworkDiscovery
    @State private var sshServer: DiscoveredServer?
    @State private var connectionChoiceServer: DiscoveredServer?
    @State private var pendingSSHServer: DiscoveredServer?
    @State private var sshAgentContext: SSHBridgeAgentContext?
    @State private var showManualEntry = false
    @State private var showAlleycatSheet = false
    @State private var manualConnectionMode: ManualConnectionMode = .ssh
    @State private var manualCodexURL = ""
    @State private var manualHost = ""
    @State private var manualSSHPort = "22"
    @State private var manualWakeMAC = ""
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var wakingServer: DiscoveredServer?
    @State private var pendingAutoNavigateServerId: String?
    @State private var pendingAutoNavigateServer: DiscoveredServer?
    @State private var connectError: String?
    @State private var renameTarget: DiscoveredServer?
    @State private var renameText = ""
    @Environment(AppState.self) private var appState
    private let autoStartDiscovery: Bool
    private let initialServers: [DiscoveredServer]

    init(
        onServerSelected: ((DiscoveredServer) -> Void)? = nil,
        discovery: NetworkDiscovery? = nil,
        autoStartDiscovery: Bool = true,
        initialServers: [DiscoveredServer] = []
    ) {
        self.onServerSelected = onServerSelected
        _discovery = State(initialValue: discovery ?? NetworkDiscovery())
        self.autoStartDiscovery = autoStartDiscovery
        self.initialServers = initialServers
    }

    private var localServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source == .local }
    }

    private var networkServers: [DiscoveredServer] {
        discovery.servers.filter { $0.source != .local }
    }

    private func applyInitialServersIfNeeded() {
        guard !initialServers.isEmpty, discovery.servers.isEmpty else { return }
        discovery.servers = initialServers
        discovery.isScanning = false
    }

    private func refreshDiscovery() {
        guard autoStartDiscovery else {
            applyInitialServersIfNeeded()
            return
        }
        discovery.startScanning()
    }

    private func handleAppear() {
        guard autoStartDiscovery else { return }
        maybeStartSimulatorAutoSSH()
    }

    private func handleDisappear() {}

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            chooserContent
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandLogo(size: 44)
            }
        }
        .onAppear { handleAppear() }
        .onDisappear { handleDisappear() }
        .sheet(item: $sshServer) { server in
            SSHLoginSheet(server: server) { target in
                sshServer = nil
                if case .sshThenRemote(let host, let credentials) = target {
                    Task { await startSSHAgentProbe(server: server, host: host, credentials: credentials) }
                } else {
                    Task { await connectToServer(server, targetOverride: target) }
                }
            }
        }
        .sheet(item: $sshAgentContext) { context in
            SSHAgentPickerSheet(
                context: context,
                appModel: appModel,
                onConnected: { result in
                    sshAgentContext = nil
                    Task { await connectSSHBridgeTarget(result, baseServer: context.server) }
                },
                onUseCodex: {
                    sshAgentContext = nil
                    Task {
                        try? await appModel.ssh.sshClose(sessionId: context.sessionId)
                        await connectToServer(
                            context.server,
                            targetOverride: .sshThenRemote(host: context.host, credentials: context.credentials)
                        )
                    }
                },
                onCancel: {
                    sshAgentContext = nil
                    Task { try? await appModel.ssh.sshClose(sessionId: context.sessionId) }
                }
            )
        }
        .confirmationDialog(
            connectionChoiceServer.map { "Connect to \($0.name)" } ?? "Choose Connection",
            isPresented: connectionChoicePresented,
            titleVisibility: .visible
        ) {
            if let server = connectionChoiceServer {
                ForEach(server.availableDirectCodexPorts, id: \.self) { port in
                    Button("Use Codex (\(port))") {
                        let preferredServer = server.withConnectionPreference(.directCodex, codexPort: port)
                        connectionChoiceServer = nil
                        Task { await connectToServer(preferredServer) }
                    }
                }
                if server.canConnectViaSSH {
                    Button("Connect via SSH") {
                        let preferredServer = server.withConnectionPreference(.ssh)
                        connectionChoiceServer = nil
                        sshServer = preferredServer
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                connectionChoiceServer = nil
            }
        } message: {
            if let server = connectionChoiceServer {
                Text(connectionChoiceMessage(for: server))
            }
        }
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
        .sheet(isPresented: $showAlleycatSheet) {
            AlleycatAddServerSheet(appModel: appModel, startScanningOnAppear: true) { result in
                showAlleycatSheet = false
                Task { await connectAlleycatTarget(result) }
            }
        }
        .onChange(of: showManualEntry) { _, isPresented in
            guard !isPresented, let pendingSSHServer else { return }
            self.pendingSSHServer = nil
            self.sshServer = pendingSSHServer
        }
        .onChange(of: appModel.snapshot) { _, _ in
            guard let pendingAutoNavigateServerId else { return }
            guard let serverSnapshot = appModel.snapshot?.serverSnapshot(for: pendingAutoNavigateServerId) else {
                return
            }
            if serverSnapshot.health == .connected {
                self.pendingAutoNavigateServerId = nil
                if let server = pendingAutoNavigateServer
                    ?? discovery.servers.first(where: { $0.id == pendingAutoNavigateServerId }) {
                    self.pendingAutoNavigateServer = nil
                    navigateAfterConnect(server)
                }
            } else if serverSnapshot.health == .disconnected,
                      let message = serverSnapshot.connectionProgress?.terminalMessage {
                self.pendingAutoNavigateServerId = nil
                self.pendingAutoNavigateServer = nil
                connectError = message
            }
        }
        .alert("Connection Failed", isPresented: showConnectError, actions: {
            Button("OK") { connectError = nil }
        }, message: {
            Text(connectError ?? "Unable to connect.")
        })
        .alert("Rename Server", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let server = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let newName = trimmed.isEmpty ? server.hostname : trimmed
                    SavedServerStore.upsert(DiscoveredServer(
                        id: server.id,
                        name: newName,
                        hostname: server.hostname,
                        port: server.port,
                        codexPorts: server.codexPorts,
                        sshPort: server.sshPort,
                        source: server.source,
                        hasCodexServer: server.hasCodexServer,
                        wakeMAC: server.wakeMAC,
                        preferredConnectionMode: server.preferredConnectionMode,
                        preferredCodexPort: server.preferredCodexPort,
                        os: server.os,
                        sshBanner: server.sshBanner
                    ))
                    if let idx = discovery.servers.firstIndex(where: { $0.id == server.id }) {
                        discovery.servers[idx] = DiscoveredServer(
                            id: server.id,
                            name: newName,
                            hostname: server.hostname,
                            port: server.port,
                            codexPorts: server.codexPorts,
                            sshPort: server.sshPort,
                            source: server.source,
                            hasCodexServer: server.hasCodexServer,
                            wakeMAC: server.wakeMAC,
                            preferredConnectionMode: server.preferredConnectionMode,
                            preferredCodexPort: server.preferredCodexPort,
                            os: server.os,
                            sshBanner: server.sshBanner
                        )
                    }
                }
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for this server.")
        }
        .alert(
            "Install Codex?",
            isPresented: pendingInstallPresented,
            presenting: pendingInstallServerSnapshot
        ) { snapshot in
            Button("Install") {
                Task {
                    LLog.trace(
                        "discovery",
                        "responding to install prompt",
                        fields: [
                            "serverId": snapshot.serverId,
                            "install": true,
                            "detail": snapshot.connectionProgressDetail ?? ""
                        ]
                    )
                    _ = try? await appModel.ssh.sshRespondToInstallPrompt(
                        serverId: snapshot.serverId,
                        install: true
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                Task {
                    LLog.trace(
                        "discovery",
                        "responding to install prompt",
                        fields: [
                            "serverId": snapshot.serverId,
                            "install": false,
                            "detail": snapshot.connectionProgressDetail ?? ""
                        ]
                    )
                    _ = try? await appModel.ssh.sshRespondToInstallPrompt(
                        serverId: snapshot.serverId,
                        install: false
                    )
                }
            }
        } message: { snapshot in
            Text(snapshot.connectionProgressDetail ?? "Codex was not found on the remote host. Install the latest stable release into ~/.litter?")
        }
    }

    // MARK: - Chooser

    @ViewBuilder
    private var chooserContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pick how you want to connect.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
                    .padding(.top, 8)

                chooserCard(
                    title: "Pair with kittylitter",
                    subtitle: "Run npx kittylitter on the host, then scan the QR code it prints.",
                    badge: "RECOMMENDED",
                    icon: "qrcode.viewfinder",
                    accessibilityID: "discovery.chooser.kittylitter"
                ) {
                    showAlleycatSheet = true
                }

                chooserCard(
                    title: "SSH or Codex URL",
                    subtitle: "Connect over SSH (auto-bootstraps codex on the host) or paste a ws:// codex URL.",
                    badge: nil,
                    icon: "terminal",
                    accessibilityID: "discovery.chooser.manual"
                ) {
                    showManualEntry = true
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func chooserCard(
        title: String,
        subtitle: String,
        badge: String?,
        icon: String,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                    .frame(width: 32, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .litterFont(.subheadline, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                    if let badge {
                        Text(badge)
                            .litterFont(.caption2, weight: .semibold)
                            .foregroundColor(LitterTheme.accentStrong)
                            .tracking(0.5)
                    }
                    Text(subtitle)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(LitterTheme.textMuted)
                    .padding(.top, 4)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LitterTheme.surface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LitterTheme.accent.opacity(0.18), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }

    // MARK: - Sections (legacy discovery list, retained for sheet plumbing)

    private var allServers: [DiscoveredServer] {
        localServers + networkServers
    }

    private var serversSection: some View {
        Section {
            if allServers.isEmpty {
                if discovery.isInitialLoad {
                    HStack {
                        ProgressView().tint(LitterTheme.textMuted).scaleEffect(0.7)
                        Text("Scanning...")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No servers found")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textMuted)
                        if discovery.isScanning {
                            Text("Still searching network...")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            } else {
                ForEach(allServers) { server in
                    serverRow(server)
                }
            }

            if let notice = discovery.tailscaleDiscoveryNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "network.slash")
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(width: 18, alignment: .top)
                    Text(notice)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Servers")
                        .foregroundColor(LitterTheme.textSecondary)
                    Spacer()
                    if discovery.isScanning, let label = discovery.scanProgressLabel {
                        Text(label)
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                }
                if discovery.isScanning {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(LitterTheme.surface)
                                .frame(height: 3)
                            Capsule()
                                .fill(LitterTheme.accent)
                                .frame(
                                    width: geo.size.width * CGFloat(discovery.scanProgress),
                                    height: 3
                                )
                                .animation(.easeInOut(duration: 0.25), value: discovery.scanProgress)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .listRowBackground(LitterTheme.surface.opacity(0.6))
    }

    // MARK: - Row

    private func serverRow(_ server: DiscoveredServer) -> some View {
        let rowIdentifier = serverRowAccessibilityIdentifier(for: server)
        let serverSnapshot = appModel.snapshot?.servers.first(where: { $0.serverId == server.id })
        return Button {
            handleTap(server)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: serverIconName(for: server))
                    .foregroundColor(server.hasCodexServer ? LitterTheme.accent : LitterTheme.textSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(serverSubtitle(server))
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Spacer()
                if serverSnapshot?.isIpcConnected == true, ExperimentalFeatures.shared.isEnabled(.ipc) {
                    statusTag(label: "ipc", color: LitterTheme.accentStrong)
                }
                if let progressTag = progressTag(for: serverSnapshot) {
                    statusTag(label: progressTag.label, color: progressTag.color)
                } else if let health = serverSnapshot?.health,
                          health != .disconnected {
                    statusTag(label: health.displayLabel.lowercased(), color: health.accentColor)
                } else if connectingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                } else if wakingServer?.id == server.id {
                    ProgressView().controlSize(.small).tint(LitterTheme.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(LitterTheme.textMuted)
                        .font(.caption)
                }
            }
        }
        .accessibilityIdentifier(rowIdentifier)
        .disabled(connectingServer != nil || wakingServer != nil)
        .contextMenu {
            if server.source != .local {
                Button {
                    renameText = server.name
                    renameTarget = server
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
    }

    private func serverRowAccessibilityIdentifier(for server: DiscoveredServer) -> String {
        let kind = server.hasCodexServer ? "codex" : "ssh"
        let host = server.hostname
            .lowercased()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "discovery.server.\(kind).\(host)"
    }

    private func serverSubtitle(_ server: DiscoveredServer) -> String {
        if server.source == .local { return "In-process server" }
        let snapshot = connectedSnapshot(for: server)
        if let progressDetail = snapshot?.connectionProgressDetail,
           !progressDetail.isEmpty {
            return progressDetail
        }
        let displayHost = snapshot?.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot!.host
            : server.hostname
        var parts = [displayHost]
        if let os = server.os {
            parts.append(" - \(os)")
        }
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if !directPorts.isEmpty {
            parts.append(" - codex \(directPorts.joined(separator: ", "))")
        }
        if server.canConnectViaSSH {
            parts.append(" - ssh \(server.resolvedSSHPort)")
        }
        if snapshot?.isIpcConnected == true, ExperimentalFeatures.shared.isEnabled(.ipc) {
            parts.append(" - ipc")
        }
        return parts.joined()
    }

    @ViewBuilder
    private func statusTag(label: String, color: Color) -> some View {
        Text(label)
            .litterFont(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func connectedSnapshot(for server: DiscoveredServer) -> AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: { $0.serverId == server.id && !$0.isLocal })
    }

    // MARK: - Actions

    private func handleTap(_ server: DiscoveredServer) {
        Task { await handleTapAsync(server) }
    }

    private func navigateAfterConnect(_ server: DiscoveredServer) {
        guard let snapshot = appModel.snapshot?.servers.first(where: { $0.serverId == server.id }) else {
            onServerSelected?(server)
            return
        }
        if snapshot.isLocal, snapshot.account == nil {
            appState.showSettings = true
            return
        }
        onServerSelected?(server)
    }

    @MainActor
    private func handleTapAsync(_ server: DiscoveredServer) async {
        if appModel.snapshot?.servers.first(where: { $0.serverId == server.id })?.health == .connected {
            navigateAfterConnect(server)
            return
        }

        let prepared = await prepareServerForSelection(server)
        if prepared.server.requiresConnectionChoice {
            connectionChoiceServer = prepared.server
        } else if prepared.server.hasCodexServer, prepared.server.connectionTarget != nil {
            await connectToServer(prepared.server)
        } else if prepared.canAttemptSSH {
            sshServer = prepared.server.withConnectionPreference(.ssh)
        } else {
            connectError = "Server did not respond after wake attempt. Enable Wake for network access on the Mac."
        }
    }

    private func prepareServerForSelection(_ server: DiscoveredServer) async -> (server: DiscoveredServer, canAttemptSSH: Bool) {
        guard server.source != .local else {
            return (server, true)
        }

        wakingServer = server
        defer { wakingServer = nil }

        let wakeResult = await waitForWakeSignal(
            host: server.hostname,
            preferredCodexPort: server.hasCodexServer ? server.port : nil,
            preferredSSHPort: server.sshPort,
            timeout: server.hasCodexServer ? 12.0 : 18.0,
            wakeMAC: server.wakeMAC
        )

        switch wakeResult {
        case .codex(let port):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: port,
                    codexPorts: [port] + server.codexPorts.filter { $0 != port },
                    sshPort: server.sshPort,
                    source: server.source,
                    hasCodexServer: true,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: server.preferredConnectionMode,
                    preferredCodexPort: port
                ),
                true
            )
        case .ssh(let sshPort):
            return (
                DiscoveredServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: nil,
                    codexPorts: server.codexPorts,
                    sshPort: sshPort,
                    source: server.source,
                    hasCodexServer: false,
                    wakeMAC: server.wakeMAC,
                    sshPortForwardingEnabled: server.sshPortForwardingEnabled,
                    preferredConnectionMode: .ssh
                ),
                true
            )
        case .none:
            // Don't hard-block when wake probing is inconclusive; continue with
            // normal connect/SSH flow so users can still attempt recovery.
            return (server, true)
        }
    }

    private enum WakeSignalResult {
        case codex(UInt16)
        case ssh(UInt16)
        case none
    }

    private func waitForWakeSignal(
        host: String,
        preferredCodexPort: UInt16?,
        preferredSSHPort: UInt16?,
        timeout: TimeInterval,
        wakeMAC: String?
    ) async -> WakeSignalResult {
        let codexPorts = orderedCodexPorts(preferred: preferredCodexPort)
        let sshPorts = orderedSSHPorts(preferred: preferredSSHPort)
        let deadline = Date().addingTimeInterval(max(timeout, 0.5))
        var lastWakePacketAt = Date.distantPast

        while Date() < deadline {
            if let wakeMAC, Date().timeIntervalSince(lastWakePacketAt) >= 2.0 {
                sendWakeMagicPacket(to: wakeMAC, hostHint: host)
                lastWakePacketAt = Date()
            }

            for port in codexPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .codex(port)
                }
            }

            for port in sshPorts {
                if await isPortOpen(host: host, port: port, timeout: 0.7) {
                    return .ssh(port)
                }
            }

            try? await Task.sleep(for: .milliseconds(350))
        }

        return .none
    }

    private func orderedCodexPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(contentsOf: [8390, 9234, 4222])

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func orderedSSHPorts(preferred: UInt16?) -> [UInt16] {
        var ports = [UInt16]()
        if let preferred {
            ports.append(preferred)
        }
        ports.append(22)

        var seen = Set<UInt16>()
        return ports.filter { seen.insert($0).inserted }
    }

    private func sendWakeMagicPacket(to wakeMAC: String, hostHint: String) {
        guard let macBytes = macBytes(from: wakeMAC) else { return }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        let targets = wakeBroadcastTargets(for: hostHint)
        for target in targets {
            sendBroadcastUDP(packet: packet, host: target, port: 9)
            sendBroadcastUDP(packet: packet, host: target, port: 7)
        }
    }

    private func macBytes(from normalizedMAC: String) -> [UInt8]? {
        let compact = normalizedMAC.replacingOccurrences(of: ":", with: "")
        guard compact.count == 12 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            let chunk = compact[index..<next]
            guard let byte = UInt8(chunk, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func wakeBroadcastTargets(for host: String) -> [String] {
        var targets = ["255.255.255.255"]
        let parts = host.split(separator: ".")
        if parts.count == 4,
           let _ = Int(parts[0]),
           let _ = Int(parts[1]),
           let _ = Int(parts[2]),
           let _ = Int(parts[3]) {
            targets.append("\(parts[0]).\(parts[1]).\(parts[2]).255")
        }
        return Array(Set(targets))
    }

    private func sendBroadcastUDP(packet: Data, host: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var enabled: Int32 = 1
        withUnsafePointer(to: &enabled) { enabledPtr in
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, enabledPtr, socklen_t(MemoryLayout<Int32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        host.withCString { cString in
            _ = inet_pton(AF_INET, cString, &addr.sin_addr)
        }

        packet.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var destination = addr
            withUnsafePointer(to: &destination) { destinationPtr in
                destinationPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(fd, base, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let gate = WakeProbeResumeGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if gate.markResumed() {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.markResumed() {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func connectToServer(_ server: DiscoveredServer, targetOverride: ConnectionTarget? = nil) async {
        guard connectingServer == nil else { return }
        connectingServer = server
        connectError = nil

        guard let target = targetOverride ?? server.connectionTarget else {
            connectError = "Server requires SSH login"
            connectingServer = nil
            return
        }

        let connectedServerId: String
        let startedAsyncBootstrap: Bool
        do {
            switch target {
            case .local:
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectLocalServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: "127.0.0.1",
                    port: 0
                )
                await appModel.restoreStoredLocalAuthState(serverId: server.id)
                SavedServerStore.remember(server)
            case .remote(let host, let port):
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectRemoteServer(
                    serverId: server.id,
                    displayName: server.name,
                    host: host,
                    port: port
                )
                SavedServerStore.remember(server.withConnectionPreference(.directCodex, codexPort: port))
            case .remoteURL(let url):
                startedAsyncBootstrap = false
                connectedServerId = try await appModel.serverBridge.connectRemoteUrlServer(
                    serverId: server.id,
                    displayName: server.name,
                    websocketUrl: url.absoluteString
                )
                SavedServerStore.remember(server)
            case .sshThenRemote(let host, let credentials):
                startedAsyncBootstrap = true
                connectedServerId = try await connectViaSSH(server: server, host: host, credentials: credentials)
            }
        } catch {
            connectingServer = nil
            connectError = error.localizedDescription
            return
        }
        await appModel.refreshSnapshot()

        connectingServer = nil
        if startedAsyncBootstrap {
            pendingAutoNavigateServerId = connectedServerId
            pendingAutoNavigateServer = server
            return
        }
        if appModel.snapshot?.servers.first(where: { $0.serverId == connectedServerId })?.health == .connected {
            navigateAfterConnect(server)
        } else {
            connectError = "Failed to connect"
        }
    }

    /// Called by `AlleycatAddServerSheet` after the sheet has already opened a
    /// fully connected ServerSession. Persist the stable node/agent metadata
    /// and navigate; the token stays in Keychain.
    private func connectAlleycatTarget(_ result: AlleycatConnectedTarget) async {
        let synthesized = DiscoveredServer(
            id: result.serverId,
            name: result.displayName,
            hostname: result.nodeId,
            port: nil,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            wakeMAC: nil,
            sshPortForwardingEnabled: false,
            websocketURL: nil,
            preferredConnectionMode: nil,
            preferredCodexPort: nil,
            os: nil,
            sshBanner: nil
        )
        SavedServerStore.rememberAlleycat(
            synthesized,
            nodeId: result.nodeId,
            relay: result.params.relay,
            agentName: result.agentName,
            agentWire: alleycatWireStorageValue(result.agentWire)
        )
        await appModel.refreshSnapshot()
        if appModel.snapshot?.servers.first(where: { $0.serverId == result.serverId })?.health == .connected {
            navigateAfterConnect(synthesized)
        }
    }

    private func alleycatWireStorageValue(_ wire: AppAlleycatAgentWire) -> String {
        switch wire {
        case .websocket:
            return "websocket"
        case .jsonl:
            return "jsonl"
        }
    }

    private func connectViaSSH(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async throws -> String {
        let serverId = try await sshConnectAndConnectServer(
            serverId: server.id,
            displayName: server.name,
            host: host,
            credentials: credentials,
            port: server.resolvedSSHPort
        )
        SavedServerStore.remember(
            server.withConnectionPreference(.ssh)
        )
        return serverId
    }

    private func startSSHAgentProbe(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async {
        connectingServer = server
        connectError = nil
        do {
            let session = try await openSSHSession(
                host: host,
                port: server.resolvedSSHPort,
                credentials: credentials
            )
            let availability = try await appModel.ssh.sshProbeRemoteAgents(sessionId: session.sessionId)
            let bridgeAgents = availability.filter {
                switch $0.kind {
                case .claude, .pi, .opencode:
                    return $0.status == .available
                case .codex:
                    return false
                }
            }
            connectingServer = nil
            guard !bridgeAgents.isEmpty else {
                try? await appModel.ssh.sshClose(sessionId: session.sessionId)
                await connectToServer(server, targetOverride: .sshThenRemote(host: host, credentials: credentials))
                return
            }
            sshAgentContext = SSHBridgeAgentContext(
                server: server,
                sessionId: session.sessionId,
                host: session.normalizedHost,
                availability: availability,
                credentials: credentials
            )
        } catch {
            connectingServer = nil
            connectError = error.localizedDescription
        }
    }

    private func openSSHSession(
        host: String,
        port: UInt16,
        credentials: SSHCredentials
    ) async throws -> AppSshSessionResult {
        switch credentials {
        case .password(let username, let password, let unlockMacosKeychain):
            return try await appModel.ssh.sshOpenSession(
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                unlockMacosKeychain: unlockMacosKeychain,
                acceptUnknownHost: true
            )
        case .key(let username, let privateKey, let passphrase):
            return try await appModel.ssh.sshOpenSession(
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                unlockMacosKeychain: false,
                acceptUnknownHost: true
            )
        }
    }

    private func connectSSHBridgeTarget(
        _ result: SSHBridgeAgentResult,
        baseServer: DiscoveredServer
    ) async {
        let synthesized = DiscoveredServer(
            id: result.serverId,
            name: result.displayName,
            hostname: result.host,
            port: nil,
            codexPorts: [],
            sshPort: result.port,
            source: .ssh,
            hasCodexServer: true,
            wakeMAC: baseServer.wakeMAC,
            sshPortForwardingEnabled: false,
            websocketURL: nil,
            preferredConnectionMode: .ssh,
            preferredCodexPort: nil,
            os: baseServer.os,
            sshBanner: baseServer.sshBanner
        )
        SavedServerStore.rememberSSHBridge(synthesized, runtimeKinds: result.runtimeKinds)
        await SshSessionStore.shared.record(sessionId: result.sessionId, for: result.serverId)
        await appModel.refreshSnapshot()
        if appModel.snapshot?.servers.first(where: { $0.serverId == result.serverId })?.health == .connected {
            navigateAfterConnect(synthesized)
        }
    }

    private func sshConnectAndConnectServer(
        serverId: String,
        displayName: String,
        host: String,
        credentials: SSHCredentials,
        port: UInt16
    ) async throws -> String {
        let authMethod: String = switch credentials {
        case .password:
            "password"
        case .key:
            "private_key"
        }
        LLog.trace(
            "discovery",
            "starting guided SSH connect",
            fields: [
                "serverId": serverId,
                "host": host,
                "sshPort": Int(port),
                "authMethod": authMethod
            ]
        )
        let ipcSocketPathOverride = ExperimentalFeatures.shared.ipcSocketPathOverride()
        switch credentials {
        case .password(let username, let password, let unlockMacosKeychain):
            return try await appModel.serverBridge.startRemoteOverSshConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: password,
                privateKeyPem: nil,
                passphrase: nil,
                unlockMacosKeychain: unlockMacosKeychain,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        case .key(let username, let privateKey, let passphrase):
            return try await appModel.serverBridge.startRemoteOverSshConnect(
                serverId: serverId,
                displayName: displayName,
                host: host,
                port: port,
                username: username,
                password: nil,
                privateKeyPem: privateKey,
                passphrase: passphrase,
                unlockMacosKeychain: false,
                acceptUnknownHost: true,
                workingDir: nil,
                ipcSocketPathOverride: ipcSocketPathOverride
            )
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySheet: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    Section {
                        Picker("Connection Type", selection: $manualConnectionMode) {
                            ForEach(ManualConnectionMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Connection")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        if manualConnectionMode == .codex {
                            TextField("ws://host:port or wss://...", text: $manualCodexURL)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.URL)
                        } else {
                            TextField("hostname or IP", text: $manualHost)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            TextField("ssh port", text: $manualSSHPort)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .keyboardType(.numberPad)
                            TextField("wake MAC (optional)", text: $manualWakeMAC)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                    } header: {
                        Text(manualConnectionMode.formHeader)
                            .foregroundColor(LitterTheme.textSecondary)
                    } footer: {
                        if manualConnectionMode == .codex {
                            Text("Prefer the SSH flow — it bootstraps codex on the remote bound to 127.0.0.1 and forwards the port over SSH.\nIf you run it manually, bind loopback and tunnel yourself: codex app-server --listen ws://127.0.0.1:8390\nFor reverse proxies: wss://example.com/ws?token=SECRET\nDo not bind 0.0.0.0 or expose directly to the internet unless you know what you are doing.")
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    Section {
                        Button(manualConnectionMode.primaryButtonTitle) {
                            submitManualEntry()
                        }
                        .foregroundColor(LitterTheme.accent)
                        .litterFont(.subheadline)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showManualEntry = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        }
    }

    private func maybeStartSimulatorAutoSSH() {
#if DEBUG
        guard !autoSSHStarted else { return }
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_SIM_AUTO_SSH"] == "1",
              let host = env["CODEXIOS_SIM_AUTO_SSH_HOST"], !host.isEmpty,
              let user = env["CODEXIOS_SIM_AUTO_SSH_USER"], !user.isEmpty else {
            return
        }
        let password = env["CODEXIOS_SIM_AUTO_SSH_PASS"]
        let keyPath = env["CODEXIOS_SIM_AUTO_SSH_KEY_PATH"]
        let keyPem: String? = keyPath.flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard (password?.isEmpty == false) || (keyPem?.isEmpty == false) else { return }
        autoSSHStarted = true

        Task {
            NSLog("[AUTO_SSH] connecting to %@ as %@ (method=%@)", host, user, keyPem == nil ? "password" : "key")
            let server = DiscoveredServer(
                id: "auto-ssh-\(host)",
                name: host,
                hostname: host,
                port: nil,
                sshPort: 22,
                source: .ssh,
                hasCodexServer: false,
                sshPortForwardingEnabled: false,
                preferredConnectionMode: .ssh
            )
            let credentials: SSHCredentials
            if let keyPem, !keyPem.isEmpty {
                credentials = .key(
                    username: user,
                    privateKey: keyPem,
                    passphrase: env["CODEXIOS_SIM_AUTO_SSH_PASSPHRASE"]
                )
            } else {
                credentials = .password(
                    username: user,
                    password: password ?? "",
                    unlockMacosKeychain: false
                )
            }
            await connectToServer(
                server,
                targetOverride: .sshThenRemote(
                    host: host,
                    credentials: credentials
                )
            )
        }
#endif
    }

    private var showConnectError: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { newValue in
                if !newValue {
                    connectError = nil
                }
            }
        )
    }

    private func submitManualEntry() {
        switch manualConnectionMode {
        case .codex:
            submitManualCodexEntry()
        case .ssh:
            submitManualSSHEntry()
        }
    }

    private func submitManualCodexEntry() {
        let raw = manualCodexURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Full URL: ws:// or wss://
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           (scheme == "ws" || scheme == "wss"),
           let host = url.host, !host.isEmpty {
            let port = url.port.flatMap { UInt16(exactly: $0) }
            let server = DiscoveredServer(
                id: "manual-url-\(raw)",
                name: host,
                hostname: host,
                port: port,
                codexPorts: port.map { [$0] } ?? [],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                websocketURL: raw,
                preferredConnectionMode: .directCodex,
                preferredCodexPort: port
            )
            showManualEntry = false
            Task { await connectToServer(server) }
            return
        }

        // Bare host:port (e.g. "192.168.1.5:8390" or "myhost:8390")
        let parts = raw.split(separator: ":", maxSplits: 1)
        let host: String
        let port: UInt16
        if parts.count == 2, let p = UInt16(parts[1]) {
            host = String(parts[0])
            port = p
        } else if parts.count == 1 {
            host = raw
            port = 8390
        } else {
            connectError = "Enter a ws:// URL or host:port"
            return
        }

        guard !host.isEmpty else { return }
        let server = DiscoveredServer(
            id: "manual-\(host):\(port)",
            name: host,
            hostname: host,
            port: port,
            codexPorts: [port],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: port
        )
        showManualEntry = false
        Task { await connectToServer(server) }
    }

    private func submitManualSSHEntry() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }

        let wakeInput = manualWakeMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWakeMAC = DiscoveredServer.normalizeWakeMAC(wakeInput)
        if !wakeInput.isEmpty && normalizedWakeMAC == nil {
            connectError = "Wake MAC must look like aa:bb:cc:dd:ee:ff"
            return
        }

        guard let sshPort = UInt16(manualSSHPort) else {
            connectError = "SSH port must be a valid number"
            return
        }
        pendingSSHServer = DiscoveredServer(
            id: "manual-ssh-\(host):\(sshPort)",
            name: host,
            hostname: host,
            port: nil,
            sshPort: sshPort,
            source: .manual,
            hasCodexServer: false,
            wakeMAC: normalizedWakeMAC,
            preferredConnectionMode: .ssh
        )
        showManualEntry = false
    }

    private var connectionChoicePresented: Binding<Bool> {
        Binding(
            get: { connectionChoiceServer != nil },
            set: { newValue in
                if !newValue {
                    connectionChoiceServer = nil
                }
            }
        )
    }

    private var pendingInstallServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: { $0.connectionProgress?.pendingInstall == true })
    }

    private var pendingInstallPresented: Binding<Bool> {
        Binding(
            get: { pendingInstallServerSnapshot != nil },
            set: { _ in }
        )
    }

    private func connectionChoiceMessage(for server: DiscoveredServer) -> String {
        let directPorts = server.availableDirectCodexPorts.map(String.init)
        if directPorts.isEmpty {
            return "Use SSH to bootstrap Codex on \(server.hostname)."
        }
        if server.canConnectViaSSH {
            return "Codex is available on ports \(directPorts.joined(separator: ", ")) and SSH is also available on port \(server.resolvedSSHPort)."
        }
        return "Choose a Codex app-server port on \(server.hostname)."
    }

    private func progressTag(
        for serverSnapshot: AppServerSnapshot?
    ) -> (label: String, color: Color)? {
        guard let serverSnapshot,
              let label = serverSnapshot.connectionProgressLabel,
              let step = serverSnapshot.currentConnectionStep else {
            return nil
        }

        let color: Color
        switch step.state {
        case .failed:
            color = .red
        case .completed where step.kind == .connected:
            color = LitterTheme.accentStrong
        case .awaitingUserInput:
            color = .orange
        default:
            color = LitterTheme.accent
        }

        return (label, color)
    }
}

private final class WakeProbeResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed {
            return false
        }
        resumed = true
        return true
    }
}

private enum ManualConnectionMode: String, CaseIterable, Identifiable {
    case codex
    case ssh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex:
            return "Codex"
        case .ssh:
            return "SSH"
        }
    }

    var formHeader: String {
        switch self {
        case .codex:
            return "Codex Server"
        case .ssh:
            return "SSH Bootstrap"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .codex:
            return "Connect"
        case .ssh:
            return "Continue to SSH Login"
        }
    }
}

#if DEBUG
#Preview("Discovery") {
    LitterPreviewScene(
        appModel: LitterPreviewData.makeDiscoveryAppModel(),
        includeBackground: false
    ) {
        NavigationStack {
            DiscoveryView(
                autoStartDiscovery: false,
                initialServers: LitterPreviewData.sampleDiscoveryServers
            )
        }
    }
}
#endif
