import XCTest
@testable import Litter

/// End-to-end interaction timing tests that measure how long each
/// user-facing operation takes in wall-clock time. These complement the
/// unit-level `PerformanceMeasurementTests` by timing the full
/// transcript build → projection → merge pipeline at scale.
@MainActor
final class InteractionTimingTests: XCTestCase {

    /// Measure the full pipeline: items → TranscriptTurn.build → merge
    /// with a medium conversation (50 turns × 4 items = 200 items).
    /// This simulates opening a conversation and rendering it.
    func testFullRenderPipeline_200Items() {
        let items = makeConversationItems(turnCount: 50, itemsPerTurn: 4)

        measure {
            let turns = TranscriptTurn.build(
                from: items,
                threadStatus: .thinking,
                expandedRecentTurnCount: 1
            )
            _ = TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(turns)
        }
    }

    /// Full render pipeline with a large conversation
    /// (200 turns × 5 items = 1000 items) — power user scenario.
    func testFullRenderPipeline_1000Items() {
        let items = makeConversationItems(turnCount: 200, itemsPerTurn: 5)

        measure {
            let turns = TranscriptTurn.build(
                from: items,
                threadStatus: .thinking,
                expandedRecentTurnCount: 1
            )
            _ = TranscriptTurn.mergeConsecutiveExplorationTurnsForRendering(turns)
        }
    }

    /// Measure ConversationScreenModel projection at scale
    /// (200 turns × 4 items = 800 hydrated items).
    func testConversationProjection_800Items() {
        let model = ConversationScreenModel()
        let items = makeHydratedItems(turnCount: 200, itemsPerTurn: 4)

        measure {
            _ = model._testProjectConversationItems(from: items)
        }
    }

    /// Simulate streaming: 500 incremental projections where each call
    /// appends one token to the last assistant item. This measures the
    /// per-token cost of the projection path (the coalescer batches
    /// these at ~8fps, but the per-call cost still matters).
    func testStreamingProjection_500TokenIncrements() {
        let model = ConversationScreenModel()
        var items = makeHydratedItems(turnCount: 10, itemsPerTurn: 3)
        let baseText = "This is a streaming response that grows "

        measure {
            for i in 0..<500 {
                // Simulate growing text on the last assistant item
                let lastIdx = items.count - 1
                items[lastIdx] = HydratedConversationItem(
                    id: items[lastIdx].id,
                    content: .assistant(HydratedAssistantMessageData(
                        text: baseText + String(repeating: "x", count: i),
                        agentNickname: nil,
                        agentRole: nil,
                        phase: nil
                    )),
                    sourceTurnId: items[lastIdx].sourceTurnId,
                    sourceTurnIndex: items[lastIdx].sourceTurnIndex,
                    timestamp: items[lastIdx].timestamp,
                    isFromUserTurnBoundary: false
                )
                _ = model._testProjectConversationItems(from: items)
            }
        }
    }

    /// Measure relativeDate with 200 timestamps (home screen with 200 sessions).
    func testRelativeDate_200Sessions() {
        let now = Date().timeIntervalSince1970
        let timestamps: [Int64] = (0..<200).map { i in
            Int64(now - Double(i * 3600))
        }

        measure {
            for ts in timestamps {
                _ = relativeDate(ts)
            }
        }
    }

    /// Measure TranscriptTurn.build with a very large conversation
    /// (500 turns × 5 items = 2500 items) — stress test.
    func testTranscriptTurnBuild_2500Items() {
        let items = makeConversationItems(turnCount: 500, itemsPerTurn: 5)

        measure {
            _ = TranscriptTurn.build(
                from: items,
                threadStatus: .thinking,
                expandedRecentTurnCount: 1
            )
        }
    }

    // MARK: - Helpers

    private func makeHydratedItems(turnCount: Int, itemsPerTurn: Int) -> [HydratedConversationItem] {
        var items: [HydratedConversationItem] = []
        for turnIdx in 0..<turnCount {
            let turnId = "turn-\(turnIdx)"
            let turnTime = Double(turnIdx) * Double(itemsPerTurn) * 2
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

    private func makeConversationItems(turnCount: Int, itemsPerTurn: Int) -> [ConversationItem] {
        var items: [ConversationItem] = []
        for turnIdx in 0..<turnCount {
            let turnId = "turn-\(turnIdx)"
            let turnTime = Date(timeIntervalSince1970: Double(turnIdx) * Double(itemsPerTurn) * 2)
            items.append(ConversationItem(
                id: UUID().uuidString,
                content: .user(ConversationUserMessageData(text: "Question \(turnIdx)", images: [])),
                sourceTurnId: turnId,
                sourceTurnIndex: turnIdx,
                timestamp: turnTime,
                isFromUserTurnBoundary: true
            ))
            for itemIdx in 1..<itemsPerTurn {
                if itemIdx % 2 == 0 {
                    items.append(ConversationItem(
                        id: UUID().uuidString,
                        content: .assistant(ConversationAssistantMessageData(
                            text: "Answer \(turnIdx).\(itemIdx) " + String(repeating: "x", count: 20),
                            agentNickname: nil,
                            agentRole: nil
                        )),
                        sourceTurnId: turnId,
                        sourceTurnIndex: turnIdx,
                        timestamp: turnTime.addingTimeInterval(Double(itemIdx))
                    ))
                } else {
                    items.append(ConversationItem(
                        id: UUID().uuidString,
                        content: .commandExecution(ConversationCommandExecutionData(
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
                        sourceTurnIndex: turnIdx,
                        timestamp: turnTime.addingTimeInterval(Double(itemIdx))
                    ))
                }
            }
        }
        return items
    }
}
