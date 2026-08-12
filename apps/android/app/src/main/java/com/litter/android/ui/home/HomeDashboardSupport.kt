package com.litter.android.ui.home

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.runtimeLabel
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.Account
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.ThreadKey

/**
 * Lightweight projection of a thread for use in lineage breadcrumbs and
 * sibling pills. Mirrors iOS `ThreadLineageMember`.
 */
data class ThreadLineageMember(val key: ThreadKey, val title: String)

/**
 * Fork lineage info for a single thread. Computed once per snapshot pass by
 * walking `forkedFromId` within a server. Singletons (`branchTotal == 1`)
 * are filtered out before attaching to a session — the render layer treats
 * `lineage == null` as "no fork relationships". Mirrors iOS `ThreadLineage`.
 */
data class ThreadLineage(
    val rootKey: ThreadKey,
    val parentKey: ThreadKey?,
    val ancestors: List<ThreadLineageMember>,
    val members: List<ThreadLineageMember>,
    val branchIndex: Int,
    val branchTotal: Int,
) {
    val hasMultipleBranches: Boolean get() = branchTotal > 1
}

/**
 * TextStyle matching the conversation body size at the current text scale,
 * using the user's selected app font at [FontWeight.Medium].
 *
 * Mirrors iOS `MarkdownMatchedTitleFont` so home dashboard titles render at
 * the same size as conversation message bodies — making row headings visually
 * match what appears inside a conversation.
 *
 * Swift reference: HomeDashboardView.swift MarkdownMatchedTitleFont (L1203-1213).
 */
@Composable
@Suppress("DEPRECATION")
fun markdownMatchedTitleStyle(): TextStyle {
    val family = LitterTheme.bodyFont
    return TextStyle(
        fontFamily = family,
        fontWeight = FontWeight.Medium,
        fontSize = LitterTextStyle.body.scaled,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )
}

/**
 * Pure functions for deriving home dashboard data from Rust snapshots.
 * No business logic duplication — just UI-specific sorting/filtering.
 */
object HomeDashboardSupport {
    fun runtimeLabel(kind: AgentRuntimeKind): String = kind.runtimeLabel

    /**
     * Connected servers sorted by: active server first, then alphabetical.
     * Deduplicates by normalized host.
     */
    fun sortedConnectedServers(snapshot: AppSnapshotRecord): List<AppServerSnapshot> {
        val seen = mutableSetOf<String>()
        return snapshot.servers
            .filter { it.health != AppServerHealth.DISCONNECTED || it.connectionProgress != null }
            .sortedWith(compareBy<AppServerSnapshot> {
                // Active server (has active thread on it) sorts first
                val activeServerId = snapshot.activeThread?.let { key ->
                    key.serverId
                }
                if (it.serverId == activeServerId) 0 else 1
            }.thenBy { it.displayName.lowercase() })
            .filter { server ->
                val hostKey = "${server.host.lowercase()}:${server.port}"
                seen.add(hostKey)
            }
    }

    /**
     * Resolve a session's display title using the same rules as the iOS
     * `HomeDashboardSupport.sessionTitle` helper — non-empty trimmed title
     * unless it is the placeholder "Untitled session", otherwise fall back
     * to the cwd's last path component or "New thread".
     */
    fun sessionTitle(session: AppSessionSummary): String {
        val trimmed = session.title.trim()
        if (trimmed.isNotEmpty() && trimmed != "Untitled session") return trimmed
        val cwd = session.cwd.trim().trimEnd('/')
        if (cwd.isNotEmpty()) {
            val tail = cwd.substringAfterLast('/')
            return tail.ifEmpty { cwd }
        }
        return "New thread"
    }

    /**
     * Walk `forkedFromId` over a snapshot of session summaries to derive a
     * `ThreadLineage` for every thread. Lineage is scoped per server — a
     * fork id always refers to a thread on the same server. Sub-agent
     * parentage is intentionally NOT traversed: it is a separate
     * relationship and surfaces through `agentNickname` / `agentRole`,
     * not via fork affordances. Mirrors iOS `ThreadLineageMap.compute`.
     */
    fun computeLineageMap(sessions: List<AppSessionSummary>): Map<ThreadKey, ThreadLineage> {
        if (sessions.isEmpty()) return emptyMap()

        val byServerThreadId = HashMap<String, HashMap<String, AppSessionSummary>>()
        for (session in sessions) {
            byServerThreadId.getOrPut(session.key.serverId) { HashMap() }[session.key.threadId] = session
        }

        fun root(session: AppSessionSummary): ThreadKey {
            var current = session
            val visited = HashSet<String>()
            visited.add(current.key.threadId)
            while (true) {
                val parentId = current.forkedFromId?.trim()
                if (parentId.isNullOrEmpty() || !visited.add(parentId)) return current.key
                val parent = byServerThreadId[current.key.serverId]?.get(parentId)
                    ?: return ThreadKey(serverId = current.key.serverId, threadId = parentId)
                current = parent
            }
        }

        fun ancestorChain(session: AppSessionSummary): List<ThreadLineageMember> {
            val chain = ArrayDeque<ThreadLineageMember>()
            var current = session
            val visited = HashSet<String>()
            visited.add(current.key.threadId)
            while (true) {
                val parentId = current.forkedFromId?.trim()
                if (parentId.isNullOrEmpty() || !visited.add(parentId)) break
                val parent = byServerThreadId[current.key.serverId]?.get(parentId) ?: break
                chain.addFirst(ThreadLineageMember(parent.key, sessionTitle(parent)))
                current = parent
            }
            return chain.toList()
        }

        val rootByKey = HashMap<ThreadKey, ThreadKey>()
        for (session in sessions) {
            rootByKey[session.key] = root(session)
        }

        val groupsByRoot = HashMap<ThreadKey, MutableList<AppSessionSummary>>()
        for (session in sessions) {
            val r = rootByKey[session.key] ?: session.key
            groupsByRoot.getOrPut(r) { mutableListOf() }.add(session)
        }

        val result = HashMap<ThreadKey, ThreadLineage>()
        for ((rootKey, group) in groupsByRoot) {
            val sorted = group.sortedByDescending { it.updatedAt ?: 0L }
            val members = sorted.map { ThreadLineageMember(it.key, sessionTitle(it)) }
            for ((idx, session) in sorted.withIndex()) {
                val parentKey = session.forkedFromId?.trim()?.takeIf { it.isNotEmpty() }
                    ?.let { ThreadKey(serverId = session.key.serverId, threadId = it) }
                val ancestors = ancestorChain(session)
                result[session.key] = ThreadLineage(
                    rootKey = rootKey,
                    parentKey = parentKey,
                    ancestors = ancestors,
                    members = members,
                    branchIndex = idx + 1,
                    branchTotal = members.size,
                )
            }
        }
        return result
    }

    /**
     * Most recent sessions from connected servers, limited to [limit].
     * Uses pre-computed fields from Rust's AppSessionSummary.
     */
    fun recentSessions(
        snapshot: AppSnapshotRecord,
        limit: Int = 10,
    ): List<AppSessionSummary> {
        val connectedServerIds = snapshot.servers
            .filter { it.health == AppServerHealth.CONNECTED }
            .map { it.serverId }
            .toSet()

        return snapshot.sessionSummaries
            .filter { it.key.serverId in connectedServerIds }
            .filter { !it.isSubagent }
            .distinctBy { it.key.serverId to it.key.threadId }
            .sortedByDescending { it.updatedAt ?: 0L }
            .take(limit)
    }

    /**
     * Extracts the last path component as a workspace label.
     */
    fun workspaceLabel(cwd: String?): String {
        if (cwd.isNullOrBlank()) return "~"
        val trimmed = cwd.trimEnd('/')
        if (trimmed.isEmpty()) return "/"
        return trimmed.substringAfterLast('/')
    }

    /**
     * Format a relative timestamp from epoch seconds.
     */
    fun relativeTime(epochSeconds: Long?): String {
        if (epochSeconds == null || epochSeconds <= 0L) return ""
        val now = System.currentTimeMillis() / 1000
        val delta = now - epochSeconds
        return when {
            delta < 60 -> "just now"
            delta < 3600 -> "${delta / 60}m ago"
            delta < 86400 -> "${delta / 3600}h ago"
            delta < 604800 -> "${delta / 86400}d ago"
            else -> "${delta / 604800}w ago"
        }
    }

    fun maskedAccountLabel(server: AppServerSnapshot): String = when (val account = server.account) {
        is Account.Chatgpt -> maskEmail(account.email).ifEmpty { "ChatGPT" }
        is Account.ApiKey -> "API Key"
        else -> "Not logged in"
    }

    private fun maskEmail(email: String): String {
        val trimmed = email.trim()
        if (trimmed.isEmpty()) return ""

        val parts = trimmed.split("@", limit = 2)
        if (parts.size != 2) return maskToken(trimmed, keepPrefix = 2, keepSuffix = 0)

        val localPart = parts[0]
        val domainPart = parts[1]
        val domainPieces = domainPart.split(".")

        val maskedLocal = maskToken(localPart, keepPrefix = 2, keepSuffix = 1)
        val maskedDomain = if (domainPieces.size >= 2) {
            val suffix = domainPieces.last()
            val host = domainPieces.dropLast(1).joinToString(".")
            "${maskToken(host, keepPrefix = 1, keepSuffix = 0)}.$suffix"
        } else {
            maskToken(domainPart, keepPrefix = 1, keepSuffix = 0)
        }

        return "$maskedLocal@$maskedDomain"
    }

    private fun maskToken(value: String, keepPrefix: Int, keepSuffix: Int): String {
        if (value.isEmpty()) return ""

        val prefixCount = keepPrefix.coerceAtMost(value.length)
        val suffixCount = keepSuffix.coerceAtMost((value.length - prefixCount).coerceAtLeast(0))
        val maskCount = (value.length - prefixCount - suffixCount).coerceAtLeast(0)

        val prefix = value.take(prefixCount)
        val suffix = if (suffixCount > 0) value.takeLast(suffixCount) else ""
        val mask = if (maskCount > 0) "*".repeat(maskCount) else ""

        return prefix + mask + suffix
    }
}

// ─────────────────────────────────────────────────────────
// Hydrated conversation walks moved to Rust
// ─────────────────────────────────────────────────────────
//
// Everything that used to live here — `isToolCallRunning`,
// `lastTurnBounds`, `hydratedToolRows`, `explorationSummary`,
// `displayedAssistantMessage`, `HomeToolRow` — duplicated reducer logic
// from `shared/rust-bridge/codex-mobile-client/src/store/boundary.rs`
// (`extract_conversation_activity`). The Rust side now produces a
// complete `AppSessionSummary` with `recent_tool_log` (flat
// `List<AppToolLogEntry>` including "Explore" / "WebSearch" entries),
// `last_response_preview`, and `last_turn_start_ms` / `last_turn_end_ms`.
// Home card composables read those session props directly; see
// `SessionCanvasRow.kt`, `InlineStats.kt`, `HomeToolRowView.kt`.
