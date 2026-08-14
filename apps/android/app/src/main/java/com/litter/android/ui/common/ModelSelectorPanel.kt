package com.litter.android.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.state.ampReasoningEffortLocked
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppThreadPermissionPreset
import uniffi.codex_mobile_client.AppThreadSnapshot
import com.litter.android.ui.common.AgentRuntimeKind
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
    catalogLoaded: Boolean = false,
    catalogError: String? = null,
    onRetryModels: () -> Unit = {},
    onToggleMode: ((AppModeKind) -> Unit)? = null,
    fastMode: Boolean,
    onFastModeChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    showBackground: Boolean = true,
) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    var modelSearchQuery by rememberSaveable { mutableStateOf("") }
    val visibleModels = remember(availableModels) {
        availableModels.filter { it.isVisibleModelOption() }
    }
    val catalogMessage = catalogError
        ?: if (!catalogLoaded) "Loading models..."
        else if (visibleModels.isEmpty()) "No models available"
        else null
    val fallbackModel = visibleModels.firstOrNull { it.agentRuntimeKind == "codex" && it.isDefault }
        ?: visibleModels.firstOrNull { it.isDefault }
        ?: visibleModels.firstOrNull()
    val pendingModel = launchState.selectedModel.takeIf { it.isNotBlank() }
    val pendingRuntime = launchState.selectedAgentRuntimeKind
    val pendingModelDefinition = pendingModel?.let { model ->
        visibleModels.firstOrNull { it.matchesModelSelection(model, pendingRuntime) }
    }
    val selectedModel = launchState.selectedModel
        .takeIf { pendingModelDefinition != null }
        ?: thread?.model
        ?: fallbackModel?.id
    val selectedRuntime = launchState.selectedAgentRuntimeKind
        .takeIf { pendingModelDefinition != null }
        ?: thread?.agentRuntimeKind
        ?: visibleModels.firstOrNull { it.id == selectedModel || it.model == selectedModel }?.agentRuntimeKind
    val selectedRuntimeSupportsPermissionOverrides =
        selectedRuntime?.supportsThreadPermissionOverrides ?: true
    val runtimeBuckets = remember(visibleModels) {
        visibleModels
            .groupBy { it.agentRuntimeKind }
            .map { (kind, models) -> RuntimeModelBucket(kind = kind, count = models.size) }
            .sortedBy { it.kind.runtimeSortIndex }
    }
    var selectedRuntimeFilterName by rememberSaveable { mutableStateOf<String?>(null) }
    var initializedRuntimeFilter by rememberSaveable { mutableStateOf(false) }
    val selectedRuntimeFilter = runtimeBuckets.firstOrNull {
        it.kind == selectedRuntimeFilterName
    }?.kind

    LaunchedEffect(thread, pendingModel, pendingRuntime, fallbackModel) {
        if (thread == null && pendingModel != null && pendingModelDefinition == null && fallbackModel != null) {
            appModel.launchState.updateSelectedModel(
                fallbackModel.id,
                agentRuntimeKind = fallbackModel.agentRuntimeKind,
            )
            appModel.launchState.updateReasoningEffort(null)
        }
    }

    LaunchedEffect(selectedRuntime, runtimeBuckets) {
        if (!initializedRuntimeFilter) {
            if (selectedRuntime != null && runtimeBuckets.any { it.kind == selectedRuntime }) {
                selectedRuntimeFilterName = selectedRuntime
            }
            initializedRuntimeFilter = true
        } else if (
            selectedRuntimeFilterName != null &&
            runtimeBuckets.none { it.kind == selectedRuntimeFilterName }
        ) {
            selectedRuntimeFilterName = null
        }
    }

    val runtimeScopedModels = remember(visibleModels, selectedRuntimeFilter) {
        selectedRuntimeFilter?.let { runtime ->
            visibleModels.filter { it.agentRuntimeKind == runtime }
        } ?: visibleModels
    }
    val modelSearchIndex = remember(runtimeScopedModels) {
        ModelSearchIndex(runtimeScopedModels)
    }
    val filteredModels = remember(modelSearchIndex, modelSearchQuery) {
        modelSearchIndex.results(modelSearchQuery)
    }
    val providerGroups = remember(filteredModels) {
        modelProviderGroups(filteredModels)
    }
    val selectedModelDefinition by remember(selectedModel, selectedRuntime, visibleModels) {
        derivedStateOf {
            visibleModels.firstOrNull { it.matchesModelSelection(selectedModel, selectedRuntime) }
                ?: visibleModels.firstOrNull { it.isDefault }
                ?: visibleModels.firstOrNull()
        }
    }
    val selectedModelIsAmp = selectedModelDefinition?.agentRuntimeKind == "amp"
    val ampEffortLocked = selectedModelIsAmp && thread?.ampReasoningEffortLocked == true
    val supportedEfforts = remember(selectedModelDefinition, ampEffortLocked) {
        if (ampEffortLocked) {
            emptyList()
        } else {
            selectedModelDefinition?.supportedReasoningEfforts ?: emptyList()
        }
    }
    val selectedEffort = if (supportedEfforts.isEmpty()) {
        null
    } else {
        launchState.reasoningEffort
            .takeIf { pending ->
                pending.isNotBlank() &&
                    supportedEfforts.any { effortLabel(it.reasoningEffort) == pending }
            }
            ?: thread?.reasoningEffort
                ?.takeIf { current ->
                    supportedEfforts.any { effortLabel(it.reasoningEffort) == current }
                }
            ?: selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel)
    }

    LaunchedEffect(launchState.reasoningEffort, selectedModelDefinition, supportedEfforts, ampEffortLocked) {
        val pendingEffort = launchState.reasoningEffort.trim()
        val defaultEffort = selectedModelDefinition?.defaultReasoningEffort
        if (pendingEffort.isEmpty()) {
            return@LaunchedEffect
        }
        if (ampEffortLocked) {
            appModel.launchState.updateReasoningEffort(null)
            return@LaunchedEffect
        }
        if (supportedEfforts.isEmpty()) {
            appModel.launchState.updateReasoningEffort(null)
            return@LaunchedEffect
        }
        if (defaultEffort == null) {
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

        if (runtimeBuckets.size > 1) {
            LazyRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(top = 2.dp, bottom = 4.dp),
            ) {
                item(key = "all") {
                    RuntimeFilterChip(
                        label = "All",
                        count = visibleModels.size,
                        selected = selectedRuntimeFilterName == null,
                        onClick = { selectedRuntimeFilterName = null },
                    )
                }
                items(runtimeBuckets, key = { it.kind }) { bucket ->
                    RuntimeFilterChip(
                        label = bucket.kind.runtimeLabel,
                        count = bucket.count,
                        selected = selectedRuntimeFilter == bucket.kind,
                        onClick = { selectedRuntimeFilterName = bucket.kind },
                        leadingIcon = { ModelRuntimeIcon(bucket.kind) },
                    )
                }
            }
        }

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

        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 320.dp)
                .padding(vertical = 4.dp),
        ) {
            providerGroups.forEach { group ->
                item(key = group.key) {
                    Text(
                        text = group.name.uppercase(Locale.ROOT),
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.caption2.scaled,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(top = 8.dp, bottom = 1.dp),
                    )
                }
                items(group.models, key = { "${it.agentRuntimeKind}:${it.id}" }) { model ->
                    val isSelected = model.matchesModelSelection(selectedModel, selectedRuntime)
                    ModelOptionRow(
                        model = model,
                        selected = isSelected,
                        onClick = {
                            appModel.launchState.updateSelectedModel(
                                model.id,
                                agentRuntimeKind = model.agentRuntimeKind,
                            )
                            appModel.launchState.updateReasoningEffort(
                                if (ampEffortLocked && model.agentRuntimeKind == "amp") {
                                    null
                                } else {
                                    model.defaultReasoningEffortSelection()
                                },
                            )
                        },
                    )
                }
            }
        }

        if (catalogMessage != null) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = catalogMessage,
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption2.scaled,
                    maxLines = 3,
                )
                if (catalogError != null) {
                    Text(
                        text = "Retry",
                        color = LitterTheme.accent,
                        fontSize = LitterTextStyle.caption2.scaled,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.clickable(onClick = onRetryModels).padding(vertical = 4.dp),
                    )
                }
            }
        }
        if (visibleModels.isNotEmpty() && filteredModels.isEmpty()) {
            Text(
                text = "No matching models",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }

        if (ampEffortLocked) {
            Text(
                text = "Reasoning effort is locked after the first message.",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
            )
        } else if (supportedEfforts.isNotEmpty()) {
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

            if (selectedRuntimeSupportsPermissionOverrides) {
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
            }
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
    ReasoningEffort.MAX -> "max"
    ReasoningEffort.ULTRA -> "ultra"
}

private fun ModelInfo.defaultReasoningEffortSelection(): String? =
    if (supportedReasoningEfforts.isEmpty()) null else effortLabel(defaultReasoningEffort)

private val AmpVisibleModes = setOf("low", "medium", "high", "ultra")

private fun normalizedAmpModeName(value: String): String =
    value.trim()
        .lowercase(Locale.ROOT)
        .removePrefix("amp/")
        .removePrefix("amp:")

private fun ModelInfo.ampModeName(): String =
    normalizedAmpModeName(id)
        .ifEmpty {
            normalizedAmpModeName(model)
        }

internal fun ModelInfo.modelPickerDisplayName(): String =
    if (agentRuntimeKind == "amp") {
        ampModeName().ifEmpty { displayName.ifBlank { id } }
    } else {
        displayName.ifBlank { id }
    }

private fun ModelInfo.isVisibleModelOption(): Boolean =
    agentRuntimeKind != "amp" || ampModeName() in AmpVisibleModes

private data class RuntimeModelBucket(
    val kind: AgentRuntimeKind,
    val count: Int,
)

private data class ModelProviderGroup(
    val key: String,
    val name: String,
    val models: List<ModelInfo>,
)

private fun ModelInfo.providerName(): String {
    val provider = providerId ?: return agentRuntimeKind.runtimeLabel
    return when (provider.lowercase(Locale.ROOT)) {
        "ai21" -> "AI21"
        "arcee-ai" -> "Arcee AI"
        "bytedance-seed" -> "ByteDance"
        "deepseek" -> "DeepSeek"
        "meta-llama" -> "Meta"
        "mistralai" -> "Mistral AI"
        "moonshotai" -> "Moonshot AI"
        "openai" -> "OpenAI"
        "openrouter" -> "OpenRouter"
        "x-ai" -> "xAI"
        else -> provider.split('-', '_').joinToString(" ") { it.replaceFirstChar(Char::uppercase) }
    }
}

private fun modelProviderGroups(models: List<ModelInfo>): List<ModelProviderGroup> =
    models
        .groupBy { model ->
            val provider = model.providerId?.takeIf(String::isNotEmpty)?.let { "provider:$it" }
                ?: "runtime"
            "${model.agentRuntimeKind}:$provider"
        }
        .map { (key, entries) ->
            val model = entries.first()
            ModelProviderGroup(
                key,
                if (model.providerId.isNullOrEmpty()) model.agentRuntimeKind.runtimeLabel
                else "${model.agentRuntimeKind.runtimeLabel} · ${model.providerName()}",
                entries,
            )
        }
        .sortedBy { it.name.lowercase(Locale.ROOT) }

private fun ModelInfo.modelNameWithinProvider(): String {
    var name = modelPickerDisplayName()
    val catalog = id.substringBefore('/', "")
    if (catalog.isNotEmpty() && name.endsWith(" ($catalog)", ignoreCase = true)) {
        name = name.dropLast(catalog.length + 3)
    }
    val provider = providerId
    if (!provider.isNullOrEmpty() && name.startsWith("$provider/")) {
        name = name.removePrefix("$provider/")
    }
    return name
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
                append(model.agentRuntimeKind)
                append('\n')
                append(model.modelPickerDisplayName())
                append('\n')
                append(model.description)
            }.lowercase(Locale.ROOT),
        )
    }

    fun results(query: String): List<ModelInfo> {
        val normalizedQuery = query.trim().lowercase(Locale.ROOT)
        if (normalizedQuery.isEmpty()) {
            return rows.map { it.model }
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
private fun RuntimeFilterChip(
    label: String,
    count: Int,
    selected: Boolean,
    onClick: () -> Unit,
    leadingIcon: (@Composable () -> Unit)? = null,
) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        leadingIcon = leadingIcon,
        label = {
            Text(
                text = "$label $count",
                fontSize = LitterTextStyle.caption2.scaled,
                maxLines = 1,
            )
        },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = LitterTheme.accent,
            selectedLabelColor = Color.Black,
        ),
    )
}

@Composable
private fun ModelOptionRow(
    model: ModelInfo,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    val background = if (selected) {
        LitterTheme.accent.copy(alpha = 0.14f)
    } else {
        LitterTheme.surface.copy(alpha = 0.55f)
    }
    val borderColor = if (selected) {
        LitterTheme.accent
    } else {
        LitterTheme.textMuted.copy(alpha = 0.32f)
    }
    val title = model.modelNameWithinProvider()
    val detail = model.description
        .takeIf { it.isNotBlank() }
        ?: model.model.takeIf { it.isNotBlank() && it != title && it != model.id }
    val runtimeLabel = model.agentRuntimeKind.runtimeLabel
        .takeUnless { model.agentRuntimeKind == "amp" }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(background)
            .border(0.8.dp, borderColor, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        ModelRuntimeIcon(model.agentRuntimeKind)
        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = title,
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.caption.scaled,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (runtimeLabel != null) {
                    Text(
                        text = runtimeLabel,
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.caption2.scaled,
                        maxLines = 1,
                    )
                }
            }
            if (detail != null) {
                Text(
                    text = detail,
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.caption2.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (selected) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = "Selected model",
                tint = LitterTheme.accent,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun ModelRuntimeIcon(kind: AgentRuntimeKind) {
    AgentIconView(kind = kind, sizeDp = 16)
}
