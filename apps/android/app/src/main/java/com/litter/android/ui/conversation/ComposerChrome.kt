package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterComposer
import com.litter.android.ui.LitterRadius
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LitterType

/** The single raised composer card shared by the home and conversation composers. */
@Composable
fun Modifier.composerCardSurface(): Modifier =
    this
        .clip(LitterRadius.composerShape)
        .background(LitterComposer.card, LitterRadius.composerShape)
        .border(1.dp, LitterComposer.outline, LitterRadius.composerShape)

/** Large gray body placeholder ("Type / for commands"). */
@Composable
fun ComposerPlaceholder(text: String = "Type / for commands") {
    Text(text = text, style = LitterType.body, color = LitterComposer.placeholder, maxLines = 1)
}

/** 48dp raised circular control (attach, mic, stop recording). */
@Composable
fun ComposerCircleButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = LitterTheme.textPrimary,
    fill: Color = LitterComposer.controlFill,
) {
    Box(
        modifier = modifier
            .size(LitterComposer.control)
            .clip(CircleShape)
            .background(fill, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(LitterComposer.iconSize))
    }
}

/** Raised capsule showing the model display name; tap opens the model picker. */
@Composable
fun ComposerModelPill(
    label: String,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .heightIn(min = LitterComposer.control)
            .widthIn(max = 200.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(LitterComposer.controlFill, RoundedCornerShape(999.dp))
            .clickable(enabled = onClick != null, role = Role.Button) { onClick?.invoke() }
            .padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = LitterType.title,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Send: muted terracotta while empty/disabled, bright when ready. */
@Composable
fun ComposerSendButton(
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ComposerCircleButton(
        icon = Icons.Default.ArrowUpward,
        contentDescription = "Send",
        onClick = onClick,
        enabled = enabled,
        modifier = modifier,
        fill = if (enabled) LitterComposer.sendActive else LitterComposer.sendIdle,
        tint = if (enabled) LitterComposer.sendActiveIcon else LitterComposer.sendIdleIcon,
    )
}

/** Stop replaces send while a turn is running. */
@Composable
fun ComposerStopButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    ComposerCircleButton(
        icon = Icons.Default.Stop,
        contentDescription = "Cancel response",
        onClick = onClick,
        modifier = modifier,
        fill = LitterTheme.textPrimary,
        tint = LitterComposer.card,
    )
}
