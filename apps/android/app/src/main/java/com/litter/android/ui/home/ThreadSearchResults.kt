package com.litter.android.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.style.TextOverflow
import uniffi.codex_mobile_client.ThreadKey
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.AgentIconView
import com.litter.android.ui.common.runtimeLabel
import com.litter.android.ui.common.runtimeSortIndex
import com.litter.android.ui.scaled
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.PinnedThreadKey

/**
 * List of every thread across connected servers, sorted by recency and
 * filtered by the current query. Tapping a row toggles its pinned state.
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
    onPin: (AppSessionSummary) -> Unit,
    onUnpin: (AppSessionSummary) -> Unit,
    modifier: Modifier = Modifier,
) {
    val filtered = run {
        val needle = query.trim().lowercase()
        sessions.filter { session ->
            (selectedRuntimeKind == null || session.agentRuntimeKind == selectedRuntimeKind) &&
                (needle.isEmpty() ||
                    session.displayTitle.lowercase().contains(needle)
                || (session.cwd ?: "").lowercase().contains(needle)
                || session.serverDisplayName.lowercase().contains(needle)
                || session.preview.lowercase().contains(needle))
        }
    }

    // Lineage for the *unfiltered* sessions, so a fork's parent (potentially
    // dropped by the filter) is still discoverable. Mirrors iOS clusters.
    val lineageMap = remember(sessions) { HomeDashboardSupport.computeLineageMap(sessions) }
    val clusters = remember(filtered, lineageMap) {
        val bucket = LinkedHashMap<ThreadKey, MutableList<AppSessionSummary>>()
        for (session in filtered) {
            val root = lineageMap[session.key]?.rootKey ?: session.key
            bucket.getOrPut(root) { mutableListOf() }.add(session)
        }
        bucket.map { (rootKey, members) ->
            ThreadSearchCluster(
                rootKey = rootKey,
                members = members.sortedByDescending { it.updatedAt ?: 0L },
            )
        }
    }
    var expandedClusters by remember { mutableStateOf<Set<ThreadKey>>(emptySet()) }

    PullToRefreshBox(
        isRefreshing = isRefreshing,
        onRefresh = onRefresh,
        modifier = modifier
            .fillMaxSize()
            .background(LitterTheme.surface.copy(alpha = 0.92f), RoundedCornerShape(14.dp))
            .border(1.dp, LitterTheme.border.copy(alpha = 0.5f), RoundedCornerShape(14.dp)),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 4.dp),
        ) {
            if (runtimeKinds.size > 1) {
                item(key = "runtime-filters") {
                    RuntimeFilterRow(
                        runtimeKinds = runtimeKinds.sortedBy { it.runtimeSortIndex },
                        selectedRuntimeKind = selectedRuntimeKind,
                        onRuntimeSelected = onRuntimeSelected,
                    )
                }
            }
            if (filtered.isEmpty()) {
                item(key = "empty") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 24.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (sessions.isEmpty()) "No threads yet" else "No matches",
                            color = LitterTheme.textMuted,
                            fontSize = LitterTextStyle.caption.scaled,
                        )
                    }
                }
            } else {
                items(
                    clusters,
                    key = { "${it.rootKey.serverId}/${it.rootKey.threadId}" },
                ) { cluster ->
                    if (cluster.members.size == 1) {
                        val only = cluster.members.first()
                        val key = PinnedThreadKey(
                            serverId = only.key.serverId,
                            threadId = only.key.threadId,
                        )
                        val isPinned = pinnedKeys.contains(key)
                        ThreadSearchRow(
                            session = only,
                            isPinned = isPinned,
                            onToggle = {
                                if (isPinned) onUnpin(only) else onPin(only)
                            },
                        )
                    } else {
                        ThreadSearchClusterRow(
                            cluster = cluster,
                            pinnedKeys = pinnedKeys,
                            isExpanded = expandedClusters.contains(cluster.rootKey),
                            onToggleExpanded = {
                                expandedClusters = if (expandedClusters.contains(cluster.rootKey)) {
                                    expandedClusters - cluster.rootKey
                                } else {
                                    expandedClusters + cluster.rootKey
                                }
                            },
                            onPin = onPin,
                            onUnpin = onUnpin,
                        )
                    }
                    HorizontalDivider(color = LitterTheme.border.copy(alpha = 0.15f))
                }
            }
        }
    }
}

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
            .padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RuntimeFilterPill(
            label = "All",
            kind = null,
            isActive = selectedRuntimeKind == null,
            onClick = { onRuntimeSelected(null) },
        )
        runtimeKinds.forEach { kind ->
            RuntimeFilterPill(
                label = kind.runtimeLabel,
                kind = kind,
                isActive = selectedRuntimeKind == kind,
                onClick = { onRuntimeSelected(kind) },
            )
        }
    }
}

@Composable
private fun RuntimeFilterPill(
    label: String,
    kind: AgentRuntimeKind?,
    isActive: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(percent = 50))
            .background(if (isActive) LitterTheme.accent else LitterTheme.surface.copy(alpha = 0.65f))
            .border(
                1.dp,
                if (isActive) LitterTheme.accent else LitterTheme.border.copy(alpha = 0.7f),
                RoundedCornerShape(percent = 50),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (kind != null) {
            AgentIconView(kind = kind, sizeDp = 12)
        }
        Text(
            text = label,
            color = if (isActive) LitterTheme.onAccentStrong else LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption.scaled,
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
        )
    }
}

@Composable
private fun ThreadSearchRow(
    session: AppSessionSummary,
    isPinned: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ThreadSearchRuntimeIcon(kind = session.agentRuntimeKind)
        Spacer(Modifier.size(8.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = session.displayTitle,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.caption.scaled,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = session.serverDisplayName,
                    color = LitterTheme.accent.copy(alpha = 0.7f),
                    fontSize = 10f.scaled,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    text = "\u00b7",
                    color = LitterTheme.textMuted.copy(alpha = 0.5f),
                    fontSize = 10f.scaled,
                )
                Text(
                    text = HomeDashboardSupport.workspaceLabel(session.cwd),
                    color = LitterTheme.textSecondary.copy(alpha = 0.8f),
                    fontSize = 10f.scaled,
                    fontFamily = FontFamily.Monospace,
                )
                val relative = HomeDashboardSupport.relativeTime(session.updatedAt)
                if (relative.isNotEmpty()) {
                    Text(
                        text = "\u00b7",
                        color = LitterTheme.textMuted.copy(alpha = 0.5f),
                        fontSize = 10f.scaled,
                    )
                    Text(
                        text = relative,
                        color = LitterTheme.textMuted.copy(alpha = 0.8f),
                        fontSize = 10f.scaled,
                        fontFamily = FontFamily.Monospace,
                        // See SessionCanvasRow: an uncapped timestamp is the
                        // only child free to wrap, so a narrow row breaks it
                        // one character per line (#162).
                        maxLines = 1,
                        softWrap = false,
                    )
                }
            }
        }
        Spacer(Modifier.size(8.dp))
        Icon(
            imageVector = if (isPinned) Icons.Default.CheckCircle else Icons.Default.Add,
            contentDescription = null,
            tint = if (isPinned) LitterTheme.accent else LitterTheme.textPrimary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun ThreadSearchRuntimeIcon(kind: AgentRuntimeKind) {
    AgentIconView(kind = kind, sizeDp = 16)
}

/**
 * One lineage's worth of search rows. Mirrors iOS `ThreadSearchCluster`.
 * `members` is sorted by `updatedAt` desc, so `members.first()` is the head
 * (most recently active branch).
 */
data class ThreadSearchCluster(
    val rootKey: ThreadKey,
    val members: List<AppSessionSummary>,
)

/**
 * Cluster row that collapses N sibling threads into a single visual unit.
 * Tapping the branches pill expands the children inline — each child has
 * its own pin button. Mirrors iOS `ThreadSearchClusterRow`.
 */
@Composable
private fun ThreadSearchClusterRow(
    cluster: ThreadSearchCluster,
    pinnedKeys: Set<PinnedThreadKey>,
    isExpanded: Boolean,
    onToggleExpanded: () -> Unit,
    onPin: (AppSessionSummary) -> Unit,
    onUnpin: (AppSessionSummary) -> Unit,
) {
    // Prefer the root thread for the head row identity (forks come and go;
    // the root is canonical). Fall back to the most-recent member when the
    // root isn't loaded into the snapshot.
    val head = cluster.members.firstOrNull { it.key == cluster.rootKey }
        ?: cluster.members.first()
    val headLatestUpdatedAt = cluster.members.maxOf { it.updatedAt ?: 0L }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                if (isExpanded) LitterTheme.surface.copy(alpha = 0.3f)
                else androidx.compose.ui.graphics.Color.Transparent,
            ),
    ) {
        val headPinKey = PinnedThreadKey(serverId = head.key.serverId, threadId = head.key.threadId)
        val headPinned = pinnedKeys.contains(headPinKey)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ThreadSearchRuntimeIcon(kind = head.agentRuntimeKind)
            Spacer(Modifier.size(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = head.displayTitle,
                    color = LitterTheme.textPrimary,
                    fontSize = 13f.scaled,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = head.serverDisplayName,
                        color = LitterTheme.accent.copy(alpha = 0.7f),
                        fontSize = 10f.scaled,
                        fontFamily = FontFamily.Monospace,
                    )
                    Text(
                        text = "·",
                        color = LitterTheme.textMuted.copy(alpha = 0.5f),
                        fontSize = 10f.scaled,
                    )
                    Text(
                        text = HomeDashboardSupport.workspaceLabel(head.cwd),
                        color = LitterTheme.textSecondary.copy(alpha = 0.8f),
                        fontSize = 10f.scaled,
                        fontFamily = FontFamily.Monospace,
                    )
                    val relative = HomeDashboardSupport.relativeTime(headLatestUpdatedAt)
                    if (relative.isNotEmpty()) {
                        Text(
                            text = "·",
                            color = LitterTheme.textMuted.copy(alpha = 0.5f),
                            fontSize = 10f.scaled,
                        )
                        Text(
                            text = relative,
                            color = LitterTheme.textMuted.copy(alpha = 0.8f),
                            fontSize = 10f.scaled,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            softWrap = false,
                        )
                    }
                }
            }
            Spacer(Modifier.size(6.dp))
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(percent = 50))
                    .background(
                        LitterTheme.accent.copy(alpha = if (isExpanded) 0.18f else 0.12f),
                    )
                    .clickable(onClick = onToggleExpanded)
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    text = "${cluster.members.size}",
                    color = LitterTheme.textPrimary,
                    fontSize = 11f.scaled,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                )
                Icon(
                    imageVector = if (isExpanded) Icons.Default.KeyboardArrowUp
                        else Icons.Default.KeyboardArrowDown,
                    contentDescription = null,
                    tint = LitterTheme.accent,
                    modifier = Modifier.size(14.dp),
                )
            }
            Spacer(Modifier.size(6.dp))
            Icon(
                imageVector = if (headPinned) Icons.Default.CheckCircle else Icons.Default.Add,
                contentDescription = null,
                tint = if (headPinned) LitterTheme.accent else LitterTheme.textPrimary,
                modifier = Modifier
                    .size(20.dp)
                    .clickable {
                        if (headPinned) onUnpin(head) else onPin(head)
                    },
            )
        }
        AnimatedVisibility(visible = isExpanded) {
            Column {
                cluster.members.forEach { member ->
                    val pin = PinnedThreadKey(
                        serverId = member.key.serverId,
                        threadId = member.key.threadId,
                    )
                    val isPinned = pinnedKeys.contains(pin)
                    ThreadSearchRow(
                        session = member,
                        isPinned = isPinned,
                        onToggle = {
                            if (isPinned) onUnpin(member) else onPin(member)
                        },
                    )
                }
            }
        }
    }
}
