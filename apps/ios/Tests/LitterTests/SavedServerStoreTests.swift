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

    func testOnlyKittylitterAndDirectURLComputersSyncAcrossDevices() {
        XCTAssertTrue(SavedServerStore.isCloudSyncable(alleycatServer(id: "alleycat:node-a", nodeId: "node-a")))
        XCTAssertTrue(SavedServerStore.isCloudSyncable(server(id: "manual-ws", websocketURL: "wss://box.example:8390")))

        // Local Studio grants are bound to one device's key.
        XCTAssertFalse(SavedServerStore.isCloudSyncable(
            alleycatServer(id: "alleycat:local-studio:node-a", nodeId: "node-a")
        ))
        // SSH keys never leave the device.
        XCTAssertFalse(SavedServerStore.isCloudSyncable(server(id: "ssh-box", source: .ssh)))
        XCTAssertFalse(SavedServerStore.isCloudSyncable(server(id: "manual-ssh-box:22", mode: .ssh)))
        // ChatGPT-connected computers need that device's own sign-in.
        XCTAssertFalse(SavedServerStore.isCloudSyncable(server(id: "slingshot-env", websocketURL: "wss://chatgpt.com/x")))
        // This device, and computers the user never chose to keep.
        XCTAssertFalse(SavedServerStore.isCloudSyncable(server(id: "local", source: .local)))
        XCTAssertFalse(SavedServerStore.isCloudSyncable(server(id: "manual-ws", remembered: false)))
    }

    private func server(
        id: String,
        source: ServerSource = .manual,
        mode: PreferredConnectionMode? = .directCodex,
        websocketURL: String? = nil,
        remembered: Bool = true
    ) -> SavedServer {
        SavedServer(
            id: id,
            name: id,
            hostname: "box.example",
            port: 8390,
            codexPorts: [],
            sshPort: nil,
            source: source,
            hasCodexServer: true,
            wakeMAC: nil,
            preferredConnectionMode: mode,
            preferredCodexPort: nil,
            sshPortForwardingEnabled: nil,
            websocketURL: websocketURL,
            rememberedByUser: remembered
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
