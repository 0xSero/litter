package com.litter.android.ui.home

import android.os.Process
import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import com.litter.android.state.SavedServer
import com.litter.android.state.currentConnectionStep
import com.litter.android.state.isConnected
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.delay
import uniffi.codex_mobile_client.AppConnectionStepState
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppServerTransportState
import java.util.concurrent.ConcurrentHashMap

/**
 * The one mono word shown next to a server that is not healthy. Healthy
 * servers show nothing. Used by the Home switcher and the Settings server list.
 */
enum class ServerLinkLabel(val text: String) {
    CONNECTING("connecting…"),
    RECONNECTING("reconnecting…"),
    OFFLINE("offline"),
    ;

    /** Quiet meta color for transient states, danger only for offline. */
    val color: Color
        get() = if (this == OFFLINE) LitterTheme.danger else LitterTheme.textSecondary
}

/**
 * Process-wide memory of which servers have been connected at least once, so
 * a later drop reads "reconnecting…" instead of "connecting…".
 */
object ServerConnectionMemory {
    private val everConnected = ConcurrentHashMap.newKeySet<String>()

    fun note(servers: List<AppServerSnapshot>) {
        servers.forEach { if (it.isConnected) everConnected.add(it.serverId) }
    }

    fun wasConnected(serverId: String): Boolean = serverId in everConnected

    /**
     * Saved servers are reconnected in the background at launch. Until this
     * window closes, a saved server with no live state yet reads as
     * "connecting…" rather than "offline".
     */
    const val LAUNCH_WINDOW_MS = 30_000L

    fun launchWindowRemainingMs(): Long {
        val sinceStart = SystemClock.uptimeMillis() - Process.getStartUptimeMillis()
        return (LAUNCH_WINDOW_MS - sinceStart).coerceAtLeast(0L)
    }
}

/** Label for a server present in the snapshot; null when healthy. */
fun serverLinkLabel(server: AppServerSnapshot, launchWindowOpen: Boolean): ServerLinkLabel? {
    val wasConnected = ServerConnectionMemory.wasConnected(server.serverId)
    val step = server.currentConnectionStep?.state
    return when {
        step == AppConnectionStepState.FAILED -> ServerLinkLabel.OFFLINE
        server.transportState == AppServerTransportState.CONNECTED -> null
        server.connectionProgress != null ||
            server.transportState == AppServerTransportState.CONNECTING ||
            server.transportState == AppServerTransportState.UNRESPONSIVE ->
            if (wasConnected) ServerLinkLabel.RECONNECTING else ServerLinkLabel.CONNECTING
        launchWindowOpen -> if (wasConnected) ServerLinkLabel.RECONNECTING else ServerLinkLabel.CONNECTING
        else -> ServerLinkLabel.OFFLINE
    }
}

/** True while saved servers may still be coming up after process start. */
@Composable
fun rememberLaunchWindowOpen(): Boolean {
    var open by remember { mutableStateOf(ServerConnectionMemory.launchWindowRemainingMs() > 0) }
    LaunchedEffect(open) {
        if (!open) return@LaunchedEffect
        delay(ServerConnectionMemory.launchWindowRemainingMs())
        open = false
    }
    return open
}

/**
 * A row in the Home server switcher. [snapshot] is null for a remembered
 * saved server the Rust store has not reported yet (the first frames after
 * launch), so the switcher can show it in place from the first frame.
 */
data class HomeServerEntry(
    val serverId: String,
    val displayName: String,
    val snapshot: AppServerSnapshot?,
    val label: ServerLinkLabel?,
    val isLocal: Boolean,
)

/**
 * Visible servers first (existing order), then remembered saved servers that
 * are not visible yet. Saved servers are matched by id or host:port so a
 * server never appears twice.
 */
internal fun homeServerEntries(
    visible: List<AppServerSnapshot>,
    allSnapshotServers: List<AppServerSnapshot>,
    remembered: List<SavedServer>,
    launchWindowOpen: Boolean,
): List<HomeServerEntry> {
    val entries = visible.map { server ->
        HomeServerEntry(
            serverId = server.serverId,
            displayName = server.displayName,
            snapshot = server,
            label = serverLinkLabel(server, launchWindowOpen),
            isLocal = server.isLocal,
        )
    }
    val seenIds = visible.mapTo(HashSet()) { it.serverId }
    val seenHosts = visible.mapTo(HashSet()) { "${it.host.lowercase()}:${it.port}" }
    val rawById = allSnapshotServers.associateBy { it.serverId }
    val pending = remembered
        .filter { saved ->
            saved.id !in seenIds &&
                "${saved.hostname.lowercase()}:${saved.port}" !in seenHosts
        }
        .distinctBy { it.id }
        .map { saved ->
            val raw = rawById[saved.id]
            val label = if (raw != null) {
                serverLinkLabel(raw, launchWindowOpen)
            } else if (launchWindowOpen) {
                if (ServerConnectionMemory.wasConnected(saved.id)) {
                    ServerLinkLabel.RECONNECTING
                } else {
                    ServerLinkLabel.CONNECTING
                }
            } else {
                ServerLinkLabel.OFFLINE
            }
            HomeServerEntry(
                serverId = saved.id,
                displayName = raw?.displayName ?: saved.name.ifBlank { saved.hostname },
                snapshot = raw,
                label = label,
                isLocal = saved.source == "local",
            )
        }
    return entries + pending
}
