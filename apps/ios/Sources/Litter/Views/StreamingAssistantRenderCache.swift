import Foundation

@MainActor
final class StreamingAssistantRenderCache {
    static let shared = StreamingAssistantRenderCache()

    private struct Entry {
        let itemId: String
        let fullText: String
        let prefixText: String
        let prefixSegments: [MessageRenderCache.AssistantSegment]
        let suffixSegments: [MessageRenderCache.AssistantSegment]
        /// Cheap identity for `fullText`: UTF-8 length plus a bounded sample of
        /// its head and tail bytes. Comparing the whole string on every cache
        /// hit was O(message length) at streaming tick rate.
        let signature: TextSignature
        /// Concatenated once at construction. The old computed property
        /// allocated a fresh array on every hit.
        let combinedSegments: [MessageRenderCache.AssistantSegment]
        /// Namespace of the suffix segments, so an append can mint a fresh
        /// identity for the final segment without re-running the parse.
        let suffixNamespace: String
        /// Block index of the final segment.
        let lastIndex: Int
        /// Markdown of the final segment, plus the whitespace
        /// `splitMarkdownBlocks` trimmed off its end. Together they are the raw
        /// tail of `fullText`, which is what an append folds into.
        let lastMarkdown: String
        let lastTrailingWhitespace: String
        let lastLength: Int
        let lastHash: UInt64
        /// Whether the final segment is a markdown chunk whose last line can
        /// absorb appended text without moving a block boundary.
        let lastCanAbsorbAppend: Bool
        /// Whether `fullText` contains `http://` or `https://`. Autolinking is
        /// the one transformation that appending raw text cannot reproduce.
        let containsURLScheme: Bool

        init(
            itemId: String,
            fullText: String,
            prefixText: String,
            prefixSegments: [MessageRenderCache.AssistantSegment],
            suffixSegments: [MessageRenderCache.AssistantSegment],
            suffixNamespace: String,
            containsURLScheme: Bool? = nil,
            lastLength: Int? = nil,
            lastHash: UInt64? = nil
        ) {
            self.itemId = itemId
            self.fullText = fullText
            self.prefixText = prefixText
            self.prefixSegments = prefixSegments
            self.suffixSegments = suffixSegments
            self.suffixNamespace = suffixNamespace
            self.signature = TextSignature(fullText)
            let combined = prefixSegments + suffixSegments
            self.combinedSegments = combined
            self.lastIndex = max(0, combined.count - 1)
            self.containsURLScheme = containsURLScheme
                ?? (fullText.contains("http://") || fullText.contains("https://"))

            let trailing = StreamingAssistantRenderCache.trailingChunkWhitespace(fullText)
            if let last = combined.last,
               case .markdown(let markdown, _) = last.kind,
               !markdown.isEmpty,
               let trailing
            {
                self.lastMarkdown = markdown
                self.lastTrailingWhitespace = trailing
                self.lastLength = lastLength ?? markdown.count
                self.lastHash = lastHash ?? StreamingAssistantRenderCache.fnv1a(markdown.utf8)
                self.lastCanAbsorbAppend = StreamingAssistantRenderCache.lineCanAbsorbAppend(markdown)
            } else {
                self.lastMarkdown = ""
                self.lastTrailingWhitespace = ""
                self.lastLength = 0
                self.lastHash = StreamingAssistantRenderCache.fnv1a("".utf8)
                self.lastCanAbsorbAppend = false
            }
        }
    }

    /// UTF-8 length plus a hash of at most 64 leading and 64 trailing bytes.
    /// `String.utf8.count` is O(1) for native strings and the sampling is
    /// bounded, so building one is O(1) regardless of message length.
    private struct TextSignature: Equatable {
        let utf8Count: Int
        /// Hash of the first `min(64, utf8Count)` bytes alone. A pure append
        /// leaves it unchanged, which is what lets `extendEntry` prove that the
        /// cached segments' prefix is still valid.
        let headHash: Int
        let sampleHash: Int

        init(_ text: String) {
            let utf8 = text.utf8
            let count = utf8.count
            var headHasher = Hasher()
            var sampleHasher = Hasher()
            sampleHasher.combine(count)
            var taken = 0
            for byte in utf8 {
                if taken < 64 {
                    headHasher.combine(byte)
                }
                sampleHasher.combine(byte)
                taken += 1
                if taken == 64 { break }
            }
            taken = 0
            for byte in utf8.reversed() {
                sampleHasher.combine(byte)
                taken += 1
                if taken == 64 { break }
            }
            self.utf8Count = count
            self.headHash = headHasher.finalize()
            self.sampleHash = sampleHasher.finalize()
        }
    }

    private let maxEntries = 128
    private let trimTarget = 96
    private let targetTailCharacters = 4096
    private let maxTailCharacters = 8192
    private let minimumReusablePrefixCharacters = 1024

    private var entries: [String: Entry] = [:]
    /// Cached math-detection results keyed by itemId. Stores the text the
    /// check ran against so a stale result is never returned after the text
    /// changes. Shares the LRU eviction with `entries`.
    private var mathResults: [String: (text: String, hasMath: Bool)] = [:]
    private var accessTimestamps: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    func segments(itemId: String, text: String) -> [MessageRenderCache.AssistantSegment] {
        let signature = TextSignature(text)
        if let cached = entries[itemId] {
            if cached.signature == signature {
                touch(itemId)
                return cached.combinedSegments
            }
            // Streaming appends are the hot path: every token used to re-parse
            // the whole message. Fold the appended run into the cached final
            // chunk instead, which is O(appended).
            if let extended = extendEntry(cached: cached, text: text, signature: signature) {
                entries[itemId] = extended
                touch(itemId)
                trimIfNeeded()
                return extended.combinedSegments
            }
        }

        let nextEntry = makeEntry(
            itemId: itemId,
            text: text,
            existing: entries[itemId]
        )
        entries[itemId] = nextEntry
        touch(itemId)
        trimIfNeeded()
        return nextEntry.combinedSegments
    }

    /// Returns whether the text contains LaTeX math, using a cached result
    /// when the text hasn't changed since the last call. This avoids a
    /// redundant `extractSegmentsTyped` Rust FFI parse on body re-evaluations
    /// that don't change the text (e.g. display-mode toggles).
    func containsMath(itemId: String, text: String) -> Bool {
        if let cached = mathResults[itemId], cached.text == text {
            touch(itemId)
            return cached.hasMath
        }
        let result = MessageContentBridge.containsMath(text)
        mathResults[itemId] = (text, result)
        touch(itemId)
        trimIfNeeded()
        return result
    }

    func reset() {
        entries.removeAll(keepingCapacity: false)
        mathResults.removeAll(keepingCapacity: false)
        accessTimestamps.removeAll(keepingCapacity: false)
        accessCounter = 0
    }

    private func makeEntry(itemId: String, text: String, existing: Entry?) -> Entry {
        // `hasPrefix(existing.fullText)` used to run here as well, doubling the
        // prefix comparison work per tick. It is redundant: reusing
        // `prefixSegments` is only sound if the new text still starts with
        // `prefixText`, and the suffix is reparsed from scratch either way.
        guard let existing,
              !existing.prefixText.isEmpty,
              text.hasPrefix(existing.prefixText)
        else {
            return rebuildEntry(itemId: itemId, text: text)
        }

        let nextSuffixText = String(text.dropFirst(existing.prefixText.count))
        if nextSuffixText.count > maxTailCharacters {
            return rebuildEntry(itemId: itemId, text: text)
        }

        let suffixNamespace = "tail-\(existing.prefixText.count)"
        let suffixSegments = parseSegments(
            text: nextSuffixText,
            itemId: itemId,
            namespace: suffixNamespace
        )

        return Entry(
            itemId: itemId,
            fullText: text,
            prefixText: existing.prefixText,
            prefixSegments: existing.prefixSegments,
            suffixSegments: suffixSegments,
            suffixNamespace: suffixNamespace
        )
    }

    private func rebuildEntry(itemId: String, text: String) -> Entry {
        let anchor = stableAnchorOffset(for: text)
        let prefixText = String(text.prefix(anchor))
        let suffixText = String(text.dropFirst(anchor))

        let prefixSegments = prefixText.isEmpty
            ? []
            : parseSegments(
                text: prefixText,
                itemId: itemId,
                namespace: "prefix-\(anchor)"
            )
        let suffixNamespace = "tail-\(anchor)"
        let suffixSegments = parseSegments(
            text: suffixText,
            itemId: itemId,
            namespace: suffixNamespace
        )

        return Entry(
            itemId: itemId,
            fullText: text,
            prefixText: prefixText,
            prefixSegments: prefixSegments,
            suffixSegments: suffixSegments,
            suffixNamespace: suffixNamespace
        )
    }

    /// Folds an appended run of plain text into the cached final chunk.
    ///
    /// A streaming delta is almost always a plain append to the paragraph being
    /// written, yet each tick used to re-run the whole parse: the Rust block
    /// builder, `splitMarkdownBlocks`, the tail copy, and several `String.count`
    /// grapheme walks, all O(message length). Extending the cached final chunk
    /// makes the tick O(appended).
    ///
    /// Returns nil — leaving the caller to re-parse — whenever the append could
    /// change how the text is split or transformed: when the text is not a pure
    /// append, when the final segment is not a markdown chunk, when the text
    /// already contains a URL that `linkify_bare_web_urls` may have rewritten,
    /// or when the appended bytes contain anything that can move a block
    /// boundary.
    private func extendEntry(
        cached: Entry,
        text: String,
        signature: TextSignature
    ) -> Entry? {
        guard cached.lastCanAbsorbAppend,
              !cached.containsURLScheme,
              signature.utf8Count > cached.signature.utf8Count,
              signature.headHash == cached.signature.headHash
        else { return nil }

        let appendedBytes = text.utf8.suffix(
            signature.utf8Count - cached.signature.utf8Count
        )
        for byte in appendedBytes where byte >= 0x80 || Self.appendBoundaryBytes.contains(byte) {
            return nil
        }

        // The sampled signature could in principle collide, so the splice point is
        // checked too. That is O(1) and confines a mismatch to one stale tick
        // instead of a wrongly spliced chunk.
        let anchorStart = cached.signature.utf8Count - min(64, cached.signature.utf8Count)
        guard text.utf8.dropFirst(anchorStart).prefix(cached.signature.utf8Count - anchorStart)
            .elementsEqual(cached.fullText.utf8.dropFirst(anchorStart))
        else { return nil }

        // `splitMarkdownBlocks` trims whitespace off the end of every chunk, so
        // the whitespace the cached chunk lost is folded back in before the
        // appended text is concatenated.
        let raw = cached.lastTrailingWhitespace.utf8.map { $0 } + appendedBytes
        var end = raw.count
        while end > 0, Self.isWhitespaceByte(raw[end - 1]) {
            end -= 1
        }
        let added = raw[0..<end]

        var suffixSegments = cached.suffixSegments
        guard !suffixSegments.isEmpty else { return nil }
        let hash = Self.fnv1a(added, seed: cached.lastHash)
        let contentHash = Int(bitPattern: UInt(hash))
        let length = cached.lastLength + added.count
        suffixSegments[suffixSegments.count - 1] = MessageRenderCache.AssistantSegment(
            id: "\(cached.itemId)-\(cached.suffixNamespace)-md-\(cached.lastIndex)-\(length)-\(contentHash)",
            kind: .markdown(
                cached.lastMarkdown + String(decoding: added, as: UTF8.self),
                stableIdentity(
                    itemId: cached.itemId,
                    namespace: cached.suffixNamespace,
                    kind: "md",
                    index: cached.lastIndex,
                    length: length,
                    contentHash: contentHash
                )
            )
        )

        return Entry(
            itemId: cached.itemId,
            fullText: text,
            prefixText: cached.prefixText,
            prefixSegments: cached.prefixSegments,
            suffixSegments: suffixSegments,
            suffixNamespace: cached.suffixNamespace,
            containsURLScheme: false,
            lastLength: length,
            lastHash: hash
        )
    }

    /// Bytes that can move a markdown block boundary when appended to a line
    /// that is already in progress: a newline starts a new line, a pipe can turn
    /// a paragraph into a table, a backtick or tilde can open a fence, a dollar
    /// or backslash can close a math span, and a colon or slash can complete a
    /// bare-URL autolink.
    private nonisolated static let appendBoundaryBytes: Set<UInt8> = Set("\n\r|`~$\\:/".utf8)

    /// Bytes a line can consist of and still be a prefix of a thematic break,
    /// an ordered-list marker, or a fence opener. A line made only of these can
    /// still change kind when text is appended, so it is not extended.
    private nonisolated static let markerOnlyBytes: Set<UInt8> = Set("0123456789.-)_*+`~ \t\r".utf8)

    private nonisolated static func isWhitespaceByte(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// Whether the final line of a chunk can absorb appended plain text without
    /// changing its markdown line kind.
    ///
    /// Appending never moves a line start, so heading, blockquote, list-item, and
    /// fence markers are decided by the cached line alone. A line that still
    /// consists only of marker bytes can however *become* a thematic break, an
    /// ordered-list marker, or a fence opener, which would make the block builder
    /// flush and split the block. Those are refused.
    private nonisolated static func lineCanAbsorbAppend(_ markdown: String) -> Bool {
        var scanned = 0
        for byte in markdown.utf8.reversed() {
            if byte == 0x0A { return false }
            if !markerOnlyBytes.contains(byte) { return true }
            scanned += 1
            if scanned >= 4096 { return false }
        }
        return false
    }

    /// Whitespace `splitMarkdownBlocks` trims off the end of the final chunk:
    /// the run of spaces, tabs, and carriage returns after the last
    /// non-whitespace byte of the final non-blank line. Blank lines at the end
    /// are dropped by the block builder, so their whitespace is not part of the
    /// chunk. Returns nil when the scan would have to look further back than
    /// `limit` bytes, which keeps the cost bounded.
    private nonisolated static func trailingChunkWhitespace(_ text: String, limit: Int = 4096) -> String? {
        var whitespace: [UInt8] = []
        var scanned = 0
        for byte in text.utf8.reversed() {
            scanned += 1
            if scanned > limit { return nil }
            switch byte {
            case 0x0A:
                whitespace.removeAll(keepingCapacity: true)
            case 0x20, 0x09, 0x0D:
                whitespace.append(byte)
            default:
                return String(decoding: whitespace.reversed(), as: UTF8.self)
            }
        }
        return String(decoding: whitespace.reversed(), as: UTF8.self)
    }

    /// FNV-1a over `bytes`, seeded with a previous result so a chunk's hash can
    /// be extended by the appended bytes alone. `Hasher` cannot be resumed, and
    /// re-hashing the whole chunk per tick is what the append path avoids.
    private nonisolated static func fnv1a(_ bytes: some Sequence<UInt8>, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func stableAnchorOffset(for text: String) -> Int {
        guard text.count > targetTailCharacters + minimumReusablePrefixCharacters else {
            return 0
        }

        let maxPrefixLength = max(0, text.count - targetTailCharacters)
        guard maxPrefixLength >= minimumReusablePrefixCharacters else { return 0 }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var consumed = 0
        var insideFence = false
        var lastBlankLineBoundary = 0
        var lastLineBoundary = 0

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            }

            consumed += line.count
            if index < lines.index(before: lines.endIndex) {
                consumed += 1
            }

            guard consumed <= maxPrefixLength, !insideFence else { continue }
            lastLineBoundary = consumed
            if trimmed.isEmpty {
                lastBlankLineBoundary = consumed
            }
        }

        if lastBlankLineBoundary >= minimumReusablePrefixCharacters {
            return lastBlankLineBoundary
        }
        if lastLineBoundary >= minimumReusablePrefixCharacters {
            return lastLineBoundary
        }
        return 0
    }

    private func parseSegments(
        text: String,
        itemId: String,
        namespace: String
    ) -> [MessageRenderCache.AssistantSegment] {
        let renderBlocks = MessageContentBridge.assistantRenderBlocks(text)
        guard !renderBlocks.isEmpty else {
            return [
                MessageRenderCache.AssistantSegment(
                    id: "\(itemId)-\(namespace)-empty",
                    kind: .markdown("", stableIdentity(itemId: itemId, namespace: namespace, kind: "empty", index: 0, length: 0))
                )
            ]
        }

        var segments: [MessageRenderCache.AssistantSegment] = []
        var blockIndex = 0
        for block in renderBlocks {
            switch block {
            case .markdown(let markdown):
                guard !markdown.isEmpty else { continue }
                let chunks = splitMarkdownBlocks(markdown)
                for chunk in chunks {
                    guard !chunk.isEmpty else { continue }
                    let contentHash = chunk.hashValue
                    let identity = stableIdentity(
                        itemId: itemId,
                        namespace: namespace,
                        kind: "md",
                        index: blockIndex,
                        length: chunk.count,
                        contentHash: contentHash
                    )
                    segments.append(
                        MessageRenderCache.AssistantSegment(
                            id: "\(itemId)-\(namespace)-md-\(blockIndex)-\(chunk.count)-\(contentHash)",
                            kind: .markdown(chunk, identity)
                        )
                    )
                    blockIndex += 1
                }
            case .codeBlock(let language, let code):
                let contentHash = code.hashValue
                let identity = stableIdentity(
                    itemId: itemId,
                    namespace: namespace,
                    kind: "code-\(language ?? "")",
                    index: blockIndex,
                    length: code.count,
                    contentHash: contentHash
                )
                segments.append(
                    MessageRenderCache.AssistantSegment(
                        id: "\(itemId)-\(namespace)-code-\(blockIndex)-\(code.count)-\(contentHash)",
                        kind: .codeBlock(language: language, code: code, identity)
                    )
                )
                blockIndex += 1
            case .inlineImage(let data):
                let contentHash = data.hashValue
                let cacheKey = "\(itemId)-\(namespace)-image-\(blockIndex)-\(data.count)-\(contentHash)"
                segments.append(
                    MessageRenderCache.AssistantSegment(
                        id: cacheKey,
                        kind: .image(data: data, cacheKey: cacheKey)
                    )
                )
                blockIndex += 1
            case .localImage(let path):
                let contentHash = path.hashValue
                let cacheKey = "\(itemId)-\(namespace)-path-\(blockIndex)-\(contentHash)"
                segments.append(
                    MessageRenderCache.AssistantSegment(
                        id: cacheKey,
                        kind: .localImage(path: path, cacheKey: cacheKey)
                    )
                )
                blockIndex += 1
            }
        }

        if segments.isEmpty {
            return [
                MessageRenderCache.AssistantSegment(
                    id: "\(itemId)-\(namespace)-empty",
                    kind: .markdown("", stableIdentity(itemId: itemId, namespace: namespace, kind: "empty", index: 0, length: 0))
                )
            ]
        }
        return segments
    }

    /// Splits a markdown string into individual top-level blocks.
    /// Each block is a paragraph, heading, list, table, blockquote, thematic break, etc.
    /// Respects code fences so fenced blocks aren't split mid-fence.
    private func splitMarkdownBlocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var insideFence = false
        var insideTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track code fences
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                current.append(line)
                continue
            }

            if insideFence {
                current.append(line)
                continue
            }

            // Track tables (consecutive lines starting with |)
            let isTableLine = trimmed.hasPrefix("|") || (insideTable && trimmed.contains("|") && trimmed.hasPrefix(":"))
            if isTableLine {
                if !insideTable && !current.isEmpty {
                    // Flush before starting table
                    let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !block.isEmpty { blocks.append(block) }
                    current = []
                }
                insideTable = true
                current.append(line)
                continue
            } else if insideTable {
                // End of table
                let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !block.isEmpty { blocks.append(block) }
                current = []
                insideTable = false
            }

            // Blank line = block boundary
            if trimmed.isEmpty {
                if !current.isEmpty {
                    let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !block.isEmpty { blocks.append(block) }
                    current = []
                }
                continue
            }

            current.append(line)
        }

        // Flush remaining
        if !current.isEmpty {
            let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { blocks.append(block) }
        }

        return blocks
    }

    private func stableIdentity(
        itemId: String,
        namespace: String,
        kind: String,
        index: Int,
        length: Int,
        contentHash: Int = 0
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(itemId)
        hasher.combine(namespace)
        hasher.combine(kind)
        hasher.combine(index)
        hasher.combine(length)
        hasher.combine(contentHash)
        return hasher.finalize()
    }

    private func touch(_ itemId: String) {
        accessCounter &+= 1
        accessTimestamps[itemId] = accessCounter
    }

    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        let sorted = accessTimestamps.sorted { $0.value < $1.value }
        let removeCount = entries.count - trimTarget
        for (key, _) in sorted.prefix(removeCount) {
            entries.removeValue(forKey: key)
            mathResults.removeValue(forKey: key)
            accessTimestamps.removeValue(forKey: key)
        }
    }
}
