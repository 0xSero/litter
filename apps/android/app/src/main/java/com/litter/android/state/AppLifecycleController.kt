package com.litter.android.state

import android.content.Context
import com.litter.android.push.PushProxyClient
import com.litter.android.util.LLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey

/**
 * Handles app lifecycle events: server reconnection on resume,
 * background turn tracking on pause, and push notification handling.
 *
 * Reconnect orchestration is delegated to the shared Rust [ReconnectController].
 */
class AppLifecycleController {

    /** Threads that were active when the app went to background. */
    private val backgroundedTurnKeys = mutableSetOf<ThreadKey>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pushProxy = PushProxyClient()
    private val pushProxyLock = Any()
    private var pushProxyRegistrationId: String? = null
    private var pushProxyGeneration: Long = 0

    /**
     * Wall-clock timestamp (epoch ms) of the most recent [onPause].
     * Used to decide whether the existing alleycat `Connection` is
     * almost certainly dead by the time we resume — see
     * [LONG_RESUME_THRESHOLD_MS] and `onLongResume`.
     */
    private var lastBackgroundedAt: Long? = null

    /** FCM device push token. */
    var devicePushToken: String? = null
        private set

    fun setDevicePushToken(token: String) {
        devicePushToken = token
    }

    /**
     * Reconnects all saved servers on app launch or resume.
     */
    suspend fun reconnectSavedServers(context: Context, appModel: AppModel) {
        val servers = SavedServerStore.remembered(context).map { it.toRecord(context) }
        appModel.reconnectController.setMultiClankerAndQuicEnabled(true)
        appModel.reconnectController.syncSavedServers(servers)
        // Hint iroh-backed sessions about a potential network change before
        // running reconnect — alleycat can recover via path migration.
        appModel.reconnectController.notifyNetworkChange()
        val results = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, results)
        val retryResults = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, retryResults)
        // Load the first page of sessions synchronously so the snapshot has
        // real thread data and accurate `session_list_has_more` cursors.
        // bare refreshSnapshot() captured a stale store before the
        // fire-and-forget warmup could finish.
        val connectedServerIds = results.map { it.serverId }
        if (connectedServerIds.isNotEmpty()) {
            appModel.loadSessionsPage(connectedServerIds, limit = 20u)
        } else {
            appModel.refreshSnapshot()
        }
        // If reconnecting saved alleycat servers triggered the iroh
        // endpoint bind, persist any freshly-generated device key.
        appModel.persistAlleycatSecretKeyIfNeeded()
    }

    /**
     * Reconnects a single server by ID.
     */
    suspend fun reconnectServer(context: Context, appModel: AppModel, serverId: String) {
        val servers = SavedServerStore.load(context).map { it.toRecord(context) }
        appModel.reconnectController.setMultiClankerAndQuicEnabled(true)
        appModel.reconnectController.syncSavedServers(servers)
        val result = appModel.reconnectController.reconnectServer(serverId)
        restoreLocalStateAfterReconnect(appModel, listOf(result))
        appModel.refreshSnapshot()
    }

    /**
     * Called when the app enters the foreground.
     */
    suspend fun onResume(context: Context, appModel: AppModel) {
        synchronized(pushProxyLock) {
            pushProxyGeneration += 1
        }
        deregisterPushProxy()
        val keysToRefresh = buildSet {
            addAll(backgroundedTurnKeys)
            appModel.snapshot.value?.activeThread?.let(::add)
        }
        val servers = SavedServerStore.remembered(context).map { it.toRecord(context) }
        appModel.reconnectController.setMultiClankerAndQuicEnabled(true)
        appModel.reconnectController.syncSavedServers(servers)

        // If we were suspended longer than iroh's per-path idle timeout,
        // the existing alleycat Connection is almost certainly dead. Kill
        // it before the user can issue a request — otherwise the worker's
        // first request would wait the full 30s connection-idle timeout
        // for iroh to declare the path dead. Fires BEFORE
        // `onAppBecameActive` so the close lands before the
        // network-change hint and saved-server reconnect.
        val backgroundedAt = lastBackgroundedAt
        lastBackgroundedAt = null
        if (backgroundedAt != null) {
            val durationMs = System.currentTimeMillis() - backgroundedAt
            if (durationMs > LONG_RESUME_THRESHOLD_MS) {
                LLog.i(
                    "AppLifecycleController",
                    "long resume — abandoning live alleycat connections backgroundDurationSec=${durationMs / 1000}",
                )
                appModel.reconnectController.onLongResume()
            }
        }

        val results = appModel.reconnectController.onAppBecameActive()
        restoreLocalStateAfterReconnect(appModel, results)
        val retryResults = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, retryResults)
        backgroundedTurnKeys.clear()
        keysToRefresh.forEach { key ->
            // Force-authoritative: a turn that completed during a long
            // suspension fired `TurnCompleted` while no client connection
            // was attached, so the local snapshot still shows the turn
            // as in-progress. Pull back `excludeTurns = false` so
            // `reconcile_active_turn` can clear the stale
            // `active_turn_id` — otherwise the user sees a "thinking"
            // spinner whose `turn/interrupt` attempts get rejected with
            // "no active turn to interrupt".
            try {
                appModel.forceRefreshThreadAuthoritative(key)
            } catch (error: Exception) {
                LLog.w(
                    "AppLifecycleController",
                    "force-authoritative refresh failed; falling back to refreshThreadSnapshot: ${error.message}",
                )
                appModel.refreshThreadSnapshot(key)
            }
        }
        // Capture any freshly-generated alleycat device secret key from
        // this foreground's reconnect cycle.
        appModel.persistAlleycatSecretKeyIfNeeded()
    }

    /**
     * Called when the app goes to background.
     * Tracks active turns for notification on completion.
     */
    fun onPause(context: Context, appModel: AppModel) {
        appModel.reconnectController.onAppEnteredBackground()
        lastBackgroundedAt = System.currentTimeMillis()
        backgroundedTurnKeys.clear()
        val snap = appModel.snapshot.value ?: return
        for (thread in snap.threads) {
            if (thread.activeTurnId != null) {
                backgroundedTurnKeys.add(thread.key)
            }
        }
        if (backgroundedTurnKeys.isNotEmpty()) {
            registerPushProxy(context)
        }
    }

    private companion object {
        /**
         * Threshold for triggering proactive `Connection::close()` on
         * resume. Tied to iroh's per-path idle timeout (default 15s):
         * if we were suspended longer, the existing path is almost
         * certainly dead and waiting on iroh's connection-level idle
         * timer would make the next user request hang for the
         * remainder of that window.
         */
        const val LONG_RESUME_THRESHOLD_MS = 15_000L
    }

    private fun registerPushProxy(context: Context) {
        val generation = synchronized(pushProxyLock) {
            if (pushProxyRegistrationId != null) return
            pushProxyGeneration
        }
        val token = devicePushToken ?: context
            .getSharedPreferences("litter_push", Context.MODE_PRIVATE)
            .getString("fcm_token", null)
            ?.takeIf { it.isNotBlank() }
        if (token.isNullOrBlank()) {
            LLog.i("AppLifecycleController", "Skipping push proxy registration; no FCM token")
            return
        }

        val trackedKeys = backgroundedTurnKeys.toList()
        val primaryKey = trackedKeys.firstOrNull()
        scope.launch {
            try {
                val registrationId = pushProxy.register(
                    platform = "android",
                    pushToken = token,
                    contentState = mapOf(
                        "phase" to "thinking",
                        "elapsedSeconds" to 0,
                        "toolCallCount" to 0,
                        "activeThreadCount" to trackedKeys.size,
                        "serverId" to (primaryKey?.serverId ?: ""),
                        "threadId" to (primaryKey?.threadId ?: ""),
                    ),
                    startTimestamp = System.currentTimeMillis() / 1000,
                )
                val shouldKeepRegistration = synchronized(pushProxyLock) {
                    if (pushProxyGeneration == generation && pushProxyRegistrationId == null) {
                        pushProxyRegistrationId = registrationId
                        true
                    } else {
                        false
                    }
                }
                if (!shouldKeepRegistration) {
                    pushProxy.deregister(registrationId)
                    LLog.i("AppLifecycleController", "Deregistered stale push proxy $registrationId")
                    return@launch
                }
                LLog.i("AppLifecycleController", "Registered push proxy $registrationId")
            } catch (error: Exception) {
                LLog.e("AppLifecycleController", "Push proxy registration failed", error)
            }
        }
    }

    private fun deregisterPushProxy() {
        val registrationId = synchronized(pushProxyLock) {
            val id = pushProxyRegistrationId ?: return
            pushProxyRegistrationId = null
            id
        }
        scope.launch {
            try {
                pushProxy.deregister(registrationId)
                LLog.i("AppLifecycleController", "Deregistered push proxy $registrationId")
            } catch (error: Exception) {
                LLog.e("AppLifecycleController", "Push proxy deregistration failed", error)
            }
        }
    }

    private suspend fun restoreLocalStateAfterReconnect(
        appModel: AppModel,
        results: List<uniffi.codex_mobile_client.ReconnectResult>,
    ) {
        for (result in results) {
            if (result.needsLocalAuthRestore) {
                appModel.restoreStoredLocalAuthState(result.serverId)
            }
        }
    }
}
