package com.litter.android.ui.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import uniffi.codex_mobile_client.ThreadKey
import com.litter.android.state.displayTitle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.WallpaperBackdrop
import com.litter.android.ui.common.FormattedText
import com.litter.android.ui.LitterSpacing
import com.litter.android.ui.LitterType
import com.litter.android.ui.metaLine
import androidx.compose.foundation.layout.heightIn
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppOperationStatus
import uniffi.codex_mobile_client.AppSessionSummary
import uniffi.codex_mobile_client.AppToolLogEntry

/**
 * Zoom-aware session card, replacing the flat `SessionCard` used previously
 * in the home dashboard. Layers reveal progressively:
 *   1  SCAN    — title + status dot only.
 *   2  GLANCE  — + time · server · workspace meta line (tool-activity label
 *                 when an active thread is running a tool).
 *   3  READ    — + modelBadgeLine (server/model + inline stats + stopwatch),
 *                 user message quote, compact tool log, short response preview.
 *   4  DEEP    — tool log expanded (3 rows), larger response preview cap.
 *
 * Each layer is wrapped in `AnimatedVisibility` so zoom transitions ripple
 * in, matching the iOS animation feel.
 *
 * Ref: HomeDashboardView.swift:591-680 (`body`) and zoom-gated rendering
 * at L620-652.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionCanvasRow(
    session: AppSessionSummary,
    zoomLevel: Int,
    isHydrating: Boolean,
    isLocal: Boolean,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    onFork: (() -> Unit)? = null,
    onReply: (() -> Unit)? = null,
    onCancelTurn: (() -> Unit)? = null,
    onPin: (() -> Unit)? = null,
    onUnpin: (() -> Unit)? = null,
    isPinned: Boolean = false,
    lineage: ThreadLineage? = null,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    // Rust's reducer already derives every field this card displays — last
    // response text, recent tool log, last-turn bounds — into `session`.
    // Reading `appModel.threadSnapshot(session.key)` here used to create a
    // per-card subscription to the global snapshot observable; every
    // streaming-delta bumped that observable and re-invalidated all cards
    // even though most had nothing to redraw. Using only `session` props
    // keeps the card's AttributeGraph footprint at one edge per row.
    val isActive = session.hasActiveTurn
    val toolRunning = remember(session.recentToolLog) {
        session.recentToolLog.lastOrNull()?.status?.let { status ->
            status == "inprogress" || status == "pending"
        } ?: false
    }

    var showMenu by remember { mutableStateOf(false) }
    val layerSpring = remember {
        spring<androidx.compose.ui.unit.IntSize>(
            stiffness = 400f,
            dampingRatio = 0.78f,
        )
    }

    // Litter Quiet: 20dp margins, ~62dp two-line rows. Zoom 1 is the dense
    // title-only list, so it keeps tighter vertical padding.
    val rowVerticalPadding = if (zoomLevel <= 1) LitterSpacing.xs else LitterSpacing.sm

    Box(modifier = modifier) {
        if (zoomLevel >= 4) {
            WallpaperBackdrop(
                threadKey = session.key,
                modifier = Modifier.matchParentSize(),
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = if (zoomLevel >= 2) LitterSpacing.row else LitterSpacing.touch)
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = LitterSpacing.margin, vertical = rowVerticalPadding),
            verticalAlignment = Alignment.Top,
        ) {
            // No status dot: healthy/running state reads from the meta line.
            Column(modifier = Modifier.weight(1f)) {
                // Lineage breadcrumb (zoom 4 only): root → … → parent. Self
                // is the title beneath, so we don't repeat it. Mirrors iOS
                // `lineageBreadcrumb`.
                // Data-driven layers (lineage, goal) render in place with no
                // expand animation, so hydration never slides rows at launch.
                if (zoomLevel >= 4 && (lineage?.ancestors?.isNotEmpty() == true)) {
                    LineageBreadcrumb(lineage = lineage)
                }

                val titleStyle = markdownMatchedTitleStyle()
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    CompositionLocalProvider(LocalTextStyle provides titleStyle) {
                        FormattedText(
                            text = session.displayTitle,
                            color = LitterTheme.textPrimary,
                            fontSize = titleStyle.fontSize,
                            maxLines = if (zoomLevel >= 4) 4 else 2,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    if (lineage != null && lineage.hasMultipleBranches) {
                        ForkRune(lineage = lineage)
                    }
                }

                // MetaLine is shown ONLY at zoom 2 (iOS `if zoomLevel == 2`).
                // At zoom 3+, modelBadgeLine replaces it with the richer,
                // single-line model/time/server row.
                AnimatedVisibility(
                    visible = zoomLevel == 2,
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    MetaLine(
                        session = session,
                        isActive = isActive,
                        toolRunning = toolRunning,
                        isHydrating = isHydrating,
                    )
                }

                // Goal line at zoom 2+. Mirrors iOS HomeDashboardView.swift
                // `goalLine`: status dot + objective + token/elapsed chips.
                val goal = session.goal
                if (zoomLevel >= 2 && goal != null) {
                    GoalLine(goal = goal)
                }

                AnimatedVisibility(
                    visible = zoomLevel >= 3,
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    Column {
                        ModelBadgeLine(
                            session = session,
                            isActive = isActive,
                        )
                        RecentUserMessageLine(session = session)
                        ToolLogColumn(
                            entries = session.recentToolLog,
                            maxEntries = if (zoomLevel >= 4) 3 else 1,
                        )
                        val text = session.lastResponsePreview?.trim().orEmpty()
                        // Key on the assistant message's source_turn_id so
                        // the crossfade only fires when a new assistant
                        // reply arrives. Keying on `stats.turnCount` would
                        // bump the id the moment the user submits a new
                        // prompt — before any new assistant text — so the
                        // preview would fade out (and back in with the
                        // same prior text) on every send.
                        val blockId = session.lastResponseTurnId ?: "empty"
                        if (text.isNotEmpty()) {
                            ResponsePreview(
                                text = text,
                                blockId = blockId,
                                zoomLevel = zoomLevel,
                            )
                        }
                    }
                }

                // Sibling pills (zoom 4 only). Each pill is a branch in the
                // lineage; the one matching this row is highlighted. Mirrors
                // iOS `siblingPillsRow`.
                if (zoomLevel >= 4 && lineage?.hasMultipleBranches == true) {
                    SiblingPillsRow(lineage = lineage, currentKey = session.key)
                }

                // Working directory line at zoom 4 only, matches iOS
                // HomeDashboardView.swift:645-652.
                AnimatedVisibility(
                    visible = zoomLevel >= 4 && !session.cwd.isNullOrBlank(),
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    Text(
                        text = com.litter.android.state.PathDisplay.display(session.cwd.orEmpty(), isLocal, context),
                        color = LitterTheme.textSecondary,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = META_FONT_SP.scaled,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }

            // Long-press on the row opens the action menu — replaces the
            // former 3-dot IconButton. Menu is anchored here so it pops
            // near the trailing edge.
            DropdownMenu(
                expanded = showMenu,
                onDismissRequest = { showMenu = false },
            ) {
                if (onReply != null) {
                    DropdownMenuItem(
                        text = { Text("Reply") },
                        onClick = {
                            showMenu = false
                            onReply()
                        },
                    )
                }
                if (onFork != null) {
                    DropdownMenuItem(
                        text = { Text("Fork") },
                        enabled = !session.hasActiveTurn,
                        onClick = {
                            showMenu = false
                            onFork()
                        },
                    )
                }
                if (onCancelTurn != null && session.hasActiveTurn) {
                    DropdownMenuItem(
                        text = { Text("Cancel Turn", color = LitterTheme.danger) },
                        onClick = {
                            showMenu = false
                            onCancelTurn()
                        },
                    )
                }
                if (isPinned && onUnpin != null) {
                    DropdownMenuItem(
                        text = { Text("Unpin") },
                        onClick = {
                            showMenu = false
                            onUnpin()
                        },
                    )
                } else if (!isPinned && onPin != null) {
                    DropdownMenuItem(
                        text = { Text("Pin") },
                        onClick = {
                            showMenu = false
                            onPin()
                        },
                    )
                }
                DropdownMenuItem(
                    text = { Text("Delete") },
                    onClick = {
                        showMenu = false
                        onDelete()
                    },
                )
            }
        }
    }
}

@Composable
private fun MetaLine(
    session: AppSessionSummary,
    isActive: Boolean,
    toolRunning: Boolean,
    isHydrating: Boolean,
) {
    val showActivity = isActive && toolRunning
    val relative = HomeDashboardSupport.relativeTime(session.updatedAt)
    val text = remember(session.serverDisplayName, session.cwd, session.agentRuntimeKind, relative, isActive, showActivity, isHydrating) {
        val runtime = HomeDashboardSupport.runtimeLabel(session.agentRuntimeKind)
        val state = when {
            showActivity -> "running tool…"
            isActive -> "thinking"
            isHydrating -> "loading…"
            else -> relative
        }
        metaLine(
            session.serverDisplayName,
            HomeDashboardSupport.workspaceLabel(session.cwd).ifBlank { runtime },
            state,
        )
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = LitterSpacing.xxs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(LitterSpacing.xs),
    ) {
        Text(
            text = text,
            style = LitterType.meta,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )

        // Inline stat chips on the trailing edge of the meta line. iOS
        // HomeDashboardView.swift:713,722-749 renders these at zoom 2.
        InlineStats(
            session = session,
            isActive = isActive,
        )
    }
}

@Composable
private fun ToolLogColumn(
    entries: List<AppToolLogEntry>,
    maxEntries: Int,
) {
    // Rust-side `recent_tool_log` is newest-last; take the tail to mirror the
    // old `hydratedToolRows` behavior. Replaces a per-card iteration over
    // hydrated items.
    val rows = remember(entries, maxEntries) { entries.takeLast(maxEntries) }
    if (rows.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 6.dp, bottom = 2.dp),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        rows.forEach { entry ->
            HomeToolRowView(entry = entry)
        }
    }
}

private const val META_FONT_SP = LitterType.META_SIZE

/**
 * Single-line goal row: status dot + objective + usage chips. Mirrors the
 * in-conversation goal card without the gauge — the home card stays
 * scan-friendly. Matches iOS `HomeDashboardView.goalLine`.
 */
@Composable
private fun GoalLine(goal: uniffi.codex_mobile_client.AppThreadGoal) {
    val tint = when (goal.status) {
        uniffi.codex_mobile_client.AppThreadGoalStatus.ACTIVE -> LitterTheme.accent
        uniffi.codex_mobile_client.AppThreadGoalStatus.PAUSED -> LitterTheme.textMuted
        uniffi.codex_mobile_client.AppThreadGoalStatus.BLOCKED,
        uniffi.codex_mobile_client.AppThreadGoalStatus.USAGE_LIMITED,
        uniffi.codex_mobile_client.AppThreadGoalStatus.BUDGET_LIMITED -> LitterTheme.warning
        uniffi.codex_mobile_client.AppThreadGoalStatus.COMPLETE -> LitterTheme.success
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            text = goal.objective,
            color = if (tint == LitterTheme.warning) tint else LitterTheme.textSecondary,
            fontFamily = LitterTheme.monoFont,
            fontSize = META_FONT_SP.scaled,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (goal.tokensUsed > 0) {
            Text(
                text = "T ${formatHomeGoalTokens(goal.tokensUsed)}",
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
            )
        }
        if (goal.timeUsedSeconds > 0) {
            Text(
                text = formatHomeGoalSeconds(goal.timeUsedSeconds),
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
            )
        }
    }
}

private fun formatHomeGoalTokens(value: Long): String =
    when {
        value >= 1_000_000 -> "%.1fM".format(value / 1_000_000.0)
        value >= 1_000 -> "%.1fk".format(value / 1_000.0)
        else -> value.toString()
    }

private fun formatHomeGoalSeconds(seconds: Long): String {
    if (seconds < 60) return "${seconds}s"
    val total = seconds.toInt()
    val minutes = total / 60
    val remainSecs = total % 60
    if (total < 3600) {
        return if (remainSecs == 0) "${minutes}m" else "${minutes}m ${remainSecs}s"
    }
    val hours = total / 3600
    val remainMins = (total % 3600) / 60
    return if (remainMins == 0) "${hours}h" else "${hours}h ${remainMins}m"
}

/**
 * Compact rune trailing the title at every zoom level. `2/3` reads as
 * "branch 2 of 3 in this lineage". Mirrors iOS `forkRune`.
 */
@Composable
private fun ForkRune(lineage: ThreadLineage) {
    Text(
        text = "${lineage.branchIndex}/${lineage.branchTotal}",
        style = LitterType.meta,
        modifier = Modifier.padding(top = 2.dp),
    )
}

/**
 * Zoom-4 lineage breadcrumb: root → … → parent. Self is the title beneath,
 * so we don't repeat it. Mirrors iOS `lineageBreadcrumb`.
 */
@Composable
private fun LineageBreadcrumb(lineage: ThreadLineage) {
    if (lineage.ancestors.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        lineage.ancestors.forEachIndexed { idx, ancestor ->
            if (idx > 0) {
                Text(
                    text = " › ",
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                )
            }
            Text(
                text = ancestor.title,
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = META_FONT_SP.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = " ›",
            color = LitterTheme.textSecondary,
            fontFamily = LitterTheme.monoFont,
            fontSize = META_FONT_SP.scaled,
        )
    }
}

/**
 * Zoom-4 sibling pills. Each pill is a branch in the lineage; the one
 * matching the current row is highlighted. Mirrors iOS `siblingPillsRow`.
 */
@Composable
private fun SiblingPillsRow(lineage: ThreadLineage, currentKey: ThreadKey) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(top = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(LitterSpacing.sm),
    ) {
        lineage.members.forEach { member ->
            val isCurrent = member.key == currentKey
            Row(
                modifier = Modifier.padding(vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = member.title,
                    color = if (isCurrent) LitterTheme.textPrimary
                        else LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                    fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
