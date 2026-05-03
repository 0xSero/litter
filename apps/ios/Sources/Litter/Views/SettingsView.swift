import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @AppStorage("fontFamily") private var fontFamily = FontFamilyOption.mono.rawValue
    @AppStorage("collapseTurns") private var collapseTurns = false
    @State private var showAddServer = false

    private var localServer: AppServerSnapshot? {
        // Account management (ChatGPT login / API key) is local-only, always.
        // If the local Codex bridge hasn't spun up there's no login target, and
        // the caller falls through to `SettingsDisconnectedAccountSection`.
        appModel.snapshot?.servers.first(where: \.isLocal)
    }

    private var connectedServers: [HomeDashboardServer] {
        HomeDashboardSupport.sortedConnectedServers(
            from: appModel.snapshot?.servers ?? [],
            activeServerId: appModel.snapshot?.activeThread?.serverId
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                Form {
                    supportSection
                    appearanceSection
                    fontSection
                    conversationSection
                    petSection
                    experimentalSection
                    accountSection
                    serversSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                }
            }
        .sheet(isPresented: $showAddServer) {
            NavigationStack {
                DiscoveryView(onServerSelected: { _ in
                    showAddServer = false
                })
            }
            .environment(appModel)
            .environment(appState)
            .environment(\.textScale, textScale)
        }
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        Section {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paintbrush")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Appearance")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Theme")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Conversation Section

    private var conversationSection: some View {
        Section {
            Toggle(isOn: $collapseTurns) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Collapse Turns")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                        Text("Collapse previous turns into cards")
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
            }
            .tint(LitterTheme.accent)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Conversation")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Font Section

    private var fontSection: some View {
        Section {
            ForEach(FontFamilyOption.allCases) { option in
                Button {
                    fontFamily = option.rawValue
                    ThemeManager.shared.syncFontPreference()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.displayName)
                                .litterFont(.subheadline)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text("The quick brown fox")
                                .font(LitterFont.sampleFont(family: option, size: 14))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if fontFamily == option.rawValue {
                            Image(systemName: "checkmark")
                                .litterFont(.subheadline, weight: .semibold)
                                .foregroundColor(LitterTheme.accentStrong)
                        }
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Font")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Experimental Section

    private var petSection: some View {
        Section {
            NavigationLink {
                PetSettingsView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pawprint.fill")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wake Pet")
                            .litterFont(.subheadline)
                            .foregroundColor(LitterTheme.textPrimary)
                        if let pet = PetOverlayController.shared.selectedPet {
                            Text(pet.displayName)
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                    }
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Pet")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Experimental Section

    private var experimentalSection: some View {
        Section {
            NavigationLink {
                ExperimentalFeaturesView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "flask")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Experimental Features")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Experimental")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

    // MARK: - Support Section

    private var supportSection: some View {
        Section {
            NavigationLink {
                TipJarView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pawprint.fill")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Tip the Kitty")
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Support")
                .foregroundColor(LitterTheme.textSecondary)
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

    // MARK: - Servers Section

    private var serversSection: some View {
        Section {
            if connectedServers.isEmpty {
                Text("No servers connected")
                    .litterFont(.footnote)
                    .foregroundColor(LitterTheme.textMuted)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            } else {
                ForEach(connectedServers, id: \.id) { conn in
                    HStack {
                        Image(systemName: conn.isLocal ? "iphone" : "server.rack")
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conn.displayName)
                                .litterFont(.footnote)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(conn.health.displayLabel)
                                .litterFont(.caption)
                                .foregroundColor(conn.health.accentColor)
                        }
                        Spacer()
                        Button("Remove") {
                            SavedServerStore.remove(serverId: conn.id)
                            Task { await SshSessionStore.shared.close(serverId: conn.id, ssh: appModel.ssh) }
                            appModel.serverBridge.disconnectServer(serverId: conn.id)
                        }
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.danger)
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            }

            Button {
                showAddServer = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(LitterTheme.accent)
                        .frame(width: 20)
                    Text("Add Server")
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.accent)
                    Spacer()
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Servers")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }

}

private struct SettingsConnectionAccountSection: View {
    @Environment(AppModel.self) private var appModel
    let server: AppServerSnapshot
    @State private var apiKey = ""
    @State private var isAuthWorking = false
    @State private var authError: String?
    @State private var hasStoredApiKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var hasStoredChatGPTTokens = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(authColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authTitle)
                        .litterFont(.subheadline)
                        .foregroundColor(LitterTheme.textPrimary)
                    if let sub = authSubtitle {
                        Text(sub)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                Spacer()
                if server.isLocal, server.account != nil {
                    Button("Logout") {
                        Task { await logout() }
                    }
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
                }
            }
            .listRowBackground(LitterTheme.surface.opacity(0.6))

            if server.isLocal, hasStoredApiKey {
                Text("Local OpenAI API key is saved.")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
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
                            .litterFont(.subheadline)
                    }
                    .foregroundColor(LitterTheme.accent)
                }
                .disabled(isAuthWorking)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if server.isLocal, allowsLocalEnvApiKey {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasStoredApiKey {
                            Text("OpenAI API key saved in the local environment.")
                                .litterFont(.caption)
                                .foregroundColor(LitterTheme.textSecondary)
                        } else if isChatGPTAccount {
                            Text("Save an API key in the local Codex environment.")
                                .litterFont(.caption)
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
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.accent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isAuthWorking)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if let authError {
                Text(authError)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Account")
                .foregroundColor(LitterTheme.textSecondary)
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
        case .chatgpt?:
            return LitterTheme.accent
        case .apiKey?:
            return Color(hex: "#00AAFF")
        case nil where server.isLocal && hasStoredChatGPTTokens:
            return LitterTheme.accent.opacity(0.7)
        case nil where server.isLocal && hasStoredApiKey:
            return Color(hex: "#00AAFF").opacity(0.7)
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
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textMuted)
                .listRowBackground(LitterTheme.surface.opacity(0.6))
        } header: {
            Text("Account")
                .foregroundColor(LitterTheme.textSecondary)
        }
    }
}

#if DEBUG
#Preview("Settings") {
    LitterPreviewScene(includeBackground: false) {
        SettingsView()
    }
}
#endif
