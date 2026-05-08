package com.litter.android.ui

import android.content.Context
import android.content.ContextWrapper
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.sp
import com.sigkitten.litter.android.R

object LitterTheme {
    private val activeTheme: LitterResolvedTheme
        get() = LitterThemeManager.activeTheme

    val themeKey: String
        get() = activeTheme.slug

    val isDark: Boolean
        get() = activeTheme.type == LitterColorThemeType.DARK

    val background: Color
        get() = activeTheme.background

    val accent: Color
        get() = activeTheme.accent

    val accentStrong: Color
        get() = activeTheme.accentStrong

    val onAccentStrong: Color
        get() = activeTheme.textOnAccent

    val textPrimary: Color
        get() = activeTheme.textPrimary

    val textSecondary: Color
        get() = activeTheme.textSecondary

    val textMuted: Color
        get() = activeTheme.textMuted

    val textBody: Color
        get() = activeTheme.textBody

    val textSystem: Color
        get() = activeTheme.textSystem

    val surface: Color
        get() = activeTheme.surface

    val surfaceLight: Color
        get() = activeTheme.surfaceLight

    val border: Color
        get() = activeTheme.border

    val divider: Color
        get() = activeTheme.separator

    val danger: Color
        get() = activeTheme.danger

    val success: Color
        get() = activeTheme.success

    val warning: Color
        get() = activeTheme.warning

    val codeBackground: Color
        get() = activeTheme.codeBackground

    val info = Color(0xFF7CAFD9)
    val violet = Color(0xFFC797D8)
    val amber = Color(0xFFD3A85E)
    val teal = Color(0xFF88C6C7)
    val olive = Color(0xFF9BCF8E)
    val sand = Color(0xFFE3A66F)

    val statusConnecting = warning
    val statusReady = accentStrong
    val statusError = danger
    val statusDisconnected = textMuted

    val toolCallCommand = Color(0xFFC7B072)
    val toolCallFileChange = info
    val toolCallFileDiff = Color(0xFF6FA9D8)
    val toolCallMcpCall = violet
    val toolCallMcpProgress = amber
    val toolCallWebSearch = teal
    val toolCallCollaboration = olive
    val toolCallImage = sand

    /** The current monospace font — Berkeley Mono when mono enabled, system mono otherwise. */
    val monoFont: FontFamily
        get() = if (LitterThemeManager.monoFontEnabled) BerkeleyMono else FontFamily.Monospace

    val backgroundBrush: Brush
        get() =
            Brush.linearGradient(
            colors =
                listOf(
                    background,
                    LitterResolvedTheme.adjustBrightness(
                        background,
                        if (isDark) 0.02f else -0.01f,
                    ),
                    LitterResolvedTheme.adjustBrightness(
                        background,
                        if (isDark) -0.01f else 0.01f,
                    ),
                ),
            )
}

val BerkeleyMono =
    FontFamily(
        Font(R.font.berkeley_mono_regular, weight = FontWeight.Normal, style = FontStyle.Normal),
        Font(R.font.berkeley_mono_oblique, weight = FontWeight.Normal, style = FontStyle.Italic),
        Font(R.font.berkeley_mono_bold, weight = FontWeight.Bold, style = FontStyle.Normal),
        Font(R.font.berkeley_mono_bold_oblique, weight = FontWeight.Bold, style = FontStyle.Italic),
    )

private val Mono = BerkeleyMono

@Suppress("DEPRECATION")
private val LitterPlatformTextStyle = PlatformTextStyle(includeFontPadding = false)

private fun litterTextStyle(
    fontFamily: FontFamily,
    fontWeight: FontWeight,
    fontSize: androidx.compose.ui.unit.TextUnit,
) = TextStyle(
    fontFamily = fontFamily,
    fontWeight = fontWeight,
    fontSize = fontSize,
    platformStyle = LitterPlatformTextStyle,
)

private fun buildTypography(fontFamily: FontFamily) =
    Typography(
        titleLarge =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 20.sp,
            ),
        titleMedium =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Medium,
                fontSize = 16.sp,
            ),
        titleSmall =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Medium,
                fontSize = 14.sp,
            ),
        headlineSmall =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 20.sp,
            ),
        bodyLarge =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Normal,
                fontSize = 16.sp,
            ),
        bodyMedium =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Normal,
                fontSize = 14.sp,
            ),
        bodySmall =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Normal,
                fontSize = 12.sp,
            ),
        labelLarge =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Medium,
                fontSize = 12.sp,
            ),
        labelMedium =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Medium,
                fontSize = 11.sp,
            ),
        labelSmall =
            litterTextStyle(
                fontFamily = fontFamily,
                fontWeight = FontWeight.Medium,
                fontSize = 10.sp,
            ),
    )

@Composable
fun LitterAppTheme(content: @Composable () -> Unit) {
    val appContext = LocalContext.current.applicationContext
    DisposableEffect(appContext) {
        LitterThemeManager.initialize(appContext)
        onDispose {}
    }

    val systemIsDark = isSystemInDarkTheme()
    val appearanceMode = LitterThemeManager.appearanceMode
    val lightThemeSlug = LitterThemeManager.lightTheme.slug
    val darkThemeSlug = LitterThemeManager.darkTheme.slug
    LaunchedEffect(appearanceMode, systemIsDark, lightThemeSlug, darkThemeSlug) {
        LitterThemeManager.applySystemTheme(systemIsDark)
    }

    val activeTheme = LitterThemeManager.activeTheme
    LitterSystemBarsEffect(useDarkTheme = activeTheme.type == LitterColorThemeType.DARK)

    val colorScheme =
        remember(activeTheme.slug, activeTheme.type) {
            if (activeTheme.type == LitterColorThemeType.DARK) {
                darkColorScheme(
                    primary = activeTheme.accentStrong,
                    onPrimary = activeTheme.textOnAccent,
                    secondary = activeTheme.textSecondary,
                    onSecondary = activeTheme.textPrimary,
                    background = activeTheme.background,
                    onBackground = activeTheme.textBody,
                    surface = activeTheme.surface,
                    onSurface = activeTheme.textBody,
                    error = activeTheme.danger,
                    onError = activeTheme.textOnAccent,
                    outline = activeTheme.border,
                )
            } else {
                lightColorScheme(
                    primary = activeTheme.accentStrong,
                    onPrimary = activeTheme.textOnAccent,
                    secondary = activeTheme.textSecondary,
                    onSecondary = activeTheme.textPrimary,
                    background = activeTheme.background,
                    onBackground = activeTheme.textBody,
                    surface = activeTheme.surface,
                    onSurface = activeTheme.textBody,
                    error = activeTheme.danger,
                    onError = activeTheme.textOnAccent,
                    outline = activeTheme.border,
                )
            }
        }

    val monoFontEnabled = LitterThemeManager.monoFontEnabled
    val typography = if (monoFontEnabled) buildTypography(Mono) else buildTypography(FontFamily.Default)

    MaterialTheme(
        colorScheme = colorScheme,
        typography = typography,
        content = content,
    )
}

@Composable
private fun LitterSystemBarsEffect(useDarkTheme: Boolean) {
    val activity = LocalContext.current.findActivity()

    SideEffect {
        val componentActivity = activity ?: return@SideEffect
        val transparent = android.graphics.Color.TRANSPARENT
        val systemBarStyle =
            if (useDarkTheme) {
                SystemBarStyle.dark(transparent)
            } else {
                SystemBarStyle.light(transparent, transparent)
            }
        componentActivity.enableEdgeToEdge(
            statusBarStyle = systemBarStyle,
            navigationBarStyle = systemBarStyle,
        )
    }
}

private tailrec fun Context.findActivity(): ComponentActivity? =
    when (this) {
        is ComponentActivity -> this
        is ContextWrapper -> baseContext.findActivity()
        else -> null
    }

@Preview(showBackground = true, backgroundColor = 0xFF000000)
@Composable
private fun LitterThemePreview() {
    LitterAppTheme {
        Surface(color = LitterTheme.background) {
            Text(
                text = "Litter Theme",
                color = MaterialTheme.colorScheme.onBackground,
                style = MaterialTheme.typography.titleMedium,
            )
        }
    }
}
