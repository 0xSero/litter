import XCTest
@testable import Litter

final class SnapshotRefreshFenceTests: XCTestCase {
    func testOverlappingRefreshCannotPublishAfterNewerRequest() {
        var fence = SnapshotRefreshFence()
        let older = fence.begin()!
        let newer = fence.begin()!
        XCTAssertEqual(fence.disposition(of: older), .superseded)
        XCTAssertEqual(fence.disposition(of: newer), .apply)
    }

    func testQueuedEventInvalidatesCaptureBeforeProjectionFlush() {
        var fence = SnapshotRefreshFence()
        let capture = fence.begin()!
        // Incoming events invalidate immediately, even when the UI batches them.
        fence.invalidate()
        XCTAssertEqual(fence.disposition(of: capture), .retry)
        // A later local write still rejects the same capture.
        fence.invalidate()
        XCTAssertEqual(fence.disposition(of: capture), .retry)
    }

    func testCaptureAfterBurstCanPublish() {
        var fence = SnapshotRefreshFence()
        let stale = fence.begin()!
        for _ in 0..<100 { fence.invalidate() }
        XCTAssertEqual(fence.disposition(of: stale), .retry)
        let trailing = fence.begin()!
        XCTAssertEqual(fence.disposition(of: stale), .superseded)
        XCTAssertEqual(fence.disposition(of: trailing), .apply)
    }

    func testStopAndRestartNeverRevivesOldCaptureOrRetry() {
        var fence = SnapshotRefreshFence()
        let old = fence.begin()!
        fence.stop()
        XCTAssertNil(fence.begin())
        XCTAssertEqual(fence.disposition(of: old), .superseded)
        fence.start()
        XCTAssertEqual(fence.disposition(of: old), .superseded)
        let current = fence.begin()!
        XCTAssertEqual(fence.disposition(of: current), .apply)
    }
}
