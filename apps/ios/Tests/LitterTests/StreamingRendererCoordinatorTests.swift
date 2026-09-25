import XCTest
import HairballUI
@testable import Litter

@MainActor
final class StreamingRendererCoordinatorTests: XCTestCase {
    func testAuthoritativeSnapshotFillsUnreadDeltaWithoutResettingRenderer() {
        let coordinator = StreamingRendererCoordinator()
        let renderer = coordinator.renderer(for: "assistant", currentText: "A")
        coordinator.synchronizeAuthoritativeText("AB", for: "assistant", revision: 20)
        coordinator.appendDelta("B", for: "assistant", revision: 20)
        XCTAssertEqual(renderer.rawText, "AB")
        XCTAssertTrue(coordinator.existingRenderer(for: "assistant") === renderer)
        coordinator.appendDelta("C", for: "assistant", revision: 21)
        coordinator.synchronizeAuthoritativeText("AB", for: "assistant", revision: 20)
        XCTAssertEqual(renderer.rawText, "ABC", "Older snapshots cannot rewind already delivered chunks")
        coordinator.synchronizeAuthoritativeText("Replacement", for: "assistant", revision: 22)
        XCTAssertEqual(renderer.rawText, "Replacement")
        coordinator.finishActive()
        let next = coordinator.renderer(for: "assistant", currentText: "New")
        coordinator.appendDelta(" turn", for: "assistant", revision: 1)
        XCTAssertEqual(next.rawText, "New turn", "Teardown must discard renderer revision ownership")
        coordinator.reset()
    }

    func testFinishedTurnReleasesCoordinatorOwnershipButPreservesMountedBubble() {
        let coordinator = StreamingRendererCoordinator()
        var mountedRenderer: StreamingMarkdownRenderer? = coordinator.renderer(
            for: "assistant", currentText: "First"
        )
        weak var releasedRenderer = mountedRenderer
        coordinator.appendDelta(" second", for: "assistant")
        coordinator.finishActive()

        XCTAssertFalse(coordinator.hasRenderer(for: "assistant"))
        XCTAssertTrue(mountedRenderer?.isFinished == true)
        XCTAssertEqual(mountedRenderer?.rawText, "First second")
        XCTAssertGreaterThan(mountedRenderer?.blockCount ?? 0, 0)
        mountedRenderer = nil
        XCTAssertNil(releasedRenderer)
    }

    func testRepeatedTurnsDoNotRetainCompletedRenderers() {
        let coordinator = StreamingRendererCoordinator()
        for turn in 0..<100 {
            let itemID = "assistant-\(turn)"
            weak var renderer = coordinator.renderer(for: itemID, currentText: "Turn \(turn)")
            XCTAssertNotNil(renderer)
            coordinator.finishActive()
            XCTAssertFalse(coordinator.hasRenderer(for: itemID))
            XCTAssertNil(renderer, "Completed renderer remained retained after turn \(turn)")
        }
        let next = coordinator.renderer(for: "next", currentText: "New turn")
        XCTAssertFalse(next.isFinished)
        coordinator.appendDelta(" continues", for: "next")
        XCTAssertEqual(next.rawText, "New turn continues")
        coordinator.reset()
        XCTAssertTrue(next.isFinished)
        XCTAssertFalse(coordinator.hasRenderer(for: "next"))
    }
}
