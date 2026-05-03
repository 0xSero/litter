package com.litter.android.ui.common

import android.os.Build
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.graphics.Color
import com.litter.android.ui.LitterTheme
import com.sigkitten.litter.android.BuildConfig

object BuildInfo {
    /// True only for release builds that came from a Play Store install.
    /// Debug builds and sideloads (adb installs, ADB shell, etc.) all return
    /// false. Note: Play's open/closed-test tracks also report
    /// `com.android.vending` as the installer, so this hides the label for
    /// alpha/beta testers too — accept this trade-off until we add a
    /// `BuildConfig` flag flipped per-track.
    val isPlayProductionInstall: Boolean
        get() {
            if (BuildConfig.DEBUG) return false
            return playInstallerPackage() == "com.android.vending"
        }

    val marketingVersion: String = BuildConfig.VERSION_NAME

    val buildNumber: Int = BuildConfig.VERSION_CODE

    /// "1.5.0 · 53306" — last 5 digits of versionCode with leading zeros
    /// stripped.
    val shortLabel: String
        get() {
            val padded = buildNumber.toString()
            val suffix = padded.takeLast(5).trimStart('0').ifEmpty { "0" }
            return "$marketingVersion · $suffix"
        }

    private fun playInstallerPackage(): String? {
        val ctx = appContextOrNull() ?: return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                ctx.packageManager.getInstallSourceInfo(ctx.packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                ctx.packageManager.getInstallerPackageName(ctx.packageName)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun appContextOrNull(): android.content.Context? = installContextRef
    private var installContextRef: android.content.Context? = null

    fun bindContext(context: android.content.Context) {
        if (installContextRef == null) {
            installContextRef = context.applicationContext
        }
    }
}

@Composable
fun DebugBuildLabel(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    remember(context) { BuildInfo.bindContext(context); 0 }
    if (BuildInfo.isPlayProductionInstall) return
    Text(
        text = BuildInfo.shortLabel,
        style = MaterialTheme.typography.labelSmall,
        color = LitterTheme.textMuted.copy(alpha = 0.55f),
        textAlign = TextAlign.End,
        modifier = modifier.padding(horizontal = 14.dp, vertical = 2.dp),
    )
}
