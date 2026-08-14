package com.litter.android.state

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import uniffi.codex_mobile_client.ThreadKey

/**
 * Per-thread conversation rebind ledger. Tracks a monotonic revision per
 * [ThreadKey] plus a single global revision, so Compose can scope
 * conversation-surface re-derivation to the visible thread and fall back
 * to a global rebind for unkeyed updates (approvals, pending inputs,
 * server/resync publishes).
 *
 * Entries are intentionally never removed: a Compose `remember`-cached
 * [StateFlow] for a re-added thread must keep collecting the same instance
 * or it would miss every later bump. Memory cost is one tiny flow per thread
 * ever seen in-process.
 *
 * Pure Kotlin (no `android.*` / UniFFI / AppModel dependency) so it is
 * plain-JVM-testable. [ThreadKey] is a UniFFI data class already used in
 * plain-JVM unit tests (see `SnapshotExtensionsTest`).
 */
class ThreadRevisionLedger {
    private val lock = Any()
    private val threadFlows = mutableMapOf<ThreadKey, MutableStateFlow<Long>>()
    private val globalFlow = MutableStateFlow(0L)

    val conversationGlobalRevision: StateFlow<Long> get() = globalFlow

    fun threadRevision(key: ThreadKey): StateFlow<Long> = synchronized(lock) {
        threadFlows.getOrPut(key) { MutableStateFlow(0L) }
    }

    fun bumpThread(key: ThreadKey) {
        synchronized(lock) {
            threadFlows.getOrPut(key) { MutableStateFlow(0L) }.also { it.value += 1 }
        }
    }

    fun bumpGlobal() {
        synchronized(lock) { globalFlow.value += 1 }
    }
}
