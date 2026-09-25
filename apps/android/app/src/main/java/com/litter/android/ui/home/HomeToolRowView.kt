package com.litter.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppToolLogEntry

/**
 * Single tool-log row rendered inside the home session card. Used at zoom 3+.
 *
 * Takes a Rust-derived [AppToolLogEntry] directly; the `tool` field is a
 * short category name (`"Bash"`, `"Edit"`, `"MCP"`, `"Tool"`, `"Explore"`,
 * `"WebSearch"`) and the `detail` is the rolled-up label (for `"Explore"`
 * it's the exploration summary, e.g. `"Explored 3 files"`).
 *
 * Ref: HomeDashboardView.swift (`toolRowView`, `toolIconView`).
 */
@Composable
fun HomeToolRowView(
    entry: AppToolLogEntry,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = entry.detail,
            color = LitterTheme.textSecondary,
            fontFamily = LitterTheme.monoFont,
            fontSize = TOOL_LOG_FONT_SP.scaled,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private const val TOOL_LOG_FONT_SP = 13f
