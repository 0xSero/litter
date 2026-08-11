package com.litter.android.ui.home

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LocalTextScale
import com.litter.android.ui.conversation.StreamingMarkdownView

/**
 * Last-assistant markdown preview at zoom 3+. Shrinks to natural height when
 * the markdown is short; caps at a zoom-dependent fraction of screen height
 * and anchors the tail visible when long. Crossfades when [blockId] changes.
 *
 * Screen-height caps: 25% at zoom 3, 50% at zoom 4 — matches iOS.
 *
 * Ref: HomeDashboardView.swift:1040-1119 (`responsePreview`,
 * `responsePreviewMaxHeight`).
 */
@Composable
fun ResponsePreview(
    text: String,
    blockId: String,
    zoomLevel: Int,
    modifier: Modifier = Modifier,
) {
    if (text.length <= 20) return

    val configuration = LocalConfiguration.current
    val capFraction = if (zoomLevel >= 4) 0.5f else 0.25f
    val capDp = (configuration.screenHeightDp * capFraction).dp
    // Pass the unscaled base size — StreamingMarkdownText reads
    // LocalTextScale itself and applies it. Passing a pre-scaled value
    // would double-scale the preview (17 × scale × scale).
    val bodySize = LitterTextStyle.body

    Crossfade(
        targetState = blockId,
        animationSpec = tween(durationMillis = 300),
        modifier = modifier.padding(top = 4.dp).fillMaxWidth(),
        label = "ResponsePreviewCrossfade",
    ) { keyedId ->
        Box(modifier = Modifier.fillMaxWidth()) {
            ShrinkOrCapMarkdown(
                text = text,
                itemId = keyedId,
                capDp = capDp,
                bodySize = bodySize,
            )
        }
    }
}

@Composable
private fun ShrinkOrCapMarkdown(
    text: String,
    itemId: String,
    capDp: androidx.compose.ui.unit.Dp,
    bodySize: Float,
) {
    val density = LocalDensity.current
    val capPx = with(density) { capDp.roundToPx() }

    SubcomposeLayout(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = capDp)
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                drawRect(brush = fadeMaskBrush(size.height), blendMode = BlendMode.DstIn)
            },
    ) { constraints ->
        val measureConstraints = Constraints(
            minWidth = 0,
            maxWidth = constraints.maxWidth,
            minHeight = 0,
            maxHeight = Constraints.Infinity,
        )
        val natural = subcompose("natural") {
            Box(modifier = Modifier.fillMaxWidth().wrapContentHeight()) {
                StreamingMarkdownView(
                    text = text,
                    itemId = "preview-$itemId",
                    bodySize = bodySize,
                )
            }
        }.first().measure(measureConstraints)

        val fits = natural.height <= capPx
        val placeable = if (fits) {
            natural
        } else {
            subcompose("scrolled") {
                val scrollState = rememberScrollState()
                LaunchedEffect(text) { scrollState.scrollTo(scrollState.maxValue) }
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(state = scrollState, enabled = false),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.Bottom,
                ) {
                    StreamingMarkdownView(
                        text = text,
                        itemId = "preview-$itemId",
                        bodySize = bodySize,
                    )
                }
            }.first().measure(
                Constraints(
                    minWidth = 0,
                    maxWidth = constraints.maxWidth,
                    minHeight = 0,
                    maxHeight = capPx,
                ),
            )
        }
        layout(placeable.width, placeable.height) {
            placeable.placeRelative(0, 0)
        }
    }
}

private fun fadeMaskBrush(heightPx: Float): Brush {
    // Stops mirror the iOS mask: nearly-transparent top, opaque below ~22%.
    return Brush.verticalGradient(
        colorStops = arrayOf(
            0.0f to Color.Black.copy(alpha = 0.55f),
            0.10f to Color.Black.copy(alpha = 0.85f),
            0.22f to Color.Black,
            1.0f to Color.Black,
        ),
        startY = 0f,
        endY = heightPx,
    )
}
