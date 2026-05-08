package com.litter.android.state

import com.litter.android.core.bridge.UniffiInit
import com.litter.android.util.LLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong
import uniffi.codex_mobile_client.AppClient
import uniffi.codex_mobile_client.AppMinigameRequest
import uniffi.codex_mobile_client.AppMinigameResult
import uniffi.codex_mobile_client.AgentRuntimeKind
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppSortDirection
import uniffi.codex_mobile_client.AppStore
import uniffi.codex_mobile_client.AppStoreSubscription
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.AppThreadSortKey
import uniffi.codex_mobile_client.AppThreadSourceKind
import uniffi.codex_mobile_client.ThreadStreamingDeltaKind
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.DiscoveryBridge
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.MessageParser
import uniffi.codex_mobile_client.ReconnectController
import uniffi.codex_mobile_client.ServerBridge
import uniffi.codex_mobile_client.SshBridge
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.AppListThreadsRequest
import uniffi.codex_mobile_client.AppLoginAccountRequest
import uniffi.codex_mobile_client.AppRefreshModelsRequest
import uniffi.codex_mobile_client.AppReadThreadRequest
import uniffi.codex_mobile_client.AppStartThreadRequest
import uniffi.codex_mobile_client.registerAndroidTools
import uniffi.codex_mobile_client.threadPermissionsAreAuthoritative

class LocalAccountLoginRequiredException(val serverId: String) :
    IllegalStateException("Local account login is required.")

/**
 * Central app state singleton. Thin wrapper over Rust [AppStore] — all business
 * logic, reconciliation, and state management lives in Rust.
 *
 * Exposes a [snapshot] StateFlow that the UI observes. Updated automatically
 * via the Rust subscription stream.
 */
class AppModel private constructor(context: android.content.Context) {

    data class ComposerPrefillRequest(
        val requestId: Long,
        val threadKey: ThreadKey,
        val text: String,
    )

    companion object {
        private var _instance: AppModel? = null

        val shared: AppModel
            get() = _instance ?: throw IllegalStateException("AppModel not initialized — call init(context) first")

        fun init(context: android.content.Context): AppModel {
            if (_instance == null) {
                _instance = AppModel(context.applicationContext)
            }
            return _instance!!
        }

        /**
         * Matches the iOS page sizes. Server clamps this at 100.
         */
        const val INITIAL_TURN_PAGE_LIMIT: UInt = 5u
        const val OLDER_TURN_PAGE_LIMIT: UInt = 5u
    }

    // --- Rust bridges (singletons behind the scenes) -------------------------

    val store: AppStore
    val client: AppClient
    val discovery: DiscoveryBridge
    val serverBridge: ServerBridge
    val ssh: SshBridge
    val sshSessionStore: SshSessionStore
    val parser: MessageParser
    val reconnectController: ReconnectController
    val launchState: AppLaunchState
    val appContext: android.content.Context = context
    init {
        UniffiInit.ensure(context)
        registerBundledCliTools()
        LLog.bootstrap(context)
        store = AppStore()
        client = AppClient()
        // The show_widget auto-save hook on the Rust side persists to this
        // directory. Without setting it at launch the hook is a silent no-op.
        client.setSavedAppsDirectory(SavedAppsDirectory.path(context))
        discovery = DiscoveryBridge()
        serverBridge = ServerBridge()
        ssh = SshBridge()
        sshSessionStore = SshSessionStore(ssh)
        parser = MessageParser()
        reconnectController = ReconnectController()
        reconnectController.setCredentialProvider(
            KotlinSshCredentialProvider(SshCredentialStore(context))
        )
        reconnectController.setIpcSocketPathOverride(
            com.litter.android.ui.ExperimentalFeatures.ipcSocketPathOverride()
        )
        reconnectController.setMultiClankerAndQuicEnabled(true)
        launchState = AppLaunchState(context)
    }

    // --- Observable state ----------------------------------------------------

    private val _snapshot = MutableStateFlow<AppSnapshotRecord?>(null)
    val snapshot: StateFlow<AppSnapshotRecord?> = _snapshot.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val loadingModelServerIds = mutableSetOf<String>()
    private val loadingRateLimitServerIds = mutableSetOf<String>()
    private val recentConversationMetadataLoads = mutableMapOf<String, Long>()
    private val cachedThreadSnapshots = mutableMapOf<ThreadKey, AppThreadSnapshot>()
    private val sessionListMutex = Mutex()
    private var pendingActiveThreadHydrationKey: ThreadKey? = null
    private var pendingActiveThreadHydrationJob: Job? = null

    // --- Composer prefill queue (for edit message / slash commands) -----------

    private val nextComposerPrefillRequestId = AtomicLong(0)
    private val _composerPrefillRequest = MutableStateFlow<ComposerPrefillRequest?>(null)
    val composerPrefillRequest: StateFlow<ComposerPrefillRequest?> = _composerPrefillRequest.asStateFlow()

    fun queueComposerPrefill(threadKey: ThreadKey, text: String) {
        _composerPrefillRequest.value = ComposerPrefillRequest(
            requestId = nextComposerPrefillRequestId.incrementAndGet(),
            threadKey = threadKey,
            text = text,
        )
    }

    fun clearComposerPrefill(requestId: Long) {
        if (_composerPrefillRequest.value?.requestId == requestId) {
            _composerPrefillRequest.value = null
        }
    }

    // --- Thinking-indicator minigame -----------------------------------------

    private val _minigameOverlay = MutableStateFlow<MinigameOverlayState>(MinigameOverlayState.Idle)
    val minigameOverlay: StateFlow<MinigameOverlayState> = _minigameOverlay.asStateFlow()
    private var minigameJob: Job? = null

    fun requestMinigame(
        parentThreadId: String,
        serverId: String,
        lastUserMessage: String?,
        lastAssistantMessage: String?,
    ) {
        if (!com.litter.android.ui.ExperimentalFeatures.isEnabled(
                com.litter.android.ui.LitterFeature.THINKING_MINIGAME
            )) return
        if (_minigameOverlay.value !is MinigameOverlayState.Idle) return
        _minigameOverlay.value = MinigameOverlayState.Loading
        minigameJob?.cancel()
        minigameJob = scope.launch {
            try {
                val result: AppMinigameResult = client.startMinigame(
                    AppMinigameRequest(
                        serverId = serverId,
                        parentThreadId = parentThreadId,
                        lastUserMessage = lastUserMessage,
                        lastAssistantMessage = lastAssistantMessage,
                    )
                )
                _minigameOverlay.value = MinigameOverlayState.Shown(
                    MinigameContent(
                        html = result.widgetHtml,
                        title = result.title,
                        width = result.width.toFloat(),
                        height = result.height.toFloat(),
                    )
                )
            } catch (t: Throwable) {
                _minigameOverlay.value = MinigameOverlayState.Failed(t.message ?: t.toString())
            }
        }
    }

    fun dismissMinigame() {
        minigameJob?.cancel()
        minigameJob = null
        _minigameOverlay.value = MinigameOverlayState.Idle
    }

    // --- Subscription lifecycle ----------------------------------------------

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var subscriptionJob: Job? = null
    private val lifecycleLock = Any()
    private var activeClients: Int = 0

    fun start() {
        val shouldStart = synchronized(lifecycleLock) {
            activeClients += 1
            subscriptionJob?.isActive != true
        }
        if (!shouldStart) return
        subscriptionJob = scope.launch {
            try {
                val subscription: AppStoreSubscription = store.subscribeUpdates()
                refreshSnapshot()
                while (true) {
                    try {
                        val update: AppStoreUpdateRecord = subscription.nextUpdate()
                        handleUpdate(update)
                    } catch (e: Exception) {
                        LLog.e("AppModel", "AppStore subscription loop failed", e)
                        throw e
                    }
                }
            } catch (e: Exception) {
                LLog.e("AppModel", "AppModel.start() subscription failed", e)
                _lastError.value = e.message
            }
        }
    }

    fun stop() {
        val shouldStop = synchronized(lifecycleLock) {
            activeClients = (activeClients - 1).coerceAtLeast(0)
            activeClients == 0
        }
        if (!shouldStop) return
        subscriptionJob?.cancel()
        subscriptionJob = null
        pendingActiveThreadHydrationJob?.cancel()
        pendingActiveThreadHydrationJob = null
        pendingActiveThreadHydrationKey = null
    }

    // --- Snapshot refresh -----------------------------------------------------

    suspend fun refreshSnapshot() {
        try {
            val snap = store.snapshot()
            applySnapshot(snap)
            val serverSummary = snap.servers.joinToString(separator = " | ") { server ->
                "${server.serverId}:${server.displayName}:${server.host}:${server.port}:${server.health}"
            }
            LLog.d(
                "AppModel",
                "snapshot refreshed",
                fields = mapOf("servers" to snap.servers.size, "summary" to serverSummary),
            )
        } catch (e: Exception) {
            _lastError.value = e.message
        }
    }

    private fun applySnapshot(snapshot: AppSnapshotRecord?) {
        val merged = snapshot
            ?.let(::applySavedServerNames)
            ?.let(::mergeCachedThreadSnapshots)
        _snapshot.value = merged
        if (merged != null) {
            persistWakeMacs(merged)
            merged.threads.forEach(::cacheThreadSnapshot)
            _lastError.value = null
        }
    }

    private fun persistWakeMacs(snapshot: AppSnapshotRecord) {
        snapshot.servers.forEach { server ->
            SavedServerStore.updateWakeMac(
                context = appContext,
                serverId = server.serverId,
                host = server.host,
                wakeMac = server.wakeMac,
            )
        }
    }

    private fun loadSavedServerNames(): Map<String, String> =
        SavedServerStore.load(appContext)
            .mapNotNull { server ->
                val trimmed = server.name.trim()
                if (trimmed.isEmpty()) null else server.id to trimmed
            }
            .toMap()

    private fun applySavedServerNames(snapshot: AppSnapshotRecord): AppSnapshotRecord {
        val nameByServerId = loadSavedServerNames()
        if (nameByServerId.isEmpty()) return snapshot

        return snapshot.copy(
            servers = snapshot.servers.map { server ->
                val savedName = nameByServerId[server.serverId]
                if (savedName != null && savedName != server.displayName) {
                    server.copy(displayName = savedName)
                } else {
                    server
                }
            },
            sessionSummaries = snapshot.sessionSummaries.map { summary ->
                val savedName = nameByServerId[summary.key.serverId]
                if (savedName != null && savedName != summary.serverDisplayName) {
                    summary.copy(serverDisplayName = savedName)
                } else {
                    summary
                }
            },
        )
    }

    private fun applySavedServerName(summary: AppSessionSummary): AppSessionSummary {
        val savedName = loadSavedServerNames()[summary.key.serverId] ?: return summary
        return if (savedName != summary.serverDisplayName) {
            summary.copy(serverDisplayName = savedName)
        } else {
            summary
        }
    }

    /// Patch a single `AppSessionSummary` in the snapshot. Called whenever
    /// the reducer emits a per-item summary update on `threadItemChanged`,
    /// so home-list derived fields track streaming items without waiting
    /// for a full snapshot rebuild.
    private fun applySessionSummary(summary: AppSessionSummary) {
        val current = _snapshot.value ?: return
        val adjusted = applySavedServerName(summary)
        val existingIndex = current.sessionSummaries.indexOfFirst { it.key == adjusted.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingIndex >= 0) {
                this[existingIndex] = adjusted
            } else {
                add(adjusted)
            }
        }
        _snapshot.value = current.copy(sessionSummaries = updatedSummaries)
    }

    suspend fun restartLocalServer() {
        val currentLocal = snapshot.value?.servers?.firstOrNull { it.isLocal }
        val serverId = currentLocal?.serverId ?: "local"
        val displayName = currentLocal?.displayName ?: "This Device"
        runCatching { serverBridge.disconnectServer(serverId) }
        serverBridge.connectLocalServer(
            serverId = serverId,
            displayName = displayName,
            host = "127.0.0.1",
            port = 0u,
        )
        restoreStoredLocalAuthState(serverId)
        try {
            refreshSessions(listOf(serverId))
        } catch (_: Exception) {
        }
        refreshSnapshot()
    }

    suspend fun refreshSessions(serverIds: Collection<String>? = null) {
        val targetServerIds = (serverIds?.toList() ?: snapshot.value?.servers
            ?.filter { it.isConnected }
            ?.map { it.serverId }
            .orEmpty())
            .distinct()

        if (targetServerIds.isEmpty()) {
            return
        }

        sessionListMutex.withLock {
            try {
                for (serverId in targetServerIds) {
                    client.listThreads(
                        serverId,
                        AppListThreadsRequest(
                            cursor = null,
                            limit = null,
                            archived = null,
                            cwd = null,
                            searchTerm = null,
                        ),
                    )
                }
                _lastError.value = null
            } catch (e: Exception) {
                _lastError.value = e.message
                throw e
            }
        }
    }

    suspend fun refreshThreadSearchSessions(
        query: String,
        runtimeKind: AgentRuntimeKind?,
        forceRepair: Boolean,
    ) {
        val trimmedQuery = query.trim()
        val servers = snapshot.value?.servers
            ?.filter { it.isConnected }
            .orEmpty()
        val targetServerIds = servers
            .filter { server ->
                runtimeKind == null || server.agentRuntimes.any {
                    it.available && it.kind == runtimeKind
                }
            }
            .map { it.serverId }
            .distinct()

        if (targetServerIds.isEmpty()) {
            return
        }

        sessionListMutex.withLock {
            try {
                for (serverId in targetServerIds) {
                    client.listThreads(
                        serverId,
                        AppListThreadsRequest(
                            cursor = null,
                            limit = 80u,
                            sortKey = AppThreadSortKey.UPDATED_AT,
                            sortDirection = AppSortDirection.DESC,
                            modelProviders = null,
                            sourceKinds = listOf(
                                AppThreadSourceKind.CLI,
                                AppThreadSourceKind.VS_CODE,
                                AppThreadSourceKind.APP_SERVER,
                            ),
                            archived = false,
                            cwd = null,
                            searchTerm = trimmedQuery.ifEmpty { null },
                            useStateDbOnly = !forceRepair,
                            runtimeKinds = runtimeKind?.let { listOf(it) },
                        ),
                    )
                }
                _lastError.value = null
            } catch (e: Exception) {
                _lastError.value = e.message
                throw e
            }
        }
    }

    suspend fun loadConversationMetadataIfNeeded(serverId: String) {
        if (hasFreshConversationMetadata(serverId)) return
        loadAvailableModelsIfNeeded(serverId)
        loadRateLimitsIfNeeded(serverId)
        recentConversationMetadataLoads[serverId] = System.currentTimeMillis()
    }

    suspend fun loadAvailableModelsIfNeeded(serverId: String) {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return
        if (!server.isConnected) return
        if (server.availableModels != null) return
        if (!loadingModelServerIds.add(serverId)) return
        try {
            client.refreshModels(
                serverId,
                AppRefreshModelsRequest(cursor = null, limit = null, includeHidden = false),
            )
            refreshSnapshot()
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            loadingModelServerIds.remove(serverId)
        }
    }

    suspend fun loadRateLimitsIfNeeded(serverId: String) {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return
        if (!server.isConnected) return
        if (server.account == null) return
        if (server.rateLimits != null) return
        if (!loadingRateLimitServerIds.add(serverId)) return
        try {
            client.refreshRateLimits(serverId)
            refreshSnapshot()
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            loadingRateLimitServerIds.remove(serverId)
        }
    }

    suspend fun restoreStoredLocalAuthState(serverId: String) {
        val apiKeyStore = OpenAIApiKeyStore(appContext)
        val storedApiKey = apiKeyStore.load()
        if (restoreStoredLocalChatGptAuth(serverId)) {
            return
        }
        apiKeyStore.applyToEnvironment()
        if (!storedApiKey.isNullOrBlank() && loginStoredLocalApiKeyAuth(serverId, storedApiKey)) {
            return
        }
    }

    suspend fun ensureLocalAuthForThreadStart(serverId: String): Boolean {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return true
        if (!server.isLocal) return true
        if (server.account != null) return true

        if (restoreStoredLocalAuthIfNeeded(serverId, reason = "startThread")) {
            return true
        }

        return false
    }

    private suspend fun restoreStoredLocalAuthIfNeeded(serverId: String, reason: String): Boolean {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return false
        if (!server.isLocal || server.account != null) return false

        val apiKeyStore = OpenAIApiKeyStore(appContext)
        val storedApiKey = apiKeyStore.load()?.trim().orEmpty()
        val hasStoredChatGptTokens = ChatGPTOAuthTokenStore(appContext).load() != null
        if (!hasStoredChatGptTokens && storedApiKey.isBlank()) return false

        LLog.i(
            "AppModel",
            "restoring stored local auth before local session operation",
            fields = mapOf(
                "serverId" to serverId,
                "reason" to reason,
            ),
        )
        restoreStoredLocalAuthState(serverId)
        refreshSnapshot()
        return snapshot.value?.servers?.firstOrNull { it.serverId == serverId }?.account != null
    }

    suspend fun restoreStoredLocalChatGptAuth(serverId: String): Boolean {
        val storedTokens = ChatGPTOAuthTokenStore(appContext).load() ?: return false
        val refreshedTokens = runCatching {
            ChatGPTOAuth.refreshStoredTokens(
                context = appContext,
                previousAccountId = null,
            )
        }.getOrNull()
        if (refreshedTokens != null &&
            loginStoredLocalChatGptAuth(serverId, refreshedTokens)
        ) {
            return true
        }
        if (loginStoredLocalChatGptAuth(serverId, storedTokens)) {
            return true
        }
        if (refreshedTokens != null) {
            return false
        }
        delay(2_000)
        return runCatching {
            ChatGPTOAuth.refreshStoredTokens(
                context = appContext,
                previousAccountId = null,
            )
        }.getOrNull()?.let { retriedRefresh ->
            loginStoredLocalChatGptAuth(serverId, retriedRefresh)
        } == true
    }

    private suspend fun loginStoredLocalChatGptAuth(
        serverId: String,
        tokens: ChatGPTOAuthTokenBundle,
    ): Boolean {
        return runCatching {
            client.loginAccount(
                serverId,
                uniffi.codex_mobile_client.AppLoginAccountRequest.ChatgptAuthTokens(
                    accessToken = tokens.accessToken,
                    chatgptAccountId = tokens.accountId,
                    chatgptPlanType = tokens.planType,
                ),
            )
            true
        }.getOrElse { error ->
            _lastError.value = error.message
            false
        }
    }

    private suspend fun loginStoredLocalApiKeyAuth(serverId: String, apiKey: String): Boolean {
        return runCatching {
            client.loginAccount(
                serverId,
                AppLoginAccountRequest.ApiKey(apiKey.trim()),
            )
            _lastError.value = null
            true
        }.getOrElse { error ->
            LLog.w(
                "AppModel",
                "restoring stored local API key auth failed",
                fields = mapOf(
                    "serverId" to serverId,
                    "error" to (error.localizedMessage ?: error.message ?: error.toString()),
                ),
            )
            false
        }
    }

    suspend fun hydrateThreadPermissions(key: ThreadKey): ThreadKey? {
        val existing = threadSnapshot(key)
        if (existing != null && hasAuthoritativePermissions(existing)) {
            launchState.syncFromThread(existing)
            return key
        }

        if (existing != null) {
            launchState.syncFromThread(existing)
            scheduleBackgroundThreadPermissionHydration(key)
            return key
        }

        if (snapshot.value?.sessionSummaries?.any { it.key == key } == true) {
            scheduleBackgroundThreadPermissionHydration(key)
            return key
        }

        return try {
            val nextKey = client.readThread(
                key.serverId,
                AppReadThreadRequest(
                    threadId = key.threadId,
                    includeTurns = false,
                ),
            )
            val threadSnapshot = store.threadSnapshot(nextKey)
            if (threadSnapshot != null) {
                applyThreadSnapshot(threadSnapshot)
                launchState.syncFromThread(threadSnapshot)
            } else {
                refreshSnapshot()
                launchState.syncFromThread(snapshot.value?.threads?.firstOrNull { it.key == nextKey })
            }
            nextKey
        } catch (e: Exception) {
            _lastError.value = e.message
            null
        }
    }

    fun activateThread(key: ThreadKey?) {
        restoreCachedThreadSnapshotIfNeeded(key)
        updateActiveThread(key)
        store.setActiveThread(key)
        scheduleDeferredActiveThreadHydrationIfNeeded(key)
    }

    suspend fun startThread(
        serverId: String,
        params: AppStartThreadRequest,
    ): ThreadKey {
        if (!ensureLocalAuthForThreadStart(serverId)) {
            throw LocalAccountLoginRequiredException(serverId)
        }
        return client.startThread(serverId, params)
    }

    suspend fun startTurn(
        key: ThreadKey,
        payload: AppComposerPayload,
    ) {
        restoreStoredLocalAuthIfNeeded(key.serverId, reason = "startTurn")

        try {
            store.startTurn(key, payload.toAppStartTurnRequest(key.threadId))
            _lastError.value = null
        } catch (e: Exception) {
            _lastError.value = e.message
            throw e
        }
    }

    suspend fun externalResumeThread(
        key: ThreadKey,
        hostId: String? = null,
    ) {
        restoreStoredLocalAuthIfNeeded(key.serverId, reason = "resumeThread")

        try {
            store.externalResumeThread(key, hostId)
            _lastError.value = null
        } catch (e: Exception) {
            _lastError.value = e.message
            throw e
        }
    }

    suspend fun refreshThreadIncludingTurns(key: ThreadKey): ThreadKey {
        try {
            val nextKey = client.readThread(
                key.serverId,
                AppReadThreadRequest(
                    threadId = key.threadId,
                    includeTurns = true,
                ),
            )
            val threadSnapshot = store.threadSnapshot(nextKey)
            if (threadSnapshot != null) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                refreshThreadSnapshot(nextKey)
            }
            _lastError.value = null
            return nextKey
        } catch (e: Exception) {
            _lastError.value = e.message
            throw e
        }
    }

    /**
     * Load the first page of turns for a thread. Intended to be called when
     * the conversation view appears for a thread whose
     * `initialTurnsLoaded == false`. Rust reconciles the page into the
     * store, and owns the fallback for servers that do not support paginated
     * turn loading.
     */
    private val initialTurnsLoadingKeys = mutableSetOf<ThreadKey>()
    private val olderTurnsLoadingKeys = mutableSetOf<ThreadKey>()

    /**
     * Launch an initial-turn load on the AppModel-owned scope so it survives
     * recomposition / LaunchedEffect key changes. The suspend body is not
     * cancelled mid-flight when the caller goes out of scope — RPC result +
     * store reconciliation always complete.
     */
    fun loadInitialTurns(key: ThreadKey, limit: UInt = INITIAL_TURN_PAGE_LIMIT) {
        if (!initialTurnsLoadingKeys.add(key)) return
        scope.launch {
            try {
                val outcome = store.loadThreadTurnsPage(key, null, limit)
                LLog.i(
                    "Pagination",
                    "loadInitialTurns",
                    fields = mapOf(
                        "threadId" to key.threadId,
                        "limit" to limit.toString(),
                        "loaded" to outcome.loaded.toString(),
                        "hasMore" to outcome.hasMore.toString(),
                    ),
                )
                _lastError.value = null
            } catch (e: Exception) {
                LLog.w(
                    "Pagination",
                    "loadInitialTurns failed",
                    fields = mapOf(
                        "threadId" to key.threadId,
                        "error" to (e.message ?: e.toString()),
                    ),
                )
                _lastError.value = e.message
            } finally {
                initialTurnsLoadingKeys.remove(key)
            }
        }
    }

    fun loadInitialTurnsIfNeeded(key: ThreadKey, limit: UInt = INITIAL_TURN_PAGE_LIMIT) {
        _snapshot.value ?: return
        if (threadSnapshot(key)?.initialTurnsLoaded == true) return
        loadInitialTurns(key, limit)
    }

    /**
     * Fetch the next older page using the thread's stored
     * `older_turns_cursor`. No-op when the cursor is null.
     *
     * Returns a [Job] so the caller can `join()` to drive UI state (e.g.
     * spinner on the "Load earlier messages" button).
     */
    fun loadOlderTurns(key: ThreadKey, limit: UInt = OLDER_TURN_PAGE_LIMIT): Job {
        val cursor = threadSnapshot(key)?.olderTurnsCursor
        if (cursor == null || !olderTurnsLoadingKeys.add(key)) {
            return scope.launch { /* no-op */ }
        }
        return scope.launch {
            try {
                val outcome = store.loadThreadTurnsPage(key, cursor, limit)
                LLog.i(
                    "Pagination",
                    "loadOlderTurns",
                    fields = mapOf(
                        "threadId" to key.threadId,
                        "cursor" to cursor,
                        "limit" to limit.toString(),
                        "loaded" to outcome.loaded.toString(),
                        "hasMore" to outcome.hasMore.toString(),
                    ),
                )
                _lastError.value = null
            } catch (e: Exception) {
                LLog.w(
                    "Pagination",
                    "loadOlderTurns failed",
                    fields = mapOf(
                        "threadId" to key.threadId,
                        "error" to (e.message ?: e.toString()),
                    ),
                )
                _lastError.value = e.message
            } finally {
                olderTurnsLoadingKeys.remove(key)
            }
        }
    }

    suspend fun ensureThreadLoaded(
        key: ThreadKey,
        maxAttempts: Int = 5,
    ): ThreadKey? {
        if (threadSnapshot(key) != null) {
            return key
        }

        var currentKey = key
        repeat(maxAttempts) { attempt ->
            var readSucceeded = false
            try {
                externalResumeThread(currentKey, null)
                store.setActiveThread(currentKey)
                readSucceeded = true
            } catch (e: Exception) {
                _lastError.value = e.message
            }

            if (readSucceeded) {
                refreshLoadedThreadSnapshot(currentKey)
                if (threadSnapshot(currentKey) != null) {
                    return currentKey
                }
            }

            if (!readSucceeded) {
                try {
                    client.listThreads(
                        currentKey.serverId,
                        AppListThreadsRequest(
                            cursor = null,
                            limit = null,
                            archived = null,
                            cwd = null,
                            searchTerm = null,
                        ),
                    )
                } catch (e: Exception) {
                    _lastError.value = e.message
                }

                refreshLoadedThreadSnapshot(currentKey)
                if (threadSnapshot(currentKey) != null) {
                    return currentKey
                }
            }

            if (attempt + 1 < maxAttempts) {
                delay(250)
            }
        }

        val activeKey = _snapshot.value?.activeThread
        if (activeKey != null &&
            activeKey.serverId == currentKey.serverId &&
            threadSnapshot(activeKey) != null
        ) {
            return activeKey
        }

        return null
    }

    private suspend fun refreshLoadedThreadSnapshot(key: ThreadKey) {
        try {
            val thread = store.threadSnapshot(key)
            if (thread != null) {
                applyThreadSnapshot(thread)
            } else {
                refreshSnapshot()
            }
        } catch (e: Exception) {
            _lastError.value = e.message
            refreshSnapshot()
        }
    }

    // --- Internal event handling ----------------------------------------------

    private suspend fun handleUpdate(update: AppStoreUpdateRecord) {
        when (update) {
            is AppStoreUpdateRecord.ThreadUpserted ->
                applyThreadUpsert(update.thread, update.sessionSummary, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ThreadMetadataChanged ->
                applyThreadStateUpdated(update.state, update.sessionSummary, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ThreadItemChanged -> {
                if (!applyThreadItemChanged(update.key, update.item)) {
                    recoverThreadDeltaApplication(update.key)
                }
                // Reducer piggybacks the refreshed per-thread summary on
                // every item change; patch our local session-summary cache
                // so home-list derived fields (stats, last tool label, etc.)
                // stay in sync with streaming items without waiting for a
                // full snapshot rebuild.
                applySessionSummary(update.sessionSummary)
            }
            is AppStoreUpdateRecord.ThreadStreamingDelta -> {
                if (!applyThreadStreamingDelta(update.key, update.itemId, update.kind, update.text)) {
                    recoverThreadDeltaApplication(update.key)
                }
            }
            is AppStoreUpdateRecord.ThreadRemoved ->
                removeThreadSnapshot(update.key, update.agentDirectoryVersion)
            is AppStoreUpdateRecord.ActiveThreadChanged -> {
                updateActiveThread(update.key)
                if (update.key != null && threadSnapshot(update.key) == null) {
                    refreshThreadSnapshot(update.key)
                }
                scheduleDeferredActiveThreadHydrationIfNeeded(update.key)
            }
            is AppStoreUpdateRecord.PendingApprovalsChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.PendingUserInputsChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.ServerChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.ServerRemoved -> refreshSnapshot()
            is AppStoreUpdateRecord.FullResync -> refreshSnapshot()
            is AppStoreUpdateRecord.VoiceSessionChanged -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeTranscriptUpdated -> Unit
            is AppStoreUpdateRecord.RealtimeHandoffRequested -> Unit
            is AppStoreUpdateRecord.RealtimeSpeechStarted -> Unit
            is AppStoreUpdateRecord.RealtimeStarted -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeSdp -> Unit
            is AppStoreUpdateRecord.RealtimeOutputAudioDelta -> Unit
            is AppStoreUpdateRecord.RealtimeError -> refreshSnapshot()
            is AppStoreUpdateRecord.RealtimeClosed -> refreshSnapshot()
            is AppStoreUpdateRecord.SavedAppsChanged -> {
                // R3: Rust broadcasts this whenever the saved-apps index/HTML/
                // state changes (show_widget finalize, update, delete). Reload
                // the Kotlin mirror so home-row takeover and Apps list can
                // react without a full snapshot churn.
                try {
                    SavedAppsStore.reload(appContext)
                } catch (_: Exception) {}
            }
            is AppStoreUpdateRecord.DynamicWidgetStreaming ->
                applyStreamingWidget(update.key, update.itemId, update.widget)
        }
    }

    /// Mutate an in-flight widget bubble's data so the timeline WebView
    /// picks up the growing HTML via its existing pushWidgetContent path.
    /// The reducer guarantees `isFinalized == false` on these; the
    /// finalized update arrives separately as ThreadItemChanged and must
    /// win.
    private fun applyStreamingWidget(
        key: ThreadKey,
        itemId: String,
        widget: uniffi.codex_mobile_client.HydratedWidgetData,
    ) {
        val current = _snapshot.value ?: return
        val threadIndex = current.threads.indexOfFirst { it.key == key }
        if (threadIndex < 0) return
        val thread = current.threads[threadIndex]
        val itemIndex = thread.hydratedConversationItems.indexOfFirst { it.id == itemId }
        val updatedItems = thread.hydratedConversationItems.toMutableList()
        if (itemIndex >= 0) {
            val item = updatedItems[itemIndex]
            val content = item.content
            // Before the first delta the item is a generic DynamicToolCall
            // (no args → hydration returns None → item stays as tool-call).
            // Replace its content unconditionally with the hydrated widget,
            // except when it's already a finalized widget (stale delta).
            if (content is HydratedConversationItemContent.Widget) {
                if (content.v1.isFinalized) return
                if (content.v1 == widget) return
            }
            updatedItems[itemIndex] = item.copy(
                content = HydratedConversationItemContent.Widget(widget),
            )
        } else {
            // First delta raced ThreadItemStarted. Synthesize a placeholder
            // so the bubble appears now; the later ThreadItemStarted/Changed
            // will overwrite with the canonical hydrated item.
            updatedItems.add(
                HydratedConversationItem(
                    id = itemId,
                    content = HydratedConversationItemContent.Widget(widget),
                    sourceTurnId = thread.activeTurnId,
                    sourceTurnIndex = null,
                    timestamp = null,
                    isFromUserTurnBoundary = false,
                ),
            )
        }
        applyThreadSnapshot(thread.copy(hydratedConversationItems = updatedItems))
    }

    private suspend fun recoverThreadDeltaApplication(key: ThreadKey) {
        val current = _snapshot.value
        val threadMissing = current?.threads?.any { it.key == key } != true
        val summaryMissing = current?.sessionSummaries?.any { it.key == key } != true
        if (threadMissing && summaryMissing) {
            refreshSnapshot()
        } else {
            refreshThreadSnapshot(key)
        }
    }

    suspend fun refreshThreadSnapshot(key: ThreadKey) {
        if (_snapshot.value == null) {
            refreshSnapshot()
            return
        }

        try {
            val threadSnapshot = store.threadSnapshot(key)
            if (threadSnapshot == null) {
                if (cachedThreadSnapshots[key] == null) {
                    removeThreadSnapshot(key, clearCache = false)
                }
                return
            }
            applyThreadSnapshot(threadSnapshot)
        } catch (e: Exception) {
            _lastError.value = e.message
            refreshSnapshot()
        }
    }

    private fun scheduleBackgroundThreadPermissionHydration(key: ThreadKey) {
        scope.launch {
            try {
                val nextKey = client.readThread(
                    key.serverId,
                    AppReadThreadRequest(
                        threadId = key.threadId,
                        includeTurns = false,
                    ),
                )
                val threadSnapshot = store.threadSnapshot(nextKey)
                if (threadSnapshot != null) {
                    applyThreadSnapshot(threadSnapshot)
                    launchState.syncFromThread(threadSnapshot)
                } else {
                    refreshSnapshot()
                    launchState.syncFromThread(snapshot.value?.threads?.firstOrNull { it.key == nextKey })
                }
            } catch (e: Exception) {
                _lastError.value = e.message
            }
        }
    }

    private fun scheduleDeferredActiveThreadHydrationIfNeeded(key: ThreadKey?) {
        if (key == null) {
            pendingActiveThreadHydrationJob?.cancel()
            pendingActiveThreadHydrationJob = null
            pendingActiveThreadHydrationKey = null
            return
        }

        val thread = threadSnapshot(key)
        if (thread == null || !shouldAttemptDeferredHydration(thread)) {
            if (pendingActiveThreadHydrationKey == key) {
                pendingActiveThreadHydrationJob?.cancel()
                pendingActiveThreadHydrationJob = null
                pendingActiveThreadHydrationKey = null
            }
            return
        }

        if (pendingActiveThreadHydrationKey == key && pendingActiveThreadHydrationJob != null) {
            return
        }

        pendingActiveThreadHydrationJob?.cancel()
        pendingActiveThreadHydrationKey = key
        pendingActiveThreadHydrationJob = scope.launch {
            delay(300)
            hydrateActiveThreadIfNeeded(key)
        }
    }

    private suspend fun hydrateActiveThreadIfNeeded(key: ThreadKey) {
        try {
            val current = snapshot.value
            val thread = threadSnapshot(key)
            if (current?.activeThread != key || thread == null || !shouldAttemptDeferredHydration(thread)) {
                return
            }

            val nextKey = client.readThread(
                key.serverId,
                AppReadThreadRequest(
                    threadId = key.threadId,
                    includeTurns = false,
                ),
            )
            val threadSnapshot = store.threadSnapshot(nextKey)
            if (threadSnapshot != null) {
                applyThreadSnapshot(threadSnapshot)
            } else {
                refreshThreadSnapshot(nextKey)
            }
        } catch (e: Exception) {
            _lastError.value = e.message
        } finally {
            if (pendingActiveThreadHydrationKey == key) {
                pendingActiveThreadHydrationJob = null
                pendingActiveThreadHydrationKey = null
            }
        }
    }

    private fun shouldAttemptDeferredHydration(thread: AppThreadSnapshot): Boolean {
        if (thread.hydratedConversationItems.isNotEmpty()) return false
        val preview = thread.info.preview?.trim().orEmpty()
        val title = thread.info.title?.trim().orEmpty()
        return preview.isNotEmpty() || title.isNotEmpty() || thread.hasActiveTurn
    }

    private fun applyThreadSnapshot(thread: AppThreadSnapshot) {
        val mergedThread = mergedThreadSnapshotPreservingHydratedItems(thread)
        val current = _snapshot.value
        if (current == null) {
            cacheThreadSnapshot(mergedThread)
            return
        }
        val existingIndex = current.threads.indexOfFirst { it.key == thread.key }
        val updatedThreads = current.threads.toMutableList().apply {
            if (existingIndex >= 0) {
                this[existingIndex] = mergedThread
            } else {
                add(mergedThread)
            }
        }
        _snapshot.value = current.copy(threads = updatedThreads)
        cacheThreadSnapshot(mergedThread)
        _lastError.value = null
    }

    private fun applyThreadUpsert(
        thread: AppThreadSnapshot,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: ULong,
    ) {
        val mergedThread = mergedThreadSnapshotPreservingHydratedItems(thread)
        val current = _snapshot.value ?: return
        val existingThreadIndex = current.threads.indexOfFirst { it.key == thread.key }

        // Race condition guard: during active streaming, if the old thread has
        // longer assistant text that starts with the new text, preserve the old
        // (more complete) text to avoid flickering backwards.
        val finalThread = if (existingThreadIndex >= 0) {
            val oldThread = current.threads[existingThreadIndex]
            if (oldThread.hasActiveTurn) {
                preserveStreamingText(oldThread, mergedThread)
            } else {
                mergedThread
            }
        } else {
            mergedThread
        }

        val updatedThreads = current.threads.toMutableList().apply {
            if (existingThreadIndex >= 0) {
                this[existingThreadIndex] = finalThread
            } else {
                add(finalThread)
            }
        }

        val adjustedSummary = applySavedServerName(sessionSummary)
        val existingSummaryIndex = current.sessionSummaries.indexOfFirst { it.key == adjustedSummary.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingSummaryIndex >= 0) {
                this[existingSummaryIndex] = adjustedSummary
            } else {
                add(adjustedSummary)
            }
            sortWith(compareByDescending<AppSessionSummary> { it.updatedAt ?: Long.MIN_VALUE }
                .thenBy { it.key.serverId }
                .thenBy { it.key.threadId })
        }

        _snapshot.value = current.copy(
            threads = updatedThreads,
            sessionSummaries = updatedSummaries,
            agentDirectoryVersion = agentDirectoryVersion,
        )
        cacheThreadSnapshot(finalThread)
        _lastError.value = null
    }

    private fun preserveStreamingText(
        oldThread: AppThreadSnapshot,
        newThread: AppThreadSnapshot,
    ): AppThreadSnapshot {
        if (newThread.hydratedConversationItems.isEmpty()) return newThread
        val oldItemsById = oldThread.hydratedConversationItems.associateBy { it.id }
        var changed = false
        val mergedItems = newThread.hydratedConversationItems.map { newItem ->
            val oldItem = oldItemsById[newItem.id]
            if (oldItem != null) {
                val oldText = assistantText(oldItem.content)
                val newText = assistantText(newItem.content)
                if (oldText != null && newText != null &&
                    oldText.length > newText.length &&
                    oldText.startsWith(newText)
                ) {
                    changed = true
                    oldItem
                } else {
                    newItem
                }
            } else {
                newItem
            }
        }
        return if (changed) newThread.copy(hydratedConversationItems = mergedItems) else newThread
    }

    private fun assistantText(content: HydratedConversationItemContent): String? =
        when (content) {
            is HydratedConversationItemContent.Assistant -> content.v1.text
            else -> null
        }

    private fun applyThreadStateUpdated(
        state: uniffi.codex_mobile_client.AppThreadStateRecord,
        sessionSummary: AppSessionSummary,
        agentDirectoryVersion: ULong,
    ) {
        val current = _snapshot.value ?: return
        val existingThreadIndex = current.threads.indexOfFirst { it.key == state.key }
        if (existingThreadIndex < 0) return

        val existingThread = current.threads[existingThreadIndex]
        val updatedThread = existingThread.copy(
            info = state.info,
            collaborationMode = state.collaborationMode,
            model = state.model,
            reasoningEffort = state.reasoningEffort,
            effectiveApprovalPolicy = state.effectiveApprovalPolicy,
            effectiveSandboxPolicy = state.effectiveSandboxPolicy,
            activeTurnId = state.activeTurnId,
            activePlanProgress = state.activePlanProgress,
            pendingPlanImplementationPrompt = state.pendingPlanImplementationPrompt,
            contextTokensUsed = state.contextTokensUsed,
            modelContextWindow = state.modelContextWindow,
            rateLimits = state.rateLimits,
            realtimeSessionId = state.realtimeSessionId,
            olderTurnsCursor = state.olderTurnsCursor,
            initialTurnsLoaded = state.initialTurnsLoaded,
        )
        val updatedThreads = current.threads.toMutableList().apply {
            this[existingThreadIndex] = updatedThread
        }

        val adjustedSummary = applySavedServerName(sessionSummary)
        val existingSummaryIndex = current.sessionSummaries.indexOfFirst { it.key == adjustedSummary.key }
        val updatedSummaries = current.sessionSummaries.toMutableList().apply {
            if (existingSummaryIndex >= 0) {
                this[existingSummaryIndex] = adjustedSummary
            } else {
                add(adjustedSummary)
            }
            sortWith(compareByDescending<AppSessionSummary> { it.updatedAt ?: Long.MIN_VALUE }
                .thenBy { it.key.serverId }
                .thenBy { it.key.threadId })
        }

        _snapshot.value = current.copy(
            threads = updatedThreads,
            sessionSummaries = updatedSummaries,
            agentDirectoryVersion = agentDirectoryVersion,
        )
        cacheThreadSnapshot(updatedThread)
        _lastError.value = null
    }

    private fun applyThreadItemChanged(
        key: ThreadKey,
        item: HydratedConversationItem,
    ): Boolean {
        val current = _snapshot.value ?: return false
        val threadIndex = current.threads.indexOfFirst { it.key == key }
        if (threadIndex < 0) return false

        val thread = current.threads[threadIndex]
        val updatedItems = thread.hydratedConversationItems.toMutableList()
        val existingItemIndex = updatedItems.indexOfFirst { it.id == item.id }
        if (existingItemIndex >= 0) {
            updatedItems[existingItemIndex] = item
        } else {
            val insertionIndex = insertionIndexForItem(updatedItems, item)
            updatedItems.add(insertionIndex, item)
        }
        applyThreadSnapshot(thread.copy(hydratedConversationItems = updatedItems))
        return true
    }

    private fun applyThreadStreamingDelta(
        key: ThreadKey,
        itemId: String,
        kind: ThreadStreamingDeltaKind,
        text: String,
    ): Boolean {
        val current = _snapshot.value ?: return false
        val threadIndex = current.threads.indexOfFirst { it.key == key }
        if (threadIndex < 0) return false

        val thread = current.threads[threadIndex]
        val itemIndex = thread.hydratedConversationItems.indexOfFirst { it.id == itemId }
        if (itemIndex < 0) return false

        val updatedContent = applyStreamingDelta(kind, text, thread.hydratedConversationItems[itemIndex].content)
            ?: return false
        val updatedItems = thread.hydratedConversationItems.toMutableList().apply {
            this[itemIndex] = this[itemIndex].copy(content = updatedContent)
        }
        applyThreadSnapshot(thread.copy(hydratedConversationItems = updatedItems))
        return true
    }

    private fun applyStreamingDelta(
        kind: ThreadStreamingDeltaKind,
        text: String,
        content: HydratedConversationItemContent,
    ): HydratedConversationItemContent? = when (kind) {
        ThreadStreamingDeltaKind.ASSISTANT_TEXT -> when (content) {
            is HydratedConversationItemContent.Assistant ->
                HydratedConversationItemContent.Assistant(content.v1.copy(text = content.v1.text + text))
            else -> null
        }
        ThreadStreamingDeltaKind.REASONING_TEXT -> when (content) {
            is HydratedConversationItemContent.Reasoning -> {
                val updatedContent = content.v1.content.toMutableList().apply {
                    if (isEmpty()) {
                        add(text)
                    } else {
                        this[lastIndex] = this[lastIndex] + text
                    }
                }
                HydratedConversationItemContent.Reasoning(content.v1.copy(content = updatedContent))
            }
            else -> null
        }
        ThreadStreamingDeltaKind.PLAN_TEXT -> when (content) {
            is HydratedConversationItemContent.ProposedPlan ->
                HydratedConversationItemContent.ProposedPlan(content.v1.copy(content = content.v1.content + text))
            else -> null
        }
        ThreadStreamingDeltaKind.COMMAND_OUTPUT -> when (content) {
            is HydratedConversationItemContent.CommandExecution ->
                HydratedConversationItemContent.CommandExecution(
                    content.v1.copy(output = (content.v1.output ?: "") + text)
                )
            else -> null
        }
        ThreadStreamingDeltaKind.MCP_PROGRESS -> when (content) {
            is HydratedConversationItemContent.McpToolCall -> {
                val updatedProgress = content.v1.progressMessages.toMutableList().apply {
                    if (text.isNotBlank()) {
                        add(text)
                    }
                }
                HydratedConversationItemContent.McpToolCall(
                    content.v1.copy(progressMessages = updatedProgress)
                )
            }
            else -> null
        }
    }

    private fun insertionIndexForItem(
        items: List<HydratedConversationItem>,
        item: HydratedConversationItem,
    ): Int {
        val targetTurn = item.sourceTurnIndex?.toInt() ?: return items.size
        val lastSameTurn = items.indexOfLast { it.sourceTurnIndex?.toInt() == targetTurn }
        if (lastSameTurn >= 0) return lastSameTurn + 1

        val nextTurn = items.indexOfFirst {
            val sourceTurn = it.sourceTurnIndex?.toInt()
            sourceTurn != null && sourceTurn > targetTurn
        }
        return if (nextTurn >= 0) nextTurn else items.size
    }

    private fun hasAuthoritativePermissions(thread: AppThreadSnapshot): Boolean =
        threadPermissionsAreAuthoritative(
            approvalPolicy = thread.effectiveApprovalPolicy,
            sandboxPolicy = thread.effectiveSandboxPolicy,
        )

    private fun removeThreadSnapshot(
        key: ThreadKey,
        agentDirectoryVersion: ULong? = null,
        clearCache: Boolean = true,
    ) {
        val current = _snapshot.value ?: return
        _snapshot.value = current.copy(
            threads = current.threads.filterNot { it.key == key },
            sessionSummaries = current.sessionSummaries.filterNot { it.key == key },
            agentDirectoryVersion = agentDirectoryVersion ?: current.agentDirectoryVersion,
            activeThread = if (current.activeThread == key) null else current.activeThread,
        )
        if (clearCache) {
            cachedThreadSnapshots.remove(key)
        }
    }

    private fun updateActiveThread(key: ThreadKey?) {
        val current = _snapshot.value ?: return
        _snapshot.value = current.copy(activeThread = key)
    }

    fun threadSnapshot(key: ThreadKey): AppThreadSnapshot? =
        _snapshot.value?.threads?.firstOrNull { it.key == key } ?: cachedThreadSnapshots[key]

    private fun hasFreshConversationMetadata(serverId: String): Boolean {
        val server = snapshot.value?.servers?.firstOrNull { it.serverId == serverId } ?: return false
        val hasModels = server.availableModels != null
        val hasRateLimits = server.account == null || server.rateLimits != null
        if (hasModels && hasRateLimits) return true

        val lastLoad = recentConversationMetadataLoads[serverId] ?: return false
        return System.currentTimeMillis() - lastLoad < 10_000L
    }

    private fun restoreCachedThreadSnapshotIfNeeded(key: ThreadKey?) {
        if (key == null) return
        if (_snapshot.value?.threads?.any { it.key == key } == true) return
        val cached = cachedThreadSnapshots[key] ?: return
        applyThreadSnapshot(cached)
    }

    private fun cacheThreadSnapshot(thread: AppThreadSnapshot) {
        cachedThreadSnapshots[thread.key] = thread
    }

    private fun mergedThreadSnapshotPreservingHydratedItems(thread: AppThreadSnapshot): AppThreadSnapshot {
        if (thread.hydratedConversationItems.isNotEmpty()) return thread
        val cached = cachedThreadSnapshots[thread.key] ?: return thread
        if (cached.hydratedConversationItems.isEmpty()) return thread
        return thread.copy(hydratedConversationItems = cached.hydratedConversationItems)
    }

    private fun mergeCachedThreadSnapshots(snapshot: AppSnapshotRecord): AppSnapshotRecord {
        val mergedThreads = snapshot.threads
            .map(::mergedThreadSnapshotPreservingHydratedItems)
            .toMutableList()

        cachedThreadSnapshots.forEach { (key, cached) ->
            val alreadyPresent = mergedThreads.any { it.key == key }
            val shouldInclude = snapshot.activeThread == key || snapshot.sessionSummaries.any { it.key == key }
            if (!alreadyPresent && shouldInclude) {
                mergedThreads += cached
            }
        }

        return snapshot.copy(threads = mergedThreads)
    }
}

private fun registerBundledCliTools() {
    val tools = emptyMap<String, String>()
    try {
        registerAndroidTools(tools)
        android.util.Log.i(
            "AppModel",
            "Registered ${tools.size} bundled CLI tools: ${tools.keys}",
        )
    } catch (e: Throwable) {
        android.util.Log.w("AppModel", "registerAndroidTools failed: ${e.message}")
    }
}
