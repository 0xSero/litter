package com.litter.android.ui

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.min

data class RecentDirectoryEntry(
    val serverId: String,
    val path: String,
    val lastUsedAtEpochMillis: Long,
    val useCount: Int,
)

class RecentDirectoryStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val preferences by lazy {
        appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    }
    private val lock = Any()

    fun listForServer(
        serverId: String,
        limit: Int = DEFAULT_LIMIT,
    ): List<RecentDirectoryEntry> {
        val normalizedServerId = normalizeServerId(serverId) ?: return emptyList()
        val cappedLimit = min(limit, MAX_ENTRIES_PER_SERVER)
        synchronized(lock) {
            return loadAllInternal()
                .asSequence()
                .filter { it.serverId == normalizedServerId }
                .sortedByDescending { it.lastUsedAtEpochMillis }
                .take(cappedLimit)
                .toList()
        }
    }

    fun record(
        serverId: String,
        path: String,
        limit: Int = DEFAULT_LIMIT,
    ): List<RecentDirectoryEntry> {
        val normalizedServerId = normalizeServerId(serverId) ?: return emptyList()
        val normalizedPath = normalizePath(path) ?: return listForServer(normalizedServerId, limit)
        synchronized(lock) {
            val all = loadAllInternal().toMutableList()
            val existingIndex = all.indexOfFirst { it.serverId == normalizedServerId && it.path == normalizedPath }
            val now = System.currentTimeMillis()
            if (existingIndex >= 0) {
                val existing = all[existingIndex]
                all[existingIndex] =
                    RecentDirectoryEntry(
                        serverId = normalizedServerId,
                        path = normalizedPath,
                        lastUsedAtEpochMillis = now,
                        useCount = existing.useCount + 1,
                    )
            } else {
                all +=
                    RecentDirectoryEntry(
                        serverId = normalizedServerId,
                        path = normalizedPath,
                        lastUsedAtEpochMillis = now,
                        useCount = 1,
                    )
            }
            saveAllInternal(trimEntriesInternal(all))
            return listForServer(normalizedServerId, limit)
        }
    }

    fun remove(
        serverId: String,
        path: String,
        limit: Int = DEFAULT_LIMIT,
    ): List<RecentDirectoryEntry> {
        val normalizedServerId = normalizeServerId(serverId) ?: return emptyList()
        val normalizedPath = normalizePath(path) ?: return listForServer(normalizedServerId, limit)
        synchronized(lock) {
            val remaining =
                loadAllInternal()
                    .filterNot { it.serverId == normalizedServerId && it.path == normalizedPath }
            saveAllInternal(remaining)
            return listForServer(normalizedServerId, limit)
        }
    }

    fun clear(
        serverId: String,
        limit: Int = DEFAULT_LIMIT,
    ): List<RecentDirectoryEntry> {
        val normalizedServerId = normalizeServerId(serverId) ?: return emptyList()
        synchronized(lock) {
            val remaining = loadAllInternal().filterNot { it.serverId == normalizedServerId }
            saveAllInternal(remaining)
            return listForServer(normalizedServerId, limit)
        }
    }

    private fun trimEntriesInternal(entries: List<RecentDirectoryEntry>): List<RecentDirectoryEntry> {
        val byServerId = linkedMapOf<String, MutableList<RecentDirectoryEntry>>()
        entries.forEach { entry ->
            byServerId.getOrPut(entry.serverId) { mutableListOf() }.add(entry)
        }
        return byServerId.values
            .flatMap { scoped ->
                scoped
                    .sortedByDescending { it.lastUsedAtEpochMillis }
                    .take(MAX_ENTRIES_PER_SERVER)
            }
    }

    private fun loadAllInternal(): List<RecentDirectoryEntry> {
        val raw = preferences.getString(STORAGE_KEY, null) ?: return emptyList()
        return runCatching {
            val json = JSONArray(raw)
            buildList {
                for (index in 0 until json.length()) {
                    val item = json.optJSONObject(index) ?: continue
                    val serverId = item.optString(KEY_SERVER_ID).trim()
                    val path = item.optString(KEY_PATH).trim()
                    if (serverId.isEmpty() || path.isEmpty()) {
                        continue
                    }
                    add(
                        RecentDirectoryEntry(
                            serverId = serverId,
                            path = path,
                            lastUsedAtEpochMillis = item.optLong(KEY_LAST_USED_AT),
                            useCount = item.optInt(KEY_USE_COUNT, 1).coerceAtLeast(1),
                        ),
                    )
                }
            }
        }.getOrDefault(emptyList())
    }

    private fun saveAllInternal(entries: List<RecentDirectoryEntry>) {
        val payload = JSONArray()
        entries.forEach { entry ->
            payload.put(
                JSONObject()
                    .put(KEY_SERVER_ID, entry.serverId)
                    .put(KEY_PATH, entry.path)
                    .put(KEY_LAST_USED_AT, entry.lastUsedAtEpochMillis)
                    .put(KEY_USE_COUNT, entry.useCount),
            )
        }
        preferences.edit().putString(STORAGE_KEY, payload.toString()).apply()
    }

    private fun normalizeServerId(serverId: String): String? =
        serverId
            .trim()
            .takeIf { it.isNotEmpty() }

    private fun normalizePath(path: String): String? {
        var normalized = path.trim()
        if (normalized.isEmpty()) {
            return null
        }
        while (normalized.length > 1 && normalized.endsWith('/')) {
            normalized = normalized.dropLast(1)
        }
        return normalized
    }

    companion object {
        private const val PREFERENCES_NAME = "litter_recent_directories"
        private const val STORAGE_KEY = "entries"
        private const val KEY_SERVER_ID = "server_id"
        private const val KEY_PATH = "path"
        private const val KEY_LAST_USED_AT = "last_used_at"
        private const val KEY_USE_COUNT = "use_count"
        private const val MAX_ENTRIES_PER_SERVER = 20
        private const val DEFAULT_LIMIT = 8
    }
}
