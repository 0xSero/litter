package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import kotlinx.coroutines.delay
import kotlin.math.max
import kotlin.math.roundToLong

/**
 * Renders a compact stopwatch chip showing the elapsed time of a turn.
 *
 * Times are seconds since the unix epoch. Callers convert from
 * `AppSessionSummary.lastTurnStartMs` / `lastTurnEndMs` (precomputed by the
 * Rust reducer) at the call site.
 *
 * - When [endSeconds] is null, the chip ticks every second off the current
 *   wall clock.
 * - When [endSeconds] is set, the chip renders a static duration.
 *
 * Ref: HomeDashboardView.swift:1140-1174 (`TurnStopwatchChip`).
 */
@Composable
fun TurnStopwatchChip(
    startSeconds: Double,
    endSeconds: Double?,
    modifier: Modifier = Modifier,
) {
    val elapsed = if (endSeconds != null) {
        max(0.0, endSeconds - startSeconds)
    } else {
        val nowSeconds by produceState(
            initialValue = System.currentTimeMillis() / 1000.0,
            key1 = startSeconds,
        ) {
            while (true) {
                delay(1_000L)
                value = System.currentTimeMillis() / 1000.0
            }
        }
        max(0.0, nowSeconds - startSeconds)
    }

    val label = formatStopwatch(elapsed)
    val tint = LitterTheme.textSecondary

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = label,
            color = tint,
            fontFamily = LitterTheme.monoFont,
            fontSize = 13f.scaled,
        )
    }
}

internal fun formatStopwatch(seconds: Double): String {
    val total = seconds.roundToLong().coerceAtLeast(0L)
    if (total < 60) return "${total}s"
    val mins = total / 60
    val secs = total % 60
    return if (secs == 0L) "${mins}m" else "${mins}m${secs}s"
}
