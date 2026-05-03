package com.litter.android.ui.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Pets
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.auth.ChatGPTOAuthActivity
import com.litter.android.state.ChatGPTOAuth
import com.litter.android.state.ChatGPTOAuthTokenStore
import com.litter.android.state.DebugSettings
import com.litter.android.state.MessageRecorder
import com.litter.android.state.OpenAIApiKeyStore
import com.litter.android.state.PetOverlayController
import com.litter.android.state.SavedServerStore
import com.litter.android.state.connectionModeLabel
import com.litter.android.state.isConnected
import com.litter.android.state.isIpcConnected
import com.litter.android.state.statusColor
import com.litter.android.state.statusLabel
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterColorThemeType
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.ConversationPrefs
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterFeature
import com.litter.android.ui.WallpaperBackdrop
import com.litter.android.ui.WallpaperManager
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterThemeIndexEntry
import com.litter.android.ui.LitterThemeManager
import com.litter.android.util.LLog
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.AppServerSnapshot
import uniffi.codex_mobile_client.AppLoginAccountRequest
import uniffi.codex_mobile_client.AppPetSummary

/**
 * Settings — hierarchical navigation matching iOS:
 * Top level: Appearance → | Font | Conversation | Experimental → | Account | Servers
 * Appearance pushes to sub-screen with theme pickers.
 * Experimental pushes to sub-screen with feature toggles.
 */

// ═══════════════════════════════════════════════════════════════════════════════
// Top-level Settings
// ═══════════════════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    onOpenAccount: (serverId: String) -> Unit,
    onOpenApps: (() -> Unit)? = null,
) {
    // Sub-screen navigation
    var subScreen by remember { mutableStateOf<SettingsSubScreen?>(null) }

    when (subScreen) {
        SettingsSubScreen.Appearance -> AppearanceScreen(onBack = { subScreen = null })
        SettingsSubScreen.Experimental -> ExperimentalScreen(onBack = { subScreen = null })
        SettingsSubScreen.Pets -> PetsScreen(onBack = { subScreen = null })
        SettingsSubScreen.TipJar -> TipJarScreen(onBack = { subScreen = null })
        SettingsSubScreen.Debug -> DebugScreen(onBack = { subScreen = null })
        null -> SettingsTopLevel(
            onDismiss = onDismiss,
            onOpenAppearance = { subScreen = SettingsSubScreen.Appearance },
            onOpenExperimental = { subScreen = SettingsSubScreen.Experimental },
            onOpenPets = { subScreen = SettingsSubScreen.Pets },
            onOpenTipJar = { subScreen = SettingsSubScreen.TipJar },
            onOpenDebug = { subScreen = SettingsSubScreen.Debug },
            onOpenAccount = onOpenAccount,
            onOpenApps = onOpenApps,
        )
    }
}

private enum class SettingsSubScreen { Appearance, Experimental, Pets, TipJar, Debug }

@Composable
private fun SettingsTopLevel(
    onDismiss: () -> Unit,
    onOpenAppearance: () -> Unit,
    onOpenExperimental: () -> Unit,
    onOpenPets: () -> Unit,
    onOpenTipJar: () -> Unit,
    onOpenDebug: () -> Unit,
    onOpenAccount: (serverId: String) -> Unit,
    onOpenApps: (() -> Unit)?,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val collapseTurns = ConversationPrefs.areTurnsCollapsed
    var renameTarget by remember { mutableStateOf<AppServerSnapshot?>(null) }
    var renameText by remember { mutableStateOf("") }

    val currentServer = remember(snapshot) {
        val activeServerId = snapshot?.activeThread?.serverId
        snapshot?.servers?.firstOrNull { it.serverId == activeServerId }
            ?: snapshot?.servers?.firstOrNull { it.isLocal }
            ?: snapshot?.servers?.firstOrNull()
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        // Title
        item {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text("Settings", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterEnd)) {
                    Text("Done", color = LitterTheme.accent)
                }
            }
            Spacer(Modifier.height(8.dp))
        }

        // ── Support ──
        item { SectionHeader("Support") }
        item {
            NavRow(icon = Icons.Default.Pets, label = "Tip the Kitty", onClick = onOpenTipJar)
        }

        // ── Theme ──
        item { SectionHeader("Theme") }
        item {
            NavRow(icon = Icons.Default.Palette, label = "Appearance", onClick = onOpenAppearance)
        }

        // ── Font ──
        item { SectionHeader("Font") }
        item {
            Column(
                Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
            ) {
                FontRow("Berkeley Mono", BerkeleyMono, LitterThemeManager.monoFontEnabled) { LitterThemeManager.applyFont(true) }
                HorizontalDivider(color = LitterTheme.divider)
                FontRow("System Default", FontFamily.Default, !LitterThemeManager.monoFontEnabled) { LitterThemeManager.applyFont(false) }
            }
        }

        // ── Conversation ──
        item { SectionHeader("Conversation") }
        item {
            SettingsRow(
                icon = { Text("⊟", color = LitterTheme.accent, fontSize = 16.sp) },
                label = "Collapse Turns", subtitle = "Collapse previous turns into cards",
                trailing = {
                    Switch(
                        checked = collapseTurns,
                        onCheckedChange = { ConversationPrefs.setCollapseTurns(context, it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent),
                    )
                },
            )
        }

        // ── Pets ──
        item { SectionHeader("Pet") }
        item {
            SettingsRow(
                icon = { Icon(Icons.Default.Pets, null, tint = LitterTheme.accent, modifier = Modifier.size(18.dp)) },
                label = "Wake Pet",
                subtitle = PetOverlayController.selectedPet?.displayName ?: "Choose a Codex pet",
                trailing = {
                    Switch(
                        checked = PetOverlayController.visible,
                        onCheckedChange = { PetOverlayController.setVisible(context, it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent),
                    )
                },
                onClick = onOpenPets,
            )
        }

        // ── Apps ──
        if (onOpenApps != null) {
            item { SectionHeader("Apps") }
            item {
                NavRow(
                    icon = Icons.Default.Widgets,
                    label = "Saved Apps",
                    onClick = {
                        onDismiss()
                        onOpenApps()
                    },
                )
            }
        }

        // ── Experimental ──
        item { SectionHeader("Experimental") }
        item {
            NavRow(icon = Icons.Default.Science, label = "Experimental Features", onClick = onOpenExperimental)
        }

        // ── Debug ──
        if (DebugSettings.enabled) {
            item { SectionHeader("Debug") }
            item {
                NavRow(icon = Icons.Default.Science, label = "Debug Settings", onClick = onOpenDebug)
            }
        }

        // ── Account ──
        item { SectionHeader("Account") }
        item {
            if (currentServer != null) {
                val accountStatus = when (val account = currentServer!!.account) {
                    is Account.Chatgpt -> account.email.ifEmpty { "ChatGPT account" }
                    is Account.ApiKey -> "OpenAI API key"
                    null -> "Not logged in"
                }
                SettingsRow(
                    icon = { Text("@", color = LitterTheme.accent, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
                    label = currentServer!!.displayName,
                    subtitle = accountStatus,
                    trailing = {
                        Icon(
                            Icons.Default.ChevronRight,
                            null,
                            tint = LitterTheme.textMuted,
                            modifier = Modifier.size(16.dp),
                        )
                    },
                    onClick = { onOpenAccount(currentServer!!.serverId) },
                )
            } else {
                SettingsRow(label = "Connect to a server first")
            }
        }

        // ── Servers ──
        item { SectionHeader("Servers") }
        val servers = snapshot?.servers ?: emptyList()
        if (servers.isEmpty()) {
            item { SettingsRow(label = "No servers connected") }
        } else {
            items(servers, key = { it.serverId }) { server ->
                ServerSettingsRow(
                    server = server,
                    onRename = if (server.isLocal) null else {
                        {
                            renameText = server.displayName
                            renameTarget = server
                        }
                    },
                    onRemove = {
                        scope.launch {
                            SavedServerStore.remove(context, server.serverId)
                            appModel.sshSessionStore.close(server.serverId)
                            appModel.serverBridge.disconnectServer(server.serverId)
                            appModel.refreshSnapshot()
                        }
                    },
                )
            }
        }

        item { Spacer(Modifier.height(32.dp)) }
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
}

@Composable
private fun ServerSettingsRow(
    server: AppServerSnapshot,
    onRename: (() -> Unit)?,
    onRemove: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
        ) {
            Text(if (server.isLocal) "📱" else "🖥", fontSize = 16.sp)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(server.displayName, color = LitterTheme.textPrimary, fontSize = 13.sp)
                Text(
                    "${server.statusLabel} · ${server.connectionModeLabel}",
                    color = server.statusColor,
                    fontSize = 11.sp,
                )
            }
            if (server.isIpcConnected) {
                Text(
                    "IPC",
                    color = LitterTheme.accentStrong,
                    fontSize = 10.sp,
                    modifier = Modifier
                        .background(
                            LitterTheme.accentStrong.copy(alpha = 0.14f),
                            RoundedCornerShape(4.dp),
                        )
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
                Spacer(Modifier.width(8.dp))
            }
            IconButton(
                onClick = { showMenu = true },
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    Icons.Default.MoreVert,
                    contentDescription = "Server actions",
                    tint = LitterTheme.textSecondary,
                )
            }
        }

        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            if (onRename != null) {
                DropdownMenuItem(
                    text = { Text("Rename") },
                    onClick = {
                        showMenu = false
                        onRename()
                    },
                )
            }
            DropdownMenuItem(
                text = { Text("Remove") },
                onClick = {
                    showMenu = false
                    onRemove()
                },
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Appearance Sub-Screen (matches iOS AppearanceSettingsView)
// ═══════════════════════════════════════════════════════════════════════════════

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearanceScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var textSizeStep by remember { mutableFloatStateOf(com.litter.android.ui.TextSizePrefs.currentStep.toFloat()) }
    var showThemePicker by remember { mutableStateOf<LitterColorThemeType?>(null) }
    var wallpaperError by remember { mutableStateOf<String?>(null) }
    val wallpaperPicker =
        rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
            if (uri == null) {
                return@rememberLauncherForActivityResult
            }
            scope.launch {
                wallpaperError =
                    if (WallpaperManager.setCustomFromUri(uri)) {
                        null
                    } else {
                        "Unable to save wallpaper from the selected image."
                    }
            }
        }

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text("Appearance", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            // Font size slider
            item { SectionHeader("Font Size") }
            item {
                Column(
                    Modifier.fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text("Font Size", color = LitterTheme.textPrimary, fontSize = 14.sp)
                        Spacer(Modifier.weight(1f))
                        val label = com.litter.android.ui.ConversationTextSize.fromStep(textSizeStep.toInt()).label
                        Text(label, color = LitterTheme.textSecondary, fontSize = 13.sp)
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("A", color = LitterTheme.textMuted, fontSize = 11.sp)
                        Slider(
                            value = textSizeStep,
                            onValueChange = {
                                textSizeStep = it
                                com.litter.android.ui.TextSizePrefs.setStep(context, it.toInt())
                            },
                            valueRange = 0f..6f, steps = 5,
                            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                            colors = SliderDefaults.colors(thumbColor = LitterTheme.accent, activeTrackColor = LitterTheme.accent),
                        )
                        Text("A", color = LitterTheme.textMuted, fontSize = 18.sp)
                    }
                }
            }
            item {
                Text("Pinch in conversations to adjust, or use this slider.", color = LitterTheme.textMuted, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
            }

            // Wallpaper picker
            item { SectionHeader("Chat Wallpaper") }
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(width = 48.dp, height = 72.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .border(1.dp, LitterTheme.border.copy(alpha = 0.5f), RoundedCornerShape(8.dp)),
                    ) {
                        WallpaperBackdrop(modifier = Modifier.fillMaxSize())
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        TextButton(
                            onClick = { wallpaperPicker.launch("image/*") },
                            contentPadding = ButtonDefaults.TextButtonContentPadding,
                        ) {
                            Text("Choose from Library", color = LitterTheme.accent)
                        }
                        if (WallpaperManager.isWallpaperSet) {
                            TextButton(
                                onClick = {
                                    WallpaperManager.clear()
                                    wallpaperError = null
                                },
                                contentPadding = ButtonDefaults.TextButtonContentPadding,
                            ) {
                                Text("Remove Wallpaper", color = LitterTheme.danger)
                            }
                        }
                        if (!wallpaperError.isNullOrBlank()) {
                            Text(
                                wallpaperError!!,
                                color = LitterTheme.danger,
                                fontSize = 11.sp,
                            )
                        }
                    }
                }
            }

            // Conversation preview
            item { SectionHeader("Preview") }
            item {
                val scale = com.litter.android.ui.ConversationTextSize.fromStep(textSizeStep.toInt()).scale
                val previewFontSize = (14f * scale).sp
                val previewCodeFontSize = (13f * scale).sp
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                ) {
                    WallpaperBackdrop(modifier = Modifier.fillMaxSize())
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        // User bubble
                        Text(
                            "Hey, why is prod on fire",
                            color = LitterTheme.textPrimary,
                            fontSize = previewFontSize,
                            lineHeight = (previewFontSize.value * 1.3f).sp,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                                .padding(10.dp),
                        )
                        // Tool call card
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                                .padding(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("✓", color = LitterTheme.success, fontSize = 12.sp)
                            Spacer(Modifier.width(6.dp))
                            Text("rg 'TODO: fix later' --count", color = LitterTheme.toolCallCommand, fontFamily = BerkeleyMono, fontSize = (previewFontSize.value - 2).sp)
                            Spacer(Modifier.weight(1f))
                            Text("0.3s", color = LitterTheme.textMuted, fontSize = 10.sp)
                        }
                        // Assistant bubble
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                "Found the issue. Someone deployed this:",
                                color = LitterTheme.textBody,
                                fontSize = previewFontSize,
                                lineHeight = (previewFontSize.value * 1.3f).sp,
                            )
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(
                                    "PYTHON",
                                    color = LitterTheme.textSecondary,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp))
                                        .padding(10.dp),
                                ) {
                                    Text(
                                        "if is_friday():\n    yolo_deploy(skip_tests=True)",
                                        color = LitterTheme.textBody,
                                        fontFamily = LitterTheme.monoFont,
                                        fontSize = previewCodeFontSize,
                                        lineHeight = (previewCodeFontSize.value * 1.35f).sp,
                                    )
                                }
                            }
                            Text(
                                "I'm not mad, just disappointed.",
                                color = LitterTheme.textBody,
                                fontSize = previewFontSize,
                                lineHeight = (previewFontSize.value * 1.3f).sp,
                            )
                        }
                        // User reply
                        Text(
                            "That was you",
                            color = LitterTheme.textPrimary,
                            fontSize = previewFontSize,
                            lineHeight = (previewFontSize.value * 1.3f).sp,
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                                .padding(10.dp),
                        )
                    }
                }
            }

            // Light theme picker
            item { SectionHeader("Light Theme") }
            item {
                val selectedLight = LitterThemeManager.lightThemes.firstOrNull {
                    it.slug == LitterThemeManager.lightTheme.slug
                } ?: LitterThemeManager.lightThemes.firstOrNull()
                ThemePickerButton(entry = selectedLight, onClick = { showThemePicker = LitterColorThemeType.LIGHT })
            }

            // Dark theme picker
            item { SectionHeader("Dark Theme") }
            item {
                val selectedDark = LitterThemeManager.darkThemes.firstOrNull {
                    it.slug == LitterThemeManager.darkTheme.slug
                } ?: LitterThemeManager.darkThemes.firstOrNull()
                ThemePickerButton(entry = selectedDark, onClick = { showThemePicker = LitterColorThemeType.DARK })
            }
        }
    }

    // Theme picker sheet
    showThemePicker?.let { type ->
        ModalBottomSheet(
            onDismissRequest = { showThemePicker = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            val themes = if (type == LitterColorThemeType.DARK) LitterThemeManager.darkThemes else LitterThemeManager.lightThemes
            val selectedSlug = if (type == LitterColorThemeType.DARK) LitterThemeManager.darkTheme.slug else LitterThemeManager.lightTheme.slug
            ThemePickerContent(
                title = if (type == LitterColorThemeType.DARK) "Dark Theme" else "Light Theme",
                themes = themes,
                selectedSlug = selectedSlug,
                onSelect = { slug ->
                    if (type == LitterColorThemeType.DARK) {
                        LitterThemeManager.selectDarkTheme(slug)
                        LitterThemeManager.applyDarkMode(true)
                    } else {
                        LitterThemeManager.selectLightTheme(slug)
                        LitterThemeManager.applyDarkMode(false)
                    }
                    showThemePicker = null
                },
                onDismiss = { showThemePicker = null },
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Theme Picker Sheet (matches iOS ThemePickerSheet)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun ThemePickerContent(
    title: String,
    themes: List<LitterThemeIndexEntry>,
    selectedSlug: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var searchQuery by remember { mutableStateOf("") }
    val filtered = remember(themes, searchQuery) {
        if (searchQuery.isBlank()) themes
        else themes.filter { it.name.contains(searchQuery, ignoreCase = true) || it.slug.contains(searchQuery, ignoreCase = true) }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
    ) {
        // Title + Done
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.weight(1f))
            Text(title, color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Done", color = LitterTheme.accent) }
        }

        Spacer(Modifier.height(8.dp))

        // Search
        Row(
            Modifier.fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.55f), RoundedCornerShape(10.dp))
                .border(1.dp, LitterTheme.border.copy(alpha = 0.85f), RoundedCornerShape(10.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.Search, null, tint = LitterTheme.textMuted, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(8.dp))
            BasicTextField(
                value = searchQuery, onValueChange = { searchQuery = it },
                textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 14.sp),
                cursorBrush = SolidColor(LitterTheme.accent),
                modifier = Modifier.fillMaxWidth(),
                decorationBox = { inner ->
                    if (searchQuery.isEmpty()) Text("Search themes", color = LitterTheme.textMuted, fontSize = 14.sp)
                    inner()
                },
            )
        }

        Spacer(Modifier.height(12.dp))

        // Theme list
        if (filtered.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.Search, null, tint = LitterTheme.textMuted, modifier = Modifier.size(24.dp))
                Spacer(Modifier.height(8.dp))
                Text("No matching themes", color = LitterTheme.textPrimary, fontSize = 14.sp)
            }
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(filtered, key = { it.slug }) { entry ->
                    val isSelected = entry.slug == selectedSlug
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                            .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                            .border(
                                1.dp,
                                if (isSelected) LitterTheme.accent.copy(alpha = 0.6f) else LitterTheme.border.copy(alpha = 0.85f),
                                RoundedCornerShape(12.dp),
                            )
                            .clickable { onSelect(entry.slug) }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                    ) {
                        ThemePreviewBadge(entry)
                        Spacer(Modifier.width(10.dp))
                        Text(entry.name, color = LitterTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        if (isSelected) {
                            Icon(Icons.Default.Check, null, tint = LitterTheme.accent, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
        }
    }
}

/** "Aa" badge with background/foreground/accent dot — matches iOS ThemePreviewBadge */
@Composable
private fun ThemePreviewBadge(entry: LitterThemeIndexEntry) {
    val bg = try { Color(android.graphics.Color.parseColor(entry.backgroundHex)) } catch (_: Exception) { LitterTheme.surface }
    val fg = try { Color(android.graphics.Color.parseColor(entry.foregroundHex)) } catch (_: Exception) { LitterTheme.textPrimary }
    val accent = try { Color(android.graphics.Color.parseColor(entry.accentHex)) } catch (_: Exception) { LitterTheme.accent }

    Box {
        Box(
            Modifier.size(width = 28.dp, height = 22.dp)
                .background(bg, RoundedCornerShape(5.dp))
                .border(0.5.dp, Color.Gray.copy(alpha = 0.3f), RoundedCornerShape(5.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("Aa", color = fg, fontSize = 11.sp, fontWeight = FontWeight.Bold, fontFamily = BerkeleyMono)
        }
        Spacer(
            Modifier.size(6.dp).clip(CircleShape).background(accent)
                .align(Alignment.BottomEnd),
        )
    }
}

@Composable
private fun ThemePickerButton(entry: LitterThemeIndexEntry?, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        if (entry != null) {
            ThemePreviewBadge(entry)
            Spacer(Modifier.width(10.dp))
            Text(entry.name, color = LitterTheme.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        } else {
            Text("No themes", color = LitterTheme.textMuted, fontSize = 14.sp, modifier = Modifier.weight(1f))
        }
        Text("⇅", color = LitterTheme.textMuted, fontSize = 12.sp)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pets Sub-Screen
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun PetsScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val connectedServers = remember(snapshot) {
        snapshot?.servers.orEmpty().filter { it.isConnected }
    }
    var selectedServerId by remember(connectedServers) {
        mutableStateOf(
            PetOverlayController.selectedPet?.serverId?.takeIf { id ->
                connectedServers.any { it.serverId == id }
            }
                ?: snapshot?.activeThread?.serverId?.takeIf { id ->
                    connectedServers.any { it.serverId == id }
                }
                ?: connectedServers.firstOrNull()?.serverId
                ?: "",
        )
    }
    var pets by remember(selectedServerId) { mutableStateOf<List<AppPetSummary>>(emptyList()) }
    var loading by remember(selectedServerId) { mutableStateOf(false) }
    var error by remember(selectedServerId) { mutableStateOf<String?>(null) }

    fun refresh() {
        if (selectedServerId.isBlank()) return
        scope.launch {
            loading = true
            error = null
            runCatching { appModel.client.listPets(selectedServerId) }
                .onSuccess { pets = it }
                .onFailure {
                    pets = emptyList()
                    error = it.message ?: "Unable to load pets."
                }
            loading = false
        }
    }

    LaunchedEffect(selectedServerId) {
        refresh()
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
                }
                Spacer(Modifier.weight(1f))
                Text("Pet", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { refresh() }, enabled = selectedServerId.isNotBlank() && !loading) {
                    Icon(Icons.Default.Refresh, "Refresh", tint = LitterTheme.accent)
                }
            }
        }

        item { SectionHeader("Wake") }
        item {
            SettingsRow(
                label = "Show Pet",
                subtitle = PetOverlayController.selectedPet?.displayName ?: "No pet selected",
                icon = { Icon(Icons.Default.Pets, null, tint = LitterTheme.accent, modifier = Modifier.size(18.dp)) },
                trailing = {
                    Switch(
                        checked = PetOverlayController.visible,
                        onCheckedChange = { PetOverlayController.setVisible(context, it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent),
                    )
                },
            )
        }

        item { SectionHeader("Server") }
        if (connectedServers.isEmpty()) {
            item { SettingsRow(label = "Connect to a server first") }
        } else {
            items(connectedServers, key = { it.serverId }) { server ->
                SettingsRow(
                    label = server.displayName,
                    subtitle = server.connectionModeLabel,
                    trailing = {
                        if (server.serverId == selectedServerId) {
                            Icon(Icons.Default.Check, null, tint = LitterTheme.accentStrong, modifier = Modifier.size(18.dp))
                        }
                    },
                    onClick = { selectedServerId = server.serverId },
                )
            }
        }

        item { SectionHeader("Pets") }
        when {
            selectedServerId.isBlank() -> {
                item { SettingsRow(label = "No server selected") }
            }
            loading -> {
                item {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
                            .padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), color = LitterTheme.accent, strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text("Loading pets", color = LitterTheme.textSecondary, fontSize = 13.sp)
                    }
                }
            }
            error != null -> {
                item { SettingsRow(label = "Unable to load pets", subtitle = error) }
            }
            pets.isEmpty() -> {
                item { SettingsRow(label = "No pets found", subtitle = "~/.codex/pets has no hatch-pet packages") }
            }
            else -> {
                items(pets, key = { it.id }) { pet ->
                    val selected = PetOverlayController.selectedPet?.serverId == selectedServerId &&
                        PetOverlayController.selectedPet?.id == pet.id
                    SettingsRow(
                        label = pet.displayName,
                        subtitle = pet.validationError ?: pet.description ?: pet.sourcePath,
                        trailing = {
                            if (PetOverlayController.isLoading && selected) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), color = LitterTheme.accent, strokeWidth = 2.dp)
                            } else if (selected) {
                                Icon(Icons.Default.Check, null, tint = LitterTheme.accentStrong, modifier = Modifier.size(18.dp))
                            }
                        },
                        onClick = if (pet.hasValidSpritesheet) {
                            {
                                scope.launch {
                                    PetOverlayController.selectPet(context, appModel, selectedServerId, pet)
                                }
                            }
                        } else {
                            null
                        },
                    )
                }
            }
        }

        PetOverlayController.errorMessage?.let { message ->
            item { SettingsRow(label = "Pet load failed", subtitle = message) }
        }

        item { Spacer(Modifier.height(32.dp)) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Experimental Sub-Screen (matches iOS ExperimentalFeaturesView)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun ExperimentalScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val features = remember { LitterFeature.entries }

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text("Experimental", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        SectionHeader("Features")
        Column(
            Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
        ) {
            features.forEachIndexed { idx, feature ->
                val enabled = ExperimentalFeatures.isEnabled(feature)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(feature.displayName, color = LitterTheme.textPrimary, fontSize = 14.sp)
                        Text(feature.description, color = LitterTheme.textSecondary, fontSize = 11.sp)
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = { ExperimentalFeatures.setEnabled(context, feature, it) },
                        colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accentStrong),
                    )
                }
                if (idx < features.lastIndex) HorizontalDivider(color = LitterTheme.divider)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text("Experimental features may be unstable or change without notice.", color = LitterTheme.textMuted, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Debug Sub-Screen
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun DebugScreen(onBack: () -> Unit) {
    val context = LocalContext.current

    Column(
        Modifier
            .fillMaxSize()
            .imePadding()
            .padding(16.dp),
    ) {
        // Nav bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = LitterTheme.accent)
            }
            Spacer(Modifier.weight(1f))
            Text("Debug", color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(48.dp))
        }

        Spacer(Modifier.height(16.dp))

        SectionHeader("Rendering")
        Column(
            Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Disable Markdown", color = LitterTheme.textPrimary, fontSize = 14.sp)
                    Text("Show raw monospace text instead of rendered markdown", color = LitterTheme.textSecondary, fontSize = 11.sp)
                }
                Switch(
                    checked = DebugSettings.disableMarkdown,
                    onCheckedChange = { DebugSettings.setDisableMarkdown(context, it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accentStrong),
                )
            }
            HorizontalDivider(color = LitterTheme.divider)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Show Turn Metrics", color = LitterTheme.textPrimary, fontSize = 14.sp)
                    Text("Display elapsed time and token count on turn items", color = LitterTheme.textSecondary, fontSize = 11.sp)
                }
                Switch(
                    checked = DebugSettings.showTurnMetrics,
                    onCheckedChange = { DebugSettings.setShowTurnMetrics(context, it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accentStrong),
                )
            }
        }

        // ── Recording ──
        Spacer(Modifier.height(12.dp))
        SectionHeader("Recording")

        val appModel = LocalAppModel.current
        val scope = rememberCoroutineScope()
        var isRecording by remember { mutableStateOf(MessageRecorder.isRecording(appModel.store)) }
        var recordings by remember { mutableStateOf(MessageRecorder.listRecordings(context)) }

        Column(
            Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        if (isRecording) "Recording..." else "Message Recording",
                        color = if (isRecording) LitterTheme.danger else LitterTheme.textPrimary,
                        fontSize = 14.sp,
                    )
                    Text("Record server messages for replay", color = LitterTheme.textSecondary, fontSize = 11.sp)
                }
                TextButton(onClick = {
                    if (isRecording) {
                        MessageRecorder.stopRecording(context, appModel.store)
                        isRecording = false
                        recordings = MessageRecorder.listRecordings(context)
                    } else {
                        MessageRecorder.startRecording(appModel.store)
                        isRecording = true
                    }
                }) {
                    Text(
                        if (isRecording) "Stop" else "Start",
                        color = if (isRecording) LitterTheme.danger else LitterTheme.accent,
                    )
                }
            }

            if (recordings.isNotEmpty()) {
                HorizontalDivider(color = LitterTheme.divider)
                Text("Saved Recordings", color = LitterTheme.textSecondary, fontSize = 11.sp)
                recordings.forEach { file ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                    ) {
                        Text(
                            file.name,
                            color = LitterTheme.textPrimary,
                            fontSize = 12.sp,
                            modifier = Modifier.weight(1f),
                        )
                        val sizeKb = file.length() / 1024
                        Text("${sizeKb}KB", color = LitterTheme.textMuted, fontSize = 10.sp)
                        Spacer(Modifier.width(8.dp))
                        TextButton(onClick = {
                            MessageRecorder.deleteRecording(file)
                            recordings = MessageRecorder.listRecordings(context)
                        }) {
                            Text("Delete", color = LitterTheme.danger, fontSize = 11.sp)
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))
        Text("Debug features are for development and testing.", color = LitterTheme.textMuted, fontSize = 11.sp, modifier = Modifier.padding(start = 4.dp))
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Account Section (inline in top-level, matches iOS SettingsConnectionAccountSection)
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun AccountSection(server: uniffi.codex_mobile_client.AppServerSnapshot) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val apiKeyStore = remember(context) { OpenAIApiKeyStore(context.applicationContext) }
    var apiKey by remember { mutableStateOf("") }
    var isAuthWorking by remember { mutableStateOf(false) }
    var authError by remember { mutableStateOf<String?>(null) }
    var hasStoredApiKey by remember { mutableStateOf(apiKeyStore.hasStoredKey()) }
    val authLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        isAuthWorking = false
        LLog.d("ChatGPTOAuth", "settings auth result", fields = mapOf("resultCode" to result.resultCode))
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            val tokens = ChatGPTOAuthActivity.parseResult(result.data)
            if (tokens == null) {
                authError = "ChatGPT login returned incomplete credentials."
                LLog.w("ChatGPTOAuth", "settings auth result missing tokens")
                return@rememberLauncherForActivityResult
            }
            scope.launch {
                isAuthWorking = true
                try {
                    LLog.d("ChatGPTOAuth", "settings loginAccount starting")
                    appModel.client.loginAccount(
                        server.serverId,
                        AppLoginAccountRequest.ChatgptAuthTokens(
                            accessToken = tokens.accessToken,
                            chatgptAccountId = tokens.accountId,
                            chatgptPlanType = tokens.planType,
                        ),
                    )
                    appModel.refreshSnapshot()
                    authError = null
                    LLog.i("ChatGPTOAuth", "settings loginAccount succeeded")
                } catch (e: Exception) {
                    authError = e.localizedMessage ?: e.message
                    LLog.e("ChatGPTOAuth", "settings loginAccount failed", e)
                }
                isAuthWorking = false
            }
        } else {
            authError = result.data?.getStringExtra(ChatGPTOAuthActivity.EXTRA_ERROR)
            authError?.let { LLog.w("ChatGPTOAuth", "settings auth canceled", fields = mapOf("error" to it)) }
        }
    }

    val authColor = when (server.account) {
        is Account.Chatgpt -> LitterTheme.accent
        is Account.ApiKey -> Color(0xFF00AAFF)
        else -> LitterTheme.textMuted
    }
    val authTitle = when (val acct = server.account) {
        is Account.Chatgpt -> acct.email.ifEmpty { "ChatGPT" }
        is Account.ApiKey -> "API Key"
        else -> "Not logged in"
    }
    val authSubtitle = when (server.account) {
        is Account.Chatgpt -> "ChatGPT account"
        is Account.ApiKey -> "OpenAI API key"
        else -> null
    }
    val allowsLocalEnvApiKey = server.isLocal
    val isChatGPTAccount = server.account is Account.Chatgpt

    androidx.compose.runtime.LaunchedEffect(server.serverId, server.account) {
        hasStoredApiKey = apiKeyStore.hasStoredKey()
    }

    Column(
        Modifier.fillMaxWidth().background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status row
        Row(verticalAlignment = Alignment.CenterVertically) {
            Spacer(Modifier.size(10.dp).clip(CircleShape).background(authColor))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(authTitle, color = LitterTheme.textPrimary, fontSize = 14.sp)
                authSubtitle?.let { Text(it, color = LitterTheme.textSecondary, fontSize = 11.sp) }
            }
            if (server.isLocal && server.account != null) {
                TextButton(onClick = {
                    scope.launch {
                        try {
                            ChatGPTOAuthTokenStore(context).clear()
                            apiKeyStore.clear()
                            appModel.client.logoutAccount(server.serverId)
                            appModel.restartLocalServer()
                        } catch (_: Exception) {}
                    }
                }) { Text("Logout", color = LitterTheme.danger, fontSize = 12.sp) }
            }
        }

        if (server.isLocal && hasStoredApiKey) {
            Text(
                "Local OpenAI API key is saved.",
                color = LitterTheme.accent,
                fontSize = 11.sp,
            )
        }

        // Login button
        if (server.isLocal && !isChatGPTAccount) {
            Button(
                onClick = {
                    try {
                        authError = null
                        isAuthWorking = true
                        authLauncher.launch(
                            ChatGPTOAuthActivity.createIntent(
                                context,
                                ChatGPTOAuth.createLoginAttempt(),
                            ),
                        )
                    } catch (e: Exception) {
                        isAuthWorking = false
                        authError = e.localizedMessage ?: e.message
                    }
                },
                enabled = !isAuthWorking,
                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            ) {
                if (isAuthWorking) { CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = LitterTheme.textPrimary); Spacer(Modifier.width(6.dp)) }
                Text("Login with ChatGPT", color = LitterTheme.accent, fontSize = 14.sp)
            }
        }

        if (allowsLocalEnvApiKey) {
            if (hasStoredApiKey) {
                Text(
                    "OpenAI API key saved in the local environment.",
                    color = LitterTheme.textSecondary,
                    fontSize = 11.sp,
                )
            } else if (isChatGPTAccount) {
                Text(
                    "Save an API key in the local Codex environment.",
                    color = LitterTheme.textSecondary,
                    fontSize = 11.sp,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                BasicTextField(
                    value = apiKey, onValueChange = { apiKey = it },
                    textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = 13.sp),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.weight(1f).background(LitterTheme.codeBackground, RoundedCornerShape(6.dp)).padding(8.dp),
                    decorationBox = { inner -> if (apiKey.isEmpty()) Text("sk-...", color = LitterTheme.textMuted, fontSize = 13.sp); inner() },
                )
                Spacer(Modifier.width(8.dp))
                TextButton(
                    onClick = {
                        val key = apiKey.trim(); if (key.isEmpty()) return@TextButton
                        scope.launch {
                            isAuthWorking = true
                            try {
                                apiKeyStore.save(key)
                                if (server.account is Account.ApiKey) {
                                    appModel.client.logoutAccount(server.serverId)
                                }
                                appModel.restartLocalServer()
                                hasStoredApiKey = apiKeyStore.hasStoredKey()
                                if (hasStoredApiKey) {
                                    apiKey = ""
                                } else {
                                    authError = "API key did not persist locally."
                                    return@launch
                                }
                                authError = null
                            } catch (e: Exception) {
                                authError = e.message
                            }
                            isAuthWorking = false
                        }
                    },
                    enabled = apiKey.trim().isNotEmpty() && !isAuthWorking,
                ) {
                    Text(
                        if (hasStoredApiKey) "Update API Key" else "Save API Key",
                        color = LitterTheme.accent,
                        fontSize = 12.sp,
                    )
                }
            }
        } else {
            Text(
                "Remote servers request their own OAuth login when needed. Settings login and API key entry stay local-only.",
                color = LitterTheme.textSecondary,
                fontSize = 11.sp,
            )
        }

        authError?.let { Text(it, color = LitterTheme.danger, fontSize = 11.sp) }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Shared Components
// ═══════════════════════════════════════════════════════════════════════════════

@Composable
private fun SectionHeader(text: String) {
    Spacer(Modifier.height(8.dp))
    Text(text.uppercase(), color = LitterTheme.textSecondary, fontSize = 11.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
}

@Composable
private fun SettingsRow(
    label: String, subtitle: String? = null,
    icon: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(12.dp),
    ) {
        icon?.invoke()
        if (icon != null) Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(label, color = LitterTheme.textPrimary, fontSize = 14.sp)
            subtitle?.let { Text(it, color = LitterTheme.textSecondary, fontSize = 11.sp) }
        }
        trailing?.invoke()
    }
}

@Composable
private fun NavRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    SettingsRow(
        icon = { Icon(icon, null, tint = LitterTheme.accent, modifier = Modifier.size(20.dp)) },
        label = label,
        trailing = { Icon(Icons.Default.ChevronRight, null, tint = LitterTheme.textMuted, modifier = Modifier.size(16.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun FontRow(name: String, fontFamily: FontFamily, isSelected: Boolean, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(name, color = LitterTheme.textPrimary, fontSize = 14.sp)
            Text("The quick brown fox", color = LitterTheme.textSecondary, fontSize = 13.sp, fontFamily = fontFamily)
        }
        if (isSelected) Icon(Icons.Default.Check, null, tint = LitterTheme.accent, modifier = Modifier.size(18.dp))
    }
}
