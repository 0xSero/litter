import XCTest
@testable import Litter

@MainActor
final class WatchProjectionTests: XCTestCase {

    // MARK: - 1. Status ranking + sort tiebreak

    func testTasksOrdersNeedsApprovalThenRunningThenIdleAndTieBreaksByRecency() {
        let needsApproval = makeSummary(
            serverId: "srv",
            threadId: "needs",
            updatedAt: 100,
            hasActiveTurn: false
        )
        let running = makeSummary(
            serverId: "srv",
            threadId: "running",
            updatedAt: 200,
            hasActiveTurn: true
        )
        let idleNew = makeSummary(
            serverId: "srv",
            threadId: "idle-new",
            updatedAt: 500,
            hasActiveTurn: false
        )
        let idleOld = makeSummary(
            serverId: "srv",
            threadId: "idle-old",
            updatedAt: 300,
            hasActiveTurn: false
        )
        let bothApprovalAndRunning = makeSummary(
            serverId: "srv",
            threadId: "both",
            updatedAt: 50,
            hasActiveTurn: true
        )

        let approvals = [
            makePendingApproval(id: "a-needs", threadId: "needs", kind: .command),
            makePendingApproval(id: "a-both", threadId: "both", kind: .fileChange)
        ]

        let result = WatchProjection.tasks(
            summaries: [idleOld, running, idleNew, needsApproval, bothApprovalAndRunning],
            threads: [],
            pendingApprovals: approvals
        )

        // needsApproval entries first; among them, the more recent updatedAt
        // wins (needs=100 > both=50). Then running, then idle (idle-new=500 > idle-old=300).
        XCTAssertEqual(
            result.map(\.threadId),
            ["needs", "both", "running", "idle-new", "idle-old"]
        )
        XCTAssertEqual(result[0].status, .needsApproval)
        XCTAssertEqual(result[1].status, .needsApproval)
        XCTAssertEqual(result[2].status, .running)
        XCTAssertEqual(result[3].status, .idle)
        XCTAssertEqual(result[4].status, .idle)
    }

    func testTasksIgnoresMcpElicitationApprovalsForStatusGrouping() {
        // mcpElicitation approvals are filtered out of status grouping —
        // the thread should fall back to its non-approval status.
        let summary = makeSummary(
            serverId: "srv",
            threadId: "thread",
            updatedAt: 100,
            hasActiveTurn: true
        )
        let approval = makePendingApproval(
            id: "ignored",
            threadId: "thread",
            kind: .mcpElicitation
        )

        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: [approval]
        )

        XCTAssertEqual(result.first?.status, .running)
        XCTAssertNil(result.first?.pendingApprovalId)
    }

    // MARK: - 2. Subtitle precedence + compact() truncation

    func testSubtitlePrefersPendingApprovalOverEverythingElse() {
        let summary = makeSummary(
            serverId: "srv",
            threadId: "t1",
            updatedAt: 1,
            hasActiveTurn: false,
            lastToolLabel: "edit_file src/foo.swift",
            lastResponsePreview: "ignored response",
            lastUserMessage: "ignored user",
            preview: "ignored preview"
        )
        let approval = makePendingApproval(
            id: "ap",
            threadId: "t1",
            kind: .command,
            command: "git push"
        )

        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: [approval]
        )

        XCTAssertEqual(result.first?.subtitle, "awaiting approval: git push")
        XCTAssertEqual(result.first?.pendingApprovalId, "ap")
    }

    func testSubtitleFallsBackToLastToolLabelThenResponsePreviewThenUserThenPreviewThenNil() {
        // last tool wins when present
        let withTool = makeSummary(
            serverId: "srv",
            threadId: "tool",
            updatedAt: 1,
            hasActiveTurn: false,
            lastToolLabel: "ran tests",
            lastResponsePreview: "ignored",
            lastUserMessage: "ignored",
            preview: "ignored"
        )
        // tool empty -> response preview wins
        let withResponse = makeSummary(
            serverId: "srv",
            threadId: "resp",
            updatedAt: 2,
            hasActiveTurn: false,
            lastToolLabel: nil,
            lastResponsePreview: "assistant said hi",
            lastUserMessage: "ignored",
            preview: "ignored"
        )
        // tool+response empty -> user message wins
        let withUser = makeSummary(
            serverId: "srv",
            threadId: "user",
            updatedAt: 3,
            hasActiveTurn: false,
            lastToolLabel: nil,
            lastResponsePreview: nil,
            lastUserMessage: "user said hi",
            preview: "ignored"
        )
        // all of the above empty -> preview field
        let withPreview = makeSummary(
            serverId: "srv",
            threadId: "prev",
            updatedAt: 4,
            hasActiveTurn: false,
            lastToolLabel: nil,
            lastResponsePreview: nil,
            lastUserMessage: nil,
            preview: "preview line"
        )
        // nothing at all -> nil
        let withNothing = makeSummary(
            serverId: "srv",
            threadId: "none",
            updatedAt: 5,
            hasActiveTurn: false,
            lastToolLabel: nil,
            lastResponsePreview: nil,
            lastUserMessage: nil,
            preview: ""
        )

        let result = WatchProjection.tasks(
            summaries: [withTool, withResponse, withUser, withPreview, withNothing],
            threads: [],
            pendingApprovals: []
        )

        let byThread = Dictionary(uniqueKeysWithValues: result.map { ($0.threadId, $0) })
        XCTAssertEqual(byThread["tool"]?.subtitle, "ran tests")
        XCTAssertEqual(byThread["resp"]?.subtitle, "assistant said hi")
        XCTAssertEqual(byThread["user"]?.subtitle, "user said hi")
        XCTAssertEqual(byThread["prev"]?.subtitle, "preview line")
        XCTAssertNil(byThread["none"]?.subtitle)
    }

    func testSubtitleEmptyStringsAreTreatedAsAbsent() {
        // Empty strings should be skipped and the next non-empty source used.
        let summary = makeSummary(
            serverId: "srv",
            threadId: "t",
            updatedAt: 1,
            hasActiveTurn: false,
            lastToolLabel: "",
            lastResponsePreview: "",
            lastUserMessage: "",
            preview: "fallback"
        )

        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: []
        )
        XCTAssertEqual(result.first?.subtitle, "fallback")
    }

    func testSubtitleAppliesCompactTruncationAtTheRightMaxWidths() {
        // tool label uses max=48
        let toolText = String(repeating: "a", count: 60)
        let toolSummary = makeSummary(
            serverId: "srv",
            threadId: "tool",
            updatedAt: 1,
            hasActiveTurn: false,
            lastToolLabel: toolText
        )
        // response preview uses max=60
        let respText = String(repeating: "b", count: 80)
        let respSummary = makeSummary(
            serverId: "srv",
            threadId: "resp",
            updatedAt: 2,
            hasActiveTurn: false,
            lastResponsePreview: respText
        )

        let result = WatchProjection.tasks(
            summaries: [toolSummary, respSummary],
            threads: [],
            pendingApprovals: []
        )
        let byThread = Dictionary(uniqueKeysWithValues: result.map { ($0.threadId, $0) })

        // compact pattern: take prefix(max - 1) and append "…"
        XCTAssertEqual(byThread["tool"]?.subtitle, String(repeating: "a", count: 47) + "…")
        XCTAssertEqual(byThread["tool"]?.subtitle?.count, 48)
        XCTAssertEqual(byThread["resp"]?.subtitle, String(repeating: "b", count: 59) + "…")
        XCTAssertEqual(byThread["resp"]?.subtitle?.count, 60)
    }

    func testApprovalSubtitleTruncatesCommandAt32() {
        let longCmd = String(repeating: "x", count: 50)
        let summary = makeSummary(
            serverId: "srv",
            threadId: "t",
            updatedAt: 1,
            hasActiveTurn: false
        )
        let approval = makePendingApproval(
            id: "ap",
            threadId: "t",
            kind: .command,
            command: longCmd
        )

        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: [approval]
        )
        // approvalLabel(.command) compacts at max=32, then prefixed with "awaiting approval: "
        let truncated = String(repeating: "x", count: 31) + "…"
        XCTAssertEqual(result.first?.subtitle, "awaiting approval: \(truncated)")
    }

    func testTitleFallsBackThroughLastUserMessageThenPreviewThenUntitled() {
        let withTitle = makeSummary(
            serverId: "srv", threadId: "a",
            updatedAt: 1, hasActiveTurn: false,
            title: "Real title",
            lastUserMessage: "ignored",
            preview: "ignored"
        )
        let withUser = makeSummary(
            serverId: "srv", threadId: "b",
            updatedAt: 2, hasActiveTurn: false,
            title: "",
            lastUserMessage: "from user",
            preview: "ignored"
        )
        let withPreview = makeSummary(
            serverId: "srv", threadId: "c",
            updatedAt: 3, hasActiveTurn: false,
            title: "",
            lastUserMessage: nil,
            preview: "preview text"
        )
        let withNothing = makeSummary(
            serverId: "srv", threadId: "d",
            updatedAt: 4, hasActiveTurn: false,
            title: "",
            lastUserMessage: nil,
            preview: ""
        )

        let result = WatchProjection.tasks(
            summaries: [withTitle, withUser, withPreview, withNothing],
            threads: [],
            pendingApprovals: []
        )
        let byThread = Dictionary(uniqueKeysWithValues: result.map { ($0.threadId, $0) })
        XCTAssertEqual(byThread["a"]?.title, "Real title")
        XCTAssertEqual(byThread["b"]?.title, "from user")
        XCTAssertEqual(byThread["c"]?.title, "preview text")
        XCTAssertEqual(byThread["d"]?.title, "untitled task")
    }

    // MARK: - 3. relativeTime

    func testRelativeTimeFormatsAcrossExpectedBuckets() {
        // We can't drive Date.now in the implementation, so we pick deltas
        // that are far enough from boundaries to be stable across millisecond
        // jitter during the test run.
        let now = Date()
        func epoch(_ secondsAgo: TimeInterval) -> Int64 {
            Int64(now.timeIntervalSince1970 - secondsAgo)
        }

        let s30 = makeSummary(serverId: "srv", threadId: "s30", updatedAt: epoch(30), hasActiveTurn: false)
        let s90 = makeSummary(serverId: "srv", threadId: "s90", updatedAt: epoch(90), hasActiveTurn: false)
        let s65min = makeSummary(serverId: "srv", threadId: "s65", updatedAt: epoch(65 * 60), hasActiveTurn: false)
        let s25h = makeSummary(serverId: "srv", threadId: "s25h", updatedAt: epoch(25 * 3600), hasActiveTurn: false)
        let s8d = makeSummary(serverId: "srv", threadId: "s8d", updatedAt: epoch(8 * 86400), hasActiveTurn: false)
        let sNoTime = makeSummary(serverId: "srv", threadId: "sNo", updatedAt: nil, hasActiveTurn: false)

        let result = WatchProjection.tasks(
            summaries: [s30, s90, s65min, s25h, s8d, sNoTime],
            threads: [],
            pendingApprovals: []
        )
        let byThread = Dictionary(uniqueKeysWithValues: result.map { ($0.threadId, $0) })

        XCTAssertEqual(byThread["s30"]?.relativeTime, "now")
        XCTAssertEqual(byThread["s90"]?.relativeTime, "1m")
        XCTAssertEqual(byThread["s65"]?.relativeTime, "1h")
        XCTAssertEqual(byThread["s25h"]?.relativeTime, "1d")
        // 8 days ago -> formatter "MMM d"
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let expected = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch(8 * 86400))))
        XCTAssertEqual(byThread["s8d"]?.relativeTime, expected)
        XCTAssertEqual(byThread["sNo"]?.relativeTime, "")
    }

    // MARK: - 4. deriveSteps + status mapping

    func testDeriveStepsKeepsLastFiveOfTwelveAndMapsEachStatus() {
        // 12 items total. Mix kinds so deriveSteps yields steps for all 12,
        // but only the last 5 are returned.
        var items: [HydratedConversationItem] = []
        for i in 0..<12 {
            let cmd = makeCommandItem(
                id: "cmd-\(i)",
                command: "step\(i)",
                status: .completed
            )
            items.append(cmd)
        }
        // Replace the final 5 with a status-mapping mix so we can verify the
        // mapping rules per state. Order in items: indices 7..11 are last-5.
        items[7]  = makeCommandItem(id: "i7", command: "completed", status: .completed)
        items[8]  = makeCommandItem(id: "i8", command: "failed",    status: .failed)
        items[9]  = makeCommandItem(id: "i9", command: "declined",  status: .declined)
        items[10] = makeCommandItem(id: "i10", command: "active",   status: .inProgress)
        items[11] = makeCommandItem(id: "i11", command: "pending",  status: .pending)

        let thread = makeThread(serverId: "srv", threadId: "t", items: items)
        let summary = makeSummary(serverId: "srv", threadId: "t", updatedAt: 100, hasActiveTurn: false)

        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [thread],
            pendingApprovals: []
        )
        let steps = result.first?.steps ?? []
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps.map(\.arg), ["completed", "failed", "declined", "active", "pending"])
        XCTAssertEqual(steps.map(\.state), [.done, .done, .done, .active, .pending])
    }

    func testDeriveStepsHandlesUnknownStatusAsPending() {
        let thread = makeThread(
            serverId: "srv",
            threadId: "t",
            items: [makeCommandItem(id: "u", command: "unk", status: .unknown)]
        )
        let summary = makeSummary(serverId: "srv", threadId: "t", updatedAt: 1, hasActiveTurn: false)
        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [thread],
            pendingApprovals: []
        )
        XCTAssertEqual(result.first?.steps.first?.state, .pending)
    }

    func testDeriveStepsCoversAllSupportedItemKinds() {
        let webSearchInProgress = makeWebSearchItem(id: "w1", query: "swift", isInProgress: true)
        let webSearchDone = makeWebSearchItem(id: "w2", query: "rust", isInProgress: false)
        let mcp = makeMcpItem(id: "m1", tool: "summarize", contentSummary: "did the thing", status: .inProgress)
        let dyn = makeDynamicItem(id: "d1", tool: "lookup", contentSummary: "found it", status: .completed)
        let fileChange = makeFileChangeItem(
            id: "f1",
            path: "src/foo.swift",
            kind: "edit",
            status: .completed
        )

        let thread = makeThread(
            serverId: "srv",
            threadId: "t",
            items: [webSearchInProgress, webSearchDone, mcp, dyn, fileChange]
        )
        let summary = makeSummary(serverId: "srv", threadId: "t", updatedAt: 1, hasActiveTurn: false)
        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [thread],
            pendingApprovals: []
        )
        let steps = result.first?.steps ?? []
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps[0].tool, "web_search")
        XCTAssertEqual(steps[0].state, .active)
        XCTAssertEqual(steps[1].tool, "web_search")
        XCTAssertEqual(steps[1].state, .done)
        XCTAssertEqual(steps[2].tool, "summarize")
        XCTAssertEqual(steps[2].state, .active)
        XCTAssertEqual(steps[3].tool, "lookup")
        XCTAssertEqual(steps[3].state, .done)
        XCTAssertEqual(steps[4].tool, "edit_file")
        XCTAssertEqual(steps[4].state, .done)
    }

    func testDeriveStepsReturnsEmptyWhenThreadIsAbsent() {
        let summary = makeSummary(serverId: "srv", threadId: "t", updatedAt: 1, hasActiveTurn: false)
        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: []
        )
        XCTAssertEqual(result.first?.steps, [])
    }

    // MARK: - 5. mapFileChangeKind

    func testFileChangeKindMaps() {
        let cases: [(String, String)] = [
            ("add",     "create_file"),
            ("create",  "create_file"),
            ("CREATED", "create_file"),
            ("delete",  "delete_file"),
            ("remove",  "delete_file"),
            ("edit",    "edit_file"),
            ("modify",  "edit_file"),
            ("",        "edit_file")
        ]

        for (kind, expectedTool) in cases {
            let thread = makeThread(
                serverId: "srv", threadId: "t",
                items: [makeFileChangeItem(id: "f", path: "/p", kind: kind, status: .completed)]
            )
            let summary = makeSummary(serverId: "srv", threadId: "t", updatedAt: 1, hasActiveTurn: false)
            let result = WatchProjection.tasks(
                summaries: [summary],
                threads: [thread],
                pendingApprovals: []
            )
            XCTAssertEqual(result.first?.steps.first?.tool, expectedTool, "kind=\(kind)")
        }
    }

    // MARK: - 6. transcript(for:)

    func testTranscriptCapsAtFourTurnsAndPrefixesCommands() {
        var items: [HydratedConversationItem] = []
        for i in 0..<3 {
            items.append(makeUserItem(id: "u\(i)", text: "user-\(i)"))
            items.append(makeAssistantItem(id: "a\(i)", text: "assistant-\(i)"))
        }
        items.append(makeCommandItem(id: "cmd", command: "ls -la", status: .completed))

        let thread = makeThread(serverId: "srv", threadId: "t", items: items)
        let result = WatchProjection.transcript(for: thread)

        XCTAssertEqual(result.count, 4)
        // The full mapped sequence is:
        //   user-0, assistant-0, user-1, assistant-1, user-2, assistant-2, $ ls -la
        // After Array(turns.suffix(4)) we keep the last four:
        XCTAssertEqual(
            result.map(\.text),
            ["assistant-1", "user-2", "assistant-2", "$ ls -la"]
        )
        XCTAssertEqual(result.map(\.role), [.assistant, .user, .assistant, .system])
    }

    func testTranscriptFiltersEmptyUserAndAssistantText() {
        let items: [HydratedConversationItem] = [
            makeUserItem(id: "u-empty", text: ""),
            makeUserItem(id: "u-real",  text: "hello"),
            makeAssistantItem(id: "a-empty", text: ""),
            makeAssistantItem(id: "a-real",  text: "hi")
        ]
        let thread = makeThread(serverId: "srv", threadId: "t", items: items)
        let result = WatchProjection.transcript(for: thread)

        XCTAssertEqual(result.map(\.text), ["hello", "hi"])
        XCTAssertEqual(result.map(\.role), [.user, .assistant])
    }

    func testTranscriptCommandWithBlankCommandFallsBackToRanCommand() {
        let thread = makeThread(
            serverId: "srv",
            threadId: "t",
            items: [makeCommandItem(id: "c", command: "   ", status: .completed)]
        )
        let result = WatchProjection.transcript(for: thread)
        XCTAssertEqual(result.first?.text, "ran command")
        XCTAssertEqual(result.first?.role, .system)
    }

    // MARK: - 7. approval(_:)

    func testApprovalProducesRightCommandTargetDiffPerKind() {
        let cmd = makePendingApproval(
            id: "1",
            threadId: nil,
            kind: .command,
            command: "ls -la",
            cwd: "/tmp",
            reason: "list dir"
        )
        let cmdResult = WatchProjection.approval(cmd)
        XCTAssertEqual(cmdResult.kind, .command)
        XCTAssertEqual(cmdResult.command, "ls -la")
        XCTAssertEqual(cmdResult.target, "/tmp")
        XCTAssertEqual(cmdResult.diffSummary, "list dir")

        let fc = makePendingApproval(
            id: "2",
            threadId: nil,
            kind: .fileChange,
            path: "/etc/foo.conf",
            grantRoot: "/etc"
        )
        let fcResult = WatchProjection.approval(fc)
        XCTAssertEqual(fcResult.kind, .fileChange)
        XCTAssertEqual(fcResult.command, "edit_file")
        XCTAssertEqual(fcResult.target, "/etc/foo.conf")
        XCTAssertEqual(fcResult.diffSummary, "/etc")

        let perm = makePendingApproval(
            id: "3",
            threadId: nil,
            kind: .permissions,
            reason: "grant network"
        )
        let permResult = WatchProjection.approval(perm)
        XCTAssertEqual(permResult.kind, .permissions)
        XCTAssertEqual(permResult.command, "permissions")
        XCTAssertEqual(permResult.target, "grant network")
        XCTAssertEqual(permResult.diffSummary, "")

        let mcp = makePendingApproval(
            id: "4",
            threadId: nil,
            kind: .mcpElicitation,
            reason: "give me input"
        )
        let mcpResult = WatchProjection.approval(mcp)
        XCTAssertEqual(mcpResult.kind, .mcpElicitation)
        XCTAssertEqual(mcpResult.command, "mcp")
        XCTAssertEqual(mcpResult.target, "give me input")
        XCTAssertEqual(mcpResult.diffSummary, "")
    }

    func testApprovalUsesFallbacksWhenOptionalFieldsMissing() {
        // command kind without command -> falls back to "command"; without
        // reason -> diffSummary is "".
        let bareCmd = makePendingApproval(id: "1", threadId: nil, kind: .command)
        let cmdResult = WatchProjection.approval(bareCmd)
        XCTAssertEqual(cmdResult.command, "command")
        XCTAssertEqual(cmdResult.target, "")
        XCTAssertEqual(cmdResult.diffSummary, "")

        // fileChange without path -> "file"; without grantRoot -> "".
        let bareFc = makePendingApproval(id: "2", threadId: nil, kind: .fileChange)
        let fcResult = WatchProjection.approval(bareFc)
        XCTAssertEqual(fcResult.command, "edit_file")
        XCTAssertEqual(fcResult.target, "file")
        XCTAssertEqual(fcResult.diffSummary, "")

        // permissions without reason -> "grant access"
        let barePerm = makePendingApproval(id: "3", threadId: nil, kind: .permissions)
        let permResult = WatchProjection.approval(barePerm)
        XCTAssertEqual(permResult.target, "grant access")

        // mcpElicitation without reason -> "input requested"
        let bareMcp = makePendingApproval(id: "4", threadId: nil, kind: .mcpElicitation)
        let mcpResult = WatchProjection.approval(bareMcp)
        XCTAssertEqual(mcpResult.target, "input requested")
    }

    // MARK: - 8. voice(from:)

    func testVoiceReturnsNilWhenSnapshotIsNil() {
        XCTAssertNil(WatchProjection.voice(from: nil))
    }

    func testVoiceReturnsNilWhenSessionIsCompletelyEmpty() {
        let snapshot = makeSnapshot(voiceSession: AppVoiceSessionSnapshot(
            activeThread: nil,
            sessionId: nil,
            phase: nil,
            lastError: nil,
            transcriptEntries: [],
            handoffThreadKey: nil
        ))
        XCTAssertNil(WatchProjection.voice(from: snapshot))
    }

    func testVoiceMapsPhasesAndExposesActiveThreadAndAudio() {
        let phases: [(AppVoiceSessionPhase?, WatchVoiceState.Mode)] = [
            (.listening,  .listening),
            (.speaking,   .speaking),
            (.thinking,   .thinking),
            (.handoff,    .thinking),
            (.error,      .error),
            (.connecting, .idle)
        ]

        for (phase, expected) in phases {
            let snapshot = makeSnapshot(voiceSession: AppVoiceSessionSnapshot(
                activeThread: ThreadKey(serverId: "srv", threadId: "th"),
                sessionId: "sess",
                phase: phase,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            ))
            let voice = WatchProjection.voice(from: snapshot, audioLevel: 0.6, isMuted: true)
            XCTAssertEqual(voice?.mode, expected, "phase=\(String(describing: phase))")
            XCTAssertEqual(voice?.serverId, "srv")
            XCTAssertEqual(voice?.threadId, "th")
            XCTAssertEqual(voice?.audioLevel, 0.6)
            XCTAssertEqual(voice?.isMuted, true)
        }
    }

    func testVoiceClampsAudioLevelToZeroOneRange() {
        let snapshot = makeSnapshot(voiceSession: AppVoiceSessionSnapshot(
            activeThread: ThreadKey(serverId: "srv", threadId: "th"),
            sessionId: nil,
            phase: .listening,
            lastError: nil,
            transcriptEntries: [],
            handoffThreadKey: nil
        ))

        XCTAssertEqual(WatchProjection.voice(from: snapshot, audioLevel: -2)?.audioLevel, 0)
        XCTAssertEqual(WatchProjection.voice(from: snapshot, audioLevel: 5)?.audioLevel, 1)
        XCTAssertEqual(WatchProjection.voice(from: snapshot, audioLevel: 0.5)?.audioLevel, 0.5)
    }

    func testVoiceTranscriptKeepsLastFourTurnsAndMapsSpeakers() {
        let entries: [AppVoiceTranscriptEntry] = [
            AppVoiceTranscriptEntry(itemId: "1", speaker: .user,      text: "first"),
            AppVoiceTranscriptEntry(itemId: "2", speaker: .assistant, text: "second"),
            AppVoiceTranscriptEntry(itemId: "3", speaker: .user,      text: "third"),
            AppVoiceTranscriptEntry(itemId: "4", speaker: .assistant, text: "fourth"),
            AppVoiceTranscriptEntry(itemId: "5", speaker: .user,      text: "fifth"),
            AppVoiceTranscriptEntry(itemId: "6", speaker: .assistant, text: "sixth")
        ]
        let snapshot = makeSnapshot(voiceSession: AppVoiceSessionSnapshot(
            activeThread: ThreadKey(serverId: "srv", threadId: "th"),
            sessionId: nil,
            phase: .speaking,
            lastError: nil,
            transcriptEntries: entries,
            handoffThreadKey: nil
        ))

        let voice = WatchProjection.voice(from: snapshot)
        XCTAssertEqual(voice?.recentTurns.count, 4)
        XCTAssertEqual(voice?.recentTurns.map(\.text), ["third", "fourth", "fifth", "sixth"])
        XCTAssertEqual(voice?.recentTurns.map(\.role), [.user, .assistant, .user, .assistant])
    }

    func testVoiceProjectsSessionWithOnlyTranscriptAndNoActiveThread() {
        let snapshot = makeSnapshot(voiceSession: AppVoiceSessionSnapshot(
            activeThread: nil,
            sessionId: nil,
            phase: nil,
            lastError: nil,
            transcriptEntries: [
                AppVoiceTranscriptEntry(itemId: "1", speaker: .user, text: "hi")
            ],
            handoffThreadKey: nil
        ))

        let voice = WatchProjection.voice(from: snapshot)
        XCTAssertNotNil(voice)
        XCTAssertEqual(voice?.mode, .idle)
        XCTAssertNil(voice?.serverId)
        XCTAssertNil(voice?.threadId)
        XCTAssertEqual(voice?.recentTurns.first?.text, "hi")
    }

    // MARK: - Identifier shape

    func testTaskIdIsServerIdColonThreadId() {
        let summary = makeSummary(
            serverId: "studio.lan",
            threadId: "t99",
            updatedAt: 1,
            hasActiveTurn: false
        )
        let result = WatchProjection.tasks(
            summaries: [summary],
            threads: [],
            pendingApprovals: []
        )
        XCTAssertEqual(result.first?.id, "studio.lan:t99")
        XCTAssertEqual(result.first?.serverId, "studio.lan")
        XCTAssertEqual(result.first?.threadId, "t99")
    }

    // MARK: - Factories

    private func makeSummary(
        serverId: String,
        threadId: String,
        updatedAt: Int64?,
        hasActiveTurn: Bool,
        title: String = "",
        lastToolLabel: String? = nil,
        lastResponsePreview: String? = nil,
        lastUserMessage: String? = nil,
        preview: String = "",
        serverDisplayName: String = "Test Server"
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            agentRuntimeKind: .codex,
            serverDisplayName: serverDisplayName,
            serverHost: "\(serverId).local",
            title: title,
            preview: preview,
            cwd: "/tmp",
            model: "",
            modelProvider: "",
            parentThreadId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: updatedAt,
            hasActiveTurn: hasActiveTurn,
            isResumed: false,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: lastResponsePreview,
            lastResponseTurnId: nil,
            lastUserMessage: lastUserMessage,
            lastToolLabel: lastToolLabel,
            recentToolLog: [],
            lastTurnStartMs: nil,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil
        )
    }

    private func makePendingApproval(
        id: String,
        threadId: String?,
        kind: ApprovalKind,
        command: String? = nil,
        path: String? = nil,
        grantRoot: String? = nil,
        cwd: String? = nil,
        reason: String? = nil
    ) -> PendingApproval {
        PendingApproval(
            id: id,
            serverId: "srv",
            kind: kind,
            threadId: threadId,
            turnId: nil,
            itemId: nil,
            command: command,
            path: path,
            grantRoot: grantRoot,
            cwd: cwd,
            reason: reason
        )
    }

    private func makeThread(
        serverId: String,
        threadId: String,
        items: [HydratedConversationItem]
    ) -> AppThreadSnapshot {
        AppThreadSnapshot(
            key: ThreadKey(serverId: serverId, threadId: threadId),
            info: ThreadInfo(
                id: threadId,
                title: nil,
                model: nil,
                status: .idle,
                preview: nil,
                cwd: nil,
                path: nil,
                modelProvider: nil,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: nil
            ),
            agentRuntimeKind: .codex,
            collaborationMode: .default,
            model: nil,
            reasoningEffort: nil,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: items,
            queuedFollowUps: [],
            activeTurnId: nil,
            activePlanProgress: nil,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: nil,
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil,
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
    }

    private func makeUserItem(id: String, text: String) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .user(HydratedUserMessageData(text: text, imageDataUris: [])),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeAssistantItem(id: String, text: String) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .assistant(HydratedAssistantMessageData(
                text: text,
                agentNickname: nil,
                agentRole: nil,
                phase: nil
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeCommandItem(
        id: String,
        command: String,
        status: AppOperationStatus
    ) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .commandExecution(HydratedCommandExecutionData(
                command: command,
                cwd: "/tmp",
                status: status,
                output: nil,
                exitCode: nil,
                durationMs: nil,
                processId: nil,
                actions: []
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeFileChangeItem(
        id: String,
        path: String,
        kind: String,
        status: AppOperationStatus
    ) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .fileChange(HydratedFileChangeData(
                status: status,
                changes: [HydratedFileChangeEntryData(
                    path: path,
                    kind: kind,
                    diff: "",
                    additions: 0,
                    deletions: 0
                )]
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeWebSearchItem(
        id: String,
        query: String,
        isInProgress: Bool
    ) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .webSearch(HydratedWebSearchData(
                query: query,
                actionJson: nil,
                isInProgress: isInProgress
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeMcpItem(
        id: String,
        tool: String,
        contentSummary: String?,
        status: AppOperationStatus
    ) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .mcpToolCall(HydratedMcpToolCallData(
                server: "srv",
                tool: tool,
                status: status,
                durationMs: nil,
                argumentsJson: nil,
                contentSummary: contentSummary,
                structuredContentJson: nil,
                rawOutputJson: nil,
                errorMessage: nil,
                progressMessages: [],
                computerUse: nil
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }

    private func makeSnapshot(voiceSession: AppVoiceSessionSnapshot) -> AppSnapshotRecord {
        AppSnapshotRecord(
            servers: [],
            threads: [],
            sessionSummaries: [],
            agentDirectoryVersion: 0,
            activeThread: nil,
            pendingApprovals: [],
            pendingUserInputs: [],
            voiceSession: voiceSession
        )
    }

    private func makeDynamicItem(
        id: String,
        tool: String,
        contentSummary: String?,
        status: AppOperationStatus
    ) -> HydratedConversationItem {
        HydratedConversationItem(
            id: id,
            content: .dynamicToolCall(HydratedDynamicToolCallData(
                tool: tool,
                status: status,
                durationMs: nil,
                success: nil,
                argumentsJson: nil,
                contentSummary: contentSummary
            )),
            sourceTurnId: nil,
            sourceTurnIndex: nil,
            timestamp: nil,
            isFromUserTurnBoundary: false
        )
    }
}
