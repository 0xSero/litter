import XCTest
@testable import Litter

final class AppThreadLaunchSelectionTests: XCTestCase {
    func testRuntimeOnlySelectionPreservesExplicitRuntime() {
        let selection = AppThreadLaunchSelection(
            agentRuntimeKind: .opencode,
            model: nil
        )

        XCTAssertEqual(selection.agentRuntimeKind, .opencode)
        XCTAssertNil(selection.model)
    }

    func testSelectionNormalizesModelWithoutChangingRuntime() {
        let selection = AppThreadLaunchSelection(
            agentRuntimeKind: .localStudio,
            model: "  local/model  "
        )

        XCTAssertEqual(selection.agentRuntimeKind, .localStudio)
        XCTAssertEqual(selection.model, "local/model")
    }

    func testWhitespaceOnlyModelDoesNotDiscardRuntime() {
        let selection = AppThreadLaunchSelection(
            agentRuntimeKind: .opencode,
            model: "  \n "
        )

        XCTAssertEqual(selection.agentRuntimeKind, .opencode)
        XCTAssertNil(selection.model)
    }
}
