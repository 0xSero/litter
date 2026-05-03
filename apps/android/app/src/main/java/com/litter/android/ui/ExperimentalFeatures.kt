package com.litter.android.ui

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

enum class LitterFeature(
    val id: String,
    val displayName: String,
    val description: String,
    val defaultEnabled: Boolean,
) {
    REALTIME_VOICE(
        id = "realtime_voice",
        displayName = "Realtime",
        description = "Show the realtime voice launcher on the home screen.",
        defaultEnabled = true,
    ),
    IPC(
        id = "ipc",
        displayName = "IPC",
        description = "Attach to desktop IPC over SSH for faster sync, approvals, and resume. Requires reconnecting the server.",
        defaultEnabled = false,
    ),
    THINKING_MINIGAME(
        id = "thinking_minigame",
        displayName = "Thinking minigame",
        description = "Tap the Thinking shimmer while the assistant generates to play a tiny generated minigame.",
        defaultEnabled = false,
    ),
}

object ExperimentalFeatures {
    private const val PREFS = "litter_ui_prefs"
    private const val KEY = "litter.experimentalFeatures"

    private var overrides by mutableStateOf<Map<String, Boolean>>(emptyMap())

    fun initialize(context: Context) {
        @Suppress("UNCHECKED_CAST")
        overrides = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY, emptySet())
            ?.mapNotNull { entry ->
                val separator = entry.indexOf('=')
                if (separator <= 0 || separator >= entry.lastIndex) {
                    null
                } else {
                    val featureId = entry.substring(0, separator)
                    val value = entry.substring(separator + 1).toBooleanStrictOrNull() ?: return@mapNotNull null
                    featureId to value
                }
            }
            ?.toMap()
            ?: emptyMap()
    }

    fun isEnabled(feature: LitterFeature): Boolean {
        return overrides[feature.id] ?: feature.defaultEnabled
    }

    fun setEnabled(context: Context, feature: LitterFeature, enabled: Boolean) {
        val next = overrides.toMutableMap()
        if (enabled == feature.defaultEnabled) {
            next.remove(feature.id)
        } else {
            next[feature.id] = enabled
        }
        overrides = next.toMap()
        persist(context)
    }

    fun ipcSocketPathOverride(): String? {
        return if (isEnabled(LitterFeature.IPC)) {
            null
        } else {
            ""
        }
    }

    private fun persist(context: Context) {
        val encoded = overrides.entries.mapTo(linkedSetOf()) { (key, value) -> "$key=$value" }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(KEY, encoded)
            .apply()
    }
}
