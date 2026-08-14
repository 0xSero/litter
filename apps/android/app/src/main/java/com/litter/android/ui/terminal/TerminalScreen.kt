package com.litter.android.ui.terminal

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.PhoneIphone
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.core.bridge.GhosttyRendererBridge
import com.litter.android.core.bridge.GhosttyRendererStatus
import com.litter.android.state.ActiveTerminalRegistry
import com.litter.android.state.AlleycatCredentialStore
import com.litter.android.state.AndroidProotBootstrap
import com.litter.android.state.AppModel
import com.litter.android.state.SavedServerStore
import com.litter.android.state.SavedSshCredential
import com.litter.android.state.SshAuthMethod
import com.litter.android.state.SshCredentialStore
import com.litter.android.state.TerminalSessionController
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.TerminalBackendKind
import uniffi.codex_mobile_client.TerminalSshAuth

@Composable
fun TerminalScreen(
    cwd: String? = null,
    preferredAlleycatNodeId: String? = null,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val controller = remember { TerminalSessionController(scope) }
    val prootState by AndroidProotBootstrap.state.collectAsState()
    val rendererStatus = remember { GhosttyRendererBridge.status() }

    controller.sshTrustChallenge?.takeIf { it.isChanged }?.let { challenge ->
        AlertDialog(
            onDismissRequest = controller::dismissSshTrustChallenge,
            title = { Text("SSH Host Identity Changed") },
            text = {
                Text("The SSH identity for this server changed. This can happen after a server is recreated, but may also indicate a man-in-the-middle attack. New fingerprint: ${challenge.fingerprint}")
            },
            confirmButton = {
                TextButton(onClick = controller::trustUnknownSshHostAndRetry) {
                    Text("Replace Stored Identity")
                }
            },
            dismissButton = {
                TextButton(onClick = controller::dismissSshTrustChallenge) {
                    Text("Cancel")
                }
            },
        )
    }
    var nativeRendererAvailable by remember {
        mutableStateOf(rendererStatus.canCreateAndroidSurface)
    }
    val backendOptions = remember(cwd, prootState) { loadBackendOptions(context, cwd, prootState) }
    var selectedBackendId by remember(preferredAlleycatNodeId) { mutableStateOf<String?>(null) }
    val selectedBackend = backendOptions.firstOrNull { it.id == selectedBackendId }
        ?: backendOptions.firstOrNull()
    var terminalGridSize by remember { mutableStateOf(TerminalGridSize(cols = 80, rows = 24)) }
    var showConfigSheet by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        TerminalConfigPrefs.initialize(context)
    }

    val currentTerminalConfig = remember(
        TerminalConfigPrefs.fontSize,
        TerminalConfigPrefs.theme,
        TerminalConfigPrefs.cursorBlink,
    ) {
        TerminalConfigPrefs.currentConfig()
    }

    LaunchedEffect(backendOptions, preferredAlleycatNodeId) {
        if (backendOptions.none { it.id == selectedBackendId }) {
            selectedBackendId = initialBackendId(backendOptions, preferredAlleycatNodeId)
        }
    }

    LaunchedEffect(selectedBackend?.id) {
        selectedBackend?.let { controller.switchBackend(it.backend) }
    }

    DisposableEffect(controller) {
        onDispose { controller.close() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        TerminalHeader(
            phase = controller.phase,
            exitCode = controller.exitCode,
            selectedBackend = selectedBackend,
            backendOptions = backendOptions,
            onSelectBackend = { option ->
                selectedBackendId = option.id
            },
            onBack = onBack,
            onConfigClick = { showConfigSheet = true },
        )

        controller.errorMessage?.let { message ->
            Text(
                text = message,
                color = LitterTheme.danger,
                fontFamily = LitterTheme.monoFont,
                fontSize = 12.sp,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
        controller.sshTrustChallenge?.let { challenge ->
            TextButton(
                onClick = controller::trustUnknownSshHostAndRetry,
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                modifier = Modifier
                    .padding(horizontal = 16.dp)
                    .height(34.dp),
            ) {
                Text(
                    text = "Trust ${challenge.fingerprint}",
                    color = Color.Black,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 12.sp,
                    maxLines = 1,
                    modifier = Modifier
                        .background(LitterTheme.accent, RoundedCornerShape(8.dp))
                        .padding(horizontal = 10.dp, vertical = 7.dp),
                )
            }
        }

        TerminalOutputPane(
            controller = controller,
            rendererStatus = rendererStatus,
            nativeRendererAvailable = nativeRendererAvailable,
            onNativeRendererUnavailable = { nativeRendererAvailable = false },
            prootState = prootState,
            selectedBackend = selectedBackend,
            terminalGridSize = terminalGridSize,
            onTerminalGridSizeChanged = { terminalGridSize = it },
            density = density,
            terminalConfig = currentTerminalConfig,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        )

        val appSnapshot by AppModel.shared.snapshot.collectAsState()
        val activeThreadKey = appSnapshot?.activeThread
        TerminalAccessoryRow(
            controller = controller,
            canSendToAssistant = activeThreadKey != null &&
                (nativeRendererAvailable || controller.output.isNotEmpty()),
            onSendToAssistant = {
                val key = activeThreadKey ?: return@TerminalAccessoryRow
                val selection = ActiveTerminalRegistry.readSelection()
                val fallback = controller.output.trim()
                val payload = (selection?.takeIf { it.isNotEmpty() } ?: fallback)
                if (payload.isEmpty()) return@TerminalAccessoryRow
                scope.launch {
                    runCatching {
                        ActiveTerminalRegistry.sendTextToAssistant(
                            store = AppModel.shared.store,
                            threadKey = key,
                            selection = payload,
                        )
                    }
                }
            },
        )
    }

    if (showConfigSheet) {
        TerminalConfigSheet(
            context = context,
            onDismiss = { showConfigSheet = false },
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TerminalConfigSheet(
    context: Context,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState()
    var draftFontSize by remember(TerminalConfigPrefs.fontSize) {
        mutableStateOf(TerminalConfigPrefs.fontSize)
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color.Black,
        contentColor = LitterTheme.textPrimary,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = "Terminal",
                color = LitterTheme.textPrimary,
                fontFamily = LitterTheme.monoFont,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
            )

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = "Font size",
                        color = LitterTheme.textSecondary,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = 13.sp,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = "${draftFontSize.toInt()} pt",
                        color = LitterTheme.textMuted,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = 13.sp,
                    )
                }
                Slider(
                    value = draftFontSize,
                    onValueChange = { draftFontSize = it },
                    onValueChangeFinished = {
                        TerminalConfigPrefs.setFontSize(context, draftFontSize)
                    },
                    valueRange = 10f..24f,
                    steps = 13,
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "Theme",
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 13.sp,
                )
                TerminalThemeChoice.entries.forEach { choice ->
                    val selected = TerminalConfigPrefs.theme == choice
                    TextButton(
                        onClick = { TerminalConfigPrefs.setTheme(context, choice) },
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = choice.title,
                            color = if (selected) LitterTheme.accent else LitterTheme.textPrimary,
                            fontFamily = LitterTheme.monoFont,
                            fontSize = 13.sp,
                            modifier = Modifier.weight(1f),
                        )
                        if (selected) {
                            Text(
                                text = "•",
                                color = LitterTheme.accent,
                                fontFamily = LitterTheme.monoFont,
                                fontSize = 16.sp,
                            )
                        }
                    }
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Cursor blink",
                    color = LitterTheme.textPrimary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.weight(1f))
                Switch(
                    checked = TerminalConfigPrefs.cursorBlink,
                    onCheckedChange = { TerminalConfigPrefs.setCursorBlink(context, it) },
                )
            }
        }
    }
}

@Composable
private fun TerminalOutputPane(
    controller: TerminalSessionController,
    rendererStatus: GhosttyRendererStatus,
    nativeRendererAvailable: Boolean,
    onNativeRendererUnavailable: () -> Unit,
    prootState: AndroidProotBootstrap.BootstrapState,
    selectedBackend: TerminalBackendOption?,
    terminalGridSize: TerminalGridSize,
    onTerminalGridSizeChanged: (TerminalGridSize) -> Unit,
    density: androidx.compose.ui.unit.Density,
    terminalConfig: uniffi.codex_mobile_client.TerminalConfig?,
    modifier: Modifier = Modifier,
) {
    val outputScroll = rememberScrollState()
    LaunchedEffect(controller.output.length) {
        outputScroll.scrollTo(outputScroll.maxValue)
    }

    // Track the pane size so the pinch-driven font-size callback can
    // re-grid against the same container dimensions without going
    // through another layout pass.
    var paneSize by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }

    Box(
        modifier = modifier
            .onSizeChanged { size ->
                paneSize = size
                applyResize(
                    width = size.width,
                    height = size.height,
                    density = density,
                    terminalGridSize = terminalGridSize,
                    onTerminalGridSizeChanged = onTerminalGridSizeChanged,
                    controller = controller,
                    selectedBackend = selectedBackend,
                )
            },
    ) {
        if (nativeRendererAvailable) {
            GhosttyTerminalSurface(
                controller = controller,
                rendererStatus = rendererStatus,
                onRendererUnavailable = onNativeRendererUnavailable,
                config = terminalConfig,
                onFontSizeChanged = { _ ->
                    // Font size change shifts cell metrics; re-grid against
                    // the current container size so the PTY learns the new
                    // dimensions on the next event.
                    if (paneSize.width > 0 && paneSize.height > 0) {
                        applyResize(
                            width = paneSize.width,
                            height = paneSize.height,
                            density = density,
                            terminalGridSize = terminalGridSize,
                            onTerminalGridSizeChanged = onTerminalGridSizeChanged,
                            controller = controller,
                            selectedBackend = selectedBackend,
                        )
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            SelectionContainer(modifier = Modifier.fillMaxSize()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(outputScroll)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = controller.output.ifEmpty {
                            terminalEmptyMessage(prootState, selectedBackend)
                        },
                        color = LitterTheme.accent,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = TerminalConfigPrefs.fontSize.sp,
                        lineHeight = (TerminalConfigPrefs.fontSize * 1.31f).sp,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

/// Recompute (cols, rows) for the PTY. Prefer the live Ghostty cell
/// metrics returned by the active renderer — they're keyed to the
/// actual painted font — and fall back to a font-size-aware estimate
/// only when no renderer has been bound yet (first paint).
private fun applyResize(
    width: Int,
    height: Int,
    density: androidx.compose.ui.unit.Density,
    terminalGridSize: TerminalGridSize,
    onTerminalGridSizeChanged: (TerminalGridSize) -> Unit,
    controller: TerminalSessionController,
    selectedBackend: TerminalBackendOption?,
) {
    val metrics = ActiveTerminalRegistry.current()?.cellMetrics()
    val grid = if (metrics != null && metrics.cellWidthPx > 0 && metrics.cellHeightPx > 0) {
        TerminalGridSize.fromCellMetrics(
            widthPx = width,
            heightPx = height,
            density = density,
            cellWidthPx = metrics.cellWidthPx,
            cellHeightPx = metrics.cellHeightPx,
        )
    } else {
        TerminalGridSize.fromEstimate(
            widthPx = width,
            heightPx = height,
            density = density,
            fontSizeSp = TerminalConfigPrefs.fontSize,
        )
    }
    if (grid != terminalGridSize) {
        onTerminalGridSizeChanged(grid)
        controller.resize(
            cols = grid.cols,
            rows = grid.rows,
            notifyBackend = selectedBackend?.supportsResize == true,
        )
    }
}

@Composable
private fun TerminalHeader(
    phase: TerminalSessionController.Phase,
    exitCode: Int?,
    selectedBackend: TerminalBackendOption?,
    backendOptions: List<TerminalBackendOption>,
    onSelectBackend: (TerminalBackendOption) -> Unit,
    onBack: () -> Unit,
    onConfigClick: () -> Unit = {},
) {
    var backendMenuExpanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(40.dp)) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = LitterTheme.textPrimary,
            )
        }
        Text(
            text = "Terminal",
            color = LitterTheme.textPrimary,
            fontFamily = LitterTheme.monoFont,
            fontWeight = FontWeight.SemiBold,
            fontSize = 16.sp,
        )
        TextButton(
            onClick = { backendMenuExpanded = true },
            enabled = backendOptions.size > 1,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
            modifier = Modifier
                .padding(start = 8.dp)
                .height(34.dp),
        ) {
            Icon(
                selectedBackend?.icon ?: Icons.Outlined.Storage,
                contentDescription = null,
                tint = LitterTheme.accent,
                modifier = Modifier.size(16.dp),
            )
            Text(
                text = selectedBackend?.title ?: "No backend",
                color = LitterTheme.accent,
                fontFamily = LitterTheme.monoFont,
                fontSize = 12.sp,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
        DropdownMenu(
            expanded = backendMenuExpanded,
            onDismissRequest = { backendMenuExpanded = false },
        ) {
            backendOptions.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = option.title,
                            color = LitterTheme.textPrimary,
                            fontFamily = LitterTheme.monoFont,
                            fontSize = 13.sp,
                        )
                    },
                    leadingIcon = {
                        Icon(option.icon, contentDescription = null, tint = LitterTheme.accent)
                    },
                    onClick = {
                        backendMenuExpanded = false
                        onSelectBackend(option)
                    },
                )
            }
        }
        Spacer(Modifier.weight(1f))
        TextButton(
            onClick = onConfigClick,
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
            modifier = Modifier
                .padding(end = 6.dp)
                .height(30.dp),
        ) {
            Text(
                text = "Aa",
                color = LitterTheme.accent,
                fontFamily = LitterTheme.monoFont,
                fontSize = 13.sp,
            )
        }
        Text(
            text = phaseLabel(phase, exitCode, selectedBackend?.runningLabel ?: "unavailable"),
            color = phaseColor(phase),
            fontFamily = LitterTheme.monoFont,
            fontSize = 12.sp,
            modifier = Modifier
                .border(1.dp, phaseColor(phase).copy(alpha = 0.45f), RoundedCornerShape(999.dp))
                .padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun TerminalAccessoryRow(
    controller: TerminalSessionController,
    canSendToAssistant: Boolean,
    onSendToAssistant: () -> Unit,
) {
    val scroll = rememberScrollState()
    val clipboard = LocalClipboardManager.current
    val pasteText = clipboard.getText()?.text
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.96f))
            .horizontalScroll(scroll)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        TerminalKey("Esc", enabled = controller.canSendInput) { controller.send("") }
        TerminalKey("Tab", enabled = controller.canSendInput) { controller.send("\t") }
        TerminalKey("Ctrl-C", enabled = controller.canSendInput) { controller.send("") }
        TerminalKey("Ctrl-D", enabled = controller.canSendInput) { controller.send("") }
        TerminalKey("Ctrl-Z", enabled = controller.canSendInput) { controller.send("") }
        TerminalKey("←", enabled = controller.canSendInput) { controller.send("[D") }
        TerminalKey("↑", enabled = controller.canSendInput) { controller.send("[A") }
        TerminalKey("↓", enabled = controller.canSendInput) { controller.send("[B") }
        TerminalKey("→", enabled = controller.canSendInput) { controller.send("[C") }
        TerminalKey("Paste", enabled = controller.canSendInput && !pasteText.isNullOrEmpty()) {
            pasteText?.let(controller::send)
        }
        TerminalKey("Clear", enabled = controller.output.isNotEmpty()) { controller.clearOutput() }
        TerminalKey("Send to AI", enabled = canSendToAssistant, onClick = onSendToAssistant)
    }
}

@Composable
private fun TerminalKey(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
        modifier = Modifier.height(34.dp),
    ) {
        Text(
            text = label,
            color = if (enabled) LitterTheme.textSecondary else LitterTheme.textMuted,
            fontFamily = LitterTheme.monoFont,
            fontSize = 12.sp,
        )
    }
}

private fun phaseLabel(
    phase: TerminalSessionController.Phase,
    exitCode: Int?,
    runningLabel: String,
): String = when (phase) {
    TerminalSessionController.Phase.IDLE -> "idle"
    TerminalSessionController.Phase.CONNECTING -> "connecting"
    TerminalSessionController.Phase.RUNNING -> runningLabel
    TerminalSessionController.Phase.EXITED -> "exited ${exitCode ?: 0}"
    TerminalSessionController.Phase.FAILED -> "failed"
}

private fun phaseColor(phase: TerminalSessionController.Phase): Color = when (phase) {
    TerminalSessionController.Phase.IDLE -> LitterTheme.textMuted
    TerminalSessionController.Phase.CONNECTING -> LitterTheme.warning
    TerminalSessionController.Phase.RUNNING -> LitterTheme.accent
    TerminalSessionController.Phase.EXITED -> LitterTheme.textMuted
    TerminalSessionController.Phase.FAILED -> LitterTheme.danger
}

private data class TerminalBackendOption(
    val id: String,
    val title: String,
    val runningLabel: String,
    val icon: ImageVector,
    val alleycatNodeId: String? = null,
    val supportsResize: Boolean,
    val backend: TerminalBackendKind,
)

private fun initialBackendId(
    options: List<TerminalBackendOption>,
    preferredAlleycatNodeId: String?,
): String? {
    val preferred = normalized(preferredAlleycatNodeId)
    return options.firstOrNull { it.alleycatNodeId == preferred }?.id
        ?: options.firstOrNull()?.id
}

private fun loadBackendOptions(
    context: Context,
    cwd: String?,
    prootState: AndroidProotBootstrap.BootstrapState,
): List<TerminalBackendOption> {
    val options = mutableListOf<TerminalBackendOption>()
    if (prootState.status == AndroidProotBootstrap.Status.Ready) {
        options.add(
            TerminalBackendOption(
                id = "local-proot",
                title = "Local Alpine",
                runningLabel = "local alpine",
                icon = Icons.Outlined.PhoneIphone,
                supportsResize = true,
                backend = TerminalBackendKind.LocalProot(normalized(cwd)),
            ),
        )
    }
    val credentialStore = AlleycatCredentialStore(context.applicationContext)
    val sshCredentialStore = SshCredentialStore(context.applicationContext)
    val seenNodeIds = mutableSetOf<String>()
    val seenSshKeys = mutableSetOf<String>()
    SavedServerStore.remembered(context).forEach { saved ->
        val nodeId = normalized(saved.alleycatNodeId)
        if (nodeId != null && seenNodeIds.add(nodeId)) {
            val token = credentialStore.loadToken(nodeId)?.trim()?.takeIf { it.isNotEmpty() }
            if (token != null) {
                options.add(
                    TerminalBackendOption(
                        id = "alleycat-$nodeId",
                        title = saved.name.trim().ifEmpty { "Remote shell" },
                        runningLabel = "remote shell",
                        icon = Icons.Outlined.Storage,
                        alleycatNodeId = nodeId,
                        supportsResize = true,
                        backend = TerminalBackendKind.RemoteAlleycat(
                            nodeId = nodeId,
                            token = token,
                            relay = normalized(saved.alleycatRelay),
                            shell = null,
                        ),
                    ),
                )
                return@forEach
            }
        }

        val host = saved.hostname.takeIf { it.isNotBlank() } ?: return@forEach
        val sshPort = (saved.sshPort ?: 22).toInt()
        val key = "${host.lowercase()}:$sshPort"
        if (!seenSshKeys.add(key)) return@forEach
        val credential = sshCredentialStore.load(host, sshPort) ?: return@forEach
        val auth = credential.toTerminalSshAuth() ?: return@forEach
        options.add(
            TerminalBackendOption(
                id = "ssh-$key",
                title = saved.name.trim().ifEmpty { "${credential.username}@$host" },
                runningLabel = "ssh shell",
                icon = Icons.Outlined.Storage,
                supportsResize = true,
                backend = TerminalBackendKind.RemoteSsh(
                    host = host,
                    port = sshPort.toUShort(),
                    username = credential.username,
                    auth = auth,
                    shell = null,
                    acceptUnknownHost = false,
                    cwd = null,
                ),
            ),
        )
    }
    return options
}

private fun SavedSshCredential.toTerminalSshAuth(): TerminalSshAuth? = when (method) {
    SshAuthMethod.PASSWORD -> password
        ?.takeIf { it.isNotEmpty() }
        ?.let { TerminalSshAuth.Password(it) }
    SshAuthMethod.KEY -> privateKey
        ?.takeIf { it.isNotEmpty() }
        ?.let { TerminalSshAuth.PrivateKey(it, passphrase) }
}

private fun normalized(value: String?): String? =
    value?.trim()?.takeIf { it.isNotEmpty() }

private fun terminalEmptyMessage(
    prootState: AndroidProotBootstrap.BootstrapState,
    selectedBackend: TerminalBackendOption?,
): String {
    if (selectedBackend != null) return ""
    return when (prootState.status) {
        AndroidProotBootstrap.Status.Pending,
        AndroidProotBootstrap.Status.Bootstrapping -> "Preparing local Alpine...\n"
        AndroidProotBootstrap.Status.PtraceDenied ->
            "Local Alpine is unavailable because this Android environment blocks ptrace.\nRemote shell remains available after pairing an Alleycat host.\n"
        AndroidProotBootstrap.Status.MissingArtifact ->
            "Local Alpine is unavailable because proot or the Alpine rootfs is not bundled.\nRemote shell remains available after pairing an Alleycat host.\n"
        AndroidProotBootstrap.Status.Failed ->
            "Local Alpine bootstrap failed: ${prootState.message ?: "unknown error"}\nRemote shell remains available after pairing an Alleycat host.\n"
        AndroidProotBootstrap.Status.Ready ->
            "Pair an Alleycat host to open a remote shell.\n"
    }
}

private data class TerminalGridSize(
    val cols: Int,
    val rows: Int,
) {
    companion object {
        /// Compute the grid from the live cell metrics Ghostty reports.
        /// Divides the container pixel size by the cell pixel size to
        /// land on the same grid Ghostty paints.
        fun fromCellMetrics(
            widthPx: Int,
            heightPx: Int,
            density: androidx.compose.ui.unit.Density,
            cellWidthPx: Float,
            cellHeightPx: Float,
        ): TerminalGridSize {
            val w = widthPx.coerceAtLeast(1)
            val h = heightPx.coerceAtLeast(1)
            val cellW = cellWidthPx.coerceAtLeast(1f)
            val cellH = cellHeightPx.coerceAtLeast(1f)
            val cols = (w / cellW).toInt().coerceIn(20, 240)
            val rows = (h / cellH).toInt().coerceIn(4, 120)
            return TerminalGridSize(cols = cols, rows = rows)
        }

        /// First-paint fallback when the renderer hasn't measured the
        /// font yet. Scale cell estimates with the chosen font size so a
        /// 24sp font doesn't over-report cols/rows.
        fun fromEstimate(
            widthPx: Int,
            heightPx: Int,
            density: androidx.compose.ui.unit.Density,
            fontSizeSp: Float,
        ): TerminalGridSize = with(density) {
            val contentWidth = widthPx.coerceAtLeast(0)
            val contentHeight = heightPx.coerceAtLeast(0)
            val cellWidthPx = (fontSizeSp.coerceAtLeast(8f) * 0.6f).sp.toPx()
            val cellHeightPx = (fontSizeSp.coerceAtLeast(8f) * 1.31f).sp.toPx()
            val cols = (contentWidth / cellWidthPx.coerceAtLeast(1f))
                .toInt().coerceIn(20, 240)
            val rows = (contentHeight / cellHeightPx.coerceAtLeast(1f))
                .toInt().coerceIn(4, 120)
            TerminalGridSize(cols = cols, rows = rows)
        }
    }
}
