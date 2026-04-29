package com.litter.android.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppThreadPermissionPreset
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.AgentRuntimeKind
import uniffi.codex_mobile_client.ModelInfo
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.threadPermissionPreset
import java.util.Locale

/**
 * Reusable model/reasoning/plan/permissions/fast-mode panel shared by the
 * conversation header (scoped to an existing thread) and the home composer
 * chip (pre-thread, `thread == null`). Mirrors iOS
 * `HeaderView.swift` + `ConversationOptionsSheet.swift`.
 *
 * When `thread` is null:
 *   - Permission toggle operates on `AppLaunchState` defaults (threadKey=null)
 *     so the choice carries through the next `startThread` call.
 *   - Plan toggle is hidden — the collaboration mode is a per-thread field
 *     with no pre-thread equivalent on Android.
 *
 * `onToggleMode` is invoked for Plan chip taps; pass null (or it will be
 * ignored because the chip is hidden) when there's no thread.
 */
@Composable
fun ModelSelectorPanel(
    thread: AppThreadSnapshot?,
    availableModels: List<ModelInfo>,
    onToggleMode: ((AppModeKind) -> Unit)? = null,
    fastMode: Boolean,
    onFastModeChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    showBackground: Boolean = true,
) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    var modelSearchQuery by rememberSaveable { mutableStateOf("") }
    val modelSearchIndex = remember(availableModels) {
        ModelSearchIndex(availableModels)
    }
    val filteredModels = remember(modelSearchIndex, modelSearchQuery) {
        modelSearchIndex.results(modelSearchQuery)
    }
    val selectedModel = launchState.selectedModel
        .takeIf { it.isNotBlank() }
        ?: thread?.model
        ?: availableModels.firstOrNull { it.isDefault }?.id
        ?: availableModels.firstOrNull()?.id
    val selectedRuntime = launchState.selectedAgentRuntimeKind
        ?: thread?.agentRuntimeKind
        ?: availableModels.firstOrNull { it.id == selectedModel || it.model == selectedModel }?.agentRuntimeKind
    val selectedModelDefinition by remember(selectedModel, selectedRuntime, availableModels) {
        derivedStateOf {
            availableModels.firstOrNull { it.matchesModelSelection(selectedModel, selectedRuntime) }
                ?: availableModels.firstOrNull { it.isDefault }
                ?: availableModels.firstOrNull()
        }
    }
    val supportedEfforts = remember(selectedModelDefinition) {
        selectedModelDefinition?.supportedReasoningEfforts ?: emptyList()
    }
    val selectedEffort = launchState.reasoningEffort
        .takeIf { pending ->
            pending.isNotBlank() &&
                supportedEfforts.any { effortLabel(it.reasoningEffort) == pending }
        }
        ?: thread?.reasoningEffort
            ?.takeIf { current ->
                supportedEfforts.any { effortLabel(it.reasoningEffort) == current }
            }
        ?: selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel)

    LaunchedEffect(launchState.reasoningEffort, selectedModelDefinition, supportedEfforts) {
        val pendingEffort = launchState.reasoningEffort.trim()
        val defaultEffort = selectedModelDefinition?.defaultReasoningEffort
        if (pendingEffort.isEmpty() || defaultEffort == null || supportedEfforts.isEmpty()) {
            return@LaunchedEffect
        }
        if (supportedEfforts.none { effortLabel(it.reasoningEffort) == pendingEffort }) {
            appModel.launchState.updateReasoningEffort(effortLabel(defaultEffort))
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .then(
                if (showBackground) {
                    Modifier.background(LitterTheme.codeBackground)
                } else {
                    Modifier
                },
            )
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            text = "Model",
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption2.scaled,
        )

        OutlinedTextField(
            value = modelSearchQuery,
            onValueChange = { modelSearchQuery = it },
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 6.dp, bottom = 4.dp),
            textStyle = TextStyle(
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.caption.scaled,
            ),
            singleLine = true,
            label = {
                Text(
                    "Search models",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption2.scaled,
                )
            },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = LitterTheme.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
            },
            trailingIcon = {
                if (modelSearchQuery.isNotEmpty()) {
                    IconButton(onClick = { modelSearchQuery = "" }) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Clear model search",
                            tint = LitterTheme.textSecondary,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
            },
        )

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(vertical = 4.dp),
        ) {
            items(filteredModels, key = { it.id }) { model ->
                val isSelected = model.matchesModelSelection(selectedModel, selectedRuntime)
                FilterChip(
                    selected = isSelected,
                    onClick = {
                        appModel.launchState.updateSelectedModel(
                            model.id,
                            agentRuntimeKind = model.agentRuntimeKind,
                        )
                        appModel.launchState.updateReasoningEffort(
                            effortLabel(model.defaultReasoningEffort),
                        )
                    },
                    leadingIcon = {
                        ModelRuntimeIcon(model.agentRuntimeKind)
                    },
                    label = {
                        Text(
                            text = model.displayName.ifBlank { model.id },
                            fontSize = LitterTextStyle.caption2.scaled,
                        )
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
            }
        }

        if (availableModels.isEmpty()) {
            Text(
                text = "Loading models...",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        } else if (filteredModels.isEmpty()) {
            Text(
                text = "No matching models",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Effort",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption2.scaled,
                )
                Spacer(Modifier.width(4.dp))
            }
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(supportedEfforts) { option ->
                    val effort = effortLabel(option.reasoningEffort)
                    FilterChip(
                        selected = selectedEffort == effort,
                        onClick = {
                            appModel.launchState.updateReasoningEffort(effort)
                        },
                        label = { Text(effort, fontSize = 10f.scaled) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent,
                            selectedLabelColor = Color.Black,
                        ),
                    )
                }
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            val threadKey = thread?.key
            if (thread != null && onToggleMode != null) {
                val isPlan = thread.collaborationMode == AppModeKind.PLAN
                FilterChip(
                    selected = isPlan,
                    onClick = {
                        val next = if (isPlan) AppModeKind.DEFAULT else AppModeKind.PLAN
                        onToggleMode(next)
                    },
                    label = { Text("Plan", fontSize = 10f.scaled) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
            }

            val currentPreset = run {
                val approval = appModel.launchState.approvalPolicyValue(threadKey)
                    ?: thread?.effectiveApprovalPolicy
                val sandbox = appModel.launchState.turnSandboxPolicy(threadKey)
                    ?: thread?.effectiveSandboxPolicy
                if (approval != null && sandbox != null) {
                    threadPermissionPreset(approval, sandbox)
                } else {
                    null
                }
            }
            val isFullAccess = currentPreset == AppThreadPermissionPreset.FULL_ACCESS
            FilterChip(
                selected = isFullAccess,
                onClick = {
                    if (isFullAccess) {
                        appModel.launchState.updateThreadPermissions(
                            threadKey,
                            approvalPolicy = "on-request",
                            sandboxMode = "workspace-write",
                        )
                    } else {
                        appModel.launchState.updateThreadPermissions(
                            threadKey,
                            approvalPolicy = "never",
                            sandboxMode = "danger-full-access",
                        )
                    }
                },
                leadingIcon = {
                    Icon(
                        imageVector = if (isFullAccess) Icons.Default.LockOpen else Icons.Default.Lock,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                    )
                },
                label = {
                    Text(
                        if (isFullAccess) "Full Access" else "Supervised",
                        fontSize = 10f.scaled,
                    )
                },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = LitterTheme.danger,
                    selectedLabelColor = Color.White,
                    selectedLeadingIconColor = Color.White,
                ),
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Fast mode",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
            )
            Switch(
                checked = fastMode,
                onCheckedChange = onFastModeChange,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = LitterTheme.accent,
                ),
            )
        }
    }
}

internal fun effortLabel(value: ReasoningEffort): String = when (value) {
    ReasoningEffort.NONE -> "none"
    ReasoningEffort.MINIMAL -> "minimal"
    ReasoningEffort.LOW -> "low"
    ReasoningEffort.MEDIUM -> "medium"
    ReasoningEffort.HIGH -> "high"
    ReasoningEffort.X_HIGH -> "xhigh"
}

private const val MaxModelSearchResults = 80

private class ModelSearchIndex(models: List<ModelInfo>) {
    private data class Row(
        val model: ModelInfo,
        val searchableText: String,
    )

    private val rows = models.map { model ->
        Row(
            model = model,
            searchableText = buildString {
                append(model.id)
                append('\n')
                append(model.model)
                append('\n')
                append(model.agentRuntimeKind.name)
                append('\n')
                append(model.displayName)
                append('\n')
                append(model.description)
            }.lowercase(Locale.ROOT),
        )
    }

    fun results(query: String): List<ModelInfo> {
        val normalizedQuery = query.trim().lowercase(Locale.ROOT)
        if (normalizedQuery.isEmpty()) {
            return rows.asSequence()
                .take(MaxModelSearchResults)
                .map { it.model }
                .toList()
        }

        val matches = ArrayList<ModelInfo>(minOf(MaxModelSearchResults, rows.size))
        for (row in rows) {
            if (row.searchableText.contains(normalizedQuery)) {
                matches += row.model
                if (matches.size == MaxModelSearchResults) {
                    break
                }
            }
        }
        return matches
    }
}

internal fun ModelInfo.matchesModelSelection(
    selection: String?,
    runtimeKind: AgentRuntimeKind? = null,
): Boolean {
    val trimmed = selection?.trim().orEmpty()
    if (trimmed.isEmpty()) return false
    if (runtimeKind != null && agentRuntimeKind != runtimeKind) return false
    return id == trimmed || model == trimmed
}

@Composable
private fun ModelRuntimeIcon(kind: AgentRuntimeKind) {
    Image(
        painter = painterResource(kind.runtimeDrawable),
        contentDescription = kind.runtimeLabel,
        modifier = Modifier.size(16.dp),
    )
}
