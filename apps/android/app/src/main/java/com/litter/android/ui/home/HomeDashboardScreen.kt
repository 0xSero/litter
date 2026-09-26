package com.litter.android.ui.home

import com.sigkitten.litter.android.BuildConfig
import android.os.Build
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewAgenda
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.automirrored.outlined.ViewQuilt
import androidx.compose.material.icons.outlined.ViewStream
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.DebugSettings
import com.litter.android.state.SavedProjectStore
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedThreadsStore
import com.litter.android.state.connectionModeLabel
import com.litter.android.state.displayTitle
import com.litter.android.state.isConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterFeature
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterSpacing
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterMark
import com.litter.android.ui.LitterMarkHeaderSize
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.common.DebugBuildLabel
import com.litter.android.ui.common.runtimeSortIndex
import com.litter.android.ui.scaled
import com.sigkitten.litter.android.R
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.SavedApp
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.deriveProjects
import uniffi.codex_mobile_client.projectIdFor

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeDashboardScreen(
    onOpenConversation: (ThreadKey) -> Unit,
    onShowDiscovery: () -> Unit,
    discoveryVisible: Boolean = false,
    onShowSettings: () -> Unit,
    onShowApps: () -> Unit,
    onOpenProjectPicker: () -> Unit,
    onOpenAccount: (String) -> Unit,
    selectedProject: AppProject?,
    selectedServerId: String?,
    onSelectServer: (AppServerSnapshot) -> Unit,
    onThreadCreated: (ThreadKey) -> Unit,
    onStartVoice: (() -> Unit)? = null,
    onOpenSavedApp: ((String) -> Unit)? = null,
    onOpenTerminal: (() -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
    val lifecycleController = remember { AppLifecycleController() }

    // Discovery renders its own confirm dialog for the same shared challenge
    // state; skip here while it is up so the two never stack.
    if (!discoveryVisible) appModel.sshHostKeyChangeChallenge?.let { challenge ->
        AlertDialog(
            onDismissRequest = appModel::clearSshHostKeyChange,
            title = { Text("SSH Host Identity Changed") },
            text = {
                Text("The SSH identity for this server changed. This can happen after a server is recreated, but may also indicate a man-in-the-middle attack. New fingerprint: ${challenge.fingerprint}")
            },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        lifecycleController.replaceSshHostKey(appModel, challenge.serverId, challenge.fingerprint)
                    }
                }) { Text("Replace Stored Identity") }
            },
            dismissButton = {
                TextButton(onClick = appModel::clearSshHostKeyChange) { Text("Cancel") }
            },
        )
    }

    var showTipJar by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<AppServerSnapshot?>(null) }
    var renameText by remember { mutableStateOf("") }
    val appVersionLabel = remember { "v${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})" }

    val snap = snapshot
    // Derivations below go through HomeMemo so re-entering Home (back from a
    // conversation) reuses the previous results when the snapshot is unchanged.
    val servers = remember(snap?.servers, snap?.activeThread?.serverId) {
        HomeMemo.servers.get(snap?.servers, snap?.activeThread?.serverId) {
            snap?.let { HomeDashboardSupport.sortedConnectedServers(it) } ?: emptyList()
        }
    }
    // Remembered saved servers are shown in the switcher from the first frame
    // with a quiet "connecting…" until the store reports them, so the pill row
    // never grows after launch and the Local Studio controller's state is
    // visible while it comes up.
    val rememberedServers = remember { HomeMemo.rememberedServers(context) }
    val launchWindowOpen = rememberLaunchWindowOpen()
    LaunchedEffect(snap?.servers) {
        snap?.servers?.let { ServerConnectionMemory.note(it) }
    }
    val serverEntries = remember(servers, snap?.servers, rememberedServers, launchWindowOpen) {
        homeServerEntries(
            visible = servers,
            allSnapshotServers = snap?.servers.orEmpty(),
            remembered = rememberedServers,
            launchWindowOpen = launchWindowOpen,
        )
    }
    // The session list is "known" once a snapshot exists and no saved server
    // is still connecting. Until then Home never shows its empty state.
    val sessionsKnown = snap != null && serverEntries.none {
        it.label == ServerLinkLabel.CONNECTING || it.label == ServerLinkLabel.RECONNECTING
    }
    // Every session across connected servers — unlimited, used by the search
    // view so the user can pin any thread.
    val allSessions = remember(snap?.servers, snap?.sessionSummaries) {
        HomeMemo.allSessions.get(snap?.servers, snap?.sessionSummaries) {
            snap?.let { HomeDashboardSupport.recentSessions(it, limit = Int.MAX_VALUE) } ?: emptyList()
        }
    }
    // Fork lineage map computed from the unfiltered snapshot so a fork
    // whose parent lives on the same server resolves even when later
    // server-scoping drops sessions. Only multi-branch lineages are kept;
    // singletons resolve to `null` at the call site.
    val lineageMap = remember(allSessions) {
        HomeMemo.lineage.get(allSessions) { HomeDashboardSupport.computeLineageMap(allSessions) }
    }

    // Pinned + hidden state. Refreshed when the user mutates via the UI.
    var pinnedKeys by remember { mutableStateOf(SavedThreadsStore.pinnedKeys(context)) }
    var hiddenKeys by remember { mutableStateOf(SavedThreadsStore.hiddenKeys(context)) }

    // Home list = pinned first (preserving pin order). Local Studio also keeps
    // recent sessions visible after a pin so newly synced Pi sessions do not
    // disappear behind legacy pinned rows. Hidden threads stay excluded.
    val homeSessions = remember(pinnedKeys, hiddenKeys, servers, allSessions) {
        HomeMemo.homeSessions.get(pinnedKeys, hiddenKeys, servers, allSessions) {
            mergeHomeSessions(pinnedKeys, hiddenKeys, servers, allSessions)
        }
    }

    val scopedServerId = selectedProject?.serverId ?: selectedServerId
    val recentSessions = remember(homeSessions, scopedServerId) {
        if (scopedServerId.isNullOrEmpty()) homeSessions
        else homeSessions.filter { it.key.serverId == scopedServerId }
    }

    fun pinThreadOnHome(key: ThreadKey) {
        val displacedKeys = if (pinnedKeys.isEmpty()) {
            recentSessions
                .map { it.key }
                .filter { it != key }
        } else {
            emptyList()
        }
        val pin = PinnedThreadKey(serverId = key.serverId, threadId = key.threadId)
        SavedThreadsStore.add(context, pin)
        if (hiddenKeys.contains(pin)) {
            SavedThreadsStore.unhide(context, pin)
        }
        pinnedKeys = SavedThreadsStore.pinnedKeys(context)
        hiddenKeys = SavedThreadsStore.hiddenKeys(context)
        if (displacedKeys.isNotEmpty()) {
            scope.launch {
                displacedKeys.distinct().forEach { displacedKey ->
                    runCatching {
                        appModel.store.unsubscribeThread(displacedKey)
                    }
                }
            }
        }
    }

    // Saved apps by origin thread id. The store's `.apps` StateFlow is kept
    // fresh by AppModel's handleUpdate on SavedAppsChanged (R3), plus a
    // best-effort reload on home re-entry to catch any changes that arrived
    // while we were off-screen.
    // Once per process: AppModel keeps the flow fresh afterwards, so back
    // navigation does not reload saved apps from disk.
    LaunchedEffect(Unit) {
        if (!HomeMemo.savedAppsLoaded) {
            HomeMemo.savedAppsLoaded = true
            try { com.litter.android.state.SavedAppsStore.reload(context) } catch (_: Exception) {}
        }
    }
    val savedAppsAll by com.litter.android.state.SavedAppsStore.apps.collectAsState()
    var confirmAction by remember { mutableStateOf<ConfirmAction?>(null) }
    // Hoisted reply-sheet target. Both the row swipe and the long-press
    // "Reply" menu item set this; the QuickReplySheet renders once at this
    // scope so the two paths stay aligned.
    var replyTargetSession by remember { mutableStateOf<AppSessionSummary?>(null) }
    var isComposerActive by remember { mutableStateOf(false) }
    // When the user taps a composer chip (model / project), a modal sheet
    // opens and the IME dismisses — which would otherwise cascade through
    // `HomeComposerBar.onActiveChange(false)` and collapse the composer
    // back to the `+` button. This flag lets us suppress collapse while a
    // chip sheet is likely mid-interaction.
    var suppressComposerCollapse by remember { mutableStateOf(false) }
    var isSearchExpanded by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    var selectedSearchRuntimeKind by remember { mutableStateOf<AgentRuntimeKind?>(null) }
    var isRefreshingThreadSearch by remember { mutableStateOf(false) }
    val resumingKeys = remember { mutableStateMapOf<String, Boolean>() }
    var coachmarkRootBounds by remember { mutableStateOf(Rect(0f, 0f, 0f, 0f)) }
    val coachmarkTargetBounds = remember { mutableStateMapOf<CoachmarkTarget, Rect>() }

    // Dashboard zoom state. `zoomLevel` observes DashboardZoomPrefs; the
    // toolbar button cycles 1→2→3→4→3→2→1 via a direction flip at the
    // bounds, mirroring iOS HomeDashboardView.swift:186-203. SessionCanvasRow
    // (task #4) owns its own per-row `animateFloatAsState` off this value.
    val zoomLevel by DashboardZoomPrefs.currentLevel.collectAsState()
    var zoomDirection by remember { mutableIntStateOf(1) }
    var pinchBaseZoom by remember { mutableStateOf<Int?>(null) }
    var pinchAccumulator by remember { mutableStateOf(1f) }
    val haptics = LocalHapticFeedback.current
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    // Home list rules: see HomeListVirtualization.
    val renderedCount = rememberPagedLimit(listState, recentSessions.size, scopedServerId)
    val visibleRange = rememberVisibleRange(listState)
    val hydrationPermits = remember {
        kotlinx.coroutines.sync.Semaphore(HomeListVirtualization.MAX_CONCURRENT_HYDRATIONS)
    }

    fun zoomIconFor(level: Int): ImageVector = when (level) {
        // Matches iOS semantics: 1 = most compact (scan), 4 = most detail (deep).
        1 -> Icons.AutoMirrored.Outlined.ViewQuilt
        2 -> Icons.AutoMirrored.Outlined.ViewList
        3 -> Icons.Outlined.ViewAgenda
        else -> Icons.Outlined.ViewStream
    }

    // Auto-resume any visible session that doesn't have a listener yet. Runs on
    // first composition and whenever the visible set changes. We resume
    // rather than read: `externalResumeThread` attaches a server-side
    // conversation listener for this connection so the card receives live
    // `TurnStarted` / `ItemStarted` / `MessageDelta` / `TurnCompleted` events
    // without the user opening the thread. Mirrors iOS `hydrateThread` in
    // `LitterApp.swift:990-1006` after commit 52ff299d. The store short-
    // circuits when a listener is already attached, so warm paths stay cheap.
    // Only pinned rows inside the viewport (+ prefetch) hydrate, at most
    // MAX_CONCURRENT_HYDRATIONS at a time.
    val hydrationWindow = HomeListVirtualization.hydrationWindow(
        firstVisible = visibleRange.first,
        lastVisible = visibleRange.last,
        count = minOf(renderedCount, recentSessions.size),
    )
    val windowSessions = if (hydrationWindow.isEmpty()) {
        emptyList()
    } else {
        recentSessions.subList(hydrationWindow.first, hydrationWindow.last + 1)
    }
    val visibleIds = windowSessions.map { "${it.key.serverId}/${it.key.threadId}" }
    val serverHydrationStates = servers
        .sortedBy { it.serverId }
        .joinToString(separator = "|") { server ->
            "${server.serverId}:${server.transportState}:${server.port}"
        }
    LaunchedEffect(visibleIds, pinnedKeys, serverHydrationStates) {
        val pinnedSet = pinnedKeys.toSet()
        val serversById = servers.associateBy { it.serverId }
        for (session in windowSessions) {
            val pinnedKey = PinnedThreadKey(
                serverId = session.key.serverId,
                threadId = session.key.threadId,
            )
            if (pinnedKey !in pinnedSet) continue
            if (session.isResumed) continue
            val key = session.key
            val id = "${key.serverId}/${key.threadId}"
            if (resumingKeys[id] == true) continue
            if (serversById[key.serverId]?.isConnected != true) continue
            resumingKeys[id] = true
            scope.launch {
                hydrationPermits.acquire()
                try {
                    var resumed = runCatching {
                        appModel.externalResumeThread(key)
                    }.isSuccess
                    if (!resumed) {
                        runCatching { appModel.refreshSessions(listOf(key.serverId)) }
                        resumed = runCatching {
                            appModel.externalResumeThread(key)
                        }.isSuccess
                    }
                    if (resumed) {
                        appModel.loadInitialTurnsIfNeeded(key)
                    }
                    appModel.refreshThreadSnapshot(key)
                } finally {
                    hydrationPermits.release()
                    resumingKeys.remove(id)
                }
            }
        }
    }

    val searchRuntimeKinds = remember(servers) {
        servers
            .flatMap { server ->
                server.agentRuntimes
                    .filter { it.available }
                    .map { it.kind }
            }
            .distinct()
            .sortedBy { it.runtimeSortIndex }
    }

    LaunchedEffect(searchRuntimeKinds) {
        if (selectedSearchRuntimeKind != null && selectedSearchRuntimeKind !in searchRuntimeKinds) {
            selectedSearchRuntimeKind = null
        }
    }

    LaunchedEffect(isSearchExpanded, searchQuery, selectedSearchRuntimeKind) {
        if (!isSearchExpanded) return@LaunchedEffect
        if (searchQuery.isNotBlank()) {
            delay(250)
        }
        isRefreshingThreadSearch = true
        runCatching {
            appModel.refreshThreadSearchSessions(
                query = searchQuery,
                runtimeKind = selectedSearchRuntimeKind,
                forceRepair = false,
            )
        }
        isRefreshingThreadSearch = false
    }

    val showOnboardingCoachmarks = sessionsKnown && recentSessions.isEmpty() &&
        !isComposerActive && !isSearchExpanded
    val relativeCoachmarkTargets = coachmarkTargetBounds.mapValues { (_, rect) ->
        rect.relativeTo(coachmarkRootBounds)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onGloballyPositioned { coachmarkRootBounds = it.boundsInRoot() },
    ) {
        // Sessions list fills the whole screen, with top/bottom content padding
        // so items don't sit under the floating chrome.
        // One set per snapshot instead of a linear server scan in every row.
        val localServerIds = remember(snap?.servers) {
            snap?.servers.orEmpty().filter { it.isLocal }.mapTo(HashSet()) { it.serverId }
        }
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    // Pinch-to-zoom. `detectTransformGestures(panZoomLock = true)`
                    // lets single-finger vertical drags still reach the
                    // LazyColumn scroll, and only begins consuming when a
                    // true pinch is in progress. We accumulate the
                    // multiplicative zoom factor across the gesture so a
                    // slow pinch composes the same as a fast one, then
                    // round to a discrete level delta (same 0.4 threshold
                    // iOS uses at HomeDashboardView.swift:334-363). The
                    // outer while-loop resets accumulator state when the
                    // gesture ends and detectTransformGestures returns.
                    while (true) {
                        pinchBaseZoom = null
                        pinchAccumulator = 1f
                        detectTransformGestures(panZoomLock = true) { _, _, zoom, _ ->
                            if (zoom == 1f) return@detectTransformGestures
                            val base = pinchBaseZoom ?: zoomLevel.also { pinchBaseZoom = it }
                            pinchAccumulator *= zoom
                            val delta = ((pinchAccumulator - 1f) / 0.4f).roundToInt()
                            val next = (base + delta).coerceIn(
                                DashboardZoomPrefs.MIN_LEVEL,
                                DashboardZoomPrefs.MAX_LEVEL,
                            )
                            if (next != zoomLevel) {
                                DashboardZoomPrefs.setLevel(context, next)
                                haptics.performHapticFeedback(
                                    HapticFeedbackType.TextHandleMove,
                                )
                            }
                        }
                    }
                },
            contentPadding = run {
                // Respect system bars so list content can scroll under the
                // translucent top/bottom chrome *and* past the status/nav bar
                // insets (edge-to-edge). The measured top offset covers the
                // floating header/server pills so the first row isn't hidden
                // behind them when the chrome height changes.
                // The chrome has a fixed height (HomeTopChromeHeight), so the
                // first row sits at its final position on the first frame.
                val sysInsets = WindowInsets.systemBars.asPaddingValues()
                androidx.compose.foundation.layout.PaddingValues(
                    top = HomeTopChromeHeight + sysInsets.calculateTopPadding(),
                    bottom = 72.dp + sysInsets.calculateBottomPadding(),
                )
            },
        ) {
            if (recentSessions.isNotEmpty()) {
                // Paged: PAGE_SIZE rows at a time (HomeListVirtualization).
                items(
                    if (renderedCount < recentSessions.size) {
                        recentSessions.subList(0, renderedCount)
                    } else {
                        recentSessions
                    },
                    key = { "${it.key.serverId}/${it.key.threadId}" },
                    contentType = { "session" },
                ) { session ->
                    val id = "${session.key.serverId}/${session.key.threadId}"
                    val isHydrating = !session.isResumed && resumingKeys[id] == true
                    // Row hosts both gestures through one swipe handler:
                    // left-swipe (trailing) hides; right-swipe (leading) opens
                    // QuickReplySheet. Nesting `SwipeToHideRow` inside
                    // `SessionReplySwipe` would have the two pointer handlers
                    // fighting over the same drag stream.
                    val sessionPinKey = PinnedThreadKey(
                        serverId = session.key.serverId,
                        threadId = session.key.threadId,
                    )
                    val sessionIsPinned = pinnedKeys.contains(sessionPinKey)
                    SessionReplySwipe(
                        session = session,
                        appModel = appModel,
                        trailingAction = com.litter.android.ui.common.SwipeAction(
                            icon = Icons.Default.MoreVert,
                            label = "hide",
                            tint = LitterTheme.textMuted,
                            onTrigger = {
                                val key = PinnedThreadKey(
                                    serverId = session.key.serverId,
                                    threadId = session.key.threadId,
                                )
                                SavedThreadsStore.hide(context, key)
                                hiddenKeys = SavedThreadsStore.hiddenKeys(context)
                                pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                                scope.launch {
                                    runCatching { appModel.store.unsubscribeThread(session.key) }
                                }
                            },
                        ),
                        onError = { msg ->
                            confirmAction = ConfirmAction.ReplyError(msg)
                        },
                        onReply = { replyTargetSession = session },
                        // No animateItem(): live updates land in place instead
                        // of sliding rows around at launch.
                    ) {
                        SessionCanvasRow(
                            session = session,
                            zoomLevel = zoomLevel,
                            isHydrating = isHydrating,
                            isLocal = session.key.serverId in localServerIds,
                            lineage = lineageMap[session.key]?.takeIf { it.hasMultipleBranches },
                            isPinned = sessionIsPinned,
                            onClick = {
                                appModel.launchState.updateCurrentCwd(session.cwd)
                                onOpenConversation(session.key)
                            },
                            onDelete = {
                                confirmAction = ConfirmAction.ArchiveSession(session)
                            },
                            onReply = { replyTargetSession = session },
                            onPin = {
                                pinThreadOnHome(session.key)
                            },
                            onUnpin = {
                                SavedThreadsStore.remove(context, sessionPinKey)
                                pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                            },
                            onCancelTurn = {
                                // `interruptTurn` requires both threadId and
                                // turnId; the active turn id lives on the
                                // thread snapshot, not on the session
                                // summary, so look it up just-in-time.
                                scope.launch {
                                    val turnId = appModel.threadSnapshot(session.key)?.activeTurnId
                                        ?: return@launch
                                    runCatching {
                                        appModel.client.interruptTurn(
                                            session.key.serverId,
                                            uniffi.codex_mobile_client.AppInterruptTurnRequest(
                                                threadId = session.key.threadId,
                                                turnId = turnId,
                                            ),
                                        )
                                    }
                                }
                            },
                            onFork = {
                                // Long-press → "Fork" on a home session card.
                                // Head-of-thread fork: duplicates the full
                                // thread server-side (no rollback) and
                                // navigates to the new copy. Mirrors iOS
                                // `forkSessionFromHome` in LitterApp.swift.
                                scope.launch {
                                    try {
                                        val sourceKey = appModel.hydrateThreadPermissions(session.key) ?: session.key
                                        val newKey = appModel.client.forkThread(
                                            sourceKey.serverId,
                                            appModel.launchState.threadForkRequest(
                                                sourceThreadId = sourceKey.threadId,
                                                cwdOverride = session.cwd,
                                                threadKey = sourceKey,
                                            ),
                                        )
                                        appModel.store.setActiveThread(newKey)
                                        appModel.refreshThreadSnapshot(newKey)
                                        appModel.launchState.updateCurrentCwd(session.cwd)
                                        onOpenConversation(newKey)
                                    } catch (e: Exception) {
                                        confirmAction = ConfirmAction.ReplyError(
                                            e.message ?: "Failed to fork thread",
                                        )
                                    }
                                }
                            },
                        )
                    }
                }
                if (zoomLevel == 1 && recentSessions.size <= 10) {
                    item(key = "home-mark-footer", contentType = "footer") {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(LitterSpacing.row),
                            contentAlignment = Alignment.Center,
                        ) {
                            LitterMark(size = LitterMarkHeaderSize, color = LitterTheme.textMuted)
                        }
                    }
                }
            } else {
                item(key = "home-empty-spacer", contentType = "spacer") {
                    Spacer(Modifier.height(1.dp))
                }
            }
        }

        // Top chrome: header + server pill row, floating over the list with a
        // gradient scrim (matches iOS translucent bar). Top edge is fully
        // opaque so the status bar area stays legible, fading to transparent
        // so list content is visibly scrolling behind the chrome.
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        colors = listOf(
                            LitterTheme.background.copy(alpha = 0.55f),
                            LitterTheme.background.copy(alpha = 0.4f),
                            androidx.compose.ui.graphics.Color.Transparent,
                        ),
                    ),
                )
                .statusBarsPadding(),
        ) {
            // Fixed geometry (HomeTopChromeHeight): 8 + 48 header + 2 + 48
            // pills + 16 fade. Nothing inside may change the chrome height.
            Spacer(Modifier.height(LitterSpacing.xs))
            val tierIcons by com.litter.android.state.TipJarSupporterState.tierIcons
            LaunchedEffect(Unit) {
                com.litter.android.state.TipJarSupporterState.refresh(context)
            }
            val leftKitties = tierIcons.take(2).filterNotNull()
            val rightKitties = tierIcons.drop(2).filterNotNull()
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(LitterSpacing.touch)
                    .padding(horizontal = LitterSpacing.xxs),
            ) {
                // Leading actions. The mark is centered independently, so
                // apps/terminal buttons appearing later never move it.
                Row(
                    modifier = Modifier.align(Alignment.CenterStart),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(onClick = onShowSettings, modifier = Modifier.size(LitterSpacing.touch)) {
                        Icon(
                            Icons.Default.Settings,
                            contentDescription = "Settings",
                            tint = LitterTheme.textSecondary,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                    if (savedAppsAll.isNotEmpty()) {
                        IconButton(onClick = onShowApps, modifier = Modifier.size(LitterSpacing.touch)) {
                            Icon(
                                Icons.Outlined.GridView,
                                contentDescription = "Apps",
                                tint = LitterTheme.textSecondary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                    if (onOpenTerminal != null) {
                        IconButton(onClick = onOpenTerminal, modifier = Modifier.size(LitterSpacing.touch)) {
                            Icon(
                                Icons.Outlined.Terminal,
                                contentDescription = "Terminal",
                                tint = LitterTheme.textSecondary,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
                // Mark, with supporter icons in fixed-width slots either side.
                Row(
                    modifier = Modifier.align(Alignment.Center),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Row(
                        modifier = Modifier.width(SupporterSlotWidth),
                        horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.End),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        leftKitties.forEach { iconRes ->
                            androidx.compose.foundation.Image(
                                painter = androidx.compose.ui.res.painterResource(iconRes),
                                contentDescription = "Supporter",
                                modifier = Modifier
                                    .size(28.dp)
                                    .clickable { showTipJar = true },
                            )
                        }
                    }
                    LitterMark(
                        size = LitterMarkHeaderSize,
                        modifier = Modifier.padding(horizontal = LitterSpacing.xs),
                    )
                    Row(
                        modifier = Modifier.width(SupporterSlotWidth),
                        horizontalArrangement = Arrangement.spacedBy(2.dp, Alignment.Start),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        rightKitties.forEach { iconRes ->
                            androidx.compose.foundation.Image(
                                painter = androidx.compose.ui.res.painterResource(iconRes),
                                contentDescription = "Supporter",
                                modifier = Modifier
                                    .size(28.dp)
                                    .clickable { showTipJar = true },
                            )
                        }
                    }
                }
                // Zoom cycle button. Cycles 1→2→3→4→3→2→1 via direction flip at
                // the bounds. Mirrors iOS HomeDashboardView.swift:186-203.
                IconButton(
                    onClick = {
                        var next = zoomLevel + zoomDirection
                        if (next > DashboardZoomPrefs.MAX_LEVEL) {
                            zoomDirection = -1
                            next = zoomLevel + zoomDirection
                        } else if (next < DashboardZoomPrefs.MIN_LEVEL) {
                            zoomDirection = 1
                            next = zoomLevel + zoomDirection
                        }
                        DashboardZoomPrefs.setLevel(context, next)
                    },
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .size(LitterSpacing.touch),
                ) {
                    Icon(
                        imageVector = zoomIconFor(zoomLevel),
                        contentDescription = "Dashboard zoom",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            Spacer(Modifier.height(2.dp))

            ServerPillRow(
                servers = serverEntries,
                selectedServerId = selectedProject?.serverId ?: selectedServerId,
                onTap = { entry ->
                    val live = entry.snapshot
                    if (live != null && entry.label == null) {
                        onSelectServer(live)
                    } else {
                        // Not up yet: a tap asks for a reconnect instead.
                        scope.launch {
                            lifecycleController.reconnectServer(context, appModel, entry.serverId)
                        }
                    }
                },
                onReconnect = { server ->
                    scope.launch {
                        lifecycleController.reconnectServer(context, appModel, server.serverId)
                    }
                },
                onRestartAppServer = { entry ->
                    val server = entry.snapshot ?: return@ServerPillRow
                    scope.launch {
                        try {
                            if (server.isLocal) {
                                appModel.restartLocalServer()
                            } else {
                                appModel.serverBridge.restartAppServer(server.serverId)
                                lifecycleController.reconnectServer(context, appModel, server.serverId)
                            }
                            appModel.refreshSnapshot()
                        } catch (error: Exception) {
                            confirmAction = ConfirmAction.ReplyError(
                                error.message ?: "Unable to restart app server.",
                            )
                        }
                    }
                },
                onRename = { entry ->
                    entry.snapshot?.let { server ->
                        renameText = server.displayName
                        renameTarget = server
                    }
                },
                onRemove = { entry ->
                    val server = entry.snapshot
                    if (server != null) {
                        confirmAction = ConfirmAction.DisconnectServer(server)
                    } else {
                        scope.launch {
                            SavedServerStore.remove(context, entry.serverId)
                            HomeMemo.invalidateRememberedServers()
                            appModel.refreshSnapshot()
                        }
                    }
                },
                onAdd = onShowDiscovery,
                onAddBoundsChanged = { coachmarkTargetBounds[CoachmarkTarget.AddServer] = it },
            )

            // Short fade at the bottom of the top scrim for a soft transition.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(16.dp)
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            colors = listOf(
                                LitterTheme.background.copy(alpha = 0.7f),
                                androidx.compose.ui.graphics.Color.Transparent,
                            ),
                        ),
                    ),
            )
        }

        // Full-screen search overlay (mirrors iOS) — search bar pinned at top
        // with a close affordance; results fill the rest of the screen on an
        // opaque background. Replaces the prior inline-in-bottom-chrome layout.
        if (isSearchExpanded) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .background(LitterTheme.background)
                    .statusBarsPadding()
                    .imePadding(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(modifier = Modifier.weight(1f)) {
                        ThreadSearchBar(
                            query = searchQuery,
                            isExpanded = true,
                            onQueryChange = { searchQuery = it },
                            onExpandChange = { expanded ->
                                isSearchExpanded = expanded
                                if (!expanded) {
                                    searchQuery = ""
                                    selectedSearchRuntimeKind = null
                                }
                            },
                        )
                    }
                    androidx.compose.material3.IconButton(
                        onClick = {
                            isSearchExpanded = false
                            searchQuery = ""
                            selectedSearchRuntimeKind = null
                        },
                        modifier = Modifier.size(40.dp),
                    ) {
                        Icon(
                            imageVector = androidx.compose.material.icons.Icons.Default.Close,
                            contentDescription = "Close search",
                            tint = LitterTheme.textSecondary,
                        )
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                ) {
                    ThreadSearchResults(
                        sessions = allSessions,
                        pinnedKeys = pinnedKeys.toSet(),
                        query = searchQuery,
                        runtimeKinds = searchRuntimeKinds,
                        selectedRuntimeKind = selectedSearchRuntimeKind,
                        isRefreshing = isRefreshingThreadSearch,
                        onRuntimeSelected = { selectedSearchRuntimeKind = it },
                        onRefresh = {
                            scope.launch {
                                isRefreshingThreadSearch = true
                                runCatching {
                                    appModel.refreshThreadSearchSessions(
                                        query = searchQuery,
                                        runtimeKind = selectedSearchRuntimeKind,
                                        forceRepair = true,
                                    )
                                }
                                isRefreshingThreadSearch = false
                            }
                        },
                        onOpen = { session ->
                            isSearchExpanded = false
                            searchQuery = ""
                            selectedSearchRuntimeKind = null
                            appModel.launchState.updateCurrentCwd(session.cwd)
                            onOpenConversation(session.key)
                        },
                        onArchive = { session ->
                            confirmAction = ConfirmAction.ArchiveSession(session)
                        },
                        onPin = { session ->
                            pinThreadOnHome(session.key)
                            selectedSearchRuntimeKind = null
                        },
                        onUnpin = { session ->
                            val key = PinnedThreadKey(
                                serverId = session.key.serverId,
                                threadId = session.key.threadId,
                            )
                            SavedThreadsStore.remove(context, key)
                            pinnedKeys = SavedThreadsStore.pinnedKeys(context)
                        },
                    )
                }
            }
        }

        // Bottom chrome: collapsed by default into two icon buttons
        // (`+` and search); each expands its corresponding row inline when
        // tapped. Mirrors iOS `HomeBottomBar` collapsed/composer/search modes.
        // Scrim fades from transparent to translucent background so the list
        // visibly scrolls behind the chrome (matches iOS translucent bar).
        // Hidden entirely while the full-screen search overlay is open.
        if (!isSearchExpanded) Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .navigationBarsPadding()
                .imePadding(),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(32.dp)
                    .background(
                        androidx.compose.ui.graphics.Brush.verticalGradient(
                            colors = listOf(
                                androidx.compose.ui.graphics.Color.Transparent,
                                LitterTheme.background.copy(alpha = 0.4f),
                            ),
                        ),
                    ),
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.background.copy(alpha = 0.4f)),
            ) {
                DebugBuildLabel(modifier = Modifier.align(Alignment.End))
                when {
                    // Full-screen search overlay above handles the search UI;
                    // suppress the bottom chrome entirely while it's open so
                    // there isn't a duplicate search bar at the bottom.
                    isSearchExpanded -> {}
                    isComposerActive -> {
                        val serverForModels = selectedProject?.serverId
                            ?: selectedServerId
                            ?: servers.firstOrNull { !it.isLocal }?.serverId
                            ?: servers.firstOrNull()?.serverId
                        // Model + project chips sit above the composer input,
                        // mirroring iOS `HomeDashboardView.swift:273-288`. The
                        // model chip opens a bottom sheet with model/effort
                        // selection; the project chip opens the project
                        // picker.
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 14.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(
                                8.dp,
                                Alignment.End,
                            ),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            ProjectChip(
                                project = selectedProject,
                                disabled = servers.isEmpty(),
                                onTap = {
                                    // Hold the composer open through the
                                    // project-picker navigation so the user
                                    // returns to an expanded composer. The
                                    // flag self-resets after a short delay.
                                    suppressComposerCollapse = true
                                    onOpenProjectPicker()
                                },
                            )
                        }
                        // Drop the collapse suppression a moment after the
                        // last chip interaction, once any transient focus
                        // churn has settled.
                        LaunchedEffect(suppressComposerCollapse) {
                            if (suppressComposerCollapse) {
                                kotlinx.coroutines.delay(1500)
                                suppressComposerCollapse = false
                            }
                        }
                        HomeComposerBar(
                            modelPill = {
                                HomeModelChip(
                                    serverId = serverForModels,
                                    disabled = serverForModels.isNullOrBlank(),
                                    onSheetStateChange = { open ->
                                        suppressComposerCollapse = open
                                    },
                                    asPill = true,
                                )
                            },
                            project = selectedProject,
                            onThreadCreated = { key ->
                                pinThreadOnHome(key)
                                onThreadCreated(key)
                            },
                            onLoginRequired = onOpenAccount,
                            onActiveChange = { active ->
                                if (active) {
                                    isComposerActive = true
                                } else if (!suppressComposerCollapse) {
                                    isComposerActive = false
                                }
                            },
                        )
                    }
                    else -> {
                        // Collapsed: realtime voice pill on the left, + and search
                        // pills on the right. All three share the same 44dp
                        // circular glass style; only the mic pill's icon tint
                        // reflects live voice state.
                        val realtimeAvailable = remember {
                            ExperimentalFeatures.isEnabled(LitterFeature.REALTIME_VOICE)
                        }
                        val voicePhase = snapshot?.voiceSession?.phase
                        val voiceIconTint = when (voicePhase) {
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.CONNECTING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.LISTENING,
                            -> LitterTheme.accent
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.SPEAKING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.THINKING,
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.HANDOFF,
                            -> LitterTheme.warning
                            uniffi.codex_mobile_client.AppVoiceSessionPhase.ERROR -> LitterTheme.danger
                            null -> LitterTheme.textSecondary
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(start = 14.dp, end = 14.dp, top = 6.dp, bottom = 20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (realtimeAvailable && onStartVoice != null) {
                                androidx.compose.material3.IconButton(
                                    onClick = { onStartVoice() },
                                    modifier = Modifier
                                        .size(44.dp)
                                        .onGloballyPositioned {
                                            coachmarkTargetBounds[CoachmarkTarget.Voice] = it.boundsInRoot()
                                        }
                                        .background(
                                            LitterTheme.surface.copy(alpha = 0.9f),
                                            CircleShape,
                                        ),
                                ) {
                                    Icon(
                                        imageVector = androidx.compose.material.icons.Icons.Default.Mic,
                                        contentDescription = "Start realtime voice",
                                        tint = voiceIconTint,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }
                            }
                            Spacer(Modifier.weight(1f))
                            androidx.compose.material3.IconButton(
                                onClick = { isComposerActive = true },
                                modifier = Modifier
                                    .size(44.dp)
                                    .onGloballyPositioned {
                                        coachmarkTargetBounds[CoachmarkTarget.NewThread] = it.boundsInRoot()
                                    }
                                    .background(
                                        LitterTheme.surface.copy(alpha = 0.9f),
                                        CircleShape,
                                    ),
                            ) {
                                Icon(
                                    imageVector = androidx.compose.material.icons.Icons.Default.Add,
                                    contentDescription = "New message",
                                    tint = LitterTheme.textPrimary,
                                    modifier = Modifier.size(22.dp),
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            androidx.compose.material3.IconButton(
                                onClick = { isSearchExpanded = true },
                                modifier = Modifier
                                    .size(44.dp)
                                    .onGloballyPositioned {
                                        coachmarkTargetBounds[CoachmarkTarget.Search] = it.boundsInRoot()
                                    }
                                    .background(
                                        LitterTheme.surface.copy(alpha = 0.9f),
                                        CircleShape,
                                    ),
                            ) {
                                Icon(
                                    imageVector = androidx.compose.material.icons.Icons.Outlined.Search,
                                    contentDescription = "Search threads",
                                    tint = LitterTheme.textSecondary,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                }
            }
        }

        if (showOnboardingCoachmarks) {
            Box(
                modifier = Modifier.matchParentSize(),
                contentAlignment = Alignment.Center,
            ) {
                LitterMark(size = 96.dp, color = LitterTheme.textMuted, fadeIn = true)
            }
            OnboardingCoachmarks(
                targets = relativeCoachmarkTargets,
                modifier = Modifier.matchParentSize(),
            )
        }

    }

    replyTargetSession?.let { target ->
        QuickReplySheet(
            thread = target,
            onDismiss = { replyTargetSession = null },
            onSend = { threadKey, text ->
                runCatching {
                    sendQuickReplyTurn(appModel, threadKey, text)
                }.onFailure { err ->
                    confirmAction = ConfirmAction.ReplyError(
                        err.message ?: "Failed to send reply",
                    )
                }
            },
        )
    }

    confirmAction?.let { action ->
        AlertDialog(
            onDismissRequest = { confirmAction = null },
            title = { Text(action.title) },
            text = { Text(action.message) },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        when (action) {
                            is ConfirmAction.ArchiveSession -> {
                                voiceController.stopVoiceSessionIfActive(appModel, action.session.key)
                                voiceController.clearPinnedLocalVoiceThreadIfMatches(appModel, action.session.key)
                                if (appModel.snapshot.value?.activeThread == action.session.key) {
                                    appModel.store.setActiveThread(null)
                                }
                                try {
                                    appModel.client.archiveThread(
                                        action.session.key.serverId,
                                        uniffi.codex_mobile_client.AppArchiveThreadRequest(
                                            threadId = action.session.key.threadId,
                                        ),
                                    )
                                } catch (_: Exception) {}
                                kotlinx.coroutines.delay(400L)
                                appModel.refreshSnapshot()
                            }
                            is ConfirmAction.DisconnectServer -> {
                                SavedServerStore.remove(context, action.server.serverId)
                                HomeMemo.invalidateRememberedServers()
                                appModel.sshSessionStore.close(action.server.serverId)
                                appModel.serverBridge.disconnectServer(action.server.serverId)
                                appModel.refreshSnapshot()
                            }
                            is ConfirmAction.ReplyError -> {
                                // Informational dialog only — "Confirm" just dismisses.
                            }
                        }
                    }
                    confirmAction = null
                }) {
                    Text("Confirm", color = LitterTheme.danger)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmAction = null }) {
                    Text("Cancel")
                }
            },
        )
    }
    renameTarget?.let { server ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename Server") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val trimmed = renameText.trim()
                    if (trimmed.isEmpty()) return@TextButton
                    scope.launch {
                        SavedServerStore.rename(context, server.serverId, trimmed)
                        appModel.refreshSnapshot()
                    }
                    renameTarget = null
                }) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) {
                    Text("Cancel")
                }
            },
        )
    }
    if (showTipJar) {
        ModalBottomSheet(
            onDismissRequest = { showTipJar = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            com.litter.android.ui.settings.TipJarScreen(onBack = { showTipJar = false })
        }
    }
}

private val HomeTopChromeHeight = 122.dp
private val SupporterSlotWidth = 64.dp

/**
 * Merge rule:
 * - If the user has pinned anything, the home list starts with their pins
 *   (in pin order, most-recent-pinned first).
 * - Local Studio appends its unpinned recent sessions so a pin cannot hide
 *   newly synced Pi sessions. Other runtimes keep the existing pins-only rule.
 * - If nothing is pinned, fill the list with up to 10 most-recent
 *   sessions so the home screen isn't empty.
 * - Hidden threads are always excluded.
 */
internal fun mergeHomeSessions(
    pinned: List<PinnedThreadKey>,
    hidden: List<PinnedThreadKey>,
    servers: List<AppServerSnapshot>,
    allSessions: List<AppSessionSummary>,
): List<AppSessionSummary> {
    val hiddenSet = hidden.toSet()
    val candidates = allSessions.filter {
        PinnedThreadKey(serverId = it.key.serverId, threadId = it.key.threadId) !in hiddenSet
    }
    if (pinned.isNotEmpty()) {
        val byKey = candidates.associateBy {
            PinnedThreadKey(serverId = it.key.serverId, threadId = it.key.threadId)
        }
        val serversById = servers.associateBy { it.serverId }
        val pinnedSessions = pinned.mapNotNull { key ->
            if (key in hiddenSet) return@mapNotNull null
            byKey[key] ?: serversById[key.serverId]?.let { server ->
                placeholderPinnedSession(key, server)
            }
        }
        val pinnedSet = pinned.toSet()
        val localStudioServerIds = servers.asSequence()
            .filter { server ->
                usesServerConfiguredModelDefault(
                    server.agentRuntimes.filter { it.available }.map { it.kind },
                )
            }
            .map { it.serverId }
            .toSet()
        val localStudioRecent = candidates.filter { session ->
            session.key.serverId in localStudioServerIds &&
                PinnedThreadKey(
                    serverId = session.key.serverId,
                    threadId = session.key.threadId,
                ) !in pinnedSet
        }
        return pinnedSessions + localStudioRecent
    }
    return candidates.take(10)
}

private fun placeholderPinnedSession(
    pinned: PinnedThreadKey,
    server: AppServerSnapshot,
): AppSessionSummary = AppSessionSummary(
    key = uniffi.codex_mobile_client.ThreadKey(
        serverId = pinned.serverId,
        threadId = pinned.threadId,
    ),
    agentRuntimeKind = if (
        usesServerConfiguredModelDefault(
            server.agentRuntimes.filter { it.available }.map { it.kind },
        )
    ) {
        "local-studio"
    } else {
        "codex"
    },
    serverDisplayName = server.displayName,
    serverHost = server.host,
    title = "Loading thread",
    preview = "",
    cwd = "",
    model = "",
    modelProvider = "",
    parentThreadId = null,
    forkedFromId = null,
    agentNickname = null,
    agentRole = null,
    agentDisplayLabel = null,
    agentStatus = uniffi.codex_mobile_client.AppSubagentStatus.UNKNOWN,
    updatedAt = null,
    hasActiveTurn = false,
    isResumed = false,
    isSubagent = false,
    isFork = false,
    lastResponsePreview = null,
    lastResponseTurnId = null,
    lastUserMessage = null,
    lastToolLabel = null,
    recentToolLog = emptyList(),
    lastTurnStartMs = null,
    lastTurnEndMs = null,
    stats = null,
    tokenUsage = null,
    goal = null,
)

private sealed class ConfirmAction {
    abstract val title: String
    abstract val message: String

    data class ArchiveSession(val session: AppSessionSummary) : ConfirmAction() {
        override val title = "Delete Session"
        override val message = "Are you sure you want to delete this session?"
    }

    data class DisconnectServer(val server: AppServerSnapshot) : ConfirmAction() {
        override val title = "Disconnect Server"
        override val message = "Disconnect from ${server.displayName}?"
    }

    data class ReplyError(val reason: String) : ConfirmAction() {
        override val title = "Reply Failed"
        override val message = reason
    }
}

private fun Rect.relativeTo(root: Rect): Rect {
    return Rect(
        left = left - root.left,
        top = top - root.top,
        right = right - root.left,
        bottom = bottom - root.top,
    )
}

