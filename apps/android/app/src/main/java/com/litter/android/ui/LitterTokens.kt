package com.litter.android.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em

/**
 * Litter Quiet layout tokens (docs/design, round 6).
 *
 * Spacing is the only separator between things: 4 / 8 / 12 / 20 / 32, page
 * margins 20, list rows ~62, 32 between conversation turns. Radius is used
 * only on raised surfaces (code, widgets, menus 14; sheet tops 16; composer 26).
 */
object LitterSpacing {
    val xxs = 4.dp
    val xs = 8.dp
    val sm = 12.dp
    val md = 20.dp
    val lg = 32.dp

    /** Horizontal page margin. */
    val margin = 20.dp

    /** Minimum height of a two-line list row (title + meta). */
    val row = 62.dp

    /** Vertical space between whole conversation turns. */
    val turn = 32.dp

    /** Minimum touch target. */
    val touch = 48.dp
}

object LitterRadius {
    val raised = 14.dp
    val sheet = 16.dp
    val composer = 26.dp

    val raisedShape = RoundedCornerShape(raised)
    val sheetShape = RoundedCornerShape(topStart = sheet, topEnd = sheet)
    val composerShape = RoundedCornerShape(composer)
}

/** Semantic colors layered on the active theme; no new accent is introduced. */
object LitterQuiet {
    /** Raised surfaces: code, widgets, sheets, menus, composer. */
    val raised: Color
        get() = LitterTheme.codeBackground

    /** Content text. */
    val text: Color
        get() = LitterTheme.textPrimary

    /** Metadata text (mono 13, lowercase). */
    val meta: Color
        get() = LitterTheme.textSecondary

    /** 2dp rule to the left of user messages. */
    val userRule: Color
        get() = lerp(LitterTheme.background, LitterTheme.textSecondary, if (LitterTheme.isDark) 0.28f else 0.24f)

    /** Faint 1dp line between whole turns. */
    val turnDivider: Color
        get() = lerp(LitterTheme.background, LitterTheme.textSecondary, if (LitterTheme.isDark) 0.1f else 0.08f)

    val warn: Color
        get() = LitterTheme.warning

    val error: Color
        get() = LitterTheme.danger
}

/**
 * The two text styles that carry almost everything: body 17 at ~1.45 line
 * height for content, and mono 13 gray for metadata. Sizes honor both the
 * app text-size setting and the system font scale.
 */
object LitterType {
    const val META_SIZE = 13f
    const val BODY_SIZE = 17f
    const val BODY_LINE_HEIGHT = 1.45f

    val body: TextStyle
        @Composable get() =
            TextStyle(
                fontFamily = LitterTheme.bodyFont,
                fontSize = BODY_SIZE.scaled,
                lineHeight = BODY_LINE_HEIGHT.em,
                color = LitterQuiet.text,
            )

    val title: TextStyle
        @Composable get() =
            TextStyle(
                fontFamily = LitterTheme.bodyFont,
                fontSize = BODY_SIZE.scaled,
                fontWeight = FontWeight.Normal,
                color = LitterQuiet.text,
            )

    val navTitle: TextStyle
        @Composable get() =
            TextStyle(
                fontFamily = LitterTheme.bodyFont,
                fontSize = BODY_SIZE.scaled,
                fontWeight = FontWeight.SemiBold,
                color = LitterQuiet.text,
            )

    val meta: TextStyle
        @Composable get() =
            TextStyle(
                fontFamily = LitterTheme.monoFont,
                fontSize = META_SIZE.scaled,
                color = LitterQuiet.meta,
            )
}

/** Joins up to three non-blank metadata items with " · ", lowercased. */
fun metaLine(vararg items: String?): String =
    items.asSequence()
        .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
        .take(3)
        .joinToString(" · ")
        .lowercase()
