package com.litter.android.ui.common

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.state.ampReasoningEffortLocked
import com.litter.android.state.supportedDefaultReasoningEffort
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppThreadPermissionPreset
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ModelEntryKind
import uniffi.codex_mobile_client.ModelInfo
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.threadPermissionPreset
import java.util.Locale

/**
 * Model picker shared by the conversation composer (scoped to an existing
 * thread) and the home composer chip (pre-thread, `thread == null`).
 * Mirrors iOS `ModelPickerView.swift`:
 *
 *  - root: current selection, recents, one row per harness, then options
 *    (reasoning effort, fast mode, plan, access);
 *  - a harness page lists its modes, plugin modes, or models grouped by
 *    provider (large catalogs start folded);
 *  - search covers every harness and provider.
 *
 * Mode vs model classification, picker labels and provider labels come
 * from Rust (`ModelInfo.entryKind` / `pickerName` / `providerLabel`).
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
    val context = LocalContext.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var openHarness by rememberSaveable { mutableStateOf<String?>(null) }
    var recents by remember { mutableStateOf(ModelPickerRecents.load(context)) }
    val catalog = remember(availableModels) { ModelPickerCatalog(availableModels) }
    val visibleModels = catalog.visible
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

    LaunchedEffect(thread, pendingModel, pendingRuntime, fallbackModel) {
        if (thread == null && pendingModel != null && pendingModelDefinition == null && fallbackModel != null) {
            appModel.launchState.updateSelectedModel(
                fallbackModel.id,
                agentRuntimeKind = fallbackModel.agentRuntimeKind,
            )
            appModel.launchState.updateReasoningEffort(null)
        }
    }

    val selectedModelDefinition by remember(selectedModel, selectedRuntime, visibleModels) {
        derivedStateOf {
            visibleModels.firstOrNull { it.matchesModelSelection(selectedModel, selectedRuntime) }
                ?: visibleModels.firstOrNull { it.isDefault }
                ?: visibleModels.firstOrNull()
        }
    }
    val selectedIsMode = selectedModelDefinition?.isModeEntry() == true
    val ampEffortLocked = selectedIsMode && thread?.ampReasoningEffortLocked == true
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
            ?: selectedModelDefinition?.supportedDefaultReasoningEffort?.let(::effortLabel)
    }

    LaunchedEffect(launchState.reasoningEffort, selectedModelDefinition, supportedEfforts, ampEffortLocked) {
        val pendingEffort = launchState.reasoningEffort.trim()
        val defaultEffort = selectedModelDefinition?.supportedDefaultReasoningEffort
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
        if (supportedEfforts.none { effortLabel(it.reasoningEffort) == pendingEffort }) {
            appModel.launchState.updateReasoningEffort(defaultEffort?.let(::effortLabel))
        }
    }

    val isSelected: (ModelInfo) -> Boolean = { model ->
        model.matchesModelSelection(selectedModel, selectedRuntime)
    }
    val onSelect: (ModelInfo) -> Unit = { model ->
        appModel.launchState.updateSelectedModel(
            model.id,
            agentRuntimeKind = model.agentRuntimeKind,
        )
        appModel.launchState.updateReasoningEffort(
            if (ampEffortLocked && model.isModeEntry()) {
                null
            } else {
                model.defaultReasoningEffortSelection()
            },
        )
        recents = ModelPickerRecents.record(context, model)
        query = ""
        openHarness = null
    }

    val harness = openHarness?.let(catalog::harness)
    val trimmedQuery = query.trim()
    val searchResults = remember(catalog, trimmedQuery, harness?.kind) {
        catalog.search(trimmedQuery, harness?.kind)
    }
    val currentModel = selectedModelDefinition
        ?.takeIf { it.matchesModelSelection(selectedModel, selectedRuntime) }
    val recentModels = remember(recents, catalog, currentModel) {
        recents
            .filter { it != currentModel?.scopedId() }
            .mapNotNull(catalog::model)
            .take(4)
    }
    var expandedProviders by remember(openHarness) {
        mutableStateOf(
            harness?.providers
                ?.filter { group -> group.models.any(isSelected) }
                ?.map { it.id }
                ?.toSet()
                ?: emptySet(),
        )
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
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp),
        ) {
            if (harness != null) {
                IconButton(onClick = {
                    openHarness = null
                    query = ""
                }) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back to harnesses",
                        tint = LitterTheme.textPrimary,
                    )
                }
                AgentIconView(kind = harness.kind, sizeDp = 20)
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text = harness?.label ?: "Model",
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                fontWeight = FontWeight.SemiBold,
            )
        }

        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 4.dp, bottom = 8.dp),
            textStyle = TextStyle(
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
            ),
            singleLine = true,
            shape = RoundedCornerShape(12.dp),
            placeholder = {
                Text(
                    if (harness != null) "Search ${harness.label}" else "Search all models",
                    color = LitterTheme.textMuted,
                    fontSize = LitterTextStyle.body.scaled,
                )
            },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Default.Search,
                    contentDescription = null,
                    tint = LitterTheme.textMuted,
                    modifier = Modifier.size(18.dp),
                )
            },
            trailingIcon = {
                if (query.isNotEmpty()) {
                    IconButton(onClick = { query = "" }) {
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
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 560.dp),
        ) {
            if (trimmedQuery.isNotEmpty()) {
                searchResultItems(searchResults, trimmedQuery, isSelected, onSelect)
            } else if (harness != null) {
                harnessItems(
                    harness = harness,
                    expanded = expandedProviders,
                    onToggle = { id ->
                        expandedProviders = if (id in expandedProviders) {
                            expandedProviders - id
                        } else {
                            expandedProviders + id
                        }
                    },
                    isSelected = isSelected,
                    onSelect = onSelect,
                )
            } else {
                if (catalogMessage != null) {
                    item(key = "notice") {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                        ) {
                            Text(
                                text = catalogMessage,
                                color = LitterTheme.textSecondary,
                                fontSize = LitterTextStyle.footnote.scaled,
                                maxLines = 3,
                            )
                            if (catalogError != null) {
                                Text(
                                    text = "Retry",
                                    color = LitterTheme.accent,
                                    fontSize = LitterTextStyle.footnote.scaled,
                                    fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier
                                        .clickable(onClick = onRetryModels)
                                        .padding(vertical = 6.dp),
                                )
                            }
                        }
                    }
                }
                if (currentModel != null) {
                    item(key = "current-header") { PickerSectionHeader("Current") }
                    item(key = "current") {
                        PickerCard {
                            PickerModelRow(
                                model = currentModel,
                                subtitle = catalog.subtitle(currentModel),
                                showsIcon = true,
                                selected = true,
                                onClick = { openHarness = currentModel.agentRuntimeKind },
                            )
                        }
                    }
                }
                if (recentModels.isNotEmpty()) {
                    item(key = "recent-header") { PickerSectionHeader("Recent") }
                    item(key = "recent") {
                        PickerCard {
                            recentModels.forEachIndexed { index, model ->
                                if (index > 0) PickerDivider()
                                PickerModelRow(
                                    model = model,
                                    subtitle = catalog.subtitle(model),
                                    showsIcon = true,
                                    selected = false,
                                    onClick = { onSelect(model) },
                                )
                            }
                        }
                    }
                }
                if (catalog.harnesses.isNotEmpty()) {
                    item(key = "harness-header") { PickerSectionHeader("Harnesses") }
                    item(key = "harnesses") {
                        PickerCard {
                            catalog.harnesses.forEachIndexed { index, entry ->
                                if (index > 0) PickerDivider()
                                PickerHarnessRow(
                                    harness = entry,
                                    isCurrent = currentModel?.agentRuntimeKind == entry.kind,
                                    onClick = { openHarness = entry.kind },
                                )
                            }
                        }
                    }
                }
                item(key = "options-header") { PickerSectionHeader("Options") }
                item(key = "options") {
                    PickerCard {
                        if (ampEffortLocked) {
                            PickerValueRow(label = "Reasoning", value = "Locked after first message")
                            PickerDivider()
                        } else if (supportedEfforts.isNotEmpty()) {
                            var menuOpen by remember { mutableStateOf(false) }
                            Box {
                                PickerValueRow(
                                    label = "Reasoning",
                                    value = selectedEffort?.replaceFirstChar { it.titlecase(Locale.ROOT) } ?: "Default",
                                    onClick = { menuOpen = true },
                                )
                                DropdownMenu(
                                    expanded = menuOpen,
                                    onDismissRequest = { menuOpen = false },
                                ) {
                                    supportedEfforts.forEach { option ->
                                        val effort = effortLabel(option.reasoningEffort)
                                        DropdownMenuItem(
                                            text = {
                                                Text(effort.replaceFirstChar { it.titlecase(Locale.ROOT) })
                                            },
                                            trailingIcon = {
                                                if (effort == selectedEffort) {
                                                    Icon(
                                                        imageVector = Icons.Default.Check,
                                                        contentDescription = null,
                                                        modifier = Modifier.size(16.dp),
                                                    )
                                                }
                                            },
                                            onClick = {
                                                appModel.launchState.updateReasoningEffort(effort)
                                                menuOpen = false
                                            },
                                        )
                                    }
                                }
                            }
                            PickerDivider()
                        }
                        PickerSwitchRow(label = "Fast mode", checked = fastMode, onCheckedChange = onFastModeChange)
                        val threadKey = thread?.key
                        if (thread != null && onToggleMode != null) {
                            val isPlan = thread.collaborationMode == AppModeKind.PLAN
                            PickerDivider()
                            PickerSwitchRow(
                                label = "Plan mode",
                                checked = isPlan,
                                onCheckedChange = { enabled ->
                                    onToggleMode(if (enabled) AppModeKind.PLAN else AppModeKind.DEFAULT)
                                },
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
                            PickerDivider()
                            PickerSwitchRow(
                                label = "Full access",
                                checked = isFullAccess,
                                checkedTrackColor = LitterTheme.danger,
                                onCheckedChange = { enabled ->
                                    if (enabled) {
                                        appModel.launchState.updateThreadPermissions(
                                            threadKey,
                                            approvalPolicy = "never",
                                            sandboxMode = "danger-full-access",
                                        )
                                    } else {
                                        appModel.launchState.updateThreadPermissions(
                                            threadKey,
                                            approvalPolicy = "on-request",
                                            sandboxMode = "workspace-write",
                                        )
                                    }
                                },
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun LazyListScope.harnessItems(
    harness: PickerHarness,
    expanded: Set<String>,
    onToggle: (String) -> Unit,
    isSelected: (ModelInfo) -> Boolean,
    onSelect: (ModelInfo) -> Unit,
) {
    if (harness.modes.isNotEmpty()) {
        item(key = "modes-header") { PickerSectionHeader("Modes") }
        item(key = "modes") {
            PickerCard {
                harness.modes.forEachIndexed { index, model ->
                    if (index > 0) PickerDivider()
                    PickerModelRow(model, model.description, false, isSelected(model)) { onSelect(model) }
                }
            }
        }
    }
    if (harness.pluginModes.isNotEmpty()) {
        item(key = "plugin-modes-header") { PickerSectionHeader("Plugin modes") }
        item(key = "plugin-modes") {
            PickerCard {
                harness.pluginModes.forEachIndexed { index, model ->
                    if (index > 0) PickerDivider()
                    PickerModelRow(model, null, false, isSelected(model)) { onSelect(model) }
                }
            }
        }
    }
    val collapses = harness.providers.size > 1 && harness.modelCount > 30
    harness.providers.forEach { group ->
        val open = !collapses || group.id in expanded
        item(key = "header:${group.id}") {
            if (collapses) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .clickable { onToggle(group.id) }
                        .padding(horizontal = 4.dp),
                ) {
                    Text(
                        text = group.title ?: "Other",
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.footnote.scaled,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.weight(1f),
                    )
                    if (group.models.any(isSelected)) {
                        Box(
                            Modifier
                                .size(6.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(LitterTheme.accent),
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(
                        text = group.models.size.toString(),
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.footnote.scaled,
                    )
                    Icon(
                        imageVector = if (open) Icons.Default.KeyboardArrowDown else Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = if (open) "Collapse" else "Expand",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            } else {
                val title = group.title
                    ?: if (harness.providers.size > 1 || harness.modes.isNotEmpty() || harness.pluginModes.isNotEmpty()) "Models" else null
                if (title != null) PickerSectionHeader(title) else Spacer(Modifier.width(0.dp))
            }
        }
        if (open) {
            items(group.models, key = { "${group.id}|${it.id}" }) { model ->
                PickerCardRow(
                    first = model === group.models.first(),
                    last = model === group.models.last(),
                ) {
                    PickerModelRow(model, model.description, false, isSelected(model)) { onSelect(model) }
                }
            }
        }
    }
}

private fun LazyListScope.searchResultItems(
    results: PickerSearchResults,
    query: String,
    isSelected: (ModelInfo) -> Boolean,
    onSelect: (ModelInfo) -> Unit,
) {
    if (results.sections.isEmpty()) {
        item(key = "no-results") {
            Text(
                text = "No models match “$query”",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
            )
        }
    }
    results.sections.forEach { section ->
        item(key = "search-header:${section.id}") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                AgentIconView(kind = section.kind, sizeDp = 14)
                Spacer(Modifier.width(6.dp))
                PickerSectionHeader(section.title)
            }
        }
        items(section.models, key = { "search:${section.id}|${it.id}" }) { model ->
            PickerCardRow(
                first = model === section.models.first(),
                last = model === section.models.last(),
            ) {
                PickerModelRow(model, null, false, isSelected(model)) { onSelect(model) }
            }
        }
    }
    if (results.total > results.shown) {
        item(key = "search-more") {
            Text(
                text = "Showing ${results.shown} of ${results.total} matches. Keep typing to narrow.",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
            )
        }
    }
}

// region Catalog projection

internal fun ModelInfo.isModeEntry(): Boolean = entryKind != ModelEntryKind.MODEL

internal fun ModelInfo.pickerLabel(): String =
    pickerName.ifEmpty { displayName.ifBlank { id } }

private fun ModelInfo.scopedId(): String = "$agentRuntimeKind:$id"

private class PickerGroup(
    val id: String,
    val title: String?,
    val models: List<ModelInfo>,
)

private class PickerHarness(
    val kind: AgentRuntimeKind,
    val label: String,
    val modes: List<ModelInfo>,
    val pluginModes: List<ModelInfo>,
    val providers: List<PickerGroup>,
    val modelCount: Int,
    val summary: String,
)

private class PickerSearchSection(
    val id: String,
    val kind: AgentRuntimeKind,
    val title: String,
    val models: MutableList<ModelInfo>,
)

private class PickerSearchResults(
    val sections: List<PickerSearchSection>,
    val shown: Int,
    val total: Int,
)

private const val MaxModelSearchResults = 150

/** Render-only grouping of the catalog; built once per model list. */
private class ModelPickerCatalog(models: List<ModelInfo>) {
    private class SearchRow(
        val model: ModelInfo,
        val sectionId: String,
        val sectionTitle: String,
        val text: String,
    )

    val visible: List<ModelInfo> = models.filter { !it.hidden }
    val harnesses: List<PickerHarness>
    private val byScopedId: Map<String, ModelInfo> = visible.associateBy { it.scopedId() }
    private val rows: List<SearchRow>

    init {
        val byKind = LinkedHashMap<AgentRuntimeKind, MutableList<ModelInfo>>()
        visible.forEach { byKind.getOrPut(it.agentRuntimeKind) { mutableListOf() }.add(it) }
        harnesses = byKind.entries
            .sortedWith(compareBy({ it.key.runtimeSortIndex }, { it.key.titleDisplayLabel.lowercase(Locale.ROOT) }))
            .map { (kind, entries) -> buildHarness(kind, entries) }
        val searchRows = ArrayList<SearchRow>(visible.size)
        harnesses.forEach { harness ->
            val label = harness.label.lowercase(Locale.ROOT)
            fun index(entries: List<ModelInfo>, sectionId: String, title: String, provider: String?) {
                entries.forEach { model ->
                    val text = listOf(
                        model.pickerLabel(), model.id, model.model, model.displayName,
                        label, provider.orEmpty(), model.providerId.orEmpty(),
                    ).joinToString("\n").lowercase(Locale.ROOT)
                    searchRows += SearchRow(model, sectionId, title, text)
                }
            }
            index(harness.modes, "${harness.kind}|modes", "${harness.label} · Modes", "mode")
            index(harness.pluginModes, "${harness.kind}|plugin-modes", "${harness.label} · Plugin modes", "plugin mode")
            harness.providers.forEach { group ->
                index(
                    group.models,
                    group.id,
                    group.title?.let { "${harness.label} · $it" } ?: harness.label,
                    group.title,
                )
            }
        }
        rows = searchRows
    }

    fun harness(kind: AgentRuntimeKind): PickerHarness? = harnesses.firstOrNull { it.kind == kind }

    fun model(scopedId: String): ModelInfo? = byScopedId[scopedId]

    fun subtitle(model: ModelInfo): String {
        val harness = model.agentRuntimeKind.titleDisplayLabel
        return when (model.entryKind) {
            ModelEntryKind.MODE -> "$harness · mode"
            ModelEntryKind.PLUGIN_MODE -> "$harness · plugin mode"
            ModelEntryKind.MODEL -> {
                val provider = model.providerLabel ?: model.providerId
                if (provider.isNullOrEmpty()) harness else "$harness · $provider"
            }
        }
    }

    fun search(query: String, kind: AgentRuntimeKind?): PickerSearchResults {
        val tokens = query.lowercase(Locale.ROOT).split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return PickerSearchResults(emptyList(), 0, 0)
        val sections = ArrayList<PickerSearchSection>()
        var shown = 0
        var total = 0
        for (row in rows) {
            if (kind != null && row.model.agentRuntimeKind != kind) continue
            if (!tokens.all { row.text.contains(it) }) continue
            total += 1
            if (shown >= MaxModelSearchResults) continue
            shown += 1
            val last = sections.lastOrNull()
            if (last != null && last.id == row.sectionId) {
                last.models += row.model
            } else {
                sections += PickerSearchSection(
                    row.sectionId,
                    row.model.agentRuntimeKind,
                    row.sectionTitle,
                    mutableListOf(row.model),
                )
            }
        }
        return PickerSearchResults(sections, shown, total)
    }

    private fun buildHarness(kind: AgentRuntimeKind, entries: List<ModelInfo>): PickerHarness {
        val modes = entries.filter { it.entryKind == ModelEntryKind.MODE }
        val pluginModes = entries.filter { it.entryKind == ModelEntryKind.PLUGIN_MODE }
        val models = entries.filter { it.entryKind == ModelEntryKind.MODEL }
        val providers = models
            .groupBy { it.providerId.orEmpty() }
            .map { (provider, grouped) ->
                PickerGroup(
                    id = "$kind|provider:$provider",
                    title = if (provider.isEmpty()) null else grouped.first().providerLabel ?: provider,
                    models = grouped,
                )
            }
            .sortedWith(compareBy({ it.title != null }, { it.title?.lowercase(Locale.ROOT).orEmpty() }))
        val parts = mutableListOf<String>()
        if (models.isNotEmpty()) {
            parts += if (models.size == 1) "1 model" else "${models.size} models"
            val named = providers.count { it.title != null }
            if (named > 1) parts += "$named providers"
        }
        if (modes.isNotEmpty()) parts += if (modes.size == 1) "1 mode" else "${modes.size} modes"
        if (pluginModes.isNotEmpty()) {
            parts += if (pluginModes.size == 1) "1 plugin mode" else "${pluginModes.size} plugin modes"
        }
        return PickerHarness(
            kind = kind,
            label = kind.titleDisplayLabel,
            modes = modes,
            pluginModes = pluginModes,
            providers = providers,
            modelCount = models.size,
            summary = parts.joinToString(" · "),
        )
    }
}

/** Recently picked models, most recent first. Platform-local preference. */
private object ModelPickerRecents {
    private const val PREFS = "model_picker"
    private const val KEY = "recents"
    private const val LIMIT = 8

    fun load(context: Context): List<String> =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null)
            ?.split('\n')
            ?.filter { it.isNotEmpty() }
            ?: emptyList()

    fun record(context: Context, model: ModelInfo): List<String> {
        val id = model.scopedId()
        val next = (listOf(id) + load(context).filter { it != id }).take(LIMIT)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, next.joinToString("\n"))
            .apply()
        return next
    }
}

// endregion

// region Rows

private val PickerCardShape = RoundedCornerShape(14.dp)

@Composable
private fun PickerSectionHeader(title: String) {
    Text(
        text = title,
        color = LitterTheme.textSecondary,
        fontSize = LitterTextStyle.footnote.scaled,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.padding(start = 4.dp, top = 16.dp, bottom = 6.dp),
    )
}

@Composable
private fun PickerCard(content: @Composable () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(PickerCardShape)
            .background(LitterTheme.textPrimary.copy(alpha = 0.045f)),
    ) {
        content()
    }
}

/** One row of a card rendered as separate lazy items (large lists). */
@Composable
private fun PickerCardRow(first: Boolean, last: Boolean, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(
        topStart = if (first) 14.dp else 0.dp,
        topEnd = if (first) 14.dp else 0.dp,
        bottomStart = if (last) 14.dp else 0.dp,
        bottomEnd = if (last) 14.dp else 0.dp,
    )
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(LitterTheme.textPrimary.copy(alpha = 0.045f)),
    ) {
        if (!first) PickerDivider()
        content()
    }
}

@Composable
private fun PickerDivider() {
    HorizontalDivider(
        color = LitterTheme.divider,
        thickness = 0.5.dp,
        modifier = Modifier.padding(start = 16.dp),
    )
}

@Composable
private fun PickerHarnessIcon(kind: AgentRuntimeKind) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .size(28.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(LitterTheme.textPrimary.copy(alpha = 0.06f)),
    ) {
        AgentIconView(kind = kind, sizeDp = 18)
    }
}

@Composable
private fun PickerModelRow(
    model: ModelInfo,
    subtitle: String?,
    showsIcon: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (showsIcon) PickerHarnessIcon(model.agentRuntimeKind)
        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = model.pickerLabel(),
                    color = LitterTheme.textPrimary,
                    fontSize = LitterTextStyle.body.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (model.isDefault) {
                    Text(
                        text = "Default",
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.caption2.scaled,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier
                            .clip(RoundedCornerShape(4.dp))
                            .background(LitterTheme.textPrimary.copy(alpha = 0.07f))
                            .padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
            }
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.footnote.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (selected) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = "Selected",
                tint = LitterTheme.accent,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun PickerHarnessRow(
    harness: PickerHarness,
    isCurrent: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        PickerHarnessIcon(harness.kind)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = harness.label,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = 1,
            )
            Text(
                text = harness.summary,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (isCurrent) {
            Icon(
                imageVector = Icons.Default.Check,
                contentDescription = "Current harness",
                tint = LitterTheme.accent,
                modifier = Modifier.size(16.dp),
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = LitterTheme.textMuted,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun PickerValueRow(label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.body.scaled,
            maxLines = 1,
        )
        if (onClick != null) {
            Icon(
                imageVector = Icons.Default.KeyboardArrowDown,
                contentDescription = null,
                tint = LitterTheme.textMuted,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun PickerSwitchRow(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    checkedTrackColor: Color = LitterTheme.accent,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = checkedTrackColor),
        )
    }
}

// endregion

internal fun effortLabel(value: ReasoningEffort): String =
    uniffi.codex_mobile_client.reasoningEffortWireValue(value)

private fun ModelInfo.defaultReasoningEffortSelection(): String? =
    supportedDefaultReasoningEffort?.let(::effortLabel)

/** Chip / header label: the mode name for mode entries, else the display name. */
internal fun ModelInfo.modelPickerDisplayName(): String =
    if (isModeEntry()) {
        pickerLabel()
    } else {
        displayName.ifBlank { id }
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
