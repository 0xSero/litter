import XCTest
@testable import Litter

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testSubscriptionCancellationWakesPendingSwiftBridgeCall() async {
        let store = AppStore()
        defer { withExtendedLifetime(store) {} }
        let subscription = store.subscribeUpdates()
        var receiveEnded = false
        let completed = expectation(description: "Pending subscription receive ended")
        let reader = Task {
            defer { receiveEnded = true }
            do {
                while !Task.isCancelled {
                    _ = try await subscription.nextUpdate()
                }
                XCTFail("The explicit subscription cancellation must end the receive")
            } catch {
                completed.fulfill()
            }
        }
        await Task.yield()
        XCTAssertFalse(receiveEnded, "The store must remain open until explicit cancellation")
        subscription.cancel()
        await fulfillment(of: [completed], timeout: 2)
        reader.cancel()
    }

    func testIdleSubscriptionDoesNotKeepModelAlive() async throws {
        var model: AppModel? = AppModel()
        model?.start()
        // The initial snapshot proves that the task has started before the
        // last owner goes away. No server connection or socket is required.
        for _ in 0..<200 where model?.snapshot == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model?.snapshot)
        weak var releasedModel = model
        model = nil
        for _ in 0..<200 where releasedModel != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(releasedModel, "An idle update task must not retain its owning model")
        // Clean up if the regression returns, so a failing test does not
        // leave another live subscription behind for subsequent tests.
        releasedModel?.stop()
    }
}
