package com.litter.android.state

import com.litter.android.util.LLog
import uniffi.codex_mobile_client.SshBridge
import java.util.concurrent.ConcurrentHashMap

/**
 * Thread-safe tracking of SSH session IDs per server.
 * Allows cleanup of SSH sessions on server disconnect.
 */
class SshSessionStore(private val ssh: SshBridge) {
    private val sessions = ConcurrentHashMap<String, String>() // serverId → sessionId

    fun record(serverId: String, sessionId: String) {
        LLog.t("SshSessionStore", "record SSH session", fields = mapOf("serverId" to serverId, "sessionId" to sessionId))
        sessions[serverId] = sessionId
    }

    fun clear(serverId: String) {
        LLog.t("SshSessionStore", "clear SSH session", fields = mapOf("serverId" to serverId))
        sessions.remove(serverId)
    }

    suspend fun close(serverId: String) {
        val sessionId = sessions.remove(serverId) ?: return
        LLog.t("SshSessionStore", "close SSH session", fields = mapOf("serverId" to serverId, "sessionId" to sessionId))
        try {
            ssh.sshClose(sessionId)
        } catch (e: Exception) {
            // Best-effort cleanup
            LLog.e("SshSessionStore", "failed to close SSH session", e, fields = mapOf("serverId" to serverId, "sessionId" to sessionId))
        }
    }
}
