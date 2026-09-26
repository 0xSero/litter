package com.litter.android.state

import android.content.Context
import uniffi.codex_mobile_client.MobilePreferences
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.preferencesAddHiddenThread
import uniffi.codex_mobile_client.preferencesAddPinnedThread
import uniffi.codex_mobile_client.preferencesLoad
import uniffi.codex_mobile_client.preferencesRemoveHiddenThread
import uniffi.codex_mobile_client.preferencesRemovePinnedThread

/**
 * Thin Kotlin wrapper around the Rust `preferences_*` functions. Rust owns
 * the storage format; Android only picks the directory and exposes the
 * typed shape to the rest of the app.
 */
object SavedThreadsStore {
    // All writes go through this object, so the last load stays valid until
    // the next write. Re-entering Home then reads pins/hidden from memory
    // instead of Rust + disk on every back navigation.
    private var cached: MobilePreferences? = null

    private fun load(context: Context): MobilePreferences = synchronized(this) {
        cached ?: preferencesLoad(MobilePreferencesDirectory.path(context)).also { cached = it }
    }

    private fun invalidate() = synchronized(this) { cached = null }

    fun pinnedKeys(context: Context): List<PinnedThreadKey> = load(context).pinnedThreads

    fun add(context: Context, key: PinnedThreadKey) {
        preferencesAddPinnedThread(MobilePreferencesDirectory.path(context), key)
        invalidate()
    }

    fun remove(context: Context, key: PinnedThreadKey) {
        preferencesRemovePinnedThread(MobilePreferencesDirectory.path(context), key)
        invalidate()
    }

    fun contains(context: Context, key: PinnedThreadKey): Boolean =
        pinnedKeys(context).contains(key)

    fun hiddenKeys(context: Context): List<PinnedThreadKey> = load(context).hiddenThreads

    fun hide(context: Context, key: PinnedThreadKey) {
        preferencesAddHiddenThread(MobilePreferencesDirectory.path(context), key)
        invalidate()
    }

    fun unhide(context: Context, key: PinnedThreadKey) {
        preferencesRemoveHiddenThread(MobilePreferencesDirectory.path(context), key)
        invalidate()
    }
}
