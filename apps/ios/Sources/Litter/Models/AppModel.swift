import Foundation
import Observation
import UIKit
import os

enum LocalAccountLoginFlowError: LocalizedError {
    case localServerUnavailable
    case remoteServer
    case loginDidNotAttach

    var errorDescription: String? {
        switch self {
        case .localServerUnavailable:
            return "Local Codex isn't running. ChatGPT login requires the local bridge."
        case .remoteServer:
            return "ChatGPT login is only available for the local server."
        case .loginDidNotAttach:
            return "ChatGPT login completed, but the local account did not attach."
        }
    }
}

@MainActor
@Observable
final class ThreadRebindSignal {
    private(set) var revision: UInt64 = 0
    func bump() { revision &+= 1 }
}

@MainActor
@Observable
final class AppModel {
    private struct PendingThreadStateEvent: Sendable {
        let state: AppThreadStateRecord
        let sessionSummary: AppSessionSummary
        let agentDirectoryVersion: UInt64
    }

    private struct PendingCommandRowMutation: Sendable {
        let key: ThreadKey
        let itemId: String
        var upsertItem: HydratedConversationItem?
    }

    private static let liveItemMutationCoalescingNanoseconds: UInt64 = 120_000_000 // ~8fps commands
    private static let liveThreadStateCoalescingNanoseconds: UInt64 = 150_000_000  // ~6fps metadata
    private static let localAuthRestoreRetryDelays: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(4)
    ]


    /// Pre-built Rust objects initialized off the main thread to avoid
    /// priority inversion (tokio runtime init blocks at default QoS).
    private struct RustBridges: @unchecked Sendable {
        let store: AppStore
        let client: AppClient
        let serverBridge: ServerBridge
        let ssh: SshBridge
        let reconnectController: ReconnectController
    }

    /// Kick off Rust bridge construction on a background thread.
    /// Call from `AppDelegate.didFinishLaunching` before SwiftUI touches `shared`.
    nonisolated static func prewarmRustBridges() {
        _ = _prewarmResult
    }

    private nonisolated static let _prewarmResult: RustBridges = {
        // Boot the iSH kernel BEFORE any Rust bridge construction so the exec
        // hook is wired up before the first command can be issued. Idempotent
        // — the AppDelegate call site is a no-op on second invocation.
        LitterPlatform.bootstrapLocalRuntimeIfNeeded()

        let rc = ReconnectController()
        rc.setCredentialProvider(provider: SwiftSshCredentialProvider())
        rc.setSlingshotCredentialProvider(provider: SwiftSlingshotCredentialProvider())
        rc.setMultiClankerAndQuicEnabled(enabled: true)
        return RustBridges(
            store: AppStore(),
            client: AppClient(),
            serverBridge: ServerBridge(),
            ssh: SshBridge(),
            reconnectController: rc
        )
    }()

    static let shared = AppModel()

    struct ComposerPrefillRequest: Identifiable, Equatable {
        let id = UUID()
        let threadKey: ThreadKey
        let text: String
    }

    let store: AppStore
    let client: AppClient
    let serverBridge: ServerBridge
    let ssh: SshBridge
    let reconnectController: ReconnectController

    private(set) var snapshot: AppSnapshotRecord? {
        didSet {
            guard oldValue != snapshot else { return }
            snapshotRevision &+= 1
        }
    }
    private(set) var snapshotRevision: UInt64 = 0
    private(set) var conversationGlobalRevision: UInt64 = 0
    @ObservationIgnored private var threadRebindSignals: [ThreadKey: ThreadRebindSignal] = [:]
    func threadRebindSignal(for key: ThreadKey) -> ThreadRebindSignal {
        if let existing = threadRebindSignals[key] { return existing }
        let signal = ThreadRebindSignal()
        threadRebindSignals[key] = signal
        return signal
    }
    private(set) var lastError: String?
    private(set) var composerPrefillRequest: ComposerPrefillRequest?

    @ObservationIgnored private var subscription: AppStoreSubscription?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var loadingModelServerIds: Set<String> = []
    @ObservationIgnored private var modelCatalogErrorsByServer: [String: String] = [:]
    @ObservationIgnored private var loadingRateLimitServerIds: Set<String> = []
    @ObservationIgnored private var pendingThreadRefreshKeys: Set<ThreadKey> = []
    @ObservationIgnored private var pendingThreadRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActiveThreadHydrationKey: ThreadKey?
    @ObservationIgnored private var pendingActiveThreadHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSnapshotRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingThreadStateEvents: [ThreadKey: PendingThreadStateEvent] = [:]
    @ObservationIgnored private var pendingThreadStateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCommandRowMutations: [String: PendingCommandRowMutation] = [:]
    @ObservationIgnored private var pendingCommandRowMutationTask: Task<Void, Never>?
    @ObservationIgnored private var cachedThreadSnapshots: [ThreadKey: AppThreadSnapshot] = [:]
    @ObservationIgnored private var loadingTurnPageThreadKeys: Set<ThreadKey> = []
    private(set) var pendingHandoffTurnErrors: [ThreadKey: String] = [:]

    func reportHandoffTurnError(key: ThreadKey, message: String) {
        pendingHandoffTurnErrors[key] = message
    }

    func clearHandoffTurnError(for key: ThreadKey) {
        pendingHandoffTurnErrors.removeValue(forKey: key)
    }

    init(
        store: AppStore? = nil,
        client: AppClient? = nil,
        serverBridge: ServerBridge? = nil,
        ssh: SshBridge? = nil,
        reconnectController: ReconnectController? = nil
    ) {
        let bridges = Self._prewarmResult
        self.store = store ?? bridges.store
        self.client = client ?? bridges.client
        self.serverBridge = serverBridge ?? bridges.serverBridge
        self.ssh = ssh ?? bridges.ssh
        self.reconnectController = reconnectController ?? bridges.reconnectController

        // Register the saved-apps directory with the Rust client so the
        // dynamic-tool finalize hook can auto-upsert on `show_widget` calls.
        // Without this, auto-save silently no-ops.
        self.client.setSavedAppsDirectory(directory: SavedAppsDirectory.path)
        self.client.setSlingshotCredentialsDirectory(directory: MobilePreferencesDirectory.path)

        // Route Swift presentation lookups through the Rust-owned
        // `AgentMetadataStore`. Any view rendering an agent label /
        // icon / capability flag goes through this single shared
        // client, so a probe response in one screen surfaces metadata
        // everywhere.
        let metadataClient = self.client
        AgentRuntimeMetadataProvider.lookup = { [weak metadataClient] name in
            metadataClient?.agentMetadata(name: name)
        }
        AgentRuntimeMetadataProvider.all = { [weak metadataClient] in
            metadataClient?.allAgentMetadata() ?? []
        }
    }

    deinit {
        updateTask?.cancel()
        pendingThreadRefreshTask?.cancel()
        pendingActiveThreadHydrationTask?.cancel()
        pendingSnapshotRefreshTask?.cancel()
        pendingThreadStateTask?.cancel()
        pendingCommandRowMutationTask?.cancel()
    }

    func start() {
        guard updateTask == nil else { return }
        let subscription = store.subscribeUpdates()
        self.subscription = subscription
        updateTask = Task.detached(priority: .userInitiated) { [weak self, subscription] in
            guard let self else { return }
            await self.refreshSnapshot()
            while !Task.isCancelled {
                do {
                    let update = try await subscription.nextUpdate()
                    await self.handleStoreUpdate(update)
                } catch {
                    if Task.isCancelled { break }
                    await self.recordStoreSubscriptionError(error)
                    break
                }
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        pendingThreadRefreshTask?.cancel()
        pendingThreadRefreshTask = nil
        pendingThreadRefreshKeys.removeAll()
        pendingActiveThreadHydrationTask?.cancel()
        pendingActiveThreadHydrationTask = nil
        pendingActiveThreadHydrationKey = nil
        pendingSnapshotRefreshTask?.cancel()
        pendingSnapshotRefreshTask = nil
        pendingThreadStateTask?.cancel()
        pendingThreadStateTask = nil
        pendingThreadStateEvents.removeAll()
        pendingCommandRowMutationTask?.cancel()
        pendingCommandRowMutationTask = nil
        pendingCommandRowMutations.removeAll()
        subscription = nil
    }

    func refreshSnapshot() async {
        pendingSnapshotRefreshTask?.cancel()
        pendingSnapshotRefreshTask = nil
        await performSnapshotRefresh()
    }

    private func performSnapshotRefresh() async {
        #if DEBUG
        guard !debugFixtureActive else { return }
        #endif
        do {
            applySnapshot(try await store.snapshot())
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func recordStoreSubscriptionError(_ error: Error) {
        lastError = error.localizedDescription
    }

    private func scheduleSnapshotRefreshDebounced() {
        guard pendingSnapshotRefreshTask == nil else { return }
        pendingSnapshotRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.pendingSnapshotRefreshTask = nil
            await self.performSnapshotRefresh()
        }
    }

    func activateThread(_ key: ThreadKey?) {
        restoreCachedThreadSnapshotIfNeeded(for: key)
        updateActiveThread(key)
        store.setActiveThread(key: key)
        scheduleDeferredActiveThreadHydrationIfNeeded(for: key)
    }

    func resumeThread(
        key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) async throws -> ThreadKey {
        await restoreStoredLocalAuthIfNeeded(serverId: key.serverId, reason: "resumeThread")

        let trimmedCwdOverride = cwdOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresResumeOverrides = requiresResumeOverrides(
            for: key,
            launchConfig: launchConfig,
            cwdOverride: trimmedCwdOverride
        )
        let requiresDistinctCwdOverride = requiresResumeCwdOverride(
            for: key,
            cwdOverride: trimmedCwdOverride
        )

        if requiresResumeOverrides {
            return try await client.resumeThread(
                serverId: key.serverId,
                params: launchConfig.threadResumeRequest(
                    threadId: key.threadId,
                    cwdOverride: requiresDistinctCwdOverride ? trimmedCwdOverride : nil
                )
            )
        }

        // No overrides: let Rust do a normal external resume/read path.
        try await store.externalResumeThread(key: key, hostId: nil)
        return key
    }

    func reloadThread(
        key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) async throws -> ThreadKey {
        await restoreStoredLocalAuthIfNeeded(serverId: key.serverId, reason: "reloadThread")

        let trimmedCwdOverride = cwdOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresResumeOverrides = requiresResumeOverrides(
            for: key,
            launchConfig: launchConfig,
            cwdOverride: trimmedCwdOverride
        )
        let requiresDistinctCwdOverride = requiresResumeCwdOverride(
            for: key,
            cwdOverride: trimmedCwdOverride
        )

        if requiresResumeOverrides {
            return try await client.resumeThread(
                serverId: key.serverId,
                params: launchConfig.threadResumeRequest(
                    threadId: key.threadId,
                    cwdOverride: requiresDistinctCwdOverride ? trimmedCwdOverride : nil
                )
            )
        }

        // No overrides: let Rust do a normal external resume/read path.
        try await store.externalResumeThread(key: key, hostId: nil)
        return key
    }

    /// Force a fresh resume so the store reconciles `active_turn_id`
    /// against the server's authoritative view. Use after a long resume /
    /// push wake — the in-flight turn may have advanced or completed during
    /// the background window with item or terminal events not delivered.
    ///
    /// On v0.125+ remotes this runs `thread/resume` with
    /// `excludeTurns: true`, then a tiny skeleton probe and a bounded full
    /// repair page when the local turn was active. Legacy remotes that don't
    /// implement `thread/turns/list` still get the embedded turn list via
    /// `excludeTurns: false`.
    func forceRefreshThreadAuthoritative(key: ThreadKey) async throws {
        try await store.forceRefreshThreadAuthoritative(key: key)
    }

    func refreshThreadIncludingTurns(key: ThreadKey) async throws -> ThreadKey {
        do {
            // 1. Refresh thread metadata only — title, status, model,
            //    active_turn_id, etc. The full historical turn list is
            //    append-only on the server, so we don't need to re-pull it
            //    here. Sending `include_turns: true` would have the server
            //    reconstruct the entire rollout in one response, which is
            //    unbounded and OOMs the device on long threads.
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: false
                )
            )
            // 2. Reload the most-recent N turns via the paginated path. On
            //    v0.125+ remotes this hits `thread/turns/list` (bounded by
            //    `initialTurnPageSize`). On older remotes that don't
            //    implement `thread/turns/list`, the Rust client transparently
            //    falls back to `thread/resume(excludeTurns: false)` which
            //    pulls the embedded turn list — preserving the prior
            //    reload-button behavior for legacy servers.
            await loadInitialTurns(threadId: nextKey)
            if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                await refreshThreadSnapshot(key: nextKey)
            }
            return nextKey
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func requiresResumeCwdOverride(
        for key: ThreadKey,
        cwdOverride: String?
    ) -> Bool {
        guard let normalizedOverride = cwdOverride, !normalizedOverride.isEmpty else {
            return false
        }

        let existingCwd =
            threadSnapshot(for: key)?.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? snapshot?.sessionSummary(for: key)?.cwd.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let existingCwd, !existingCwd.isEmpty else {
            return true
        }
        return existingCwd != normalizedOverride
    }

    private func requiresResumeOverrides(
        for key: ThreadKey,
        launchConfig: AppThreadLaunchConfig,
        cwdOverride: String?
    ) -> Bool {
        if !(launchConfig.developerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return true
        }
        if !launchConfig.persistExtendedHistory {
            return true
        }
        if requiresResumeCwdOverride(for: key, cwdOverride: cwdOverride) {
            return true
        }

        guard let existingThread = threadSnapshot(for: key) else {
            let existingModel = snapshot?.sessionSummary(for: key)?.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedModel = launchConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let requestedModel, !requestedModel.isEmpty, requestedModel != existingModel {
                return true
            }
            return launchConfig.approvalPolicy != nil
                || launchConfig.sandbox != nil
        }

        let requestedModel = launchConfig.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingModel = (existingThread.model ?? existingThread.info.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedModel, !requestedModel.isEmpty, requestedModel != existingModel {
            return true
        }
        if let requestedApproval = launchConfig.approvalPolicy,
           requestedApproval != existingThread.effectiveApprovalPolicy {
            return true
        }
        if let requestedSandbox = launchConfig.sandbox,
           requestedSandbox != existingThread.effectiveSandboxPolicy?.launchOverrideMode {
            return true
        }
        return false
    }

    /// True if the given `serverId` resolves to a local-server snapshot
    /// entry. Used at every `startThread` call site to gate the generative-UI
    /// dynamic tools (show_widget / visualize_read_me) so remote servers
    /// never see them.
    func isLocalServer(serverId: String) -> Bool {
        snapshot?.servers.first(where: { $0.serverId == serverId })?.isLocal == true
    }

    /// `generativeUiDynamicToolSpecs()` when `serverId` is a local server,
    /// otherwise `nil`. Use this to construct the `dynamicTools` field on
    /// any thread-start request.
    func localGenerativeUiToolSpecs(for serverId: String) -> [AppDynamicToolSpec]? {
        isLocalServer(serverId: serverId) ? generativeUiDynamicToolSpecs() : nil
    }

    func loginLocalChatGPTAccount(serverId: String) async throws {
        guard let server = snapshot?.serverSnapshot(for: serverId) else {
            throw LocalAccountLoginFlowError.localServerUnavailable
        }
        guard server.isLocal else {
            throw LocalAccountLoginFlowError.remoteServer
        }

        let tokens = try await ChatGPTOAuth.login()
        _ = try await client.loginAccount(
            serverId: serverId,
            params: .chatgptAuthTokens(
                accessToken: tokens.accessToken,
                chatgptAccountId: tokens.accountID,
                chatgptPlanType: tokens.planType
            )
        )
        await refreshSnapshot()
    }

    func ensureLocalAuthForThreadStart(serverId: String) async throws -> Bool {
        guard let server = snapshot?.serverSnapshot(for: serverId) else {
            return true
        }
        guard server.isLocal else {
            return true
        }
        guard server.account == nil else {
            return true
        }

        if await restoreStoredLocalAuthIfNeeded(serverId: serverId, reason: "startThread") {
            return true
        }

        do {
            try await loginLocalChatGPTAccount(serverId: serverId)
        } catch ChatGPTOAuthError.cancelled {
            return false
        }

        guard snapshot?.serverSnapshot(for: serverId)?.account != nil else {
            throw LocalAccountLoginFlowError.loginDidNotAttach
        }
        return true
    }

    @discardableResult
    private func restoreStoredLocalAuthIfNeeded(serverId: String, reason: String) async -> Bool {
        guard let server = snapshot?.serverSnapshot(for: serverId), server.isLocal else {
            return false
        }
        guard server.account == nil else {
            return false
        }
        let storedApiKey = await loadStoredLocalApiKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTokens = await loadStoredLocalChatGPTTokens()
        guard storedTokens != nil || storedApiKey?.isEmpty == false else {
            return false
        }

        LLog.info(
            "auth",
            "restoring stored local auth before local session operation",
            fields: [
                "serverId": serverId,
                "reason": reason
            ]
        )
        await restoreStoredLocalAuthState(serverId: serverId)
        return snapshot?.serverSnapshot(for: serverId)?.account != nil
    }

    func resolvedLocalServerDisplayName() -> String {
        let connectedLocalName = snapshot?.servers
            .first(where: \.isLocal)
            .flatMap { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let connectedLocalName, !connectedLocalName.isEmpty, connectedLocalName != "This Device" {
            return connectedLocalName
        }

        let savedLocalName = SavedServerStore.load()
            .first(where: { $0.id == "local" || $0.source == .local })
            .flatMap { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let savedLocalName, !savedLocalName.isEmpty, savedLocalName != "This Device" {
            return savedLocalName
        }

        return LitterPlatform.localRuntimeDisplayName()
    }

    func restartLocalServer() async throws {
        let currentLocal = snapshot?.servers.first(where: \.isLocal)
        let serverId = currentLocal?.serverId ?? "local"
        let displayName = resolvedLocalServerDisplayName()
        serverBridge.disconnectServer(serverId: serverId)
        _ = try await serverBridge.connectLocalServer(
            serverId: serverId,
            displayName: displayName,
            host: "127.0.0.1",
            port: 0
        )
        await restoreStoredLocalAuthState(serverId: serverId)
        await refreshSnapshot()
    }

    func restoreStoredLocalAuthState(serverId: String) async {
        let storedApiKey: String?
        if let rawApiKey = await loadStoredLocalApiKey() {
            let trimmedApiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            storedApiKey = trimmedApiKey.isEmpty ? nil : trimmedApiKey
        } else {
            storedApiKey = nil
        }
        let storedTokens = await loadStoredLocalChatGPTTokens()

        guard storedApiKey != nil || storedTokens != nil else { return }

        for attempt in 0...Self.localAuthRestoreRetryDelays.count {
            if let storedTokens,
               await restoreStoredLocalChatGPTAuth(
                serverId: serverId,
                storedTokens: storedTokens
               ) {
                await refreshSnapshot()
                return
            }

            if let storedApiKey {
                OpenAIApiKeyStore.shared.applyToEnvironment()
                if await loginStoredLocalApiKeyAuth(serverId: serverId, apiKey: storedApiKey) {
                    await refreshSnapshot()
                    return
                }
            }

            guard attempt < Self.localAuthRestoreRetryDelays.count else { break }
            let delay = Self.localAuthRestoreRetryDelays[attempt]
            LLog.warn(
                "auth",
                "stored local auth restore did not stick; retrying after startup delay",
                fields: [
                    "serverId": serverId,
                    "attempt": attempt + 1,
                    "delaySeconds": delay.components.seconds
                ]
            )
            try? await Task.sleep(for: delay)
        }

        guard storedApiKey != nil else { return }
        OpenAIApiKeyStore.shared.applyToEnvironment()
        guard await reconnectLocalServerForStoredApiKeyRestore(serverId: serverId) else { return }
        if let storedApiKey, await loginStoredLocalApiKeyAuth(serverId: serverId, apiKey: storedApiKey) {
            await refreshSnapshot()
        }
    }

    func restoreMissingLocalAuthStateIfNeeded() async {
        guard let snapshot else { return }
        let localServerIds = snapshot.servers
            .filter { $0.isLocal && $0.account == nil }
            .map(\.serverId)

        guard !localServerIds.isEmpty else { return }

        for serverId in localServerIds {
            await restoreStoredLocalAuthState(serverId: serverId)
        }
        await refreshSnapshot()
    }

    private func loadStoredLocalApiKey() async -> String? {
        do {
            return try OpenAIApiKeyStore.shared.load()
        } catch let error as NSError where isTransientLocalKeychainFailure(error) {
            for delay in [0.5, 1.0, 2.0] {
                LLog.warn(
                    "auth",
                    "local OpenAI API key unavailable until keychain unlock; retrying",
                    fields: ["delaySeconds": delay]
                )
                try? await Task.sleep(for: .seconds(delay))
                do {
                    return try OpenAIApiKeyStore.shared.load()
                } catch let retryError as NSError where isTransientLocalKeychainFailure(retryError) {
                    continue
                } catch {
                    LLog.error(
                        "auth",
                        "loading stored local OpenAI API key failed",
                        fields: ["error": String(describing: error)]
                    )
                    return nil
                }
            }
            return nil
        } catch {
            LLog.error(
                "auth",
                "loading stored local OpenAI API key failed",
                fields: ["error": error.localizedDescription]
            )
            return nil
        }
    }

    private func isTransientLocalKeychainFailure(_ error: NSError) -> Bool {
        guard error.domain == NSOSStatusErrorDomain else { return false }
        return error.code == Int(errSecInteractionNotAllowed)
            || error.code == Int(errSecNotAvailable)
    }

    private func restoreStoredLocalChatGPTAuth(
        serverId: String,
        storedTokens: ChatGPTOAuthTokenBundle
    ) async -> Bool {
        let refreshedTokens = try? await ChatGPTOAuth.refreshStoredTokens(
            previousAccountID: nil,
            storedTokens: storedTokens
        )
        if let refreshedTokens,
           await loginStoredLocalChatGPTAuth(serverId: serverId, tokens: refreshedTokens) {
            return true
        }

        if await loginStoredLocalChatGPTAuth(serverId: serverId, tokens: storedTokens) {
            return true
        }

        guard refreshedTokens == nil else {
            return false
        }

        try? await Task.sleep(for: .seconds(2))
        if let retriedRefresh = try? await ChatGPTOAuth.refreshStoredTokens(
            previousAccountID: nil,
            storedTokens: storedTokens
        ) {
            return await loginStoredLocalChatGPTAuth(serverId: serverId, tokens: retriedRefresh)
        }
        return false
    }

    private func loginStoredLocalApiKeyAuth(serverId: String, apiKey: String) async -> Bool {
        do {
            _ = try await client.loginAccount(
                serverId: serverId,
                params: .apiKey(apiKey: apiKey)
            )
            lastError = nil
            return true
        } catch {
            LLog.warn(
                "auth",
                "restoring stored local API key auth failed",
                fields: [
                    "serverId": serverId,
                    "error": error.localizedDescription
                ]
            )
            return false
        }
    }

    private func reconnectLocalServerForStoredApiKeyRestore(serverId: String) async -> Bool {
        guard let localServer = snapshot?.servers.first(where: { $0.serverId == serverId && $0.isLocal })
            ?? snapshot?.servers.first(where: \.isLocal) else {
            return false
        }

        LLog.warn(
            "auth",
            "reconnecting local server to re-inherit stored API key environment",
            fields: ["serverId": serverId]
        )

        serverBridge.disconnectServer(serverId: localServer.serverId)

        do {
            _ = try await serverBridge.connectLocalServer(
                serverId: localServer.serverId,
                displayName: resolvedLocalServerDisplayName(),
                host: "127.0.0.1",
                port: 0
            )
            return true
        } catch {
            LLog.warn(
                "auth",
                "reconnecting local server for stored API key restore failed",
                fields: [
                    "serverId": serverId,
                    "error": error.localizedDescription
                ]
            )
            return false
        }
    }

    private func loadStoredLocalChatGPTTokens() async -> ChatGPTOAuthTokenBundle? {
        do {
            return try ChatGPTOAuthTokenStore.shared.load()
        } catch let error as ChatGPTOAuthError where error.isTransientKeychainAvailabilityFailure {
            for delay in [0.5, 1.0, 2.0] {
                LLog.warn(
                    "auth",
                    "local ChatGPT auth tokens unavailable until keychain unlock; retrying",
                    fields: ["delaySeconds": delay]
                )
                try? await Task.sleep(for: .seconds(delay))
                do {
                    return try ChatGPTOAuthTokenStore.shared.load()
                } catch let retryError as ChatGPTOAuthError where retryError.isTransientKeychainAvailabilityFailure {
                    continue
                } catch {
                    LLog.error(
                        "auth",
                        "loading stored local ChatGPT auth tokens failed",
                        fields: ["error": String(describing: error)]
                    )
                    return nil
                }
            }
            return nil
        } catch {
            LLog.error(
                "auth",
                "loading stored local ChatGPT auth tokens failed",
                fields: ["error": error.localizedDescription]
            )
            return nil
        }
    }

    private func loginStoredLocalChatGPTAuth(
        serverId: String,
        tokens: ChatGPTOAuthTokenBundle
    ) async -> Bool {
        do {
            _ = try await client.loginAccount(
                serverId: serverId,
                params: .chatgptAuthTokens(
                    accessToken: tokens.accessToken,
                    chatgptAccountId: tokens.accountID,
                    chatgptPlanType: tokens.planType
                )
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func applySnapshot(_ snapshot: AppSnapshotRecord?) {
        let normalizedSnapshot = snapshot.map(normalizingLocalServerDisplayNames)
        let mergedSnapshot = normalizedSnapshot.map(mergingCachedThreadSnapshots)
        let revisionBefore = snapshotRevision
        self.snapshot = mergedSnapshot
        if snapshotRevision != revisionBefore { conversationGlobalRevision &+= 1 }
        if let mergedSnapshot {
            persistWakeMACs(from: mergedSnapshot.servers)
            mergedSnapshot.threads.forEach(cacheThreadSnapshot)
            lastError = nil
        }
    }

    private func persistWakeMACs(from servers: [AppServerSnapshot]) {
        for server in servers {
            SavedServerStore.updateWakeMAC(
                serverId: server.serverId,
                host: server.host,
                wakeMAC: server.wakeMac
            )
        }
    }

    private func normalizingLocalServerDisplayNames(_ snapshot: AppSnapshotRecord) -> AppSnapshotRecord {
        var snapshot = snapshot
        let fallbackName = LitterPlatform.localRuntimeDisplayName()
        for index in snapshot.servers.indices {
            guard snapshot.servers[index].isLocal else { continue }
            let displayName = snapshot.servers[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayName.isEmpty || displayName == "This Device" {
                snapshot.servers[index].displayName = fallbackName
            }
        }
        return snapshot
    }

    private func handleStoreUpdate(_ update: AppStoreUpdateRecord) async {
        #if DEBUG
        let debugArrival = debugIngressArrival(update)
        #endif
        switch update {
        case .threadUpserted(let thread, let sessionSummary, let agentDirectoryVersion):
            applyThreadUpsert(
                thread,
                sessionSummary: sessionSummary,
                agentDirectoryVersion: agentDirectoryVersion
            )
        case .threadMetadataChanged(let state, let sessionSummary, let agentDirectoryVersion):
            if shouldBatchLiveThreadStateUpdate(for: state.key) {
                enqueueThreadStateUpdate(
                    state,
                    sessionSummary: sessionSummary,
                    agentDirectoryVersion: agentDirectoryVersion
                )
            } else {
                applyThreadStateUpdated(
                    state,
                    sessionSummary: sessionSummary,
                    agentDirectoryVersion: agentDirectoryVersion
                )
            }
        case .threadItemChanged(let key, let item, let sessionSummary):
            let isBatched = shouldBatchCommandRowMutation(for: key, item: item)
            if isBatched {
                enqueueCommandRowUpsert(key: key, item: item)
            } else if !applyThreadItemUpsert(key: key, item: item) {
                scheduleThreadSnapshotRefresh(for: key)
            }
            // Reducer piggybacks the refreshed per-thread summary on every
            // item change, so the home dashboard's session-summary driven
            // fields (stats, last tool label, etc.) stay in sync with the
            // stream without waiting for a full snapshot rebuild.
            applySessionSummary(sessionSummary)
        case .threadStreamingDelta(let key, let itemId, let kind, let text):
            switch kind {
            case .assistantText:
                if !applyThreadStreamingDelta(key: key, itemId: itemId, kind: kind, text: text) {
                    scheduleThreadSnapshotRefresh(for: key)
                }
                StreamingRendererCoordinator.shared.appendDelta(text, for: itemId)
            default:
                if !applyThreadStreamingDelta(key: key, itemId: itemId, kind: kind, text: text) {
                    scheduleThreadSnapshotRefresh(for: key)
                }
            }
        case .threadRemoved(let key, let agentDirectoryVersion):
            removeThreadSnapshot(for: key, agentDirectoryVersion: agentDirectoryVersion)
        case .activeThreadChanged(let key):
            updateActiveThread(key)
            conversationGlobalRevision &+= 1
            if let key, threadSnapshot(for: key) == nil {
                await refreshThreadSnapshot(key: key)
            }
            scheduleDeferredActiveThreadHydrationIfNeeded(for: key)
        case .pendingApprovalsChanged:
            await refreshSnapshot()
        case .pendingUserInputsChanged:
            await refreshSnapshot()
        case .serverChanged:
            scheduleSnapshotRefreshDebounced()
        case .serverRemoved:
            await refreshSnapshot()
        case .fullResync:
            await refreshSnapshot()
        case .voiceSessionChanged:
            await refreshSnapshot()
        case .realtimeTranscriptUpdated:
            break
        case .realtimeHandoffRequested:
            break
        case .realtimeSpeechStarted:
            break
        case .realtimeStarted:
            await refreshSnapshot()
        case .realtimeSdp:
            break
        case .realtimeOutputAudioDelta:
            break
        case .realtimeError:
            await refreshSnapshot()
        case .realtimeClosed:
            await refreshSnapshot()
        case .savedAppsChanged:
            SavedAppsStore.shared.reload()
        case .dynamicWidgetStreaming(let key, let itemId, _, let widget):
            applyStreamingWidget(key: key, itemId: itemId, widget: widget)
        case .terminalSessionsChanged:
            await refreshSnapshot()
        }
        #if DEBUG
        debugRecordIngressPostApply(arrival: debugArrival)
        #endif
    }

    #if DEBUG
    func _testHandleStoreUpdate(_ update: AppStoreUpdateRecord) async { await handleStoreUpdate(update) }
    #endif

    /// Mutate an in-flight widget bubble's `HydratedWidgetData` so the
    /// timeline `WidgetWebView` picks up the growing HTML via its existing
    /// `Coordinator.scheduleUpdate` debounce. The reducer guarantees
    /// `is_finalized == false` on these; the finalized update arrives
    /// separately as `.threadItemChanged` and must win.
    private func applyStreamingWidget(
        key: ThreadKey,
        itemId: String,
        widget: HydratedWidgetData
    ) {
        guard var snapshot else {
            LLog.warn("streaming", "applyStreamingWidget: no snapshot")
            return
        }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            LLog.warn("streaming", "applyStreamingWidget: thread not in snapshot",
                      fields: ["threadId": key.threadId, "htmlLen": widget.widgetHtml.count])
            return
        }
        var thread = snapshot.threads[threadIndex]
        if let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == itemId }) {
            var item = thread.hydratedConversationItems[itemIndex]
            if case .widget(let existing) = item.content, existing.isFinalized { return }
            if case .widget(let existing) = item.content, existing == widget { return }
            item.content = .widget(widget)
            thread.hydratedConversationItems[itemIndex] = item
            LLog.info("streaming", "widget delta mutated existing",
                      fields: ["itemId": itemId, "htmlLen": widget.widgetHtml.count])
        } else {
            let placeholder = HydratedConversationItem(
                id: itemId,
                content: .widget(widget),
                sourceTurnId: thread.activeTurnId,
                sourceTurnIndex: nil,
                timestamp: nil,
                isFromUserTurnBoundary: false
            )
            thread.hydratedConversationItems.append(placeholder)
            LLog.info("streaming", "widget delta inserted placeholder",
                      fields: ["itemId": itemId, "htmlLen": widget.widgetHtml.count,
                               "sourceTurnId": thread.activeTurnId ?? "nil"])
        }
        snapshot.threads[threadIndex] = thread
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
    }

    private func applyThreadStreamingDelta(
        key: ThreadKey,
        itemId: String,
        kind: ThreadStreamingDeltaKind,
        text: String
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }

        var thread = snapshot.threads[threadIndex]
        guard let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == itemId }) else {
            return false
        }

        var item = thread.hydratedConversationItems[itemIndex]
        guard let updatedContent = applyingStreamingDelta(
            kind: kind,
            text: text,
            to: item.content
        ) else {
            return false
        }

        item.content = updatedContent
        guard thread.hydratedConversationItems[itemIndex] != item else {
            return true
        }

        thread.hydratedConversationItems[itemIndex] = item
        snapshot.threads[threadIndex] = thread
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
        return true
    }

    private func applyingStreamingDelta(
        kind: ThreadStreamingDeltaKind,
        text: String,
        to content: HydratedConversationItemContent
    ) -> HydratedConversationItemContent? {
        switch (kind, content) {
        case (.assistantText, .assistant(var data)):
            data.text += text
            return .assistant(data)
        case (.reasoningText, .reasoning(var data)):
            if data.content.isEmpty {
                data.content.append(text)
            } else {
                data.content[data.content.index(before: data.content.endIndex)] += text
            }
            return .reasoning(data)
        case (.planText, .proposedPlan(var data)):
            data.content += text
            return .proposedPlan(data)
        case (.commandOutput, .commandExecution(var data)):
            data.output = (data.output ?? "") + text
            return .commandExecution(data)
        case (.mcpProgress, .mcpToolCall(var data)):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                data.progressMessages.append(text)
            }
            return .mcpToolCall(data)
        default:
            return nil
        }
    }

    func refreshThreadSnapshot(key: ThreadKey) async {
        guard snapshot != nil else {
            await refreshSnapshot()
            return
        }

        do {
            guard let threadSnapshot = try await store.threadSnapshot(key: key) else {
                if cachedThreadSnapshots[key] == nil {
                    removeThreadSnapshot(for: key, clearCache: false)
                }
                return
            }
            applyThreadSnapshot(threadSnapshot)
        } catch {
            lastError = error.localizedDescription
            await refreshSnapshot()
        }
    }

    private func scheduleThreadSnapshotRefresh(for key: ThreadKey) {
        pendingThreadRefreshKeys.insert(key)
        guard pendingThreadRefreshTask == nil else { return }
        pendingThreadRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            let keys = self.pendingThreadRefreshKeys
            self.pendingThreadRefreshKeys.removeAll()
            self.pendingThreadRefreshTask = nil
            for key in keys {
                await self.refreshThreadSnapshot(key: key)
            }
        }
    }

    private func shouldBatchLiveThreadStateUpdate(for key: ThreadKey) -> Bool {
        guard let thread = threadSnapshot(for: key) ?? cachedThreadSnapshots[key] else {
            return false
        }
        return thread.activeTurnId != nil || thread.info.status == .active
    }

    private func shouldBatchLiveCommandMutation(for key: ThreadKey) -> Bool {
        shouldBatchLiveThreadStateUpdate(for: key)
    }

    private func shouldBatchCommandRowMutation(
        for key: ThreadKey,
        item: HydratedConversationItem
    ) -> Bool {
        guard shouldBatchLiveCommandMutation(for: key) else { return false }
        return shouldBatchLiveNonAssistantItem(item)
    }

    private func shouldBatchLiveNonAssistantItem(_ item: HydratedConversationItem) -> Bool {
        switch item.content {
        case .assistant, .user:
            return false
        default:
            return true
        }
    }

    private func enqueueThreadStateUpdate(
        _ state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        pendingThreadStateEvents[state.key] = PendingThreadStateEvent(
            state: state,
            sessionSummary: sessionSummary,
            agentDirectoryVersion: agentDirectoryVersion
        )

        guard pendingThreadStateTask == nil else { return }
        pendingThreadStateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveThreadStateCoalescingNanoseconds)
            guard let self else { return }
            await self.flushPendingThreadStateUpdates()
        }
    }

    private func flushPendingThreadStateUpdates() async {
        let events = pendingThreadStateEvents.values
        pendingThreadStateEvents.removeAll()
        pendingThreadStateTask = nil
        guard !events.isEmpty else { return }

        let relatedMutationKeys = Set(events.map(\.state.key))
        let relatedMutations = drainPendingCommandRowMutations(for: relatedMutationKeys)
        if !relatedMutations.isEmpty {
            let refreshKeys = applyCombinedLiveMutationBatch(
                Array(events),
                mutations: relatedMutations
            )
            for key in refreshKeys {
                await refreshThreadSnapshot(key: key)
            }
            return
        }

        for event in events {
            applyThreadStateUpdated(
                event.state,
                sessionSummary: event.sessionSummary,
                agentDirectoryVersion: event.agentDirectoryVersion
            )
        }
    }

    private func commandRowMutationKey(key: ThreadKey, itemId: String) -> String {
        "\(key.serverId)::\(key.threadId)::\(itemId)"
    }

    private func enqueueCommandRowUpsert(
        key: ThreadKey,
        item: HydratedConversationItem
    ) {
        let mutationKey = commandRowMutationKey(key: key, itemId: item.id)
        var mutation = pendingCommandRowMutations[mutationKey]
            ?? PendingCommandRowMutation(key: key, itemId: item.id)
        mutation.upsertItem = item
        pendingCommandRowMutations[mutationKey] = mutation
        schedulePendingCommandRowMutationsFlush()
    }

    private func schedulePendingCommandRowMutationsFlush() {
        guard pendingCommandRowMutationTask == nil else { return }
        pendingCommandRowMutationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.liveItemMutationCoalescingNanoseconds)
            guard let self else { return }
            await self.flushPendingCommandRowMutations()
        }
    }

    private func flushPendingCommandRowMutations() async {
        let mutations = Array(pendingCommandRowMutations.values)
        pendingCommandRowMutations.removeAll()
        pendingCommandRowMutationTask = nil
        guard !mutations.isEmpty else { return }

        let relatedStateKeys = Set(mutations.map(\.key))
        let relatedStateEvents = drainPendingThreadStateEvents(for: relatedStateKeys)
        if !relatedStateEvents.isEmpty {
            let refreshKeys = applyCombinedLiveMutationBatch(
                relatedStateEvents,
                mutations: mutations
            )
            for key in refreshKeys {
                await refreshThreadSnapshot(key: key)
            }
            return
        }

        let refreshKeys = applyCommandRowMutationBatch(mutations)
        for key in refreshKeys {
            await refreshThreadSnapshot(key: key)
        }
    }

    private func applyCommandRowMutationBatch(
        _ mutations: [PendingCommandRowMutation]
    ) -> Set<ThreadKey> {
        guard var snapshot else {
            return Set(mutations.map(\.key))
        }

        var mutated = false
        var touchedThreadIndexes: Set<Int> = []
        let refreshKeys = applyCommandRowMutationBatch(
            mutations,
            to: &snapshot,
            touchedThreadIndexes: &touchedThreadIndexes,
            mutated: &mutated
        )

        if mutated {
            self.snapshot = snapshot
            for threadIndex in touchedThreadIndexes {
                cacheThreadSnapshot(snapshot.threads[threadIndex])
            }
            lastError = nil
        }

        return refreshKeys
    }

    private func drainPendingThreadStateEvents(
        for keys: Set<ThreadKey>
    ) -> [PendingThreadStateEvent] {
        guard !keys.isEmpty else { return [] }
        let drained = pendingThreadStateEvents
            .filter { keys.contains($0.key) }
            .map(\.value)
        for key in keys {
            pendingThreadStateEvents.removeValue(forKey: key)
        }
        if pendingThreadStateEvents.isEmpty {
            pendingThreadStateTask?.cancel()
            pendingThreadStateTask = nil
        }
        return drained
    }

    private func drainPendingCommandRowMutations(
        for keys: Set<ThreadKey>
    ) -> [PendingCommandRowMutation] {
        guard !keys.isEmpty else { return [] }
        let drained = pendingCommandRowMutations
            .values
            .filter { keys.contains($0.key) }
        pendingCommandRowMutations = pendingCommandRowMutations.filter { _, value in
            !keys.contains(value.key)
        }
        if pendingCommandRowMutations.isEmpty {
            pendingCommandRowMutationTask?.cancel()
            pendingCommandRowMutationTask = nil
        }
        return Array(drained)
    }

    private func applyCombinedLiveMutationBatch(
        _ stateEvents: [PendingThreadStateEvent],
        mutations: [PendingCommandRowMutation]
    ) -> Set<ThreadKey> {
        guard var snapshot else {
            return Set(stateEvents.map(\.state.key)).union(mutations.map(\.key))
        }

        var mutated = false
        var refreshKeys: Set<ThreadKey> = []
        var touchedThreadIndexes: Set<Int> = []

        for event in stateEvents {
            if applyThreadStateUpdated(
                to: &snapshot,
                state: event.state,
                sessionSummary: event.sessionSummary,
                agentDirectoryVersion: event.agentDirectoryVersion
            ) {
                mutated = true
                if let threadIndex = snapshot.threads.firstIndex(where: { $0.key == event.state.key }) {
                    touchedThreadIndexes.insert(threadIndex)
                }
            }
        }

        let commandRefreshKeys = applyCommandRowMutationBatch(
            mutations,
            to: &snapshot,
            touchedThreadIndexes: &touchedThreadIndexes,
            mutated: &mutated
        )
        refreshKeys.formUnion(commandRefreshKeys)

        if mutated {
            self.snapshot = snapshot
            for threadIndex in touchedThreadIndexes {
                cacheThreadSnapshot(snapshot.threads[threadIndex])
            }
            lastError = nil
        }

        return refreshKeys
    }

    @discardableResult
    private func applyThreadStateUpdated(
        to snapshot: inout AppSnapshotRecord,
        state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) -> Bool {
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == state.key }) else {
            return false
        }

        var thread = snapshot.threads[threadIndex]
        let shouldPreserveLiveTimestamps = Self.isLiveThreadState(
            existing: thread,
            incoming: state
        )
        let isVisibleActiveLiveThread = shouldPreserveLiveTimestamps && snapshot.activeThread == state.key
        var effectiveInfo = state.info
        if shouldPreserveLiveTimestamps {
            effectiveInfo.updatedAt = thread.info.updatedAt
        }
        thread.info = effectiveInfo
        thread.collaborationMode = state.collaborationMode
        thread.model = state.model
        thread.reasoningEffort = state.reasoningEffort
        thread.effectiveApprovalPolicy = state.effectiveApprovalPolicy
        thread.effectiveSandboxPolicy = state.effectiveSandboxPolicy
        thread.queuedFollowUps = state.queuedFollowUps
        thread.activeTurnId = state.activeTurnId
        thread.activePlanProgress = state.activePlanProgress
        thread.pendingPlanImplementationPrompt = state.pendingPlanImplementationPrompt
        thread.contextTokensUsed = state.contextTokensUsed
        thread.modelContextWindow = state.modelContextWindow
        thread.rateLimits = state.rateLimits
        thread.realtimeSessionId = state.realtimeSessionId
        thread.goal = state.goal
        thread.olderTurnsCursor = state.olderTurnsCursor
        thread.initialTurnsLoaded = state.initialTurnsLoaded
        let threadChanged = snapshot.threads[threadIndex] != thread
        snapshot.threads[threadIndex] = thread

        let sessionSummaryChanged: Bool
        if let index = snapshot.sessionSummaries.firstIndex(where: { $0.key == sessionSummary.key }) {
            let existingSummary = snapshot.sessionSummaries[index]
            var effectiveSessionSummary = sessionSummary
            if shouldPreserveLiveTimestamps {
                effectiveSessionSummary.updatedAt = existingSummary.updatedAt
            }
            sessionSummaryChanged = existingSummary != effectiveSessionSummary
            snapshot.sessionSummaries[index] = effectiveSessionSummary
        } else {
            sessionSummaryChanged = true
            snapshot.sessionSummaries.append(sessionSummary)
        }
        if sessionSummaryChanged {
            snapshot.sessionSummaries.sort(by: Self.sessionSummarySort(lhs:rhs:))
        }
        let agentDirectoryChanged = snapshot.agentDirectoryVersion != agentDirectoryVersion
        if isVisibleActiveLiveThread && !threadChanged && !agentDirectoryChanged {
            return false
        }
        snapshot.agentDirectoryVersion = agentDirectoryVersion
        return threadChanged || sessionSummaryChanged || agentDirectoryChanged
    }

    private func applyCommandRowMutationBatch(
        _ mutations: [PendingCommandRowMutation],
        to snapshot: inout AppSnapshotRecord,
        touchedThreadIndexes: inout Set<Int>,
        mutated: inout Bool
    ) -> Set<ThreadKey> {
        var refreshKeys: Set<ThreadKey> = []

        for mutation in mutations {
            guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == mutation.key }) else {
                refreshKeys.insert(mutation.key)
                continue
            }

            guard let item = mutation.upsertItem else { continue }
            var thread = snapshot.threads[threadIndex]

            if let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == item.id }) {
                guard thread.hydratedConversationItems[itemIndex] != item else { continue }
                thread.hydratedConversationItems[itemIndex] = item
            } else {
                let insertionIndex = Self.insertionIndex(for: item, in: thread.hydratedConversationItems)
                thread.hydratedConversationItems.insert(item, at: insertionIndex)
            }

            snapshot.threads[threadIndex] = thread
            touchedThreadIndexes.insert(threadIndex)
            mutated = true
        }

        return refreshKeys
    }

    private func scheduleDeferredActiveThreadHydrationIfNeeded(for key: ThreadKey?) {
        guard let key else {
            pendingActiveThreadHydrationTask?.cancel()
            pendingActiveThreadHydrationTask = nil
            pendingActiveThreadHydrationKey = nil
            return
        }

        guard let thread = threadSnapshot(for: key),
              shouldAttemptDeferredHydration(for: thread) else {
            if pendingActiveThreadHydrationKey == key {
                pendingActiveThreadHydrationTask?.cancel()
                pendingActiveThreadHydrationTask = nil
                pendingActiveThreadHydrationKey = nil
            }
            return
        }

        guard pendingActiveThreadHydrationKey != key || pendingActiveThreadHydrationTask == nil else {
            return
        }

        pendingActiveThreadHydrationTask?.cancel()
        pendingActiveThreadHydrationKey = key
        pendingActiveThreadHydrationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            await self.hydrateActiveThreadIfNeeded(key: key)
        }
    }

    private func hydrateActiveThreadIfNeeded(key: ThreadKey) async {
        defer {
            if pendingActiveThreadHydrationKey == key {
                pendingActiveThreadHydrationTask = nil
                pendingActiveThreadHydrationKey = nil
            }
        }

        guard snapshot?.activeThread == key,
              let thread = threadSnapshot(for: key),
              shouldAttemptDeferredHydration(for: thread) else {
            return
        }

        do {
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: false
                )
            )
            if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                await refreshThreadSnapshot(key: nextKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldAttemptDeferredHydration(for thread: AppThreadSnapshot) -> Bool {
        guard thread.agentRuntimeKind.reportsEffectiveThreadPermissions else { return false }
        guard thread.hydratedConversationItems.isEmpty else { return false }
        let preview = thread.info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = thread.info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !preview.isEmpty || !title.isEmpty || thread.hasActiveTurn
    }

    func renameThread(serverId: String, threadId: String, title rawTitle: String) async throws {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let key = ThreadKey(serverId: serverId, threadId: threadId)

        _ = try await client.renameThread(
            serverId: serverId,
            params: AppRenameThreadRequest(threadId: threadId, name: title)
        )
        applyLocalThreadTitle(title, for: key)
        await refreshSnapshot()
        applyLocalThreadTitle(title, for: key)
    }

    private func applyLocalThreadTitle(_ title: String, for key: ThreadKey) {
        guard var snapshot else { return }
        guard snapshot.applyLocalThreadTitle(title, for: key) else { return }
        self.snapshot = snapshot
        if let thread = snapshot.threadSnapshot(for: key) {
            cacheThreadSnapshot(thread)
        }
        lastError = nil
    }

    private func applyThreadSnapshot(_ thread: AppThreadSnapshot) {
        let thread = mergedThreadSnapshotPreservingHydratedItems(thread)
        guard var snapshot else {
            cacheThreadSnapshot(thread)
            applySnapshot(nil)
            return
        }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            snapshot.threads[index] = thread
        } else {
            snapshot.threads.append(thread)
        }
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
    }

    private func applyThreadUpsert(
        _ thread: AppThreadSnapshot,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        var thread = mergedThreadSnapshotPreservingHydratedItems(thread)
        guard var snapshot else { return }

        if let index = snapshot.threads.firstIndex(where: { $0.key == thread.key }) {
            let oldThread = snapshot.threads[index]
            if oldThread.activeTurnId != nil {
                Self.preserveStreamingText(from: oldThread, into: &thread)
            }
            snapshot.threads[index] = thread
        } else {
            snapshot.threads.append(thread)
        }

        if let index = snapshot.sessionSummaries.firstIndex(where: { $0.key == sessionSummary.key }) {
            snapshot.sessionSummaries[index] = sessionSummary
        } else {
            snapshot.sessionSummaries.append(sessionSummary)
        }
        snapshot.sessionSummaries.sort(by: Self.sessionSummarySort(lhs:rhs:))
        snapshot.agentDirectoryVersion = agentDirectoryVersion
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
    }

    private func applyThreadStateUpdated(
        _ state: AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: UInt64
    ) {
        guard var snapshot else { return }
        guard applyThreadStateUpdated(
            to: &snapshot,
            state: state,
            sessionSummary: sessionSummary,
            agentDirectoryVersion: agentDirectoryVersion
        ) else {
            return
        }
        self.snapshot = snapshot
        if let thread = snapshot.threadSnapshot(for: state.key) {
            cacheThreadSnapshot(thread)
        }
        lastError = nil
    }

    private func applyThreadItemUpsert(
        key: ThreadKey,
        item: HydratedConversationItem
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }

        var thread = snapshot.threads[threadIndex]
        if let itemIndex = thread.hydratedConversationItems.firstIndex(where: { $0.id == item.id }) {
            guard thread.hydratedConversationItems[itemIndex] != item else { return true }
            thread.hydratedConversationItems[itemIndex] = item
        } else {
            let insertionIndex = Self.insertionIndex(for: item, in: thread.hydratedConversationItems)
            thread.hydratedConversationItems.insert(item, at: insertionIndex)
        }

        snapshot.threads[threadIndex] = thread
        self.snapshot = snapshot
        cacheThreadSnapshot(thread)
        lastError = nil
        return true
    }

    /// Patch the matching `AppSessionSummary` in `snapshot.sessionSummaries`
    /// when the reducer hands us a freshly-derived one (via `threadItemChanged`,
    /// which now carries it as a field). Ensures home-list fields like
    /// `lastResponsePreview`, `lastToolLabel`, and `stats` track streaming
    /// items without needing a full snapshot rebuild.
    private func applySessionSummary(_ summary: AppSessionSummary) {
        guard var snapshot else { return }
        if let idx = snapshot.sessionSummaries.firstIndex(where: { $0.key == summary.key }) {
            snapshot.sessionSummaries[idx] = summary
        } else {
            snapshot.sessionSummaries.append(summary)
        }
        self.snapshot = snapshot
    }

    private func applyThreadCommandExecutionUpdated(
        key: ThreadKey,
        itemId: String,
        status: AppOperationStatus,
        exitCode: Int32?,
        durationMs: Int64?,
        processId: String?
    ) -> Bool {
        guard var snapshot else { return false }
        guard let threadIndex = snapshot.threads.firstIndex(where: { $0.key == key }) else {
            return false
        }
        guard let itemIndex = snapshot.threads[threadIndex].hydratedConversationItems.firstIndex(where: { $0.id == itemId }) else {
            return false
        }

        var item = snapshot.threads[threadIndex].hydratedConversationItems[itemIndex]
        guard case .commandExecution(var data) = item.content else {
            return false
        }
        data.status = status
        data.exitCode = exitCode
        data.durationMs = durationMs
        data.processId = processId
        item.content = .commandExecution(data)
        guard snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] != item else {
            return true
        }
        snapshot.threads[threadIndex].hydratedConversationItems[itemIndex] = item
        self.snapshot = snapshot
        cacheThreadSnapshot(snapshot.threads[threadIndex])
        lastError = nil
        return true
    }

    private func removeThreadSnapshot(
        for key: ThreadKey,
        agentDirectoryVersion: UInt64? = nil,
        clearCache: Bool = true
    ) {
        guard var snapshot else { return }
        snapshot.threads.removeAll { $0.key == key }
        snapshot.sessionSummaries.removeAll { $0.key == key }
        if snapshot.activeThread == key {
            snapshot.activeThread = nil
        }
        if let agentDirectoryVersion {
            snapshot.agentDirectoryVersion = agentDirectoryVersion
        }
        self.snapshot = snapshot
        threadRebindSignal(for: key).bump()
        if clearCache {
            cachedThreadSnapshots.removeValue(forKey: key)
        }
    }

    private func updateActiveThread(_ key: ThreadKey?) {
        guard var snapshot else { return }
        snapshot.activeThread = key
        self.snapshot = snapshot
    }

    private static func preserveStreamingText(
        from oldThread: AppThreadSnapshot,
        into newThread: inout AppThreadSnapshot
    ) {
        let oldItemsById = Dictionary(
            oldThread.hydratedConversationItems.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for (newIndex, newItem) in newThread.hydratedConversationItems.enumerated() {
            guard let oldItem = oldItemsById[newItem.id] else {
                continue
            }
            if let preserved = preservedStreamingContent(old: oldItem.content, new: newItem.content) {
                newThread.hydratedConversationItems[newIndex].content = preserved
            }
        }
    }

    private static func preservedStreamingContent(
        old: HydratedConversationItemContent,
        new: HydratedConversationItemContent
    ) -> HydratedConversationItemContent? {
        switch (old, new) {
        case (.assistant(let oldData), .assistant(var newData))
            where oldData.text.count > newData.text.count && oldData.text.hasPrefix(newData.text):
            newData.text = oldData.text
            return .assistant(newData)
        case (.reasoning(let oldData), .reasoning(var newData))
            where oldData.content.count > newData.content.count:
            let shared = zip(oldData.content, newData.content)
            if shared.allSatisfy({ old, new in old.hasPrefix(new) }) {
                newData.content = oldData.content
                return .reasoning(newData)
            }
            return nil
        case (.proposedPlan(let oldData), .proposedPlan(var newData))
            where oldData.content.count > newData.content.count && oldData.content.hasPrefix(newData.content):
            newData.content = oldData.content
            return .proposedPlan(newData)
        default:
            return nil
        }
    }

    private static func isLiveThreadState(
        existing: AppThreadSnapshot,
        incoming: AppThreadStateRecord
    ) -> Bool {
        if existing.activeTurnId != nil || incoming.activeTurnId != nil {
            return true
        }
        return existing.info.status == .active || incoming.info.status == .active
    }

    private static func sessionSummarySort(lhs: AppSessionSummary, rhs: AppSessionSummary) -> Bool {
        let lhsUpdatedAt = lhs.updatedAt ?? Int64.min
        let rhsUpdatedAt = rhs.updatedAt ?? Int64.min
        if lhsUpdatedAt != rhsUpdatedAt {
            return lhsUpdatedAt > rhsUpdatedAt
        }
        if lhs.key.serverId != rhs.key.serverId {
            return lhs.key.serverId < rhs.key.serverId
        }
        return lhs.key.threadId < rhs.key.threadId
    }

    private static func insertionIndex(
        for item: HydratedConversationItem,
        in items: [HydratedConversationItem]
    ) -> Int {
        guard let targetTurnIndex = item.sourceTurnIndex.map(Int.init) else {
            return items.count
        }
        if let lastSameTurnIndex = items.lastIndex(where: { $0.sourceTurnIndex.map(Int.init) == targetTurnIndex }) {
            return lastSameTurnIndex + 1
        }
        if let nextTurnIndex = items.firstIndex(where: {
            guard let sourceTurnIndex = $0.sourceTurnIndex.map(Int.init) else { return false }
            return sourceTurnIndex > targetTurnIndex
        }) {
            return nextTurnIndex
        }
        return items.count
    }

    private static func insertionIndex(
        for item: HydratedConversationItem,
        turnIndex: Int,
        turnItemIndex: Int,
        in items: [HydratedConversationItem]
    ) -> Int {
        let sameTurnIndices = items.enumerated().compactMap { index, existing in
            existing.sourceTurnIndex.map(Int.init) == turnIndex ? index : nil
        }

        if let start = sameTurnIndices.first {
            return min(start + turnItemIndex, start + sameTurnIndices.count)
        }

        if let nextTurnIndex = items.firstIndex(where: {
            guard let sourceTurnIndex = $0.sourceTurnIndex.map(Int.init) else { return false }
            return sourceTurnIndex > turnIndex
        }) {
            return nextTurnIndex
        }

        return item.sourceTurnIndex != nil ? items.count : insertionIndex(for: item, in: items)
    }

    func queueComposerPrefill(threadKey: ThreadKey, text: String) {
        composerPrefillRequest = ComposerPrefillRequest(threadKey: threadKey, text: text)
    }

    func clearComposerPrefill(id: UUID) {
        guard composerPrefillRequest?.id == id else { return }
        composerPrefillRequest = nil
    }

    func availableModels(for serverId: String) -> [ModelInfo] {
        snapshot?.serverSnapshot(for: serverId)?.availableModels ?? []
    }

    func modelCatalogError(for serverId: String) -> String? {
        modelCatalogErrorsByServer[serverId]
    }

    func rateLimits(for serverId: String) -> RateLimitSnapshot? {
        snapshot?.serverSnapshot(for: serverId)?.rateLimits
    }

    /// Per-runtime rate limits. Returns the snapshot reported by the agent
    /// runtime that owns the thread the user is currently looking at — e.g.
    /// Claude Code threads return Claude usage, Codex threads return Codex
    /// usage. Returns `nil` when the runtime hasn't reported any.
    func rateLimits(forServer serverId: String, runtime: AgentRuntimeKind) -> RateLimitSnapshot? {
        snapshot?
            .serverSnapshot(for: serverId)?
            .rateLimitsByRuntime
            .first(where: { $0.runtimeKind == runtime })?
            .rateLimits
    }

    func loadConversationMetadataIfNeeded(serverId: String) async {
        await loadAvailableModelsIfNeeded(serverId: serverId)
        await loadRateLimitsIfNeeded(serverId: serverId)
    }

    func loadAvailableModelsIfNeeded(serverId: String, force: Bool = false) async {
        guard let server = snapshot?.serverSnapshot(for: serverId), server.isConnected else { return }
        guard force || server.availableModels == nil else { return }
        guard !loadingModelServerIds.contains(serverId) else { return }
        loadingModelServerIds.insert(serverId)
        defer { loadingModelServerIds.remove(serverId) }
        modelCatalogErrorsByServer.removeValue(forKey: serverId)
        do {
            _ = try await client.refreshModels(
                serverId: serverId,
                params: AppRefreshModelsRequest(cursor: nil, limit: nil, includeHidden: false)
            )
            modelCatalogErrorsByServer.removeValue(forKey: serverId)
            await refreshSnapshot()
        } catch {
            modelCatalogErrorsByServer[serverId] = error.localizedDescription
            await refreshSnapshot()
        }
    }

    func loadRateLimitsIfNeeded(serverId: String) async {
        guard let server = snapshot?.serverSnapshot(for: serverId), server.isConnected else { return }
        guard server.rateLimits == nil else { return }
        guard server.account != nil else { return }
        guard !loadingRateLimitServerIds.contains(serverId) else { return }
        loadingRateLimitServerIds.insert(serverId)
        defer { loadingRateLimitServerIds.remove(serverId) }
        do {
            _ = try await client.refreshRateLimits(serverId: serverId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startTurn(key: ThreadKey, payload: AppComposerPayload) async throws {
        #if DEBUG
        if debugBurstDriver?.noteStartTurnEntered(key: key, text: payload.text) == true { return }
        #endif
        await restoreStoredLocalAuthIfNeeded(serverId: key.serverId, reason: "startTurn")

        do {
            try await store.startTurn(
                key: key,
                params: payload.turnStartRequest(threadId: key.threadId)
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func hydrateThreadPermissions(for key: ThreadKey, appState: AppState) async -> ThreadKey? {
        if let existing = threadSnapshot(for: key) {
            appState.hydratePermissions(from: existing)
            if existing.agentRuntimeKind.reportsEffectiveThreadPermissions,
               !hasAuthoritativePermissions(existing) {
                scheduleBackgroundThreadPermissionHydration(for: key, appState: appState)
            }
            return key
        }

        if let summary = snapshot?.sessionSummary(for: key) {
            if summary.agentRuntimeKind.reportsEffectiveThreadPermissions {
                scheduleBackgroundThreadPermissionHydration(for: key, appState: appState)
            }
            return key
        }

        do {
            let nextKey = try await client.readThread(
                serverId: key.serverId,
                params: AppReadThreadRequest(
                    threadId: key.threadId,
                    includeTurns: false
                )
            )
            if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                applyThreadSnapshot(threadSnapshot)
                appState.hydratePermissions(from: threadSnapshot)
            } else {
                await refreshSnapshot()
                appState.hydratePermissions(from: snapshot?.threadSnapshot(for: nextKey))
            }
            return nextKey
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func scheduleBackgroundThreadPermissionHydration(
        for key: ThreadKey,
        appState: AppState
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let nextKey = try await client.readThread(
                    serverId: key.serverId,
                    params: AppReadThreadRequest(
                        threadId: key.threadId,
                        includeTurns: false
                    )
                )
                if let threadSnapshot = try await store.threadSnapshot(key: nextKey) {
                    applyThreadSnapshot(threadSnapshot)
                    appState.hydratePermissions(from: threadSnapshot)
                } else {
                    await refreshSnapshot()
                    appState.hydratePermissions(from: snapshot?.threadSnapshot(for: nextKey))
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func ensureThreadLoaded(
        key: ThreadKey,
        maxAttempts: Int = 5
    ) async -> ThreadKey? {
        if threadSnapshot(for: key) != nil {
            return key
        }

        let currentKey = key
        for attempt in 0..<maxAttempts {
            var readSucceeded = false
            do {
                try await store.externalResumeThread(key: currentKey, hostId: nil)
                store.setActiveThread(key: currentKey)
                readSucceeded = true
            } catch {
                lastError = error.localizedDescription
            }

            if readSucceeded {
                await refreshLoadedThreadSnapshot(key: currentKey)
                if threadSnapshot(for: currentKey) != nil {
                    return currentKey
                }
            }

            if !readSucceeded && attempt == 0 {
                do {
                    _ = try await client.listThreads(
                        serverId: currentKey.serverId,
                        params: AppListThreadsRequest(
                            cursor: nil,
                            limit: nil,
                            sortKey: .updatedAt,
                            sortDirection: .desc,
                            archived: nil,
                            cwd: nil,
                            searchTerm: nil,
                            useStateDbOnly: false,
                            runtimeKinds: nil
                        )
                    )
                } catch {
                    lastError = error.localizedDescription
                }

                await refreshLoadedThreadSnapshot(key: currentKey)
                if threadSnapshot(for: currentKey) != nil {
                    return currentKey
                }
            }

            if attempt + 1 < maxAttempts {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if let activeKey = snapshot?.activeThread,
           activeKey.serverId == currentKey.serverId,
           threadSnapshot(for: activeKey) != nil {
            return activeKey
        }

        return nil
    }

    private static let initialTurnPageSize: UInt32 = 5
    private static let olderTurnPageSize: UInt32 = 5

    /// Fetch the first page of turns for a thread whose `initialTurnsLoaded`
    /// is still false. Called after a resume that sent `exclude_turns: true`
    /// against a v0.125+ server.
    func loadInitialTurns(threadId key: ThreadKey) async {
        await loadTurnPage(key: key, cursor: nil, limit: Self.initialTurnPageSize)
    }

    func loadInitialTurnsIfNeeded(threadId key: ThreadKey) async {
        guard threadSnapshot(for: key)?.initialTurnsLoaded != true else {
            return
        }
        await loadInitialTurns(threadId: key)
    }

    /// Fetch the next older page of turns using the thread's current cursor.
    /// No-op when no cursor is available (older-turns button should be hidden
    /// in that case).
    func loadOlderTurns(threadId key: ThreadKey) async {
        guard let cursor = threadSnapshot(for: key)?.olderTurnsCursor,
              !cursor.isEmpty else {
            return
        }
        await loadTurnPage(key: key, cursor: cursor, limit: Self.olderTurnPageSize)
    }

    private func loadTurnPage(key: ThreadKey, cursor: String?, limit: UInt32) async {
        if loadingTurnPageThreadKeys.contains(key) { return }
        loadingTurnPageThreadKeys.insert(key)
        defer { loadingTurnPageThreadKeys.remove(key) }

        do {
            _ = try await store.loadThreadTurnsPage(
                key: key,
                cursor: cursor,
                limit: limit
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshLoadedThreadSnapshot(key: ThreadKey) async {
        do {
            if let thread = try await store.threadSnapshot(key: key) {
                applyThreadSnapshot(thread)
            } else {
                await refreshSnapshot()
            }
        } catch {
            lastError = error.localizedDescription
            await refreshSnapshot()
        }
    }

    func threadSnapshot(for key: ThreadKey) -> AppThreadSnapshot? {
        snapshot?.threadSnapshot(for: key) ?? cachedThreadSnapshots[key]
    }

    private func hasAuthoritativePermissions(_ thread: AppThreadSnapshot) -> Bool {
        threadPermissionsAreAuthoritative(
            approvalPolicy: thread.effectiveApprovalPolicy,
            sandboxPolicy: thread.effectiveSandboxPolicy
        )
    }

    private func restoreCachedThreadSnapshotIfNeeded(for key: ThreadKey?) {
        guard let key,
              snapshot?.threadSnapshot(for: key) == nil,
              let cached = cachedThreadSnapshots[key] else {
            return
        }
        applyThreadSnapshot(cached)
    }

    private func cacheThreadSnapshot(_ thread: AppThreadSnapshot) {
        let changed = cachedThreadSnapshots[thread.key] != thread
        cachedThreadSnapshots[thread.key] = thread
        if changed { threadRebindSignal(for: thread.key).bump() }
    }

    private func mergedThreadSnapshotPreservingHydratedItems(_ thread: AppThreadSnapshot) -> AppThreadSnapshot {
        guard let cached = cachedThreadSnapshots[thread.key],
              !cached.hydratedConversationItems.isEmpty else {
            return thread
        }

        if thread.hydratedConversationItems.count < cached.hydratedConversationItems.count {
            LLog.warn("streaming", "threadUpsert arrived with fewer items than cached", fields: [
                "threadId": thread.key.threadId,
                "incoming": thread.hydratedConversationItems.count,
                "cached": cached.hydratedConversationItems.count,
                "status": String(describing: thread.info.status)
            ])
        }

        // Incoming has no items → use cached items entirely.
        if thread.hydratedConversationItems.isEmpty {
            var merged = thread
            merged.hydratedConversationItems = cached.hydratedConversationItems
            return merged
        }

        return thread
    }

    private func mergingCachedThreadSnapshots(_ snapshot: AppSnapshotRecord) -> AppSnapshotRecord {
        var snapshot = snapshot

        for index in snapshot.threads.indices {
            let thread = snapshot.threads[index]
            snapshot.threads[index] = mergedThreadSnapshotPreservingHydratedItems(thread)
        }

        for (key, cached) in cachedThreadSnapshots {
            guard snapshot.threads.contains(where: { $0.key == key }) == false else { continue }
            guard snapshot.activeThread == key ||
                  snapshot.sessionSummaries.contains(where: { $0.key == key }) else {
                continue
            }
            snapshot.threads.append(cached)
        }

        return snapshot
    }

    #if DEBUG
    @ObservationIgnored private(set) var debugFixtureActive = false
    @ObservationIgnored private(set) var debugBeaconRevision: UInt64 = 0
    @ObservationIgnored private(set) var debugBeaconVisibleUntilMs: UInt64 = 0
    var debugBeaconVisible: Bool { debugBeaconVisibleUntilMs >= DebugPerfClock.monoMs() }
    @ObservationIgnored private var debugBurstDriver: DebugBurstDriver?
    @ObservationIgnored var debugIngressLedger: [String] = []
    @ObservationIgnored var debugIngressDropped = 0
    @ObservationIgnored private var debugWatchdogTask: Task<Void, Never>?
    @ObservationIgnored private var debugForeignStreamTask: Task<Void, Never>?

    func debugBeaconBlink() { debugBeaconRevision &+= 1; debugBeaconVisibleUntilMs = DebugPerfClock.monoMs() + 66 }
    func debugAppendLedger(_ line: String) {
        debugIngressLedger.append(line)
        if debugIngressLedger.count > 512 { let overflow = debugIngressLedger.count - 512; debugIngressDropped += overflow; debugIngressLedger.removeFirst(overflow) }
    }
    struct DebugIngressArrival { let monoMs: UInt64; let wallMs: UInt64; let variant: String; let key: ThreadKey?; let queued: Int?; let steerKinds: String; let activeTurn: String? }
    func debugIngressArrival(_ update: AppStoreUpdateRecord) -> DebugIngressArrival {
        var key: ThreadKey?, queued: Int?, activeTurn: String?, m = 0, p = 0, r = 0
        func tally(_ previews: [AppQueuedFollowUpPreview]) -> Int {
            for q in previews { switch q.kind { case .message: m += 1; case .pendingSteer: p += 1; default: r += 1 } }
            return previews.count
        }
        switch update {
        case .threadUpserted(let t, _, _): key = t.key; queued = tally(t.queuedFollowUps); activeTurn = t.activeTurnId
        case .threadMetadataChanged(let s, _, _): key = s.key; queued = tally(s.queuedFollowUps); activeTurn = s.activeTurnId
        case .threadItemChanged(let k, _, _): key = k
        case .threadStreamingDelta(let k, _, _, _): key = k
        case .threadRemoved(let k, _): key = k
        case .activeThreadChanged(let k): key = k
        case .dynamicWidgetStreaming(let k, _, _, _): key = k
        default: break
        }
        return DebugIngressArrival(monoMs: DebugPerfClock.monoMs(), wallMs: DebugPerfClock.wallMs(), variant: Mirror(reflecting: update).children.first?.label ?? String(describing: update), key: key, queued: queued, steerKinds: queued != nil ? "\(m)/\(p)/\(r)" : "-", activeTurn: activeTurn)
    }
    func debugRecordIngressPostApply(arrival: DebugIngressArrival) {
        let line = "burst.ingress arriveMs=\(arrival.monoMs) applyMs=\(DebugPerfClock.monoMs()) wallMs=\(arrival.wallMs) variant=\(arrival.variant) threadKey=\(arrival.key.map { "\($0.serverId)/\($0.threadId)" } ?? "-") queued=\(arrival.queued.map(String.init) ?? "-") steerKinds=\(arrival.steerKinds) activeTurn=\(arrival.activeTurn ?? "-") rev=\(snapshotRevision)"
        debugAppendLedger(line)
        os_signpost(.event, log: PerfAttribution.log, name: "burst.ingress", "%@", line)
    }
    @discardableResult
    func debugFlushIngressLedger(reason: String = "manual") -> String? {
        guard !debugIngressLedger.isEmpty else { return nil }
        let header = "burst.ledger flush reason=\(reason) entries=\(debugIngressLedger.count) dropped=\(debugIngressDropped)"
        NSLog("%@", header)
        debugIngressLedger.forEach { NSLog("%@", $0) }
        debugIngressLedger.removeAll(); debugIngressDropped = 0
        return header
    }
    private func debugStartWatchdog() {
        guard debugWatchdogTask == nil else { return }
        debugWatchdogTask = Task { [weak self] in
            var lastMs = DebugPerfClock.monoMs()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                let nowMs = DebugPerfClock.monoMs(); let gapMs = nowMs - lastMs; lastMs = nowMs
                if gapMs > 500 { self.debugAppendLedger("burst.watchdog gapMs=\(gapMs) t=\(nowMs) wallMs=\(DebugPerfClock.wallMs())") }
            }
        }
    }

    private func debugStartForeignStream(key: ThreadKey, itemId: String, intervalMs: UInt64) {
        guard debugForeignStreamTask == nil, intervalMs > 0 else { return }
        debugForeignStreamTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
                guard let self else { return }
                n += 1
                await self._testHandleStoreUpdate(.threadStreamingDelta(key: key, itemId: itemId, kind: .assistantText, text: " f\u{3b4}\(n)"))
            }
        }
    }

    @discardableResult
    func applyDebugProductionFixtureIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["CODEXIOS_UI_TEST_PRODUCTION_FIXTURE"] == "1" else { return false }
        let sessions = Int(env["CODEXIOS_UI_TEST_SESSION_COUNT"] ?? "") ?? 300
        let items = Int(env["CODEXIOS_UI_TEST_ITEM_COUNT"] ?? "") ?? 1500
        applySnapshot(DebugProductionFixture.makeSnapshot(sessions: max(sessions, 2), items: items))
        debugFixtureActive = true
        debugArmBurstDriverIfRequested(environment: env)
        if let raw = env["CODEXIOS_UI_TEST_STREAM_FOREIGN"], !raw.isEmpty {
            let cadenceMs: UInt64 = raw == "1" ? 100 : UInt64(raw) ?? 100
            debugStartForeignStream(key: DebugProductionFixture.liveThreadKey, itemId: DebugProductionFixture.liveAssistantItemId, intervalMs: cadenceMs)
        }
        debugStartWatchdog()
        return true
    }

    @discardableResult
    func debugArmBurstDriverIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if debugBurstDriver == nil { debugBurstDriver = DebugBurstDriver() }
        guard let driver = debugBurstDriver else { return false }
        driver.armIfRequested(environment: environment, appModel: self)
        guard driver.phase != .idle else { return false }
        debugStartWatchdog()
        return true
    }
    #endif
}

extension AppSnapshotRecord {
    func threadSnapshot(for key: ThreadKey) -> AppThreadSnapshot? {
        if let idx = threads.firstIndex(where: { $0.key == key }) {
            return threads[idx]
        }
        return nil
    }

    func serverSnapshot(for serverId: String) -> AppServerSnapshot? {
        servers.first { $0.serverId == serverId }
    }

    func sessionSummary(for key: ThreadKey) -> AppSessionSummary? {
        sessionSummaries.first { $0.key == key }
    }

    func resolvedThreadKey(for receiverId: String, serverId: String) -> ThreadKey? {
        guard let normalized = AgentLabelFormatter.sanitized(receiverId) else { return nil }
        if let summary = sessionSummaries.first(where: {
            $0.key.serverId == serverId && $0.key.threadId == normalized
        }) {
            return summary.key
        }
        return ThreadKey(serverId: serverId, threadId: normalized)
    }

    func resolvedAgentTargetLabel(for target: String, serverId: String) -> String? {
        if AgentLabelFormatter.looksLikeDisplayLabel(target) {
            return AgentLabelFormatter.sanitized(target)
        }
        guard let normalized = AgentLabelFormatter.sanitized(target) else { return nil }
        if let summary = sessionSummaries.first(where: {
            $0.key.serverId == serverId && $0.key.threadId == normalized
        }) {
            return summary.agentDisplayLabel ?? AgentLabelFormatter.sanitized(target)
        }
        return nil
    }
}

#if DEBUG
enum PerfAttribution {
    static let log = OSLog(subsystem: "com.sigkitten.litter", category: "PerfAttribution")
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log); os_signpost(.begin, log: log, name: name, signpostID: id); return id
    }
    static func end(_ name: StaticString, _ id: OSSignpostID) { os_signpost(.end, log: log, name: name, signpostID: id) }
}
enum DebugPerfClock {
    static func monoMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    static func wallMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}
extension Notification.Name { static let litterDebugBurstFire = Notification.Name("litter.debug.burstFire") }

enum DebugProductionFixture {
    static let epoch: Int64 = 1_700_000_000
    static let serverId = "fixture-server"
    static let liveAssistantItemId = "fixture-live-assistant-1"
    static let liveThreadKey = ThreadKey(serverId: serverId, threadId: "fixture-thread-1")

    static func item(at i: Int) -> HydratedConversationItem {
        let id = "fixture-item-\(i)", turn = UInt32(i / 6), slot = UInt32(i % 6), ts = Double(epoch) + Double(i), turnId = "fixture-turn-\(turn)"
        switch i % 6 {
        case 0: return HydratedConversationItem(id: id, content: .user(HydratedUserMessageData(text: "Fixture user message \(i).", imageDataUris: [])), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: true)
        case 1: return HydratedConversationItem(id: id, content: .assistant(HydratedAssistantMessageData(text: "Fixture assistant reply \(i).", agentNickname: nil, agentRole: nil, phase: .finalAnswer)), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: false)
        case 2: return HydratedConversationItem(id: id, content: .reasoning(HydratedReasoningData(summary: ["Fixture reasoning \(i)."], content: [])), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: false)
        case 3: return HydratedConversationItem(id: id, content: .commandExecution(HydratedCommandExecutionData(command: "echo fixture-\(i)", cwd: "/Projects/Workspace-\(i % 12)", status: .completed, output: "fixture output \(i)", exitCode: 0, durationMs: 120, processId: nil, actions: [])), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: false)
        case 4: return HydratedConversationItem(id: id, content: .mcpToolCall(HydratedMcpToolCallData(server: "fixture-mcp", tool: "fixtureTool", status: .completed, durationMs: 80, argumentsJson: "{}", contentSummary: "Fixture tool summary \(i).", structuredContentJson: nil, rawOutputJson: nil, errorMessage: nil, progressMessages: [], computerUse: nil)), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: false)
        default: return HydratedConversationItem(id: id, content: .commandExecution(HydratedCommandExecutionData(command: "sleep \(i % 3 + 1)", cwd: "/Projects/Workspace-\(i % 12)", status: .inProgress, output: nil, exitCode: nil, durationMs: nil, processId: nil, actions: [])), sourceTurnId: turnId, sourceTurnIndex: slot, timestamp: ts, isFromUserTurnBoundary: false)
        }
    }

    static func makeThread(index i: Int, items: [HydratedConversationItem]) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: ThreadKey(serverId: serverId, threadId: "fixture-thread-\(i)"),
            info: ThreadInfo(id: "fixture-thread-\(i)", title: "Fixture thread \(i)", model: "gpt-fixture", status: .idle, preview: "Fixture preview \(i)", cwd: "/Projects/Workspace-\(i / 25)", path: nil, modelProvider: "openai", agentNickname: nil, agentRole: nil, parentThreadId: i > 0 && i % 10 == 9 ? "fixture-thread-\(i - 9)" : nil, forkedFromId: nil, agentStatus: nil, createdAt: epoch - Int64(i) - 3_600, updatedAt: epoch - Int64(i)),
            agentRuntimeKind: "codex", collaborationMode: .default, model: "gpt-fixture", reasoningEffort: nil, effectiveApprovalPolicy: nil, effectiveSandboxPolicy: nil, hydratedConversationItems: items, queuedFollowUps: [], activeTurnId: nil, activePlanProgress: nil, pendingPlanImplementationPrompt: nil, contextTokensUsed: nil, modelContextWindow: nil, rateLimits: nil, realtimeSessionId: nil, goal: nil, stats: nil, tokenUsage: nil, olderTurnsCursor: nil, initialTurnsLoaded: true
        )
    }

    static func summary(for thread: AppThreadSnapshot) -> AppSessionSummary {
        AppSessionSummary(key: thread.key, agentRuntimeKind: thread.agentRuntimeKind, serverDisplayName: "Fixture Studio", serverHost: "fixture.local", title: thread.info.title ?? "", preview: thread.info.preview ?? "", cwd: thread.info.cwd ?? "", model: thread.model ?? "", modelProvider: thread.info.modelProvider ?? "", parentThreadId: thread.info.parentThreadId, forkedFromId: nil, agentNickname: nil, agentRole: nil, agentDisplayLabel: thread.key.threadId, agentStatus: .unknown, updatedAt: thread.info.updatedAt, hasActiveTurn: thread.activeTurnId != nil, isResumed: false, isSubagent: false, isFork: false, lastResponsePreview: nil, lastResponseTurnId: nil, lastUserMessage: nil, lastToolLabel: nil, recentToolLog: [], lastTurnStartMs: nil, lastTurnEndMs: nil, stats: nil, tokenUsage: nil, goal: nil)
    }

    static func makeSnapshot(sessions: Int, items: Int) -> AppSnapshotRecord {
        var threads: [AppThreadSnapshot] = []
        for i in 0..<max(sessions, 2) {
            let threadItems: [HydratedConversationItem]
            if i == 0 { threadItems = (0..<max(items, 0)).map(item(at:)) } else if i == 1 {
                threadItems = [
                    HydratedConversationItem(id: "fixture-live-user-1", content: .user(HydratedUserMessageData(text: "Fixture live turn.", imageDataUris: [])), sourceTurnId: "fixture-live-turn", sourceTurnIndex: 0, timestamp: Double(epoch) + 10, isFromUserTurnBoundary: true),
                    HydratedConversationItem(id: liveAssistantItemId, content: .assistant(HydratedAssistantMessageData(text: "Fixture live stream.", agentNickname: nil, agentRole: nil, phase: .commentary)), sourceTurnId: "fixture-live-turn", sourceTurnIndex: 1, timestamp: Double(epoch) + 11, isFromUserTurnBoundary: false),
                    HydratedConversationItem(id: "fixture-live-assistant-2", content: .assistant(HydratedAssistantMessageData(text: "Done.", agentNickname: nil, agentRole: nil, phase: .finalAnswer)), sourceTurnId: "fixture-live-turn", sourceTurnIndex: 2, timestamp: Double(epoch) + 12, isFromUserTurnBoundary: false)
                ]
            } else { threadItems = [] }
            threads.append(makeThread(index: i, items: threadItems))
        }
        let server = AppServerSnapshot(serverId: serverId, displayName: "Fixture Studio", host: "fixture.local", port: 8390, wakeMac: nil, isLocal: false, health: .connected, transportState: .connected, capabilities: AppServerCapabilities(canUseTransportActions: true, canBrowseDirectories: true, canStartThreads: true, canResumeThreads: true, supportsTurnPagination: false), account: nil, requiresOpenaiAuth: false, rateLimits: nil, rateLimitsByRuntime: [], availableModels: nil, agentRuntimes: [AgentRuntimeInfo(kind: .codex, name: "codex", displayName: "Codex", available: true)], connectionProgress: nil, usageStats: nil)
        return AppSnapshotRecord(servers: [server], threads: threads, sessionSummaries: threads.map { summary(for: $0) }, agentDirectoryVersion: 0, activeThread: nil, pendingApprovals: [], pendingUserInputs: [], voiceSession: AppVoiceSessionSnapshot(activeThread: nil, sessionId: nil, phase: nil, lastError: nil, transcriptEntries: [], handoffThreadKey: nil), terminalSessions: [], activeTerminalId: nil)
    }

    static func burstState(_ key: ThreadKey, status: ThreadSummaryStatus, activeTurnId: String?, queued: [AppQueuedFollowUpPreview]) -> AppThreadStateRecord {
        AppThreadStateRecord(key: key, info: ThreadInfo(id: key.threadId, title: "Fixture thread", model: "gpt-fixture", status: status, preview: "Fixture preview", cwd: "/Projects/Workspace-0", path: nil, modelProvider: "openai", agentNickname: nil, agentRole: nil, parentThreadId: nil, forkedFromId: nil, agentStatus: nil, createdAt: epoch, updatedAt: epoch), agentRuntimeKind: "codex", collaborationMode: .default, model: "gpt-fixture", reasoningEffort: nil, effectiveApprovalPolicy: nil, effectiveSandboxPolicy: nil, queuedFollowUps: queued, activeTurnId: activeTurnId, activePlanProgress: nil, pendingPlanImplementationPrompt: nil, contextTokensUsed: nil, modelContextWindow: nil, rateLimits: nil, realtimeSessionId: nil, goal: nil, olderTurnsCursor: nil, initialTurnsLoaded: true)
    }

    static func burstSummary(_ key: ThreadKey, active: Bool, updatedAt: Int64) -> AppSessionSummary {
        AppSessionSummary(key: key, agentRuntimeKind: "codex", serverDisplayName: "Fixture Studio", serverHost: "fixture.local", title: "Fixture thread", preview: "Fixture preview", cwd: "/Projects/Workspace-0", model: "gpt-fixture", modelProvider: "openai", parentThreadId: nil, forkedFromId: nil, agentNickname: nil, agentRole: nil, agentDisplayLabel: key.threadId, agentStatus: .unknown, updatedAt: updatedAt, hasActiveTurn: active, isResumed: false, isSubagent: false, isFork: false, lastResponsePreview: nil, lastResponseTurnId: nil, lastUserMessage: nil, lastToolLabel: nil, recentToolLog: [], lastTurnStartMs: nil, lastTurnEndMs: nil, stats: nil, tokenUsage: nil, goal: nil)
    }

    static func burstUpdates(index: Int, key: ThreadKey, texts: [String]) -> [AppStoreUpdateRecord] {
        let queued = texts.prefix(index + 1).enumerated().map { AppQueuedFollowUpPreview(id: "fixture-burst-followup-\($0.offset)", kind: .message, text: $0.element) }
        return [.threadMetadataChanged(state: burstState(key, status: .active, activeTurnId: "fixture-burst-turn", queued: Array(queued)), sessionSummary: burstSummary(key, active: true, updatedAt: epoch), agentDirectoryVersion: 0), .threadStreamingDelta(key: key, itemId: "fixture-item-1", kind: .assistantText, text: " F\(index + 1) burst \u{3b4}")]
    }

    static func burstDrainUpdate(key: ThreadKey) -> AppStoreUpdateRecord {
        .threadMetadataChanged(state: burstState(key, status: .idle, activeTurnId: nil, queued: []), sessionSummary: burstSummary(key, active: false, updatedAt: epoch + 1), agentDirectoryVersion: 0)
    }
}

@MainActor
final class DebugBurstDriver {
    enum Phase { case idle, armed, fired }
    enum SteerMode: String { case plain = "PLAIN", steer = "STEER" }
    struct Configuration { let offsetsMs: [Int]; let trial: String; let attempt: String; let mode: SteerMode; let hex: String; let raw: String; let fixtureMode: Bool }

    static let anchorPrompt = "Run the command sh -c 'for i in 1 2 3 4 5 6 7 8; do echo tick $i; sleep 1; done' and then summarize its output in one sentence."
    static let anchorPromptLong = "Run the command sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo tick $i; sleep 1; done' and then summarize its output in one sentence."
    static let defaultOffsetsMs = [200, 400, 700]
    static let inputPattern = try! NSRegularExpression(pattern: #"^B([1-9][0-9]{0,2})\.([1-9][0-9]?)-(PLAIN|STEER)-([0-9a-f]{6})$"#)

    static func wireNonce(_ configuration: Configuration, fire: Int) -> String { "B\(configuration.trial).\(configuration.attempt)-F\(fire)-\(configuration.hex)" }
    static func followUpTexts(configuration: Configuration) -> [String] { ["Follow-up one \(wireNonce(configuration, fire: 1)): reply with exactly ALPHA.", "Follow-up two \(wireNonce(configuration, fire: 2)): reply with exactly \(configuration.mode == .steer ? "BRAVO-STEERED" : "BRAVO").", "Follow-up three \(wireNonce(configuration, fire: 3)): reply with exactly CHARLIE."] }
    static func anchorWindowMs(for text: String) -> Int? { text == anchorPrompt ? 8_000 : text == anchorPromptLong ? 20_000 : nil }
    static func checkpointDelayMs(lastFireOffsetMs: Int, commandWindowMs: Int) -> Int { max(lastFireOffsetMs + 1_000, commandWindowMs + 8_000) }

    static func parseTimings(_ raw: String?) -> [Int] {
        let fields = raw?.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return (0..<3).map { i in guard i < fields.count, let v = Int(fields[i]) else { return defaultOffsetsMs[i] }; return min(max(v, 10), 2000) }
    }
    static func rejectLine(_ reason: String, value: String? = nil) -> String { value.map { "burst.driver reject reason=\(reason) value=\"\($0)\"" } ?? "burst.driver reject reason=\(reason)" }

    static func configuration(environment: [String: String]) -> Configuration? {
        guard environment["CODEXIOS_UI_TEST_BURST_FOLLOWUPS"] == "1" else { return nil }
        guard let input = environment["CODEXIOS_UI_TEST_BURST_NONCE"], !input.isEmpty else { NSLog("%@", rejectLine("missing-nonce")); return nil }
        func malformed() { NSLog("%@", rejectLine("malformed-nonce", value: input)) }
        guard let match = inputPattern.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { malformed(); return nil }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: input).map { String(input[$0]) } }
        guard let trial = group(1), let attempt = group(2), let mode = group(3).flatMap(SteerMode.init(rawValue:)), let hex = group(4) else { malformed(); return nil }
        return Configuration(offsetsMs: parseTimings(environment["CODEXIOS_UI_TEST_BURST_TIMINGS_MS"]), trial: trial, attempt: attempt, mode: mode, hex: hex, raw: input, fixtureMode: environment["CODEXIOS_UI_TEST_PRODUCTION_FIXTURE"] == "1")
    }

    static func burstPlan(offsetsMs: [Int], anchorMs: UInt64) -> [(index: Int, intendedMs: UInt64)] {
        offsetsMs.enumerated().map { (index: $0.offset, intendedMs: anchorMs + UInt64(max($0.element, 0))) }
    }

    private(set) var phase: Phase = .idle; private(set) var scheduledFireCount = 0
    private var config: Configuration?; private weak var appModel: AppModel?; private var fixtureApplyChain: Task<Void, Never>?

    func armIfRequested(environment: [String: String], appModel: AppModel) {
        guard phase == .idle, let armed = Self.configuration(environment: environment) else { return }
        config = armed; self.appModel = appModel; phase = .armed
        NSLog("burst.driver idle->armed offsets=\(armed.offsetsMs.map(String.init).joined(separator: ",")) input=\(armed.raw) trial=\(armed.trial) attempt=\(armed.attempt) steer=\(armed.mode.rawValue) hex=\(armed.hex) mode=\(armed.fixtureMode ? "fixture" : "live")")
    }

    @discardableResult
    func noteStartTurnEntered(key: ThreadKey, text: String) -> Bool {
        guard let config else { return false }
        if phase == .armed, let commandWindowMs = Self.anchorWindowMs(for: text) {
            phase = .fired; scheduleFires(key, commandWindowMs: commandWindowMs); return config.fixtureMode
        }
        if phase == .fired, Self.followUpTexts(configuration: config).contains(text) { NSLog("burst.driver follow-up entry (recursion-guarded)") }
        return false
    }

    private func scheduleFires(_ key: ThreadKey, commandWindowMs: Int) {
        guard let config else { return }
        let anchorMs = DebugPerfClock.monoMs(); NSLog("burst.driver armed->fired anchorMonoMs=\(anchorMs) wallMs=\(DebugPerfClock.wallMs())")
        let plan = Self.burstPlan(offsetsMs: config.offsetsMs, anchorMs: anchorMs); let texts = Self.followUpTexts(configuration: config); let nonces = (1...3).map { Self.wireNonce(config, fire: $0) }
        scheduledFireCount = plan.count
        for entry in plan {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(entry.intendedMs - anchorMs) * 1_000_000); self?.fire(index: entry.index, key: key, intendedMs: entry.intendedMs, texts: texts, nonces: nonces, config: config)
            }
        }
        guard let lastMs = plan.map(\.intendedMs).max() else { return }
        if config.fixtureMode {
            Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(lastMs - anchorMs + 1_000) * 1_000_000); guard let self, let chain = self.fixtureApplyChain else { return }; await chain.value; await self.appModel?._testHandleStoreUpdate(DebugProductionFixture.burstDrainUpdate(key: key)) }
        }
        Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(Self.checkpointDelayMs(lastFireOffsetMs: Int(lastMs - anchorMs), commandWindowMs: commandWindowMs)) * 1_000_000); self?.appModel?.debugFlushIngressLedger(reason: "burst-checkpoint"); NSLog("burst.driver checkpoint") }
    }

    private func fire(index: Int, key: ThreadKey, intendedMs: UInt64, texts: [String], nonces: [String], config: Configuration) {
        let actualMs = DebugPerfClock.monoMs(); NSLog("burst.driver fire F\(index + 1) intended=\(intendedMs) actual=\(actualMs) drift=\(actualMs &- intendedMs) nonce=\(nonces[index]) wallMs=\(DebugPerfClock.wallMs())")
        appModel?.debugBeaconBlink()
        guard index < texts.count else { return }
        if config.fixtureMode {
            let updates = DebugProductionFixture.burstUpdates(index: index, key: key, texts: texts)
            fixtureApplyChain = Task { [previous = fixtureApplyChain, weak appModel] in await previous?.value; for update in updates { await appModel?._testHandleStoreUpdate(update) } }
        } else {
            NotificationCenter.default.post(name: .litterDebugBurstFire, object: nil, userInfo: ["key": key, "text": texts[index]])
        }
    }
}
#endif
