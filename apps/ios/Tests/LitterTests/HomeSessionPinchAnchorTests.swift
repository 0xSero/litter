import XCTest
import CoreGraphics
@testable import Litter

final class HomeSessionPinchAnchorTests: XCTestCase {
    func testDeepPinchUsesCommittedPageGeometryForTheSameRow() {
        let naturalFrames = frames(height: 400)
        let pageFrames = frames(height: 700)
        let naturalOffset = HomeSessionViewport.pinchOffset(
            in: naturalFrames, index: 900, fraction: 0.4,
            viewportY: 300, topInset: 20, pageFit: false
        )!
        let pageOffset = HomeSessionViewport.pinchOffset(
            in: pageFrames, index: 900, fraction: 0.4,
            viewportY: 300, topInset: 20, pageFit: true
        )!
        // Leaving the old offset would show row 514 instead of row 900.
        XCTAssertEqual(HomeSessionViewport.anchor(in: pageFrames, at: naturalOffset + 20)?.0, 514)
        XCTAssertEqual(pageOffset, 900 * 700 - 20)
        XCTAssertEqual(HomeSessionViewport.anchor(in: pageFrames, at: pageOffset + 20)?.0, 900)
    }

    func testFinalPageSnapKeepsChosenRowAcrossFingerPositions() {
        let pageFrames = frames(height: 700)
        for viewportY: CGFloat in [0, 200, 650] {
            for fraction: CGFloat in [0, 0.5, 1] {
                XCTAssertEqual(HomeSessionViewport.pinchOffset(
                    in: pageFrames, index: 900, fraction: fraction,
                    viewportY: viewportY, topInset: 20, pageFit: true
                ), 900 * 700 - 20)
            }
        }
        XCTAssertNil(HomeSessionViewport.pinchOffset(
            in: [], index: 0, fraction: 0, viewportY: 0, topInset: 0, pageFit: true
        ))
    }

    func testOffscreenHeightInvalidationPreservesDeepRowAndPixelOffset() {
        let keys = (0..<1_000).map { ThreadKey(serverId: "server", threadId: "session-\($0)") }
        let before = frames(height: 150)
        let after = frames(height: 140)
        let originalY: CGFloat = 900 * 150 + 12
        let anchor = HomeSessionViewport.scrollAnchor(in: before, keys: keys, at: originalY)!
        let indices = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        let corrected = HomeSessionViewport.contentY(for: anchor, in: after, indices: indices)!
        XCTAssertEqual(HomeSessionViewport.anchor(in: after, at: originalY)?.0, 964)
        XCTAssertEqual(corrected, 900 * 140 + 12)
        XCTAssertEqual(HomeSessionViewport.anchor(in: after, at: corrected)?.0, 900)
    }

    func testInsertionAndReorderingPreserveStableKeyWhileTopStaysUnanchored() {
        let keys = (0..<1_000).map { ThreadKey(serverId: "server", threadId: "session-\($0)") }
        let initial = frames(height: 150)
        let anchor = HomeSessionViewport.scrollAnchor(in: initial, keys: keys, at: 900 * 150 + 12)!
        let insertedKeys = [ThreadKey(serverId: "server", threadId: "new")] + keys
        let insertedFrames = (0..<insertedKeys.count).map {
            CGRect(x: 0, y: CGFloat($0) * 150, width: 390, height: 150)
        }
        let indices = Dictionary(uniqueKeysWithValues: insertedKeys.enumerated().map { ($1, $0) })
        XCTAssertEqual(HomeSessionViewport.contentY(for: anchor, in: insertedFrames, indices: indices), 901 * 150 + 12)
        XCTAssertNil(HomeSessionViewport.scrollAnchor(in: initial, keys: keys, at: 0))
        XCTAssertNil(HomeSessionViewport.scrollAnchor(in: initial, keys: keys, at: -20))
        XCTAssertNil(HomeSessionViewport.contentY(for: anchor, in: initial, indices: [:]))

        // The same key lookup is used by the active pinch when new sessions arrive.
        let movedIndex = indices[anchor.key]!
        XCTAssertEqual(HomeSessionViewport.pinchOffset(
            in: insertedFrames, index: movedIndex, fraction: 0.5,
            viewportY: 300, topInset: 0, pageFit: true
        ), 901 * 150)
    }

    private func frames(height: CGFloat) -> [CGRect] {
        (0..<1_000).map { CGRect(x: 0, y: CGFloat($0) * height, width: 390, height: height) }
    }
}
