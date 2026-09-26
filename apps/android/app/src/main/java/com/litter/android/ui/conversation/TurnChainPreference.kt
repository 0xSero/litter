package com.litter.android.ui.conversation

import android.content.Context
import android.content.SharedPreferences

/**
 * Remembers whether finished turns show their work chain expanded. Stored
 * locally; it is presentation state only and never touches conversation data.
 * Read once per process so opening a conversation does no repeated disk work.
 */
internal class TurnChainPreference private constructor(private val prefs: SharedPreferences) {
    @Volatile
    private var cached: Boolean = prefs.getBoolean(KEY, false)

    var expandedByDefault: Boolean
        get() = cached
        set(value) {
            if (value == cached) return
            cached = value
            prefs.edit().putBoolean(KEY, value).apply()
        }

    companion object {
        private const val KEY = "turn_chain_expanded"

        @Volatile
        private var instance: TurnChainPreference? = null

        fun get(context: Context): TurnChainPreference =
            instance ?: synchronized(this) {
                instance ?: TurnChainPreference(
                    context.applicationContext.getSharedPreferences("litter_transcript", Context.MODE_PRIVATE),
                ).also { instance = it }
            }
    }
}
