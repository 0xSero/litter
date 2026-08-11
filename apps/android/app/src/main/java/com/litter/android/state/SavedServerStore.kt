package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.SavedServerRecord

/**
 * Persistent server list stored in SharedPreferences.
 * Platform-specific — cannot live in Rust.
 */
data class SavedServer(
    val id: String,
    val name: String,
    val hostname: String,
    val port: Int,
    val codexPorts: List<Int> = emptyList(),
    val sshPort: Int? = null,
    val source: String = "manual", // local, bonjour, tailscale, lanProbe, arpScan, ssh, manual
    val hasCodexServer: Boolean = false,
    val wakeMAC: String? = null,
    val preferredConnectionMode: String? = null, // directCodex or ssh
    val preferredCodexPort: Int? = null,
    val sshPortForwardingEnabled: Boolean? = null, // legacy migration only
    val websocketURL: String? = null,
    val os: String? = null,
    val sshBanner: String? = null,
    val rememberedByUser: Boolean = false,
    val alleycatHost: String? = null,
    val alleycatNodeId: String? = null,
    val alleycatRelay: String? = null,
    val alleycatAgentName: String? = null,
    val alleycatAgentWire: String? = null,
) {
    /** Stable key for deduplication across discovery cycles. */
    val deduplicationKey: String
        get() = websocketURL ?: normalizedHostKey(hostname)

    private fun normalizedHostKey(host: String): String {
        val trimmed = host.trim().trimStart('[').trimEnd(']')
        val withoutScope = if (!trimmed.contains(":")) {
            trimmed.substringBefore('%')
        } else {
            trimmed
        }
        return withoutScope.lowercase()
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("hostname", hostname)
        put("port", port)
        put("codexPorts", JSONArray(availableDirectCodexPorts))
        sshPort?.let { put("sshPort", it) }
        put("source", source)
        put("hasCodexServer", hasCodexServer)
        wakeMAC?.let { put("wakeMAC", it) }
        preferredConnectionMode?.let { put("preferredConnectionMode", it) }
        preferredCodexPort?.let { put("preferredCodexPort", it) }
        sshPortForwardingEnabled?.let { put("sshPortForwardingEnabled", it) }
        websocketURL?.let { put("websocketURL", it) }
        os?.let { put("os", it) }
        sshBanner?.let { put("sshBanner", it) }
        put("rememberedByUser", rememberedByUser)
        alleycatHost?.let { put("alleycatHost", it) }
        alleycatNodeId?.let { put("alleycatNodeId", it) }
        alleycatRelay?.let { put("alleycatRelay", it) }
        alleycatAgentName?.let { put("alleycatAgentName", it) }
        alleycatAgentWire?.let { put("alleycatAgentWire", it) }
    }

    val availableDirectCodexPorts: List<Int>
        get() {
            val ordered = buildList {
                if (hasCodexServer && port > 0) add(port)
                addAll(codexPorts.filter { it > 0 })
            }
            return ordered.distinct()
        }

    val resolvedPreferredConnectionMode: String?
        get() = when (preferredConnectionMode) {
            "directCodex" -> if (availableDirectCodexPorts.isNotEmpty() || websocketURL != null) "directCodex" else null
            "ssh" -> if (canConnectViaSsh) "ssh" else null
            else -> if (sshPortForwardingEnabled == true) "ssh" else null
        }

    val prefersSshConnection: Boolean
        get() = resolvedPreferredConnectionMode == "ssh"

    val canConnectViaSsh: Boolean
        get() = websocketURL == null && (
            sshPort != null ||
                source == "ssh" ||
                (!hasCodexServer && resolvedSshPort > 0) ||
                preferredConnectionMode == "ssh" ||
                sshPortForwardingEnabled == true
        )

    val resolvedSshPort: Int
        get() = sshPort ?: port.takeIf { !hasCodexServer && it > 0 } ?: 22

    val resolvedPreferredCodexPort: Int?
        get() = when {
            resolvedPreferredConnectionMode != "directCodex" -> null
            preferredCodexPort != null && availableDirectCodexPorts.contains(preferredCodexPort) -> preferredCodexPort
            else -> null
        }

    val requiresConnectionChoice: Boolean
        get() = websocketURL == null &&
            resolvedPreferredConnectionMode == null &&
            (
                availableDirectCodexPorts.size > 1 ||
                    (availableDirectCodexPorts.isNotEmpty() && canConnectViaSsh)
            )

    val directCodexPort: Int?
        get() = when {
            websocketURL != null -> null
            prefersSshConnection -> null
            resolvedPreferredCodexPort != null -> resolvedPreferredCodexPort
            requiresConnectionChoice -> null
            availableDirectCodexPorts.isNotEmpty() -> availableDirectCodexPorts.first()
            else -> null
        }

    fun withPreferredConnection(mode: String?, codexPort: Int? = null): SavedServer =
        copy(
            port = when (mode) {
                "directCodex" -> codexPort ?: directCodexPort ?: availableDirectCodexPorts.firstOrNull() ?: port
                "ssh" -> resolvedSshPort
                else -> port
            },
            codexPorts = availableDirectCodexPorts,
            sshPort = sshPort ?: if (canConnectViaSsh) resolvedSshPort else null,
            preferredConnectionMode = mode,
            preferredCodexPort = if (mode == "directCodex") {
                codexPort ?: directCodexPort ?: availableDirectCodexPorts.firstOrNull()
            } else {
                null
            },
            sshPortForwardingEnabled = null,
        )

    fun normalizedForPersistence(): SavedServer = withPreferredConnection(
        mode = resolvedPreferredConnectionMode,
        codexPort = resolvedPreferredCodexPort ?: availableDirectCodexPorts.firstOrNull(),
    )

    companion object {
        fun normalizeWakeMac(raw: String?): String? {
            val compact = raw
                ?.trim()
                ?.replace(":", "")
                ?.replace("-", "")
                ?.lowercase()
                ?: return null
            if (compact.length != 12 || compact.any { !it.isDigit() && it !in 'a'..'f' }) {
                return null
            }
            return buildString {
                compact.chunked(2).forEachIndexed { index, chunk ->
                    if (index > 0) append(':')
                    append(chunk)
                }
            }
        }

        fun fromJson(obj: JSONObject): SavedServer = SavedServer(
            id = obj.getString("id"),
            name = obj.optString("name", ""),
            hostname = obj.optString("hostname", ""),
            port = obj.optInt("port", 0),
            codexPorts = buildList {
                val ports = obj.optJSONArray("codexPorts")
                if (ports != null) {
                    for (index in 0 until ports.length()) {
                        add(ports.optInt(index))
                    }
                }
            },
            sshPort = if (obj.has("sshPort")) obj.getInt("sshPort") else null,
            source = obj.optString("source", "manual"),
            hasCodexServer = obj.optBoolean("hasCodexServer", false),
            wakeMAC = if (obj.has("wakeMAC")) obj.getString("wakeMAC") else null,
            preferredConnectionMode = obj.optString("preferredConnectionMode").ifBlank { null },
            preferredCodexPort = if (obj.has("preferredCodexPort")) obj.getInt("preferredCodexPort") else null,
            sshPortForwardingEnabled = if (obj.has("sshPortForwardingEnabled")) {
                obj.optBoolean("sshPortForwardingEnabled")
            } else {
                null
            },
            websocketURL = if (obj.has("websocketURL")) obj.getString("websocketURL") else null,
            os = if (obj.has("os")) obj.getString("os") else null,
            sshBanner = if (obj.has("sshBanner")) obj.getString("sshBanner") else null,
            rememberedByUser = if (obj.has("rememberedByUser")) {
                obj.optBoolean("rememberedByUser")
            } else {
                true
            },
            alleycatHost = if (obj.has("alleycatHost")) obj.getString("alleycatHost") else null,
            alleycatNodeId = obj.optString("alleycatNodeId").ifBlank { null },
            alleycatRelay = obj.optString("alleycatRelay").ifBlank { null },
            alleycatAgentName = obj.optString("alleycatAgentName").ifBlank { null },
            alleycatAgentWire = obj.optString("alleycatAgentWire").ifBlank { null },
        )

    }
}

fun SavedServer.toRecord(context: Context? = null) = SavedServerRecord(
    id = id,
    name = name,
    hostname = hostname,
    port = port.toUShort(),
    codexPorts = codexPorts.map { it.toUShort() },
    sshPort = sshPort?.toUShort(),
    source = source,
    hasCodexServer = hasCodexServer,
    wakeMac = wakeMAC,
    preferredConnectionMode = preferredConnectionMode,
    preferredCodexPort = preferredCodexPort?.toUShort(),
    sshPortForwardingEnabled = sshPortForwardingEnabled,
    websocketUrl = websocketURL,
    rememberedByUser = rememberedByUser,
    alleycatHost = alleycatHost,
    alleycatUdpPort = alleycatUdpPort,
    alleycatNodeId = alleycatNodeId,
    alleycatToken = alleycatNodeId?.let { nodeId -> context?.let { AlleycatCredentialStore(it).loadToken(nodeId) } },
    alleycatRelay = alleycatRelay,
    alleycatAgentName = alleycatAgentName,
    alleycatAgentWire = alleycatAgentWire,
)

private val SavedServer.alleycatUdpPort: UShort?
    get() {
        if (alleycatHost == null || !id.startsWith("alleycat:")) return null
        return id.substringAfterLast(':').toUShortOrNull()
    }

object SavedServerStore {
    private const val PREFS_NAME = "codex_saved_servers_prefs"
    private const val KEY = "codex_saved_servers"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun load(context: Context): List<SavedServer> {
        val json = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            val decoded = (0 until array.length()).map { SavedServer.fromJson(array.getJSONObject(it)) }
            val migrated = decoded.map { migrateDisplayName(it.normalizedForPersistence()) }
            if (decoded != migrated) {
                save(context, migrated)
            }
            migrated
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun save(context: Context, servers: List<SavedServer>) {
        val array = JSONArray()
        servers.forEach { array.put(it.toJson()) }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    fun remember(context: Context, server: SavedServer) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.add(server.copy(rememberedByUser = true))
        save(context, existing)
    }

    fun rememberAlleycat(
        context: Context,
        serverId: String,
        displayName: String,
        nodeId: String,
        relay: String?,
        agentName: String,
        agentWire: String,
    ) {
        val server = SavedServer(
            id = serverId,
            name = displayName,
            hostname = nodeId,
            port = 0,
            codexPorts = emptyList(),
            sshPort = null,
            source = "manual",
            hasCodexServer = true,
            rememberedByUser = true,
            alleycatNodeId = nodeId,
            alleycatRelay = relay,
            alleycatAgentName = agentName,
            alleycatAgentWire = agentWire,
        )
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.add(server)
        save(context, existing)
    }

    fun remembered(context: Context): List<SavedServer> =
        load(context).filter { it.rememberedByUser }

    fun remove(context: Context, serverId: String) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == serverId }
        save(context, existing)
    }

    fun rename(context: Context, serverId: String, newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return

        val existing = load(context)
        val renamed = existing.map { server ->
            if (server.id == serverId) server.copy(name = trimmed) else server
        }
        if (renamed != existing) {
            save(context, renamed)
        }
    }

    fun updateWakeMac(context: Context, serverId: String, host: String, wakeMac: String?) {
        val normalizedWakeMac = SavedServer.normalizeWakeMac(wakeMac) ?: return
        val existing = load(context)
        val updated = existing.map { server ->
            if (server.id == serverId || normalizedHostKey(server.hostname) == normalizedHostKey(host)) {
                if (server.wakeMAC != normalizedWakeMac) server.copy(wakeMAC = normalizedWakeMac) else server
            } else {
                server
            }
        }
        if (updated != existing) {
            save(context, updated)
        }
    }

    private fun normalizedHostKey(host: String): String {
        val trimmed = host.trim().trimStart('[').trimEnd(']').replace("%25", "%")
        val withoutScope = if (!trimmed.contains(":")) {
            trimmed.substringBefore('%')
        } else {
            trimmed
        }
        return withoutScope.lowercase()
    }

    private fun migrateDisplayName(server: SavedServer): SavedServer {
        val nodeId = server.alleycatNodeId?.trim()?.takeIf { it.isNotEmpty() } ?: return server
        val name = server.name.trim()
        if (name.isNotEmpty() && !name.equals("Alleycat Host", ignoreCase = true)) {
            return server
        }
        return server.copy(name = "Alleycat ${shortNodeId(nodeId)}")
    }

    private fun shortNodeId(raw: String): String =
        if (raw.length <= 16) raw else raw.take(8) + "..." + raw.takeLast(8)
}
