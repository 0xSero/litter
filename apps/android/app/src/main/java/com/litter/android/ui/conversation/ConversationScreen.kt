package com.litter.android.ui.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.contextPercent
import com.litter.android.state.hasActiveTurn
import com.litter.android.state.isActiveStatus
import com.litter.android.state.PerfTrace
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.ChatWallpaperBackground
import com.litter.android.ui.ConversationPrefs
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterQuiet
import com.litter.android.ui.LitterRadius
import com.litter.android.ui.LitterSpacing
import com.litter.android.ui.LitterType
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.scaled
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.WallpaperType
import com.litter.android.ui.isNearListBottom
import com.litter.android.ui.rememberStickyFollowTail
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.AppRenameThreadRequest
import uniffi.codex_mobile_client.PendingUserInputRequest
import uniffi.codex_mobile_client.ThreadKey

/**
 * Main conversation screen with turn grouping, scroll-to-bottom FAB,
 * pinned context strip, gradient fade, and inline user input.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
    onNavigateToSessions: (() -> Unit)? = null,
    onShowDirectoryPicker: (() -> Unit)? = null,
    onOpenSavedApp: ((String) -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val launchState by appModel.launchState.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    // Pre-warm Markwon and MessageParser on conversation open
    val warmMarkwon = remember(context) {
        try {
            val prism4j = io.noties.prism4j.Prism4j(com.litter.android.ui.Prism4jGrammarLocator())
            io.noties.markwon.Markwon.builder(context)
                .usePlugin(io.noties.markwon.syntax.SyntaxHighlightPlugin.create(prism4j, io.noties.markwon.syntax.Prism4jThemeDarkula.create()))
                .usePlugin(io.noties.markwon.ext.tables.TablePlugin.create(context))
                .build()
        } catch (_: Exception) {
            io.noties.markwon.Markwon.create(context)
        }
    }
    LaunchedEffect(Unit) {
        // Closes the interval opened by `navigateToConversation`, so the
        // `perf` log reports "tap → conversation composed" as one duration.
        PerfTrace.endInterval("OpenThread", PerfTrace.intervalKey(threadKey))
        // Trigger a lightweight parse to JIT-warm the Rust MessageParser
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            appModel.parser.extractRenderBlocksTyped("")
        }
    }

    val thread = remember(snapshot, threadKey) {
        appModel.threadSnapshot(threadKey)
    }
    val server = remember(snapshot, threadKey) {
        snapshot?.servers?.find { it.serverId == threadKey.serverId }
    }
    val items = thread?.hydratedConversationItems ?: emptyList()
    val normalizedActiveTurnId = thread?.activeTurnId?.trim()?.takeIf { it.isNotEmpty() }
    val isThinking = thread?.info?.status?.isActiveStatus == true
    val minigameOverlay by appModel.minigameOverlay.collectAsState()
    val isMinigameActive = minigameOverlay !is com.litter.android.state.MinigameOverlayState.Idle
    val collapseTurns = ConversationPrefs.areTurnsCollapsed
    val agentDirectoryVersion = snapshot?.agentDirectoryVersion ?: 0uL
    val transcriptTurns = remember(items, thread?.info?.status, isThinking, collapseTurns) {
        buildTranscriptTurns(
            items = items,
            isStreaming = isThinking,
            expandedRecentTurnCount = if (collapseTurns) 1 else Int.MAX_VALUE,
        )
    }
    val transcriptTailSignature = remember(items, normalizedActiveTurnId, isThinking) {
        var hash = 17
        items.takeLast(4).forEach { item ->
            hash = 31 * hash + item.hashCode()
        }
        hash = 31 * hash + items.size
        hash = 31 * hash + (normalizedActiveTurnId?.hashCode() ?: 0)
        hash = 31 * hash + if (isThinking) 1 else 0
        hash
    }
    // Server-paginated windowing: the Rust reducer owns which turns are
    // currently loaded for this thread. Kotlin just renders whatever is in
    // `hydratedConversationItems` and exposes a "Load earlier" button gated
    // on `olderTurnsCursor`. On legacy v0.124 servers this cursor stays null
    // (all turns arrive in the resume response), so the button stays hidden.
    val displayedTurns = transcriptTurns
    val hasMoreTurnsAbove = thread?.olderTurnsCursor != null
    val supportsTurnPagination = server?.capabilities?.supportsTurnPagination == true
    val isInitialTurnsLoading = thread != null &&
        !thread.initialTurnsLoaded &&
        supportsTurnPagination &&
        hasMoreTurnsAbove &&
        displayedTurns.isNotEmpty()
    var isLoadingOlderTurns by remember(threadKey) { mutableStateOf(false) }
    var expandedTurnIds by remember(threadKey, collapseTurns) { mutableStateOf(setOf<String>()) }
    val turnCollapseState = remember(threadKey, collapseTurns) { TranscriptPresentationState() }
    val transcriptRows = remember(transcriptTurns, turnCollapseState, expandedTurnIds) {
        buildTranscriptRows(transcriptTurns, turnCollapseState, expandedTurnIds)
    }
    var streamingRenderTick by remember(threadKey) { mutableStateOf(0) }
    var followScrollToken by remember(threadKey) { mutableStateOf(0) }
    var hasPositionedInitialTail by remember(threadKey) { mutableStateOf(false) }
    var waitingForDataExpired by remember(threadKey) { mutableStateOf(false) }
    LaunchedEffect(threadKey) {
        waitingForDataExpired = false
        kotlinx.coroutines.delay(1000)
        waitingForDataExpired = true
    }
    val threadHasServerData = thread?.let {
        !it.info.preview.isNullOrBlank() || !it.info.title.isNullOrBlank()
    } == true
    val isWaitingForData = items.isEmpty() && threadHasServerData && !waitingForDataExpired
    var lastObservedUpdatedAt by remember(threadKey) { mutableStateOf<Long?>(null) }
    LaunchedEffect(thread?.info?.updatedAt, isThinking) {
        val updatedAt = thread?.info?.updatedAt
        if (updatedAt != null && updatedAt != lastObservedUpdatedAt && isThinking) {
            followScrollToken += 1
        }
        lastObservedUpdatedAt = updatedAt
    }

    // Reuse already-loaded thread content on re-entry, and only fall back to
    // resume/read flows when the conversation isn't available locally yet.
    LaunchedEffect(threadKey) {
        appModel.dismissMinigame()
        try {
            val resolvedThreadKey = appModel.hydrateThreadPermissions(threadKey) ?: threadKey
            appModel.activateThread(resolvedThreadKey)
            // Always call externalResumeThread so the server attaches a
            // streaming listener for this connection. Rust skips the RPC when
            // state is already fresh.
            try {
                appModel.externalResumeThread(resolvedThreadKey)
            } catch (_: Exception) {
                // Fall back to client.resumeThread for servers that need
                // launch config overrides.
                val cwdOverride = appModel.threadSnapshot(resolvedThreadKey)?.info?.cwd
                appModel.client.resumeThread(
                    resolvedThreadKey.serverId,
                    appModel.launchState.threadResumeRequest(
                        resolvedThreadKey.threadId,
                        cwdOverride = cwdOverride,
                        threadKey = resolvedThreadKey,
                    ),
                )
                appModel.refreshThreadSnapshot(resolvedThreadKey)
            }
            if (appModel.threadSnapshot(resolvedThreadKey) == null) {
                appModel.ensureThreadLoaded(resolvedThreadKey)
            }
            appModel.loadConversationMetadataIfNeeded(resolvedThreadKey.serverId)
        } catch (_: Exception) {}
    }

    LaunchedEffect(
        thread?.info?.cwd,
        thread?.effectiveApprovalPolicy,
        thread?.effectiveSandboxPolicy,
    ) {
        appModel.launchState.syncFromThread(thread)
    }

    // Initial turn load. Runs on the AppModel scope so it
    // survives recomposition — when Rust applies the page it flips
    // `initialTurnsLoaded` to true, which recomposes this view and would
    // otherwise cancel a LaunchedEffect mid-RPC. Rust owns the pagination
    // capability decision and falls back to embedded resume turns when needed.
    LaunchedEffect(threadKey, thread?.initialTurnsLoaded) {
        if (thread != null && !thread.initialTurnsLoaded) {
            appModel.loadInitialTurnsIfNeeded(threadKey)
        }
    }

    var showModelSelector by remember { mutableStateOf(false) }
    var showCollaborationModeSelector by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameDraft by remember(threadKey) { mutableStateOf("") }
    var showPermissionsSheet by remember { mutableStateOf(false) }
    var showExperimentalSheet by remember { mutableStateOf(false) }
    var showSkillsSheet by remember { mutableStateOf(false) }
    var showSessionDiffSheet by remember { mutableStateOf(false) }
    var slashErrorMessage by remember { mutableStateOf<String?>(null) }
    var reloadErrorMessage by remember { mutableStateOf<String?>(null) }
    var collaborationModesLoading by remember { mutableStateOf(false) }
    var collaborationModePresets by remember {
        mutableStateOf<List<uniffi.codex_mobile_client.AppCollaborationModePreset>>(emptyList())
    }
    LaunchedEffect(showModelSelector, server?.health, server?.account, server?.availableModels, server?.rateLimits) {
        if (showModelSelector || (server?.account != null && server.rateLimits == null)) {
            appModel.loadConversationMetadataIfNeeded(threadKey.serverId)
        }
    }
    LaunchedEffect(showCollaborationModeSelector) {
        if (!showCollaborationModeSelector || collaborationModesLoading) return@LaunchedEffect
        collaborationModesLoading = true
        collaborationModePresets = try {
            appModel.client.listCollaborationModes(threadKey.serverId)
        } catch (_: Exception) {
            fallbackCollaborationModePresets()
        }
        collaborationModesLoading = false
    }

    // Pending user input for this thread. The dismissal ledger is shared with
    // the global ApprovalOverlay via [LocalDismissedUserInputs] so dismissing
    // from either surface hides the request everywhere.
    val dismissedUserInputs = com.litter.android.ui.LocalDismissedUserInputs.current
    val pendingInput = remember(snapshot, threadKey, dismissedUserInputs.ids) {
        snapshot?.pendingUserInputs?.firstOrNull {
            it.isRelevantToThread(threadKey) &&
                !dismissedUserInputs.isDismissed(it.id)
        }
    }

    val activeTaskSummary = remember(items) {
        items.asReversed().firstNotNullOfOrNull { item ->
            val content = item.content as? HydratedConversationItemContent.TodoList ?: return@firstNotNullOfOrNull null
            val steps = content.v1.steps
            if (steps.isEmpty()) return@firstNotNullOfOrNull null

            val activeSteps = steps.filter {
                it.status != uniffi.codex_mobile_client.HydratedPlanStepStatus.COMPLETED
            }
            if (activeSteps.isEmpty()) return@firstNotNullOfOrNull null

            val completed = steps.count {
                it.status == uniffi.codex_mobile_client.HydratedPlanStepStatus.COMPLETED
            }
            val focusStep = steps.firstOrNull {
                it.status == uniffi.codex_mobile_client.HydratedPlanStepStatus.IN_PROGRESS
            } ?: steps.firstOrNull {
                it.status == uniffi.codex_mobile_client.HydratedPlanStepStatus.PENDING
            } ?: activeSteps.firstOrNull()
            val detail = focusStep?.step?.trim().orEmpty()

            ActiveTaskSummary(
                progress = "$completed/${steps.size}",
                label = detail.ifBlank {
                    if (activeSteps.size == 1) "1 active task" else "${activeSteps.size} active tasks"
                },
            )
        }
    }

    // Only reparse diffs when context items change, not on each assistant token.
    val contextItems = remember(items) {
        items.filter {
            it.content is HydratedConversationItemContent.TodoList ||
                it.content is HydratedConversationItemContent.FileChange ||
                it.content is HydratedConversationItemContent.TurnDiff
        }
    }
    // Pinned context: latest TODO progress + combined session diff summary
    val pinnedContext = remember(contextItems) {
        var todoProgress: String? = null
        val rawDiffSections = mutableListOf<SessionDiffSection>()
        for (i in contextItems.indices.reversed()) {
            when (val c = contextItems[i].content) {
                is HydratedConversationItemContent.TodoList -> {
                    if (todoProgress == null) {
                        val done = c.v1.steps.count {
                            it.status == uniffi.codex_mobile_client.HydratedPlanStepStatus.COMPLETED
                        }
                        todoProgress = "$done/${c.v1.steps.size}"
                    }
                }
                is HydratedConversationItemContent.FileChange -> {
                    c.v1.changes.forEach { change ->
                        val diff = change.diff.trim()
                        if (diff.isBlank()) return@forEach
                        rawDiffSections += SessionDiffSection(
                            title = workspaceTitleCompat(change.path),
                            diff = diff,
                        )
                    }
                }
                is HydratedConversationItemContent.TurnDiff -> {
                    rawDiffSections += parseSessionDiffSections(c.v1.diff)
                }
                else -> {}
            }
        }
        val diffSections = mergeSessionDiffSections(rawDiffSections)
        val diffSummary = diffSections
            .takeIf { it.isNotEmpty() }
            ?.fold(DiffSummary(additions = 0, deletions = 0)) { acc, section ->
                DiffSummary(
                    additions = acc.additions + section.summary.additions,
                    deletions = acc.deletions + section.summary.deletions,
                )
            }
        if (todoProgress != null || diffSummary != null) {
            PinnedContextData(
                todoProgress = todoProgress,
                diffSummary = diffSummary,
                diffSections = diffSections,
            )
        } else {
            null
        }
    }

    // Auto-scroll state
    val listState = rememberLazyListState()
    val shouldFollowTail = rememberStickyFollowTail(
        listState = listState,
        resetKey = threadKey,
    )
    val isAtBottom by remember {
        derivedStateOf {
            listState.isNearListBottom()
        }
    }

    val bottomAnchorIndex = transcriptRows.size +
        (if (hasMoreTurnsAbove) 1 else 0) +
        (if (isWaitingForData || isInitialTurnsLoading) 1 else 0)
    LaunchedEffect(threadKey, bottomAnchorIndex, transcriptTailSignature, followScrollToken, streamingRenderTick) {
        if (shouldFollowTail && displayedTurns.isNotEmpty()) {
            if (!hasPositionedInitialTail || isThinking) {
                listState.scrollToItem(bottomAnchorIndex)
                hasPositionedInitialTail = true
            } else {
                listState.animateScrollToItem(bottomAnchorIndex)
            }
        }
    }

    val wallpaperVersion = WallpaperManager.version
    val hasWallpaper = remember(threadKey, wallpaperVersion) {
        WallpaperManager.resolvedConfig(threadKey)?.type?.let { it != WallpaperType.NONE } == true
    }
    val composerScrimColor = if (hasWallpaper) LitterTheme.surface.copy(alpha = 0.75f) else LitterTheme.surface
    Box(modifier = Modifier.fillMaxSize()) {
        // Wallpaper fills the entire screen edge-to-edge (behind status + nav bars)
        ChatWallpaperBackground(threadKey = threadKey)

        Column(modifier = Modifier.fillMaxSize()) {
            // Message list with gradient fade and scroll FAB
            Box(modifier = Modifier.weight(1f)) {
                if (thread == null) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = LitterTheme.accent)
                    }
                } else {
                    // Use transparent gradient when wallpaper is set
                    val fadeColor = if (hasWallpaper) Color.Transparent else LitterTheme.background

                    // Row callbacks are created once per thread so transcript rows
                    // don't see new lambda instances on every snapshot update.
                    val currentItems = rememberUpdatedState(items)
                    val currentThread = rememberUpdatedState(thread)
                    val onEditMessageStable: (String) -> Unit = remember(threadKey) {
                        { messageId ->
                            // Resolve the user-message position in the
                            // currently-loaded transcript. The Rust
                            // `editMessage` / `forkThreadFromMessage` APIs
                            // expect an index into `thread.items` filtered
                            // to user messages — recomputing here keeps
                            // the index correct under pagination, where a
                            // cached `sourceTurnIndex` from a prior hydrate
                            // would be stale.
                            loadedUserItemIndex(currentItems.value, messageId)?.let { turnIndex ->
                                scope.launch {
                                    val prefill = appModel.store.editMessage(threadKey, turnIndex)
                                    appModel.queueComposerPrefill(threadKey, prefill)
                                }
                            }
                        }
                    }
                    val onForkFromMessageStable: (String) -> Unit = remember(threadKey) {
                        { messageId ->
                            loadedUserItemIndex(currentItems.value, messageId)?.let { turnIndex ->
                                scope.launch {
                                    try {
                                        val newKey = appModel.store.forkThreadFromMessage(
                                            threadKey,
                                            turnIndex,
                                            appModel.launchState.forkThreadFromMessageRequest(
                                                cwdOverride = currentThread.value?.info?.cwd,
                                                threadKey = threadKey,
                                            ),
                                        )
                                        appModel.store.setActiveThread(newKey)
                                        appModel.refreshThreadSnapshot(newKey)
                                    } catch (_: Exception) {}
                                }
                            }
                        }
                    }
                    val onWidgetPromptStable: (String) -> Unit = remember(threadKey) {
                        { text ->
                            scope.launch {
                                try {
                                    val payload = com.litter.android.state.AppComposerPayload(
                                        text = text,
                                        additionalInputs = emptyList(),
                                        approvalPolicy = appModel.launchState.approvalPolicyValue(threadKey),
                                        sandboxPolicy = appModel.launchState.turnSandboxPolicy(threadKey),
                                        model = appModel.launchState.snapshot.value.selectedModel.trim().ifEmpty { null },
                                        reasoningEffort = null,
                                        serviceTier = null,
                                    )
                                    appModel.startTurn(threadKey, payload)
                                } catch (_: Exception) {}
                            }
                        }
                    }

                    LazyColumn(
                        state = listState,
                        contentPadding = PaddingValues(top = 68.dp),
                        verticalArrangement = Arrangement.spacedBy(LitterSpacing.xs),
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = LitterSpacing.margin)
                            .then(
                                if (!hasWallpaper) {
                                    Modifier.drawWithContent {
                                        drawContent()
                                        drawRect(
                                            brush = Brush.verticalGradient(
                                                colors = listOf(LitterTheme.background, Color.Transparent),
                                                startY = 0f,
                                                endY = 48f,
                                            ),
                                        )
                                    }
                                } else Modifier.drawWithContent { drawContent() }
                            ),
                    ) {
                        if (isWaitingForData || isInitialTurnsLoading) {
                            item {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(top = 40.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (isInitialTurnsLoading) {
                                        CircularProgressIndicator(
                                            color = LitterTheme.accent,
                                            strokeWidth = 2.dp,
                                            modifier = Modifier.size(20.dp),
                                        )
                                    } else {
                                        Text(
                                            "Loading conversation…",
                                            color = LitterTheme.textMuted,
                                            fontSize = LitterTextStyle.footnote.scaled,
                                        )
                                    }
                                }
                            }
                        }

                        if (hasMoreTurnsAbove) {
                            item {
                                TextButton(
                                    enabled = !isLoadingOlderTurns,
                                    onClick = {
                                        if (isLoadingOlderTurns) return@TextButton
                                        isLoadingOlderTurns = true
                                        scope.launch {
                                            try {
                                                appModel.loadOlderTurns(threadKey).join()
                                            } finally {
                                                isLoadingOlderTurns = false
                                            }
                                        }
                                    },
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    if (isLoadingOlderTurns) {
                                        CircularProgressIndicator(
                                            color = LitterTheme.accent,
                                            strokeWidth = 2.dp,
                                            modifier = Modifier.size(16.dp),
                                        )
                                    } else {
                                        Text(
                                            "Load earlier messages",
                                            color = LitterTheme.accent,
                                            fontSize = LitterTextStyle.footnote.scaled,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                    }
                                }
                            }
                        }

                        transcriptRows(transcriptRows) { row ->
                            when (row) {
                                is TranscriptRow.Entry -> when (val entry = row.entry) {
                                    is TimelineEntry.Single -> {
                                        ConversationTimelineItem(
                                            item = entry.item,
                                            serverId = threadKey.serverId,
                                            threadId = threadKey.threadId,
                                            threadCwd = thread?.info?.cwd,
                                            agentDirectoryVersion = agentDirectoryVersion,
                                            latestCommandExecutionItemId = row.latestCommandExecutionItemId,
                                            isLiveTurn = row.isActiveTurn,
                                            isStreamingMessage = entry.item.id == row.streamingAssistantItemId,
                                            onStreamingSnapshotRendered = if (entry.item.id == row.streamingAssistantItemId) {
                                                { streamingRenderTick += 1 }
                                            } else {
                                                null
                                            },
                                            onEditMessage = onEditMessageStable,
                                            onForkFromMessage = onForkFromMessageStable,
                                            onOpenSavedApp = onOpenSavedApp,
                                            onWidgetPrompt = onWidgetPromptStable,
                                        )
                                    }
                                    is TimelineEntry.Exploration -> ExplorationGroupRow(
                                        group = entry.group,
                                        showsCollapsedPreview = row.isLastEntry,
                                    )
                                }
                                is TranscriptRow.Collapsed -> CollapsedTurnCard(turn = row.turn) {
                                    expandedTurnIds = expandedTurnIds + row.expansionId
                                }
                                is TranscriptRow.Footer -> Column {
                                    val turn = row.turn
                                    // Debug turn metrics
                                    if (com.litter.android.state.DebugSettings.enabled && com.litter.android.state.DebugSettings.showTurnMetrics) {
                                        val metricsText = remember(turn.items) {
                                            val dur = turn.totalDurationMs
                                            val cmds = turn.commandCount
                                            val files = turn.fileChangeCount
                                            val itemCount = turn.items.size
                                            buildString {
                                                append("$itemCount items")
                                                if (cmds > 0) append(" \u00b7 $cmds cmds")
                                                if (files > 0) append(" \u00b7 $files files")
                                                if (dur > 0) {
                                                    val durStr = if (dur < 1000) "${dur}ms" else "%.1fs".format(dur / 1000.0)
                                                    append(" \u00b7 $durStr")
                                                }
                                            }
                                        }
                                        Text(
                                            text = metricsText,
                                            style = LitterType.meta,
                                            modifier = Modifier.padding(top = 2.dp, start = 4.dp),
                                        )
                                    }
                                    if (turn.isActiveTurn) StreamingCursor()
                                    if (row.canCollapse) {
                                        Text(
                                            text = "show less",
                                            style = LitterType.meta,
                                            modifier = Modifier
                                                .clickable { expandedTurnIds = expandedTurnIds - row.expansionId }
                                                .padding(vertical = LitterSpacing.xxs),
                                        )
                                    }
                                    if (!turn.isActiveTurn) {
                                        // Faint 1dp rule between whole turns; with the list's
                                        // 8dp item spacing this lands at ~32dp between turns.
                                        HorizontalDivider(
                                            thickness = 1.dp,
                                            color = LitterQuiet.turnDivider,
                                            modifier = Modifier.padding(top = LitterSpacing.sm, bottom = LitterSpacing.sm - 1.dp),
                                        )
                                    }
                                }
                            }
                        }

                        item { Spacer(Modifier.height(80.dp)) }
                    }
                }

                // Scroll-to-bottom FAB
                if (!isAtBottom && displayedTurns.isNotEmpty()) {
                    SmallFloatingActionButton(
                        onClick = {
                            scope.launch {
                                listState.animateScrollToItem(bottomAnchorIndex)
                            }
                        },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 8.dp),
                        containerColor = LitterTheme.surface,
                        contentColor = LitterTheme.textPrimary,
                    ) {
                        Icon(Icons.Default.KeyboardArrowDown, "Scroll to bottom", modifier = Modifier.size(20.dp))
                    }
                }
            }

            // Bottom area: gradient fade + pinned context + composer + nav bar inset
            // Hidden while the thinking-minigame overlay is up.
            if (!isMinigameActive) Column(modifier = Modifier.fillMaxWidth()) {
                // Floating minigame launcher — visible only while thinking,
                // gated by the experimental flag.
                val minigameFeatureOn = com.litter.android.ui.ExperimentalFeatures.isEnabled(
                    com.litter.android.ui.LitterFeature.THINKING_MINIGAME,
                )
                if (minigameFeatureOn) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 12.dp, end = 12.dp, bottom = 4.dp),
                        horizontalArrangement = Arrangement.Start,
                    ) {
                        MinigameLaunchButton(onClick = {
                            val (lastUser, lastAssistant) = lastUserAndAssistantText(items)
                            appModel.requestMinigame(
                                parentThreadId = threadKey.threadId,
                                serverId = threadKey.serverId,
                                lastUserMessage = lastUser,
                                lastAssistantMessage = lastAssistant,
                            )
                        })
                    }
                }

                // Gradient fade from transparent to scrim
                if (hasWallpaper) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(24.dp)
                            .background(
                                Brush.verticalGradient(
                                    colors = listOf(Color.Transparent, composerScrimColor),
                                ),
                            ),
                    )
                }

                // Solid scrim area for controls
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(composerScrimColor),
                ) {
                    // Pinned context strip
                    if (pinnedContext != null) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.codeBackground.copy(alpha = if (hasWallpaper) 0.75f else 1f))
                                .padding(horizontal = 16.dp, vertical = 2.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            pinnedContext.todoProgress?.let { todo ->
                                PlanContextBadge(progress = todo)
                            }
                            pinnedContext.diffSummary?.let { diff ->
                                DiffSummaryBadge(
                                    summary = diff,
                                    onClick = { showSessionDiffSheet = true },
                                )
                                CollaborationModeChip(
                                    mode = thread?.collaborationMode ?: uniffi.codex_mobile_client.AppModeKind.DEFAULT,
                                    onClick = { showCollaborationModeSelector = true },
                                )
                            }
                        }
                    }

                    // Inline voice status strip (above composer when voice active)
                    run {
                        val voiceController = remember { com.litter.android.state.VoiceRuntimeController.shared }
                        val voiceLocalSession by voiceController.activeVoiceSession.collectAsState()
                        val voiceSnap by appModel.snapshot.collectAsState()
                        val voicePhase = voiceSnap?.voiceSession?.phase
                        if (voiceLocalSession != null && voicePhase != null) {
                            com.litter.android.ui.voice.InlineVoiceStatusStrip(
                                phase = voicePhase,
                                inputLevel = voiceLocalSession?.inputLevel ?: 0f,
                                outputLevel = voiceLocalSession?.outputLevel ?: 0f,
                                onToggleSpeaker = {
                                    val current = voiceController.isSpeakerEnabled()
                                    voiceController.setSpeakerEnabled(!current)
                                },
                            )
                        }
                    }

                    // Composer bar
                    // Stable callbacks: freshly-allocated inline lambdas here
                    // re-allocate on every recomposition (snapshot emissions are
                    // frequent while streaming), disabling ComposerBar's
                    // argument-level skipping. remember()ed captures keep
                    // identity stable across unrelated recompositions.
                    val onOpenCollaborationModePicker = remember { { showCollaborationModeSelector = true } }
                    val onToggleModelSelector = remember { { showModelSelector = !showModelSelector } }
                    val onShowDirectoryPickerStable = remember { onShowDirectoryPicker }
                    val onNavigateToSessionsStable = remember { onNavigateToSessions }
                    val onShowRenameDialog: (String?) -> Unit = remember(scope, appModel, threadKey, thread?.info?.title) {
                        { initialName: String? ->
                            val trimmed = initialName?.trim().orEmpty()
                            if (trimmed.isNotEmpty()) {
                                scope.launch {
                                    try {
                                        appModel.client.renameThread(
                                            threadKey.serverId,
                                            AppRenameThreadRequest(
                                                threadId = threadKey.threadId,
                                                name = trimmed,
                                            ),
                                        )
                                        appModel.refreshThreadSnapshot(threadKey)
                                    } catch (e: Exception) {
                                        slashErrorMessage = e.message ?: "Failed to rename conversation"
                                    }
                                }
                            } else {
                                renameDraft = thread?.info?.title?.takeIf { it.isNotBlank() }.orEmpty()
                                showRenameDialog = true
                            }
                        }
                    }
                    val onShowPermissionsSheet = remember { { showPermissionsSheet = true } }
                    val onShowExperimentalSheet = remember { { showExperimentalSheet = true } }
                    val onShowSkillsSheet = remember { { showSkillsSheet = true } }
                    val onSlashError = remember { { message: String -> slashErrorMessage = message } }
                    val onDismissPendingUserInput: () -> Unit = remember(pendingInput) {
                        { pendingInput?.let { dismissedUserInputs.dismiss(it.id) }; Unit }
                    }
                    ComposerBar(
                        threadKey = threadKey,
                        collaborationMode = thread?.collaborationMode ?: uniffi.codex_mobile_client.AppModeKind.DEFAULT,
                        activePlanProgress = thread?.activePlanProgress,
                        onOpenCollaborationModePicker = onOpenCollaborationModePicker,
                        onToggleModelSelector = onToggleModelSelector,
                        onNavigateToSessions = onNavigateToSessionsStable,
                        onShowDirectoryPicker = onShowDirectoryPickerStable,
                        activeTurnId = thread?.activeTurnId,
                        contextPercent = thread?.composerContextPercent(),
                        isThinking = isThinking,
                        activeTaskSummary = activeTaskSummary,
                        queuedFollowUps = thread?.queuedFollowUps ?: emptyList(),
                        goal = thread?.goal,
                        rateLimits = thread?.agentRuntimeKind?.let { runtimeKind ->
                            server?.rateLimitsByRuntime?.firstOrNull { it.runtimeKind == runtimeKind }?.rateLimits
                        },
                        showCollaborationModeChip = pinnedContext?.diffSummary == null,
                        onShowRenameDialog = onShowRenameDialog,
                        onShowPermissionsSheet = onShowPermissionsSheet,
                        onShowExperimentalSheet = onShowExperimentalSheet,
                        onShowSkillsSheet = onShowSkillsSheet,
                        onSlashError = onSlashError,
                        pendingUserInput = pendingInput,
                        onDismissPendingUserInput = onDismissPendingUserInput,
                    )

                    // One bottom inset: the keyboard when it is up, otherwise the
                    // navigation bar (the composer used to add both).
                    Spacer(
                        Modifier.windowInsetsBottomHeight(
                            WindowInsets.ime.union(WindowInsets.navigationBars),
                        ),
                    )
                }
            }
        }

        // Only the navigation controls float over the transcript; the full-width
        // title/model bar is gone so messages can scroll through the freed space.
        Column(modifier = Modifier.align(Alignment.TopCenter)) {
            Spacer(Modifier.statusBarsPadding())
            HeaderBar(
                thread = thread,
                onBack = onBack,
                onInfo = onInfo,
                onReloadError = { reloadErrorMessage = it },
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 2.dp),
            )
        }

        // Thinking-indicator minigame overlay: bottom 40% of the screen.
        // Slides up from the bottom when appearing and slides back out on
        // dismiss, mirroring iOS ConversationView.swift:148
        // `.transition(.move(edge: .bottom).combined(with: .opacity))`.
        AnimatedVisibility(
            visible = isMinigameActive,
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .fillMaxHeight(0.4f)
                .padding(horizontal = 8.dp, vertical = 8.dp)
                .navigationBarsPadding(),
        ) {
            MinigameOverlay(
                state = minigameOverlay,
                onClose = { appModel.dismissMinigame() },
                onRetry = {
                    val (lastUser, lastAssistant) = lastUserAndAssistantText(items)
                    appModel.dismissMinigame()
                    appModel.requestMinigame(
                        parentThreadId = threadKey.threadId,
                        serverId = threadKey.serverId,
                        lastUserMessage = lastUser,
                        lastAssistantMessage = lastAssistant,
                    )
                },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (showPermissionsSheet) {
            ModalBottomSheet(
                onDismissRequest = { showPermissionsSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerPermissionsSheet(
                    threadKey = threadKey,
                    onDismiss = { showPermissionsSheet = false },
                )
            }
        }

        if (showModelSelector) {
            LaunchedEffect(threadKey.serverId) {
                appModel.loadAvailableModelsIfNeeded(threadKey.serverId)
            }
            ModalBottomSheet(
                onDismissRequest = { showModelSelector = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                com.litter.android.ui.common.ModelSelectorPanel(
                    thread = thread,
                    availableModels = server?.availableModels ?: emptyList(),
                    catalogLoaded = server?.availableModels != null,
                    catalogError = server?.serverId?.let(appModel::modelCatalogError),
                    onRetryModels = {
                        scope.launch {
                            appModel.loadAvailableModelsIfNeeded(threadKey.serverId, force = true)
                        }
                    },
                    onToggleMode = { mode ->
                        scope.launch {
                            runCatching { appModel.store.setThreadCollaborationMode(threadKey, mode) }
                        }
                    },
                    fastMode = HeaderOverrides.pendingFastMode,
                    onFastModeChange = { HeaderOverrides.pendingFastMode = it },
                    showBackground = false,
                )
            }
        }

        if (showCollaborationModeSelector) {
            ModalBottomSheet(
                onDismissRequest = { showCollaborationModeSelector = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                CollaborationModeSheet(
                    presets = collaborationModePresets.ifEmpty { fallbackCollaborationModePresets() },
                    selectedMode = thread?.collaborationMode ?: uniffi.codex_mobile_client.AppModeKind.DEFAULT,
                    isLoading = collaborationModesLoading,
                    onDismiss = { showCollaborationModeSelector = false },
                    onSelect = { mode ->
                        showCollaborationModeSelector = false
                        scope.launch {
                            try {
                                appModel.store.setThreadCollaborationMode(threadKey, mode)
                            } catch (e: Exception) {
                                slashErrorMessage = e.message ?: "Failed to switch collaboration mode"
                            }
                        }
                    },
                )
            }
        }

        if (showExperimentalSheet) {
            ModalBottomSheet(
                onDismissRequest = { showExperimentalSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerExperimentalSheet(
                    serverId = threadKey.serverId,
                    onDismiss = { showExperimentalSheet = false },
                    onError = { slashErrorMessage = it },
                )
            }
        }

        if (showSkillsSheet) {
            ModalBottomSheet(
                onDismissRequest = { showSkillsSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                ComposerSkillsSheet(
                    serverId = threadKey.serverId,
                    cwd = thread?.info?.cwd ?: launchState.currentCwd.ifBlank { "/" },
                    onDismiss = { showSkillsSheet = false },
                    onError = { slashErrorMessage = it },
                )
            }
        }

        if (showSessionDiffSheet && !pinnedContext?.diffSections.isNullOrEmpty()) {
            ModalBottomSheet(
                onDismissRequest = { showSessionDiffSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                SessionDiffSheet(
                    sections = pinnedContext?.diffSections.orEmpty(),
                    onDismiss = { showSessionDiffSheet = false },
                )
            }
        }

        if (showRenameDialog) {
            AlertDialog(
                onDismissRequest = { showRenameDialog = false },
                title = { Text("Rename Thread") },
                text = {
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        label = { Text("New thread title") },
                        singleLine = true,
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            val nextTitle = renameDraft.trim()
                            if (nextTitle.isEmpty()) {
                                showRenameDialog = false
                                return@TextButton
                            }
                            showRenameDialog = false
                            scope.launch {
                                try {
                                    appModel.client.renameThread(
                                        threadKey.serverId,
                                        AppRenameThreadRequest(
                                            threadId = threadKey.threadId,
                                            name = nextTitle,
                                        ),
                                    )
                                    appModel.refreshThreadSnapshot(threadKey)
                                } catch (e: Exception) {
                                    slashErrorMessage = e.message ?: "Failed to rename conversation"
                                }
                            }
                        },
                    ) {
                        Text("Rename")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showRenameDialog = false }) {
                        Text("Cancel")
                    }
                },
            )
        }

        thread?.pendingPlanImplementationPrompt?.let {
            AlertDialog(
                onDismissRequest = { appModel.store.dismissPlanImplementationPrompt(threadKey) },
                title = { Text("Implement this plan?") },
                text = { Text("Switch back to Default mode and send \"Implement the plan.\"") },
                confirmButton = {
                    TextButton(
                        onClick = {
                            scope.launch {
                                try {
                                    appModel.store.implementPlan(threadKey)
                                } catch (e: Exception) {
                                    slashErrorMessage = e.message ?: "Failed to implement plan"
                                }
                            }
                        },
                    ) {
                        Text("Yes, implement")
                    }
                },
                dismissButton = {
                    TextButton(
                        onClick = { appModel.store.dismissPlanImplementationPrompt(threadKey) },
                    ) {
                        Text("No, stay in Plan")
                    }
                },
            )
        }

        slashErrorMessage?.let { message ->
            AlertDialog(
                onDismissRequest = { slashErrorMessage = null },
                title = { Text("Slash Command Error") },
                text = { Text(message) },
                confirmButton = {
                    TextButton(onClick = { slashErrorMessage = null }) {
                        Text("OK")
                    }
                },
            )
        }

        reloadErrorMessage?.let { message ->
            AlertDialog(
                onDismissRequest = { reloadErrorMessage = null },
                title = { Text("Reload Failed") },
                text = { Text(message) },
                confirmButton = {
                    TextButton(onClick = { reloadErrorMessage = null }) {
                        Text("OK")
                    }
                },
            )
        }
    }
}

private fun PendingUserInputRequest.isRelevantToThread(threadKey: ThreadKey): Boolean {
    if (serverId != threadKey.serverId) return false

    val requestThreadId = threadId.trim()
    return requestThreadId.isEmpty() || requestThreadId == threadKey.threadId
}

private fun fallbackCollaborationModePresets(): List<uniffi.codex_mobile_client.AppCollaborationModePreset> =
    listOf(
        uniffi.codex_mobile_client.AppCollaborationModePreset(
            kind = uniffi.codex_mobile_client.AppModeKind.DEFAULT,
            name = "Default",
            model = null,
            reasoningEffort = null,
        ),
        uniffi.codex_mobile_client.AppCollaborationModePreset(
            kind = uniffi.codex_mobile_client.AppModeKind.PLAN,
            name = "Plan",
            model = null,
            reasoningEffort = uniffi.codex_mobile_client.ReasoningEffort.Medium,
        ),
    )

@Composable
private fun CollaborationModeSheet(
    presets: List<uniffi.codex_mobile_client.AppCollaborationModePreset>,
    selectedMode: uniffi.codex_mobile_client.AppModeKind,
    isLoading: Boolean,
    onDismiss: () -> Unit,
    onSelect: (uniffi.codex_mobile_client.AppModeKind) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Collaboration Mode",
                color = LitterTheme.textPrimary,
                fontSize = 18f.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            TextButton(onClick = onDismiss) {
                Text("Done")
            }
        }

        if (isLoading && presets.isEmpty()) {
            CircularProgressIndicator(color = LitterTheme.accent)
        }

        presets.forEach { preset ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.surface, RoundedCornerShape(16.dp))
                    .clickable { onSelect(preset.kind) }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = preset.name,
                        color = LitterTheme.textPrimary,
                        fontSize = LitterTextStyle.body.scaled,
                        fontWeight = FontWeight.SemiBold,
                    )
                    preset.reasoningEffort?.let { effort ->
                        Text(
                            text = collaborationModeEffortLabel(effort),
                            color = LitterTheme.textSecondary,
                            fontSize = LitterTextStyle.footnote.scaled,
                        )
                    }
                }
                if (preset.kind == selectedMode) {
                    Text(
                        text = "Selected",
                        color = LitterTheme.accent,
                        fontSize = LitterTextStyle.footnote.scaled,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

private fun collaborationModeEffortLabel(
    effort: uniffi.codex_mobile_client.ReasoningEffort,
): String =
    when (effort) {
        uniffi.codex_mobile_client.ReasoningEffort.None -> "None"
        uniffi.codex_mobile_client.ReasoningEffort.Minimal -> "Minimal"
        uniffi.codex_mobile_client.ReasoningEffort.Low -> "Low"
        uniffi.codex_mobile_client.ReasoningEffort.Medium -> "Medium"
        uniffi.codex_mobile_client.ReasoningEffort.High -> "High"
        uniffi.codex_mobile_client.ReasoningEffort.XHigh -> "XHigh"
        uniffi.codex_mobile_client.ReasoningEffort.Max -> "Max"
        uniffi.codex_mobile_client.ReasoningEffort.Ultra -> "Ultra"
        uniffi.codex_mobile_client.ReasoningEffort.Persistent -> "Persistent"
        is uniffi.codex_mobile_client.ReasoningEffort.Custom -> effort.value
    }

private data class PinnedContextData(
    val todoProgress: String?,
    val diffSummary: DiffSummary?,
    val diffSections: List<SessionDiffSection>,
)

private data class DiffSummary(
    val additions: Int,
    val deletions: Int,
) {
    val hasChanges: Boolean
        get() = additions > 0 || deletions > 0
}

private data class SessionDiffSection(
    val title: String,
    val diff: String,
) {
    val id: String = "$title|${diff.hashCode()}"
    val summary: DiffSummary = summarizeDiff(diff)
}

private const val MAX_STICKY_DIFF_SECTIONS = 8
private const val MAX_STICKY_DIFF_CHARACTERS = 20_000

private fun summarizeDiff(diff: String): DiffSummary {
    var additions = 0
    var deletions = 0
    diff.lineSequence().forEach { line ->
        when {
            line.startsWith("+") && !line.startsWith("+++") -> additions += 1
            line.startsWith("-") && !line.startsWith("---") -> deletions += 1
        }
    }
    return DiffSummary(additions = additions, deletions = deletions)
}

private fun uniffi.codex_mobile_client.AppThreadSnapshot.composerContextPercent(): Int? {
    if (contextTokensUsed == null && modelContextWindow == null) return null
    val contextWindow = modelContextWindow?.toLong()
    val baseline = 12_000L
    if (contextWindow == null || contextWindow <= baseline) {
        return contextPercent.coerceIn(0, 100)
    }
    val totalTokens = contextTokensUsed?.toLong() ?: baseline
    val effectiveWindow = contextWindow - baseline
    val usedTokens = (totalTokens - baseline).coerceAtLeast(0)
    val remainingTokens = (effectiveWindow - usedTokens).coerceAtLeast(0)
    return ((remainingTokens.toDouble() / effectiveWindow.toDouble()) * 100.0)
        .toInt()
        .coerceIn(0, 100)
}


@Composable
private fun PlanContextBadge(progress: String) {
    Text(
        text = "Plan $progress",
        color = LitterTheme.accent,
        fontSize = LitterTextStyle.footnote.scaled,
        fontWeight = FontWeight.Medium,
        modifier = Modifier
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

@Composable
private fun DiffSummaryBadge(
    summary: DiffSummary,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(999.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "\u2194",
            color = LitterTheme.accent,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        if (summary.hasChanges) {
            Text(
                text = "+${summary.additions}",
                color = LitterTheme.success,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
                fontFamily = BerkeleyMono,
            )
            Text(
                text = "-${summary.deletions}",
                color = LitterTheme.danger,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
                fontFamily = BerkeleyMono,
            )
        } else {
            Text(
                text = "Diff",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

private fun parseSessionDiffSections(diff: String): List<SessionDiffSection> {
    val normalized = diff.trim()
    if (normalized.isBlank()) return emptyList()

    val lines = normalized.lines()
    val splitIndices = lines.mapIndexedNotNull { index, line ->
        if (line.startsWith("diff --git ")) index else null
    }

    if (splitIndices.isEmpty()) {
        return listOf(
            SessionDiffSection(
                title = diffSectionTitle(normalized),
                diff = normalized,
            ),
        )
    }

    return splitIndices.mapIndexedNotNull { offset, start ->
        val end = if (offset + 1 < splitIndices.size) splitIndices[offset + 1] else lines.size
        val chunk = lines.subList(start, end).joinToString("\n").trim()
        if (chunk.isBlank()) null else SessionDiffSection(title = diffSectionTitle(chunk), diff = chunk)
    }
}

private fun mergeSessionDiffSections(sections: List<SessionDiffSection>): List<SessionDiffSection> {
    val orderedTitles = mutableListOf<String>()
    val mergedByTitle = linkedMapOf<String, String>()
    val passthrough = mutableListOf<SessionDiffSection>()

    sections.forEach { section ->
        val title = section.title.trim()
        if (title.isBlank()) {
            passthrough += section
            return@forEach
        }

        val existing = mergedByTitle[title]
        if (existing == null) {
            orderedTitles += title
            mergedByTitle[title] = section.diff
        } else {
            mergedByTitle[title] = "$existing\n\n${section.diff}"
        }
    }

    return orderedTitles.mapNotNull { title ->
        mergedByTitle[title]?.let { SessionDiffSection(title = title, diff = it) }
    } + passthrough
}

private fun diffSectionTitle(diff: String): String {
    diff.lineSequence().forEach { line ->
        when {
            line.startsWith("diff --git ") -> {
                return stripDiffPathPrefix(line.substringAfterLast(' '))
            }
            line.startsWith("+++ ") -> {
                val path = line.removePrefix("+++ ")
                if (path != "/dev/null") return stripDiffPathPrefix(path)
            }
            line.startsWith("--- ") -> {
                val path = line.removePrefix("--- ")
                if (path != "/dev/null") return stripDiffPathPrefix(path)
            }
        }
    }
    return ""
}

private fun stripDiffPathPrefix(path: String): String {
    return when {
        path.startsWith("a/") || path.startsWith("b/") -> path.drop(2)
        else -> path
    }
}

private fun workspaceTitleCompat(path: String): String {
    return path.trimEnd('/').substringAfterLast('/').ifBlank { path }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionDiffSheet(
    sections: List<SessionDiffSection>,
    onDismiss: () -> Unit,
) {
    var collapsedSectionIds by remember(sections) {
        mutableStateOf(sections.mapTo(linkedSetOf()) { it.id })
    }
    val totalSummary = remember(sections) {
        sections.fold(DiffSummary(additions = 0, deletions = 0)) { acc, section ->
            DiffSummary(
                additions = acc.additions + section.summary.additions,
                deletions = acc.deletions + section.summary.deletions,
            )
        }
    }
    val useStickyHeaders = remember(sections) {
        sections.size <= MAX_STICKY_DIFF_SECTIONS &&
            sections.sumOf { it.diff.length } <= MAX_STICKY_DIFF_CHARACTERS
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "+${totalSummary.additions}",
                    color = LitterTheme.success,
                    fontSize = LitterTextStyle.footnote.scaled,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = BerkeleyMono,
                )
                Text(
                    text = "-${totalSummary.deletions}",
                    color = LitterTheme.danger,
                    fontSize = LitterTextStyle.footnote.scaled,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = BerkeleyMono,
                )
            }
        }

        sections.forEach { section ->
            if (section.title.isNotEmpty()) {
                if (useStickyHeaders) {
                    stickyHeader(key = "header-${section.id}") {
                        SessionDiffSectionHeader(
                            section = section,
                            expanded = !collapsedSectionIds.contains(section.id),
                        ) {
                            collapsedSectionIds =
                                linkedSetOf<String>().apply {
                                    addAll(collapsedSectionIds)
                                    if (contains(section.id)) {
                                        remove(section.id)
                                    } else {
                                        add(section.id)
                                    }
                                }
                        }
                    }
                } else {
                    item(key = "header-${section.id}") {
                        SessionDiffSectionHeader(
                            section = section,
                            expanded = !collapsedSectionIds.contains(section.id),
                        ) {
                            collapsedSectionIds =
                                linkedSetOf<String>().apply {
                                    addAll(collapsedSectionIds)
                                    if (contains(section.id)) {
                                        remove(section.id)
                                    } else {
                                        add(section.id)
                                    }
                                }
                        }
                    }
                }
            }

            item(key = "body-${section.id}") {
                if (section.title.isEmpty() || !collapsedSectionIds.contains(section.id)) {
                    SyntaxHighlightedDiffBlock(
                        diff = section.diff,
                        titleHint = section.title.ifEmpty { null },
                        fontSize = LitterTextStyle.caption.sp,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(LitterTheme.codeBackground, RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                    )
                }
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(onClick = onDismiss) {
                    Text("Done", color = LitterTheme.accent)
                }
            }
        }
    }
}

@Composable
private fun SessionDiffSectionHeader(
    section: SessionDiffSection,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.background)
            .clickable(onClick = onToggle)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = section.title.uppercase(),
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = "+${section.summary.additions}",
            color = LitterTheme.success,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.SemiBold,
            fontFamily = BerkeleyMono,
        )
        Text(
            text = "-${section.summary.deletions}",
            color = LitterTheme.danger,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.SemiBold,
            fontFamily = BerkeleyMono,
        )
        Text(
            text = if (expanded) "▲" else "▼",
            color = LitterTheme.textMuted,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Bold,
        )
    }
}

/**
 * Resolve the user-message position in the currently-loaded transcript.
 * `forkThreadFromMessage` / `editMessage` on the Rust side expect an index
 * into the thread's items filtered to user messages — see
 * `rollback_depth_for_turn` in `mobile_client/thread_projection.rs`.
 * Recomputing from the live `items` keeps the index correct under
 * pagination (older turns can shift positions; a cached `sourceTurnIndex`
 * from a prior hydrate would be stale).
 */
private fun loadedUserItemIndex(
    items: List<uniffi.codex_mobile_client.HydratedConversationItem>,
    messageId: String,
): UInt? {
    var idx = 0u
    for (candidate in items) {
        if (candidate.content !is HydratedConversationItemContent.User) continue
        if (candidate.id == messageId) return idx
        idx++
    }
    return null
}

private fun lastUserAndAssistantText(
    items: List<uniffi.codex_mobile_client.HydratedConversationItem>,
): Pair<String?, String?> {
    var lastUser: String? = null
    var lastAssistant: String? = null
    for (item in items.reversed()) {
        when (val c = item.content) {
            is HydratedConversationItemContent.User -> if (lastUser == null) lastUser = c.v1.text
            is HydratedConversationItemContent.Assistant -> if (lastAssistant == null) lastAssistant = c.v1.text
            else -> {}
        }
        if (lastUser != null && lastAssistant != null) break
    }
    return lastUser to lastAssistant
}

/**
 * Quiet "thinking…" line shown while the assistant is working. Static by
 * design: the stop button and streaming text already signal live work.
 */
@Composable
private fun StreamingCursor() {
    Text(
        text = "thinking…",
        style = LitterType.meta,
        modifier = Modifier.padding(vertical = LitterSpacing.xxs),
    )
}

@Composable
private fun MinigameLaunchButton(onClick: () -> Unit) {
    androidx.compose.material3.Surface(
        onClick = onClick,
        shape = androidx.compose.foundation.shape.CircleShape,
        color = LitterTheme.surface.copy(alpha = 0.9f),
        border = androidx.compose.foundation.BorderStroke(0.5.dp, LitterTheme.accent.copy(alpha = 0.3f)),
        shadowElevation = 2.dp,
        modifier = Modifier.size(36.dp),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Filled.SportsEsports,
                contentDescription = "Play a minigame while waiting",
                tint = LitterTheme.accent,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
