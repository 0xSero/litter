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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
 * Groups a flat list of hydrated items into UI turns with the same boundary rules
 * as iOS: explicit user turn boundaries split turns, and streaming tails merge
 * back into the live turn instead of rendering as separate groups.
 */
fun buildTranscriptTurns(
    items: List<HydratedConversationItem>,
    isStreaming: Boolean,
    expandedRecentTurnCount: Int,
): List<TranscriptTurn> {
    if (items.isEmpty()) return emptyList()

    val groupedItems = mergeConsecutiveExplorationGroups(
        mergeTrailingStreamingGroups(groupItems(items), isStreaming),
    )
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

private fun mergeTrailingStreamingGroups(
    groups: List<List<HydratedConversationItem>>,
    isStreaming: Boolean,
): List<List<HydratedConversationItem>> {
    if (!isStreaming || groups.size <= 1) return groups

    val liveTurnStartIndex = groups.indexOfLast { containsLiveTurnBoundary(it) }
    if (liveTurnStartIndex == -1 || liveTurnStartIndex >= groups.lastIndex) return groups

    val mergedLiveTurn = groups.subList(liveTurnStartIndex, groups.size).flatten()
    return buildList {
        addAll(groups.subList(0, liveTurnStartIndex))
        add(mergedLiveTurn)
    }
}

private fun mergeConsecutiveExplorationGroups(
    groups: List<List<HydratedConversationItem>>,
): List<List<HydratedConversationItem>> {
    val merged = mutableListOf<List<HydratedConversationItem>>()
    val explorationBuffer = mutableListOf<HydratedConversationItem>()

    fun flushExplorationBuffer() {
        if (explorationBuffer.isEmpty()) return
        merged += explorationBuffer.toList()
        explorationBuffer.clear()
    }

    groups.forEach { group ->
        if (group.isExplorationGroup()) {
            explorationBuffer += group
        } else {
            flushExplorationBuffer()
            merged += group
        }
    }

    flushExplorationBuffer()
    return merged
}

private fun containsLiveTurnBoundary(items: List<HydratedConversationItem>): Boolean {
    return items.any { item ->
        item.isFromUserTurnBoundary || item.content is HydratedConversationItemContent.User
    }
}

private fun List<HydratedConversationItem>.isExplorationGroup(): Boolean {
    return isNotEmpty() && all { item ->
        val content = item.content as? HydratedConversationItemContent.CommandExecution
        content?.v1?.isPureExploration() == true
    }
}

private fun turnIdentifier(items: List<HydratedConversationItem>, ordinal: Int): String {
    val first = items.firstOrNull() ?: return "turn-$ordinal"
    val sourceTurnId = items.firstNotNullOfOrNull { it.sourceTurnId }
    return if (sourceTurnId != null) {
        "turn-$sourceTurnId-${first.id}"
    } else {
        "turn-${first.id}"
    }
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
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(10.dp))
            .clickable(onClick = onExpand)
            .padding(10.dp),
    ) {
        // User prompt preview
        turn.userPrompt?.let { prompt ->
            Text(
                text = prompt,
                color = LitterTheme.textPrimary,
                fontSize = LitterTextStyle.footnote.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        // Assistant snippet
        turn.assistantSnippet?.let { snippet ->
            Text(
                text = snippet,
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }

        // Metadata footer
        Row(
            modifier = Modifier.padding(top = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (turn.commandCount > 0) {
                MetadataBadge("${turn.commandCount} cmd", LitterTheme.toolCallCommand)
            }
            if (turn.fileChangeCount > 0) {
                MetadataBadge("${turn.fileChangeCount} files", LitterTheme.toolCallFileChange)
            }
            if (turn.totalDurationMs > 0) {
                val dur = if (turn.totalDurationMs < 1000) "${turn.totalDurationMs}ms"
                else "%.1fs".format(turn.totalDurationMs / 1000.0)
                MetadataBadge(dur, LitterTheme.textMuted)
            }
            Spacer(Modifier.weight(1f))
            Text("Tap to expand", color = LitterTheme.textMuted, fontSize = LitterTextStyle.caption2.scaled)
        }
    }
}

@Composable
private fun MetadataBadge(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(
        text = text,
        color = color,
        fontSize = LitterTextStyle.caption2.scaled,
        fontWeight = FontWeight.Medium,
    )
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
    var expanded by remember { mutableStateOf(false) }
    val entries = remember(group.items) { group.explorationEntries() }
    val isActive = remember(entries) { entries.any { it.isInProgress } }
    val previewScrollState = rememberScrollState()
    val shimmerProgress by rememberInfiniteTransition(label = "exploration-header-shimmer").animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "exploration-header-shimmer-progress",
    )
    val bulletSize = (6f * textScale).dp
    val bulletTopPadding = (5f * textScale).dp
    val previewHeight = (LitterTextStyle.caption * textScale * 3.6f).dp + 18.dp

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
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                .clickable { expanded = !expanded }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = if (expanded) "▼" else "▶",
                color = LitterTheme.textMuted,
                fontSize = LitterTextStyle.caption.scaled,
            )
            Spacer(Modifier.width(6.dp))
            Text(
                text = remember(entries, isActive) {
                    group.explorationSummaryText(isActive = isActive)
                },
                color = if (isActive) LitterTheme.textPrimary else LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption.scaled,
                modifier = Modifier
                    .weight(1f)
                    .explorationHeaderShimmer(active = isActive, progress = shimmerProgress),
            )
        }

        if (!expanded && showsCollapsedPreview && entries.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 24.dp, top = 4.dp)
                    .heightIn(min = 56.dp, max = previewHeight)
                    .background(
                        LitterTheme.surface.copy(alpha = 0.6f),
                        RoundedCornerShape(8.dp),
                    )
                    .padding(horizontal = 8.dp, vertical = 6.dp)
                    .verticalScroll(previewScrollState),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                entries.forEach { entry ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Spacer(
                            modifier = Modifier
                                .padding(top = bulletTopPadding)
                                .width(bulletSize)
                                .height(bulletSize)
                                .background(
                                    color = if (entry.isInProgress) {
                                        LitterTheme.warning
                                    } else {
                                        LitterTheme.textMuted
                                    },
                                    shape = RoundedCornerShape(percent = 50),
                                ),
                        )
                        Text(
                            text = entry.label,
                            color = LitterTheme.textSecondary,
                            fontSize = LitterTextStyle.caption.scaled,
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
                        .padding(start = 24.dp, top = 1.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    Spacer(
                        modifier = Modifier
                            .padding(top = bulletTopPadding)
                            .width(bulletSize)
                            .height(bulletSize)
                            .background(
                                color = if (entry.isInProgress) {
                                    LitterTheme.warning
                                } else {
                                    LitterTheme.textMuted
                                },
                                shape = RoundedCornerShape(percent = 50),
                            ),
                    )
                    Text(
                        text = entry.label,
                        color = LitterTheme.textSecondary,
                        fontSize = LitterTextStyle.caption.scaled,
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

private fun Modifier.explorationHeaderShimmer(active: Boolean, progress: Float): Modifier {
    if (!active) return this
    return drawWithContent {
        drawContent()
        val width = size.width
        val shimmerWidth = width * 0.35f
        val startX = (width + shimmerWidth) * progress - shimmerWidth
        drawRect(
            brush = Brush.horizontalGradient(
                colors = listOf(
                    Color.Transparent,
                    Color.White.copy(alpha = 0.3f),
                    Color.Transparent,
                ),
                startX = startX,
                endX = startX + shimmerWidth,
            ),
            topLeft = Offset.Zero,
            size = size,
            blendMode = BlendMode.SrcAtop,
        )
    }
}
