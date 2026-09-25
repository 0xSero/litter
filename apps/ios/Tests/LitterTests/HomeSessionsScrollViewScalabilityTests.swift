import XCTest
import UIKit
@testable import Litter

@MainActor
final class HomeSessionsScrollViewScalabilityTests: XCTestCase {
    func testThousandSessionsMountOnlyViewportAndOverscan() async {
        let view = makeView()
        apply(sessions: sessions(count: 1_000), to: view)
        let scroll = scrollView(in: view)
        XCTAssertGreaterThan(mountedRows(in: scroll).count, 0)
        XCTAssertLessThan(mountedRows(in: scroll).count, 50)
        XCTAssertGreaterThan(scroll.contentSize.height, 50_000)

        weak var firstRow = mountedRows(in: scroll).first
        scroll.contentOffset.y = 27_000
        view.scrollViewDidScroll(scroll)
        // UIKit can retain rows until an in-flight layout animation completes.
        for _ in 0..<50 where firstRow != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(firstRow, "Offscreen hosting trees must be released")
        XCTAssertLessThan(mountedRows(in: scroll).count, 60)
        XCTAssertTrue(mountedRows(in: scroll).contains { $0.frame.contains(CGPoint(x: 100, y: 27_050)) })

        scroll.contentOffset.y = scroll.contentSize.height - scroll.bounds.height
        view.scrollViewDidScroll(scroll)
        XCTAssertLessThan(mountedRows(in: scroll).count, 50)
        XCTAssertEqual(mountedRows(in: scroll).map(\.frame.maxY).max(), scroll.contentSize.height)

        apply(sessions: [], to: view)
        XCTAssertTrue(mountedRows(in: scroll).isEmpty)
        XCTAssertEqual(scroll.contentSize.height, 0)
    }

    func testPageFitKeepsFullContentExtentWithBoundedMounts() {
        let view = makeView()
        apply(sessions: sessions(count: 1_000), to: view, zoom: 4)
        let scroll = scrollView(in: view)
        XCTAssertEqual(scroll.contentSize.height, 800_000, accuracy: 1)
        XCTAssertLessThanOrEqual(mountedRows(in: scroll).count, 3)
        scroll.contentOffset.y = 400_000
        view.scrollViewDidScroll(scroll)
        XCTAssertLessThanOrEqual(mountedRows(in: scroll).count, 3)
        XCTAssertTrue(mountedRows(in: scroll).contains { $0.frame.minY == 400_000 })
    }

    func testAllZoomLevelsKeepBoundedMountsAndReachFinalSession() {
        let view = makeView()
        let data = sessions(count: 1_000)
        let scroll = scrollView(in: view)
        for zoom in [1, 2, 3, 4, 2, 1] {
            apply(sessions: data, to: view, zoom: zoom)
            scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height)
            view.scrollViewDidScroll(scroll)
            XCTAssertGreaterThan(mountedRows(in: scroll).count, 0)
            XCTAssertLessThan(mountedRows(in: scroll).count, 100)
            XCTAssertEqual(mountedRows(in: scroll).map(\.frame.maxY).max(), scroll.contentSize.height)
        }
    }

    func testIdleRowsDoNotKeepPausedPinchAnimationsWhenMountedOrReattached() {
        let view = makeView()
        let window = UIWindow(frame: view.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        apply(sessions: sessions(count: 1_000), to: view)
        let scroll = scrollView(in: view)
        XCTAssertFalse(mountedRows(in: scroll).contains(where: \.debugHasActivePinchAnimator))

        // This path materializes rows outside apply(), the original leak path.
        scroll.contentOffset.y = 27_000
        view.scrollViewDidScroll(scroll)
        XCTAssertGreaterThan(mountedRows(in: scroll).count, 0)
        XCTAssertFalse(mountedRows(in: scroll).contains(where: \.debugHasActivePinchAnimator))

        view.removeFromSuperview()
        root.view.addSubview(view)
        NotificationCenter.default.post(name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        XCTAssertFalse(mountedRows(in: scroll).contains(where: \.debugHasActivePinchAnimator))
    }

    func testHeightComparisonDoesNotTraverseEverySiblingForEverySession() {
        let members = familyMembers()
        var updatedMembers = familyMembers() // Fresh buffer, as on each derivation.
        updatedMembers[999] = .init(key: members[999].key, title: "Renamed sibling")
        updatedMembers.swapAt(500, 501)
        let before = sessions(count: 1_000, members: members)
        let after = sessions(count: 1_000, members: updatedMembers)
        // Complete rendering state differs, but one-line horizontal pill
        // content/order cannot change the offscreen vertical measurements.
        XCTAssertNotEqual(before[900], after[900])
        for index in before.indices {
            XCTAssertTrue(HomeSessionViewport.hasSameHeightContent(before[index], after[index]))
        }
        XCTAssertFalse(HomeSessionViewport.hasSameHeightContent(nil, after[0]))
        XCTAssertFalse(HomeSessionViewport.hasSameHeightContent(before[0], sessions(count: 1_000, members: members, responseAt: [0: "Longer response"])[0]))
        XCTAssertFalse(HomeSessionViewport.hasSameHeightContent(before[1], sessions(count: 1_000, members: members, ancestorTitle: "Changed ancestor title")[1]))
        var sizingPillChanged = members
        sizingPillChanged[0] = .init(key: members[0].key, title: "Changed sizing pill")
        XCTAssertFalse(HomeSessionViewport.hasSameHeightContent(before[0], sessions(count: 1_000, members: sizingPillChanged)[0]))
    }

    func testMountedRowsRefreshSameCountSiblingTitlesAndOrder() {
        let view = makeView()
        let members = familyMembers()
        apply(sessions: sessions(count: 1_000, members: members), to: view)
        let row = mountedRows(in: scrollView(in: view)).first { $0.debugSession?.key == members[0].key }!
        let refreshes = row.debugRootViewRefreshCount
        var changed = familyMembers()
        changed[999] = .init(key: members[999].key, title: "Updated visible family")
        changed.swapAt(500, 501)
        apply(sessions: sessions(count: 1_000, members: changed), to: view)
        XCTAssertGreaterThan(row.debugRootViewRefreshCount, refreshes, "Height reuse must not suppress hosted content refresh")
        XCTAssertEqual(row.debugSession?.lineage?.members, changed)
    }

    func testOffscreenHeightSurvivesSiblingChangeButInvalidatesResponseChange() {
        let view = makeView()
        let members = familyMembers()
        apply(sessions: sessions(count: 1_000, members: members), to: view)
        let row = mountedRows(in: scrollView(in: view)).first { $0.debugSession?.key == members[0].key }!
        _ = row.forceMeasureHostHeight(width: 390)
        XCTAssertNotNil(row.cachedNaturalHeight(atZoom: 2, width: 390), "On-demand measurement must be reusable before an implicit layout pass")
        view.debugScroll(to: 900)
        XCTAssertTrue(view.debugHasMeasuredHeight(for: members[0].key))
        var changed = familyMembers()
        changed[999] = .init(key: members[999].key, title: "Different sibling")
        apply(sessions: sessions(count: 1_000, members: changed), to: view)
        XCTAssertTrue(view.debugHasMeasuredHeight(for: members[0].key))
        apply(sessions: sessions(count: 1_000, members: changed, responseAt: [0: "New multiline\nresponse"]), to: view)
        XCTAssertFalse(view.debugHasMeasuredHeight(for: members[0].key), "Offscreen content changes must discard its old measured height")
    }

    func testOnDemandMeasurementUpdatesCacheWidthBeforeImplicitLayout() {
        let view = makeView()
        apply(sessions: sessions(count: 1), to: view)
        let row = mountedRows(in: scrollView(in: view)).first!
        let original = row.forceMeasureHostHeight(width: 390)
        XCTAssertEqual(row.cachedNaturalHeight(atZoom: 2, width: 390), original)
        let resized = row.forceMeasureHostHeight(width: 280)
        XCTAssertNil(row.cachedNaturalHeight(atZoom: 2, width: 390))
        XCTAssertEqual(row.cachedNaturalHeight(atZoom: 2, width: 280), resized)
    }

    private func familyMembers() -> [ThreadLineageMember] {
        (0..<1_000).map { .init(key: ThreadKey(serverId: "scale-test", threadId: "session-\($0)"), title: "Sibling \($0)") }
    }

    func testInitialMountThousandSessionsPerformance() {
        let data = sessions(count: 1_000)
        measure {
            let view = makeView()
            apply(sessions: data, to: view)
            XCTAssertLessThan(mountedRows(in: scrollView(in: view)).count, 50)
        }
    }

    private func makeView() -> HomeSessionsScrollUIView {
        let view = HomeSessionsScrollUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        view.layoutIfNeeded()
        return view
    }

    private func scrollView(in view: HomeSessionsScrollUIView) -> UIScrollView {
        view.subviews.compactMap { $0 as? UIScrollView }.first!
    }

    private func mountedRows(in scroll: UIScrollView) -> [HomeRowContainer] {
        scroll.subviews.flatMap(\.subviews).compactMap { $0 as? HomeRowContainer }
    }

    private func apply(sessions: [HomeDashboardRecentSession], to view: HomeSessionsScrollUIView, zoom: Int = 2) {
        view.apply(
            sessions: sessions, pinnedThreadKeys: [], hydratingKeys: [], cancellingKeys: [],
            openingKey: nil, zoomLevel: zoom, showCatFooter: false, topInset: 0, bottomInset: 0,
            textScale: 1, themeManager: .shared, wallpaperManager: .shared,
            callbacks: .init(
                onOpen: { _ in }, onReply: { _ in }, onHide: { _ in }, onPin: { _ in },
                onUnpin: { _ in }, onCancelTurn: { _ in }, onDelete: { _ in },
                onFork: { _ in }, onShowPiP: { _ in }
            )
        )
    }

    private func sessions(count: Int, members: [ThreadLineageMember]? = nil, responseAt: [Int: String] = [:], ancestorTitle: String = "Root") -> [HomeDashboardRecentSession] {
        (0..<count).map { index in
            HomeDashboardRecentSession(
                key: ThreadKey(serverId: "scale-test", threadId: "session-\(index)"),
                serverId: "scale-test", serverDisplayName: "Scale test", agentRuntimeKind: .codex,
                isLocal: false, sessionTitle: "Session \(index)", preview: "Preview", cwd: "/tmp",
                model: "test", agentLabel: nil, updatedAt: Date(timeIntervalSince1970: 1_000),
                hasTurnActive: false, isResumed: false, isSubagent: false, isFork: false,
                forkedFromId: nil,
                lineage: members.map { family in
                    ThreadLineage(rootKey: family[0].key, parentKey: index == 0 ? nil : family[0].key,
                                  ancestors: index == 0 ? [] : [.init(key: family[0].key, title: ancestorTitle)],
                                  omittedAncestorCount: 0, members: family, branchIndex: index + 1, branchTotal: family.count)
                },
                lastResponsePreview: responseAt[index], lastResponseTurnId: nil,
                lastUserMessage: nil, lastToolLabel: nil, stats: nil, tokenUsage: nil, goal: nil,
                recentToolLog: [], lastTurnStart: nil, lastTurnEnd: nil
            )
        }
    }
}
