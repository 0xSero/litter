package com.litter.android.ui.conversation

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.accentColor
import com.litter.android.state.displayModelLabel
import com.litter.android.state.resolvedModel
import com.litter.android.state.statusColor
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.modelPickerDisplayName
import com.litter.android.ui.common.matchesModelSelection
import com.litter.android.ui.common.reportsEffectiveThreadPermissions
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ThreadKey

/**
 * Top bar showing model, reasoning, status dot, cwd.
 * Inline model selector expands on tap.
 */
@Composable
fun HeaderBar(
    thread: AppThreadSnapshot?,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
    showModelSelector: Boolean,
    onToggleModelSelector: () -> Unit,
    onReloadError: ((String) -> Unit)? = null,
    transparentBackground: Boolean = false,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val launchState by appModel.launchState.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val server = remember(snapshot, thread) {
        thread?.let { t -> snapshot?.servers?.find { it.serverId == t.key.serverId } }
    }
    val pendingModelId = launchState.selectedModel.trim()
    val pendingRuntime = launchState.selectedAgentRuntimeKind
    val pendingModelLabel = server?.availableModels
        ?.firstOrNull { it.matchesModelSelection(pendingModelId, pendingRuntime) }
        ?.modelPickerDisplayName()
        ?.ifBlank { pendingModelId }
        ?: pendingModelId.ifBlank { null }
    val currentModelId = pendingModelId.ifBlank {
        (thread?.model ?: thread?.info?.model ?: "").trim()
    }
    val currentRuntime = pendingRuntime ?: thread?.agentRuntimeKind
    val selectedModelDefinition = remember(server?.availableModels, currentModelId, currentRuntime) {
        server?.availableModels?.firstOrNull { it.matchesModelSelection(currentModelId, currentRuntime) }
            ?: server?.availableModels?.firstOrNull { it.isDefault }
            ?: server?.availableModels?.firstOrNull()
    }
    val reasoningLabel = remember(launchState.reasoningEffort, thread?.reasoningEffort, selectedModelDefinition) {
        val pendingReasoning = launchState.reasoningEffort.trim()
        if (pendingReasoning.isNotEmpty()) {
            pendingReasoning
        } else {
            val threadReasoning = thread?.reasoningEffort?.trim().orEmpty()
            if (threadReasoning.isNotEmpty()) {
                threadReasoning
            } else if (selectedModelDefinition?.supportedReasoningEfforts?.isEmpty() == true) {
                ""
            } else {
                selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabelLocal) ?: "default"
            }
        }
    }
    val modelLabel = remember(pendingModelLabel, thread?.displayModelLabel) {
        (pendingModelLabel ?: thread?.displayModelLabel).orEmpty().ifBlank { "litter" }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (!transparentBackground) Modifier.background(LitterTheme.surface) else Modifier),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }

            // Status dot
            val health = server?.health ?: AppServerHealth.UNKNOWN
            val statusColor = server?.statusColor ?: health.accentColor
            val shouldPulse = health == AppServerHealth.CONNECTING || health == AppServerHealth.UNRESPONSIVE
            val dotAlpha = if (shouldPulse) {
                val infiniteTransition = rememberInfiniteTransition(label = "statusDotPulse")
                infiniteTransition.animateFloat(
                    initialValue = 0.3f,
                    targetValue = 1.0f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(durationMillis = 1000),
                        repeatMode = RepeatMode.Reverse,
                    ),
                    label = "statusDotAlpha",
                ).value
            } else {
                1.0f
            }
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(statusColor.copy(alpha = dotAlpha)),
            )
            Spacer(Modifier.width(8.dp))

            // Model + reasoning label (tappable)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable { onToggleModelSelector() },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = modelLabel,
                        color = LitterTheme.textPrimary,
                        fontSize = LitterTextStyle.footnote.scaled,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (HeaderOverrides.pendingFastMode) {
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "\u26A1",
                            color = LitterTheme.warning,
                            fontSize = LitterTextStyle.caption2.scaled,
                        )
                    }
                    if (reasoningLabel.isNotBlank()) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = reasoningLabel,
                            color = LitterTheme.textSecondary,
                            fontSize = LitterTextStyle.caption.scaled,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = "Open model selector",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(14.dp),
                    )
                }
                val cwd = thread?.info?.cwd
                if (cwd != null) {
                    val abbreviated = cwd.replace(Regex("^/home/[^/]+"), "~")
                        .replace(Regex("^/Users/[^/]+"), "~")
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = abbreviated,
                            color = LitterTheme.textMuted,
                            fontSize = 10f.scaled,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (thread?.collaborationMode == AppModeKind.PLAN) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "plan",
                                color = Color.Black,
                                fontSize = 10f.scaled,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                                modifier = Modifier
                                    .background(
                                        LitterTheme.accent,
                                        RoundedCornerShape(999.dp),
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                        // Permission-preset chip: show a danger-tinted `lock.open`
                        // when this thread is running at full-access (approval =
                        // never + sandbox = danger-full-access). Mirrors iOS
                        // HeaderView.swift:74-78 `headerPermissionPreset == .fullAccess`.
                        val permissionPreset = thread
                            ?.takeIf { it.agentRuntimeKind.reportsEffectiveThreadPermissions }
                            ?.let { t ->
                                val approval = appModel.launchState.approvalPolicyValue(t.key)
                                    ?: t.effectiveApprovalPolicy
                                val sandbox = appModel.launchState.turnSandboxPolicy(t.key)
                                    ?: t.effectiveSandboxPolicy
                                uniffi.codex_mobile_client.threadPermissionPreset(approval, sandbox)
                            }
                        if (permissionPreset ==
                            uniffi.codex_mobile_client.AppThreadPermissionPreset.FULL_ACCESS) {
                            Spacer(Modifier.width(6.dp))
                            Icon(
                                imageVector = Icons.Default.LockOpen,
                                contentDescription = "Full access permissions",
                                tint = LitterTheme.danger,
                                modifier = Modifier.size(10.dp),
                            )
                        }
                    }
                }
            }

            // Reload button
            var isReloading by remember { mutableStateOf(false) }
            IconButton(
                onClick = {
                    if (thread == null || isReloading) return@IconButton
                    scope.launch {
                        isReloading = true
                        try {
                            if (server != null && !server.isLocal && server.account == null) {
                                val authUrl = appModel.client.startRemoteSshOauthLogin(
                                    thread.key.serverId,
                                )
                                CustomTabsIntent.Builder()
                                    .setShowTitle(true)
                                    .build()
                                    .launchUrl(context, Uri.parse(authUrl))
                                return@launch
                            }
                            val nextKey = appModel.refreshThreadIncludingTurns(thread.key)
                            appModel.store.setActiveThread(nextKey)
                        } catch (e: Exception) {
                            onReloadError?.invoke(e.message ?: "Failed to reload conversation")
                        } finally {
                            isReloading = false
                        }
                    }
                },
                enabled = !isReloading,
                modifier = Modifier.size(32.dp),
            ) {
                if (isReloading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = "Reload",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }

            // Info button
            if (onInfo != null) {
                IconButton(
                    onClick = onInfo,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        Icons.Outlined.Info,
                        contentDescription = "Info",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        // Inline model selector — shared panel lives in
        // `com.litter.android.ui.common.ModelSelectorPanel`; the home
        // composer's HomeModelChip uses the same panel inside a
        // ModalBottomSheet.
        AnimatedVisibility(
            visible = showModelSelector,
            enter = expandVertically(),
            exit = shrinkVertically(),
        ) {
            com.litter.android.ui.common.ModelSelectorPanel(
                thread = thread,
                availableModels = server?.availableModels ?: emptyList(),
                onToggleMode = { mode ->
                    thread?.let { t ->
                        scope.launch {
                            try {
                                appModel.store.setThreadCollaborationMode(t.key, mode)
                            } catch (_: Exception) {}
                        }
                    }
                },
                fastMode = HeaderOverrides.pendingFastMode,
                onFastModeChange = { HeaderOverrides.pendingFastMode = it },
                showBackground = false,
            )
        }
    }
}

/**
 * Holds the fast-mode override selected in the header.
 * Launch model/effort state lives in [AppLaunchState].
 */
object HeaderOverrides {
    var pendingFastMode by mutableStateOf(false)
}

private fun effortLabelLocal(value: uniffi.codex_mobile_client.ReasoningEffort): String =
    when (value) {
        uniffi.codex_mobile_client.ReasoningEffort.NONE -> "none"
        uniffi.codex_mobile_client.ReasoningEffort.MINIMAL -> "minimal"
        uniffi.codex_mobile_client.ReasoningEffort.LOW -> "low"
        uniffi.codex_mobile_client.ReasoningEffort.MEDIUM -> "medium"
        uniffi.codex_mobile_client.ReasoningEffort.HIGH -> "high"
        uniffi.codex_mobile_client.ReasoningEffort.X_HIGH -> "xhigh"
        uniffi.codex_mobile_client.ReasoningEffort.MAX -> "max"
        uniffi.codex_mobile_client.ReasoningEffort.ULTRA -> "ultra"
    }
