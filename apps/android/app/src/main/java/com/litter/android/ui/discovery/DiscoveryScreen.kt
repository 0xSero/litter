package com.litter.android.ui.discovery

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.DeveloperBoard
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedSshCredential
import com.litter.android.state.ChatGPTOAuth
import com.litter.android.state.SshAuthMethod
import com.litter.android.state.SshCredentialStore
import com.litter.android.state.isConnected
import com.litter.android.auth.ChatGPTOAuthActivity
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.common.AgentIconView
import com.litter.android.ui.common.BetaBadge
import com.litter.android.ui.common.isBeta
import com.litter.android.util.LLog
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.codex_mobile_client.AgentAvailabilityStatus
import com.litter.android.ui.common.AgentRuntimeKind
import com.litter.android.ui.common.metadata
import com.litter.android.ui.common.runtimeLabel
import com.litter.android.ui.common.runtimeSortIndex
import uniffi.codex_mobile_client.AppSshSessionResult
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.RemoteAgentAvailability
import uniffi.codex_mobile_client.AppSlingshotEnvironment
import uniffi.codex_mobile_client.SshBridgeTransport

private data class SshBridgeAgentContext(
    val server: SavedServer,
    val sessionId: String,
    val host: String,
    val availability: List<RemoteAgentAvailability>,
    val credential: SavedSshCredential,
)

private const val SLINGSHOT_BASE_URL = "https://chatgpt.com/backend-api"

/**
 * Server connection screen.
 */
@Composable
fun DiscoveryScreen(
    onDismiss: () -> Unit,
) {
    val logTag = "DiscoveryScreen"
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sshCredentialStore = remember(context) { SshCredentialStore(context.applicationContext) }

    var showManualEntry by remember { mutableStateOf(false) }
    var showAlleycatSheet by remember { mutableStateOf(false) }
    var alleycatPairingMode by remember { mutableStateOf(AlleycatPairingMode.Kittylitter) }
    var showSlingshotComputers by remember { mutableStateOf(false) }
    var slingshotEnvironments by remember { mutableStateOf<List<AppSlingshotEnvironment>>(emptyList()) }
    var slingshotIsLoading by remember { mutableStateOf(false) }
    var slingshotError by remember { mutableStateOf<String?>(null) }
    var pendingManualSshServer by remember { mutableStateOf<SavedServer?>(null) }
    var sshServer by remember { mutableStateOf<SavedServer?>(null) }
    var sshAgentContext by remember { mutableStateOf<SshBridgeAgentContext?>(null) }
    var pendingAutoNavigateServerId by remember { mutableStateOf<String?>(null) }
    var pendingSlingshotEnvironment by remember { mutableStateOf<AppSlingshotEnvironment?>(null) }
    var authorizedSlingshotConnect by remember { mutableStateOf<Pair<AppSlingshotEnvironment, String>?>(null) }
    var wakingServerId by remember { mutableStateOf<String?>(null) }
    var connectError by remember { mutableStateOf<String?>(null) }
    val slingshotStepUpLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val environment = pendingSlingshotEnvironment
        pendingSlingshotEnvironment = null
        if (environment == null) {
            return@rememberLauncherForActivityResult
        }
        if (result.resultCode != android.app.Activity.RESULT_OK) {
            connectError = result.data?.getStringExtra(ChatGPTOAuthActivity.EXTRA_ERROR)
                ?: "Remote-control authorization was cancelled."
            return@rememberLauncherForActivityResult
        }
        val stepUpToken = ChatGPTOAuthActivity.parseRemoteControlStepUpToken(result.data)
        if (stepUpToken == null) {
            connectError = "Remote-control authorization returned incomplete credentials."
            return@rememberLauncherForActivityResult
        }
        authorizedSlingshotConnect = environment to stepUpToken
    }

    LaunchedEffect(showManualEntry, pendingManualSshServer) {
        if (!showManualEntry && pendingManualSshServer != null) {
            sshServer = pendingManualSshServer
            pendingManualSshServer = null
        }
    }

    LaunchedEffect(snapshot, pendingAutoNavigateServerId) {
        val pendingServerId = pendingAutoNavigateServerId ?: return@LaunchedEffect
        val serverSnapshot = snapshot?.servers?.firstOrNull { it.serverId == pendingServerId } ?: return@LaunchedEffect
        if (serverSnapshot.isConnected) {
            pendingAutoNavigateServerId = null
            onDismiss()
        } else if (serverSnapshot.health == AppServerHealth.DISCONNECTED) {
            serverSnapshot.connectionProgress?.terminalMessage?.let { message ->
                pendingAutoNavigateServerId = null
                connectError = message
            }
        }
    }

    suspend fun loadSlingshotEnvironments() {
        if (slingshotIsLoading) {
            return
        }
        slingshotIsLoading = true
        slingshotError = null
        try {
            val tokens = loadSlingshotTokens(context)
            slingshotEnvironments = appModel.serverBridge
                .listSlingshotEnvironments(
                    baseUrl = SLINGSHOT_BASE_URL,
                    accessToken = tokens.accessToken,
                    accountId = tokens.accountId,
                )
                .sortedWith(
                    compareByDescending<AppSlingshotEnvironment> { it.online }
                        .thenBy { it.busy }
                        .thenBy { it.displayName.lowercase() },
                )
        } catch (e: Exception) {
            LLog.e(logTag, "slingshot environment load failed", e)
            slingshotError = e.message ?: "Unable to load connected computers."
        } finally {
            slingshotIsLoading = false
        }
    }

    suspend fun connectSlingshotEnvironmentOrThrow(environment: AppSlingshotEnvironment, stepUpToken: String) {
        if (!environment.online) {
            throw IllegalStateException("${environment.displayName} is offline.")
        }
        val server = slingshotSavedServer(environment)
        val tokens = loadSlingshotTokens(context)
        appModel.serverBridge.connectRemoteSlingshotUrlServer(
            server.id,
            server.name,
            environment.connectionUrl,
            tokens.accessToken,
            tokens.accountId,
            stepUpToken,
        )
        SavedServerStore.remember(context, server.normalizedForPersistence())
        appModel.refreshSnapshot()
    }

    fun finishSuccessfulSlingshotConnect() {
        showSlingshotComputers = false
        onDismiss()
    }

    fun startSlingshotConnect(environment: AppSlingshotEnvironment) {
        if (!environment.online) {
            connectError = "${environment.displayName} is offline."
            return
        }
        scope.launch {
            var needsAuthorization = false
            try {
                connectSlingshotEnvironmentOrThrow(environment, "")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (!ChatGPTOAuth.isRemoteControlAuthorizationRequired(e)) {
                    LLog.e(
                        logTag,
                        "slingshot cached connect failed",
                        e,
                        fields = mapOf("environmentId" to environment.id),
                    )
                    connectError = e.message ?: "Unable to connect to this computer."
                    return@launch
                }
                needsAuthorization = true
            }

            if (!needsAuthorization) {
                finishSuccessfulSlingshotConnect()
                return@launch
            }

            try {
                pendingSlingshotEnvironment = environment
                slingshotStepUpLauncher.launch(
                    ChatGPTOAuthActivity.createIntent(
                        context,
                        ChatGPTOAuth.createRemoteControlEnrollmentAttempt(),
                    ),
                )
            } catch (e: Exception) {
                pendingSlingshotEnvironment = null
                connectError = e.localizedMessage ?: e.message ?: "Unable to authorize remote control."
            }
        }
    }

    suspend fun connectSlingshotEnvironment(environment: AppSlingshotEnvironment, stepUpToken: String) {
        try {
            connectSlingshotEnvironmentOrThrow(environment, stepUpToken)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            LLog.e(
                logTag,
                "slingshot connect failed",
                e,
                fields = mapOf("environmentId" to environment.id),
            )
            connectError = e.message ?: "Unable to connect to this computer."
            return
        }
        finishSuccessfulSlingshotConnect()
    }

    LaunchedEffect(authorizedSlingshotConnect) {
        val pending = authorizedSlingshotConnect ?: return@LaunchedEffect
        authorizedSlingshotConnect = null
        connectSlingshotEnvironment(pending.first, pending.second)
    }

    suspend fun openSshSession(server: SavedServer, credential: SavedSshCredential): AppSshSessionResult =
        when (credential.method) {
            SshAuthMethod.PASSWORD -> appModel.ssh.sshOpenSession(
                host = server.hostname,
                port = server.resolvedSshPort.toUShort(),
                username = credential.username,
                password = credential.password,
                privateKeyPem = null,
                passphrase = null,
                unlockMacosKeychain = credential.unlockMacosKeychain,
                acceptUnknownHost = true,
            )

            SshAuthMethod.KEY -> appModel.ssh.sshOpenSession(
                host = server.hostname,
                port = server.resolvedSshPort.toUShort(),
                username = credential.username,
                password = null,
                privateKeyPem = credential.privateKey,
                passphrase = credential.passphrase,
                unlockMacosKeychain = false,
                acceptUnknownHost = true,
            )
        }

    suspend fun startGuidedSshConnect(server: SavedServer, credential: SavedSshCredential) {
        when (credential.method) {
            SshAuthMethod.PASSWORD -> {
                appModel.serverBridge.startRemoteOverSshConnect(
                    serverId = server.id,
                    displayName = server.name,
                    host = server.hostname,
                    port = server.resolvedSshPort.toUShort(),
                    username = credential.username,
                    password = credential.password,
                    privateKeyPem = null,
                    passphrase = null,
                    unlockMacosKeychain = credential.unlockMacosKeychain,
                    acceptUnknownHost = true,
                    workingDir = null,
                )
            }

            SshAuthMethod.KEY -> {
                appModel.serverBridge.startRemoteOverSshConnect(
                    serverId = server.id,
                    displayName = server.name,
                    host = server.hostname,
                    port = server.resolvedSshPort.toUShort(),
                    username = credential.username,
                    password = null,
                    privateKeyPem = credential.privateKey,
                    passphrase = credential.passphrase,
                    unlockMacosKeychain = false,
                    acceptUnknownHost = true,
                    workingDir = null,
                )
            }
        }
    }

    suspend fun prepareServerForSelection(entry: SavedServer): SavedServer {
        if (entry.websocketURL != null) {
            return entry
        }

        wakingServerId = entry.id
        try {
            return when (
                val probeResult = probeManualServer(
                    host = entry.hostname,
                    preferredCodexPort = entry.directCodexPort ?: entry.availableDirectCodexPorts.firstOrNull(),
                    timeoutMillis = 12_000L,
                )
            ) {
                is ManualServerProbeResult.Codex -> entry.copy(
                    port = probeResult.port,
                    codexPorts = listOf(probeResult.port) + entry.availableDirectCodexPorts.filter { it != probeResult.port },
                    hasCodexServer = true,
                    preferredConnectionMode = entry.preferredConnectionMode,
                    preferredCodexPort = probeResult.port,
                ).normalizedForPersistence()

                is ManualServerProbeResult.Ssh -> entry.copy(
                    port = probeResult.port,
                    sshPort = probeResult.port,
                    hasCodexServer = false,
                    preferredConnectionMode = "ssh",
                    preferredCodexPort = null,
                ).normalizedForPersistence()

                ManualServerProbeResult.None -> entry
            }
        } finally {
            wakingServerId = null
        }
    }

    suspend fun connectPreparedRemoteUrl(prepared: SavedServer) {
        val websocketURL = prepared.websocketURL ?: return
        appModel.serverBridge.connectRemoteUrlServer(
            prepared.id,
            prepared.name,
            websocketURL,
        )
    }

    suspend fun connectSelectedServer(entry: SavedServer) {
        if (wakingServerId != null && wakingServerId != entry.id) {
            return
        }

        try {
            val connected = connectedSnapshot(entry, snapshot?.servers ?: emptyList())
            if (connected?.isConnected == true) {
                LLog.t(logTag, "server already connected", fields = mapOf("serverId" to entry.id))
                onDismiss()
                return
            }

            val prepared = prepareServerForSelection(entry)
            when {
                prepared.websocketURL != null -> {
                    connectPreparedRemoteUrl(prepared)
                    SavedServerStore.remember(context, prepared.normalizedForPersistence())
                    appModel.refreshSnapshot()
                    onDismiss()
                }

                prepared.prefersSshConnection || (!prepared.hasCodexServer && prepared.canConnectViaSsh) -> {
                    sshServer = prepared.withPreferredConnection("ssh")
                }

                else -> {
                    val directCodexPort = checkNotNull(prepared.directCodexPort)
                    appModel.serverBridge.connectRemoteServer(
                        prepared.id,
                        prepared.name,
                        prepared.hostname,
                        directCodexPort.toUShort(),
                    )
                    SavedServerStore.remember(
                        context,
                        prepared.withPreferredConnection("directCodex", directCodexPort),
                    )
                    appModel.refreshSnapshot()
                    onDismiss()
                }
            }
        } catch (e: Exception) {
            LLog.e(
                logTag,
                "server connect failed",
                e,
                fields = mapOf(
                    "serverId" to entry.id,
                    "host" to entry.hostname,
                    "preferredConnectionMode" to entry.preferredConnectionMode,
                ),
            )
            connectError = e.message ?: "Unable to connect."
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                text = "Add Server",
                color = LitterTheme.textPrimary,
                fontSize = 18.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
        }

        Spacer(Modifier.height(8.dp))

        Text(
            text = "Pick how you want to connect.",
            color = LitterTheme.textSecondary,
            fontSize = 12.sp,
        )

        Spacer(Modifier.height(14.dp))

        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ChooserCard(
                title = "Pair with kittylitter",
                subtitle = "Run npx kittylitter on the host, then scan the QR code it prints.",
                badge = "RECOMMENDED",
                icon = Icons.Default.QrCodeScanner,
                supportedAgents = KittylitterAgents,
                isRecommended = true,
                onClick = {
                    alleycatPairingMode = AlleycatPairingMode.Kittylitter
                    showAlleycatSheet = true
                },
            )

            ChooserCard(
                title = "Local Studio",
                subtitle = "Scan the QR from Local Studio Profile, or paste Copy connection JSON.",
                badge = null,
                icon = Icons.Outlined.DeveloperBoard,
                supportedAgents = listOf("local-studio"),
                isRecommended = false,
                onClick = {
                    alleycatPairingMode = AlleycatPairingMode.LocalStudio
                    showAlleycatSheet = true
                },
            )

            ChooserCard(
                title = "Connected Computer",
                subtitle = "Connect to a computer already signed in and running Codex for this ChatGPT account.",
                badge = null,
                icon = Icons.Outlined.DesktopWindows,
                supportedAgents = CodexOnlyAgents,
                isRecommended = false,
                onClick = { showSlingshotComputers = true },
            )

            ChooserCard(
                title = "SSH or Codex URL",
                subtitle = "Connect over SSH or paste a ws:// codex URL.",
                badge = null,
                icon = Icons.Outlined.Terminal,
                supportedAgents = CodexOnlyAgents,
                isRecommended = false,
                onClick = { showManualEntry = true },
            )
        }
    }

    if (showManualEntry) {
        ManualEntryDialog(
            onDismiss = { showManualEntry = false },
            onSubmit = { action ->
                when (action) {
                    is ManualEntryAction.Connect -> {
                        showManualEntry = false
                        scope.launch { connectSelectedServer(action.server) }
                    }

                    is ManualEntryAction.ContinueWithSsh -> {
                        pendingManualSshServer = action.server
                        showManualEntry = false
                    }
                }
            },
        )
    }

    if (showSlingshotComputers) {
        ConnectedComputersDialog(
            environments = slingshotEnvironments,
            loading = slingshotIsLoading,
            error = slingshotError,
            onDismiss = { showSlingshotComputers = false },
            onRefresh = { scope.launch { loadSlingshotEnvironments() } },
            onSelect = { environment ->
                startSlingshotConnect(environment)
            },
        )
        LaunchedEffect(Unit) {
            if (slingshotEnvironments.isEmpty() && !slingshotIsLoading) {
                loadSlingshotEnvironments()
            }
        }
    }

    sshServer?.let { server ->
        SSHLoginDialog(
            server = server,
            initialCredential = sshCredentialStore.load(server.hostname, server.resolvedSshPort),
            onDismiss = { sshServer = null },
            onConnect = { credential, rememberCredentials ->
                try {
                    LLog.t(
                        logTag,
                        "starting SSH connect",
                        fields = mapOf(
                            "serverId" to server.id,
                            "host" to server.hostname,
                            "sshPort" to server.resolvedSshPort,
                            "authMethod" to credential.method.name,
                            "os" to server.os,
                        ),
                    )
                    if (rememberCredentials) {
                        sshCredentialStore.save(server.hostname, server.resolvedSshPort, credential)
                    } else {
                        sshCredentialStore.delete(server.hostname, server.resolvedSshPort)
                    }

                    val session = openSshSession(server, credential)
                    val availability = appModel.ssh.sshProbeRemoteAgents(session.sessionId)
                    val bridgeAgents = availableSshBridgeKinds(availability)
                    if (bridgeAgents.isNotEmpty()) {
                        sshAgentContext = SshBridgeAgentContext(
                            server = server,
                            sessionId = session.sessionId,
                            host = session.normalizedHost,
                            availability = availability,
                            credential = credential,
                        )
                        sshServer = null
                        null
                    } else {
                        appModel.ssh.sshClose(session.sessionId)
                        LLog.t(
                            logTag,
                            "no SSH bridge agents available; falling back to Codex SSH",
                            fields = mapOf(
                                "serverId" to server.id,
                                "host" to server.hostname,
                            ),
                        )
                        startGuidedSshConnect(server, credential)
                        SavedServerStore.remember(
                            context,
                            server.withPreferredConnection("ssh"),
                        )
                        appModel.refreshSnapshot()
                        pendingAutoNavigateServerId = server.id
                        LLog.t(
                            logTag,
                            "guided SSH bootstrap started",
                            fields = mapOf(
                                "serverId" to server.id,
                                "host" to server.hostname,
                                "sshPort" to server.resolvedSshPort,
                            ),
                        )
                        sshServer = null
                        null
                    }
                } catch (e: Exception) {
                    LLog.e(
                        logTag,
                        "guided SSH connect failed",
                        e,
                        fields = mapOf(
                            "serverId" to server.id,
                            "host" to server.hostname,
                            "sshPort" to server.resolvedSshPort,
                            "authMethod" to credential.method.name,
                            "os" to server.os,
                        ),
                    )
                    e.message ?: "Unable to connect over SSH."
                }
            },
        )
    }

    sshAgentContext?.let { agentContext ->
        SSHAgentPickerDialog(
            context = agentContext,
            onDismiss = {
                scope.launch {
                    runCatching { appModel.ssh.sshClose(agentContext.sessionId) }
                    sshAgentContext = null
                }
            },
            onUseCodex = {
                scope.launch {
                    runCatching { appModel.ssh.sshClose(agentContext.sessionId) }
                    startGuidedSshConnect(agentContext.server, agentContext.credential)
                    SavedServerStore.remember(
                        context,
                        agentContext.server.withPreferredConnection("ssh"),
                    )
                    appModel.refreshSnapshot()
                    pendingAutoNavigateServerId = agentContext.server.id
                    sshAgentContext = null
                }
            },
            onConnect = { selectedKinds ->
                try {
                    val result = appModel.ssh.sshConnectBridgeSession(
                        sessionId = agentContext.sessionId,
                        serverId = "ssh-bridge:${agentContext.host}",
                        displayName = agentContext.server.name,
                        host = agentContext.host,
                        stateRoot = sshBridgeStateRoot(context, agentContext.host),
                        runtimeKinds = selectedKinds,
                        transport = SshBridgeTransport.EPHEMERAL,
                    )
                    val server = agentContext.server.copy(
                        id = result.serverId,
                        hostname = agentContext.host,
                        port = 0,
                        codexPorts = emptyList(),
                        source = "ssh",
                        hasCodexServer = true,
                        preferredConnectionMode = "ssh",
                        alleycatAgentName = selectedKinds.joinToString(","),
                        alleycatAgentWire = "ssh-bridge",
                    )
                    appModel.sshSessionStore.record(result.serverId, agentContext.sessionId)
                    SavedServerStore.remember(context, server)
                    appModel.refreshSnapshot()
                    pendingAutoNavigateServerId = result.serverId
                    sshAgentContext = null
                    null
                } catch (e: Exception) {
                    LLog.e(
                        logTag,
                        "SSH bridge connect failed",
                        e,
                        fields = mapOf(
                            "serverId" to agentContext.server.id,
                            "host" to agentContext.host,
                        ),
                    )
                    e.message ?: "Unable to connect SSH bridge agents."
                }
            },
        )
    }

    connectError?.let { message ->
        AlertDialog(
            onDismissRequest = { connectError = null },
            title = { Text("Connection Failed") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { connectError = null }) {
                    Text("OK")
                }
            },
        )
    }

    if (showAlleycatSheet) {
        @OptIn(ExperimentalMaterial3Api::class)
        ModalBottomSheet(
            onDismissRequest = { showAlleycatSheet = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            AlleycatAddServerSheet(
                onDismiss = { showAlleycatSheet = false },
                startScanningOnAppear = true,
                pairingMode = alleycatPairingMode,
                onConnected = { result ->
                    showAlleycatSheet = false
                    scope.launch {
                        SavedServerStore.rememberAlleycat(
                            context = context,
                            serverId = result.serverId,
                            displayName = result.displayName,
                            nodeId = result.nodeId,
                            relay = result.params.relay,
                            agentName = result.agentName,
                            agentWire = alleycatWireStorageValue(result.agentWire),
                        )
                        appModel.refreshSnapshot()
                        pendingAutoNavigateServerId = result.serverId
                    }
                },
            )
        }
    }
}

/**
 * Canonical agent list shown on the kittylitter chooser card. Mirrors
 * the splash carousel order so cold-start branding stays consistent.
 * New agents added in the alleycat manifest still surface on connected
 * hosts via the real metadata store; this list only seeds the
 * pre-pair preview.
 */
private val KittylitterAgents: List<AgentRuntimeKind> = listOf(
    "codex",
    "pi",
    "amp",
    "opencode",
    "claude",
    "droid",
    "hermes",
    "devin",
    "grok",
)

private val CodexOnlyAgents: List<AgentRuntimeKind> = listOf("codex")

@Composable
private fun ChooserCard(
    title: String,
    subtitle: String,
    badge: String?,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    supportedAgents: List<AgentRuntimeKind>,
    isRecommended: Boolean,
    onClick: () -> Unit,
) {
    val borderColor = if (isRecommended) {
        LitterTheme.accent.copy(alpha = 0.45f)
    } else {
        LitterTheme.accent.copy(alpha = 0.18f)
    }
    val backgroundColor = if (isRecommended) {
        LitterTheme.surface.copy(alpha = 0.85f)
    } else {
        LitterTheme.surface.copy(alpha = 0.6f)
    }
    val iconBubble = LitterTheme.accent.copy(alpha = if (isRecommended) 0.16f else 0.10f)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(backgroundColor, RoundedCornerShape(14.dp))
            .border(
                width = if (isRecommended) 1.dp else 0.8.dp,
                color = borderColor,
                shape = RoundedCornerShape(14.dp),
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Box(
                modifier = Modifier
                    .padding(top = 2.dp)
                    .size(36.dp)
                    .background(iconBubble, RoundedCornerShape(50)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = LitterTheme.accent,
                    modifier = Modifier.size(20.dp),
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = title,
                        color = LitterTheme.textPrimary,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (badge != null) {
                        Box(
                            modifier = Modifier
                                .background(
                                    LitterTheme.accent.copy(alpha = 0.14f),
                                    RoundedCornerShape(50),
                                )
                                .border(
                                    width = 0.6.dp,
                                    color = LitterTheme.accent.copy(alpha = 0.45f),
                                    shape = RoundedCornerShape(50),
                                )
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        ) {
                            Text(
                                text = badge,
                                color = LitterTheme.accent,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                                letterSpacing = 0.5.sp,
                            )
                        }
                    }
                }
                Text(
                    text = subtitle,
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = LitterTheme.textMuted,
                modifier = Modifier.padding(top = 10.dp),
            )
        }

        if (supportedAgents.isNotEmpty()) {
            SupportedAgentsStrip(supportedAgents)
        }
    }
}

@Composable
private fun SupportedAgentsStrip(agents: List<AgentRuntimeKind>) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text = "Works with",
            color = LitterTheme.textMuted,
            fontSize = 10.sp,
            letterSpacing = 0.4.sp,
            maxLines = 1,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            agents.forEach { agent ->
                com.litter.android.ui.common.AgentIconView(
                    kind = agent,
                    sizeDp = 18,
                )
            }
        }
    }
}

@Composable
private fun ConnectedComputersDialog(
    environments: List<AppSlingshotEnvironment>,
    loading: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onRefresh: () -> Unit,
    onSelect: (AppSlingshotEnvironment) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Connected Computers") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = "These computers come from ChatGPT using your signed-in account. Start Codex on the computer first so it appears here.",
                    color = LitterTheme.textSecondary,
                    fontSize = 12.sp,
                )
                when {
                    loading && environments.isEmpty() -> {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                                color = LitterTheme.accent,
                            )
                            Text(
                                text = "Loading connected computers...",
                                color = LitterTheme.textSecondary,
                                fontSize = 12.sp,
                            )
                        }
                    }

                    error != null -> {
                        Text(
                            text = error,
                            color = LitterTheme.danger,
                            fontSize = 12.sp,
                        )
                    }

                    environments.isEmpty() -> {
                        Text(
                            text = "No connected computers were found for this account.",
                            color = LitterTheme.textSecondary,
                            fontSize = 12.sp,
                        )
                    }

                    else -> {
                        if (loading) {
                            LinearProgressIndicator(
                                modifier = Modifier.fillMaxWidth(),
                                color = LitterTheme.accent,
                                trackColor = LitterTheme.border,
                            )
                        }
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.height(340.dp),
                        ) {
                            items(environments, key = { it.id }) { environment ->
                                ConnectedComputerRow(
                                    environment = environment,
                                    onClick = { onSelect(environment) },
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onRefresh,
                enabled = !loading,
            ) {
                Text("Refresh")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

@Composable
private fun ConnectedComputerRow(
    environment: AppSlingshotEnvironment,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(enabled = environment.online, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Icon(
            imageVector = slingshotEnvironmentIcon(environment),
            contentDescription = null,
            tint = if (environment.online) LitterTheme.accent else LitterTheme.textMuted,
            modifier = Modifier.size(22.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = environment.displayName,
                color = if (environment.online) LitterTheme.textPrimary else LitterTheme.textSecondary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = slingshotEnvironmentSubtitle(environment),
                color = LitterTheme.textSecondary,
                fontSize = 11.sp,
            )
        }
        Text(
            text = slingshotEnvironmentStatus(environment),
            color = if (environment.online && !environment.busy) LitterTheme.accent else LitterTheme.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

private fun slingshotSavedServer(environment: AppSlingshotEnvironment): SavedServer =
    SavedServer(
        id = "slingshot-${environment.id}",
        name = environment.displayName,
        hostname = environment.id,
        port = 0,
        codexPorts = emptyList(),
        source = "manual",
        hasCodexServer = true,
        preferredConnectionMode = "directCodex",
        websocketURL = environment.connectionUrl,
        os = environment.operatingSystem,
        rememberedByUser = true,
    )

private fun slingshotEnvironmentSubtitle(environment: AppSlingshotEnvironment): String {
    val parts = buildList {
        environment.hostName?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
        listOfNotNull(
            environment.operatingSystem.trim().takeIf { it.isNotEmpty() },
            environment.architecture?.trim()?.takeIf { it.isNotEmpty() },
        ).joinToString(" ").takeIf { it.isNotEmpty() }?.let(::add)
        environment.appServerVersion?.trim()?.takeIf { it.isNotEmpty() }?.let { add("Codex $it") }
    }
    return parts.ifEmpty { listOf(environment.id) }.joinToString(" - ")
}

private fun slingshotEnvironmentStatus(environment: AppSlingshotEnvironment): String =
    when {
        !environment.online -> "offline"
        environment.busy -> "busy"
        else -> "online"
    }

private fun slingshotEnvironmentIcon(
    environment: AppSlingshotEnvironment,
): androidx.compose.ui.graphics.vector.ImageVector =
    when (environment.operatingSystem.lowercase()) {
        "linux" -> Icons.Outlined.Dns
        "windows" -> Icons.Outlined.DesktopWindows
        "macos", "darwin" -> Icons.Outlined.DesktopWindows
        else -> Icons.Outlined.Laptop
    }

@Composable
private fun ManualEntryDialog(
    onDismiss: () -> Unit,
    onSubmit: (ManualEntryAction) -> Unit,
) {
    var mode by remember { mutableStateOf(ManualConnectionMode.SSH) }
    var codexUrl by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    var sshPort by remember { mutableStateOf("22") }
    var wakeMac by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Server") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = mode == ManualConnectionMode.CODEX,
                        onClick = { mode = ManualConnectionMode.CODEX },
                        label = { Text(ManualConnectionMode.CODEX.label) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent.copy(alpha = 0.18f),
                            selectedLabelColor = LitterTheme.textPrimary,
                        ),
                    )
                    FilterChip(
                        selected = mode == ManualConnectionMode.SSH,
                        onClick = { mode = ManualConnectionMode.SSH },
                        label = { Text(ManualConnectionMode.SSH.label) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent.copy(alpha = 0.18f),
                            selectedLabelColor = LitterTheme.textPrimary,
                        ),
                    )
                }

                when (mode) {
                    ManualConnectionMode.CODEX -> {
                        OutlinedTextField(
                            value = codexUrl,
                            onValueChange = {
                                codexUrl = it
                                errorMessage = null
                            },
                            label = { Text("Codex URL") },
                            placeholder = { Text("ws://host:8390 or host:8390") },
                            singleLine = true,
                        )
                        Text(
                            text = "Prefer the SSH flow — it binds 127.0.0.1 on the remote and forwards the port. " +
                                "If you run manually, bind loopback and tunnel yourself: " +
                                "codex app-server --listen ws://127.0.0.1:8390",
                            color = LitterTheme.textMuted,
                            fontSize = 11.sp,
                        )
                    }

                    ManualConnectionMode.SSH -> {
                        OutlinedTextField(
                            value = host,
                            onValueChange = {
                                host = it
                                errorMessage = null
                            },
                            label = { Text("SSH host") },
                            placeholder = { Text("hostname or IP") },
                            singleLine = true,
                        )
                        OutlinedTextField(
                            value = sshPort,
                            onValueChange = {
                                sshPort = it
                                errorMessage = null
                            },
                            label = { Text("SSH port") },
                            singleLine = true,
                        )
                        OutlinedTextField(
                            value = wakeMac,
                            onValueChange = {
                                wakeMac = it
                                errorMessage = null
                            },
                            label = { Text("Wake MAC (optional)") },
                            placeholder = { Text("aa:bb:cc:dd:ee:ff") },
                            singleLine = true,
                        )
                    }
                }

                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = LitterTheme.danger,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    errorMessage = when (val action = buildManualEntryAction(
                        mode,
                        codexUrl,
                        host,
                        sshPort,
                        wakeMac,
                    )) {
                        is ManualEntryBuild.Action -> {
                            onSubmit(action.action)
                            null
                        }

                        is ManualEntryBuild.Error -> action.message
                    }
                },
            ) {
                Text(mode.primaryButtonTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

@Composable
internal fun SSHLoginDialog(
    server: SavedServer,
    initialCredential: SavedSshCredential?,
    onDismiss: () -> Unit,
    onConnect: suspend (SavedSshCredential, Boolean) -> String?,
) {
    val scope = rememberCoroutineScope()
    var username by remember(server.id) { mutableStateOf(initialCredential?.username ?: "") }
    var authMethod by remember(server.id) { mutableStateOf(initialCredential?.method ?: SshAuthMethod.PASSWORD) }
    var password by remember(server.id) { mutableStateOf(initialCredential?.password ?: "") }
    var isPasswordVisible by remember(server.id) { mutableStateOf(false) }
    var privateKey by remember(server.id) { mutableStateOf(initialCredential?.privateKey ?: "") }
    var passphrase by remember(server.id) { mutableStateOf(initialCredential?.passphrase ?: "") }
    var rememberCredentials by remember(server.id) { mutableStateOf(initialCredential != null) }
    var unlockMacosKeychain by remember(server.id) {
        mutableStateOf(initialCredential?.unlockMacosKeychain ?: false)
    }
    var isConnecting by remember(server.id) { mutableStateOf(false) }
    var errorMessage by remember(server.id) { mutableStateOf<String?>(null) }
    val hostDisplay = if (server.resolvedSshPort == 22) {
        server.hostname
    } else {
        "${server.hostname}:${server.resolvedSshPort}"
    }

    AlertDialog(
        onDismissRequest = { if (!isConnecting) onDismiss() },
        title = { Text("SSH Login") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = "${server.name.ifBlank { server.hostname }}\n$hostDisplay",
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                )
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username") },
                    singleLine = true,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = { authMethod = SshAuthMethod.PASSWORD },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.PASSWORD) "Password *" else "Password")
                    }
                    TextButton(
                        onClick = {
                            authMethod = SshAuthMethod.KEY
                            isPasswordVisible = false
                        },
                        enabled = !isConnecting,
                    ) {
                        Text(if (authMethod == SshAuthMethod.KEY) "SSH Key *" else "SSH Key")
                    }
                }
                if (authMethod == SshAuthMethod.PASSWORD) {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Password") },
                        singleLine = true,
                        visualTransformation = if (isPasswordVisible) {
                            VisualTransformation.None
                        } else {
                            PasswordVisualTransformation()
                        },
                        trailingIcon = {
                            IconButton(
                                onClick = { isPasswordVisible = !isPasswordVisible },
                                enabled = !isConnecting,
                            ) {
                                Icon(
                                    imageVector = if (isPasswordVisible) {
                                        Icons.Filled.VisibilityOff
                                    } else {
                                        Icons.Filled.Visibility
                                    },
                                    contentDescription = if (isPasswordVisible) {
                                        "Hide password"
                                    } else {
                                        "Show password"
                                    },
                                )
                            }
                        },
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Switch(
                            checked = unlockMacosKeychain,
                            onCheckedChange = { unlockMacosKeychain = it },
                            enabled = !isConnecting,
                        )
                        Column {
                            Text(
                                text = "Unlock keychain (macOS)",
                                color = LitterTheme.textPrimary,
                                fontSize = 12.sp,
                            )
                            Text(
                                text = "Uses your SSH/login password during headless bootstrap. Required for tools like gh CLI auth.",
                                color = LitterTheme.textSecondary,
                                fontSize = 11.sp,
                            )
                        }
                    }
                } else {
                    OutlinedTextField(
                        value = privateKey,
                        onValueChange = { privateKey = it },
                        label = { Text("Private Key") },
                        minLines = 5,
                    )
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passphrase (optional)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Switch(
                        checked = rememberCredentials,
                        onCheckedChange = { rememberCredentials = it },
                        enabled = !isConnecting,
                    )
                    Text(
                        text = "Remember credentials on this device",
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                    )
                }
                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = LitterTheme.danger,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isConnecting && username.isNotBlank() && when (authMethod) {
                    SshAuthMethod.PASSWORD -> password.isNotBlank()
                    SshAuthMethod.KEY -> privateKey.isNotBlank()
                },
                onClick = {
                    val credential = when (authMethod) {
                        SshAuthMethod.PASSWORD -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.PASSWORD,
                            password = password,
                            unlockMacosKeychain = unlockMacosKeychain,
                        )

                        SshAuthMethod.KEY -> SavedSshCredential(
                            username = username.trim(),
                            method = SshAuthMethod.KEY,
                            privateKey = privateKey,
                            passphrase = passphrase.ifBlank { null },
                            unlockMacosKeychain = false,
                        )
                    }
                    scope.launch {
                        isConnecting = true
                        errorMessage = onConnect(credential, rememberCredentials)
                        isConnecting = false
                    }
                },
            ) {
                if (isConnecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Text("Connect")
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !isConnecting) {
                Text("Cancel")
            }
        },
    )
}

@Composable
private fun SSHAgentPickerDialog(
    context: SshBridgeAgentContext,
    onDismiss: () -> Unit,
    onUseCodex: () -> Unit,
    onConnect: suspend (List<AgentRuntimeKind>) -> String?,
) {
    val scope = rememberCoroutineScope()
    val availableKinds = remember(context.sessionId) {
        availableSshBridgeKinds(context.availability)
    }
    var selectedKinds by remember(context.sessionId) {
        mutableStateOf(availableKinds.toSet())
    }
    var isConnecting by remember(context.sessionId) { mutableStateOf(false) }
    var errorMessage by remember(context.sessionId) { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = { if (!isConnecting) onDismiss() },
        title = { Text("Remote Agents") },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = "${context.server.name.ifBlank { context.host }}\n${context.host}",
                    color = LitterTheme.textPrimary,
                    fontSize = 13.sp,
                )
                context.availability.forEach { agent ->
                    val enabled = isSshBridgeKind(agent.kind) &&
                        agent.status == AgentAvailabilityStatus.AVAILABLE &&
                        !isConnecting
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = enabled) {
                                selectedKinds = if (agent.kind in selectedKinds) {
                                    selectedKinds - agent.kind
                                } else {
                                    selectedKinds + agent.kind
                                }
                            }
                            .padding(vertical = 4.dp),
                    ) {
                        AgentIconView(
                            kind = agent.kind,
                            sizeDp = 22,
                            modifier = Modifier.alpha(
                                if (agent.status == AgentAvailabilityStatus.AVAILABLE) 1f else 0.45f,
                            ),
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = sshRuntimeLabel(agent.kind),
                                    color = if (agent.status == AgentAvailabilityStatus.AVAILABLE) {
                                        LitterTheme.textPrimary
                                    } else {
                                        LitterTheme.textSecondary
                                    },
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Medium,
                                )
                                if (agent.kind.isBeta) {
                                    Spacer(Modifier.width(6.dp))
                                    BetaBadge()
                                }
                            }
                            Text(
                                text = sshAgentStatusLabel(agent),
                                color = LitterTheme.textSecondary,
                                fontSize = 11.sp,
                            )
                        }
                        if (agent.kind in selectedKinds) {
                            Icon(
                                imageVector = Icons.Filled.CheckCircle,
                                contentDescription = null,
                                tint = LitterTheme.accent,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
                if (errorMessage != null) {
                    Text(
                        text = errorMessage!!,
                        color = LitterTheme.danger,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !isConnecting && selectedKinds.isNotEmpty(),
                onClick = {
                    scope.launch {
                        isConnecting = true
                        errorMessage = onConnect(selectedKinds.sortedBy(::sshRuntimeSortRank))
                        isConnecting = false
                    }
                },
            ) {
                if (isConnecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Text("Connect")
                }
            }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onUseCodex, enabled = !isConnecting) {
                    Text("Use Codex SSH")
                }
                TextButton(onClick = onDismiss, enabled = !isConnecting) {
                    Text("Cancel")
                }
            }
        },
    )
}

private fun availableSshBridgeKinds(agents: List<RemoteAgentAvailability>): List<AgentRuntimeKind> =
    agents
        .filter { isSshBridgeKind(it.kind) && it.status == AgentAvailabilityStatus.AVAILABLE }
        .map { it.kind }
        .sortedBy(::sshRuntimeSortRank)

private fun isSshBridgeKind(kind: AgentRuntimeKind): Boolean =
    kind.metadata?.capabilities?.supportsSshBridge
        ?: (kind in setOf("claude", "pi", "opencode", "local-studio"))

private fun sshRuntimeLabel(kind: AgentRuntimeKind): String = kind.runtimeLabel

private fun sshRuntimeSortRank(kind: AgentRuntimeKind): Int = kind.runtimeSortIndex

private fun sshAgentStatusLabel(agent: RemoteAgentAvailability): String = when (agent.status) {
    AgentAvailabilityStatus.AVAILABLE -> "Available"
    AgentAvailabilityStatus.AGENT_CLI_MISSING -> "CLI missing"
    AgentAvailabilityStatus.WINDOWS_NOT_YET_SUPPORTED -> "Windows not supported"
}

private fun sshBridgeStateRoot(context: Context, host: String): String {
    val safeHost = host.replace(Regex("[^A-Za-z0-9._-]"), "_")
    val dir = File(File(context.filesDir, "alleycat-bridges"), safeHost)
    dir.mkdirs()
    return dir.absolutePath
}

private fun connectedSnapshot(
    entry: SavedServer,
    servers: List<AppServerSnapshot>,
): AppServerSnapshot? = servers.firstOrNull { it.serverId == entry.id }
    ?: servers.firstOrNull { it.host.lowercase().trim().trimStart('[').trimEnd(']') == entry.deduplicationKey }

private sealed interface ManualEntryAction {
    data class Connect(val server: SavedServer) : ManualEntryAction
    data class ContinueWithSsh(val server: SavedServer) : ManualEntryAction
}

private sealed interface ManualEntryBuild {
    data class Action(val action: ManualEntryAction) : ManualEntryBuild
    data class Error(val message: String) : ManualEntryBuild
}

private enum class ManualConnectionMode(
    val label: String,
    val primaryButtonTitle: String,
) {
    CODEX("Codex", "Connect"),
    SSH("SSH", "Continue to SSH Login"),
}

private fun buildManualEntryAction(
    mode: ManualConnectionMode,
    codexUrl: String,
    host: String,
    sshPort: String,
    wakeMac: String,
): ManualEntryBuild = when (mode) {
    ManualConnectionMode.CODEX -> buildManualCodexEntry(codexUrl)
    ManualConnectionMode.SSH -> buildManualSshEntry(host, sshPort, wakeMac)
}

private fun buildManualCodexEntry(rawInput: String): ManualEntryBuild {
    val raw = rawInput.trim()
    if (raw.isEmpty()) {
        return ManualEntryBuild.Error("Enter a ws:// URL or host:port.")
    }

    runCatching { URI(raw) }
        .getOrNull()
        ?.let { uri ->
            val scheme = uri.scheme?.lowercase()
            val host = uri.host?.takeIf { it.isNotBlank() }
            if ((scheme == "ws" || scheme == "wss") && host != null) {
                val port = uri.port.takeIf { it > 0 }
                return ManualEntryBuild.Action(
                    ManualEntryAction.Connect(
                        SavedServer(
                            id = "manual-url-$raw",
                            name = host,
                            hostname = host,
                            port = port ?: 0,
                            codexPorts = port?.let(::listOf) ?: emptyList(),
                            source = "manual",
                            hasCodexServer = true,
                            preferredConnectionMode = "directCodex",
                            preferredCodexPort = port,
                            websocketURL = raw,
                        ).normalizedForPersistence(),
                    ),
                )
            }
        }

    val (host, port) = parseBareHostAndPort(raw) ?: return ManualEntryBuild.Error("Enter a ws:// URL or host:port.")
    if (host.isBlank()) {
        return ManualEntryBuild.Error("Enter a hostname or IP address.")
    }

    return ManualEntryBuild.Action(
        ManualEntryAction.Connect(
            SavedServer(
                id = "manual-$host:$port",
                name = host,
                hostname = host,
                port = port,
                codexPorts = listOf(port),
                source = "manual",
                hasCodexServer = true,
                preferredConnectionMode = "directCodex",
                preferredCodexPort = port,
            ).normalizedForPersistence(),
        ),
    )
}

private fun buildManualSshEntry(
    hostInput: String,
    sshPortInput: String,
    wakeMacInput: String,
): ManualEntryBuild {
    val host = hostInput.trim()
    if (host.isEmpty()) {
        return ManualEntryBuild.Error("Enter a hostname or IP address.")
    }

    val sshPort = sshPortInput.trim().toIntOrNull()
    if (sshPort == null || sshPort !in 1..65535) {
        return ManualEntryBuild.Error("SSH port must be a valid number.")
    }

    val wakeInput = wakeMacInput.trim()
    val normalizedWakeMac = SavedServer.normalizeWakeMac(wakeInput)
    if (wakeInput.isNotEmpty() && normalizedWakeMac == null) {
        return ManualEntryBuild.Error("Wake MAC must look like aa:bb:cc:dd:ee:ff.")
    }

    return ManualEntryBuild.Action(
        ManualEntryAction.ContinueWithSsh(
            SavedServer(
                id = "manual-ssh-$host:$sshPort",
                name = host,
                hostname = host,
                port = sshPort,
                sshPort = sshPort,
                source = "manual",
                hasCodexServer = false,
                wakeMAC = normalizedWakeMac,
                preferredConnectionMode = "ssh",
            ).normalizedForPersistence(),
        ),
    )
}

private fun parseBareHostAndPort(raw: String): Pair<String, Int>? {
    if (raw.startsWith("[")) {
        val closing = raw.indexOf(']')
        if (closing > 1) {
            val host = raw.substring(1, closing)
            val portPart = raw.substring(closing + 1)
            val port = when {
                portPart.isEmpty() -> 8390
                portPart.startsWith(":") -> portPart.drop(1).toIntOrNull() ?: return null
                else -> return null
            }
            return host to port
        }
    }

    val colonCount = raw.count { it == ':' }
    if (colonCount == 1) {
        val index = raw.lastIndexOf(':')
        val host = raw.substring(0, index)
        val port = raw.substring(index + 1).toIntOrNull() ?: return null
        return host to port
    }

    return raw to 8390
}

private suspend fun loadSlingshotTokens(context: Context) =
    ChatGPTOAuth.requireStoredOrRefreshedTokens(
        context,
        "Sign in with ChatGPT before connecting with Slingshot.",
    )

private sealed interface ManualServerProbeResult {
    data class Codex(val port: Int) : ManualServerProbeResult
    data class Ssh(val port: Int) : ManualServerProbeResult
    data object None : ManualServerProbeResult
}

private suspend fun probeManualServer(
    host: String,
    preferredCodexPort: Int?,
    timeoutMillis: Long,
): ManualServerProbeResult = withContext(Dispatchers.IO) {
    val codexPorts = orderedCodexPorts(preferredCodexPort)
    val sshPorts = orderedSshPorts()
    val deadline = System.currentTimeMillis() + maxOf(timeoutMillis, 500L)

    while (System.currentTimeMillis() < deadline) {
        for (port in codexPorts) {
            if (isPortOpen(host, port, 700)) {
                return@withContext ManualServerProbeResult.Codex(port)
            }
        }

        for (port in sshPorts) {
            if (isPortOpen(host, port, 700)) {
                return@withContext ManualServerProbeResult.Ssh(port)
            }
        }

        delay(350)
    }

    ManualServerProbeResult.None
}

private fun orderedCodexPorts(preferred: Int?): List<Int> = buildList {
    preferred?.let(::add)
    addAll(listOf(8390, 9234, 4222))
}.filter { it in 1..65535 }.distinct()

private fun orderedSshPorts(): List<Int> = listOf(22)

private fun isPortOpen(host: String, port: Int, timeoutMillis: Int): Boolean =
    runCatching {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), timeoutMillis)
            true
        }
    }.getOrDefault(false)
