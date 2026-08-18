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
import com.litter.android.ui.common.StatusDot
import com.litter.android.ui.common.StatusDotState
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

    val dotState = when {
        isActive -> StatusDotState.ACTIVE
        isHydrating -> StatusDotState.PENDING
        session.isResumed -> StatusDotState.OK
        else -> StatusDotState.IDLE
    }

    var showMenu by remember { mutableStateOf(false) }
    val layerSpring = remember {
        spring<androidx.compose.ui.unit.IntSize>(
            stiffness = 400f,
            dampingRatio = 0.78f,
        )
    }

    // Vertical padding per zoom matches iOS `[3, 6, 10, 12][zoomLevel-1]`
    // (HomeDashboardView.swift:661). Horizontal kept at 14dp to match iOS.
    val rowVerticalPadding = when (zoomLevel) {
        1 -> 3.dp
        2 -> 6.dp
        3 -> 10.dp
        else -> 12.dp
    }

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
                .combinedClickable(
                    onClick = onClick,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = 14.dp, vertical = rowVerticalPadding),
            verticalAlignment = Alignment.Top,
        ) {
            // Mirrors iOS `HomeDashboardView.swift:602-604`:
            //   .frame(width: markerWidth (14), height: 16)
            //   .padding(.top, 2)
            // 10pt dot centered in a 14×16 slot with a 2pt top nudge puts
            // the dot center at y≈10 from the row top, which lines up with
            // the midline of the title's first line (17pt body, line
            // height ≈20pt), including when the title wraps to two lines.
            Box(
                modifier = Modifier
                    .padding(top = 2.dp)
                    .width(14.dp)
                    .height(16.dp),
                contentAlignment = Alignment.Center,
            ) {
                StatusDot(
                    state = dotState,
                    size = 10.dp,
                )
            }
            Spacer(Modifier.width(8.dp))

            Column(modifier = Modifier.weight(1f)) {
                // Lineage breadcrumb (zoom 4 only): root → … → parent. Self
                // is the title beneath, so we don't repeat it. Mirrors iOS
                // `lineageBreadcrumb`.
                AnimatedVisibility(
                    visible = zoomLevel >= 4 && (lineage?.ancestors?.isNotEmpty() == true),
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    lineage?.let { LineageBreadcrumb(lineage = it) }
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
                            color = if (isActive) LitterTheme.accent else LitterTheme.textPrimary,
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
                    )
                }

                // Goal line at zoom 2+. Mirrors iOS HomeDashboardView.swift
                // `goalLine`: status dot + objective + token/elapsed chips.
                AnimatedVisibility(
                    visible = zoomLevel >= 2 && session.goal != null,
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    session.goal?.let { GoalLine(goal = it) }
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
                AnimatedVisibility(
                    visible = zoomLevel >= 4 && (lineage?.hasMultipleBranches == true),
                    enter = fadeIn(tween(200)) + expandVertically(animationSpec = layerSpring),
                    exit = fadeOut(tween(120)) + shrinkVertically(animationSpec = layerSpring),
                ) {
                    lineage?.let { SiblingPillsRow(lineage = it, currentKey = session.key) }
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
                        color = LitterTheme.textMuted.copy(alpha = 0.7f),
                        fontFamily = LitterTheme.monoFont,
                        fontSize = 10f.scaled,
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
) {
    val showActivity = isActive && toolRunning
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (showActivity) {
                Text(
                    text = "running tool…",
                    color = LitterTheme.accent,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                val relative = HomeDashboardSupport.relativeTime(session.updatedAt)
                if (relative.isNotEmpty()) {
                    Text(
                        text = relative,
                        color = LitterTheme.textMuted,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = META_FONT_SP.scaled,
                        // Every sibling in this row caps at one line; this one
                        // did not, so when the row ran out of width the
                        // timestamp was the only child that could wrap -- and
                        // being squeezed to a ~1-character column it wrapped
                        // after every letter (#162).
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Clip,
                    )
                }
                Text(
                    text = HomeDashboardSupport.runtimeLabel(session.agentRuntimeKind),
                    color = LitterTheme.accent,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = session.serverDisplayName,
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = HomeDashboardSupport.workspaceLabel(session.cwd),
                    color = LitterTheme.textMuted,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = META_FONT_SP.scaled,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (isActive) {
                    Text(
                        text = "thinking",
                        color = LitterTheme.accent,
                        fontFamily = LitterTheme.monoFont,
                        fontSize = META_FONT_SP.scaled,
                    )
                }
            }
        }

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

private const val META_FONT_SP = 11f

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
        Box(
            modifier = Modifier
                .size(5.dp)
                .background(tint, androidx.compose.foundation.shape.CircleShape),
        )
        Text(
            text = goal.objective,
            color = LitterTheme.textSecondary.copy(alpha = 0.85f),
            fontFamily = LitterTheme.monoFont,
            fontSize = 10f.scaled,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (goal.tokensUsed > 0) {
            Text(
                text = "T ${formatHomeGoalTokens(goal.tokensUsed)}",
                color = LitterTheme.textMuted.copy(alpha = 0.7f),
                fontFamily = LitterTheme.monoFont,
                fontSize = 10f.scaled,
            )
        }
        if (goal.timeUsedSeconds > 0) {
            Text(
                text = formatHomeGoalSeconds(goal.timeUsedSeconds),
                color = LitterTheme.textMuted.copy(alpha = 0.7f),
                fontFamily = LitterTheme.monoFont,
                fontSize = 10f.scaled,
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
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(percent = 50))
            .border(
                width = 1.dp,
                color = LitterTheme.border.copy(alpha = 0.6f),
                shape = RoundedCornerShape(percent = 50),
            )
            .padding(horizontal = 6.dp, vertical = 1.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            text = "⊢", // ⊢ — visually similar to a branch glyph, no Material extended icons needed.
            color = LitterTheme.textSecondary.copy(alpha = 0.85f),
            fontFamily = LitterTheme.monoFont,
            fontSize = 9f.scaled,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            text = "${lineage.branchIndex}/${lineage.branchTotal}",
            color = LitterTheme.accent,
            fontFamily = LitterTheme.monoFont,
            fontSize = 9f.scaled,
            fontWeight = FontWeight.SemiBold,
        )
    }
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
                    color = LitterTheme.textMuted.copy(alpha = 0.55f),
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 9f.scaled,
                )
            }
            Text(
                text = ancestor.title,
                color = LitterTheme.textMuted.copy(alpha = 0.85f),
                fontFamily = LitterTheme.monoFont,
                fontSize = 9f.scaled,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            text = " ›",
            color = LitterTheme.textMuted.copy(alpha = 0.55f),
            fontFamily = LitterTheme.monoFont,
            fontSize = 9f.scaled,
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
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        lineage.members.forEach { member ->
            val isCurrent = member.key == currentKey
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(percent = 50))
                    .background(
                        if (isCurrent) LitterTheme.accent.copy(alpha = 0.12f)
                        else LitterTheme.surface.copy(alpha = 0.6f),
                    )
                    .border(
                        width = 1.dp,
                        color = if (isCurrent) LitterTheme.accent.copy(alpha = 0.6f)
                            else LitterTheme.border.copy(alpha = 0.6f),
                        shape = RoundedCornerShape(percent = 50),
                    )
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(5.dp)
                        .background(
                            if (isCurrent) LitterTheme.accent
                            else LitterTheme.textMuted.copy(alpha = 0.5f),
                            androidx.compose.foundation.shape.CircleShape,
                        ),
                )
                Text(
                    text = member.title,
                    color = if (isCurrent) LitterTheme.accent
                        else LitterTheme.textSecondary.copy(alpha = 0.85f),
                    fontFamily = LitterTheme.monoFont,
                    fontSize = 10f.scaled,
                    fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}
