import XCTest
import HairballUI
@testable import Litter

@MainActor
final class StreamingRendererCoordinatorTests: XCTestCase {
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
