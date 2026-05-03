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
        val results = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, results)
        appModel.refreshSnapshot()
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
        val results = appModel.reconnectController.onAppBecameActive()
        restoreLocalStateAfterReconnect(appModel, results)
        backgroundedTurnKeys.clear()
        keysToRefresh.forEach { key ->
            appModel.refreshThreadSnapshot(key)
        }
    }

    /**
     * Called when the app goes to background.
     * Tracks active turns for notification on completion.
     */
    fun onPause(context: Context, appModel: AppModel) {
        appModel.reconnectController.onAppEnteredBackground()
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
            if (!result.needsLocalAuthRestore) {
                continue
            }
            appModel.restoreStoredLocalAuthState(result.serverId)
            runCatching {
                appModel.refreshSessions(listOf(result.serverId))
            }
        }
    }
}
