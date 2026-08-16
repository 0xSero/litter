package com.litter.android.ui.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import com.litter.android.state.displayTitle
import com.litter.android.state.isConnected
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.RecentDirectoryEntry
import com.litter.android.ui.RecentDirectoryStore
import com.litter.android.ui.home.HomeDashboardSupport
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppArchiveThreadRequest
import uniffi.codex_mobile_client.AppRenameThreadRequest
import uniffi.codex_mobile_client.ThreadKey

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(
    serverId: String?,
    title: String,
    sessionsUiState: SessionsUiState,
    onOpenConversation: (ThreadKey) -> Unit,
    onNewSession: (() -> Unit)? = null,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val connectedServerIds = remember(snapshot) {
        snapshot?.servers
            ?.filter { it.isConnected }
            ?.map { it.serverId }
            ?.sorted()
            .orEmpty()
    }

    var searchQuery by remember { mutableStateOf("") }
    var showSortMenu by remember { mutableStateOf(false) }
    var isLoading by remember { mutableStateOf(false) }
    var isForkingActiveThread by remember { mutableStateOf(false) }
    var hasLoadedInitialSessions by remember { mutableStateOf(false) }
    var pendingActiveSessionScroll by remember { mutableStateOf(false) }
    val derived = remember(
        snapshot,
        searchQuery,
        serverId,
        sessionsUiState.sortMode,
        sessionsUiState.showOnlyForks,
    ) {
        val summaries = snapshot?.sessionSummaries ?: emptyList()
        SessionsDerivation.derive(
            summaries = summaries,
            serverFilter = serverId,
            searchQuery = searchQuery,
            sortMode = sessionsUiState.sortMode,
            forkOnly = sessionsUiState.showOnlyForks,
        )
    }

    val listState = rememberLazyListState()

    fun scheduleActiveSessionScrollIfNeeded() {
        if (snapshot?.activeThread != null) {
            pendingActiveSessionScroll = true
        }
    }

    suspend fun scrollToActiveSessionIfNeeded() {
        val activeKey = snapshot?.activeThread ?: return
        if (!pendingActiveSessionScroll) return

        val activeThread = derived.filteredThreads.firstOrNull { it.key == activeKey } ?: run {
            pendingActiveSessionScroll = false
            return
        }

        val activeGroupKey = derived.workspaceGroupKeyByThreadKey[activeKey]
            ?: SessionsDerivation.workspaceGroupKey(activeThread)
        if (activeGroupKey in sessionsUiState.collapsedWorkspaceGroupKeys) {
            sessionsUiState.expandWorkspaceGroup(activeGroupKey)
            return
        }

        val collapsedAncestor = ancestorThreadKeys(activeKey, derived.parentByKey)
            .asReversed()
            .firstOrNull { it in sessionsUiState.collapsedSessionNodeKeys }
        if (collapsedAncestor != null) {
            sessionsUiState.expandSessionNode(collapsedAncestor)
            return
        }

        val flatIndex = flatListIndexForThread(
            groups = derived.groups,
            activeKey = activeKey,
            collapsedWorkspaceGroupKeys = sessionsUiState.collapsedWorkspaceGroupKeys,
            collapsedSessionNodeKeys = sessionsUiState.collapsedSessionNodeKeys,
        ) ?: run {
            pendingActiveSessionScroll = false
            return
        }

        pendingActiveSessionScroll = false
        listState.scrollToItem(flatIndex)
    }

    suspend fun loadSessions(force: Boolean = false) {
        if (isLoading) return
        if (!force && hasLoadedInitialSessions) return
        if (connectedServerIds.isEmpty()) {
            isLoading = false
            return
        }

        isLoading = true
        try {
            appModel.refreshSessions(connectedServerIds)
            hasLoadedInitialSessions = true
        } catch (_: Exception) {
        } finally {
            isLoading = false
        }
    }

    suspend fun forkThread(summary: uniffi.codex_mobile_client.AppSessionSummary) {
        if (isForkingActiveThread) return
        isForkingActiveThread = true
        try {
            val sourceKey = appModel.hydrateThreadPermissions(summary.key) ?: summary.key
            val newKey = appModel.client.forkThread(
                sourceKey.serverId,
                appModel.launchState.threadForkRequest(
                    sourceThreadId = sourceKey.threadId,
                    cwdOverride = summary.cwd,
                    threadKey = sourceKey,
                ),
            )
            appModel.store.setActiveThread(newKey)
            appModel.refreshThreadSnapshot(newKey)
            appModel.launchState.updateCurrentCwd(summary.cwd)
            onOpenConversation(newKey)
        } finally {
            isForkingActiveThread = false
        }
    }

    LaunchedEffect(connectedServerIds) {
        if (connectedServerIds.isEmpty()) {
            isLoading = false
            return@LaunchedEffect
        }
        loadSessions(force = hasLoadedInitialSessions)

        // Seed recent directories from loaded sessions.
        val snap = appModel.snapshot.value
        if (snap != null) {
            val recentStore = RecentDirectoryStore(context)
            for (server in snap.servers) {
                val entries = snap.sessionSummaries
                    .filter { it.key.serverId == server.serverId && it.cwd.isNotBlank() }
                    .map { summary ->
                        RecentDirectoryEntry(
                            serverId = server.serverId,
                            path = summary.cwd,
                            lastUsedAtEpochMillis = (summary.updatedAt ?: 0L) * 1000L,
                            useCount = 0,
                        )
                    }
                if (entries.isNotEmpty()) {
                    recentStore.mergeSessionDirectories(server.serverId, entries)
                }
            }
        }

        scheduleActiveSessionScrollIfNeeded()
    }

    LaunchedEffect(snapshot?.activeThread) {
        scheduleActiveSessionScrollIfNeeded()
    }

    LaunchedEffect(derived.workspaceGroupKeys) {
        sessionsUiState.pruneWorkspaceGroupKeys(derived.workspaceGroupKeys.toSet())
    }

    LaunchedEffect(derived.allThreadKeys) {
        sessionsUiState.pruneSessionNodeKeys(derived.allThreadKeys.toSet())
    }

    LaunchedEffect(
        pendingActiveSessionScroll,
        derived.filteredThreadKeys,
        sessionsUiState.collapsedWorkspaceGroupKeys,
        sessionsUiState.collapsedSessionNodeKeys,
    ) {
        scrollToActiveSessionIfNeeded()
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Top bar
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            IconButton(onClick = onBack) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                )
            }
            Text(
                text = title,
                color = LitterTheme.textPrimary,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = "${derived.filteredCount}/${derived.totalCount}",
                color = LitterTheme.textMuted,
                fontSize = 12.sp,
            )
            val activeSummary = snapshot?.activeThread?.let { activeKey ->
                snapshot?.sessionSummaries?.firstOrNull { it.key == activeKey }
            }
            if (activeSummary != null) {
                TextButton(
                    onClick = { scope.launch { forkThread(activeSummary) } },
                    enabled = !isForkingActiveThread && !activeSummary.hasActiveTurn,
                ) {
                    if (isForkingActiveThread) {
                        CircularProgressIndicator(
                            color = LitterTheme.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp),
                        )
                    } else {
                        Text("Fork", color = LitterTheme.accent, fontSize = 12.sp)
                    }
                }
            }
            IconButton(
                onClick = { scope.launch { loadSessions(force = true) } },
                enabled = !isLoading && connectedServerIds.isNotEmpty(),
                modifier = Modifier.size(32.dp),
            ) {
                if (isLoading && hasLoadedInitialSessions) {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(16.dp),
                    )
                } else {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = "Refresh sessions",
                        tint = if (connectedServerIds.isEmpty()) {
                            LitterTheme.textMuted
                        } else {
                            LitterTheme.accent
                        },
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            if (onInfo != null) {
                IconButton(onClick = onInfo, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Outlined.Info,
                        contentDescription = "Server Info",
                        tint = LitterTheme.accent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        if (serverId != null) {
            Button(
                onClick = { onNewSession?.invoke() },
                colors = ButtonDefaults.buttonColors(
                    containerColor = LitterTheme.accent,
                    contentColor = Color.Black,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
            ) {
                Icon(
                    Icons.Default.Add,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(6.dp))
                Text("New Session")
            }
        }

        // Search bar + filter chips
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
            ) {
                if (searchQuery.isEmpty()) {
                    Text("Search sessions\u2026", color = LitterTheme.textMuted, fontSize = 13.sp)
                }
                BasicTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            FilterChip(
                selected = sessionsUiState.showOnlyForks,
                onClick = { sessionsUiState.showOnlyForks = !sessionsUiState.showOnlyForks },
                label = { Text("Forks", fontSize = 11.sp) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = LitterTheme.accent,
                    selectedLabelColor = Color.Black,
                ),
            )
            Box {
                FilterChip(
                    selected = sessionsUiState.sortMode != WorkspaceSortMode.RECENT,
                    onClick = { showSortMenu = true },
                    label = { Text(sessionsUiState.sortMode.title, fontSize = 11.sp) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
                DropdownMenu(expanded = showSortMenu, onDismissRequest = { showSortMenu = false }) {
                    WorkspaceSortMode.entries.forEach { mode ->
                        DropdownMenuItem(
                            text = { Text(mode.title) },
                            onClick = {
                                sessionsUiState.sortMode = mode
                                showSortMenu = false
                                scheduleActiveSessionScrollIfNeeded()
                            },
                        )
                    }
                }
            }
        }

        if (derived.totalCount == 0) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
            ) {
                if (isLoading) {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text(
                        text = "No sessions yet",
                        color = LitterTheme.textMuted,
                        fontSize = 13.sp,
                    )
                }
            }
        } else {
            if (isLoading) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    CircularProgressIndicator(
                        color = LitterTheme.accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(14.dp),
                    )
                    Text(
                        text = "Loading more sessions...",
                        color = LitterTheme.textMuted,
                        fontSize = 12.sp,
                    )
                }
            }

            // Session list
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 16.dp),
            ) {
                for (group in derived.groups) {
                    val groupKey = SessionsDerivation.workspaceGroupKey(group.serverId, group.cwd)
                    val isCollapsed = groupKey in sessionsUiState.collapsedWorkspaceGroupKeys

                    // Group header
                    item(key = "header-$groupKey") {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    sessionsUiState.toggleWorkspaceGroup(groupKey)
                                }
                                .padding(vertical = 8.dp),
                        ) {
                            Icon(
                                if (isCollapsed) Icons.Default.ChevronRight else Icons.Default.ExpandMore,
                                contentDescription = null,
                                tint = LitterTheme.textMuted,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = group.workspaceLabel,
                                color = LitterTheme.textSecondary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                text = "${group.nodes.size}",
                                color = LitterTheme.textMuted,
                                fontSize = 11.sp,
                            )
                        }
                    }

                    // Session nodes (if expanded)
                    if (!isCollapsed) {
                        items(
                            items = visibleSessionRows(group.nodes, sessionsUiState.collapsedSessionNodeKeys),
                            key = { "${it.summary.key.serverId}/${it.summary.key.threadId}" },
                        ) { node ->
                            SessionNodeRow(
                                node = node,
                                hasChildren = node.children.isNotEmpty(),
                                isCollapsed = node.summary.key in sessionsUiState.collapsedSessionNodeKeys,
                                onToggleCollapse = {
                                    if (node.children.isNotEmpty()) {
                                        sessionsUiState.toggleSessionNode(node.summary.key)
                                        scheduleActiveSessionScrollIfNeeded()
                                    }
                                },
                                onClick = {
                                    appModel.launchState.updateCurrentCwd(node.summary.cwd)
                                    onOpenConversation(node.summary.key)
                                },
                                onFork = {
                                    scope.launch { forkThread(node.summary) }
                                },
                            )
                        }
                    }
                }

                item { Spacer(Modifier.height(32.dp)) }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionNodeRow(
    node: SessionTreeNode,
    hasChildren: Boolean,
    isCollapsed: Boolean,
    onToggleCollapse: () -> Unit,
    onClick: () -> Unit,
    onFork: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val scope = rememberCoroutineScope()
    val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
    val summary = node.summary
    var showMenu by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var showArchiveDialog by remember { mutableStateOf(false) }

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = (node.depth * 16).dp)
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .let { modifier ->
                        if (hasChildren) {
                            modifier.clickable(onClick = onToggleCollapse)
                        } else {
                            modifier
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (hasChildren) {
                    Icon(
                        if (isCollapsed) Icons.Default.ChevronRight else Icons.Default.ExpandMore,
                        contentDescription = if (isCollapsed) "Expand session children" else "Collapse session children",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Spacer(Modifier.width(6.dp))

            // Active turn indicator
            if (summary.hasActiveTurn) {
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(LitterTheme.accent),
                )
                Spacer(Modifier.width(6.dp))
            }

            Column(modifier = Modifier.weight(1f)) {
                com.litter.android.ui.common.FormattedText(
                    text = summary.displayTitle,
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                    maxLines = 1,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    summary.model?.let { model ->
                        Text(
                            text = model.substringAfterLast('/'),
                            color = LitterTheme.textMuted,
                            fontSize = 10.sp,
                        )
                    }
                    summary.agentDisplayLabel?.let { label ->
                        Text(
                            text = label,
                            color = LitterTheme.accent,
                            fontSize = 10.sp,
                        )
                    }
                }
            }

            // Without these the timestamp is the flex loser in the Row and
            // gets squeezed to a one-character column, wrapping after every
            // letter (#162). `softWrap = false` keeps it on one line and
            // `wrapContentWidth(unbounded = false)` lets it claim its
            // intrinsic width instead of being compressed to nothing.
            Text(
                text = HomeDashboardSupport.relativeTime(summary.updatedAt),
                color = LitterTheme.textMuted,
                fontSize = 10.sp,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.wrapContentWidth(),
            )
        }

        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text("Fork") },
                onClick = {
                    showMenu = false
                    onFork()
                },
            )
            DropdownMenuItem(
                text = { Text("Rename") },
                onClick = { showMenu = false; showRenameDialog = true },
            )
            DropdownMenuItem(
                text = { Text("Archive") },
                onClick = { showMenu = false; showArchiveDialog = true },
            )
        }
    }

    // Rename dialog
    if (showRenameDialog) {
        var newName by remember { mutableStateOf(summary.title ?: "") }
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            title = { Text("Rename Session") },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    label = { Text("Name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    showRenameDialog = false
                    scope.launch {
                        try {
                            appModel.client.renameThread(
                                summary.key.serverId,
                                AppRenameThreadRequest(
                                    threadId = summary.key.threadId,
                                    name = newName,
                                ),
                            )
                            appModel.refreshThreadSnapshot(summary.key)
                        } catch (_: Exception) {}
                    }
                }) { Text("Rename") }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false }) { Text("Cancel") }
            },
        )
    }

    // Archive confirmation dialog
    if (showArchiveDialog) {
        AlertDialog(
            onDismissRequest = { showArchiveDialog = false },
            title = { Text("Archive Session") },
            text = { Text("Are you sure you want to archive this session?") },
            confirmButton = {
                TextButton(onClick = {
                    showArchiveDialog = false
                    scope.launch {
                        try {
                            voiceController.stopVoiceSessionIfActive(appModel, summary.key)
                            voiceController.clearPinnedLocalVoiceThreadIfMatches(appModel, summary.key)
                            if (appModel.snapshot.value?.activeThread == summary.key) {
                                appModel.store.setActiveThread(null)
                            }
                            appModel.client.archiveThread(
                                summary.key.serverId,
                                AppArchiveThreadRequest(threadId = summary.key.threadId),
                            )
                            appModel.refreshSnapshot()
                        } catch (_: Exception) {}
                    }
                }) { Text("Archive", color = LitterTheme.danger) }
            },
            dismissButton = {
                TextButton(onClick = { showArchiveDialog = false }) { Text("Cancel") }
            },
        )
    }

    Spacer(Modifier.height(4.dp))
}

private fun visibleSessionRows(
    nodes: List<SessionTreeNode>,
    collapsedSessionNodeKeys: Set<ThreadKey>,
): List<SessionTreeNode> {
    val result = mutableListOf<SessionTreeNode>()
    fun walk(node: SessionTreeNode) {
        result.add(node)
        if (node.summary.key !in collapsedSessionNodeKeys) {
            node.children.forEach { walk(it) }
        }
    }
    nodes.forEach { walk(it) }
    return result
}

private fun flatListIndexForThread(
    groups: List<WorkspaceSessionGroup>,
    activeKey: ThreadKey,
    collapsedWorkspaceGroupKeys: Set<String>,
    collapsedSessionNodeKeys: Set<ThreadKey>,
): Int? {
    var flatIndex = 0
    for (group in groups) {
        val groupKey = SessionsDerivation.workspaceGroupKey(group.serverId, group.cwd)
        flatIndex += 1
        if (groupKey in collapsedWorkspaceGroupKeys) {
            continue
        }

        val visibleNodes = visibleSessionRows(group.nodes, collapsedSessionNodeKeys)
        val matchIndex = visibleNodes.indexOfFirst { it.summary.key == activeKey }
        if (matchIndex >= 0) {
            return flatIndex + matchIndex
        }
        flatIndex += visibleNodes.size
    }
    return null
}

private fun ancestorThreadKeys(
    key: ThreadKey,
    parentByKey: Map<ThreadKey, uniffi.codex_mobile_client.AppSessionSummary>,
): List<ThreadKey> {
    val ancestors = mutableListOf<ThreadKey>()
    val visited = mutableSetOf<ThreadKey>()
    var cursor = parentByKey[key]
    while (cursor != null && visited.add(cursor.key)) {
        ancestors += cursor.key
        cursor = parentByKey[cursor.key]
    }
    return ancestors
}
