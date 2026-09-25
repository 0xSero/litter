package com.litter.android.ui.conversation

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.litter.android.state.MinigameOverlayState
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.apps.MinigameWebView
import com.litter.android.ui.scaled

@Composable
fun MinigameOverlay(
    state: MinigameOverlayState,
    onClose: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .shadow(
                elevation = 12.dp,
                shape = RoundedCornerShape(16.dp),
                ambientColor = Color.Black.copy(alpha = 0.18f),
                spotColor = Color.Black.copy(alpha = 0.18f),
            )
            .clip(RoundedCornerShape(16.dp))
            .background(LitterTheme.surface)
            .border(0.5.dp, LitterTheme.textSecondary.copy(alpha = 0.15f), RoundedCornerShape(16.dp)),
    ) {
        Header(state = state, onClose = onClose)
        HorizontalDivider(color = LitterTheme.textSecondary.copy(alpha = 0.2f))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            when (state) {
                is MinigameOverlayState.Idle -> {}
                is MinigameOverlayState.Loading -> LoadingSkeleton()
                is MinigameOverlayState.Shown -> {
                    MinigameWebView(
                        widgetHtml = state.content.html,
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 4.dp, vertical = 4.dp),
                    )
                }
                is MinigameOverlayState.Failed -> FailureCard(message = state.message, onRetry = onRetry)
            }
        }
    }
}

@Composable
private fun Header(state: MinigameOverlayState, onClose: () -> Unit) {
    val title = when (state) {
        is MinigameOverlayState.Idle -> ""
        is MinigameOverlayState.Loading -> "Generating…"
        is MinigameOverlayState.Shown -> state.content.title
        is MinigameOverlayState.Failed -> "Couldn't generate"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onClose) {
            Icon(
                Icons.Default.Close,
                contentDescription = "Close minigame",
                tint = LitterTheme.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

private val LOADING_STAGES = listOf(
    "Choosing archetype…",
    "Sketching sprites…",
    "Scattering hazards…",
    "Tuning physics…",
    "Wiring up controls…",
    "Launching…",
)

@Composable
private fun LoadingSkeleton() {
    val transition = rememberInfiniteTransition(label = "minigame-skeleton-shimmer")
    val shimmerOffset by transition.animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "minigame-skeleton-offset",
    )
    val brush = Brush.linearGradient(
        colors = listOf(
            LitterTheme.textSecondary.copy(alpha = 0.18f),
            LitterTheme.accent.copy(alpha = 0.4f),
            LitterTheme.textSecondary.copy(alpha = 0.18f),
        ),
        start = Offset(shimmerOffset * 200f, 0f),
        end = Offset((shimmerOffset + 0.6f) * 200f, 0f),
    )
    val stageState = androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(0) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        while (true) {
            kotlinx.coroutines.delay(1200)
            stageState.value = (stageState.value + 1) % LOADING_STAGES.size
        }
    }
    val stageIndex = stageState.value
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = LOADING_STAGES[stageIndex],
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            fontWeight = FontWeight.Medium,
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(96.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(brush)
        )
        Box(
            Modifier
                .fillMaxWidth(0.7f)
                .height(14.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(brush)
        )
    }
}

@Composable
private fun FailureCard(message: String, onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "Couldn't generate a minigame.",
            color = LitterTheme.textPrimary,
            fontSize = LitterTextStyle.body.scaled,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            message,
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.footnote.scaled,
            style = TextStyle(textAlign = androidx.compose.ui.text.style.TextAlign.Center),
        )
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = onRetry,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = LitterTheme.accent,
                containerColor = Color.Transparent,
            ),
        ) {
            Text("Try again", fontSize = LitterTextStyle.footnote.scaled, fontWeight = FontWeight.SemiBold)
        }
    }
}
