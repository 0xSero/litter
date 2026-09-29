import XCTest
@testable import Litter

@MainActor
final class SavedServerStoreTests: XCTestCase {
    func testForgettingAlleycatServerReturnsOnlyUnreferencedNodeToken() {
        let primary = alleycatServer(id: "primary", nodeId: " NODE-A ")
        let duplicate = alleycatServer(id: "duplicate", nodeId: "node-a")
        let independent = alleycatServer(id: "independent", nodeId: "node-b")

        XCTAssertEqual(
            SavedServerStore.orphanedAlleycatNodeIds(
                removing: primary.id,
                from: [primary, duplicate, independent]
            ),
            []
        )
        XCTAssertEqual(
            SavedServerStore.orphanedAlleycatNodeIds(
                removing: independent.id,
                from: [primary, duplicate, independent]
            ),
            ["node-b"]
        )
    }

    private func alleycatServer(id: String, nodeId: String) -> SavedServer {
        SavedServer(
            id: id,
            name: id,
            hostname: nodeId,
            port: nil,
            codexPorts: [],
            sshPort: nil,
            source: .manual,
            hasCodexServer: true,
            wakeMAC: nil,
            preferredConnectionMode: nil,
            preferredCodexPort: nil,
            sshPortForwardingEnabled: nil,
            websocketURL: nil,
            rememberedByUser: true,
            alleycatNodeId: nodeId
        )
    }
}
