import Observation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @AppStorage("collapseTurns") private var collapseTurns = false
    @AppStorage(ConversationDisplayPreferenceKey.reasoning) private var reasoningDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.commands) private var commandDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @AppStorage(ConversationDisplayPreferenceKey.tools) private var toolDisplayMode = ConversationDetailDisplayMode.collapsed.rawValue
    @State private var activeServerSheet: SettingsServerSheet?
    @State private var serverEditError: String?
    /// Server projections mirrored out of `appModel.snapshot` by
    /// `snapshotObserver`. Reading the snapshot from `body` (as these used to,
    /// via computed properties) re-rendered all of Settings at the ~8 fps
    /// streaming snapshot cadence.
    @State private var localServer: AppServerSnapshot?
    @State private var connectedServers: [HomeDashboardServer] = []
    @State private var snapshotObserver = AppSnapshotObserver()

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                // One plain grouped list. Every row opens its settings
                // directly (no pages that only hold another link); rarely
                // used switches live under a single "Advanced" row.
                List {
                    Section {
                        category("Computers", "desktopcomputer", value: computersValue, id: "settings.category.computers") {
                            settingsPage("Computers") { serversSection }
                        }
                        category("Harnesses", "cpu", id: "settings.category.harnesses") {
                            HarnessSettingsView()
                        }
                        category("Account", "person.crop.circle", value: accountValue, id: "settings.category.account") {
                            settingsPage("Account") { accountSection }
                        }
                    } header: {
                        settingsHeader("Connections")
                    }
                    Section {
                        category("Appearance", "paintbrush", id: "settings.category.appearance") {
                            AppearanceSettingsView()
                        }
                        category("Conversation", "text.bubble", id: "settings.category.conversation") {
                            settingsPage("Conversation") { conversationSection }
                        }
                    } header: {
                        settingsHeader("Interface")
                    }
                    Section {
                        category("Advanced", "slider.horizontal.3", id: "settings.category.advanced") {
                            settingsPage("Advanced") { advancedSections }
                        }
                        category("Tip the Kitty", "heart", id: "settings.category.support") {
                            TipJarView()
                        }
                    } header: {
                        settingsHeader("More")
                    } footer: {
                        if let versionLabel {
                            Text(versionLabel)
                                .litterMeta()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, LitterSpace.m)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .task {
                // Mirror the server projections out of the snapshot from a
                // non-body context. `AppSnapshotObserver` re-runs this on every
                // (coalesced) snapshot revision, so connection health, account
                // state and new/removed servers all still land here — but the
                // Form only re-renders when a projection actually changes.
                let model = appModel
                snapshotObserver.start(appModel: model) { refreshServerProjections(model) }
            }
            .onDisappear { snapshotObserver.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .litterSavedServersDidChange)) { _ in
                // `connectedServers` also folds in `SavedServerStore`, which
                // changes without a snapshot revision (add/remove/rename).
                refreshServerProjections(appModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .accessibilityIdentifier("settings.done")
                }
            }
            .sheet(item: $activeServerSheet) { sheet in
                switch sheet {
                case .add:
                    NavigationStack {
                        DiscoveryView(onServerSelected: { _ in
                            activeServerSheet = nil
                        })
                    }
                    .environment(appModel)
                    .environment(appState)
                    .environment(\.textScale, textScale)
                case .edit(let server):
                    SettingsServerConnectionEditor(
                        server: server,
                        onSave: { configuration in
                            saveServerConfiguration(configuration, reconnect: false)
                            activeServerSheet = nil
                        },
                        onReconnect: { configuration in
                            activeServerSheet = nil
                            saveServerConfiguration(configuration, reconnect: true)
                        }
                    )
                    .environment(\.textScale, textScale)
                case .sshReconnect(let server):
                    SSHLoginSheet(server: server) { target in
                        activeServerSheet = nil
                        if case .sshThenRemote(let host, let credentials) = target {
                            Task { await reconnectViaSSH(server: server, host: host, credentials: credentials) }
                        }
                    }
                }
            }
            .alert("Couldn't update computer", isPresented: Binding(
                get: { serverEditError != nil },
                set: { if !$0 { serverEditError = nil } }
            )) {
                Button("OK") { serverEditError = nil }
            } message: {
                Text(serverEditError ?? "Unable to update this server.")
            }
        }
    }

    /// Recompute the server-derived projections. Called from
    /// `snapshotObserver` (every coalesced snapshot revision) and from the
    /// saved-servers notification — never from `body`. Writes `@State` only
    /// when a value actually changed, so an idle snapshot bump costs nothing.
    /// Takes the model explicitly: the observer invokes this long after the
    /// enclosing `body` ran, and `@Environment` should not be read from a
    /// deferred closure.
    private func refreshServerProjections(_ appModel: AppModel) {
        let snapshot = appModel.snapshot
        let servers = snapshot?.servers ?? []

        // Account management (ChatGPT login / API key) is local-only, always.
        // If the local Codex bridge hasn't spun up there's no login target, and
        // the caller falls through to `SettingsDisconnectedAccountSection`.
        let nextLocalServer = servers.first(where: \.isLocal)
        if localServer != nextLocalServer {
            localServer = nextLocalServer
        }

        let nextConnectedServers = HomeDashboardSupport.sortedConnectedServers(
            from: servers,
            savedServers: SavedServerStore.rememberedServers(),
            activeServerId: snapshot?.activeThread?.serverId
        )
        if connectedServers != nextConnectedServers {
            connectedServers = nextConnectedServers
        }
    }

    // MARK: - Root row values

    private var computersValue: String? {
        connectedServers.isEmpty ? nil : "\(connectedServers.count)"
    }

    private var accountValue: String? {
        guard let localServer else { return nil }
        switch localServer.account {
        case .chatgpt(let email, _)?:
            return email.isEmpty ? "ChatGPT" : email
        case .apiKey?:
            return "API key"
        case nil:
            return "Not signed in"
        }
    }

    private var versionLabel: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "Litter \(version) (\(build))"
        }
        return "Litter \(version)"
    }

    // MARK: - Conversation Section

    private var conversationSection: some View {
        Group {
            Section {
                Toggle(isOn: $collapseTurns) {
                    SettingsRowText(
                        title: "Collapse earlier turns",
                        subtitle: "Long conversations collapse automatically"
                    )
                }
                .tint(LitterTheme.accent)
                .settingsRowBackground()
            }

            Section {
                transcriptDisplayPicker(title: "Thinking", selection: $reasoningDisplayMode)
                transcriptDisplayPicker(title: "Commands", selection: $commandDisplayMode)
                transcriptDisplayPicker(title: "Tools", selection: $toolDisplayMode)
            } header: {
                settingsHeader("Show in transcript")
            } footer: {
                Text("Tools covers MCP, web, image, and file-change cards.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
    }

    private func transcriptDisplayPicker(
        title: String,
        selection: Binding<String>
    ) -> some View {
        Picker(selection: selection) {
            ForEach(ConversationDetailDisplayMode.allCases) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        } label: {
            Text(title)
                .litterFont(.body)
                .foregroundColor(LitterTheme.textPrimary)
        }
        .pickerStyle(.menu)
        .tint(LitterTheme.textSecondary)
        .settingsRowBackground()
    }

    // MARK: - Advanced

    /// Rarely used switches in one place: experimental features, the wake
    /// pet, debug mode and the Local Studio link.
    private var advancedSections: some View {
        Group {
            ExperimentalFeatureSections()

            Section {
                NavigationLink {
                    PetSettingsView()
                } label: {
                    SettingsRowLabel(
                        title: "Wake Pet",
                        systemImage: "pawprint",
                        value: PetOverlayController.shared.selectedPet?.displayName
                    )
                }
                .accessibilityIdentifier("settings.category.pets")
                .settingsRowBackground()

                Link(destination: URL(string: "https://localstudio.ai")!) {
                    HStack(spacing: LitterSpace.m) {
                        SettingsRowLabel(title: "Local Studio", systemImage: "sparkles", value: "localstudio.ai")
                        Image(systemName: "arrow.up.right")
                            .litterFont(.footnote, weight: .semibold)
                            .foregroundColor(LitterTheme.textMuted)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("settings.category.localai")
                .settingsRowBackground()
            } header: {
                settingsHeader("Extras")
            }
        }
    }

    // MARK: - Account Section (inline, no nested sheet)

    private var accountSection: some View {
        Group {
            if let localServer {
                SettingsConnectionAccountSection(server: localServer)
            } else {
                SettingsDisconnectedAccountSection()
            }
        }
    }

    // MARK: - Layout helpers

    private func settingsHeader(_ title: String) -> some View {
        SettingsSectionHeader(title)
    }

    private func category<Destination: View>(
        _ title: String,
        _ symbol: String,
        value: String? = nil,
        id: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowLabel(title: title, systemImage: symbol, value: value)
        }
        .accessibilityIdentifier(id)
        .settingsRowBackground()
    }

    private func settingsPage<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Form { content() }
                .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Computers: the one place to add, edit and remove hosts (iOS Settings
    /// list pattern — tap to edit, swipe or long-press to remove).
    private var serversSection: some View {
        Section {
            ForEach(connectedServers, id: \.id) { conn in
                Button {
                    activeServerSheet = .edit(conn)
                } label: {
                    HStack(spacing: LitterSpace.m) {
                        StatusDot(state: conn.statusDotState, size: 8)
                            .frame(width: SettingsRowLabel.iconWidth)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.displayName)
                                .litterFont(.body)
                                .foregroundColor(LitterTheme.textPrimary)
                                .lineLimit(1)
                            if let word = conn.connectionWord {
                                Text(word.text)
                                    .litterFont(.footnote)
                                    .foregroundColor(word.color)
                            } else {
                                Text(conn.sourceLabel)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .litterFont(.footnote, weight: .semibold)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.computerRow")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !conn.isLocal {
                        Button(role: .destructive) {
                            removeServer(conn)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .contextMenu {
                    Button {
                        activeServerSheet = .edit(conn)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    if !conn.isLocal {
                        Button(role: .destructive) {
                            removeServer(conn)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                .settingsRowBackground()
            }

            Button {
                activeServerSheet = .add
            } label: {
                HStack(spacing: LitterSpace.m) {
                    Image(systemName: "plus")
                        .litterFont(.body)
                        .frame(width: SettingsRowLabel.iconWidth)
                    Text("Add computer")
                        .litterFont(.body)
                }
                .foregroundColor(LitterTheme.accent)
            }
            .accessibilityIdentifier("settings.addComputer")
            .settingsRowBackground()
        } footer: {
            Text("Pair a computer running kittylitter, Local Studio, or reachable over SSH. Swipe a computer to remove it.")
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textMuted)
        }
    }

    private func removeServer(_ server: HomeDashboardServer) {
        SavedServerStore.remove(serverId: server.id)
        Task { await SshSessionStore.shared.close(serverId: server.id, ssh: appModel.ssh) }
        appModel.serverBridge.disconnectServer(serverId: server.id)
    }

    private func saveServerConfiguration(
        _ configuration: SettingsServerConnectionConfiguration,
        reconnect: Bool
    ) {
        var saved = SavedServerStore.load()
        if let index = saved.firstIndex(where: { $0.id == configuration.savedServer.id }) {
            saved[index] = configuration.savedServer
        } else {
            saved.append(configuration.savedServer)
        }
        SavedServerStore.save(saved)
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(
            servers: SavedServerStore.reconnectRecords(
                localDisplayName: appModel.resolvedLocalServerDisplayName()
            )
        )
        appModel.store.renameServer(
            serverId: configuration.savedServer.id,
            displayName: configuration.savedServer.name
        )

        guard reconnect else { return }
        reconnectServer(using: configuration)
    }

    private func reconnectServer(using configuration: SettingsServerConnectionConfiguration) {
        let server = configuration.discoveredServer

        // For SSH we keep the existing connection alive until the user actually
        // submits credentials, so a cancelled credential sheet does not leave
        // them disconnected.
        if case .ssh = configuration.connectionMode {
            activeServerSheet = .sshReconnect(server)
            return
        }

        Task {
            await SshSessionStore.shared.close(serverId: server.id, ssh: appModel.ssh)
            appModel.serverBridge.disconnectServer(serverId: server.id)

            do {
                switch configuration.connectionMode {
                case .local:
                    try await appModel.restartLocalServer()
                case .directCodex:
                    guard let port = server.resolvedDirectCodexPort else {
                        throw SettingsServerConnectionError.missingCodexPort
                    }
                    _ = try await appModel.serverBridge.connectRemoteServer(
                        serverId: server.id,
                        displayName: server.name,
                        host: server.hostname,
                        port: port
                    )
                    await appModel.refreshSnapshot()
                case .websocket:
                    guard let websocketURL = server.websocketURL else {
                        throw SettingsServerConnectionError.invalidWebsocketURL
                    }
                    if isSettingsSlingshotURL(websocketURL) {
                        let tokens = try await ChatGPTOAuth.loadStoredOrRefreshedTokens()
                        do {
                            _ = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                                serverId: server.id,
                                displayName: server.name,
                                connectionUrl: websocketURL,
                                accessToken: tokens.accessToken,
                                accountId: tokens.accountID,
                                stepUpToken: ""
                            )
                        } catch {
                            guard ChatGPTOAuth.isRemoteControlAuthorizationRequired(error) else {
                                throw error
                            }
                            let stepUpToken = try await ChatGPTOAuth.remoteControlEnrollmentStepUpToken()
                            _ = try await appModel.serverBridge.connectRemoteSlingshotUrlServer(
                                serverId: server.id,
                                displayName: server.name,
                                connectionUrl: websocketURL,
                                accessToken: tokens.accessToken,
                                accountId: tokens.accountID,
                                stepUpToken: stepUpToken
                            )
                        }
                    } else {
                        _ = try await appModel.serverBridge.connectRemoteUrlServer(
                            serverId: server.id,
                            displayName: server.name,
                            websocketUrl: websocketURL
                        )
                    }
                    await appModel.refreshSnapshot()
                case .ssh:
                    break
                }
            } catch {
                serverEditError = error.localizedDescription
            }
        }
    }

    private func reconnectViaSSH(
        server: DiscoveredServer,
        host: String,
        credentials: SSHCredentials
    ) async {
        await SshSessionStore.shared.close(serverId: server.id, ssh: appModel.ssh)
        appModel.serverBridge.disconnectServer(serverId: server.id)

        do {
            _ = try await startRemoteOverSSH(
                serverId: server.id,
                displayName: server.name,
                host: host,
                port: server.resolvedSSHPort,
                credentials: credentials
            )
            await appModel.refreshSnapshot()
        } catch {
            serverEditError = error.localizedDescription
        }
    }

    private func startRemoteOverSSH(
        serverId: String,
        displayName: String,
        host: String,
        port: UInt16,
        credentials: SSHCredentials
    ) async throws -> String {
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

}


private enum SettingsServerSheet: Identifiable {
    case add
    case edit(HomeDashboardServer)
    case sshReconnect(DiscoveredServer)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let server):
            return "edit-\(server.id)"
        case .sshReconnect(let server):
            return "ssh-\(server.id)"
        }
    }
}

private enum SettingsServerConnectionMode: String, CaseIterable, Identifiable {
    case local
    case ssh
    case directCodex
    case websocket

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .ssh:
            return "SSH"
        case .directCodex:
            return "Codex"
        case .websocket:
            return "WebSocket"
        }
    }

    var formHeader: String {
        switch self {
        case .local:
            return "Local Runtime"
        case .ssh:
            return "SSH Host"
        case .directCodex:
            return "Codex Server"
        case .websocket:
            return "Codex URL"
        }
    }
}

private enum SettingsServerConnectionError: LocalizedError {
    case emptyName
    case emptyHost
    case invalidCodexPort
    case missingCodexPort
    case invalidSSHPort
    case invalidWakeMAC
    case invalidWebsocketURL

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Name cannot be empty."
        case .emptyHost:
            return "Host cannot be empty."
        case .invalidCodexPort, .missingCodexPort:
            return "Codex port must be a valid number."
        case .invalidSSHPort:
            return "SSH port must be a valid number."
        case .invalidWakeMAC:
            return "Wake MAC must look like aa:bb:cc:dd:ee:ff."
        case .invalidWebsocketURL:
            return "Enter a valid ws:// or wss:// URL."
        }
    }
}

private struct SettingsServerConnectionConfiguration {
    let savedServer: SavedServer
    let discoveredServer: DiscoveredServer
    let connectionMode: SettingsServerConnectionMode
}

private struct SettingsServerConnectionEditor: View {
    let server: HomeDashboardServer
    let onSave: (SettingsServerConnectionConfiguration) -> Void
    let onReconnect: (SettingsServerConnectionConfiguration) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var connectionMode: SettingsServerConnectionMode
    @State private var host: String
    @State private var codexPort: String
    @State private var websocketURL: String
    @State private var sshPort: String
    @State private var wakeMAC: String
    @State private var validationError: String?

    private let originalSavedServer: SavedServer?

    @MainActor
    init(
        server: HomeDashboardServer,
        onSave: @escaping (SettingsServerConnectionConfiguration) -> Void,
        onReconnect: @escaping (SettingsServerConnectionConfiguration) -> Void
    ) {
        self.server = server
        self.onSave = onSave
        self.onReconnect = onReconnect

        let saved = SavedServerStore.load().first { $0.id == server.id }
        self.originalSavedServer = saved

        let resolvedMode: SettingsServerConnectionMode
        if server.isLocal {
            resolvedMode = .local
        } else if saved?.websocketURL != nil {
            resolvedMode = .websocket
        } else if saved?.preferredConnectionMode == .ssh || saved?.sshPort != nil && saved?.hasCodexServer == false {
            resolvedMode = .ssh
        } else {
            resolvedMode = .directCodex
        }

        let name = saved?.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = saved?.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCodexPort = saved?.preferredCodexPort ?? saved?.port ?? (server.port == 0 ? nil : server.port)
        let resolvedSSHPort = saved?.sshPort ?? (resolvedMode == .ssh ? server.port : nil) ?? 22

        _displayName = State(initialValue: name?.isEmpty == false ? name! : server.displayName)
        _connectionMode = State(initialValue: resolvedMode)
        _host = State(initialValue: resolvedHost?.isEmpty == false ? resolvedHost! : server.host)
        _codexPort = State(initialValue: resolvedCodexPort.map(String.init) ?? "8390")
        _websocketURL = State(initialValue: saved?.websocketURL ?? "")
        _sshPort = State(initialValue: String(resolvedSSHPort))
        _wakeMAC = State(initialValue: saved?.wakeMAC ?? "")
    }

    private var availableModes: [SettingsServerConnectionMode] {
        server.isLocal ? [.local] : [.ssh, .directCodex, .websocket]
    }

    private var isSpecialPairedServer: Bool {
        originalSavedServer?.alleycatNodeId != nil || originalSavedServer?.alleycatAgentWire == "ssh-bridge"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    nameSection
                    connectionSection
                    actionSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .alert("Check the details", isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK") { validationError = nil }
            } message: {
                Text(validationError ?? "Check the server details.")
            }
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Name", text: $displayName)
                .litterFont(.body)
                .foregroundColor(LitterTheme.textPrimary)
        } header: {
            SettingsSectionHeader("Name")
        }
        .settingsRowBackground()
    }

    private var connectionSection: some View {
        Section {
            if isSpecialPairedServer {
                Text("This paired server uses saved pairing metadata. Edit its display name here, or remove and add it again to change the pairing.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
            } else if connectionMode == .local {
                Text("This device's local runtime is managed automatically.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
            } else {
                Picker("Connection Type", selection: $connectionMode) {
                    ForEach(availableModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                switch connectionMode {
                case .local:
                    EmptyView()
                case .ssh:
                    hostField
                    TextField("ssh port", text: $sshPort)
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textPrimary)
                        .keyboardType(.numberPad)
                    TextField("wake MAC (optional)", text: $wakeMAC)
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                case .directCodex:
                    hostField
                    TextField("codex port", text: $codexPort)
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textPrimary)
                        .keyboardType(.numberPad)
                case .websocket:
                    TextField("ws://host:port or wss://...", text: $websocketURL)
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                }
            }
        } header: {
            SettingsSectionHeader(connectionMode.formHeader)
        } footer: {
            if !isSpecialPairedServer, connectionMode == .websocket {
                Text("Prefer SSH when possible. If you run codex manually, bind loopback and tunnel it yourself; do not expose it directly to the internet unless you know what you are doing.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
        .settingsRowBackground()
    }

    private var hostField: some View {
        TextField("hostname or IP", text: $host)
            .litterFont(.body)
            .foregroundColor(LitterTheme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
    }

    private var actionSection: some View {
        Section {
            Button("Save") {
                submit(reconnect: false)
            }
            .foregroundColor(LitterTheme.textPrimary)
            .litterFont(.body)

            if !isSpecialPairedServer {
                Button(connectionMode == .local ? "Save & Restart" : "Save & Reconnect") {
                    submit(reconnect: true)
                }
                .foregroundColor(LitterTheme.textPrimary)
                .litterFont(.body)
            }
        }
        .settingsRowBackground()
    }

    private func submit(reconnect: Bool) {
        do {
            let configuration = try buildConfiguration()
            if reconnect {
                onReconnect(configuration)
            } else {
                onSave(configuration)
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func buildConfiguration() throws -> SettingsServerConnectionConfiguration {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SettingsServerConnectionError.emptyName }

        if isSpecialPairedServer, let originalSavedServer {
            let updated = originalSavedServer.withName(name)
            return SettingsServerConnectionConfiguration(
                savedServer: updated,
                discoveredServer: updated.toDiscoveredServer(),
                connectionMode: connectionMode
            )
        }

        switch connectionMode {
        case .local:
            let saved = SavedServer(
                id: server.id,
                name: name,
                hostname: "127.0.0.1",
                port: 0,
                codexPorts: [],
                sshPort: nil,
                source: .local,
                hasCodexServer: true,
                wakeMAC: nil,
                preferredConnectionMode: nil,
                preferredCodexPort: nil,
                sshPortForwardingEnabled: nil,
                websocketURL: nil,
                rememberedByUser: true
            )
            return SettingsServerConnectionConfiguration(
                savedServer: saved,
                discoveredServer: saved.toDiscoveredServer(),
                connectionMode: .local
            )
        case .ssh:
            let resolvedHost = try validatedHost()
            let resolvedWakeMAC = try validatedWakeMAC()
            guard let resolvedSSHPort = UInt16(sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SettingsServerConnectionError.invalidSSHPort
            }
            let saved = SavedServer(
                id: server.id,
                name: name,
                hostname: resolvedHost,
                port: nil,
                codexPorts: [],
                sshPort: resolvedSSHPort,
                source: .manual,
                hasCodexServer: false,
                wakeMAC: resolvedWakeMAC,
                preferredConnectionMode: .ssh,
                preferredCodexPort: nil,
                sshPortForwardingEnabled: nil,
                websocketURL: nil,
                rememberedByUser: true
            )
            return SettingsServerConnectionConfiguration(
                savedServer: saved,
                discoveredServer: saved.toDiscoveredServer(),
                connectionMode: .ssh
            )
        case .directCodex:
            let resolvedHost = try validatedHost()
            guard let resolvedCodexPort = UInt16(codexPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SettingsServerConnectionError.invalidCodexPort
            }
            let saved = SavedServer(
                id: server.id,
                name: name,
                hostname: resolvedHost,
                port: resolvedCodexPort,
                codexPorts: [resolvedCodexPort],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                wakeMAC: nil,
                preferredConnectionMode: .directCodex,
                preferredCodexPort: resolvedCodexPort,
                sshPortForwardingEnabled: nil,
                websocketURL: nil,
                rememberedByUser: true
            )
            return SettingsServerConnectionConfiguration(
                savedServer: saved,
                discoveredServer: saved.toDiscoveredServer(),
                connectionMode: .directCodex
            )
        case .websocket:
            let rawURL = websocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "ws" || scheme == "wss"),
                  let resolvedHost = url.host,
                  !resolvedHost.isEmpty else {
                throw SettingsServerConnectionError.invalidWebsocketURL
            }
            let resolvedPort = url.port.flatMap { UInt16(exactly: $0) }
            let saved = SavedServer(
                id: server.id,
                name: name,
                hostname: resolvedHost,
                port: resolvedPort,
                codexPorts: resolvedPort.map { [$0] } ?? [],
                sshPort: nil,
                source: .manual,
                hasCodexServer: true,
                wakeMAC: nil,
                preferredConnectionMode: .directCodex,
                preferredCodexPort: resolvedPort,
                sshPortForwardingEnabled: nil,
                websocketURL: rawURL,
                rememberedByUser: true
            )
            return SettingsServerConnectionConfiguration(
                savedServer: saved,
                discoveredServer: saved.toDiscoveredServer(),
                connectionMode: .websocket
            )
        }
    }

    private func validatedHost() throws -> String {
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedHost.isEmpty else { throw SettingsServerConnectionError.emptyHost }
        return resolvedHost
    }

    private func validatedWakeMAC() throws -> String? {
        let wakeInput = wakeMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wakeInput.isEmpty else { return nil }
        guard let normalized = DiscoveredServer.normalizeWakeMAC(wakeInput) else {
            throw SettingsServerConnectionError.invalidWakeMAC
        }
        return normalized
    }
}

private struct SettingsConnectionAccountSection: View {
    @Environment(AppModel.self) private var appModel
    let server: AppServerSnapshot
    @State private var apiKey = ""
    @State private var openAIBaseURL = ""
    @State private var isAuthWorking = false
    @State private var authError: String?
    @State private var hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var hasStoredChatGPTTokens = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textPrimary)
                    if let sub = authSubtitle {
                        Text(sub)
                            .litterMeta(authColor)
                    }
                }
                Spacer()
                if server.isLocal, server.account != nil {
                    Button("Logout") {
                        Task { await logout() }
                    }
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .settingsRowBackground()

            if server.isLocal, hasStoredApiKey {
                Text("Local OpenAI API key is saved.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textPrimary)
                    .settingsRowBackground()
            }

            if server.isLocal, hasStoredBaseURL {
                Text("OpenAI-compatible base URL is saved.")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textPrimary)
                    .settingsRowBackground()
            }

            if server.isLocal, !isChatGPTAccount {
                Button {
                    Task {
                        isAuthWorking = true
                        await loginWithChatGPT()
                        isAuthWorking = false
                    }
                } label: {
                    HStack {
                        if isAuthWorking {
                            ProgressView().tint(LitterTheme.textPrimary).scaleEffect(0.8)
                        }
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Login with ChatGPT")
                            .litterFont(.body)
                    }
                    .foregroundColor(LitterTheme.textPrimary)
                }
                .disabled(isAuthWorking)
                .settingsRowBackground()
            }

            if server.isLocal, allowsLocalEnvApiKey {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasStoredApiKey {
                            Text("OpenAI API key saved in the local environment.")
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textSecondary)
                        } else if isChatGPTAccount {
                            Text("Save an API key in the local Codex environment.")
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        SecureField("sk-...", text: $apiKey)
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button {
                        let key = apiKey.trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        Task {
                            isAuthWorking = true
                            await saveApiKey(key)
                            isAuthWorking = false
                        }
                    } label: {
                        Text(hasStoredApiKey ? "Update API Key" : "Save API Key")
                    }
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textPrimary)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isAuthWorking)
                }
                .settingsRowBackground()

                VStack(alignment: .leading, spacing: 8) {
                    if hasStoredBaseURL {
                        Text("Custom OpenAI-compatible endpoint saved for the local Codex server.")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textSecondary)
                    } else {
                        Text("Optional OpenAI-compatible endpoint for local models.")
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                    HStack(spacing: 8) {
                        TextField("http://host:port/v1", text: $openAIBaseURL)
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button {
                            let baseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                isAuthWorking = true
                                await saveBaseURL(baseURL)
                                isAuthWorking = false
                            }
                        } label: {
                            Text(hasStoredBaseURL ? "Update Base URL" : "Save Base URL")
                        }
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textPrimary)
                        .disabled(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthWorking)
                    }
                    if hasStoredBaseURL {
                        Button("Clear Base URL") {
                            Task {
                                isAuthWorking = true
                                await clearBaseURL()
                                isAuthWorking = false
                            }
                        }
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.danger)
                        .disabled(isAuthWorking)
                    }
                }
                .settingsRowBackground()
            }

            if let authError {
                Text(authError)
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.danger)
                    .settingsRowBackground()
            }
        } header: {
            SettingsSectionHeader("Account")
        }
        .task(id: server.serverId) {
            refreshStoredCredentialFlags()
            await refreshAuthStatusIfNeeded()
        }
    }

    private var allowsLocalEnvApiKey: Bool {
        server.isLocal
    }

    private var isChatGPTAccount: Bool {
        if case .chatgpt? = server.account {
            return true
        }
        return false
    }

    private var hasStoredLocalCredentials: Bool {
        hasStoredApiKey || hasStoredChatGPTTokens
    }

    private var authColor: Color {
        switch server.account {
        case .chatgpt?, .apiKey?:
            return LitterTheme.textSecondary
        case nil where server.isLocal && (hasStoredChatGPTTokens || hasStoredApiKey):
            return LitterTheme.meta
        case nil:
            return LitterTheme.textMuted
        }
    }

    private var authTitle: String {
        switch server.account {
        case .chatgpt(let email, _)?:
            return email.isEmpty ? "ChatGPT" : email
        case .apiKey?:
            return "API Key"
        case nil where server.isLocal && hasStoredChatGPTTokens:
            return "ChatGPT"
        case nil where server.isLocal && hasStoredApiKey:
            return "API Key"
        case nil:
            return "Not logged in"
        }
    }

    private var authSubtitle: String? {
        switch server.account {
        case .chatgpt?:
            return "ChatGPT account"
        case .apiKey?:
            return "OpenAI API key"
        case nil where server.isLocal && hasStoredChatGPTTokens:
            return "Stored locally; restoring session"
        case nil where server.isLocal && hasStoredApiKey:
            return "Saved locally; refreshing local account"
        case nil:
            return nil
        }
    }

    private func loginWithChatGPT() async {
        guard server.isLocal else {
            authError = "Settings login is only available for the local server."
            return
        }
        do {
            authError = nil
            try await appModel.loginLocalChatGPTAccount(serverId: server.serverId)
        } catch ChatGPTOAuthError.cancelled {
            return
        } catch {
            authError = error.localizedDescription
        }
    }

    private func refreshStoredCredentialFlags() {
        hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
        hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
        do {
            hasStoredChatGPTTokens = try ChatGPTOAuthTokenStore.shared.load() != nil
        } catch let error as ChatGPTOAuthError where error.isTransientKeychainAvailabilityFailure {
            hasStoredChatGPTTokens = false
        } catch {
            hasStoredChatGPTTokens = false
        }
    }

    private func refreshAuthStatusIfNeeded() async {
        guard server.isLocal, server.account == nil else { return }
        guard hasStoredLocalCredentials else { return }
        await appModel.restoreStoredLocalAuthState(serverId: server.serverId)
        await refreshAccount()
    }

    private func refreshAccount() async {
        do {
            _ = try await appModel.client.refreshAccount(
                serverId: server.serverId,
                params: AppRefreshAccountRequest(refreshToken: false)
            )
            await appModel.refreshSnapshot()
            refreshStoredCredentialFlags()
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func saveApiKey(_ key: String) async {
        guard server.isLocal else {
            authError = "API keys can only be saved for the local server."
            return
        }
        do {
            authError = nil
            try OpenAIApiKeyStore.shared.save(key)
            if case .apiKey? = server.account {
                _ = try await appModel.client.logoutAccount(serverId: server.serverId)
            }
            try await appModel.restartLocalServer()
            refreshStoredCredentialFlags()
            guard hasStoredApiKey else {
                authError = "API key did not persist locally."
                return
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    private func saveBaseURL(_ rawBaseURL: String) async {
        guard server.isLocal else {
            authError = "Base URL can only be saved for the local server."
            return
        }
        guard let baseURL = normalizedOpenAIBaseURL(rawBaseURL) else {
            authError = "Enter a valid http or https base URL."
            return
        }
        do {
            authError = nil
            try OpenAIApiKeyStore.shared.saveBaseURL(baseURL)
            try await appModel.restartLocalServer()
            refreshStoredCredentialFlags()
            guard hasStoredBaseURL else {
                authError = "Base URL did not persist locally."
                return
            }
            openAIBaseURL = ""
        } catch {
            authError = error.localizedDescription
        }
    }

    private func clearBaseURL() async {
        guard server.isLocal else {
            authError = "Base URL can only be cleared for the local server."
            return
        }
        do {
            authError = nil
            try OpenAIApiKeyStore.shared.clearBaseURL()
            try await appModel.restartLocalServer()
            refreshStoredCredentialFlags()
            openAIBaseURL = ""
        } catch {
            authError = error.localizedDescription
        }
    }

    private func normalizedOpenAIBaseURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func logout() async {
        guard server.isLocal else {
            authError = "Settings logout is only available for the local server."
            return
        }
        do {
            try? ChatGPTOAuthTokenStore.shared.clear()
            try? OpenAIApiKeyStore.shared.clear()
            _ = try await appModel.client.logoutAccount(serverId: server.serverId)
            try await appModel.restartLocalServer()
            refreshStoredCredentialFlags()
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }
}

private struct SettingsDisconnectedAccountSection: View {
    var body: some View {
        Section {
            Text("Local Codex isn't running. ChatGPT login and API key entry require the local bridge.")
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textMuted)
                .settingsRowBackground()
        } header: {
            SettingsSectionHeader("Account")
        }
    }
}

private func isSettingsSlingshotURL(_ rawURL: String) -> Bool {
    URL(string: rawURL)?.scheme?.lowercased() == "slingshot"
}

// MARK: - Shared settings rows

/// Icon + title + optional trailing value: the one row shape used by every
/// settings list (T3/iOS Settings pattern).
struct SettingsRowLabel: View {
    static let iconWidth: CGFloat = 26

    let title: String
    var systemImage: String? = nil
    var value: String? = nil

    var body: some View {
        HStack(spacing: LitterSpace.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .litterFont(.body)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .frame(width: Self.iconWidth)
                    .accessibilityHidden(true)
            }
            Text(title)
                .litterFont(.body)
                .foregroundStyle(LitterTheme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: LitterSpace.s)
            if let value, !value.isEmpty {
                Text(value)
                    .litterFont(.body)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Sentence-case section title shared by every settings list.
struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .litterFont(.footnote, weight: .medium)
            .foregroundColor(LitterTheme.textSecondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Title with an optional one-line explanation, for toggles and pickers.
struct SettingsRowText: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .litterFont(.body)
                .foregroundColor(LitterTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textSecondary)
            }
        }
    }
}

extension View {
    /// Row fill shared by every settings list.
    func settingsRowBackground() -> some View {
        listRowBackground(LitterTheme.surface.opacity(0.6))
    }
}
