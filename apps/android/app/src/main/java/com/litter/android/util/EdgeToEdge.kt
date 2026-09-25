package com.litter.android.util

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat

/**
 * Draws the app behind transparent system bars on every API level without
 * touching the window APIs Android 15 deprecated.
 *
 * On API 35+ edge-to-edge is enforced by the platform for apps targeting 35+,
 * so only the bar icon appearance is set. The legacy calls (decor fitting,
 * bar colors, cutout mode) run only on older releases where they are the
 * supported way to get the same result, which is what `enableEdgeToEdge()`
 * from activity 1.9 did unconditionally.
 */
object EdgeToEdge {
    fun apply(activity: Activity, darkBars: Boolean) {
        val window = activity.window
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            applyLegacy(activity)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Keep the gesture/nav bar fully transparent instead of a scrim.
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = !darkBars
            isAppearanceLightNavigationBars = !darkBars
        }
    }

    @Suppress("DEPRECATION")
    private fun applyLegacy(activity: Activity) {
        val window = activity.window
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
        }
    }
}
