package com.litter.android.ui

import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sigkitten.litter.android.R
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Animated splash screen matching the iOS version.
 * Time-driven animation: bobbing kittens, blinking, ear twitches, meowing.
 */
@Composable
fun AnimatedSplashScreen() {
    val elapsedMillis = remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        val startedAt = withInfiniteAnimationFrameMillis { it }
        while (true) {
            withInfiniteAnimationFrameMillis { elapsedMillis.longValue = it - startedAt }
        }
    }
    // Read the clock in drawing/layer scopes: animation must not recompose
    // the splash layout, text, and provider images on every frame.

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val s = min(size.width, size.height) * 0.55f
            val scale = s / 500f
            val ox = (size.width - s) / 2f
            val oy = (size.height - s) / 2f - size.height * 0.05f
            val anim = KittenAnimState(elapsedMillis.longValue / 1_000.0)

            drawLeftKitten(scale, ox, oy, anim)
            drawRightKitten(scale, ox, oy, anim)
            drawCenterKitten(scale, ox, oy, anim)
            drawBox(scale, ox, oy)
            drawPaws(scale, ox, oy)
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 80.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SpinningProviderCarousel(elapsedMillis = elapsedMillis)
            Text(
                text = " on your phone",
                color = LitterTheme.textMuted,
                style = TextStyle(
                    fontFamily = LitterTheme.monoFont,
                    fontWeight = FontWeight.Normal,
                    fontSize = 14.sp,
                ),
            )
        }
    }
}

private data class SplashProvider(
    val label: String,
    val drawableId: Int,
)

private val SplashProviders = listOf(
    SplashProvider("codex", R.drawable.agent_codex),
    SplashProvider("opencode", R.drawable.agent_opencode),
    SplashProvider("amp", R.drawable.agent_amp),
    SplashProvider("pi", R.drawable.agent_pi),
    SplashProvider("claude", R.drawable.agent_claude),
    SplashProvider("droid", R.drawable.agent_droid),
    SplashProvider("devin", R.drawable.agent_devin),
    SplashProvider("grok", R.drawable.agent_grok),
)

@Composable
private fun SpinningProviderCarousel(elapsedMillis: State<Long>) {
    val itemHeight = 18f
    val density = LocalDensity.current
    val cycleHeight = itemHeight * SplashProviders.size

    Box(
        modifier = Modifier
            .width(104.dp)
            .height((itemHeight * 3).dp),
        contentAlignment = Alignment.CenterEnd,
    ) {
        SplashProviders.forEachIndexed { index, provider ->
            val selected by remember(index, elapsedMillis) {
                derivedStateOf {
                    val phase = providerCarouselPhase(elapsedMillis.value / 1_000.0)
                    abs(wrapCarouselOffset((index - phase).toFloat() * itemHeight, cycleHeight)) / itemHeight < 0.35f
                }
            }

            Row(
                modifier = Modifier
                    .align(Alignment.CenterEnd)
                    .graphicsLayer {
                        val phase = providerCarouselPhase(elapsedMillis.value / 1_000.0)
                        val y = wrapCarouselOffset((index - phase).toFloat() * itemHeight, cycleHeight)
                        val dist = min(abs(y) / itemHeight, 1f)
                        translationY = with(density) { y.dp.toPx() }
                        alpha = if (dist < 0.35f) 1f else max(0.18f, 1f - dist * 0.7f)
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Image(
                    painter = painterResource(provider.drawableId),
                    contentDescription = provider.label,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    text = provider.label,
                    color = if (selected) LitterTheme.textSecondary else LitterTheme.textMuted,
                    style = TextStyle(
                        fontFamily = LitterTheme.monoFont,
                        fontWeight = FontWeight.Normal,
                        fontSize = 14.sp,
                    ),
                    modifier = Modifier.padding(start = 5.dp),
                )
            }
        }
    }
}

private fun providerCarouselPhase(elapsed: Double): Double {
    val perWord = 0.9
    val transitionFraction = 0.45
    val totalCycle = perWord * SplashProviders.size
    val cycleT = elapsed % totalCycle
    val wordIndex = floor(cycleT / perWord)
    val withinWord = cycleT - wordIndex * perWord
    val dwell = perWord * (1.0 - transitionFraction)
    if (withinWord < dwell) {
        return wordIndex
    }
    val progress = (withinWord - dwell) / (perWord * transitionFraction)
    val eased = 0.5 - 0.5 * cos(progress * Math.PI)
    return wordIndex + eased
}

private fun wrapCarouselOffset(offset: Float, range: Float): Float {
    var value = offset % range
    if (value > range / 2f) {
        value -= range
    }
    if (value < -range / 2f) {
        value += range
    }
    return value
}

// ── Animation state from elapsed seconds ──

private class KittenAnimState(t: Double) {
    val bobLeft: Float = (sin(t * 1.4) * 0.5 + 0.5).toFloat()
    val bobCenter: Float = (sin(t * 1.2 + 0.8) * 0.5 + 0.5).toFloat()
    val bobRight: Float = (sin(t * 1.65 + 1.6) * 0.5 + 0.5).toFloat()
    val eyeLeft: Float = blinkPulse(t, 2.8, 0.0)
    val eyeRight: Float = blinkPulse(t, 3.5, 1.2)
    val earLeft: Float = earTwitchPulse(t, 4.5, 0.5, -10f)
    val earRight: Float = earTwitchPulse(t, 5.5, 2.0, 10f)
    val meow: Float = meowPulse(t, 4.0, 1.5)

    companion object {
        fun blinkPulse(t: Double, period: Double, offset: Double): Float {
            val phase = (t + offset) % period
            if (phase < 0.15) {
                val half = 0.075
                val d = if (phase < half) phase / half else (0.15 - phase) / half
                return (1.0 - d * 0.95).toFloat()
            }
            return 1f
        }

        fun earTwitchPulse(t: Double, period: Double, offset: Double, degrees: Float): Float {
            val phase = (t + offset) % period
            if (phase < 0.25) {
                val norm = phase / 0.25
                val curve = if (norm < 0.4) (norm / 0.4) else max(0.0, 1.0 - (norm - 0.4) / 0.6)
                return degrees * curve.toFloat()
            }
            return 0f
        }

        fun meowPulse(t: Double, period: Double, offset: Double): Float {
            val phase = (t + offset) % period
            val duration = 0.5
            val fade = 0.1
            if (phase < duration) {
                if (phase < fade) return (phase / fade).toFloat()
                if (phase > duration - fade) return ((duration - phase) / fade).toFloat()
                return 1f
            }
            return 0f
        }
    }
}

// ── Colors ──

private val Gray = Color(0xFFE5E7EB)
private val Ink = Color(0xFF1F2937)
private val GrayWhisker = Color(0xFFC0C4CA)
private val Charcoal = Color(0xFF374151)
private val White = Color(0xFFF9FAFB)
private val CharcoalWhisker = Color(0xFF4B5563)
private val Ginger = Color(0xFFF59E0B)
private val GingerWhisker = Color(0xFFC8860E)
private val BoxColor = Color(0xFFD98A53)
private val LipColor = Color(0xFFC27A45)
private val HandleColor = Color(0xFFB06535)
private val DarkPaw = Color(0xFF4B5563)

// ── Drawing helpers ──

private fun DrawScope.tri(p1: Offset, p2: Offset, p3: Offset, color: Color) {
    val path = Path().apply {
        moveTo(p1.x, p1.y); lineTo(p2.x, p2.y); lineTo(p3.x, p3.y); close()
    }
    drawPath(path, color)
}

private fun DrawScope.whisker(from: Offset, to: Offset, color: Color, width: Float) {
    drawLine(color, from, to, strokeWidth = width, cap = StrokeCap.Round)
}

private fun p(x: Float, y: Float, s: Float, ox: Float, oy: Float) = Offset(ox + x * s, oy + y * s)

// ── Left Kitten ──

private fun DrawScope.drawLeftKitten(s: Float, ox: Float, oy: Float, a: KittenAnimState) {
    val by = -5f * s * a.bobLeft

    // Left ear with twitch
    val pivot = p(140f, 200f, s, ox, oy + by)
    withTransform({
        rotate(a.earLeft, pivot)
    }) {
        tri(p(125f, 200f, s, ox, oy + by), p(120f, 150f, s, ox, oy + by), p(150f, 180f, s, ox, oy + by), Gray)
    }
    // Right ear
    tri(p(199f, 200f, s, ox, oy + by), p(204f, 150f, s, ox, oy + by), p(174f, 180f, s, ox, oy + by), Gray)

    // Body
    drawRoundRect(Gray, topLeft = Offset(ox + 120 * s, oy + 170 * s + by), size = Size(84 * s, 100 * s), cornerRadius = CornerRadius(42 * s))

    // Eyes
    val er = 4 * s * a.eyeLeft
    val eh = max(er * 2, 0.5f)
    drawOval(Ink, topLeft = Offset(ox + 145 * s - er, oy + 210 * s + by - er), size = Size(er * 2, eh))
    drawOval(Ink, topLeft = Offset(ox + 179 * s - er, oy + 210 * s + by - er), size = Size(er * 2, eh))

    // Nose
    tri(p(158f, 220f, s, ox, oy + by), p(166f, 220f, s, ox, oy + by), p(162f, 225f, s, ox, oy + by), Ink)

    // Whiskers
    val ww = 1.2f * s
    whisker(p(120f, 216f, s, ox, oy + by), p(144f, 220f, s, ox, oy + by), GrayWhisker, ww)
    whisker(p(118f, 222f, s, ox, oy + by), p(143f, 223f, s, ox, oy + by), GrayWhisker, ww)
    whisker(p(180f, 220f, s, ox, oy + by), p(204f, 216f, s, ox, oy + by), GrayWhisker, ww)
    whisker(p(181f, 223f, s, ox, oy + by), p(206f, 222f, s, ox, oy + by), GrayWhisker, ww)
}

// ── Right Kitten ──

private fun DrawScope.drawRightKitten(s: Float, ox: Float, oy: Float, a: KittenAnimState) {
    val by = -4f * s * a.bobRight

    // Left ear
    tri(p(301f, 200f, s, ox, oy + by), p(296f, 150f, s, ox, oy + by), p(326f, 180f, s, ox, oy + by), Charcoal)

    // Right ear with twitch
    val pivot = p(360f, 200f, s, ox, oy + by)
    withTransform({
        rotate(a.earRight, pivot)
    }) {
        tri(p(375f, 200f, s, ox, oy + by), p(380f, 150f, s, ox, oy + by), p(350f, 180f, s, ox, oy + by), Charcoal)
    }

    // Body
    drawRoundRect(Charcoal, topLeft = Offset(ox + 296 * s, oy + 170 * s + by), size = Size(84 * s, 100 * s), cornerRadius = CornerRadius(42 * s))

    // Eyes
    val er = 4 * s * a.eyeRight
    val eh = max(er * 2, 0.5f)
    drawOval(White, topLeft = Offset(ox + 321 * s - er, oy + 210 * s + by - er), size = Size(er * 2, eh))
    drawOval(White, topLeft = Offset(ox + 355 * s - er, oy + 210 * s + by - er), size = Size(er * 2, eh))

    // Nose
    tri(p(334f, 220f, s, ox, oy + by), p(342f, 220f, s, ox, oy + by), p(338f, 225f, s, ox, oy + by), White)

    // Whiskers
    val ww = 1.2f * s
    whisker(p(296f, 216f, s, ox, oy + by), p(320f, 220f, s, ox, oy + by), CharcoalWhisker, ww)
    whisker(p(294f, 222f, s, ox, oy + by), p(319f, 223f, s, ox, oy + by), CharcoalWhisker, ww)
    whisker(p(356f, 220f, s, ox, oy + by), p(380f, 216f, s, ox, oy + by), CharcoalWhisker, ww)
    whisker(p(357f, 223f, s, ox, oy + by), p(382f, 222f, s, ox, oy + by), CharcoalWhisker, ww)
}

// ── Center Kitten ──

private fun DrawScope.drawCenterKitten(s: Float, ox: Float, oy: Float, a: KittenAnimState) {
    val by = -7f * s * a.bobCenter
    val m = a.meow

    // Ears
    tri(p(205f, 160f, s, ox, oy + by), p(200f, 105f, s, ox, oy + by), p(240f, 140f, s, ox, oy + by), Ginger)
    tri(p(295f, 160f, s, ox, oy + by), p(300f, 105f, s, ox, oy + by), p(260f, 140f, s, ox, oy + by), Ginger)

    // Body
    drawRoundRect(Ginger, topLeft = Offset(ox + 195 * s, oy + 130 * s + by), size = Size(110 * s, 150 * s), cornerRadius = CornerRadius(55 * s))

    // Happy squint eyes (visible when not meowing)
    if (m < 0.99f) {
        val sw = 3f * s
        val alpha = 1f - m

        val leftEye = Path().apply {
            moveTo(ox + 222 * s, oy + 185 * s + by)
            quadraticTo(ox + 230 * s, oy + 176 * s + by, ox + 238 * s, oy + 185 * s + by)
        }
        val rightEye = Path().apply {
            moveTo(ox + 262 * s, oy + 185 * s + by)
            quadraticTo(ox + 270 * s, oy + 176 * s + by, ox + 278 * s, oy + 185 * s + by)
        }
        drawPath(leftEye, Ink.copy(alpha = alpha), style = Stroke(width = sw, cap = StrokeCap.Round))
        drawPath(rightEye, Ink.copy(alpha = alpha), style = Stroke(width = sw, cap = StrokeCap.Round))
    }

    // Open round eyes (visible when meowing)
    if (m > 0.01f) {
        val er = 5f * s
        drawCircle(Ink.copy(alpha = m), radius = er, center = Offset(ox + 230 * s, oy + 180 * s + by))
        drawCircle(Ink.copy(alpha = m), radius = er, center = Offset(ox + 270 * s, oy + 180 * s + by))
    }

    // Whiskers
    val ww = 1.2f * s
    whisker(p(195f, 195f, s, ox, oy + by), p(228f, 200f, s, ox, oy + by), GingerWhisker, ww)
    whisker(p(193f, 203f, s, ox, oy + by), p(227f, 204f, s, ox, oy + by), GingerWhisker, ww)
    whisker(p(272f, 200f, s, ox, oy + by), p(305f, 195f, s, ox, oy + by), GingerWhisker, ww)
    whisker(p(273f, 204f, s, ox, oy + by), p(307f, 203f, s, ox, oy + by), GingerWhisker, ww)

    // Nose (lifts during meow)
    val nu = -3f * s * m
    tri(
        Offset(ox + 246 * s, oy + 198 * s + by + nu),
        Offset(ox + 254 * s, oy + 198 * s + by + nu),
        Offset(ox + 250 * s, oy + 204 * s + by + nu),
        Ink,
    )

    // Meow mouth
    if (m > 0.01f) {
        val rx = 4f * s * m
        val ry = 6f * s * m
        drawOval(Ink, topLeft = Offset(ox + 250 * s - rx, oy + 206 * s + by), size = Size(rx * 2, ry * 2))
    }
}

// ── Box ──

private fun DrawScope.drawBox(s: Float, ox: Float, oy: Float) {
    val boxPath = Path().apply {
        moveTo(ox + 100 * s, oy + 256 * s)
        lineTo(ox + 400 * s, oy + 256 * s)
        lineTo(ox + 385 * s, oy + 360 * s)
        quadraticTo(ox + 383 * s, oy + 366 * s, ox + 372 * s, oy + 370 * s)
        lineTo(ox + 128 * s, oy + 370 * s)
        quadraticTo(ox + 117 * s, oy + 366 * s, ox + 115 * s, oy + 360 * s)
        close()
    }
    drawPath(boxPath, BoxColor)

    // Handle
    drawRoundRect(HandleColor.copy(alpha = 0.8f), topLeft = Offset(ox + 220 * s, oy + 285 * s), size = Size(60 * s, 16 * s), cornerRadius = CornerRadius(8 * s))

    // Inner shadow
    val shadowPath = Path().apply {
        moveTo(ox + 100 * s, oy + 256 * s)
        lineTo(ox + 400 * s, oy + 256 * s)
        lineTo(ox + 397 * s, oy + 268 * s)
        lineTo(ox + 103 * s, oy + 268 * s)
        close()
    }
    drawPath(shadowPath, HandleColor.copy(alpha = 0.4f))

    // Lip
    drawRoundRect(LipColor, topLeft = Offset(ox + 90 * s, oy + 240 * s), size = Size(320 * s, 16 * s), cornerRadius = CornerRadius(8 * s))
}

// ── Paws ──

private fun DrawScope.drawPaws(s: Float, ox: Float, oy: Float) {
    // Left kitten paws (white)
    for (x in listOf(135f, 165f)) {
        drawRoundRect(Color.White, topLeft = Offset(ox + x * s, oy + 234 * s), size = Size(18 * s, 28 * s), cornerRadius = CornerRadius(9 * s))
    }
    // Center kitten paws (white)
    for (x in listOf(225f, 255f)) {
        drawRoundRect(Color.White, topLeft = Offset(ox + x * s, oy + 230 * s), size = Size(20 * s, 30 * s), cornerRadius = CornerRadius(10 * s))
    }
    // Right kitten paws (dark)
    for (x in listOf(317f, 347f)) {
        drawRoundRect(DarkPaw, topLeft = Offset(ox + x * s, oy + 234 * s), size = Size(18 * s, 28 * s), cornerRadius = CornerRadius(9 * s))
    }
}
