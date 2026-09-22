package com.litter.android.ui.conversation

import android.util.LruCache
import uniffi.codex_mobile_client.AppMessageRenderBlock
import uniffi.codex_mobile_client.MessageParser

/**
 * Tracks streaming text state per conversation item. Maintains a "frontier"
 * position so that stable (already-revealed) text can be cached and only the
 * newly-appended tail needs re-parsing and animation.
 *
 * The coordinator splits text at a markdown-safe boundary (blank line outside
 * of a code fence) so that the stable prefix is valid markdown.
 */
object StreamingTextCoordinator {

    data class StreamingTextState(
        /** Render blocks for the stable prefix — these don't change until the frontier advances. */
        val stableBlocks: List<AppMessageRenderBlock>,
        /** Render blocks for the frontier (new tokens). Rendered with fade-in animation. */
        val frontierBlocks: List<AppMessageRenderBlock>,
        /** The full text this state was computed from. */
        val fullText: String,
    )

    private data class CachedEntry(
        val fullText: String,
        val stablePrefix: String,
        val stableBlocks: List<AppMessageRenderBlock>,
        val frontierBlocks: List<AppMessageRenderBlock>,
        /** Whether the frontier's final block can absorb appended plain text. */
        val frontierCanAbsorbAppend: Boolean,
        /** Whether [fullText] contains a bare-URL scheme that linkify rewrites. */
        val containsUrlScheme: Boolean,
    )

    /** How many characters of tail text we target for the frontier. */
    private const val TARGET_TAIL_CHARS = 512

    /** If the frontier grows past this, re-anchor the stable prefix forward. */
    private const val MAX_TAIL_CHARS = 2048

    /** Minimum stable prefix length before we bother caching it. */
    private const val MIN_REUSABLE_PREFIX = 256

    /** Bytes compared at the splice point to confirm the caller's text is an append. */
    private const val SPLICE_CHECK_CHARS = 64

    /** Bytes that can move a markdown block boundary when appended to a line in progress. */
    private val APPEND_BOUNDARY_CHARS = "\n\r|`~$\\:/".toSet()

    /** Bytes a line can consist of and still be a prefix of a thematic break, an ordered-list
     *  marker, or a fence opener. Such a line can still change kind, so it is not extended. */
    private val MARKER_ONLY_CHARS = "0123456789.-)_*+`~ \t\r".toSet()

    private val cache = LruCache<String, CachedEntry>(128)

    fun update(
        itemId: String,
        text: String,
        parser: MessageParser,
    ): StreamingTextState {
        val existing = cache.get(itemId)

        // Fast path: text unchanged
        if (existing != null && existing.fullText == text) {
            return StreamingTextState(
                stableBlocks = existing.stableBlocks,
                frontierBlocks = existing.frontierBlocks,
                fullText = text,
            )
        }

        // Can we reuse the existing stable prefix, or extend the frontier in place?
        if (existing != null) {
            val reusablePrefix = existing.stablePrefix.isNotEmpty() &&
                text.startsWith(existing.stablePrefix)
            val tailStart = if (reusablePrefix) existing.stablePrefix.length else 0
            if (text.length - tailStart <= MAX_TAIL_CHARS) {
                // Streaming appends are the hot path: extending the frontier's
                // final block keeps the tick O(appended) instead of re-parsing
                // the whole tail through Rust.
                val appended = appendedPlainText(existing, text)
                if (appended != null) {
                    val extended = extendFrontier(existing, text, appended)
                    if (extended != null) {
                        cache.put(itemId, extended)
                        return StreamingTextState(
                            stableBlocks = extended.stableBlocks,
                            frontierBlocks = extended.frontierBlocks,
                            fullText = text,
                        )
                    }
                }

                if (reusablePrefix) {
                    val frontierBlocks = parser.extractRenderBlocksTyped(
                        text.substring(tailStart)
                    )
                    val entry = CachedEntry(
                        fullText = text,
                        stablePrefix = existing.stablePrefix,
                        stableBlocks = existing.stableBlocks,
                        frontierBlocks = frontierBlocks,
                        frontierCanAbsorbAppend = frontierCanAbsorbAppend(frontierBlocks),
                        containsUrlScheme = containsUrlScheme(text),
                    )
                    cache.put(itemId, entry)
                    return StreamingTextState(
                        stableBlocks = entry.stableBlocks,
                        frontierBlocks = entry.frontierBlocks,
                        fullText = text,
                    )
                }
            }
        }

        // Need to (re)compute a stable anchor
        val anchor = stableAnchorOffset(text)
        val prefixText = text.substring(0, anchor)
        val tailText = text.substring(anchor)

        val stableBlocks = if (prefixText.isEmpty()) {
            emptyList()
        } else {
            parser.extractRenderBlocksTyped(prefixText)
        }
        val frontierBlocks = parser.extractRenderBlocksTyped(tailText)

        val entry = CachedEntry(
            fullText = text,
            stablePrefix = prefixText,
            stableBlocks = stableBlocks,
            frontierBlocks = frontierBlocks,
            frontierCanAbsorbAppend = frontierCanAbsorbAppend(frontierBlocks),
            containsUrlScheme = containsUrlScheme(text),
        )
        cache.put(itemId, entry)

        return StreamingTextState(
            stableBlocks = stableBlocks,
            frontierBlocks = frontierBlocks,
            fullText = text,
        )
    }

    /**
     * The appended run when [text] is a pure append of plain text to [existing], or null when the
     * caller must re-parse.
     *
     * Appending never moves a line start, so heading, blockquote, list-item, and fence markers are
     * decided by the cached text alone. A newline starts a new line, a pipe can turn a paragraph into
     * a table, a backtick or tilde can open a fence, a dollar or backslash can close a math span, and
     * a colon or slash can complete a bare-URL autolink. Any of those means re-parse.
     */
    private fun appendedPlainText(existing: CachedEntry, text: String): String? {
        if (!existing.frontierCanAbsorbAppend) return null
        if (existing.containsUrlScheme) return null
        val cachedLength = existing.fullText.length
        if (text.length <= cachedLength) return null

        // The caller's text is a pure append only if it still ends with the cached text. Compare a
        // bounded window at the splice point so the check stays O(1) instead of O(message length).
        val anchor = (cachedLength - SPLICE_CHECK_CHARS).coerceAtLeast(0)
        val checked = cachedLength - anchor
        if (!text.regionMatches(anchor, existing.fullText, anchor, checked)) return null

        val appended = text.substring(cachedLength)
        for (char in appended) {
            if (char.code >= 0x80 || char in APPEND_BOUNDARY_CHARS) return null
        }
        return appended
    }

    /** Extends the frontier's final markdown block by [appended], or null when it is not markdown. */
    private fun extendFrontier(
        existing: CachedEntry,
        text: String,
        appended: String,
    ): CachedEntry? {
        val last = existing.frontierBlocks.lastOrNull() ?: return null
        if (last !is AppMessageRenderBlock.Markdown) return null

        val markdown = last.markdown + appended
        val frontierBlocks = existing.frontierBlocks.dropLast(1) +
            AppMessageRenderBlock.Markdown(markdown)
        return CachedEntry(
            fullText = text,
            stablePrefix = existing.stablePrefix,
            stableBlocks = existing.stableBlocks,
            frontierBlocks = frontierBlocks,
            frontierCanAbsorbAppend = lineCanAbsorbAppend(markdown),
            containsUrlScheme = false,
        )
    }

    /** Whether the final block is markdown whose last line can absorb appended plain text. */
    private fun frontierCanAbsorbAppend(blocks: List<AppMessageRenderBlock>): Boolean {
        val last = blocks.lastOrNull() as? AppMessageRenderBlock.Markdown ?: return false
        return lineCanAbsorbAppend(last.markdown)
    }

    /** Whether [markdown]'s final line can absorb appended text without changing its line kind. */
    private fun lineCanAbsorbAppend(markdown: String): Boolean {
        var scanned = 0
        for (index in markdown.indices.reversed()) {
            val char = markdown[index]
            if (char == '\n') return false
            if (char !in MARKER_ONLY_CHARS) return true
            scanned += 1
            if (scanned >= SPLICE_CHECK_CHARS) return false
        }
        return false
    }

    private fun containsUrlScheme(text: String): Boolean =
        text.contains("http://") || text.contains("https://")

    /** Evict a specific item when streaming ends and the final result gets cached normally. */
    fun evict(itemId: String) {
        cache.remove(itemId)
    }

    fun clear() {
        cache.evictAll()
    }

    /**
     * Find a markdown-safe split point: the last blank line outside of a code fence,
     * leaving approximately [TARGET_TAIL_CHARS] for the tail.
     */
    private fun stableAnchorOffset(text: String): Int {
        if (text.length <= TARGET_TAIL_CHARS + MIN_REUSABLE_PREFIX) return 0

        val maxPrefixLen = (text.length - TARGET_TAIL_CHARS).coerceAtLeast(0)
        if (maxPrefixLen < MIN_REUSABLE_PREFIX) return 0

        var consumed = 0
        var insideFence = false
        var lastBlankBoundary = 0
        var lastLineBoundary = 0
        val lines = text.split('\n')

        for ((index, line) in lines.withIndex()) {
            val trimmed = line.trim()
            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                insideFence = !insideFence
            }

            consumed += line.length
            if (index < lines.size - 1) consumed += 1 // newline char

            if (consumed > maxPrefixLen || insideFence) continue

            lastLineBoundary = consumed
            if (trimmed.isEmpty()) {
                lastBlankBoundary = consumed
            }
        }

        if (lastBlankBoundary >= MIN_REUSABLE_PREFIX) return lastBlankBoundary
        if (lastLineBoundary >= MIN_REUSABLE_PREFIX) return lastLineBoundary
        return 0
    }
}
