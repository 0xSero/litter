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

        init(
            itemId: String,
            fullText: String,
            prefixText: String,
            prefixSegments: [MessageRenderCache.AssistantSegment],
            suffixSegments: [MessageRenderCache.AssistantSegment]
        ) {
            self.itemId = itemId
            self.fullText = fullText
            self.prefixText = prefixText
            self.prefixSegments = prefixSegments
            self.suffixSegments = suffixSegments
            self.signature = TextSignature(fullText)
            self.combinedSegments = prefixSegments + suffixSegments
        }

        var suffixText: String {
            String(fullText.dropFirst(prefixText.count))
        }
    }

    /// UTF-8 length plus a hash of at most 64 leading and 64 trailing bytes.
    /// `String.utf8.count` is O(1) for native strings and the sampling is
    /// bounded, so building one is O(1) regardless of message length.
    private struct TextSignature: Equatable {
        let utf8Count: Int
        let sampleHash: Int

        init(_ text: String) {
            let utf8 = text.utf8
            let count = utf8.count
            var hasher = Hasher()
            hasher.combine(count)
            var taken = 0
            for byte in utf8 {
                hasher.combine(byte)
                taken += 1
                if taken == 64 { break }
            }
            taken = 0
            for byte in utf8.reversed() {
                hasher.combine(byte)
                taken += 1
                if taken == 64 { break }
            }
            self.utf8Count = count
            self.sampleHash = hasher.finalize()
        }
    }

    private let maxEntries = 128
    private let trimTarget = 96
    private let targetTailCharacters = 4096
    private let maxTailCharacters = 8192
    private let minimumReusablePrefixCharacters = 1024

    private var entries: [String: Entry] = [:]
    private var accessTimestamps: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    func segments(itemId: String, text: String) -> [MessageRenderCache.AssistantSegment] {
        if let cached = entries[itemId], cached.signature == TextSignature(text) {
            touch(itemId)
            return cached.combinedSegments
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

    func reset() {
        entries.removeAll(keepingCapacity: false)
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

        let suffixSegments = parseSegments(
            text: nextSuffixText,
            itemId: itemId,
            namespace: "tail-\(existing.prefixText.count)"
        )

        return Entry(
            itemId: itemId,
            fullText: text,
            prefixText: existing.prefixText,
            prefixSegments: existing.prefixSegments,
            suffixSegments: suffixSegments
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
        let suffixSegments = parseSegments(
            text: suffixText,
            itemId: itemId,
            namespace: "tail-\(anchor)"
        )

        return Entry(
            itemId: itemId,
            fullText: text,
            prefixText: prefixText,
            prefixSegments: prefixSegments,
            suffixSegments: suffixSegments
        )
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
            accessTimestamps.removeValue(forKey: key)
        }
    }
}
