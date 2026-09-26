package com.litter.android.ui.conversation

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterQuiet
import com.litter.android.ui.LitterSpacing
import com.litter.android.ui.LitterType
import com.litter.android.ui.metaLine
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.HydratedCommandActionKind
import uniffi.codex_mobile_client.HydratedConversationItem
import uniffi.codex_mobile_client.HydratedConversationItemContent
import uniffi.codex_mobile_client.AppMessagePhase

/**
 * A group of conversation items belonging to the same turn.
 */
data class TranscriptTurn(
    val id: String,
    val turnId: String?,
    val items: List<HydratedConversationItem>,
    val isActiveTurn: Boolean,
    val isCollapsedByDefault: Boolean,
) {
    val userPrompt: String?
        get() = items.firstOrNull { it.content is HydratedConversationItemContent.User }
            ?.let { (it.content as HydratedConversationItemContent.User).v1.text }

    val assistantSnippet: String?
        get() = (
            items.firstOrNull {
                when (val content = it.content) {
                    is HydratedConversationItemContent.Assistant ->
                        content.v1.phase == AppMessagePhase.FINAL_ANSWER
                    is HydratedConversationItemContent.CodeReview -> true
                    else -> false
                }
            }
                ?: items.lastOrNull {
                    it.content is HydratedConversationItemContent.Assistant ||
                        it.content is HydratedConversationItemContent.CodeReview
                }
            )?.let {
                when (val content = it.content) {
                    is HydratedConversationItemContent.Assistant -> content.v1.text
                    is HydratedConversationItemContent.CodeReview ->
                        content.v1.findings.firstOrNull()?.title ?: "Code review"
                    else -> null
                }
            }
            ?.take(120)

    val commandCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.CommandExecution }

    val fileChangeCount: Int
        get() = items.count { it.content is HydratedConversationItemContent.FileChange }

    val totalDurationMs: Long
        get() = items.sumOf {
            when (val c = it.content) {
                is HydratedConversationItemContent.CommandExecution -> c.v1.durationMs ?: 0L
                else -> 0L
            }
        }
}

/**
 * Groups a flat list of hydrated items by explicit user boundaries and server
 * turn IDs. Items without provenance remain with the preceding turn.
 */
fun buildTranscriptTurns(
    items: List<HydratedConversationItem>,
    isStreaming: Boolean,
    expandedRecentTurnCount: Int,
): List<TranscriptTurn> {
    if (items.isEmpty()) return emptyList()

    val groupedItems = groupItems(items)
    val collapseBoundary = maxOf(0, groupedItems.size - expandedRecentTurnCount)
    val lastIndex = groupedItems.lastIndex

    return groupedItems.mapIndexed { index, turnItems ->
        val turnId = turnItems.firstNotNullOfOrNull { it.sourceTurnId }
        TranscriptTurn(
            id = turnIdentifier(turnItems, index),
            turnId = turnId,
            items = turnItems,
            isActiveTurn = isStreaming && index == lastIndex,
            isCollapsedByDefault = index < collapseBoundary,
        )
    }
}

private fun groupItems(items: List<HydratedConversationItem>): List<List<HydratedConversationItem>> {
    val groups = mutableListOf<List<HydratedConversationItem>>()
    var current = mutableListOf<HydratedConversationItem>()
    var currentSourceTurnId: String? = null
    for (item in items) {
        val startsNewTurn =
            current.isNotEmpty() && (
                item.isFromUserTurnBoundary ||
                    (
                        item.sourceTurnId != null &&
                            currentSourceTurnId != null &&
                            item.sourceTurnId != currentSourceTurnId
                        )
                )

        if (startsNewTurn) {
            groups += current.toList()
            current = mutableListOf()
        }
        current += item

        currentSourceTurnId = when {
            currentSourceTurnId == null -> item.sourceTurnId
            current.size == 1 -> current.firstOrNull()?.sourceTurnId
            else -> currentSourceTurnId
        }
    }

    if (current.isNotEmpty()) {
        groups += current.toList()
    }

    return groups
}

private fun turnIdentifier(items: List<HydratedConversationItem>, ordinal: Int): String {
    val first = items.firstOrNull() ?: return "turn-$ordinal"
    return "turn-${first.id}"
}

/** Collapse is an initial presentation choice, not a reaction to sending a turn. */
internal class TranscriptPresentationState {
    private val defaults = mutableMapOf<String, Boolean>()
    private val presentationIds = mutableMapOf<String, String>()
    private var uniqueSourceAliases = emptyMap<String, String>()

    fun update(turns: List<TranscriptTurn>) {
        entryCache.keys.retainAll(turns.map { it.id }.toSet())
        val sourceCounts = turns.mapNotNull { it.turnId }.groupingBy { it }.eachCount()
        turns.forEach { turn ->
            val presentationId = presentationIds.getOrPut(turn.id) {
                turn.turnId?.takeIf { sourceCounts[it] == 1 }?.let(uniqueSourceAliases::get) ?: turn.id
            }
            defaults.getOrPut(presentationId) { turn.isCollapsedByDefault && !turn.isActiveTurn }
        }
        // Explicit user boundaries can split one source turn into several UI
        // groups; only unambiguous server IDs may transfer presentation state.
        uniqueSourceAliases = turns.mapNotNull { turn ->
            turn.turnId?.takeIf { sourceCounts[it] == 1 }?.let { it to presentationId(turn) }
        }.toMap()
    }

    private data class CachedEntries(
        val items: List<HydratedConversationItem>,
        val isActive: Boolean,
        val rows: List<TranscriptRow.Entry>,
        val chain: TurnChain?,
    )

    /** Chain expansion default per finished turn, captured once so a changed preference never re-flips old turns. */
    private val chainDefaults = mutableMapOf<String, Boolean>()

    fun chainExpanded(turn: TranscriptTurn, overrides: Map<String, Boolean>, preference: Boolean): Boolean {
        val id = presentationId(turn)
        overrides[id]?.let { return it }
        if (turn.isActiveTurn) return true
        return chainDefaults.getOrPut(id) { preference }
    }

    fun chain(turn: TranscriptTurn): TurnChain? {
        entries(turn)
        return entryCache[turn.id]?.chain
    }

    private val entryCache = mutableMapOf<String, CachedEntries>()

    fun entries(turn: TranscriptTurn): List<TranscriptRow.Entry> {
        val cached = entryCache[turn.id]
        if (cached != null && cached.isActive == turn.isActiveTurn && cached.items == turn.items) {
            return cached.rows
        }
        return projectEntries(turn).also {
            entryCache[turn.id] = CachedEntries(turn.items, turn.isActiveTurn, it, buildTurnChain(turn, it))
        }
    }

    private fun projectEntries(turn: TranscriptTurn): List<TranscriptRow.Entry> {
        val entries = buildTimelineEntries(turn.items, turn.isActiveTurn)
        val streamingAssistantId = if (turn.isActiveTurn) {
            turn.items.lastOrNull { it.content is HydratedConversationItemContent.Assistant }?.id
        } else null
        val latestCommandId = entries.asReversed().firstNotNullOfOrNull { entry ->
            (entry as? TimelineEntry.Single)?.item
                ?.takeIf { it.content is HydratedConversationItemContent.CommandExecution }?.id
        }
        return entries.mapIndexed { index, entry ->
            TranscriptRow.Entry(entry, turn.isActiveTurn, streamingAssistantId, latestCommandId, index == entries.lastIndex)
        }
    }

    fun presentationId(turn: TranscriptTurn): String = presentationIds[turn.id] ?: turn.id

    fun isCollapsedByDefault(turn: TranscriptTurn): Boolean = defaults[presentationId(turn)] == true
}

/** Each message/tool group is its own lazy item, even inside a very long turn. */
internal sealed class TranscriptRow(val key: String, val contentType: String) {
    class Entry(
        val entry: TimelineEntry,
        val isActiveTurn: Boolean,
        val streamingAssistantItemId: String?,
        val latestCommandExecutionItemId: String?,
        val isLastEntry: Boolean,
    ) : TranscriptRow(
        when (entry) {
            is TimelineEntry.Single -> "item-${entry.item.id}"
            is TimelineEntry.Exploration -> entry.group.id
        },
        when (entry) {
            is TimelineEntry.Single -> entry.item.content.javaClass.simpleName
            is TimelineEntry.Exploration -> "exploration"
        },
    )

    /** Per-turn summary line ("ran 3 commands · read 2 files ›") that discloses the work chain. */
    class Chain(val turn: TranscriptTurn, val chain: TurnChain, val expanded: Boolean, val expansionId: String) :
        TranscriptRow("chain-${turn.id}", "chain")

    class Collapsed(val turn: TranscriptTurn, val expansionId: String) : TranscriptRow("collapsed-${turn.id}", "collapsed")
    class Footer(val turn: TranscriptTurn, val canCollapse: Boolean, val expansionId: String) :
        TranscriptRow("footer-${turn.id}", "footer")
}

internal fun LazyListScope.transcriptRows(
    rows: List<TranscriptRow>,
    content: @Composable LazyItemScope.(TranscriptRow) -> Unit,
) {
    items(rows, key = { it.key }, contentType = { it.contentType }, itemContent = content)
}

internal fun buildTranscriptRows(
    turns: List<TranscriptTurn>,
    collapseState: TranscriptPresentationState,
    expandedTurnIds: Set<String>,
    chainOverrides: Map<String, Boolean> = emptyMap(),
    chainExpandedByDefault: Boolean = false,
): List<TranscriptRow> = buildList {
    collapseState.update(turns)
    turns.forEach { turn ->
        val canCollapse = collapseState.isCollapsedByDefault(turn)
        val expansionId = collapseState.presentationId(turn)
        if (canCollapse && expansionId !in expandedTurnIds && !turn.isActiveTurn) {
            add(TranscriptRow.Collapsed(turn, expansionId))
        } else {
            val entries = collapseState.entries(turn)
            val chain = collapseState.chain(turn)
            if (chain == null) {
                addAll(entries)
            } else {
                // Collapsed chains emit no rows for their members, so their
                // children are never composed; visible rows keep their keys.
                val expanded = collapseState.chainExpanded(turn, chainOverrides, chainExpandedByDefault)
                entries.forEachIndexed { index, entry ->
                    if (index == chain.firstIndex) add(TranscriptRow.Chain(turn, chain, expanded, expansionId))
                    if (expanded || entry.key !in chain.memberKeys) add(entry)
                }
            }
            add(TranscriptRow.Footer(turn, canCollapse, expansionId))
        }
    }
}

/** View-only projection of a turn's reasoning, tool, and subagent work. */
internal class TurnChain(
    val memberKeys: Set<String>,
    val firstIndex: Int,
    val summary: String,
    val isRunning: Boolean,
)

/** Items that belong in the collapsible work chain rather than the answer. */
private fun HydratedConversationItemContent.isChainWork(): Boolean = when (this) {
    is HydratedConversationItemContent.Reasoning,
    is HydratedConversationItemContent.CommandExecution,
    is HydratedConversationItemContent.FileChange,
    is HydratedConversationItemContent.McpToolCall,
    is HydratedConversationItemContent.DynamicToolCall,
    is HydratedConversationItemContent.MultiAgentAction,
    is HydratedConversationItemContent.WebSearch,
    is HydratedConversationItemContent.ImageView,
    -> true
    else -> false
}

private fun AppOperationStatus.isRunning(): Boolean =
    this == AppOperationStatus.PENDING || this == AppOperationStatus.IN_PROGRESS

internal fun buildTurnChain(turn: TranscriptTurn, entries: List<TranscriptRow.Entry>): TurnChain? {
    // Commentary between tool calls is part of the work; the last assistant
    // message (the answer) always stays visible.
    val lastAssistantId = turn.items.lastOrNull { it.content is HydratedConversationItemContent.Assistant }?.id
    val members = mutableSetOf<String>()
    var firstIndex = -1
    var thought = false
    var commands = 0
    var reads = 0
    var searches = 0
    var edits = 0
    var tools = 0
    var agents = 0
    var durationMs = 0L
    var running = false
    entries.forEachIndexed { index, row ->
        val isMember = when (val entry = row.entry) {
            is TimelineEntry.Exploration -> {
                entry.group.items.forEach { item ->
                    val data = (item.content as? HydratedConversationItemContent.CommandExecution)?.v1 ?: return@forEach
                    durationMs += data.durationMs ?: 0L
                    if (data.status.isRunning()) running = true
                    data.actions.forEach { action ->
                        when (action.kind) {
                            HydratedCommandActionKind.READ -> reads += 1
                            HydratedCommandActionKind.SEARCH, HydratedCommandActionKind.LIST_FILES -> searches += 1
                            HydratedCommandActionKind.UNKNOWN -> commands += 1
                        }
                    }
                }
                true
            }
            is TimelineEntry.Single -> {
                val item = entry.item
                when (val c = item.content) {
                    is HydratedConversationItemContent.Reasoning -> { thought = true; true }
                    is HydratedConversationItemContent.CommandExecution -> {
                        commands += 1
                        durationMs += c.v1.durationMs ?: 0L
                        if (c.v1.status.isRunning()) running = true
                        true
                    }
                    is HydratedConversationItemContent.FileChange -> {
                        edits += c.v1.changes.size.coerceAtLeast(1)
                        if (c.v1.status.isRunning()) running = true
                        true
                    }
                    is HydratedConversationItemContent.MultiAgentAction -> {
                        agents += c.v1.receiverThreadIds.size.coerceAtLeast(1)
                        if (c.v1.status.isRunning()) running = true
                        true
                    }
                    is HydratedConversationItemContent.Assistant ->
                        c.v1.phase == AppMessagePhase.COMMENTARY && item.id != lastAssistantId
                    else -> if (c.isChainWork()) { tools += 1; true } else false
                }
            }
        }
        if (isMember) {
            members += row.key
            if (firstIndex < 0) firstIndex = index
        }
    }
    if (members.isEmpty()) return null
    return TurnChain(
        memberKeys = members,
        firstIndex = firstIndex,
        summary = turnChainSummary(thought, durationMs, commands, reads, searches, edits, tools, agents, turn.isActiveTurn),
        isRunning = running || turn.isActiveTurn,
    )
}

internal fun turnChainSummary(
    thought: Boolean,
    durationMs: Long,
    commands: Int,
    reads: Int,
    searches: Int,
    edits: Int,
    tools: Int,
    agents: Int,
    isActive: Boolean,
): String {
    fun plural(n: Int, one: String, many: String) = "$n ${if (n == 1) one else many}"
    val duration = durationMs.takeIf { it >= 1000 }?.let { formatChainDuration(it) }
    val lead = when {
        isActive -> "working"
        thought && duration != null -> "thought $duration"
        thought -> "thought"
        duration != null -> "worked $duration"
        else -> null
    }
    val parts = listOfNotNull(
        lead,
        commands.takeIf { it > 0 }?.let { "ran ${plural(it, "command", "commands")}" },
        reads.takeIf { it > 0 }?.let { "read ${plural(it, "file", "files")}" },
        searches.takeIf { it > 0 }?.let { "searched ${plural(it, "time", "times")}" },
        edits.takeIf { it > 0 }?.let { "edited ${plural(it, "file", "files")}" },
        tools.takeIf { it > 0 }?.let { "called ${plural(it, "tool", "tools")}" },
        agents.takeIf { it > 0 }?.let { plural(it, "agent", "agents") },
    )
    return parts.joinToString(" · ").ifEmpty { "worked" }
}

private fun formatChainDuration(ms: Long): String {
    val seconds = ms / 1000
    return if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"
}

/** Summary line for a turn's work chain; tapping toggles the chain. */
@Composable
internal fun TurnChainSummaryRow(
    chain: TurnChain,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    Text(
        text = chain.summary + if (expanded) " ‹" else " ›",
        style = LitterType.meta,
        color = if (chain.isRunning) LitterTheme.textSecondary else LitterQuiet.meta,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(vertical = LitterSpacing.xs),
    )
}

/**
 * Renders a collapsed turn card with preview and metadata.
 * Tap to expand and show all items.
 */
@Composable
fun CollapsedTurnCard(
    turn: TranscriptTurn,
    onExpand: () -> Unit,
) {
    // Older turns collapse to the prompt plus one mono summary line.
    val meta = remember(turn.id, turn.commandCount, turn.fileChangeCount, turn.totalDurationMs) {
        val dur = turn.totalDurationMs
        metaLine(
            turn.commandCount.takeIf { it > 0 }?.let { "$it cmd" },
            turn.fileChangeCount.takeIf { it > 0 }?.let { "$it files" },
            dur.takeIf { it > 0 }?.let { if (it < 1000) "${it}ms" else "%.1fs".format(it / 1000.0) },
        )
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onExpand)
            .padding(vertical = LitterSpacing.xs),
        verticalArrangement = Arrangement.spacedBy(LitterSpacing.xxs),
    ) {
        turn.userPrompt?.let { prompt ->
            Text(
                text = prompt,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.body.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        turn.assistantSnippet?.let { snippet ->
            Text(
                text = snippet,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.subheadline.scaled,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = if (meta.isEmpty()) "earlier turn ›" else "$meta ›",
            style = LitterType.meta,
        )
    }
}

/**
 * Groups consecutive CommandExecution items with empty/null output
 * into a collapsed "Explored N locations" row.
 */
data class ExplorationGroup(
    val id: String,
    val items: List<HydratedConversationItem>,
)

private data class ExplorationDisplayEntry(
    val id: String,
    val label: String,
    val isInProgress: Boolean,
)

/**
 * Detects exploration groups in a list of items within a single turn.
 * Returns a mixed list of either individual items or exploration groups.
 */
sealed class TimelineEntry {
    data class Single(val item: HydratedConversationItem) : TimelineEntry()
    data class Exploration(val group: ExplorationGroup) : TimelineEntry()
}

fun buildTimelineEntries(
    items: List<HydratedConversationItem>,
    isLive: Boolean,
): List<TimelineEntry> {
    val result = mutableListOf<TimelineEntry>()
    var explorationRun = mutableListOf<HydratedConversationItem>()

    fun flushExploration() {
        if (explorationRun.isEmpty()) return
        if (isLive || explorationRun.size > 1) {
            val id = explorationRun.firstOrNull()?.id ?: "exploration"
            result.add(TimelineEntry.Exploration(ExplorationGroup(id = "exploration-$id", items = explorationRun.toList())))
        } else {
            explorationRun.forEach { result.add(TimelineEntry.Single(it)) }
        }
        explorationRun = mutableListOf()
    }

    for (item in items) {
        val content = item.content
        if (content is HydratedConversationItemContent.CommandExecution &&
            content.v1.isPureExploration()
        ) {
            explorationRun.add(item)
        } else {
            flushExploration()
            result.add(TimelineEntry.Single(item))
        }
    }
    flushExploration()
    return result
}

/**
 * Renders an exploration group as a collapsible summary.
 */
@Composable
fun ExplorationGroupRow(
    group: ExplorationGroup,
    showsCollapsedPreview: Boolean,
) {
    val textScale = LocalTextScale.current
    var expanded by rememberSaveable { mutableStateOf(false) }
    val entries = remember(group.items) { group.explorationEntries() }
    val isActive = remember(entries) { entries.any { it.isInProgress } }
    val previewScrollState = rememberScrollState()
    val previewHeight = (LitterType.META_SIZE * textScale * 4.4f).dp + 18.dp

    LaunchedEffect(entries, previewScrollState.maxValue, expanded, showsCollapsedPreview) {
        if (expanded || !showsCollapsedPreview || previewScrollState.maxValue <= 0) return@LaunchedEffect
        previewScrollState.animateScrollTo(previewScrollState.maxValue)
    }

    LaunchedEffect(showsCollapsedPreview) {
        if (!showsCollapsedPreview) {
            expanded = false
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize(),
    ) {
        // Expandable mono line; no always-on shimmer (it animated even for
        // finished groups).
        Text(
            text = remember(entries, isActive, expanded) {
                group.explorationSummaryText(isActive = isActive).lowercase() +
                    if (expanded) " ‹" else " ›"
            },
            style = LitterType.meta,
            color = if (isActive) LitterTheme.textPrimary else LitterQuiet.meta,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { expanded = !expanded }
                .padding(vertical = LitterSpacing.xs),
        )

        if (!expanded && showsCollapsedPreview && entries.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = LitterSpacing.sm)
                    .heightIn(max = previewHeight)
                    .verticalScroll(previewScrollState),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                entries.forEach { entry ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Text(
                            text = entry.label,
                            style = LitterType.meta,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        } else if (expanded) {
            for (entry in entries) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = LitterSpacing.sm, top = 1.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Text(
                        text = entry.label,
                        style = LitterType.meta,
                        maxLines = Int.MAX_VALUE,
                        overflow = TextOverflow.Clip,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        }
    }
}

private fun uniffi.codex_mobile_client.HydratedCommandExecutionData.isPureExploration(): Boolean {
    if (actions.isEmpty()) return false
    return actions.all { action ->
        when (action.kind) {
            HydratedCommandActionKind.READ,
            HydratedCommandActionKind.SEARCH,
            HydratedCommandActionKind.LIST_FILES,
            -> true

            HydratedCommandActionKind.UNKNOWN -> false
        }
    }
}

private fun HydratedConversationItem.isInProgressExplorationItem(): Boolean {
    val content = content as? HydratedConversationItemContent.CommandExecution ?: return false
    return content.v1.status == AppOperationStatus.PENDING || content.v1.status == AppOperationStatus.IN_PROGRESS
}

private fun ExplorationGroup.explorationEntries(): List<ExplorationDisplayEntry> {
    return items.flatMap { item ->
        val content = item.content as? HydratedConversationItemContent.CommandExecution ?: return@flatMap emptyList()
        val data = content.v1
        val isInProgress = data.status == AppOperationStatus.PENDING || data.status == AppOperationStatus.IN_PROGRESS
        if (data.actions.isEmpty()) {
            listOf(
                ExplorationDisplayEntry(
                    id = "${item.id}-command",
                    label = data.command,
                    isInProgress = isInProgress,
                ),
            )
        } else {
            data.actions.mapIndexed { index, action ->
                ExplorationDisplayEntry(
                    id = "${item.id}-$index",
                    label = explorationActionLabel(action, data.command),
                    isInProgress = isInProgress,
                )
            }
        }
    }
}

private fun ExplorationGroup.explorationSummaryText(isActive: Boolean): String {
    var readCount = 0
    var searchCount = 0
    var listingCount = 0
    var fallbackCount = 0

    items.forEach { item ->
        val content = item.content as? HydratedConversationItemContent.CommandExecution ?: return@forEach
        val data = content.v1
        if (data.actions.isEmpty()) {
            fallbackCount += 1
            return@forEach
        }
        data.actions.forEach { action ->
            when (action.kind) {
                HydratedCommandActionKind.READ -> readCount += 1
                HydratedCommandActionKind.SEARCH -> searchCount += 1
                HydratedCommandActionKind.LIST_FILES -> listingCount += 1
                HydratedCommandActionKind.UNKNOWN -> fallbackCount += 1
            }
        }
    }

    val parts = buildList {
        if (readCount > 0) add("$readCount ${if (readCount == 1) "file" else "files"}")
        if (searchCount > 0) add("$searchCount ${if (searchCount == 1) "search" else "searches"}")
        if (listingCount > 0) add("$listingCount ${if (listingCount == 1) "listing" else "listings"}")
        if (fallbackCount > 0) add("$fallbackCount ${if (fallbackCount == 1) "step" else "steps"}")
    }

    val prefix = if (isActive) "Exploring" else "Explored"
    return if (parts.isEmpty()) {
        val count = explorationEntries().size
        "$prefix $count exploration ${if (count == 1) "step" else "steps"}"
    } else {
        "$prefix ${parts.joinToString(", ")}"
    }
}

private fun explorationActionLabel(
    action: uniffi.codex_mobile_client.HydratedCommandActionData,
    fallback: String,
): String {
    val suffix = explorationCommandSuffix(action)
    return when (action.kind) {
        HydratedCommandActionKind.READ -> {
            action.path?.let { "Read ${workspaceTitle(it)}$suffix" } ?: fallback
        }

        HydratedCommandActionKind.SEARCH -> {
            when {
                !action.query.isNullOrBlank() && !action.path.isNullOrBlank() ->
                    "Searched for ${action.query} in ${workspaceTitle(action.path!!)}$suffix"
                !action.query.isNullOrBlank() ->
                    "Searched for ${action.query}$suffix"
                else -> fallback
            }
        }

        HydratedCommandActionKind.LIST_FILES -> {
            action.path?.let { "Listed files in ${workspaceTitle(it)}$suffix" } ?: fallback
        }

        HydratedCommandActionKind.UNKNOWN -> fallback
    }
}

private fun explorationCommandSuffix(
    action: uniffi.codex_mobile_client.HydratedCommandActionData,
): String {
    val command = action.command.trim()
    if (!command.endsWith(")")) return ""
    val start = command.lastIndexOf(" (")
    return if (start >= 0) command.substring(start) else ""
}

private fun workspaceTitle(path: String): String {
    val normalized = path.replace('\\', '/').trimEnd('/')
    val lastSegment = normalized.substringAfterLast('/', normalized)
    return if (lastSegment.isBlank()) path else lastSegment
}
