import SwiftUI

struct DiscoveryView: View {
    var onServerSelected: ((DiscoveredServer) -> Void)?
    @Environment(AppModel.self) private var appModel
    @State private var sshServer: DiscoveredServer?
    @State private var pendingSSHServer: DiscoveredServer?
    @State private var sshAgentContext: SSHBridgeAgentContext?
    @State private var showManualEntry = false
    @State private var alleycatPairingMode: AlleycatPairingMode?
    @State private var showSlingshotHosts = false
    @State private var slingshotEnvironments: [AppSlingshotEnvironment] = []
    @State private var slingshotIsLoading = false
    @State private var slingshotError: String?
    @State private var manualConnectionMode: ManualConnectionMode = .ssh
    @State private var manualCodexURL = ""
    @State private var manualHost = ""
    @State private var manualSSHPort = "22"
    @State private var manualWakeMAC = ""
    @State private var autoSSHStarted = false
    @State private var connectingServer: DiscoveredServer?
    @State private var pendingAutoNavigateServerId: String?
    @State private var pendingAutoNavigateServer: DiscoveredServer?
    @State private var connectError: String?
    @Environment(AppState.self) private var appState
    private let autoStartSimulatorSSH: Bool
    private let slingshotBaseURL = "https://chatgpt.com/backend-api"

    init(
        onServerSelected: ((DiscoveredServer) -> Void)? = nil,
        autoStartSimulatorSSH: Bool = true
    ) {
        self.onServerSelected = onServerSelected
        self.autoStartSimulatorSSH = autoStartSimulatorSSH
    }

    private func handleAppear() {
        guard autoStartSimulatorSSH else { return }
        maybeStartSimulatorAutoSSH()
    }

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
        .sheet(isPresented: $showManualEntry) {
            manualEntrySheet
        }
        .sheet(isPresented: $showSlingshotHosts) {
            slingshotHostsSheet
        }
        .sheet(item: $alleycatPairingMode) { pairingMode in
            AlleycatAddServerSheet(
                appModel: appModel,
                startScanningOnAppear: true,
                pairingMode: pairingMode,
                onConnected: { result in
                    alleycatPairingMode = nil
                    Task { await connectAlleycatTarget(result) }
                }
            )
        }
        .onChange(of: showManualEntry) { _, isPresented in
            guard !isPresented, let pendingSSHServer else { return }
            self.pendingSSHServer = nil
            self.sshServer = pendingSSHServer
        }
        .onChange(of: appModel.snapshotRevision) { _, _ in
            guard let pendingAutoNavigateServerId else { return }
            guard let serverSnapshot = appModel.snapshot?.serverSnapshot(for: pendingAutoNavigateServerId) else {
                return
            }
            if serverSnapshot.health == .connected {
                self.pendingAutoNavigateServerId = nil
                if let server = pendingAutoNavigateServer {
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
                    supportedAgents: Self.kittylitterAgents,
                    isRecommended: true,
                    accessibilityID: "discovery.chooser.kittylitter"
                ) {
                    alleycatPairingMode = .kittylitter
                }

                chooserCard(
                    title: "Local Studio",
                    subtitle: "Scan the QR from Local Studio Profile, or paste Copy connection JSON.",
                    badge: nil,
                    icon: "server.rack",
                    supportedAgents: ["local-studio"],
                    isRecommended: false,
                    accessibilityID: "discovery.chooser.local-studio"
                ) {
                    alleycatPairingMode = .localStudio
                }

                chooserCard(
                    title: "Connected Computer",
                    subtitle: "Connect to a computer already signed in and running Codex for this ChatGPT account.",
                    badge: nil,
                    icon: "desktopcomputer",
                    supportedAgents: [AgentRuntimeKind.codex],
                    isRecommended: false,
                    accessibilityID: "discovery.chooser.slingshot"
                ) {
                    showSlingshotHosts = true
                }

                chooserCard(
                    title: "SSH or Codex URL",
                    subtitle: "Connect over SSH or paste a ws:// codex URL.",
                    badge: nil,
                    icon: "terminal",
                    supportedAgents: [AgentRuntimeKind.codex],
                    isRecommended: false,
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

    /// Canonical agent list shown on the kittylitter chooser card.
    /// Mirrors the splash carousel order so cold-start branding stays
    /// consistent. New agents added in the alleycat manifest still
    /// surface on connected hosts via the real metadata store; this list
    /// only seeds the pre-pair preview.
    private static let kittylitterAgents: [AgentRuntimeKind] = [
        "codex",
        "pi",
        "amp",
        "opencode",
        "claude",
        "droid",
        "hermes",
        "devin",
        "grok",
    ]

    private func chooserCard(
        title: String,
        subtitle: String,
        badge: String?,
        icon: String,
        supportedAgents: [AgentRuntimeKind],
        isRecommended: Bool,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(LitterTheme.accent.opacity(isRecommended ? 0.16 : 0.10))
                        )
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title)
                                .litterFont(.subheadline, weight: .semibold)
                                .foregroundColor(LitterTheme.textPrimary)
                            if let badge {
                                Text(badge)
                                    .litterFont(.caption2, weight: .semibold)
                                    .foregroundColor(LitterTheme.accentStrong)
                                    .tracking(0.5)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(LitterTheme.accent.opacity(0.14))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(LitterTheme.accent.opacity(0.45), lineWidth: 0.6)
                                    )
                            }
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
                        .padding(.top, 10)
                }

                if !supportedAgents.isEmpty {
                    supportedAgentsStrip(supportedAgents)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LitterTheme.surface.opacity(isRecommended ? 0.85 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LitterTheme.accent.opacity(isRecommended ? 0.45 : 0.18),
                        lineWidth: isRecommended ? 1.0 : 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
    }

    @ViewBuilder
    private func supportedAgentsStrip(_ agents: [AgentRuntimeKind]) -> some View {
        HStack(spacing: 8) {
            Text("Works with")
                .litterFont(.caption2)
                .foregroundColor(LitterTheme.textMuted)
                .tracking(0.4)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 5) {
                ForEach(agents, id: \.self) { agent in
                    AgentIconView(kind: agent, size: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Spacer(minLength: 0)
        }
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

    // MARK: - Actions

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
                if url.scheme?.lowercased() == "slingshot" {
                    let tokens = try await ChatGPTOAuth.loadStoredOrRefreshedTokens()
                    do {
                        connectedServerId = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            connectionUrl: url.absoluteString,
                            accessToken: tokens.accessToken,
                            accountId: tokens.accountID,
                            stepUpToken: ""
                        )
                    } catch {
                        guard ChatGPTOAuth.isRemoteControlAuthorizationRequired(error) else {
                            throw error
                        }
                        let stepUpToken = try await ChatGPTOAuth.remoteControlEnrollmentStepUpToken()
                        connectedServerId = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            connectionUrl: url.absoluteString,
                            accessToken: tokens.accessToken,
                            accountId: tokens.accountID,
                            stepUpToken: stepUpToken
                        )
                    }
                } else {
                    connectedServerId = try await appModel.serverBridge.connectRemoteUrlServer(
                        serverId: server.id,
                        displayName: server.name,
                        websocketUrl: url.absoluteString
                    )
                }
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
                // SSH bridge bootstrap can launch claude / pi / opencode
                // on the remote; everything else (codex, amp, droid,
                // hermes, anything new) only reaches the host via the
                // alleycat pairing path.
                guard $0.status == .available else { return false }
                if let supports = $0.kind.metadata?.capabilities?.supportsSshBridge {
                    return supports && $0.kind != "codex"
                }
                switch $0.kind {
                case "claude", "pi", "opencode", "local-studio": return true
                default: return false
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
                workingDir: nil
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
                workingDir: nil
            )
        }
    }

    // MARK: - Connected Computers

    private var slingshotHostsSheet: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                List {
                    Section {
                        if slingshotIsLoading && slingshotEnvironments.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .tint(LitterTheme.accent)
                                Text("Loading connected computers...")
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        } else if let slingshotError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(slingshotError)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                                Button("Retry") {
                                    Task { await loadSlingshotEnvironments() }
                                }
                                .foregroundColor(LitterTheme.accent)
                                .litterFont(.footnote, weight: .semibold)
                            }
                        } else if slingshotEnvironments.isEmpty {
                            Text("No connected computers were found for this account.")
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textSecondary)
                        } else {
                            ForEach(slingshotEnvironments, id: \.id) { environment in
                                Button {
                                    showSlingshotHosts = false
                                    Task { await connectSlingshotEnvironment(environment) }
                                } label: {
                                    slingshotEnvironmentRow(environment)
                                }
                                .buttonStyle(.plain)
                                .disabled(!environment.online)
                            }
                        }
                    } header: {
                        Text("Connected Computers")
                            .foregroundColor(LitterTheme.textSecondary)
                    } footer: {
                        Text("These computers come from ChatGPT using your signed-in account. Start Codex on the computer first so it appears here.")
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Connected Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Refresh") {
                        Task { await loadSlingshotEnvironments() }
                    }
                    .disabled(slingshotIsLoading)
                    .foregroundColor(LitterTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { showSlingshotHosts = false }
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .task {
                if slingshotEnvironments.isEmpty && !slingshotIsLoading {
                    await loadSlingshotEnvironments()
                }
            }
        }
    }

    private func slingshotEnvironmentRow(_ environment: AppSlingshotEnvironment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: slingshotIconName(for: environment))
                .foregroundColor(environment.online ? LitterTheme.accent : LitterTheme.textMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.displayName)
                    .litterFont(.subheadline)
                    .foregroundColor(environment.online ? LitterTheme.textPrimary : LitterTheme.textSecondary)
                Text(slingshotSubtitle(for: environment))
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
            }
            Spacer()
            statusTag(
                label: environment.online ? (environment.busy ? "busy" : "online") : "offline",
                color: environment.online ? (environment.busy ? .orange : LitterTheme.accent) : LitterTheme.textMuted
            )
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func loadSlingshotEnvironments() async {
        guard !slingshotIsLoading else { return }
        slingshotIsLoading = true
        slingshotError = nil
        defer { slingshotIsLoading = false }

        do {
            let tokens = try await ChatGPTOAuth.loadStoredOrRefreshedTokens()
            let environments = try await appModel.serverBridge.listSlingshotEnvironments(
                baseUrl: slingshotBaseURL,
                accessToken: tokens.accessToken,
                accountId: tokens.accountID
            )
            slingshotEnvironments = environments.sorted { lhs, rhs in
                if lhs.online != rhs.online { return lhs.online && !rhs.online }
                if lhs.busy != rhs.busy { return !lhs.busy && rhs.busy }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            slingshotError = error.localizedDescription
        }
    }

    @MainActor
    private func connectSlingshotEnvironment(_ environment: AppSlingshotEnvironment) async {
        guard environment.online else {
            connectError = "\(environment.displayName) is offline."
            return
        }
        guard let server = slingshotServer(for: environment) else {
            connectError = "Could not prepare this connected computer."
            return
        }
        await connectToServer(server)
    }

    private func slingshotServer(for environment: AppSlingshotEnvironment) -> DiscoveredServer? {
        guard URL(string: environment.connectionUrl) != nil else {
            return nil
        }
        return DiscoveredServer(
            id: "slingshot-\(environment.id)",
            name: environment.displayName,
            hostname: environment.id,
            port: nil,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            websocketURL: environment.connectionUrl,
            preferredConnectionMode: .directCodex,
            os: environment.operatingSystem,
            sshBanner: nil
        )
    }

    private func slingshotSubtitle(for environment: AppSlingshotEnvironment) -> String {
        var parts: [String] = []
        if let hostName = environment.hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            parts.append(hostName)
        }
        let platform = [environment.operatingSystem, environment.architecture]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " ")
        if !platform.isEmpty {
            parts.append(platform)
        }
        if let version = environment.appServerVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            parts.append("Codex \(version)")
        }
        if parts.isEmpty {
            parts.append(environment.id)
        }
        return parts.joined(separator: " - ")
    }

    private func slingshotIconName(for environment: AppSlingshotEnvironment) -> String {
        switch environment.operatingSystem.lowercased() {
        case "linux":
            return "server.rack"
        case "windows":
            return "desktopcomputer"
        case "macos", "darwin":
            return "desktopcomputer"
        default:
            return "laptopcomputer"
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
            DiscoveryView(autoStartSimulatorSSH: false)
        }
    }
}
#endif
