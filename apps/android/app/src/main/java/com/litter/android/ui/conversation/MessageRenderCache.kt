package com.litter.android.ui.conversation

import android.util.LruCache
import uniffi.codex_mobile_client.AppMessageRenderBlock
import uniffi.codex_mobile_client.MessageParser

/**
 * LRU cache for expensive message parsing results.
 * Keyed by (itemId, serverId, agentDirectoryVersion) to invalidate on changes.
 * Calls Rust [MessageParser] and caches the typed result.
 */
object MessageRenderCache {

    data class CacheKey(
        val itemId: String,
        val revisionToken: Int,
        val serverId: String,
        val agentDirectoryVersion: ULong,
    )

    private val renderBlockCache = LruCache<CacheKey, List<AppMessageRenderBlock>>(1024)

    fun getRenderBlocks(
        key: CacheKey,
        parser: MessageParser,
        text: String,
    ): List<AppMessageRenderBlock> {
        renderBlockCache.get(key)?.let { return it }
        val blocks = parser.extractRenderBlocksTyped(text)
        renderBlockCache.put(key, blocks)
        return blocks
    }

    fun clear() {
        renderBlockCache.evictAll()
    }
}
