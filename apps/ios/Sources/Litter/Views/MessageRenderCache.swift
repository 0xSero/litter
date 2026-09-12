import Foundation

@MainActor
final class MessageRenderCache {
    struct AssistantSegment: Identifiable {
        enum Kind {
            case markdown(String, Int)
            case codeBlock(language: String?, code: String, Int)
            case image(data: Data, cacheKey: String)
            case localImage(path: String, cacheKey: String)
        }

        let id: String
        let kind: Kind
    }

    struct RevisionKey: Hashable {
        let messageId: String
        let revisionToken: Int
        let serverId: String
        let agentDirectoryVersion: UInt64
    }

    static let shared = MessageRenderCache()

    private let maxEntries = 1024
    private let trimTarget = 768

    private var assistantCache: [RevisionKey: [AssistantSegment]] = [:]
    private var systemCache: [RevisionKey: ToolCallParseResult] = [:]
    // Monotonic access counters instead of an ordered array. The array form did
    // an O(n) `firstIndex(of:)` with String-comparing keys plus an O(n)
    // `remove(at:)` memmove on every cache *hit*, and it grew with the session —
    // the classic "slower the longer you use it" shape.
    private var assistantAccessStamps: [RevisionKey: UInt64] = [:]
    private var systemAccessStamps: [RevisionKey: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    var assistantEntryCount: Int { assistantCache.count }
    var systemEntryCount: Int { systemCache.count }

    func assistantSegments(
        for message: ChatMessage,
        key: RevisionKey
    ) -> [AssistantSegment] {
        assistantSegments(
            text: message.text,
            messageId: message.id.uuidString,
            key: key
        )
    }

    func assistantSegments(
        text: String,
        messageId: String,
        key: RevisionKey
    ) -> [AssistantSegment] {
        if let cached = assistantCache[key] {
            touch(&assistantAccessStamps, key: key)
            return cached
        }

        let parsed = extractSegments(from: text, messageId: messageId, key: key)
        assistantCache[key] = parsed
        touch(&assistantAccessStamps, key: key)
        trimIfNeeded(&assistantCache, accessStamps: &assistantAccessStamps)
        return parsed
    }

    func systemParseResult(
        for message: ChatMessage,
        key: RevisionKey,
        resolveTargetLabel: ((String) -> String?)?
    ) -> ToolCallParseResult {
        if let cached = systemCache[key] {
            touch(&systemAccessStamps, key: key)
            return cached
        }

        let cards = MessageContentBridge.parseToolCalls(text: message.text)
        let parsed: ToolCallParseResult = cards.first.map { .recognized($0) } ?? .unrecognized
        systemCache[key] = parsed
        touch(&systemAccessStamps, key: key)
        trimIfNeeded(&systemCache, accessStamps: &systemAccessStamps)
        return parsed
    }

    func reset() {
        assistantCache.removeAll(keepingCapacity: false)
        systemCache.removeAll(keepingCapacity: false)
        assistantAccessStamps.removeAll(keepingCapacity: false)
        systemAccessStamps.removeAll(keepingCapacity: false)
        accessCounter = 0
    }

    static func makeRevisionKey(
        for message: ChatMessage,
        serverId: String?,
        agentDirectoryVersion: UInt64,
        isStreaming: Bool
    ) -> RevisionKey {
        RevisionKey(
            messageId: message.id.uuidString,
            revisionToken: stableRevisionToken(for: message, isStreaming: isStreaming),
            serverId: serverId ?? "<nil>",
            agentDirectoryVersion: agentDirectoryVersion
        )
    }

    static func makeRevisionKey(
        for item: ConversationItem,
        serverId: String?,
        agentDirectoryVersion: UInt64,
        isStreaming: Bool
    ) -> RevisionKey {
        RevisionKey(
            messageId: item.id,
            revisionToken: stableRevisionToken(for: item, isStreaming: isStreaming),
            serverId: serverId ?? "<nil>",
            agentDirectoryVersion: agentDirectoryVersion
        )
    }

    static func stableRevisionToken(for message: ChatMessage, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(message.renderDigest)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    static func stableRevisionToken(for item: ConversationItem, isStreaming: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(item.renderDigest)
        hasher.combine(isStreaming)
        return hasher.finalize()
    }

    /// O(1) on a hit: one dictionary write, no array scan and no memmove.
    private func touch<Key: Hashable>(_ accessStamps: inout [Key: UInt64], key: Key) {
        accessCounter &+= 1
        accessStamps[key] = accessCounter
    }

    /// O(n log n), but only when the cache actually overflows `maxEntries`.
    private func trimIfNeeded<Key: Hashable, Value>(
        _ cache: inout [Key: Value],
        accessStamps: inout [Key: UInt64]
    ) {
        guard cache.count > maxEntries else { return }
        let removeCount = cache.count - trimTarget
        guard removeCount > 0 else { return }
        let oldest = accessStamps.sorted { $0.value < $1.value }.prefix(removeCount)
        for (key, _) in oldest {
            cache.removeValue(forKey: key)
            accessStamps.removeValue(forKey: key)
        }
        // Drop stamps for entries that were evicted or reset elsewhere.
        if accessStamps.count > cache.count {
            accessStamps = accessStamps.filter { cache[$0.key] != nil }
        }
    }

    private func extractSegments(
        from text: String,
        messageId: String,
        key: RevisionKey
    ) -> [AssistantSegment] {
        assistantSegments(
            from: MessageContentBridge.assistantRenderBlocks(text),
            messageId: messageId,
            key: key
        )
    }

    private func assistantSegments(
        from parsedSegments: [MessageContentBridge.AssistantRenderBlock],
        messageId: String,
        key: RevisionKey
    ) -> [AssistantSegment] {
        guard !parsedSegments.isEmpty else {
            return [AssistantSegment(
                id: "text-0-\(messageId.count)",
                kind: .markdown("", key.revisionToken)
            )]
        }

        var segments: [AssistantSegment] = []
        for (index, segment) in parsedSegments.enumerated() {
            switch segment {
            case .markdown(let text):
                guard !text.isEmpty else { continue }
                let fragmentId = "assistant-segment-\(index)-text-\(text.count)"
                segments.append(
                    AssistantSegment(
                        id: "text-\(index)-\(text.count)",
                        kind: .markdown(
                            text,
                            stableFragmentIdentity(key: key, fragmentId: fragmentId)
                        )
                    )
                )
            case .codeBlock(let language, let code):
                let fragmentId = "assistant-segment-\(index)-code-\(language ?? "")-\(code.count)"
                segments.append(
                    AssistantSegment(
                        id: "code-\(index)-\(code.count)",
                        kind: .codeBlock(
                            language: language,
                            code: code,
                            stableFragmentIdentity(key: key, fragmentId: fragmentId)
                        )
                    )
                )
            case .inlineImage(let data):
                let contentHash = data.hashValue
                let cacheKey = "assistant-\(messageId)-segment-\(index)-\(data.count)-\(contentHash)"
                segments.append(
                    AssistantSegment(
                        id: "image-\(index)-\(data.count)-\(contentHash)",
                        kind: .image(data: data, cacheKey: cacheKey)
                    )
                )
            case .localImage(let path):
                let contentHash = path.hashValue
                let cacheKey = "assistant-\(messageId)-path-\(index)-\(contentHash)"
                segments.append(
                    AssistantSegment(
                        id: cacheKey,
                        kind: .localImage(path: path, cacheKey: cacheKey)
                    )
                )
            }
        }

        return segments.isEmpty
            ? [AssistantSegment(
                id: "text-0-\(messageId.count)",
                kind: .markdown("", key.revisionToken)
            )]
            : segments
    }

    private func stableFragmentIdentity(key: RevisionKey, fragmentId: String) -> Int {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(fragmentId)
        return hasher.finalize()
    }
}
