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
    // Deep paths retain the oldest loaded ancestor and nearest three parents.
    val omittedAncestorCount: Int = 0,
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
        data class PathProjection(
            val rootKey: ThreadKey,
            val ancestors: List<ThreadLineageMember>,
            val omittedAncestorCount: Int = 0,
        )
        val byKey = sessions.associateBy { it.key }
        val membersByKey = byKey.mapValues { (_, session) -> ThreadLineageMember(session.key, sessionTitle(session)) }
        fun parentKey(session: AppSessionSummary): ThreadKey? = session.forkedFromId?.trim()
            ?.takeIf { it.isNotEmpty() }?.let { ThreadKey(session.key.serverId, it) }
        val paths = HashMap<ThreadKey, PathProjection>()
        for (session in sessions) {
            if (session.key in paths) continue
            val trail = mutableListOf<AppSessionSummary>()
            val positions = HashMap<ThreadKey, Int>()
            var current = session
            while (current.key !in paths) {
                val cycleStart = positions[current.key]
                if (cycleStart != null) {
                    // Malformed cycles share a deterministic root and have no
                    // cyclic breadcrumb, matching the iOS fallback.
                    val cycle = trail.subList(cycleStart, trail.size)
                    val root = cycle.minBy { it.key.threadId }.key
                    cycle.forEach { paths[it.key] = PathProjection(root, emptyList()) }
                    cycle.clear()
                    break
                }
                positions[current.key] = trail.size
                trail.add(current)
                val parentKey = parentKey(current)
                if (parentKey == null) {
                    paths[current.key] = PathProjection(current.key, emptyList())
                    trail.removeAt(trail.lastIndex)
                    break
                }
                val parent = byKey[parentKey]
                if (parent == null) {
                    paths[current.key] = PathProjection(parentKey, emptyList())
                    trail.removeAt(trail.lastIndex)
                    break
                }
                current = parent
            }
            // Resolve every key once, retaining at most four breadcrumb entries.
            for (child in trail.asReversed()) {
                val parentKey = parentKey(child)!!
                val parentPath = paths.getValue(parentKey)
                val ancestors = (parentPath.ancestors + membersByKey.getValue(parentKey)).toMutableList()
                var omitted = parentPath.omittedAncestorCount
                if (ancestors.size > 4) {
                    ancestors.removeAt(1)
                    omitted += 1
                }
                paths[child.key] = PathProjection(parentPath.rootKey, ancestors, omitted)
            }
        }

        val groupsByRoot = sessions.groupBy { paths.getValue(it.key).rootKey }
        val result = HashMap<ThreadKey, ThreadLineage>()
        for ((rootKey, group) in groupsByRoot) {
            val sorted = group.sortedByDescending { it.updatedAt ?: 0L }
            // Share one complete family list across its branch projections.
            val members = sorted.map { membersByKey.getValue(it.key) }
            for ((idx, session) in sorted.withIndex()) {
                val path = paths.getValue(session.key)
                result[session.key] = ThreadLineage(
                    rootKey = rootKey,
                    parentKey = parentKey(session),
                    ancestors = path.ancestors,
                    members = members,
                    branchIndex = idx + 1,
                    branchTotal = members.size,
                    omittedAncestorCount = path.omittedAncestorCount,
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

        // Summary-only rows come from Rust's launch cache and are shown
        // before their server reconnects; live threads still require a
        // connected server.
        val liveThreadKeys = snapshot.threads
            .map { it.key.serverId to it.key.threadId }
            .toSet()

        return snapshot.sessionSummaries
            .filter {
                it.key.serverId in connectedServerIds ||
                    (it.key.serverId to it.key.threadId) !in liveThreadKeys
            }
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
