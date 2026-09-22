package com.litter.android.state

import android.os.SystemClock
import android.util.Log
import com.sigkitten.litter.android.BuildConfig
import uniffi.codex_mobile_client.ThreadKey

/**
 * Android counterpart of the iOS `PerfTracker`.
 *
 * A user-visible latency ("tap → conversation shown", "send → first streamed
 * token") begins in one place and ends in another, usually across a coroutine
 * suspension. `android.os.Trace.beginAsyncSection` cannot carry that on this
 * app's `minSdk` (26) — it is only public from API 29 — and `androidx.tracing`
 * would be a new dependency for a debug-only measurement. So intervals are timed
 * with [SystemClock.uptimeMillis] and reported on the `perf` log tag, which is
 * the same shape the iOS side writes to its `perf` log category:
 *
 * ```
 * perf: OpenThread latency key=srv/thr 214.30ms
 * ```
 *
 * `tools/scripts/measure-interaction-latency.sh android` parses those lines out
 * of logcat. Every method is a no-op outside debug builds.
 *
 * [uptimeMillis] is the right clock: it excludes deep sleep, so a measurement
 * never reports time the device spent suspended mid-interaction.
 */
object PerfTrace {
    private const val TAG = "perf"

    private val pending = HashMap<String, Pair<Long, Long>>()

    /** Stable interval key for a thread, shared by the begin and end sites. */
    fun intervalKey(key: ThreadKey): String = "${key.serverId}/${key.threadId}"

    /**
     * Start an interval that another call site will end.
     *
     * Re-beginning the same key drops the older start rather than ending it, so
     * a double tap cannot produce a bogus multi-second duration.
     */
    fun beginInterval(name: String, key: String) {
        if (!BuildConfig.DEBUG) return
        pending["$name#$key"] = SystemClock.uptimeMillis() to 0L
    }

    /**
     * End an interval opened by [beginInterval] with the same name and key.
     *
     * A missing start is logged and ignored: the end site must never fabricate a
     * duration for an interaction that began before this process existed.
     */
    fun endInterval(name: String, key: String) {
        if (!BuildConfig.DEBUG) return
        val start = pending.remove("$name#$key")?.first ?: run {
            Log.d(TAG, "$name end without begin key=$key")
            return
        }
        val elapsedMs = SystemClock.uptimeMillis() - start
        Log.d(TAG, "$name latency key=$key ${elapsedMs}ms")
    }
}
