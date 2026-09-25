import XCTest
import SwiftUI
import UIKit
@testable import Litter

@MainActor
final class ThreadLineageScalabilityTests: XCTestCase {
    func testOrdinaryPathsPreserveEveryAncestorAndBranchOrdering() {
        let sessions = (0..<5).map { summary("\($0)", parent: $0 == 0 ? nil : "\($0 - 1)", updatedAt: Int64($0)) }
        let map = ThreadLineageMap.compute(sessions: Array(sessions.reversed()))
        let last = map[sessions[4].key]!
        XCTAssertEqual(last.ancestors.map(\.key.threadId), ["0", "1", "2", "3"])
        XCTAssertEqual(last.omittedAncestorCount, 0)
        XCTAssertEqual(last.parentKey, sessions[3].key)
        XCTAssertEqual(last.rootKey, sessions[0].key)
        XCTAssertEqual(last.members.map(\.key.threadId), ["4", "3", "2", "1", "0"])
        XCTAssertEqual(last.branchIndex, 1)
    }

    func testThousandDeepForksKeepBoundedBreadcrumbsAndCompleteMembership() {
        let sessions = (0..<1_000).map { summary("\($0)", parent: $0 == 0 ? nil : "\($0 - 1)", updatedAt: Int64($0)) }
        let map = ThreadLineageMap.compute(sessions: Array(sessions.reversed()))
        XCTAssertEqual(map.count, 1_000)
        XCTAssertEqual(map.values.reduce(0) { $0 + $1.ancestors.count }, 3_990)
        let last = map[sessions[999].key]!
        XCTAssertEqual(last.ancestors.map(\.key.threadId), ["0", "996", "997", "998"])
        XCTAssertEqual(last.omittedAncestorCount, 995)
        XCTAssertEqual(last.branchTotal, 1_000)
        XCTAssertEqual(Set(last.members.map(\.key)).count, 1_000)
        // Value arrays share one family buffer instead of copying 1,000 members
        // for each branch. Breadcrumb arrays themselves have at most four entries.
        last.members.withUnsafeBufferPointer { shared in
            for lineage in map.values {
                lineage.members.withUnsafeBufferPointer { XCTAssertEqual($0.baseAddress, shared.baseAddress) }
            }
        }
    }

    func testThousandWideForksKeepEveryBranch() {
        let sessions = [summary("root")] + (1..<1_000).map { summary("\($0)", parent: "root") }
        let map = ThreadLineageMap.compute(sessions: sessions)
        XCTAssertEqual(map.values.reduce(0) { $0 + $1.ancestors.count }, 999)
        XCTAssertTrue(map.values.allSatisfy { $0.branchTotal == 1_000 && $0.omittedAncestorCount == 0 })
    }

    func testMissingParentsStayServerScopedAndSubagentsDoNotJoinForks() {
        let sessions = [summary("a", parent: "missing"), summary("b", parent: " missing "),
                        summary("a", server: "other", parent: "missing"), summary("agent", subagentParent: "a")]
        let map = ThreadLineageMap.compute(sessions: sessions)
        XCTAssertEqual(map[sessions[0].key]?.rootKey, ThreadKey(serverId: "server", threadId: "missing"))
        XCTAssertEqual(map[sessions[0].key]?.branchTotal, 2)
        XCTAssertEqual(map[sessions[2].key]?.branchTotal, 1)
        XCTAssertTrue(map[sessions[0].key]!.ancestors.isEmpty)
        XCTAssertEqual(map[sessions[3].key]?.rootKey, sessions[3].key)
    }

    func testMalformedCyclesHaveDeterministicRootWithoutCyclicBreadcrumbs() {
        let sessions = [summary("b", parent: "a"), summary("a", parent: "b"), summary("child", parent: "b"), summary("self", parent: "self")]
        let map = ThreadLineageMap.compute(sessions: sessions)
        let reversed = ThreadLineageMap.compute(sessions: Array(sessions.reversed()))
        for key in [sessions[0].key, sessions[1].key, sessions[2].key] {
            XCTAssertEqual(map[key]?.rootKey.threadId, "a")
            XCTAssertEqual(map[key]?.rootKey, reversed[key]?.rootKey)
            XCTAssertEqual(map[key]?.branchTotal, 3)
        }
        XCTAssertTrue(map[sessions[0].key]!.ancestors.isEmpty)
        XCTAssertTrue(map[sessions[1].key]!.ancestors.isEmpty)
        XCTAssertEqual(map[sessions[2].key]?.ancestors.map(\.key.threadId), ["b"])
        XCTAssertTrue(map[sessions[3].key]!.ancestors.isEmpty)
    }

    func testThousandSiblingPillsHaveBoundedZoomFourRowHeight() {
        let members = (0..<1_000).map { ThreadLineageMember(key: ThreadKey(serverId: "server", threadId: "\($0)"), title: "Branch \($0)") }
        let lineage = ThreadLineage(rootKey: members[0].key, parentKey: nil, ancestors: [], omittedAncestorCount: 0,
                                    members: members, branchIndex: 1, branchTotal: members.count)
        let session = HomeDashboardRecentSession(
            key: members[0].key, serverId: "server", serverDisplayName: "Fixture", agentRuntimeKind: .codex,
            isLocal: false, sessionTitle: "Fixture", preview: "", cwd: "/fixtures", model: "fixture", agentLabel: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000), hasTurnActive: false, isResumed: false,
            isSubagent: false, isFork: false, forkedFromId: nil, lineage: lineage,
            lastResponsePreview: nil, lastResponseTurnId: nil, lastUserMessage: nil, lastToolLabel: nil,
            stats: nil, tokenUsage: nil, goal: nil, recentToolLog: [], lastTurnStart: nil, lastTurnEnd: nil
        )
        let host = UIHostingController(rootView: SessionCanvasLine(session: session, isOpening: false, isHydrating: false, isCancelling: false, zoomLevel: 4))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let height = host.sizeThatFits(in: CGSize(width: 390, height: 10_000)).height
        XCTAssertGreaterThan(height, 20)
        XCTAssertLessThan(height, 600, "Lazy horizontal siblings must use pill height, not expand the vertically measured row")
    }

    private func summary(
        _ id: String,
        server: String = "server",
        parent: String? = nil,
        subagentParent: String? = nil,
        updatedAt: Int64 = 0
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: ThreadKey(serverId: server, threadId: id),
            agentRuntimeKind: .codex,
            serverDisplayName: server,
            serverHost: "\(server).local",
            title: id,
            preview: "",
            cwd: "/workspace",
            model: "",
            modelProvider: "",
            parentThreadId: subagentParent,
            forkedFromId: parent,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: updatedAt,
            hasActiveTurn: false,
            isResumed: false,
            isSubagent: subagentParent != nil,
            isFork: parent != nil,
            lastResponsePreview: nil,
            lastResponseTurnId: nil,
            lastUserMessage: nil,
            lastToolLabel: nil,
            recentToolLog: [],
            lastTurnStartMs: nil,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil,
            goal: nil
        )
    }
}
