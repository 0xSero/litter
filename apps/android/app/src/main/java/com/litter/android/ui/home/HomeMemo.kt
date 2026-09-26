package com.litter.android.ui.home

import android.content.Context
import com.litter.android.state.SavedServer
import com.litter.android.state.SavedServerStore

/**
 * Home is recomposed from scratch on every back from a conversation. These
 * process-level memos keep that re-entry cheap: each derivation is recomputed
 * only when its inputs change (compared by identity, since snapshot lists are
 * immutable and replaced on change), so back-to-Home does no sorting,
 * lineage building, or storage reads when nothing changed.
 */
internal class IdentityMemo<V> {
    private var inputs: Array<out Any?>? = null
    private var value: Any? = null

    @Suppress("UNCHECKED_CAST")
    @Synchronized
    fun get(vararg keys: Any?, compute: () -> V): V {
        val last = inputs
        if (last != null && last.size == keys.size && last.indices.all { last[it] === keys[it] }) {
            return value as V
        }
        val next = compute()
        inputs = keys
        value = next
        return next
    }
}

internal object HomeMemo {
    val servers = IdentityMemo<List<uniffi.codex_mobile_client.AppServerSnapshot>>()
    val allSessions = IdentityMemo<List<uniffi.codex_mobile_client.AppSessionSummary>>()
    val lineage = IdentityMemo<Map<uniffi.codex_mobile_client.ThreadKey, ThreadLineage>>()
    val homeSessions = IdentityMemo<List<uniffi.codex_mobile_client.AppSessionSummary>>()

    @Volatile
    var savedAppsLoaded = false

    @Volatile
    private var remembered: List<SavedServer>? = null

    fun rememberedServers(context: Context): List<SavedServer> =
        remembered ?: SavedServerStore.remembered(context).also { remembered = it }

    fun invalidateRememberedServers() {
        remembered = null
    }
}
