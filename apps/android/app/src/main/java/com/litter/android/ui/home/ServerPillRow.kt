package com.litter.android.ui.home

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.litter.android.state.statusDotState
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.common.StatusDotState
import com.litter.android.ui.LitterSpacing
import androidx.compose.foundation.layout.heightIn
import com.litter.android.ui.common.AgentIconView
import com.litter.android.ui.common.runtimeSortIndex
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AgentRuntimeInfo
import com.litter.android.ui.common.AgentRuntimeKind
import uniffi.codex_mobile_client.AppServerSnapshot

private const val MaxRuntimeBadgesWithoutOverflow = 4
private const val RuntimeBadgesWhenOverflowing = 3

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ServerPillRow(
    servers: List<HomeServerEntry>,
    selectedServerId: String?,
    onTap: (HomeServerEntry) -> Unit,
    onReconnect: (HomeServerEntry) -> Unit,
    onRestartAppServer: (HomeServerEntry) -> Unit,
    onRename: (HomeServerEntry) -> Unit,
    onRemove: (HomeServerEntry) -> Unit,
    onAdd: () -> Unit,
    onAddBoundsChanged: (Rect) -> Unit = {},
) {
    val scroll = rememberScrollState()
    // Fixed height: the row is reserved from the first frame whether or not
    // any server has reported yet, so the list below never moves.
    Row(
        modifier = Modifier
            .height(LitterSpacing.touch)
            .horizontalScroll(scroll)
            .padding(horizontal = LitterSpacing.sm),
        horizontalArrangement = Arrangement.spacedBy(LitterSpacing.xxs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        servers.forEach { server ->
            androidx.compose.runtime.key(server.serverId) {
            ServerPill(
                server = server,
                isSelected = server.serverId == selectedServerId,
                onTap = { onTap(server) },
                onReconnect = { onReconnect(server) },
                onRestartAppServer = { onRestartAppServer(server) },
                onRename = { onRename(server) },
                onRemove = { onRemove(server) },
            )
            }
        }
        AddServerPill(
            onTap = onAdd,
            onBoundsChanged = onAddBoundsChanged,
        )
    }
}

/**
 * Text-only server switcher entry. Healthy servers show just their name; a
 * server that is connecting, reconnecting, or offline adds one quiet mono
 * word. The selected server is the one in full-strength text.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ServerPill(
    server: HomeServerEntry,
    isSelected: Boolean,
    onTap: () -> Unit,
    onReconnect: () -> Unit,
    onRestartAppServer: () -> Unit,
    onRename: () -> Unit,
    onRemove: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    val problem: Pair<String, Color>? = server.label?.let { it.text to it.color }

    Box {
        Row(
            modifier = Modifier
                .heightIn(min = LitterSpacing.touch)
                .clip(RoundedCornerShape(LitterSpacing.xs))
                .combinedClickable(
                    onClick = onTap,
                    onLongClick = { showMenu = true },
                )
                .padding(horizontal = LitterSpacing.xs),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(LitterSpacing.xs),
        ) {
            Text(
                text = server.displayName,
                color = if (isSelected) LitterTheme.textPrimary else LitterTheme.textSecondary,
                fontSize = LitterTextStyle.footnote.scaled,
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                fontFamily = LitterTheme.monoFont,
                maxLines = 1,
            )
            if (problem != null) {
                Text(
                    text = problem.first,
                    color = problem.second,
                    fontSize = LitterTextStyle.footnote.scaled,
                    fontFamily = LitterTheme.monoFont,
                    maxLines = 1,
                )
            }
        }
        DropdownMenu(expanded = showMenu, onDismissRequest = { showMenu = false }) {
            DropdownMenuItem(
                text = { Text("Reconnect") },
                onClick = { showMenu = false; onReconnect() },
            )
            if (server.snapshot != null) {
                DropdownMenuItem(
                    text = { Text("Restart app server") },
                    onClick = { showMenu = false; onRestartAppServer() },
                )
            }
            if (!server.isLocal) {
                DropdownMenuItem(
                    text = { Text("Rename") },
                    onClick = { showMenu = false; onRename() },
                )
            }
            DropdownMenuItem(
                text = { Text("Remove") },
                onClick = { showMenu = false; onRemove() },
            )
        }
    }
}

@Composable
private fun AddServerPill(
    onTap: () -> Unit,
    onBoundsChanged: (Rect) -> Unit,
) {
    Box(
        modifier = Modifier
            .onGloballyPositioned { onBoundsChanged(it.boundsInRoot()) }
            .heightIn(min = LitterSpacing.touch)
            .clip(RoundedCornerShape(LitterSpacing.xs))
            .clickable(onClickLabel = "Add server", onClick = onTap)
            .padding(horizontal = LitterSpacing.xs),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "+ server",
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontFamily = LitterTheme.monoFont,
        )
    }
}
