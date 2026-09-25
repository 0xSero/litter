import XCTest
@testable import Litter

@MainActor
final class SessionsDerivationTests: XCTestCase {
    func testSiblingsKeepServerScopeAndMostRecentOrder() {
        let sessions = [
            summary("parent"),
            summary("selected", parent: " parent ", updatedAt: 20),
            summary("older", parent: "parent", updatedAt: 10),
            summary("newer", parent: "parent", updatedAt: 30),
            summary("parent", server: "other"),
            summary("foreign", server: "other", parent: "parent", updatedAt: 40)
        ]
        let derived = build(sessions)
        XCTAssertEqual(derived.siblings(for: sessions[1].key).map(\.threadId), ["newer", "older"])
        XCTAssertTrue(derived.siblings(for: sessions[0].key).isEmpty)
        XCTAssertTrue(derived.siblings(for: sessions[5].key).isEmpty)
    }

    func testMissingParentDoesNotInventSiblingNavigation() {
        let sessions = [summary("one", parent: "missing"), summary("two", parent: "missing")]
        let derived = build(sessions)
        XCTAssertTrue(derived.siblings(for: sessions[0].key).isEmpty)
        XCTAssertEqual(derived.workspaceSections.first?.groups.first?.treeRoots.count, 2)
    }

    func testFilteredListRetainsNavigationToHiddenSiblings() {
        let sessions = [summary("parent"), summary("selected", parent: "parent"), summary("hidden", parent: "parent")]
        let derived = build(sessions, searchQuery: "selected")
        XCTAssertEqual(derived.filteredThreadKeys, [sessions[1].key])
        XCTAssertEqual(derived.siblings(for: sessions[1].key).map(\.threadId), ["hidden"])
    }

    func testLargeSiblingFamiliesRetainOnlyOneChildList() {
        for count in [100, 1_000] {
            let sessions = [summary("parent")] + (0..<count).map {
                summary("child-\($0)", parent: "parent", updatedAt: Int64($0))
            }
            let start = ContinuousClock.now
            let derived = build(sessions)
            let elapsed = start.duration(to: .now)
            XCTAssertEqual(derived.childrenByKey.values.reduce(0) { $0 + $1.count }, count)
            XCTAssertEqual(derived.siblings(for: sessions[1].key).count, count - 1)
            XCTAssertEqual(derived.allThreadKeys.count, count + 1)
            print("SessionsDerivation siblings=\(count) elapsed=\(elapsed) retainedChildEntries=\(count)")
        }
    }

    private func build(_ sessions: [AppSessionSummary], searchQuery: String = "") -> SessionsDerivedData {
        SessionsDerivation.build(
            sessions: sessions,
            selectedServerFilterId: nil,
            showOnlyForks: false,
            selectedRuntimeKind: nil,
            workspaceSortMode: .mostRecent,
            searchQuery: searchQuery,
            frozenMostRecentOrder: nil
        )
    }

    private func summary(
        _ id: String,
        server: String = "server",
        parent: String? = nil,
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
            parentThreadId: parent,
            forkedFromId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: updatedAt,
            hasActiveTurn: false,
            isResumed: false,
            isSubagent: parent != nil,
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
