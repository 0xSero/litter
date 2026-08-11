package com.litter.android.ui.conversation

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.reportsEffectiveThreadPermissions
import com.litter.android.ui.common.supportsThreadPermissionOverrides
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AbsolutePath
import uniffi.codex_mobile_client.AppAskForApproval
import uniffi.codex_mobile_client.AppListExperimentalFeaturesRequest
import uniffi.codex_mobile_client.AppListSkillsRequest
import uniffi.codex_mobile_client.AppWriteConfigValueRequest
import uniffi.codex_mobile_client.ExperimentalFeature
import uniffi.codex_mobile_client.AppMergeStrategy
import uniffi.codex_mobile_client.AppSandboxPolicy
import uniffi.codex_mobile_client.SkillMetadata
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.threadPermissionsAreAuthoritative

private data class ComposerSelectionOption(
    val title: String,
    val description: String,
    val wireValue: String,
)

private val composerApprovalOptions = listOf(
    ComposerSelectionOption(
        title = "Default",
        description = "Use the thread or server default",
        wireValue = "inherit",
    ),
    ComposerSelectionOption(
        title = "Untrusted",
        description = "Always ask before taking action",
        wireValue = "untrusted",
    ),
    ComposerSelectionOption(
        title = "On failure",
        description = "Ask only when a command fails",
        wireValue = "on-failure",
    ),
    ComposerSelectionOption(
        title = "On request",
        description = "Ask when escalation is requested",
        wireValue = "on-request",
    ),
    ComposerSelectionOption(
        title = "Never",
        description = "Run without asking for approval",
        wireValue = "never",
    ),
)

private val composerSandboxOptions = listOf(
    ComposerSelectionOption(
        title = "Default",
        description = "Use the thread or server default",
        wireValue = "inherit",
    ),
    ComposerSelectionOption(
        title = "Read only",
        description = "Can read files, but cannot edit them",
        wireValue = "read-only",
    ),
    ComposerSelectionOption(
        title = "Workspace write",
        description = "Can edit files, but only in this workspace",
        wireValue = "workspace-write",
    ),
    ComposerSelectionOption(
        title = "Full access",
        description = "Can edit files outside this workspace",
        wireValue = "danger-full-access",
    ),
)

private fun selectedApprovalLabel(approvalPolicy: String): String =
    composerApprovalOptions.firstOrNull { it.wireValue == approvalPolicy }?.title ?: "Custom"

private fun selectedSandboxLabel(sandboxMode: String): String =
    composerSandboxOptions.firstOrNull { it.wireValue == sandboxMode }?.title ?: "Custom"

private fun AppAskForApproval.displayTitle(): String =
    when (this) {
        AppAskForApproval.UnlessTrusted -> "Untrusted"
        AppAskForApproval.OnFailure -> "On failure"
        AppAskForApproval.OnRequest -> "On request"
        is AppAskForApproval.Granular -> "Granular"
        AppAskForApproval.Never -> "Never"
    }

private fun AppSandboxPolicy.displayTitle(): String =
    when (this) {
        AppSandboxPolicy.DangerFullAccess -> "Full access"
        is AppSandboxPolicy.ReadOnly -> "Read only"
        is AppSandboxPolicy.WorkspaceWrite -> "Workspace write"
        is AppSandboxPolicy.ExternalSandbox -> "External sandbox"
    }

@Composable
fun ComposerPermissionsSheet(threadKey: ThreadKey? = null, onDismiss: () -> Unit) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    val appSnapshot by appModel.snapshot.collectAsState()
    val selectedApproval = appModel.launchState.selectedApprovalPolicy(threadKey)
    val selectedSandbox = appModel.launchState.selectedSandboxMode(threadKey)
    val effectiveThread = appSnapshot?.threads?.firstOrNull { it.key == threadKey }
    val selectedRuntime = effectiveThread?.agentRuntimeKind ?: launchState.selectedAgentRuntimeKind
    val currentRuntimeSupportsPermissionOverrides =
        selectedRuntime?.supportsThreadPermissionOverrides ?: true
    val hasAuthoritativeThreadPermissions = if (
        (selectedRuntime?.reportsEffectiveThreadPermissions ?: true) &&
        threadPermissionsAreAuthoritative(
            approvalPolicy = effectiveThread?.effectiveApprovalPolicy,
            sandboxPolicy = effectiveThread?.effectiveSandboxPolicy,
        )
    ) true else false
    val currentApprovalLabel =
        if (hasAuthoritativeThreadPermissions) effectiveThread?.effectiveApprovalPolicy?.displayTitle() ?: "Syncing..."
        else "Syncing..."
    val currentSandboxLabel =
        if (hasAuthoritativeThreadPermissions) effectiveThread?.effectiveSandboxPolicy?.displayTitle() ?: "Syncing..."
        else "Syncing..."
    val usesThreadDefaults = selectedApproval == "inherit" && selectedSandbox == "inherit"
    val scrollState = rememberScrollState()

    LaunchedEffect(threadKey) {
        threadKey ?: return@LaunchedEffect
        appModel.hydrateThreadPermissions(threadKey)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxSize(fraction = 0.92f)
            .verticalScroll(scrollState)
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SheetHeader(title = "Permissions", onDismiss = onDismiss)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface.copy(alpha = 0.82f), RoundedCornerShape(20.dp))
                .border(1.dp, LitterTheme.border.copy(alpha = 0.55f), RoundedCornerShape(20.dp))
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Thread permissions",
                        color = LitterTheme.textPrimary,
                        fontSize = 18f.scaled,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        text = if (currentRuntimeSupportsPermissionOverrides) {
                            "Changes apply on your next turn and later turns."
                        } else {
                            "This runtime controls its own permissions."
                        },
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption2.scaled,
                    )
                }
                Text(
                    text = if (!currentRuntimeSupportsPermissionOverrides) {
                        "Runtime managed"
                    } else if (usesThreadDefaults) {
                        "Using defaults"
                    } else {
                        "Custom override"
                    },
                    color = if (!currentRuntimeSupportsPermissionOverrides || usesThreadDefaults) {
                        LitterTheme.textSecondary
                    } else {
                        LitterTheme.accentStrong
                    },
                    fontSize = LitterTextStyle.caption2.scaled,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .background(
                            color = (
                                if (!currentRuntimeSupportsPermissionOverrides || usesThreadDefaults) {
                                    LitterTheme.surfaceLight
                                } else {
                                    LitterTheme.accentStrong
                                }
                            ).copy(alpha = 0.16f),
                            shape = RoundedCornerShape(999.dp),
                        )
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PermissionSummaryTile(
                    title = "Next turn",
                    approval = selectedApprovalLabel(selectedApproval),
                    sandbox = selectedSandboxLabel(selectedSandbox),
                    accent = LitterTheme.accentStrong,
                    modifier = Modifier.weight(1f),
                )
                if (threadKey != null) {
                    PermissionSummaryTile(
                        title = "Current thread",
                        approval = currentApprovalLabel,
                        sandbox = currentSandboxLabel,
                        accent = if (hasAuthoritativeThreadPermissions) LitterTheme.textSecondary else LitterTheme.warning,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }

        if (currentRuntimeSupportsPermissionOverrides) {
            PermissionSettingsSection(
                title = "Approval policy",
                subtitle = "Choose when Codex asks for approval",
            ) {
                PermissionDropdownField(
                    options = composerApprovalOptions,
                    selectedValue = selectedApproval,
                    onSelect = { value ->
                        appModel.launchState.updateThreadPermissions(threadKey, value, selectedSandbox)
                    },
                )
            }

            PermissionSettingsSection(
                title = "Sandbox settings",
                subtitle = "Choose how much Codex can do when running commands",
            ) {
                PermissionDropdownField(
                    options = composerSandboxOptions,
                    selectedValue = selectedSandbox,
                    onSelect = { value ->
                        appModel.launchState.updateThreadPermissions(threadKey, selectedApproval, value)
                    },
                )
            }
        } else {
            PermissionSettingsSection(
                title = "Runtime managed",
                subtitle = "This runtime does not accept client-side permission overrides.",
            ) {
                Text(
                    text = "Use the runtime's own controls for approval and sandbox behavior.",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption.scaled,
                )
            }
        }
    }
}

@Composable
private fun PermissionSummaryTile(
    title: String,
    approval: String,
    sandbox: String,
    accent: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .background(LitterTheme.surfaceLight.copy(alpha = 0.78f), RoundedCornerShape(16.dp))
            .border(1.dp, LitterTheme.border.copy(alpha = 0.45f), RoundedCornerShape(16.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = title,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption2.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        PermissionSummaryRow(label = "Approval", value = approval, accent = accent)
        PermissionSummaryRow(label = "Sandbox", value = sandbox, accent = accent)
    }
}

@Composable
private fun PermissionSummaryRow(
    label: String,
    value: String,
    accent: androidx.compose.ui.graphics.Color,
) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            text = label,
            color = LitterTheme.textMuted,
            fontSize = 10f.scaled,
            fontWeight = FontWeight.Medium,
        )
        Text(
            text = value,
            color = accent,
            fontSize = LitterTextStyle.code.scaled,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun PermissionSettingsSection(
    title: String,
    subtitle: String,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface.copy(alpha = 0.74f), RoundedCornerShape(20.dp))
            .border(1.dp, LitterTheme.border.copy(alpha = 0.5f), RoundedCornerShape(20.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                text = title,
                color = LitterTheme.textPrimary,
                fontSize = 18f.scaled,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = subtitle,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
            )
        }
        content()
    }
}

@Composable
private fun PermissionDropdownField(
    options: List<ComposerSelectionOption>,
    selectedValue: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedOption = options.firstOrNull { it.wireValue == selectedValue }

    Box(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surfaceLight.copy(alpha = 0.9f), RoundedCornerShape(14.dp))
                .border(1.dp, LitterTheme.border.copy(alpha = 0.45f), RoundedCornerShape(14.dp))
                .clickable { expanded = true }
                .padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = selectedOption?.title ?: "Custom",
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
                Text(
                    text = selectedOption?.description ?: "This setting is managed by the server.",
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption2.scaled,
                    maxLines = 1,
                )
            }
            Icon(
                imageVector = Icons.Default.KeyboardArrowDown,
                contentDescription = null,
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(18.dp),
            )
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = option.title,
                                color = LitterTheme.textPrimary,
                                fontSize = LitterTextStyle.body.scaled,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = option.description,
                                color = LitterTheme.textMuted,
                                fontSize = LitterTextStyle.caption2.scaled,
                            )
                        }
                    },
                    trailingIcon = {
                        if (selectedValue == option.wireValue) {
                            Icon(
                                imageVector = Icons.Default.Check,
                                contentDescription = null,
                                tint = LitterTheme.accentStrong,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    },
                    onClick = {
                        expanded = false
                        onSelect(option.wireValue)
                    },
                )
            }
        }
    }
}

@Composable
fun ComposerExperimentalSheet(
    serverId: String,
    onDismiss: () -> Unit,
    onError: (String) -> Unit,
) {
    val appModel = LocalAppModel.current
    val scope = rememberCoroutineScope()
    var features by remember(serverId) { mutableStateOf<List<ExperimentalFeature>>(emptyList()) }
    var isLoading by remember(serverId) { mutableStateOf(true) }
    var reloadToken by remember(serverId) { mutableIntStateOf(0) }

    LaunchedEffect(serverId, reloadToken) {
        isLoading = true
        runCatching {
            appModel.client.listExperimentalFeatures(
                serverId,
                AppListExperimentalFeaturesRequest(cursor = null, limit = 200u),
            )
        }.onSuccess { featuresResult ->
            features = featuresResult.sortedBy { (it.displayName ?: it.name).lowercase() }
        }.onFailure { error ->
            features = emptyList()
            onError(error.message ?: "Failed to load experimental features")
        }
        isLoading = false
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxSize(fraction = 0.9f)
            .imePadding()
            .padding(16.dp),
    ) {
        SheetHeader(
            title = "Experimental",
            leadingActionLabel = "Reload",
            onLeadingAction = { reloadToken += 1 },
            onDismiss = onDismiss,
        )
        Spacer(Modifier.height(12.dp))
        when {
            isLoading -> {
                Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = LitterTheme.accent, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                }
            }

            features.isEmpty() -> {
                Text("No experimental features available", color = LitterTheme.textMuted, fontSize = LitterTextStyle.code.scaled)
            }

            else -> {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(features, key = { it.name }) { feature ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(feature.displayName ?: feature.name, color = LitterTheme.textPrimary, fontSize = LitterTextStyle.body.scaled)
                                feature.description?.takeIf { it.isNotBlank() }?.let { description ->
                                    Text(description, color = LitterTheme.textSecondary, fontSize = LitterTextStyle.caption.scaled)
                                }
                            }
                            Switch(
                                checked = feature.enabled,
                                onCheckedChange = { enabled ->
                                    val previous = feature.enabled
                                    features = features.map {
                                        if (it.name == feature.name) {
                                            ExperimentalFeature(
                                                name = it.name,
                                                stage = it.stage,
                                                displayName = it.displayName,
                                                description = it.description,
                                                announcement = it.announcement,
                                                enabled = enabled,
                                                defaultEnabled = it.defaultEnabled,
                                            )
                                        } else {
                                            it
                                        }
                                    }
                                    scope.launch {
                                        runCatching {
                                            appModel.client.writeConfigValue(
                                                serverId,
                                                AppWriteConfigValueRequest(
                                                    keyPath = "features.${feature.name}",
                                                    valueJson = if (enabled) "true" else "false",
                                                    mergeStrategy = AppMergeStrategy.UPSERT,
                                                    filePath = null,
                                                    expectedVersion = null,
                                                ),
                                            )
                                        }.onFailure { error ->
                                            features = features.map {
                                                if (it.name == feature.name) {
                                                    ExperimentalFeature(
                                                        name = it.name,
                                                        stage = it.stage,
                                                        displayName = it.displayName,
                                                        description = it.description,
                                                        announcement = it.announcement,
                                                        enabled = previous,
                                                        defaultEnabled = it.defaultEnabled,
                                                    )
                                                } else {
                                                    it
                                                }
                                            }
                                            onError(error.message ?: "Failed to update experimental feature")
                                        }
                                    }
                                },
                                colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ComposerSkillsSheet(
    serverId: String,
    cwd: String,
    onDismiss: () -> Unit,
    onError: (String) -> Unit,
) {
    val appModel = LocalAppModel.current
    var skills by remember(serverId, cwd) { mutableStateOf<List<SkillMetadata>>(emptyList()) }
    var isLoading by remember(serverId, cwd) { mutableStateOf(true) }
    var reloadToken by remember(serverId, cwd) { mutableIntStateOf(0) }

    LaunchedEffect(serverId, cwd, reloadToken) {
        isLoading = true
        runCatching {
            appModel.client.listSkills(
                serverId,
                AppListSkillsRequest(
                    cwds = listOf(cwd),
                    forceReload = reloadToken > 0,
                ),
            )
        }.onSuccess { skillResults ->
            skills = skillResults.sortedBy { it.name.lowercase() }
        }.onFailure { error ->
            skills = emptyList()
            onError(error.message ?: "Failed to load skills")
        }
        isLoading = false
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxSize(fraction = 0.9f)
            .imePadding()
            .padding(16.dp),
    ) {
        SheetHeader(
            title = "Skills",
            leadingActionLabel = "Reload",
            onLeadingAction = { reloadToken += 1 },
            onDismiss = onDismiss,
        )
        Spacer(Modifier.height(12.dp))
        when {
            isLoading -> {
                Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = LitterTheme.accent, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                }
            }

            skills.isEmpty() -> {
                Text("No skills available for this workspace", color = LitterTheme.textMuted, fontSize = LitterTextStyle.code.scaled)
            }

            else -> {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(skills, key = { "${it.path.value}#${it.name}" }) { skill ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(skill.name, color = LitterTheme.textPrimary, fontSize = LitterTextStyle.body.scaled, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.weight(1f))
                                if (skill.enabled) {
                                    Text(
                                        "enabled",
                                        color = LitterTheme.accent,
                                        fontSize = LitterTextStyle.caption2.scaled,
                                        modifier = Modifier
                                            .background(LitterTheme.accent.copy(alpha = 0.14f), RoundedCornerShape(999.dp))
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                            Text(skill.description, color = LitterTheme.textSecondary, fontSize = LitterTextStyle.caption.scaled)
                            Text(skill.path.value, color = LitterTheme.textMuted, fontSize = LitterTextStyle.caption2.scaled)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetHeader(
    title: String,
    leadingActionLabel: String? = null,
    onLeadingAction: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leadingActionLabel != null && onLeadingAction != null) {
            TextButton(onClick = onLeadingAction) {
                Text(leadingActionLabel, color = LitterTheme.accent)
            }
        } else {
            Spacer(Modifier.width(64.dp))
        }
        Spacer(Modifier.weight(1f))
        Text(title, color = LitterTheme.textPrimary, fontSize = LitterTextStyle.headline.scaled, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onDismiss) {
            Text("Done", color = LitterTheme.accent)
        }
    }
    HorizontalDivider(color = LitterTheme.divider, modifier = Modifier.padding(top = 8.dp))
}
