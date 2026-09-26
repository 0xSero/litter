package com.litter.android.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * The Litter mark: an abstract line drawing of a cat sitting in a basket
 * (docs/design launch.webp). One stroke color from the theme, no animation
 * beyond an optional one-shot fade in. Replaces the animated kitten logo,
 * the splash kittens, and the home cat GIFs. The app icon is separate.
 */
@Composable
fun LitterMark(
    size: Dp,
    modifier: Modifier = Modifier,
    color: Color = LitterTheme.textSecondary,
    fadeIn: Boolean = false,
) {
    val alpha = remember { Animatable(if (fadeIn) 0f else 1f) }
    if (fadeIn) {
        LaunchedEffect(Unit) { alpha.animateTo(1f, tween(durationMillis = 240)) }
    }
    Canvas(
        modifier = modifier
            .size(size)
            .graphicsLayer { this.alpha = alpha.value }
            .semantics { contentDescription = "Litter" },
    ) {
        val s = min(this.size.width, this.size.height)
        val ox = (this.size.width - s) / 2f
        val oy = (this.size.height - s) / 2f
        fun x(v: Float) = ox + v / 100f * s
        fun y(v: Float) = oy + v / 100f * s
        val stroke = Stroke(
            width = s * 0.05f,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        )
        // Head: two pointed ears over a soft crown, sides dropping into the basket.
        val head = Path().apply {
            moveTo(x(30f), y(56f))
            lineTo(x(30f), y(36f))
            lineTo(x(35f), y(19f))
            lineTo(x(45f), y(29f))
            quadraticTo(x(50f), y(27.5f), x(55f), y(29f))
            lineTo(x(65f), y(19f))
            lineTo(x(70f), y(36f))
            lineTo(x(70f), y(56f))
        }
        // Closed eyes: two short arcs.
        val eyes = Path().apply {
            moveTo(x(39f), y(42f))
            quadraticTo(x(42f), y(45f), x(45f), y(42f))
            moveTo(x(55f), y(42f))
            quadraticTo(x(58f), y(45f), x(61f), y(42f))
        }
        // Basket: rim, tapered bowl, one weave line.
        val basket = Path().apply {
            moveTo(x(17f), y(56f))
            lineTo(x(83f), y(56f))
            moveTo(x(20f), y(56f))
            lineTo(x(27f), y(80f))
            lineTo(x(73f), y(80f))
            lineTo(x(80f), y(56f))
            moveTo(x(23.5f), y(68f))
            lineTo(x(76.5f), y(68f))
        }
        drawPath(head, color, style = stroke)
        drawPath(eyes, color, style = stroke)
        drawPath(basket, color, style = stroke)
    }
}

/** Default mark size used in the Home header. */
val LitterMarkHeaderSize = 28.dp
