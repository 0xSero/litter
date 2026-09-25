package com.litter.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Text scaling system matching iOS ConversationTextSize.
 * 7-level scale from tiny (0.65x) to huge (1.8x), default medium (1.0x).
 * All conversation text sizes are multiplied by this scale.
 */
enum class ConversationTextSize(val step: Int, val scale: Float, val label: String) {
    TINY(0, 0.65f, "Tiny"),
    SMALL(1, 0.8f, "Small"),
    MEDIUM(2, 1.0f, "Medium"),
    LARGE(3, 1.2f, "Large"),
    LARGER(4, 1.4f, "XL"),
    X_LARGE(5, 1.6f, "XXL"),
    HUGE(6, 1.8f, "Huge");

    companion object {
        val DEFAULT = MEDIUM

        fun fromStep(step: Int): ConversationTextSize =
            entries.firstOrNull { it.step == step } ?: DEFAULT
    }
}

/**
 * CompositionLocal providing the current text scale factor.
 * Read this in any composable to scale text: `fontSize = 14.scaled`
 */
val LocalTextScale = compositionLocalOf { ConversationTextSize.DEFAULT.scale }

/**
 * Scale a base value by the current app text scale. The result is in `sp`,
 * so the system font-size setting (accessibility) applies on top, the same
 * way iOS Dynamic Type does.
 */
val Int.scaled: TextUnit
    @Composable get() = (this@scaled * LocalTextScale.current).sp

val Float.scaled: TextUnit
    @Composable get() = (this@scaled * LocalTextScale.current).sp

/**
 * Semantic text sizes matching iOS UIFont text-style point sizes at default
 * (Large) dynamic type. iOS reads `UIFont.preferredFont(forTextStyle: .body)
 * .pointSize` for body — 17pt at the system default. Android mirrors those
 * values so `LitterTextStyle.<role>.scaled` produces the same physical size
 * as iOS's `.litterFont(size:)` at equal app-level scales.
 *
 * If you change these, change the iOS side at Extensions.swift:122 too.
 */
object LitterTextStyle {
    /** Main message body text — iOS .body = 17pt. */
    const val body = 17f
    /** User bubble / callout — iOS uses body (17pt). */
    const val callout = 17f
    /** Secondary title — iOS .subheadline = 15pt. */
    const val subheadline = 15f
    /** Section headers, small titles — iOS .footnote = 13pt. */
    const val footnote = 13f
    /** Small labels, timestamps — iOS .caption = 12pt. */
    const val caption = 12f
    /** Very small labels — iOS .caption2 = 11pt. */
    const val caption2 = 11f
    /** Code in messages — matches iOS body (17pt) per CodeBlockView. */
    const val code = 17f
    /** Large headings — iOS .headline = 17pt. */
    const val headline = 17f
}

/**
 * Persistent storage for text size preference.
 */
object TextSizePrefs {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY = "conversationTextSizeStep"

    var currentStep by mutableIntStateOf(ConversationTextSize.DEFAULT.step)
        private set

    val currentScale: Float
        get() = ConversationTextSize.fromStep(currentStep).scale

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        currentStep = prefs.getInt(KEY, ConversationTextSize.DEFAULT.step)
    }

    fun setStep(context: Context, step: Int) {
        val clamped = step.coerceIn(0, ConversationTextSize.entries.size - 1)
        currentStep = clamped
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY, clamped).apply()
    }
}

/**
 * Persistent conversation UI preferences that are shared across screens.
 */
object ConversationPrefs {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY_COLLAPSE_TURNS = "collapseTurns"

    var collapseTurns by mutableIntStateOf(0)
        private set

    fun initialize(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        collapseTurns = if (prefs.getBoolean(KEY_COLLAPSE_TURNS, false)) 1 else 0
    }

    fun setCollapseTurns(context: Context, enabled: Boolean) {
        collapseTurns = if (enabled) 1 else 0
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_COLLAPSE_TURNS, enabled).apply()
    }

    val areTurnsCollapsed: Boolean
        get() = collapseTurns != 0
}
