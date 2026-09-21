package com.litter.android.ui

import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Compact animated logo — three kittens in a box.
 * Same animation as the splash screen but sized for inline use (header, nav bar).
 */
@Composable
fun AnimatedLogo(size: Dp = 44.dp) {
    val elapsedMillis = remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        val startedAt = withInfiniteAnimationFrameMillis { it }
        while (true) {
            withInfiniteAnimationFrameMillis { elapsedMillis.longValue = it - startedAt }
        }
    }

    Canvas(modifier = Modifier.size(size)) {
        val s = min(this.size.width, this.size.height)
        val scale = s / 500f
        val ox = (this.size.width - s) / 2f
        val oy = (this.size.height - s) / 2f
        // Observe animation time only while drawing, so the header stays composed.
        val anim = LogoAnimState(elapsedMillis.longValue / 1_000.0)

        drawLogoLeftKitten(scale, ox, oy, anim)
        drawLogoRightKitten(scale, ox, oy, anim)
        drawLogoCenterKitten(scale, ox, oy, anim)
        drawLogoBox(scale, ox, oy)
        drawLogoPaws(scale, ox, oy)
    }
}

// Reuse the same animation state and drawing from AnimatedSplashScreen,
// but as a standalone composable without background/text.

private class LogoAnimState(t: Double) {
    val bobLeft = (sin(t * 1.8) * 0.5 + 0.5).toFloat()
    val bobCenter = (sin(t * 1.5 + 0.8) * 0.5 + 0.5).toFloat()
    val bobRight = (sin(t * 2.0 + 1.6) * 0.5 + 0.5).toFloat()
    val eyeLeft = blinkPulse(t, 2.2, 0.0)
    val eyeRight = blinkPulse(t, 2.8, 1.0)
    val earLeft = earTwitch(t, 3.0, 0.5, -15f)
    val earRight = earTwitch(t, 3.5, 1.5, 15f)
    val meow = meowPulse(t, 3.0, 1.0)

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

        fun earTwitch(t: Double, period: Double, offset: Double, degrees: Float): Float {
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
            val dur = 0.5
            val fade = 0.1
            if (phase < dur) {
                if (phase < fade) return (phase / fade).toFloat()
                if (phase > dur - fade) return ((dur - phase) / fade).toFloat()
                return 1f
            }
            return 0f
        }
    }
}

private val LGray = Color(0xFFE5E7EB)
private val LInk = Color(0xFF1F2937)
private val LGrayW = Color(0xFFC0C4CA)
private val LCharcoal = Color(0xFF374151)
private val LWhite = Color(0xFFF9FAFB)
private val LCharcoalW = Color(0xFF4B5563)
private val LGinger = Color(0xFFF59E0B)
private val LGingerW = Color(0xFFC8860E)
private val LBox = Color(0xFFD98A53)
private val LLip = Color(0xFFC27A45)
private val LHandle = Color(0xFFB06535)
private val LDarkPaw = Color(0xFF4B5563)

private fun p(x: Float, y: Float, s: Float, ox: Float, oy: Float) = Offset(ox + x * s, oy + y * s)
private fun DrawScope.tri(p1: Offset, p2: Offset, p3: Offset, c: Color) {
    drawPath(Path().apply { moveTo(p1.x, p1.y); lineTo(p2.x, p2.y); lineTo(p3.x, p3.y); close() }, c)
}
private fun DrawScope.wh(f: Offset, t: Offset, c: Color, w: Float) {
    drawLine(c, f, t, strokeWidth = w, cap = StrokeCap.Round)
}

private fun DrawScope.drawLogoLeftKitten(s: Float, ox: Float, oy: Float, a: LogoAnimState) {
    val by = -10f * s * a.bobLeft
    val pivot = p(140f, 200f, s, ox, oy + by)
    withTransform({ rotate(a.earLeft, pivot) }) {
        tri(p(125f, 200f, s, ox, oy + by), p(120f, 150f, s, ox, oy + by), p(150f, 180f, s, ox, oy + by), LGray)
    }
    tri(p(199f, 200f, s, ox, oy + by), p(204f, 150f, s, ox, oy + by), p(174f, 180f, s, ox, oy + by), LGray)
    drawRoundRect(LGray, Offset(ox + 120 * s, oy + 170 * s + by), Size(84 * s, 100 * s), CornerRadius(42 * s))
    val er = 4 * s * a.eyeLeft; val eh = max(er * 2, 0.5f)
    drawOval(LInk, Offset(ox + 145 * s - er, oy + 210 * s + by - er), Size(er * 2, eh))
    drawOval(LInk, Offset(ox + 179 * s - er, oy + 210 * s + by - er), Size(er * 2, eh))
    tri(p(158f, 220f, s, ox, oy + by), p(166f, 220f, s, ox, oy + by), p(162f, 225f, s, ox, oy + by), LInk)
    val ww = 1.2f * s
    wh(p(120f, 216f, s, ox, oy + by), p(144f, 220f, s, ox, oy + by), LGrayW, ww)
    wh(p(118f, 222f, s, ox, oy + by), p(143f, 223f, s, ox, oy + by), LGrayW, ww)
    wh(p(180f, 220f, s, ox, oy + by), p(204f, 216f, s, ox, oy + by), LGrayW, ww)
    wh(p(181f, 223f, s, ox, oy + by), p(206f, 222f, s, ox, oy + by), LGrayW, ww)
}

private fun DrawScope.drawLogoRightKitten(s: Float, ox: Float, oy: Float, a: LogoAnimState) {
    val by = -8f * s * a.bobRight
    tri(p(301f, 200f, s, ox, oy + by), p(296f, 150f, s, ox, oy + by), p(326f, 180f, s, ox, oy + by), LCharcoal)
    val pivot = p(360f, 200f, s, ox, oy + by)
    withTransform({ rotate(a.earRight, pivot) }) {
        tri(p(375f, 200f, s, ox, oy + by), p(380f, 150f, s, ox, oy + by), p(350f, 180f, s, ox, oy + by), LCharcoal)
    }
    drawRoundRect(LCharcoal, Offset(ox + 296 * s, oy + 170 * s + by), Size(84 * s, 100 * s), CornerRadius(42 * s))
    val er = 4 * s * a.eyeRight; val eh = max(er * 2, 0.5f)
    drawOval(LWhite, Offset(ox + 321 * s - er, oy + 210 * s + by - er), Size(er * 2, eh))
    drawOval(LWhite, Offset(ox + 355 * s - er, oy + 210 * s + by - er), Size(er * 2, eh))
    tri(p(334f, 220f, s, ox, oy + by), p(342f, 220f, s, ox, oy + by), p(338f, 225f, s, ox, oy + by), LWhite)
    val ww = 1.2f * s
    wh(p(296f, 216f, s, ox, oy + by), p(320f, 220f, s, ox, oy + by), LCharcoalW, ww)
    wh(p(294f, 222f, s, ox, oy + by), p(319f, 223f, s, ox, oy + by), LCharcoalW, ww)
    wh(p(356f, 220f, s, ox, oy + by), p(380f, 216f, s, ox, oy + by), LCharcoalW, ww)
    wh(p(357f, 223f, s, ox, oy + by), p(382f, 222f, s, ox, oy + by), LCharcoalW, ww)
}

private fun DrawScope.drawLogoCenterKitten(s: Float, ox: Float, oy: Float, a: LogoAnimState) {
    val by = -14f * s * a.bobCenter; val m = a.meow
    tri(p(205f, 160f, s, ox, oy + by), p(200f, 105f, s, ox, oy + by), p(240f, 140f, s, ox, oy + by), LGinger)
    tri(p(295f, 160f, s, ox, oy + by), p(300f, 105f, s, ox, oy + by), p(260f, 140f, s, ox, oy + by), LGinger)
    drawRoundRect(LGinger, Offset(ox + 195 * s, oy + 130 * s + by), Size(110 * s, 150 * s), CornerRadius(55 * s))
    if (m < 0.99f) {
        val sw = 3f * s; val alpha = 1f - m
        val le = Path().apply { moveTo(ox + 222 * s, oy + 185 * s + by); quadraticTo(ox + 230 * s, oy + 176 * s + by, ox + 238 * s, oy + 185 * s + by) }
        val re = Path().apply { moveTo(ox + 262 * s, oy + 185 * s + by); quadraticTo(ox + 270 * s, oy + 176 * s + by, ox + 278 * s, oy + 185 * s + by) }
        drawPath(le, LInk.copy(alpha = alpha), style = Stroke(width = sw, cap = StrokeCap.Round))
        drawPath(re, LInk.copy(alpha = alpha), style = Stroke(width = sw, cap = StrokeCap.Round))
    }
    if (m > 0.01f) {
        val er = 5f * s
        drawCircle(LInk.copy(alpha = m), radius = er, center = Offset(ox + 230 * s, oy + 180 * s + by))
        drawCircle(LInk.copy(alpha = m), radius = er, center = Offset(ox + 270 * s, oy + 180 * s + by))
    }
    val ww = 1.2f * s
    wh(p(195f, 195f, s, ox, oy + by), p(228f, 200f, s, ox, oy + by), LGingerW, ww)
    wh(p(193f, 203f, s, ox, oy + by), p(227f, 204f, s, ox, oy + by), LGingerW, ww)
    wh(p(272f, 200f, s, ox, oy + by), p(305f, 195f, s, ox, oy + by), LGingerW, ww)
    wh(p(273f, 204f, s, ox, oy + by), p(307f, 203f, s, ox, oy + by), LGingerW, ww)
    val nu = -3f * s * m
    tri(Offset(ox + 246 * s, oy + 198 * s + by + nu), Offset(ox + 254 * s, oy + 198 * s + by + nu), Offset(ox + 250 * s, oy + 204 * s + by + nu), LInk)
    if (m > 0.01f) {
        val rx = 4f * s * m; val ry = 6f * s * m
        drawOval(LInk, Offset(ox + 250 * s - rx, oy + 206 * s + by), Size(rx * 2, ry * 2))
    }
}

private fun DrawScope.drawLogoBox(s: Float, ox: Float, oy: Float) {
    val bp = Path().apply {
        moveTo(ox + 100 * s, oy + 256 * s); lineTo(ox + 400 * s, oy + 256 * s)
        lineTo(ox + 385 * s, oy + 360 * s); quadraticTo(ox + 383 * s, oy + 366 * s, ox + 372 * s, oy + 370 * s)
        lineTo(ox + 128 * s, oy + 370 * s); quadraticTo(ox + 117 * s, oy + 366 * s, ox + 115 * s, oy + 360 * s); close()
    }
    drawPath(bp, LBox)
    drawRoundRect(LHandle.copy(alpha = 0.8f), Offset(ox + 220 * s, oy + 285 * s), Size(60 * s, 16 * s), CornerRadius(8 * s))
    val sp = Path().apply {
        moveTo(ox + 100 * s, oy + 256 * s); lineTo(ox + 400 * s, oy + 256 * s)
        lineTo(ox + 397 * s, oy + 268 * s); lineTo(ox + 103 * s, oy + 268 * s); close()
    }
    drawPath(sp, LHandle.copy(alpha = 0.4f))
    drawRoundRect(LLip, Offset(ox + 90 * s, oy + 240 * s), Size(320 * s, 16 * s), CornerRadius(8 * s))
}

private fun DrawScope.drawLogoPaws(s: Float, ox: Float, oy: Float) {
    for (x in listOf(135f, 165f)) drawRoundRect(Color.White, Offset(ox + x * s, oy + 234 * s), Size(18 * s, 28 * s), CornerRadius(9 * s))
    for (x in listOf(225f, 255f)) drawRoundRect(Color.White, Offset(ox + x * s, oy + 230 * s), Size(20 * s, 30 * s), CornerRadius(10 * s))
    for (x in listOf(317f, 347f)) drawRoundRect(LDarkPaw, Offset(ox + x * s, oy + 234 * s), Size(18 * s, 28 * s), CornerRadius(9 * s))
}
