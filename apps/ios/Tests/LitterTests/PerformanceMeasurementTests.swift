import XCTest
@testable import Litter

/// Performance measurement tests using XCTest `measure {}` blocks.
/// These establish baselines for the critical paths we optimized:
/// - TranscriptTurn.build (conversation rendering)
/// - TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering
/// - StreamingAssistantRenderCache (per-token streaming)
/// - ConversationScreenModel projection (snapshot → transcript)
/// - relativeDate formatter (home card rendering)
@MainActor
final class PerformanceMeasurementTests: XCTestCase {

    // MARK: - TranscriptTurn.build (conversation rendering)

    func testTranscriptTurnBuildPerformance_SmallConversation() {
        let items = generateConversation(turnCount: 10, itemsPerTurn: 3)
        measure {
            _ = TranscriptTurn.build(
                from: items,
                threadStatus: .idle,
                expandedRecentTurnCount: .max
            )
        }
    }

    func testTranscriptTurnBuildPerformance_LargeConversation() {
        let items = generateConversation(turnCount: 200, itemsPerTurn: 5)
        measure {
            _ = TranscriptTurn.build(
                from: items,
                threadStatus: .thinking,
                expandedRecentTurnCount: 1
            )
        }
    }

    // MARK: - Merge exploration turns (rendered turns path)

    func testMergeExplorationTurnsPerformance() {
        let items = generateConversation(turnCount: 100, itemsPerTurn: 4)
        let turns = TranscriptTurn.build(
            from: items,
            threadStatus: .idle,
            expandedRecentTurnCount: .max
        )
        measure {
            _ = TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(turns)
        }
    }

    // MARK: - StreamingAssistantRenderCache (per-token cost)

    func testStreamingRenderCachePerformance_1000Tokens() {
        StreamingAssistantRenderCache.shared.reset()
        let itemId = "perf-stream-1"
        let tokenChunk = "The quick brown fox jumps over the lazy dog. "
        measure {
            StreamingAssistantRenderCache.shared.reset()
            var accumulated = ""
            for i in 0..<1000 {
                accumulated += tokenChunk + "\(i) "
                _ = StreamingAssistantRenderCache.shared.segments(
                    itemId: itemId,
                    text: accumulated
                )
            }
        }
    }

    func testStreamingRenderCachePerformance_StablePrefixReuse() {
        StreamingAssistantRenderCache.shared.reset()
        let itemId = "perf-stream-2"
        let baseText = String(repeating: "Lorem ipsum dolor sit amet. ", count: 500)
        // First call seeds the cache
        _ = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: baseText)
        measure {
            // Simulate streaming: append a small tail each frame
            var text = baseText
            for i in 0..<500 {
                text += "token\(i) "
                _ = StreamingAssistantRenderCache.shared.segments(itemId: itemId, text: text)
            }
        }
    }

    // MARK: - ConversationScreenModel projection

    func testConversationScreenModelProjectionPerformance() {
        let model = ConversationScreenModel()
        let items = generateHydratedConversation(turnCount: 100, itemsPerTurn: 4)
        measure {
            _ = model._testProjectConversationItems(from: items)
        }
    }

    // MARK: - relativeDate formatter (home card path)

    func testRelativeDateFormatterPerformance() {
        let timestamps: [Int64] = (0..<100).map { i in
            Int64(Date().addingTimeInterval(-Double(i * 3600)).timeIntervalSince1970)
        }
        measure {
            for ts in timestamps {
                _ = relativeDate(ts)
            }
        }
    }

    // MARK: - TranscriptTurn.build with live streaming turn

    func testTranscriptTurnBuildPerformance_WithLiveStreamingTurn() {
        let baseTime = Date(timeIntervalSince1970: 100)
        var items: [ConversationItem] = []
        // 50 completed turns
        for turnIdx in 0..<50 {
            let turnId = "turn-\(turnIdx)"
            items.append(makeUserItem(text: "Question \(turnIdx)", turnId: turnId, turnIndex: turnIdx, timestamp: baseTime.addingTimeInterval(Double(turnIdx) * 10)))
            items.append(makeAssistantItem(text: String(repeating: "Answer ", count: 50), turnId: turnId, turnIndex: turnIdx, timestamp: baseTime.addingTimeInterval(Double(turnIdx) * 10 + 1)))
        }
        // One live streaming turn (no turnId)
        items.append(makeUserItem(text: "Latest question", turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(500)))
        items.append(makeAssistantItem(text: String(repeating: "Streaming ", count: 20), turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(501)))

        measure {
            _ = TranscriptTurn.build(
                from: items,
                threadStatus: .thinking,
                expandedRecentTurnCount: 1
            )
        }
    }

    // MARK: - Helpers

    private func generateConversation(turnCount: Int, itemsPerTurn: Int) -> [ConversationItem] {
        let baseTime = Date(timeIntervalSince1970: 100)
        var items: [ConversationItem] = []
        for turnIdx in 0..<turnCount {
            let turnId = "turn-\(turnIdx)"
            let turnTime = baseTime.addingTimeInterval(Double(turnIdx) * Double(itemsPerTurn) * 2)
            items.append(makeUserItem(
                text: "Question \(turnIdx)",
                turnId: turnId,
                turnIndex: turnIdx,
                timestamp: turnTime
            ))
            for itemIdx in 1..<itemsPerTurn {
                if itemIdx % 2 == 0 {
                    items.append(makeAssistantItem(
                        text: "Answer \(turnIdx).\(itemIdx) " + String(repeating: "x", count: 20),
                        turnId: turnId,
                        turnIndex: turnIdx,
                        timestamp: turnTime.addingTimeInterval(Double(itemIdx))
                    ))
                } else {
                    items.append(makeCommandItem(
                        command: "rg pattern\(itemIdx)",
                        turnId: turnId,
                        turnIndex: turnIdx,
                        timestamp: turnTime.addingTimeInterval(Double(itemIdx)),
                        durationMs: 120
                    ))
                }
            }
        }
        return items
    }

    private func generateHydratedConversation(turnCount: Int, itemsPerTurn: Int) -> [HydratedConversationItem] {
        let baseTime: Double = 100
        var items: [HydratedConversationItem] = []
        for turnIdx in 0..<turnCount {
            let turnId = "turn-\(turnIdx)"
            let turnTime = baseTime + Double(turnIdx) * Double(itemsPerTurn) * 2
            items.append(HydratedConversationItem(
                id: UUID().uuidString,
                content: .user(HydratedUserMessageData(text: "Question \(turnIdx)", imageDataUris: [])),
                sourceTurnId: turnId,
                sourceTurnIndex: UInt32(turnIdx),
                timestamp: turnTime,
                isFromUserTurnBoundary: true
            ))
            for itemIdx in 1..<itemsPerTurn {
                if itemIdx % 2 == 0 {
                    items.append(HydratedConversationItem(
                        id: UUID().uuidString,
                        content: .assistant(HydratedAssistantMessageData(
                            text: "Answer \(turnIdx).\(itemIdx) " + String(repeating: "x", count: 20),
                            agentNickname: nil,
                            agentRole: nil,
                            phase: nil
                        )),
                        sourceTurnId: turnId,
                        sourceTurnIndex: UInt32(turnIdx),
                        timestamp: turnTime + Double(itemIdx),
                        isFromUserTurnBoundary: false
                    ))
                } else {
                    items.append(HydratedConversationItem(
                        id: UUID().uuidString,
                        content: .commandExecution(HydratedCommandExecutionData(
                            command: "rg pattern\(itemIdx)",
                            cwd: "/tmp",
                            status: .completed,
                            output: nil,
                            exitCode: 0,
                            durationMs: 120,
                            processId: nil,
                            actions: []
                        )),
                        sourceTurnId: turnId,
                        sourceTurnIndex: UInt32(turnIdx),
                        timestamp: turnTime + Double(itemIdx),
                        isFromUserTurnBoundary: false
                    ))
                }
            }
        }
        return items
    }

    private func makeUserItem(
        id: String? = nil,
        text: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date
    ) -> ConversationItem {
        ConversationItem(
            id: id ?? UUID().uuidString,
            content: .user(ConversationUserMessageData(text: text, images: [])),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: true
        )
    }

    private func makeAssistantItem(
        id: String? = nil,
        text: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date
    ) -> ConversationItem {
        ConversationItem(
            id: id ?? UUID().uuidString,
            content: .assistant(ConversationAssistantMessageData(text: text, agentNickname: nil, agentRole: nil)),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp
        )
    }

    private func makeCommandItem(
        command: String,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date,
        durationMs: Int? = nil
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            content: .commandExecution(
                ConversationCommandExecutionData(
                    command: command,
                    cwd: "/tmp",
                    status: .completed,
                    output: nil,
                    exitCode: 0,
                    durationMs: durationMs,
                    processId: nil,
                    actions: []
                )
            ),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp
        )
    }
}
