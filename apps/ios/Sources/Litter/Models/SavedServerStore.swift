import Foundation
import UIKit

extension Notification.Name {
    static let litterSavedServersDidChange = Notification.Name("litterSavedServersDidChange")
}

@MainActor
enum SavedServerStore {
    private static let savedServersKey = "codex_saved_servers"

    static func save(_ servers: [SavedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: savedServersKey)
        NotificationCenter.default.post(name: .litterSavedServersDidChange, object: nil)
    }

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        let decoded = (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
        let migrated = decoded.map { saved -> SavedServer in
            let server = saved.toDiscoveredServer()
            let restored = SavedServer
                .from(server, rememberedByUser: saved.rememberedByUser)
                .withAlleycatHost(saved.alleycatHost)
                .withAlleycat(
                    nodeId: saved.alleycatNodeId,
                    relay: saved.alleycatRelay,
                    agentName: saved.alleycatAgentName,
                    agentWire: saved.alleycatAgentWire
                )
            if shouldReplaceLegacyLocalPlaceholder(restored) {
                return restored.withName(LitterPlatform.localRuntimeDisplayName())
            }
            if shouldReplaceLegacyAlleycatPlaceholder(restored) {
                return restored.withName(alleycatFallbackDisplayName(restored))
            }
            return restored
        }
        if migrated != decoded {
            save(migrated)
        }
        return migrated
    }

    static func upsert(_ server: DiscoveredServer) {
        var saved = load()
        let existing = existingMatch(for: server, in: saved)
        saved.removeAll { entry in matches(server, entry) }
        saved.append(
            SavedServer.from(
                server,
                rememberedByUser: existing?.rememberedByUser ?? false
            )
        )
        save(saved)
    }

    static func remember(_ server: DiscoveredServer) {
        var saved = load()
        saved.removeAll { entry in matches(server, entry) }
        saved.append(SavedServer.from(server, rememberedByUser: true))
        save(saved)
    }

    static func rememberAlleycat(
        _ server: DiscoveredServer,
        nodeId: String,
        relay: String?,
        agentName: String,
        agentWire: String
    ) {
        var saved = load()
        saved.removeAll { entry in matches(server, entry) }
        saved.append(
            SavedServer
                .from(server, rememberedByUser: true)
                .withAlleycat(
                    nodeId: nodeId,
                    relay: relay,
                    agentName: agentName,
                    agentWire: agentWire
                )
        )
        save(saved)
    }

    static func rememberSSHBridge(_ server: DiscoveredServer, runtimeKinds: [AgentRuntimeKind]) {
        var saved = load()
        saved.removeAll { entry in matches(server, entry) }
        saved.append(
            SavedServer
                .from(server, rememberedByUser: true)
                .withSSHBridge(runtimeKinds: runtimeKinds)
        )
        save(saved)
    }

    static func rememberedServers() -> [SavedServer] {
        load().filter(\.rememberedByUser)
    }

    static func reconnectRecords(
        localDisplayName: String,
        rememberedOnly: Bool = false
    ) -> [SavedServerRecord] {
        let saved = rememberedOnly ? rememberedServers() : load()
        var records = saved.map { $0.toRecord() }
        if LitterPlatform.supportsLocalRuntime,
           records.contains(where: { $0.id == "local" || $0.source == ServerSource.local.rawValue }) == false {
            records.append(
                SavedServerRecord(
                    id: "local",
                    name: localDisplayName,
                    hostname: "127.0.0.1",
                    port: 0,
                    codexPorts: [],
                    sshPort: nil,
                    source: ServerSource.local.rawValue,
                    hasCodexServer: true,
                    wakeMac: nil,
                    preferredConnectionMode: nil,
                    preferredCodexPort: nil,
                    sshPortForwardingEnabled: nil,
                    websocketUrl: nil,
                    rememberedByUser: true,
                    alleycatHost: nil,
                    alleycatUdpPort: nil,
                    alleycatNodeId: nil,
                    alleycatToken: nil,
                    alleycatRelay: nil,
                    alleycatAgentName: nil,
                    alleycatAgentWire: nil
                )
            )
        }
        return records
    }

    static func remove(serverId: String) {
        let saved = load()
        let nodeIdsToForget = orphanedAlleycatNodeIds(removing: serverId, from: saved)
        let remaining = saved.filter { $0.id != serverId }
        save(remaining)

        for nodeId in nodeIdsToForget {
            do {
                try AlleycatCredentialStore.shared.deleteToken(nodeId: nodeId)
            } catch {
                LLog.error("alleycat", "keychain token deletion failed while forgetting server", error: error)
            }
        }
    }

    /// An Alleycat token is keyed by node ID, so retain it when another saved
    /// server still refers to the same node. The installation-wide device key
    /// is deliberately not part of this server-scoped cleanup.
    static func orphanedAlleycatNodeIds(removing serverId: String, from servers: [SavedServer]) -> [String] {
        let removedNodeIds = Set(
            servers
                .filter { $0.id == serverId }
                .compactMap { normalizedAlleycatNodeId($0.alleycatNodeId) }
        )
        guard !removedNodeIds.isEmpty else { return [] }

        let retainedNodeIds = Set(
            servers
                .filter { $0.id != serverId }
                .compactMap { normalizedAlleycatNodeId($0.alleycatNodeId) }
        )
        return removedNodeIds.subtracting(retainedNodeIds).sorted()
    }

    static func rename(serverId: String, newName: String) {
        var saved = load()
        guard let index = saved.firstIndex(where: { $0.id == serverId }) else { return }
        let old = saved[index]
        saved[index] = SavedServer(
            id: old.id,
            name: newName,
            hostname: old.hostname,
            port: old.port,
            codexPorts: old.codexPorts,
            sshPort: old.sshPort,
            source: old.source,
            hasCodexServer: old.hasCodexServer,
            wakeMAC: old.wakeMAC,
            preferredConnectionMode: old.preferredConnectionMode,
            preferredCodexPort: old.preferredCodexPort,
            sshPortForwardingEnabled: old.sshPortForwardingEnabled,
            websocketURL: old.websocketURL,
            rememberedByUser: old.rememberedByUser,
            alleycatHost: old.alleycatHost,
            alleycatNodeId: old.alleycatNodeId,
            alleycatRelay: old.alleycatRelay,
            alleycatAgentName: old.alleycatAgentName,
            alleycatAgentWire: old.alleycatAgentWire
        )
        save(saved)
    }

    static func updateWakeMAC(serverId: String, host: String, wakeMAC: String?) {
        guard let normalizedWakeMAC = DiscoveredServer.normalizeWakeMAC(wakeMAC) else { return }

        var saved = load()
        guard let index = saved.firstIndex(where: { entry in
            entry.id == serverId || normalizedHost(entry.hostname) == normalizedHost(host)
        }) else {
            return
        }

        let existing = saved[index]
        guard existing.wakeMAC != normalizedWakeMAC else { return }

        saved[index] = SavedServer(
            id: existing.id,
            name: existing.name,
            hostname: existing.hostname,
            port: existing.port,
            codexPorts: existing.codexPorts,
            sshPort: existing.sshPort,
            source: existing.source,
            hasCodexServer: existing.hasCodexServer,
            wakeMAC: normalizedWakeMAC,
            preferredConnectionMode: existing.preferredConnectionMode,
            preferredCodexPort: existing.preferredCodexPort,
            sshPortForwardingEnabled: existing.sshPortForwardingEnabled,
            websocketURL: existing.websocketURL,
            rememberedByUser: existing.rememberedByUser,
            alleycatHost: existing.alleycatHost,
            alleycatNodeId: existing.alleycatNodeId,
            alleycatRelay: existing.alleycatRelay,
            alleycatAgentName: existing.alleycatAgentName,
            alleycatAgentWire: existing.alleycatAgentWire
        )
        save(saved)
    }

    private static func existingMatch(for server: DiscoveredServer, in saved: [SavedServer]) -> SavedServer? {
        saved.first { matches(server, $0) }
    }

    private static func matches(_ server: DiscoveredServer, _ savedServer: SavedServer) -> Bool {
        savedServer.id == server.id || savedServer.toDiscoveredServer().deduplicationKey == server.deduplicationKey
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")

        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        return normalized.lowercased()
    }

    private static func shouldReplaceLegacyLocalPlaceholder(_ server: SavedServer) -> Bool {
        server.source == .local
            && server.name.trimmingCharacters(in: .whitespacesAndNewlines) == "This Device"
    }

    private static func shouldReplaceLegacyAlleycatPlaceholder(_ server: SavedServer) -> Bool {
        guard server.alleycatNodeId != nil else { return false }
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.caseInsensitiveCompare("Alleycat Host") == .orderedSame
    }

    private static func alleycatFallbackDisplayName(_ server: SavedServer) -> String {
        guard let nodeId = server.alleycatNodeId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nodeId.isEmpty else {
            return "Alleycat"
        }
        if nodeId.count <= 16 {
            return "Alleycat \(nodeId)"
        }
        return "Alleycat \(nodeId.prefix(8))...\(nodeId.suffix(8))"
    }

    private static func normalizedAlleycatNodeId(_ nodeId: String?) -> String? {
        let normalized = nodeId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }
}
