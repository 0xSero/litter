package com.litter.android.ui.home

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterQuiet
import com.litter.android.ui.LitterSpacing
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterType
import com.litter.android.ui.common.AgentRuntimeKind
import com.litter.android.ui.common.runtimeLabel
import com.litter.android.ui.common.runtimeSortIndex
import com.litter.android.ui.metaLine
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.PinnedThreadKey
import java.util.Calendar

/**
 * Every past session across connected servers as one plain list: mono
 * lowercase section labels (pinned / now / today / yesterday / this week /
 * older), rows of title + one mono meta line "server · project · age".
 * Tap opens; long-press offers pin/unpin and archive.
 *
 * Virtualization follows HomeListVirtualization: stable keys, a contentType
 * per row kind, PAGE_SIZE rows rendered at a time. Rows show the summary only
 * and never hydrate threads.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadSearchResults(
    sessions: List<AppSessionSummary>,
    pinnedKeys: Set<PinnedThreadKey>,
    query: String,
    runtimeKinds: List<AgentRuntimeKind>,
    selectedRuntimeKind: AgentRuntimeKind?,
    isRefreshing: Boolean,
    onRuntimeSelected: (AgentRuntimeKind?) -> Unit,
    onRefresh: () -> Unit,
    onOpen: (AppSessionSummary) -> Unit,
    onPin: (AppSessionSummary) -> Unit,
    onUnpin: (AppSessionSummary) -> Unit,
    onArchive: (AppSessionSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    val entries = remember(sessions, pinnedKeys, query, selectedRuntimeKind) {
        val needle = query.trim().lowercase()
        val filtered = sessions.filter { session ->
            (selectedRuntimeKind == null || session.agentRuntimeKind == selectedRuntimeKind) &&
                (needle.isEmpty() ||
                    session.displayTitle.lowercase().contains(needle) ||
                    (session.cwd ?: "").lowercase().contains(needle) ||
                    session.serverDisplayName.lowercase().contains(needle) ||
                    session.preview.lowercase().contains(needle))
        }
        sessionListEntries(filtered, pinnedKeys, System.currentTimeMillis())
    }
    val listState = rememberLazyListState()
    val rendered = rememberPagedLimit(
        listState,
        entries.size,
        resetKey = "$query|$selectedRuntimeKind",
    )

    PullToRefreshBox(
        isRefreshing = isRefreshing,
        onRefresh = onRefresh,
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = LitterSpacing.lg),
        ) {
            if (runtimeKinds.size > 1) {
                item(key = "runtime-filters", contentType = "filters") {
                    RuntimeFilterRow(
                        runtimeKinds = runtimeKinds.sortedBy { it.runtimeSortIndex },
                        selectedRuntimeKind = selectedRuntimeKind,
                        onRuntimeSelected = onRuntimeSelected,
                    )
                }
            }
            if (entries.isEmpty()) {
                item(key = "empty", contentType = "empty") {
                    Text(
                        text = when {
                            sessions.isEmpty() && isRefreshing -> "loading…"
                            sessions.isEmpty() -> "no sessions yet"
                            else -> "no matches"
                        },
                        style = LitterType.meta,
                        modifier = Modifier.padding(
                            horizontal = LitterSpacing.margin,
                            vertical = LitterSpacing.md,
                        ),
                    )
                }
            } else {
                items(
                    if (rendered < entries.size) entries.subList(0, rendered) else entries,
                    key = { it.key },
                    contentType = { if (it is SessionListEntry.Header) "header" else "session" },
                ) { entry ->
                    when (entry) {
                        is SessionListEntry.Header -> SectionLabel(entry.section.label)
                        is SessionListEntry.Row -> SessionListRow(
                            session = entry.session,
                            isPinned = entry.isPinned,
                            onOpen = { onOpen(entry.session) },
                            onTogglePin = {
                                if (entry.isPinned) onUnpin(entry.session) else onPin(entry.session)
                            },
                            onArchive = { onArchive(entry.session) },
                        )
                    }
                }
            }
        }
    }
}

enum class SessionSection(val label: String) {
    PINNED("pinned"),
    NOW("now"),
    TODAY("today"),
    YESTERDAY("yesterday"),
    THIS_WEEK("this week"),
    OLDER("older"),
}

sealed interface SessionListEntry {
    val key: String

    data class Header(val section: SessionSection) : SessionListEntry {
        override val key: String get() = "section:${section.name}"
    }

    data class Row(
        val session: AppSessionSummary,
        val isPinned: Boolean,
    ) : SessionListEntry {
        override val key: String get() = "${session.key.serverId}/${session.key.threadId}"
    }
}

/** Sessions updated within this many seconds count as "now". */
private const val NOW_WINDOW_SECONDS = 3_600L

/** Section for a session updated at [updatedAtSeconds], relative to [nowMillis]. */
fun sessionSection(updatedAtSeconds: Long?, nowMillis: Long): SessionSection {
    val updated = updatedAtSeconds?.takeIf { it > 0L } ?: return SessionSection.OLDER
    val nowSeconds = nowMillis / 1000
    if (nowSeconds - updated < NOW_WINDOW_SECONDS) return SessionSection.NOW
    val startOfToday = Calendar.getInstance().apply {
        timeInMillis = nowMillis
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis / 1000
    return when {
        updated >= startOfToday -> SessionSection.TODAY
        updated >= startOfToday - 86_400L -> SessionSection.YESTERDAY
        updated >= startOfToday - 6 * 86_400L -> SessionSection.THIS_WEEK
        else -> SessionSection.OLDER
    }
}

/** Pinned first, then recency sections; each section sorted newest first. */
fun sessionListEntries(
    sessions: List<AppSessionSummary>,
    pinnedKeys: Set<PinnedThreadKey>,
    nowMillis: Long,
): List<SessionListEntry> {
    val sorted = sessions
        .distinctBy { "${it.key.serverId}/${it.key.threadId}" }
        .sortedByDescending { it.updatedAt ?: 0L }
    val grouped = LinkedHashMap<SessionSection, MutableList<SessionListEntry.Row>>()
    SessionSection.entries.forEach { grouped[it] = mutableListOf() }
    for (session in sorted) {
        val pinned = PinnedThreadKey(
            serverId = session.key.serverId,
            threadId = session.key.threadId,
        ) in pinnedKeys
        val section = if (pinned) SessionSection.PINNED else sessionSection(session.updatedAt, nowMillis)
        grouped.getValue(section).add(SessionListEntry.Row(session, pinned))
    }
    return buildList {
        grouped.forEach { (section, rows) ->
            if (rows.isEmpty()) return@forEach
            add(SessionListEntry.Header(section))
            addAll(rows)
        }
    }
}

/** Compact age for the meta line: "now", "4m", "2h", "3d", "5w". */
fun compactAge(epochSeconds: Long?): String {
    if (epochSeconds == null || epochSeconds <= 0L) return ""
    val delta = System.currentTimeMillis() / 1000 - epochSeconds
    return when {
        delta < 60 -> "now"
        delta < 3_600 -> "${delta / 60}m"
        delta < 86_400 -> "${delta / 3_600}h"
        delta < 604_800 -> "${delta / 86_400}d"
        else -> "${delta / 604_800}w"
    }
}

@Composable
private fun SectionLabel(label: String) {
    Text(
        text = label,
        style = LitterType.meta,
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = LitterSpacing.margin,
                end = LitterSpacing.margin,
                top = LitterSpacing.md,
                bottom = LitterSpacing.xxs,
            )
            .semantics { heading() },
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionListRow(
    session: AppSessionSummary,
    isPinned: Boolean,
    onOpen: () -> Unit,
    onTogglePin: () -> Unit,
    onArchive: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    Box {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = HomeListVirtualization.ROW_HEIGHT)
                .combinedClickable(
                    onClick = onOpen,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = LitterSpacing.margin, vertical = LitterSpacing.xs),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = session.displayTitle,
                style = LitterType.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = metaLine(
                    session.serverDisplayName,
                    HomeDashboardSupport.workspaceLabel(session.cwd),
                    compactAge(session.updatedAt),
                ),
                style = LitterType.meta,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text(if (isPinned) "Unpin" else "Pin") },
                onClick = {
                    showMenu = false
                    onTogglePin()
                },
            )
            DropdownMenuItem(
                text = { Text("Archive", color = LitterQuiet.error) },
                onClick = {
                    showMenu = false
                    onArchive()
                },
            )
        }
    }
}

/** Runtime filter as plain mono words; the selected one is full-strength text. */
@Composable
private fun RuntimeFilterRow(
    runtimeKinds: List<AgentRuntimeKind>,
    selectedRuntimeKind: AgentRuntimeKind?,
    onRuntimeSelected: (AgentRuntimeKind?) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = LitterSpacing.sm),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FilterWord("all", selectedRuntimeKind == null) { onRuntimeSelected(null) }
        runtimeKinds.forEach { kind ->
            FilterWord(kind.runtimeLabel.lowercase(), selectedRuntimeKind == kind) {
                onRuntimeSelected(kind)
            }
        }
    }
}

@Composable
private fun FilterWord(label: String, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = LitterSpacing.touch)
            .clickable(onClick = onClick)
            .padding(horizontal = LitterSpacing.xs),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = LitterType.meta,
            color = if (active) LitterTheme.textPrimary else LitterQuiet.meta,
        )
    }
}
