import XCTest
@testable import Litter

final class AlleycatPairingModeTests: XCTestCase {
    func testLocalStudioModeIncludesOnlyLocalStudio() {
        XCTAssertTrue(AlleycatPairingMode.localStudio.includesAgent(named: "local-studio"))
        XCTAssertFalse(AlleycatPairingMode.localStudio.includesAgent(named: "codex"))
        XCTAssertFalse(AlleycatPairingMode.localStudio.includesAgent(named: "pi"))
    }

    func testKittyLitterModeIncludesEveryAgent() {
        XCTAssertTrue(AlleycatPairingMode.kittylitter.includesAgent(named: "local-studio"))
        XCTAssertTrue(AlleycatPairingMode.kittylitter.includesAgent(named: "codex"))
        XCTAssertTrue(AlleycatPairingMode.kittylitter.includesAgent(named: "pi"))
    }
}
