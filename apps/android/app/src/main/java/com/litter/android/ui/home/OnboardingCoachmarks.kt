package com.litter.android.ui.home

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LitterTheme
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

internal enum class CoachmarkTarget {
    AddServer,
    NewThread,
    Search,
    Voice,
}

private enum class CoachmarkLineStyle {
    SmoothCurve,
    SolidSquiggle,
    DashedSquiggle,
    Dotted,
}

private enum class CoachmarkLabelAlignment {
    Leading,
    Center,
    Trailing,
}

private data class CoachmarkItem(
    val id: CoachmarkTarget,
    val primary: String,
    val secondary: String?,
    val positionX: Float,
    val positionY: Float,
    val labelWidth: Dp,
    val labelAlignment: CoachmarkLabelAlignment,
    val style: CoachmarkLineStyle,
    val isPrimary: Boolean,
)

private val coachmarkItems = listOf(
    CoachmarkItem(
        id = CoachmarkTarget.AddServer,
        primary = "add a remote computer",
        secondary = "if you have one",
        positionX = 0.55f,
        positionY = 0.20f,
        labelWidth = 200.dp,
        labelAlignment = CoachmarkLabelAlignment.Center,
        style = CoachmarkLineStyle.SmoothCurve,
        isPrimary = false,
    ),
    CoachmarkItem(
        id = CoachmarkTarget.Search,
        primary = "see all\nyour threads",
        secondary = null,
        positionX = 0.92f,
        positionY = 0.62f,
        labelWidth = 110.dp,
        labelAlignment = CoachmarkLabelAlignment.Trailing,
        style = CoachmarkLineStyle.DashedSquiggle,
        isPrimary = false,
    ),
    CoachmarkItem(
        id = CoachmarkTarget.NewThread,
        primary = "start a new thread",
        secondary = "or just type a message",
        positionX = 0.50f,
        positionY = 0.70f,
        labelWidth = 220.dp,
        labelAlignment = CoachmarkLabelAlignment.Center,
        style = CoachmarkLineStyle.SolidSquiggle,
        isPrimary = true,
    ),
    CoachmarkItem(
        id = CoachmarkTarget.Voice,
        primary = "realtime voice",
        secondary = "needs OpenAI key in Settings",
        positionX = 0.20f,
        positionY = 0.78f,
        labelWidth = 160.dp,
        labelAlignment = CoachmarkLabelAlignment.Leading,
        style = CoachmarkLineStyle.Dotted,
        isPrimary = false,
    ),
)

@Composable
internal fun OnboardingCoachmarks(
    targets: Map<CoachmarkTarget, Rect>,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier = modifier) {
        val transition = rememberInfiniteTransition(label = "coachmarkHalo")
        val haloPhase by transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 1600),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "coachmarkHaloPhase",
        )
        val density = LocalDensity.current
        val widthPx = with(density) { maxWidth.toPx() }
        val heightPx = with(density) { maxHeight.toPx() }
        val labelHeightPx = with(density) { 60.dp.toPx() }
        val clampPx = with(density) { 8.dp.toPx() }
        val voiceFallback = rememberVoiceFallback(widthPx, heightPx, density)
        val resolved = coachmarkItems.mapNotNull { item ->
            val target = targets[item.id] ?: if (item.id == CoachmarkTarget.Voice) voiceFallback else null
            target?.let { item to it }
        }
        val labelRects = resolved.associate { (item, _) ->
            val labelWidthPx = with(density) { item.labelWidth.toPx() }
            val proposedX = widthPx * item.positionX - labelWidthPx / 2f
            val proposedY = heightPx * item.positionY - labelHeightPx / 2f
            val clampedX = proposedX.coerceIn(clampPx, widthPx - labelWidthPx - clampPx)
            val clampedY = proposedY.coerceIn(clampPx, heightPx - labelHeightPx - clampPx)
            item.id to Rect(clampedX, clampedY, clampedX + labelWidthPx, clampedY + labelHeightPx)
        }

        resolved.forEach { (item, targetRect) ->
            val labelRect = labelRects[item.id] ?: return@forEach
            // Keep the original painter order: each halo precedes its arrow.
            // Only this canvas observes time; static arrows retain their layers.
            if (item.isPrimary) {
                Canvas(modifier = Modifier.matchParentSize()) {
                    drawCoachmarkHalo(targetRect, haloPhase)
                }
            }
            Box(
                modifier = Modifier.matchParentSize().graphicsLayer().drawWithCache {
                    val arrow = makeCoachmarkArrow(
                        from = labelRect.center,
                        to = targetRect.center,
                        targetRect = targetRect,
                        labelRect = labelRect,
                        style = item.style,
                        isPrimary = item.isPrimary,
                    )
                    onDrawBehind {
                        drawPath(
                            arrow.path,
                            LitterTheme.accent.copy(alpha = if (item.isPrimary) 0.95f else 0.80f),
                            style = arrow.stroke,
                        )
                        drawPath(arrow.head, LitterTheme.accent.copy(alpha = if (item.isPrimary) 0.95f else 0.9f))
                    }
                },
            )
        }

        resolved.forEach { (item, _) ->
            val labelRect = labelRects[item.id] ?: return@forEach
            CoachmarkLabel(
                item = item,
                modifier = Modifier
                    .offset {
                        IntOffset(labelRect.left.roundToInt(), labelRect.top.roundToInt())
                    }
                    .size(width = item.labelWidth, height = 60.dp),
            )
        }
    }
}

@Composable
private fun rememberVoiceFallback(
    widthPx: Float,
    heightPx: Float,
    density: androidx.compose.ui.unit.Density,
): Rect {
    return with(density) {
        val size = 44.dp.toPx()
        val leading = 14.dp.toPx()
        val bottomInset = 4.dp.toPx()
        Rect(
            left = leading,
            top = heightPx - bottomInset - size,
            right = leading + size,
            bottom = heightPx - bottomInset,
        )
    }
}

@Composable
private fun CoachmarkLabel(
    item: CoachmarkItem,
    modifier: Modifier = Modifier,
) {
    val alignment = when (item.labelAlignment) {
        CoachmarkLabelAlignment.Leading -> Alignment.TopStart
        CoachmarkLabelAlignment.Center -> Alignment.TopCenter
        CoachmarkLabelAlignment.Trailing -> Alignment.TopEnd
    }
    val textAlign = when (item.labelAlignment) {
        CoachmarkLabelAlignment.Leading -> TextAlign.Start
        CoachmarkLabelAlignment.Center -> TextAlign.Center
        CoachmarkLabelAlignment.Trailing -> TextAlign.End
    }
    Box(modifier = modifier, contentAlignment = alignment) {
        androidx.compose.foundation.layout.Column(
            horizontalAlignment = when (item.labelAlignment) {
                CoachmarkLabelAlignment.Leading -> Alignment.Start
                CoachmarkLabelAlignment.Center -> Alignment.CenterHorizontally
                CoachmarkLabelAlignment.Trailing -> Alignment.End
            },
        ) {
            val shadow = if (LitterTheme.isDark) {
                Shadow(color = Color.Black.copy(alpha = 0.7f), offset = Offset(0f, 1f), blurRadius = 4f)
            } else {
                null
            }
            Text(
                text = item.primary,
                color = LitterTheme.accent,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = LitterTheme.monoFont,
                textAlign = textAlign,
                style = androidx.compose.ui.text.TextStyle(shadow = shadow),
            )
            if (item.secondary != null) {
                Text(
                    text = item.secondary,
                    color = LitterTheme.textSecondary,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Normal,
                    fontFamily = LitterTheme.monoFont,
                    textAlign = textAlign,
                    style = androidx.compose.ui.text.TextStyle(shadow = shadow),
                )
            }
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawCoachmarkHalo(
    targetRect: Rect,
    phase: Float,
) {
    val radius = (max(targetRect.width, targetRect.height) + 18.dp.toPx()) / 2f
    val scale = 1f + 0.08f * phase
    val outerOpacity = 0.18f - 0.13f * phase
    val outerWidth = 4.dp.toPx() + 4.dp.toPx() * phase
    drawCircle(
        color = LitterTheme.accent.copy(alpha = outerOpacity),
        radius = radius * scale,
        center = targetRect.center,
        style = Stroke(width = outerWidth),
    )
    drawCircle(
        color = LitterTheme.accent.copy(alpha = 0.7f),
        radius = radius * scale,
        center = targetRect.center,
        style = Stroke(width = 1.5.dp.toPx()),
    )
}

private data class CoachmarkArrow(val path: Path, val head: Path, val stroke: Stroke)

private fun makeCoachmarkArrow(
    from: Offset,
    to: Offset,
    targetRect: Rect,
    labelRect: Rect,
    style: CoachmarkLineStyle,
    isPrimary: Boolean,
): CoachmarkArrow {
    val start = trimToRect(from = to, toward = from, rect = labelRect.inflate(6f))
    val endInset = if (style == CoachmarkLineStyle.SmoothCurve) -11f else -6f
    val end = trimToRect(from = from, toward = to, rect = targetRect.inflate(endInset))
    val dx = end.x - start.x
    val dy = end.y - start.y
    val length = max(1f, sqrt(dx * dx + dy * dy))
    val ux = dx / length
    val uy = dy / length
    val nx = -uy
    val ny = ux
    val path = when (style) {
        CoachmarkLineStyle.SmoothCurve -> makeSmoothCurve(start, end, nx, ny, length)
        CoachmarkLineStyle.SolidSquiggle,
        CoachmarkLineStyle.DashedSquiggle,
        CoachmarkLineStyle.Dotted,
        -> makeSquigglePath(
            start = start,
            end = end,
            dx = dx,
            dy = dy,
            nx = nx,
            ny = ny,
            length = length,
            amplitude = squiggleAmplitude(style, length),
        )
    }
    val headLen = 8f
    val headHalfWidth = 4.5f
    val baseX = end.x - ux * headLen
    val baseY = end.y - uy * headLen
    val leftX = baseX + (-uy) * headHalfWidth
    val leftY = baseY + ux * headHalfWidth
    val rightX = baseX - (-uy) * headHalfWidth
    val rightY = baseY - ux * headHalfWidth
    val head = Path().apply {
        moveTo(end.x, end.y)
        lineTo(leftX, leftY)
        lineTo(rightX, rightY)
        close()
    }
    return CoachmarkArrow(path, head, strokeStyle(style, isPrimary))
}

private fun squiggleAmplitude(style: CoachmarkLineStyle, length: Float): Float {
    if (length <= 70f) return 0f
    return when (style) {
        CoachmarkLineStyle.SolidSquiggle -> 5.5f
        CoachmarkLineStyle.DashedSquiggle -> 4.5f
        CoachmarkLineStyle.Dotted -> 0f
        CoachmarkLineStyle.SmoothCurve -> 0f
    }
}

private fun strokeStyle(style: CoachmarkLineStyle, isPrimary: Boolean): Stroke {
    return when (style) {
        CoachmarkLineStyle.SmoothCurve -> Stroke(width = 1.4f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        CoachmarkLineStyle.SolidSquiggle -> Stroke(
            width = if (isPrimary) 1.8f else 1.4f,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
        )
        CoachmarkLineStyle.DashedSquiggle -> Stroke(
            width = 1.4f,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(5f, 5f), 0f),
        )
        CoachmarkLineStyle.Dotted -> Stroke(
            width = 2.4f,
            cap = StrokeCap.Round,
            join = StrokeJoin.Round,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(0.01f, 7f), 0f),
        )
    }
}

private fun makeSquigglePath(
    start: Offset,
    end: Offset,
    dx: Float,
    dy: Float,
    nx: Float,
    ny: Float,
    length: Float,
    amplitude: Float,
): Path {
    val waves = max(2f, length / 44f)
    val steps = max(40, (length / 3f).roundToInt())
    return Path().apply {
        moveTo(start.x, start.y)
        for (i in 1..steps) {
            val t = i.toFloat() / steps.toFloat()
            val baseX = start.x + dx * t
            val baseY = start.y + dy * t
            val taper = sin((PI * t).toFloat())
            val phase = t * waves * 2f * PI.toFloat()
            val amp = amplitude * sin(phase) * taper
            lineTo(baseX + nx * amp, baseY + ny * amp)
        }
    }
}

private fun makeSmoothCurve(
    start: Offset,
    end: Offset,
    nx: Float,
    ny: Float,
    length: Float,
): Path {
    val mid = Offset((start.x + end.x) / 2f, (start.y + end.y) / 2f)
    val bend = min(7f, length * 0.06f)
    val control = Offset(mid.x + nx * bend, mid.y + ny * bend)
    return Path().apply {
        moveTo(start.x, start.y)
        quadraticTo(control.x, control.y, end.x, end.y)
    }
}

private fun trimToRect(from: Offset, toward: Offset, rect: Rect): Offset {
    val dx = from.x - toward.x
    val dy = from.y - toward.y
    val length = max(1f, sqrt(dx * dx + dy * dy))
    val ux = dx / length
    val uy = dy / length
    var t = 0f
    var probe = toward
    while (t <= length) {
        if (!rect.contains(probe)) return probe
        probe = Offset(probe.x + ux, probe.y + uy)
        t += 1f
    }
    return from
}

private fun Rect.inflate(amount: Float): Rect {
    return Rect(left - amount, top - amount, right + amount, bottom + amount)
}
