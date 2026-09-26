package com.litter.android.ui.conversation

import android.content.Context

/**
 * Remembers whether finished turns show their work chain expanded. Stored
 * locally; it is presentation state only and never touches conversation data.
 */
internal class TurnChainPreference(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences("litter_transcript", Context.MODE_PRIVATE)

    @Volatile
    private var cached: Boolean = prefs.getBoolean(KEY, false)

    var expandedByDefault: Boolean
        get() = cached
        set(value) {
            if (value == cached) return
            cached = value
            prefs.edit().putBoolean(KEY, value).apply()
        }

    private companion object {
        const val KEY = "turn_chain_expanded"
    }
}
