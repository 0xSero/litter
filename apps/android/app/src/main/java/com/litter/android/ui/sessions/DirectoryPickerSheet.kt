package com.litter.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.RecentDirectoryEntry
import com.litter.android.ui.RecentDirectoryStore
import com.litter.android.state.canBrowseDirectories
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.codex_mobile_client.RemotePath

@Composable
fun DirectoryPickerSheet(
    servers: List<DirectoryPickerServerOption>,
    initialServerId: String,
    onSelect: (serverId: String, cwd: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val recentStore = remember(context) { RecentDirectoryStore(context) }
    val scope = rememberCoroutineScope()
    val serverIds = remember(servers) { servers.map { it.id } }

    var selectedServerId by remember {
        mutableStateOf(
            servers.firstOrNull { it.id == initialServerId }?.id
                ?: servers.firstOrNull()?.id
                ?: "",
        )
    }
    var currentPath by remember(selectedServerId) { mutableStateOf("") }
    var allEntries by remember(selectedServerId) { mutableStateOf<List<String>>(emptyList()) }
    var recentEntries by remember(selectedServerId) { mutableStateOf<List<RecentDirectoryEntry>>(emptyList()) }
    var isLoading by remember(selectedServerId) { mutableStateOf(true) }
    var errorMessage by remember(selectedServerId) { mutableStateOf<String?>(null) }
    var showHiddenDirectories by remember { mutableStateOf(false) }
    var searchQuery by remember(selectedServerId) { mutableStateOf("") }
    var showServerMenu by remember { mutableStateOf(false) }
    var showRecentsMenu by remember { mutableStateOf(false) }
    var showGoToPathDialog by remember { mutableStateOf(false) }
    var pathInput by remember { mutableStateOf("") }
    var remoteHomePath by remember(selectedServerId) { mutableStateOf("") }

    fun refreshRecentEntries(serverId: String) {
        recentEntries = recentStore.listForServer(serverId, limit = 8)
    }

    fun completeSelection(serverId: String, path: String) {
        recentEntries = recentStore.record(serverId, path, limit = 8)
        onSelect(serverId, path)
    }

    fun isDisconnectedError(error: Throwable): Boolean {
        val message = error.message?.lowercase().orEmpty()
        return "disconnected" in message ||
            ("transport error" in message && "not connected" in message)
    }

    fun isLocalServer(serverId: String): Boolean =
        appModel.snapshot.value?.servers?.firstOrNull { it.serverId == serverId }?.isLocal == true

    suspend fun resolveHome(serverId: String): String {
        if (isLocalServer(serverId)) {
            return com.litter.android.state.HomeAnchor.path(context)
        }
        val serverSnapshot = appModel.snapshot.value?.servers?.firstOrNull { it.serverId == serverId }
        if (serverSnapshot?.canBrowseDirectories != true) {
            errorMessage = "Selected server is not connected."
            return "/"
        }
        return runCatching {
            appModel.client.resolveRemoteHome(serverId)
        }.getOrElse { error ->
            if (isDisconnectedError(error)) {
                errorMessage = "Selected server is not connected."
            }
            "/"
        }
    }

    suspend fun listDirectory(serverId: String, path: String) {
        val normalizedPath = path.trim().ifEmpty { "/" }
        isLoading = true
        errorMessage = null

        if (isLocalServer(serverId)) {
            val dir = java.io.File(normalizedPath)
            val entries = withContext(Dispatchers.IO) {
                runCatching { dir.listFiles()?.filter { it.isDirectory }?.map { it.name } ?: emptyList() }
            }
            if (serverId != selectedServerId) return
            entries.onSuccess { names ->
                allEntries = names.sortedWith(String.CASE_INSENSITIVE_ORDER)
                currentPath = normalizedPath
            }.onFailure { err ->
                allEntries = emptyList()
                errorMessage = err.message ?: "Failed to list directory."
            }
            isLoading = false
            return
        }

        val serverSnapshot = appModel.snapshot.value?.servers?.firstOrNull { it.serverId == serverId }
        if (serverSnapshot?.canBrowseDirectories != true) {
            isLoading = false
            allEntries = emptyList()
            errorMessage = "Selected server is not connected."
            return
        }

        val response = runCatching {
            appModel.client.listRemoteDirectory(serverId, normalizedPath)
        }

        if (serverId != selectedServerId) {
            return
        }

        response.onSuccess { result ->
            allEntries = result.directories
            currentPath = result.path
        }.onFailure { error ->
            allEntries = emptyList()
            errorMessage = if (isDisconnectedError(error)) {
                "Selected server is not connected."
            } else {
                error.message ?: "Failed to list directory."
            }
        }
        isLoading = false
    }

    suspend fun loadInitialPath(serverId: String) {
        isLoading = true
        errorMessage = null
        allEntries = emptyList()
        currentPath = ""
        val home = resolveHome(serverId)
        if (serverId != selectedServerId) return
        remoteHomePath = home
        currentPath = home
        listDirectory(serverId, home)
    }

    fun pathSegments(path: String): List<Pair<String, String>> {
        val normalized = path.trim()
        if (normalized.isEmpty()) return listOf("/" to "/")
        val raw = RemotePath.parse(normalized).segments().map { seg -> seg.label to seg.fullPath }
        if (!isLocalServer(selectedServerId)) return raw
        // On local, hide every breadcrumb above `~` and relabel the anchor
        // itself as "~" so the trail reads `~ / projects / foo` rather than
        // `data / user / 0 / com.sigkitten.litter / files / codex-home / workspace / projects / foo`.
        val home = com.litter.android.state.HomeAnchor.path(context)
        val homeRoot = "~" to home
        val suffix = raw.dropWhile { it.second != home }.drop(1)
        return listOf(homeRoot) + suffix
    }

    fun relativeTime(epochMillis: Long): String {
        val deltaMinutes = ((System.currentTimeMillis() - epochMillis).coerceAtLeast(0L) / 60000L)
        return when {
            deltaMinutes < 1L -> "just now"
            deltaMinutes < 60L -> "${deltaMinutes}m ago"
            deltaMinutes < 1440L -> "${deltaMinutes / 60L}h ago"
            deltaMinutes < 10080L -> "${deltaMinutes / 1440L}d ago"
            else -> "${deltaMinutes / 10080L}w ago"
        }
    }

    fun navigateInto(name: String) {
        val nextPath = RemotePath.parse(currentPath).join(name).asString()
        scope.launch { listDirectory(selectedServerId, nextPath) }
    }

    fun navigateUp() {
        val nextPath = RemotePath.parse(currentPath).parent().asString()
        scope.launch { listDirectory(selectedServerId, nextPath) }
    }

    fun navigateToInputPath() {
        val target = com.litter.android.state.PathDisplay
            .expand(
                pathInput,
                isLocalServer(selectedServerId),
                context,
                remoteHome = remoteHomePath,
            )
            .trim()
        pathInput = ""
        showGoToPathDialog = false
        if (target.isNotEmpty()) {
            scope.launch { listDirectory(selectedServerId, target) }
        }
    }

    val selectedServer = remember(servers, selectedServerId) {
        servers.firstOrNull { it.id == selectedServerId }
    }
    val filteredEntries = remember(allEntries, searchQuery, showHiddenDirectories) {
        val hiddenFiltered = if (showHiddenDirectories) allEntries else allEntries.filterNot { it.startsWith(".") }
        val query = searchQuery.trim()
        if (query.isEmpty()) hiddenFiltered else hiddenFiltered.filter { it.contains(query, ignoreCase = true) }
    }

    LaunchedEffect(serverIds, initialServerId) {
        val currentServerId = selectedServerId
        if (currentServerId.isBlank() || !serverIds.contains(currentServerId)) {
            selectedServerId = servers.firstOrNull { it.id == initialServerId }?.id
                ?: servers.firstOrNull()?.id
                ?: ""
        }
    }

    LaunchedEffect(selectedServerId) {
        if (selectedServerId.isBlank()) return@LaunchedEffect
        searchQuery = ""
        refreshRecentEntries(selectedServerId)
        loadInitialPath(selectedServerId)
    }

    if (showGoToPathDialog) {
        AlertDialog(
            onDismissRequest = {
                showGoToPathDialog = false
                pathInput = ""
            },
            title = { Text("Go to Path") },
            text = {
                OutlinedTextField(
                    value = pathInput,
                    onValueChange = { pathInput = it },
                    singleLine = true,
                    placeholder = { Text("D:\\Projects or /home/me/project") },
                )
            },
            confirmButton = {
                TextButton(onClick = { navigateToInputPath() }) {
                    Text("Go")
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    showGoToPathDialog = false
                    pathInput = ""
                }) {
                    Text("Cancel")
                }
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(0.94f),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.background)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "Select Directory",
                color = LitterTheme.textPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = selectedServer?.let { "Connected server: ${it.name} • ${it.sourceLabel}" } ?: "No server selected",
                    color = if (selectedServer == null) LitterTheme.textMuted else LitterTheme.textSecondary,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )

                Box {
                    Text(
                        text = "Change Server",
                        color = LitterTheme.accent,
                        fontSize = 12.sp,
                        modifier = Modifier.clickable(enabled = servers.isNotEmpty()) { showServerMenu = true },
                    )
                    DropdownMenu(
                        expanded = showServerMenu,
                        onDismissRequest = { showServerMenu = false },
                    ) {
                        servers.forEach { server ->
                            DropdownMenuItem(
                                text = { Text("${server.name} • ${server.sourceLabel}") },
                                onClick = {
                                    showServerMenu = false
                                    selectedServerId = server.id
                                },
                            )
                        }
                    }
                }

                IconButton(onClick = { showHiddenDirectories = !showHiddenDirectories }) {
                    Icon(
                        imageVector = if (showHiddenDirectories) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                        contentDescription = if (showHiddenDirectories) "Hide hidden folders" else "Show hidden folders",
                        tint = if (showHiddenDirectories) LitterTheme.accent else LitterTheme.textSecondary,
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                    .border(1.dp, LitterTheme.border.copy(alpha = 0.85f), RoundedCornerShape(8.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Search, contentDescription = null, tint = LitterTheme.textMuted)
                Spacer(Modifier.width(8.dp))
                Box(modifier = Modifier.weight(1f)) {
                    if (searchQuery.isEmpty()) {
                        Text("Search folders", color = LitterTheme.textMuted, fontSize = 13.sp)
                    }
                    BasicTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                        cursorBrush = SolidColor(LitterTheme.accent),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (searchQuery.isNotEmpty()) {
                    IconButton(onClick = { searchQuery = "" }) {
                        Icon(Icons.Default.Clear, contentDescription = "Clear search", tint = LitterTheme.textMuted)
                    }
                }
            }

            val homeAnchorLocal = remember(selectedServerId, context) {
                if (isLocalServer(selectedServerId)) com.litter.android.state.HomeAnchor.path(context) else null
            }
            val canGoUp = currentPath != "/" && currentPath.isNotEmpty() && currentPath != homeAnchorLocal
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    Text(
                        text = "Up one level",
                        color = if (canGoUp) LitterTheme.accent else LitterTheme.textMuted,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                            .clickable(enabled = canGoUp) { navigateUp() }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
                item {
                    Text(
                        text = "Go to Path",
                        color = LitterTheme.accent,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                            .clickable {
                                pathInput = com.litter.android.state.PathDisplay.display(
                                    currentPath,
                                    isLocalServer(selectedServerId),
                                    context,
                                    remoteHome = remoteHomePath,
                                )
                                showGoToPathDialog = true
                            }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
                items(pathSegments(currentPath)) { segment ->
                    val isCurrent = segment.second == currentPath
                    Text(
                        text = segment.first,
                        color = if (isCurrent) Color.Black else LitterTheme.textSecondary,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .background(
                                if (isCurrent) LitterTheme.accent else LitterTheme.surface,
                                RoundedCornerShape(8.dp),
                            )
                            .clickable { scope.launch { listDirectory(selectedServerId, segment.second) } }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
            }
        }

        when {
            isLoading -> {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Loading…", color = LitterTheme.textSecondary, fontSize = 13.sp)
                }
            }

            errorMessage != null -> {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text("Unable to load directory", color = LitterTheme.danger, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = errorMessage ?: "",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "Retry",
                            color = LitterTheme.accent,
                            fontSize = 13.sp,
                            modifier = Modifier.clickable { scope.launch { listDirectory(selectedServerId, currentPath.ifEmpty { "/" }) } },
                        )
                        Text(
                            text = "Change Server",
                            color = LitterTheme.accent,
                            fontSize = 13.sp,
                            modifier = Modifier.clickable { showServerMenu = true },
                        )
                    }
                }
            }

            else -> {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .background(LitterTheme.background),
                ) {
                    val mostRecentEntry = recentEntries.firstOrNull()
                    if (mostRecentEntry != null && searchQuery.isBlank()) {
                        item("recent-continue") {
                            PickerRow(
                                icon = Icons.Default.CheckCircle,
                                title = "Continue in ${(mostRecentEntry.path.substringAfterLast('/')).ifBlank { mostRecentEntry.path }}",
                                subtitle = com.litter.android.state.PathDisplay.display(
                                    mostRecentEntry.path,
                                    isLocalServer(selectedServerId),
                                    context,
                                ),
                                accent = LitterTheme.accent,
                                onClick = { completeSelection(selectedServerId, mostRecentEntry.path) },
                            )
                        }
                    }

                    if (recentEntries.isNotEmpty() && searchQuery.isBlank()) {
                        item("recent-header") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Recent Directories", color = LitterTheme.textSecondary, fontSize = 12.sp)
                                Spacer(Modifier.weight(1f))
                                Box {
                                    IconButton(onClick = { showRecentsMenu = true }) {
                                        Icon(Icons.Default.MoreHoriz, contentDescription = "Recent options", tint = LitterTheme.textMuted)
                                    }
                                    DropdownMenu(
                                        expanded = showRecentsMenu,
                                        onDismissRequest = { showRecentsMenu = false },
                                    ) {
                                        DropdownMenuItem(
                                            text = { Text("Clear recent directories") },
                                            onClick = {
                                                showRecentsMenu = false
                                                recentEntries = recentStore.clear(selectedServerId, limit = 8)
                                            },
                                        )
                                    }
                                }
                            }
                        }
                        items(recentEntries, key = { "recent-${it.serverId}-${it.path}" }) { recent ->
                            val pretty = com.litter.android.state.PathDisplay.display(
                                recent.path,
                                isLocalServer(selectedServerId),
                                context,
                            )
                            PickerRow(
                                icon = Icons.Default.Folder,
                                title = recent.path.substringAfterLast('/').ifBlank { recent.path },
                                subtitle = "$pretty • ${relativeTime(recent.lastUsedAtEpochMillis)}",
                                accent = LitterTheme.textSecondary,
                                onClick = { completeSelection(selectedServerId, recent.path) },
                            )
                        }
                        item("recent-footer") {
                            Text(
                                text = "Recent directories are saved per connected server.",
                                color = LitterTheme.textMuted,
                                fontSize = 11.sp,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                            )
                        }
                    }

                    if (filteredEntries.isEmpty()) {
                        item("empty") {
                            Text(
                                text = if (searchQuery.isBlank()) "No subdirectories" else "No matches for \"$searchQuery\"",
                                color = LitterTheme.textMuted,
                                fontSize = 12.sp,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
                            )
                        }
                    } else {
                        items(filteredEntries, key = { "entry-$it" }) { entry ->
                            PickerRow(
                                icon = Icons.Default.Folder,
                                title = entry,
                                subtitle = null,
                                accent = LitterTheme.accent,
                                onClick = { navigateInto(entry) },
                            )
                        }
                    }
                }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.background)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = currentPath.ifBlank { "Choose a folder to start a new session." },
                color = if (currentPath.isBlank()) LitterTheme.textSecondary else LitterTheme.textMuted,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = LitterTheme.surface,
                        contentColor = LitterTheme.textPrimary,
                    ),
                ) {
                    Text("Cancel")
                }
                Button(
                    onClick = { completeSelection(selectedServerId, currentPath) },
                    enabled = currentPath.isNotBlank(),
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (currentPath.isNotBlank()) LitterTheme.accent else LitterTheme.surface,
                        contentColor = if (currentPath.isNotBlank()) Color.Black else LitterTheme.textMuted,
                    ),
                ) {
                    Text("Select Folder")
                }
            }
        }
    }
}

@Composable
private fun PickerRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String?,
    accent: Color,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = accent)
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = LitterTheme.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
            subtitle?.let {
                Spacer(Modifier.height(2.dp))
                Text(it, color = LitterTheme.textMuted, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
