package com.litter.android.ui

import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import com.litter.android.state.AppModel
import com.litter.android.state.LocalAccountLoginRequiredException
import com.litter.android.state.NetworkDiscovery
import com.litter.android.state.PetOverlayController
import com.litter.android.state.SavedThreadsStore
import com.litter.android.state.VoiceRuntimeController
import com.litter.android.state.connectionModeLabel
import kotlinx.coroutines.launch
import com.litter.android.ui.conversation.ApprovalOverlay
import com.litter.android.ui.conversation.ConversationInfoScreen
import com.litter.android.ui.conversation.ConversationScreen
import com.litter.android.ui.discovery.DiscoveryScreen
import com.litter.android.ui.home.HomeDashboardScreen
import com.litter.android.ui.home.HomeDashboardSupport
import com.litter.android.ui.home.ProjectPickerSheet
import com.litter.android.ui.pets.PetOverlayView
import com.litter.android.state.SavedProjectStore
import com.litter.android.ui.settings.AccountSheet
import com.litter.android.ui.settings.SettingsSheet
import com.litter.android.ui.settings.SettingsStartDestination
import com.litter.android.ui.sessions.DirectoryPickerServerOption
import com.litter.android.ui.sessions.DirectoryPickerSheet
import com.litter.android.ui.sessions.SessionLaunchSupport
import com.litter.android.ui.sessions.SessionsUiState
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.deriveProjects
import uniffi.codex_mobile_client.projectIdFor

/**
 * CompositionLocal for accessing [AppModel] from any composable.
 */
val LocalAppModel = staticCompositionLocalOf<AppModel> {
    error("AppModel not provided")
}

/**
 * Root composable for the app. Manages navigation stack and global overlays.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LitterApp(
    appModel: AppModel,
    openPetSettingsRequest: Int = 0,
) {
    val context = LocalContext.current

    // Initialize text size preference
    LaunchedEffect(Unit) {
        TextSizePrefs.initialize(context)
        ConversationPrefs.initialize(context)
        com.litter.android.ui.home.DashboardZoomPrefs.initialize(context)
        ExperimentalFeatures.initialize(context)
        com.litter.android.state.DebugSettings.initialize(context)
        PetOverlayController.initialize(context)
    }

    // Read currentStep so Compose tracks it as a dependency and recomposes on change.
    val textScale = ConversationTextSize.fromStep(TextSizePrefs.currentStep).scale
    CompositionLocalProvider(
        LocalAppModel provides appModel,
        LocalTextScale provides textScale,
    ) {
        val snapshot by appModel.snapshot.collectAsState()
        val scope = androidx.compose.runtime.rememberCoroutineScope()

        // Navigation state
        var navStack by remember { mutableStateOf<List<Route>>(listOf(Route.Home)) }
        val currentRoute = navStack.lastOrNull() ?: Route.Home
        val sessionsUiState = remember { SessionsUiState() }

        // Global sheet state
        var showDiscovery by remember { mutableStateOf(false) }
        var showSettings by remember { mutableStateOf(false) }
        var settingsStartDestination by remember { mutableStateOf(SettingsStartDestination.TopLevel) }
        var showAccountForServer by remember { mutableStateOf<String?>(null) }
        var directoryPickerServerId by remember { mutableStateOf<String?>(null) }
        var directoryPickerForProject by remember { mutableStateOf(false) }
        var showProjectPicker by remember { mutableStateOf(false) }

        // Home selection state
        var selectedServerId by remember {
            mutableStateOf(SavedProjectStore.selectedServerId(context))
        }
        var selectedProject by remember { mutableStateOf<AppProject?>(null) }

        // Persist selections
        LaunchedEffect(selectedServerId) {
            SavedProjectStore.setSelectedServerId(context, selectedServerId)
        }
        LaunchedEffect(selectedProject?.id) {
            SavedProjectStore.setSelectedProjectId(context, selectedProject?.id)
        }

        // Derive projects from current sessions
        val projects = remember(snapshot) {
            snapshot?.let { deriveProjects(it.sessionSummaries) } ?: emptyList()
        }

        // Keep selectedServerId valid against connected servers. Default is
        // no filter — if the persisted/pinned server isn't connected, clear.
        LaunchedEffect(snapshot) {
            val connected = snapshot?.let { snap ->
                HomeDashboardSupport.sortedConnectedServers(snap).map { it.serverId }
            } ?: emptyList()
            if (selectedServerId != null && selectedServerId !in connected) {
                selectedServerId = null
            }
        }

        // Reconcile selectedProject against selectedServerId + projects
        LaunchedEffect(selectedServerId, projects) {
            val currentServerId = selectedServerId ?: run {
                selectedProject = null
                return@LaunchedEffect
            }
            val serverProjects = projects.filter { it.serverId == currentServerId }
            val current = selectedProject
            if (current != null && current.serverId == currentServerId) {
                val refreshed = serverProjects.firstOrNull { it.id == current.id }
                if (refreshed != null) {
                    selectedProject = refreshed
                }
                return@LaunchedEffect
            }
            val persistedId = SavedProjectStore.selectedProjectId(context)
            val match = serverProjects.firstOrNull { it.id == persistedId }
                ?: serverProjects.firstOrNull()
            selectedProject = match
        }

        // Network discovery
        val networkDiscovery = remember { NetworkDiscovery(appModel.discovery) }
        val voiceController = remember { VoiceRuntimeController.shared }

        LaunchedEffect(openPetSettingsRequest) {
            if (openPetSettingsRequest <= 0) return@LaunchedEffect
            settingsStartDestination = SettingsStartDestination.Pets
            showSettings = true
        }

        // Navigate helpers
        val navigate = remember {
            { route: Route -> navStack = navStack + route }
        }
        val navigateBack = remember {
            { if (navStack.size > 1) navStack = navStack.dropLast(1) }
        }
        val navigateToConversation = remember {
            { key: ThreadKey -> navStack = listOf(Route.Home, Route.Conversation(key)) }
        }
        val connectedServerOptions = remember(snapshot) {
            snapshot?.let { snap ->
                HomeDashboardSupport.sortedConnectedServers(snap).map { server ->
                    DirectoryPickerServerOption(
                        id = server.serverId,
                        name = server.displayName,
                        sourceLabel = server.connectionModeLabel,
                    )
                }
            } ?: emptyList()
        }

        suspend fun startNewSession(serverId: String, cwd: String) {
            val serverIsLocal = appModel.snapshot.value
                ?.servers
                ?.firstOrNull { it.serverId == serverId }
                ?.isLocal == true
            val startedKey = appModel.startThread(
                serverId,
                appModel.launchState.threadStartRequest(cwd, serverIsLocal = serverIsLocal),
            )
            RecentDirectoryStore(context).record(serverId, cwd)
            SavedThreadsStore.add(
                context,
                PinnedThreadKey(serverId = startedKey.serverId, threadId = startedKey.threadId),
            )
            appModel.store.setActiveThread(startedKey)
            appModel.refreshThreadSnapshot(startedKey)
            val resolvedKey = appModel.ensureThreadLoaded(startedKey)
                ?: appModel.snapshot.value?.threads?.firstOrNull { it.key == startedKey }?.key
                ?: startedKey
            navigateToConversation(resolvedKey)
        }

        fun openDirectoryPicker(preferredServerId: String? = null) {
            val targetServerId = SessionLaunchSupport.defaultConnectedServerId(
                connectedServerIds = connectedServerOptions.map { it.id },
                activeThreadKey = snapshot?.activeThread,
                preferredServerId = preferredServerId,
            )
            if (targetServerId == null) {
                showDiscovery = true
            } else {
                directoryPickerServerId = targetServerId
            }
        }

        val interceptSystemBack =
            showDiscovery ||
                showSettings ||
                showAccountForServer != null ||
                directoryPickerServerId != null ||
                showProjectPicker ||
                navStack.size > 1

        BackHandler(enabled = interceptSystemBack) {
            when {
                showAccountForServer != null -> showAccountForServer = null
                directoryPickerServerId != null -> directoryPickerServerId = null
                showProjectPicker -> showProjectPicker = false
                showSettings -> showSettings = false
                showDiscovery -> {
                    showDiscovery = false
                    networkDiscovery.stopScanning()
                }
                navStack.size > 1 -> navStack = navStack.dropLast(1)
            }
        }

        // Auto-navigate to active thread when it changes.
        // Home-composer sends don't call setActiveThread, so this only triggers
        // for real "open a thread" actions (e.g. voice session handoff).
        LaunchedEffect(snapshot?.activeThread) {
            val activeKey = snapshot?.activeThread ?: return@LaunchedEffect
            val alreadyShowing = when (val route = currentRoute) {
                is Route.Conversation -> route.key == activeKey
                is Route.RealtimeVoice -> route.key == activeKey
                else -> false
            }
            if (!alreadyShowing) {
                navStack = listOf(Route.Home, Route.Conversation(activeKey))
            }
        }

        val rootModifier = if (currentRoute is Route.Conversation) {
            Modifier
                .fillMaxSize()
                .background(LitterTheme.background)
        } else {
            Modifier
                .fillMaxSize()
                .background(LitterTheme.background)
                .systemBarsPadding()
        }

        Box(modifier = rootModifier) {
            when (val route = currentRoute) {
                is Route.Home -> {
                    HomeDashboardScreen(
                        onOpenConversation = navigateToConversation,
                        onShowDiscovery = { showDiscovery = true },
                        onShowSettings = { showSettings = true },
                        onShowApps = { navigate(Route.Apps) },
                        onOpenProjectPicker = { showProjectPicker = true },
                        onOpenAccount = { serverId -> showAccountForServer = serverId },
                        selectedProject = selectedProject,
                        selectedServerId = selectedServerId,
                        onSelectServer = { server ->
                            // Tap again to clear the filter and show all.
                            if (selectedServerId == server.serverId) {
                                selectedServerId = null
                                selectedProject = null
                            } else {
                                selectedServerId = server.serverId
                            }
                        },
                        onThreadCreated = { key ->
                            SavedThreadsStore.add(
                                context,
                                PinnedThreadKey(serverId = key.serverId, threadId = key.threadId),
                            )
                        },
                        onStartVoice = {
                            scope.launch {
                                val launchState = appModel.launchState.snapshot.value
                                val threadKey = voiceController.preparePinnedLocalVoiceThread(
                                    appModel = appModel,
                                    cwd = launchState.currentCwd.ifBlank { "~" },
                                    model = launchState.selectedModel.ifBlank { null },
                                )
                                if (threadKey != null) {
                                    navigate(Route.RealtimeVoice(threadKey))
                                }
                            }
                        },
                        onOpenSavedApp = { appId -> navigate(Route.SavedApp(appId)) },
                    )
                }

                is Route.Sessions -> {
                    com.litter.android.ui.sessions.SessionsScreen(
                        serverId = route.serverId,
                        title = route.title,
                        sessionsUiState = sessionsUiState,
                        onOpenConversation = navigateToConversation,
                        onNewSession = { openDirectoryPicker(route.serverId) },
                        onBack = navigateBack,
                        onInfo = { navigate(Route.ServerInfo(route.serverId)) },
                    )
                }

                is Route.Conversation -> {
                    ConversationScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onInfo = { navigate(Route.ConversationInfo(route.key)) },
                        onShowDirectoryPicker = { openDirectoryPicker(route.key.serverId) },
                        onOpenSavedApp = { appId -> navigate(Route.SavedApp(appId)) },
                    )
                }

                is Route.ConversationInfo -> {
                    ConversationInfoScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onChangeWallpaper = { navigate(Route.WallpaperSelection(route.key)) },
                    )
                }

                is Route.WallpaperSelection -> {
                    com.litter.android.ui.settings.WallpaperSelectionScreen(
                        threadKey = route.key,
                        onBack = {
                            WallpaperManager.clearPendingWallpaper()
                            navigateBack()
                        },
                        onApplied = {
                            navStack = navStack.filter {
                                it !is Route.WallpaperSelection &&
                                    it !is Route.WallpaperAdjust
                            }
                        },
                    )
                }

                is Route.WallpaperAdjust -> {
                    com.litter.android.ui.settings.WallpaperAdjustScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                        onApplied = {
                            // Pop back to conversation info (keep it on the stack)
                            navStack = navStack.filter {
                                it !is Route.WallpaperSelection &&
                                    it !is Route.WallpaperAdjust
                            }
                        },
                    )
                }

                is Route.ServerInfo -> {
                    ConversationInfoScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = navigateBack,
                        onChangeWallpaper = { navigate(Route.ServerWallpaperSelection(route.serverId)) },
                    )
                }

                is Route.ServerWallpaperSelection -> {
                    com.litter.android.ui.settings.WallpaperSelectionScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = {
                            WallpaperManager.clearPendingWallpaper()
                            navigateBack()
                        },
                        onApplied = {
                            navStack = navStack.filter {
                                it !is Route.ServerWallpaperSelection &&
                                    it !is Route.ServerWallpaperAdjust
                            }
                        },
                    )
                }

                is Route.ServerWallpaperAdjust -> {
                    com.litter.android.ui.settings.WallpaperAdjustScreen(
                        threadKey = null,
                        serverId = route.serverId,
                        onBack = navigateBack,
                        onApplied = {
                            navStack = navStack.filter {
                                it !is Route.ServerWallpaperSelection &&
                                    it !is Route.ServerWallpaperAdjust
                            }
                        },
                    )
                }

                is Route.RealtimeVoice -> {
                    com.litter.android.ui.voice.RealtimeVoiceScreen(
                        threadKey = route.key,
                        onBack = navigateBack,
                    )
                }

                is Route.Apps -> {
                    com.litter.android.ui.apps.AppsListScreen(
                        onBack = navigateBack,
                        onOpenApp = { appId -> navigate(Route.SavedApp(appId)) },
                    )
                }

                is Route.SavedApp -> {
                    com.litter.android.ui.apps.SavedAppScreen(
                        appId = route.appId,
                        onBack = navigateBack,
                        onOpenConversation = { key -> navigate(Route.Conversation(key)) },
                    )
                }
            }

            val pet = PetOverlayController.selectedPet
            if (pet != null && PetOverlayController.shouldShowInAppOverlay(context)) {
                PetOverlayView(
                    pet = pet,
                    state = PetOverlayController.avatarState(snapshot),
                    message = PetOverlayController.avatarMessage(snapshot),
                    reducedMotion = context.animationsDisabled(),
                    modifier = Modifier.align(Alignment.TopStart),
                )
            }

            // Global approval overlay
            val approvals = snapshot?.pendingApprovals.orEmpty()
            val userInputs = snapshot?.pendingUserInputs.orEmpty()
            if (approvals.isNotEmpty() || userInputs.isNotEmpty()) {
                ApprovalOverlay(
                    approvals = approvals,
                    userInputs = userInputs,
                    appStore = appModel.store,
                )
            }
        }

        // Discovery bottom sheet
        if (showDiscovery) {
            val discoveredServers by networkDiscovery.servers.collectAsState()
            val isScanning by networkDiscovery.isScanning.collectAsState()
            val scanProgress by networkDiscovery.scanProgress.collectAsState()
            val scanProgressLabel by networkDiscovery.scanProgressLabel.collectAsState()
            val context = LocalContext.current

            // Start scanning when discovery sheet opens
            LaunchedEffect(showDiscovery) {
                networkDiscovery.startScanning(context)
            }

            ModalBottomSheet(
                onDismissRequest = {
                    showDiscovery = false
                    networkDiscovery.stopScanning()
                },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                DiscoveryScreen(
                    discoveredServers = discoveredServers,
                    isScanning = isScanning,
                    scanProgress = scanProgress,
                    scanProgressLabel = scanProgressLabel,
                    onRefresh = { networkDiscovery.startScanning(context) },
                    onDismiss = {
                        showDiscovery = false
                        networkDiscovery.stopScanning()
                    },
                )
            }
        }

        // Settings bottom sheet
        if (showSettings) {
            ModalBottomSheet(
                onDismissRequest = { showSettings = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                SettingsSheet(
                    onDismiss = {
                        showSettings = false
                        settingsStartDestination = SettingsStartDestination.TopLevel
                    },
                    onOpenAccount = { serverId ->
                        showSettings = false
                        settingsStartDestination = SettingsStartDestination.TopLevel
                        showAccountForServer = serverId
                    },
                    initialSubScreen = settingsStartDestination,
                    onOpenApps = {
                        showSettings = false
                        settingsStartDestination = SettingsStartDestination.TopLevel
                        navigate(Route.Apps)
                    },
                )
            }
        }

        if (directoryPickerServerId != null) {
            ModalBottomSheet(
                onDismissRequest = {
                    directoryPickerServerId = null
                    directoryPickerForProject = false
                },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                DirectoryPickerSheet(
                    servers = connectedServerOptions,
                    initialServerId = directoryPickerServerId!!,
                    onSelect = { serverId, cwd ->
                        directoryPickerServerId = null
                        val forProject = directoryPickerForProject
                        directoryPickerForProject = false
                        if (forProject) {
                            selectedServerId = serverId
                            val id = projectIdFor(serverId, cwd)
                            val match = projects.firstOrNull { it.id == id }
                            selectedProject = match ?: AppProject(
                                id = id,
                                serverId = serverId,
                                cwd = cwd,
                                lastUsedAtMs = null,
                            )
                            RecentDirectoryStore(context).record(serverId, cwd)
                        } else {
                            scope.launch {
                                runCatching { startNewSession(serverId, cwd) }
                                    .onFailure { error ->
                                        if (error is LocalAccountLoginRequiredException) {
                                            showAccountForServer = error.serverId
                                        }
                                    }
                            }
                        }
                    },
                    onDismiss = {
                        directoryPickerServerId = null
                        directoryPickerForProject = false
                    },
                )
            }
        }

        if (showProjectPicker) {
            ModalBottomSheet(
                onDismissRequest = { showProjectPicker = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                val serverNames = remember(snapshot) {
                    snapshot?.servers?.associate { it.serverId to it.displayName } ?: emptyMap()
                }
                val isLocalById = remember(snapshot) {
                    snapshot?.servers?.associate { it.serverId to it.isLocal } ?: emptyMap()
                }
                ProjectPickerSheet(
                    projects = projects,
                    serverNamesById = serverNames,
                    isLocalById = isLocalById,
                    onSelect = { project ->
                        selectedServerId = project.serverId
                        selectedProject = project
                    },
                    onCreateNew = {
                        showProjectPicker = false
                        val targetServerId = selectedServerId
                            ?: SessionLaunchSupport.defaultConnectedServerId(
                                connectedServerIds = connectedServerOptions.map { it.id },
                                activeThreadKey = snapshot?.activeThread,
                                preferredServerId = null,
                            )
                        if (targetServerId != null) {
                            directoryPickerForProject = true
                            directoryPickerServerId = targetServerId
                        } else {
                            showDiscovery = true
                        }
                    },
                    onDismiss = { showProjectPicker = false },
                )
            }
        }

        // Account bottom sheet
        showAccountForServer?.let { serverId ->
            ModalBottomSheet(
                onDismissRequest = { showAccountForServer = null },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = LitterTheme.background,
            ) {
                AccountSheet(
                    serverId = serverId,
                    onDismiss = { showAccountForServer = null },
                )
            }
        }
    }
}

private fun android.content.Context.animationsDisabled(): Boolean {
    val scale = runCatching {
        Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE)
    }.getOrDefault(1f)
    return scale == 0f
}
