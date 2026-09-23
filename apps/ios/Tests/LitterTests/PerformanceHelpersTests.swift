import XCTest
@testable import Litter

@MainActor
final class PerformanceHelpersTests: XCTestCase {
    func testLargeConversationRespectsCollapsePreference() {
        for count in [1, 199, 200, 2_500] {
            XCTAssertEqual(ConversationTurnCollapsePolicy.expandedRecentTurnCount(
                preferenceEnabled: false, itemCount: count
            ), .max)
            XCTAssertEqual(ConversationTurnCollapsePolicy.expandedRecentTurnCount(
                preferenceEnabled: true, itemCount: count
            ), 1)
        }
    }

    func testFollowUpPreservesExistingExpandedTurns() {
        let now = Date()
        let items = [
            makeUserItem(text: "First", turnId: "a", turnIndex: 0, timestamp: now),
            makeAssistantItem(text: "Answer", turnId: "a", turnIndex: 0, timestamp: now)
        ]
        let initial = TranscriptTurn.build(from: items, threadStatus: .ready, expandedRecentTurnCount: 1)
        let next = TranscriptTurn.build(from: items + [
            makeUserItem(text: "Follow up", turnId: "b", turnIndex: 1, timestamp: now)
        ], threadStatus: .thinking, expandedRecentTurnCount: 1)
        let preserved = TranscriptTurn.preservingCollapseState(in: next, from: initial)
        XCTAssertEqual(preserved.count, 2)
        XCTAssertFalse(preserved[0].isCollapsedByDefault)
        XCTAssertFalse(preserved[1].isCollapsedByDefault)
        XCTAssertEqual(preserved[0].items, initial[0].items)
    }

    func testAcknowledgementPreservesCollapseStateAndExpansionAlias() {
        let now = Date()
        let old = TranscriptTurn.build(from: [
            makeUserItem(id: "optimistic", text: "Prompt", turnId: "a", turnIndex: 0, timestamp: now)
        ], threadStatus: .ready, expandedRecentTurnCount: 1)
        let next = TranscriptTurn.build(from: [
            makeUserItem(id: "acknowledged", text: "Prompt", turnId: "a", turnIndex: 0, timestamp: now),
            makeUserItem(text: "Follow up", turnId: "b", turnIndex: 1, timestamp: now)
        ], threadStatus: .thinking, expandedRecentTurnCount: 1)
        XCTAssertFalse(TranscriptTurn.preservingCollapseState(in: next, from: old)[0].isCollapsedByDefault)
        XCTAssertEqual(TranscriptTurn.previousTurnIDs(in: next, from: old)[next[0].id], old[0].id)
    }

    func testTurnIdentitySurvivesLateServerProvenance() {
        var user = makeUserItem(text: "Prompt", turnId: nil, turnIndex: nil, timestamp: Date())
        let before = TranscriptTurn.build(from: [user], threadStatus: .thinking)
        user.sourceTurnId = "server-turn"
        user.sourceTurnIndex = 0
        let after = TranscriptTurn.build(from: [user], threadStatus: .thinking)
        XCTAssertEqual(before[0].id, after[0].id)
    }

    func testAcknowledgedUserIdentityDoesNotReplaceAssistantScrollTarget() {
        let now = Date()
        let assistant = makeAssistantItem(text: "Reply", turnId: "a", turnIndex: 0, timestamp: now)
        var projection = ConversationTranscriptProjection()
        func update(userID: String) {
            let turns = TranscriptTurn.build(from: [
                makeUserItem(id: userID, text: "Prompt", turnId: "a", turnIndex: 0, timestamp: now),
                assistant
            ], threadStatus: .thinking, expandedRecentTurnCount: .max)
            projection.update(turns: turns, expandedTurnIDs: [], reasoning: .collapsed,
                              commands: .collapsed, tools: .collapsed)
        }
        update(userID: "optimistic")
        let assistantTarget = projection.entries[1].id
        update(userID: "acknowledged")
        XCTAssertEqual(projection.entries[1].id, assistantTarget)
    }

    func testStreamingDoesNotMergeDifferentAuthoritativeTurns() {
        let now = Date()
        let items = [
            makeUserItem(text: "Prompt", turnId: "a", turnIndex: 0, timestamp: now),
            makeAssistantItem(text: "Old response", turnId: "a", turnIndex: 0, timestamp: now),
            makeAssistantItem(text: "New turn without a user echo", turnId: "b", turnIndex: 1, timestamp: now)
        ]
        let turns = TranscriptTurn.build(from: items, threadStatus: .thinking, expandedRecentTurnCount: .max)
        XCTAssertEqual(turns.count, 2)
        XCTAssertFalse(turns[0].isLive)
        XCTAssertTrue(turns[1].isLive)
        XCTAssertEqual(turns.flatMap(\.items), items)
    }

    func testResumedLiveTurnAlwaysRendersItsMessages() {
        let turn = TranscriptTurn.build(from: [
            makeUserItem(text: "Resume", turnId: "a", turnIndex: 0, timestamp: Date())
        ], threadStatus: .thinking)[0].withCollapsedByDefault(true)
        var projection = ConversationTranscriptProjection()
        projection.update(turns: [turn], expandedTurnIDs: [], reasoning: .collapsed,
                          commands: .collapsed, tools: .collapsed)
        XCTAssertEqual(projection.entries.count, 2)
        guard case .row = projection.entries[0].content else {
            return XCTFail("A resumed live turn must not be hidden behind a summary")
        }
    }

    func testLongTurnProjectsIndividualStableScrollTargets() {
        let now = Date()
        var items = [makeUserItem(text: "Prompt", turnId: "a", turnIndex: 0, timestamp: now)]
        items += (0..<500).map { index in
            makeAssistantItem(text: "Message \(index)", turnId: "a", turnIndex: 0, timestamp: now)
        }
        var projection = ConversationTranscriptProjection()
        func update(_ turns: [TranscriptTurn], expanded: Set<String> = []) {
            projection.update(turns: turns, expandedTurnIDs: expanded,
                              reasoning: .collapsed, commands: .collapsed, tools: .collapsed)
        }
        let initial = TranscriptTurn.build(from: items, threadStatus: .ready, expandedRecentTurnCount: .max)
        update(initial)
        let previousIDs = projection.entries.map(\.id)
        XCTAssertEqual(previousIDs.count, 501)
        XCTAssertEqual(Set(previousIDs).count, 501)
        XCTAssertEqual(Set(projection.turnIDByEntryID.values), [initial[0].id])

        items.append(makeUserItem(text: "Follow up", turnId: "b", turnIndex: 1, timestamp: now))
        let next = TranscriptTurn.build(from: items, threadStatus: .thinking, expandedRecentTurnCount: 1)
        let preserved = TranscriptTurn.preservingCollapseState(in: next, from: initial)
        update(preserved)
        XCTAssertEqual(Array(projection.entries.prefix(previousIDs.count).map(\.id)), previousIDs)
        XCTAssertEqual(projection.entries.count, 503) // Prior rows, follow-up, typing footer.

        // An explicit expansion of a restored collapsed turn also survives updates.
        update(next, expanded: [next[0].id])
        XCTAssertEqual(Array(projection.entries.prefix(previousIDs.count).map(\.id)), previousIDs)
    }

    func testInfiniteScrollPrefetchesBeforeTheVisibleCacheEdge() {
        let orderedIDs = (0..<20).map { "turn-\($0)" }

        XCTAssertEqual(
            ConversationInfiniteScrollPolicy.earliestVisibleIndex(
                visibleIDs: ["turn-8", "turn-9", "turn-10"],
                orderedIDs: orderedIDs
            ),
            8
        )
        XCTAssertEqual(
            ConversationInfiniteScrollPolicy.earliestVisibleIndex(
                visibleIDs: ["turn-4", "turn-5", "turn-6"],
                orderedIDs: orderedIDs
            ),
            4
        )
    }

    func testTranscriptTurnBuilderCollapsesPreviousTurnOnceANewLiveTurnStarts() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Turn 1", turnId: "turn-1", turnIndex: 0, timestamp: baseTime),
                makeAssistantItem(text: "Reply 1", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.3)),
                makeUserItem(text: "Turn 2", turnId: "turn-2", turnIndex: 1, timestamp: baseTime.addingTimeInterval(1)),
                makeAssistantItem(text: "Reply 2", turnId: "turn-2", turnIndex: 1, timestamp: baseTime.addingTimeInterval(1.6)),
                makeUserItem(text: "Turn 3", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(2)),
                makeCommandItem(command: "rg status", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(4.2)),
                makeAssistantItem(text: "Reply 3", turnId: "turn-3", turnIndex: 2, timestamp: baseTime.addingTimeInterval(5.2)),
                makeUserItem(text: "Turn 4", turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(6)),
                makeAssistantItem(text: "Streaming reply", turnId: nil, turnIndex: nil, timestamp: baseTime.addingTimeInterval(6.4))
            ],
            threadStatus: .thinking,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 4)
        XCTAssertTrue(turns[0].isCollapsedByDefault)
        XCTAssertTrue(turns[1].isCollapsedByDefault)
        XCTAssertTrue(turns[2].isCollapsedByDefault)
        XCTAssertTrue(turns[3].isLive)
        XCTAssertFalse(turns[3].isCollapsedByDefault)
        XCTAssertEqual(turns[2].preview.secondaryText, "Reply 3")
        XCTAssertEqual(turns[2].preview.toolCallCount, 1)
        XCTAssertEqual(turns[2].preview.durationText, "3.2s")
    }

    func testTranscriptTurnBuilderUsesUserToAssistantDuration() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Inspect repo", turnId: "turn-1", turnIndex: 0, timestamp: baseTime),
                makeCommandItem(command: "rg repo", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.2), durationMs: 840),
                makeAssistantItem(text: "Done", turnId: "turn-1", turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.84))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
        XCTAssertEqual(turns[0].preview.toolCallCount, 1)
    }

    func testTranscriptTurnBuilderProducesUniqueIDsWhenSourceTurnIDRepeatsAcrossBoundarySplits() {
        let baseTime = Date(timeIntervalSince1970: 100)
        let repeatedSourceTurnId = "turn-1"
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(id: "11111111-1111-1111-1111-111111111111", text: "First question", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime),
                makeAssistantItem(id: "11111111-1111-1111-1111-111111111112", text: "First answer", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(0.5)),
                makeUserItem(id: "11111111-1111-1111-1111-111111111113", text: "Follow-up", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(1)),
                makeAssistantItem(id: "11111111-1111-1111-1111-111111111114", text: "Follow-up answer", turnId: repeatedSourceTurnId, turnIndex: 0, timestamp: baseTime.addingTimeInterval(1.5))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(Set(turns.map(\.id)).count, 2)
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    func testTranscriptTurnBuilderFallsBackToExplicitDurationForRestoredHistory() {
        let restoredAt = Date(timeIntervalSince1970: 200)
        let turns = TranscriptTurn.build(
            from: [
                makeUserItem(text: "Inspect repo", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt),
                makeCommandItem(command: "rg repo", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt.addingTimeInterval(0.01), durationMs: 840),
                makeAssistantItem(text: "Done", turnId: "turn-1", turnIndex: 0, timestamp: restoredAt.addingTimeInterval(0.02))
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].preview.durationText, "840ms")
    }

    func testRenderingFiltersEmptyTurnsWithoutMergingAuthoritativeTurns() {
        let baseTime = Date(timeIntervalSince1970: 300)
        let firstTurn = TranscriptTurn.build(
            from: [
                makeExplorationItem(
                    command: "cat reducer.rs",
                    actionKind: .read,
                    path: "/tmp/reducer.rs",
                    turnId: "turn-1",
                    turnIndex: 0,
                    timestamp: baseTime
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0].withCollapsedByDefault(true)
        let emptyAssistantTurn = TranscriptTurn.build(
            from: [
                makeAssistantItem(
                    text: "",
                    turnId: "turn-2",
                    turnIndex: 1,
                    timestamp: baseTime.addingTimeInterval(0.5)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0].withCollapsedByDefault(true)
        let secondTurn = TranscriptTurn.build(
            from: [
                makeExplorationItem(
                    command: "rg pendingSteers",
                    actionKind: .search,
                    path: "/tmp/chatwidget.rs",
                    query: "pendingSteers",
                    turnId: "turn-3",
                    turnIndex: 2,
                    timestamp: baseTime.addingTimeInterval(1)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0].withCollapsedByDefault(true)

        let merged = TranscriptTurn.renderableTurns([
            firstTurn,
            emptyAssistantTurn,
            secondTurn,
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].items.count, 1)
        XCTAssertEqual(merged[1].items.count, 1)
        XCTAssertEqual(merged.map(\.id), [firstTurn.id, secondTurn.id])
        XCTAssertEqual(merged[0].preview.toolCallCount, 1)
        XCTAssertEqual(merged[0].preview.primaryText, "Read reducer.rs")
        XCTAssertTrue(merged[0].isCollapsedByDefault)
    }

    func testRenderMergeStillSplitsOnVisibleAssistantBetweenExplorationTurns() {
        let baseTime = Date(timeIntervalSince1970: 400)
        let firstTurn = TranscriptTurn.build(
            from: [
                makeExplorationItem(
                    command: "cat reducer.rs",
                    actionKind: .read,
                    path: "/tmp/reducer.rs",
                    turnId: "turn-1",
                    turnIndex: 0,
                    timestamp: baseTime
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]
        let visibleAssistantTurn = TranscriptTurn.build(
            from: [
                makeAssistantItem(
                    text: "Checking the reducer",
                    turnId: "turn-2",
                    turnIndex: 1,
                    timestamp: baseTime.addingTimeInterval(0.5)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]
        let secondTurn = TranscriptTurn.build(
            from: [
                makeExplorationItem(
                    command: "rg pendingSteers",
                    actionKind: .search,
                    path: "/tmp/chatwidget.rs",
                    query: "pendingSteers",
                    turnId: "turn-3",
                    turnIndex: 2,
                    timestamp: baseTime.addingTimeInterval(1)
                )
            ],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]

        let merged = TranscriptTurn.renderableTurns([
            firstTurn,
            visibleAssistantTurn,
            secondTurn,
        ])

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].items.count, 1)
        XCTAssertEqual(merged[1].items.count, 1)
        XCTAssertEqual(merged[2].items.count, 1)
    }

    func testExplorationMergeKeepsItsIdentityWhenOlderTurnsArePrepended() {
        let baseTime = Date(timeIntervalSince1970: 500)
        let olderTurn = TranscriptTurn.build(
            from: [makeExplorationItem(
                command: "pwd",
                actionKind: .read,
                path: "/tmp",
                turnId: "turn-0",
                turnIndex: 0,
                timestamp: baseTime
            )],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]
        let firstLoadedTurn = TranscriptTurn.build(
            from: [makeExplorationItem(
                command: "cat reducer.rs",
                actionKind: .read,
                path: "/tmp/reducer.rs",
                turnId: "turn-1",
                turnIndex: 1,
                timestamp: baseTime.addingTimeInterval(1)
            )],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]
        let newestTurn = TranscriptTurn.build(
            from: [makeExplorationItem(
                command: "rg pendingSteers",
                actionKind: .search,
                path: "/tmp/reducer.rs",
                query: "pendingSteers",
                turnId: "turn-2",
                turnIndex: 2,
                timestamp: baseTime.addingTimeInterval(2)
            )],
            threadStatus: .ready,
            expandedRecentTurnCount: 1
        )[0]

        let beforePrepend = TranscriptTurn.renderableTurns([
            firstLoadedTurn,
            newestTurn,
        ])
        let afterPrepend = TranscriptTurn.renderableTurns([
            olderTurn,
            firstLoadedTurn,
            newestTurn,
        ])

        XCTAssertEqual(beforePrepend.map(\.id), Array(afterPrepend.dropFirst().map(\.id)))
    }

    func testMessageRenderCacheReusesStableAssistantRevisionKey() {
        let cache = MessageRenderCache()
        let base64Pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn8Vf0AAAAASUVORK5CYII="
        let messageText = "Hello ![](data:image/png;base64,\(base64Pixel))"
        var message = ChatMessage(role: .assistant, text: messageText)

        let key = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        XCTAssertEqual(cache.assistantEntryCount, 0)

        let initialSegments = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(initialSegments.count, 2)

        let cachedSegments = cache.assistantSegments(for: message, key: key)
        XCTAssertEqual(cache.assistantEntryCount, 1)
        XCTAssertEqual(cachedSegments.map(\.id), initialSegments.map(\.id))

        message.text += "\nMore"
        let changedKey = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        let changedSegments = cache.assistantSegments(for: message, key: changedKey)
        XCTAssertEqual(cache.assistantEntryCount, 2)
        XCTAssertEqual(changedSegments.count, 3)
    }

    func testMessageRenderCacheScopesSystemEntriesByAgentDirectoryRevision() {
        let cache = MessageRenderCache()
        let message = ChatMessage(
            role: .system,
            text: """
            ### Collaboration
            Status: completed
            Tool: ask_agent
            Targets: thread-alpha
            """
        )

        let key0 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 0,
            isStreaming: false
        )
        let key1 = MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: "server-a",
            agentDirectoryVersion: 1,
            isStreaming: false
        )

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key0, resolveTargetLabel: { _ in "Planner [lead]" })
        XCTAssertEqual(cache.systemEntryCount, 1)

        _ = cache.systemParseResult(for: message, key: key1, resolveTargetLabel: { _ in "Builder [worker]" })
        XCTAssertEqual(cache.systemEntryCount, 2)
    }

    func testChatMessageRenderDigestChangesWhenMarkdownChanges() {
        var message = ChatMessage(role: .assistant, text: "# Title")
        let originalDigest = message.renderDigest

        message.text = """
        # Title

        ```swift
        print("updated")
        ```
        """

        XCTAssertNotEqual(message.renderDigest, originalDigest)
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
        durationMs: Int? = nil,
        actions: [ConversationCommandAction] = []
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
                    actions: actions
                )
            ),
            sourceTurnId: turnId,
            sourceTurnIndex: turnIndex,
            timestamp: timestamp
        )
    }

    private func makeExplorationItem(
        command: String,
        actionKind: HydratedCommandActionKind,
        path: String?,
        query: String? = nil,
        turnId: String?,
        turnIndex: Int?,
        timestamp: Date
    ) -> ConversationItem {
        makeCommandItem(
            command: command,
            turnId: turnId,
            turnIndex: turnIndex,
            timestamp: timestamp,
            actions: [
                ConversationCommandAction(
                    kind: actionKind,
                    command: command,
                    name: nil,
                    path: path,
                    query: query
                )
            ]
        )
    }
}
