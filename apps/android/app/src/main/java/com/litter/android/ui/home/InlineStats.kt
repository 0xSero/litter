package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppSessionSummary

/**
 * Compact right-aligned stat chip row: turn count / tool count / diff /
 * stopwatch / token usage. Meant to live on the same line as the model
 * badge at zoom 3+, taking just enough width so left-side text (which
 * carries `weight(1f)`) truncates before these chips compress.
 *
 * Stopwatch bounds come from `session.lastTurnStartMs` / `lastTurnEndMs`
 * (precomputed by the Rust reducer) so the card stays pure-prop-driven —
 * no `appModel.threadSnapshot` read, no AttributeGraph subscription
 * per session.
 *
 * Ref: HomeDashboardView.swift:820-855 (`inlineStats`).
 */
@Composable
fun InlineStats(
    session: AppSessionSummary,
    isActive: Boolean,
    modifier: Modifier = Modifier,
) {
    val stats = session.stats
    val turnCount = stats?.turnCount?.toInt() ?: 0
    val toolCallCount = stats?.toolCallCount?.toInt() ?: 0
    val additions = stats?.diffAdditions?.toInt() ?: 0
    val deletions = stats?.diffDeletions?.toInt() ?: 0
    val startSeconds = session.lastTurnStartMs?.let { it.toDouble() / 1000.0 }
    val endSeconds = if (isActive) {
        null
    } else {
        session.lastTurnEndMs?.let { it.toDouble() / 1000.0 }
    }
    val tokenUsage = session.tokenUsage

    Row(
        modifier = modifier.wrapContentWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (turnCount > 0) {
            Text(
                text = "$turnCount turns",
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = CHIP_FONT_SP.scaled,
            )
        }
        if (toolCallCount > 0) {
            Text(
                text = "$toolCallCount tools",
                color = LitterTheme.textSecondary,
                fontFamily = LitterTheme.monoFont,
                fontSize = CHIP_FONT_SP.scaled,
            )
        }
        if (additions > 0 || deletions > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = "+$additions",
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = CHIP_FONT_SP.scaled,
                )
                Text(
                    text = "-$deletions",
                    color = LitterTheme.textSecondary,
                    fontFamily = LitterTheme.monoFont,
                    fontSize = CHIP_FONT_SP.scaled,
                )
            }
        }
        if (startSeconds != null) {
            TurnStopwatchChip(
                startSeconds = startSeconds,
                endSeconds = endSeconds,
            )
        }
        val window = tokenUsage?.contextWindow
        if (tokenUsage != null && window != null && window > 0L) {
            val pct = ((tokenUsage.totalTokens.toDouble() / window.toDouble()) * 100.0).toInt()
            val color = if (pct > 80) {
                LitterTheme.warning
            } else {
                LitterTheme.textSecondary
            }
            Text(
                text = "$pct%",
                color = color,
                fontFamily = LitterTheme.monoFont,
                fontSize = CHIP_FONT_SP.scaled,
            )
        }
    }
}

private const val CHIP_FONT_SP = 13f
