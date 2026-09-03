import Foundation
import SwiftUI

/// Lightweight projection of a thread for use in lineage breadcrumbs and
/// sibling pills. Carries the resolved title so render-time code doesn't need
/// to look up the underlying `AppSessionSummary` again.
struct ThreadLineageMember: Equatable, Hashable {
    let key: ThreadKey
    let title: String
}

/// Fork lineage info for a single thread. Computed once per
/// `HomeDashboardSupport.recentConnectedSessions` pass over the snapshot's
/// session summaries by walking `parentThreadId` within a server. Only attached
/// to a session when the lineage actually has more than one member — singletons
/// don't need the structure at the render layer.
struct ThreadLineage: Equatable, Hashable {
    /// Top of the chain. Equals `self.key` when this thread is itself the root.
    let rootKey: ThreadKey
    /// Immediate parent (nil if this thread is the root of its lineage).
    let parentKey: ThreadKey?
    /// Ordered ancestors, root → ... → parent. Excludes self. Empty when
    /// `parentKey == nil` or when ancestors aren't loaded.
    let ancestors: [ThreadLineageMember]
    /// All loaded threads sharing this root, sorted by `updatedAt` desc.
    /// Includes self.
    let members: [ThreadLineageMember]
    /// 1-based position of self in `members`.
    let branchIndex: Int
    /// Equal to `members.count`. Cached so callers don't reach into the array.
    let branchTotal: Int

    var hasMultipleBranches: Bool { branchTotal > 1 }
}

struct HomeDashboardRecentSession: Identifiable, Hashable {
    let key: ThreadKey
    let serverId: String
    let serverDisplayName: String
    let agentRuntimeKind: AgentRuntimeKind
    let isLocal: Bool
    let sessionTitle: String
    let preview: String
    let cwd: String
    let model: String
    let agentLabel: String?
    let updatedAt: Date
    let hasTurnActive: Bool
    let isResumed: Bool
    let isSubagent: Bool
    let isFork: Bool
    /// Source thread id when this thread was created via the in-app
    /// fork actions (`forkThread` / `forkThreadFromMessage`). Distinct
    /// from sub-agent parentage — sub-agents never set this.
    let forkedFromId: String?
    /// Set when this thread shares a fork root with at least one other
    /// loaded thread. `nil` for singletons.
    let lineage: ThreadLineage?
    let lastResponsePreview: String?
    /// `source_turn_id` of the assistant item behind
    /// `lastResponsePreview`. Used as the crossfade key in
    /// `HomeDashboardView.responsePreview` so the text only re-animates when
    /// a new assistant reply arrives, not when the user submits a new
    /// prompt (which bumps `stats.turnCount` before any assistant text
    /// exists).
    let lastResponseTurnId: String?
    let lastUserMessage: String?
    let lastToolLabel: String?
    let stats: AppConversationStats?
    let tokenUsage: AppTokenUsage?
    let goal: AppThreadGoal?
    /// Tool activity log precomputed by the Rust reducer in
    /// `extract_conversation_activity` (shared/rust-bridge/.../boundary.rs).
    /// The iOS home card used to redo this walk client-side — that was the
    /// dominant AttributeGraph subscription during streaming. Using the
    /// Rust-side log removes every `appModel.snapshot` read from the card
    /// at zoom 1–3.
    let recentToolLog: [AppToolLogEntry]
    /// Bounds of the most recent turn. Rust emits these in milliseconds
    /// since epoch alongside `recent_tool_log`; we project into `Date` so
    /// the zoom-4 stopwatch chip can render durations without reading
    /// `appModel.snapshot`. `end` is `nil` when the turn is still active
    /// — the chip then drives its own live ticker.
    let lastTurnStart: Date?
    let lastTurnEnd: Date?

    var id: ThreadKey { key }
}

struct HomeDashboardServer: Identifiable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let isLocal: Bool
    let health: AppServerHealth
    let sourceLabel: String
    let statusLabel: String
    let statusColor: Color
    let statusDotState: StatusDotState
    let agentRuntimes: [AgentRuntimeInfo]
    /// Whether the session list on this server has more pages to load via
    /// `AppStore.load_threads_page`. Rust owns this; offline/remembered
    /// servers default to false.
    let sessionListHasMore: Bool

    var deduplicationKey: String {
        if isLocal {
            return "local"
        }

        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
            .lowercased()

        return normalized.isEmpty ? id : normalized
    }

    var canLaunchSessions: Bool {
        health != .disconnected
    }

    static func == (lhs: HomeDashboardServer, rhs: HomeDashboardServer) -> Bool {
        lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.host == rhs.host &&
            lhs.port == rhs.port &&
            lhs.isLocal == rhs.isLocal &&
            lhs.health == rhs.health &&
            lhs.sourceLabel == rhs.sourceLabel &&
            lhs.statusLabel == rhs.statusLabel &&
            lhs.agentRuntimes.map(agentRuntimeEqualityKey) == rhs.agentRuntimes.map(agentRuntimeEqualityKey) &&
            lhs.sessionListHasMore == rhs.sessionListHasMore
    }
}

private func agentRuntimeEqualityKey(_ runtime: AgentRuntimeInfo) -> String {
    "\(runtime.kind)-\(runtime.name)-\(runtime.displayName)-\(runtime.available)"
}

@MainActor
enum HomeDashboardSupport {
    static func recentConnectedSessions(
        from sessions: [AppSessionSummary],
        serversById: [String: HomeDashboardServer],
        limit: Int? = 10
    ) -> [HomeDashboardRecentSession] {
        // Compute lineage from the *unfiltered* snapshot so a fork whose
        // parent lives on the same server (always the case in practice)
        // resolves even if we later drop sessions due to server filters.
        let lineageByKey = ThreadLineageMap.compute(sessions: sessions)
        let sorted = sessions
            .filter { serversById[$0.key.serverId] != nil }
            .filter { !$0.isSubagent }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .compactMap { session -> HomeDashboardRecentSession? in
                guard let server = serversById[session.key.serverId] else { return nil }
                let lineage = lineageByKey[session.key].flatMap { $0.hasMultipleBranches ? $0 : nil }
                return HomeDashboardRecentSession(
                    key: session.key,
                    serverId: session.key.serverId,
                    serverDisplayName: server.displayName,
                    agentRuntimeKind: session.agentRuntimeKind,
                    isLocal: server.isLocal,
                    sessionTitle: sessionTitle(for: session),
                    preview: session.preview,
                    cwd: session.cwd,
                    model: session.model,
                    agentLabel: session.agentDisplayLabel,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(session.updatedAt ?? 0)),
                    hasTurnActive: session.hasActiveTurn,
                    isResumed: session.isResumed,
                    isSubagent: session.isSubagent,
                    isFork: session.isFork,
                    forkedFromId: session.forkedFromId,
                    lineage: lineage,
                    lastResponsePreview: session.lastResponsePreview,
                    lastResponseTurnId: session.lastResponseTurnId,
                    lastUserMessage: session.lastUserMessage,
                    lastToolLabel: session.lastToolLabel,
                    stats: session.stats,
                    tokenUsage: session.tokenUsage,
                    goal: session.goal,
                    recentToolLog: session.recentToolLog,
                    lastTurnStart: session.lastTurnStartMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) },
                    lastTurnEnd: session.hasActiveTurn
                        ? nil
                        : session.lastTurnEndMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
                )
            }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    static func sortedConnectedServers(
        from servers: [AppServerSnapshot],
        savedServers: [SavedServer] = [],
        activeServerId: String?
    ) -> [HomeDashboardServer] {
        let liveServers = servers
            .filter { $0.health != .disconnected || $0.connectionProgress != nil }
            .map { server in
                HomeDashboardServer(
                    id: server.serverId,
                    displayName: server.displayName,
                    host: server.host,
                    port: server.port,
                    isLocal: server.isLocal,
                    health: server.health,
                    sourceLabel: server.connectionModeLabel,
                    statusLabel: server.statusLabel,
                    statusColor: server.statusColor,
                    statusDotState: server.statusDotState,
                    agentRuntimes: server.agentRuntimes,
                    sessionListHasMore: server.sessionListHasMore
                )
            }

        var seenServerIds = Set(liveServers.map(\.id))
        var seenServerKeys = Set(liveServers.map(\.deduplicationKey))
        var merged = liveServers

        for saved in savedServers where saved.rememberedByUser {
            let offline = offlineServer(from: saved)
            guard seenServerIds.insert(offline.id).inserted,
                  seenServerKeys.insert(offline.deduplicationKey).inserted else {
                continue
            }
            merged.append(offline)
        }

        return merged
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.id == activeServerId
                let rhsIsActive = rhs.id == activeServerId
                if lhsIsActive != rhsIsActive {
                    return lhsIsActive && !rhsIsActive
                }

                let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if byName != .orderedSame {
                    return byName == .orderedAscending
                }

                return lhs.id < rhs.id
            }
    }

    private static func offlineServer(from saved: SavedServer) -> HomeDashboardServer {
        HomeDashboardServer(
            id: saved.id,
            displayName: saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? saved.hostname
                : saved.name,
            host: saved.hostname,
            port: saved.preferredCodexPort ?? saved.port ?? saved.sshPort ?? 0,
            isLocal: saved.source == .local,
            health: .disconnected,
            sourceLabel: sourceLabel(for: saved),
            statusLabel: AppServerHealth.disconnected.displayLabel,
            statusColor: AppServerHealth.disconnected.accentColor,
            statusDotState: .idle,
            agentRuntimes: savedAgentRuntimes(for: saved),
            sessionListHasMore: false
        )
    }

    private static func sourceLabel(for saved: SavedServer) -> String {
        if saved.alleycatAgentWire == "ssh-bridge" { return "ssh" }
        if saved.alleycatNodeId != nil { return "alleycat" }
        if saved.websocketURL != nil { return "remote" }
        if saved.preferredConnectionMode == .ssh { return "ssh" }
        switch saved.source {
        case .local:
            return "local"
        case .bonjour:
            return "bonjour"
        case .ssh:
            return "ssh"
        case .tailscale:
            return "tailscale"
        case .manual:
            return "manual"
        }
    }

    private static func savedAgentRuntimes(for saved: SavedServer) -> [AgentRuntimeInfo] {
        let kinds: [AgentRuntimeKind]
        if saved.alleycatAgentWire == "ssh-bridge" || saved.alleycatNodeId != nil {
            kinds = parseRuntimeKinds(saved.alleycatAgentName)
        } else {
            // Direct Codex connections have a single known runtime —
            // the codex app-server itself. Use the cached metadata id
            // when present so the entry survives if codex is renamed
            // server-side; fall back to the literal "codex" id
            // otherwise (cold start before first probe).
            let fallback = AgentRuntimeMetadataProvider.all?()
                .first(where: { $0.capabilities?.usesDirectCodexPort == true })?
                .name
                ?? "codex"
            kinds = [fallback]
        }
        return kinds.map { kind in
            AgentRuntimeInfo(
                kind: kind,
                name: kind.displayLabel.lowercased(),
                displayName: kind.displayLabel,
                available: true
            )
        }
    }

    private static func parseRuntimeKinds(_ raw: String?) -> [AgentRuntimeKind] {
        let parsed = (raw ?? "")
            .split(separator: ",")
            .compactMap { token -> AgentRuntimeKind? in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { return nil }
                switch trimmed {
                case "pi.dev", "pidev": return "pi"
                case "ampcode", "amp-code", "amp_code", "amp code": return "amp"
                case "open-code", "open_code", "open code": return "opencode"
                case "claude-code", "claude_code", "claude code": return "claude"
                case "factory", "factory-droid", "factory_droid", "factory droid": return "droid"
                default: return trimmed
                }
            }
        return parsed.isEmpty ? ["codex"] : parsed
    }

    static func serverSubtitle(for server: HomeDashboardServer) -> String {
        if server.isLocal {
            return "In-process server"
        }

        return "\(server.host):\(server.port) | \(server.sourceLabel)"
    }

    static func workspaceLabel(for cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    static func sessionTitle(for session: AppSessionSummary) -> String {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && trimmedTitle != "Untitled session" {
            return trimmedTitle
        }

        let trimmedPreview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreview.isEmpty { return trimmedPreview }

        if let userMessage = session.lastUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userMessage.isEmpty {
            return userMessage
        }

        return "New thread"
    }
}

/// Walks `forkedFromId` over a snapshot of session summaries to derive a
/// `ThreadLineage` for every thread. Lineage is scoped per server — a fork
/// id always refers to a thread on the same server. Cycles are guarded by
/// tracking visited thread ids during the walk. Sub-agent parentage is
/// intentionally NOT traversed: it's a separate relationship and surfaces
/// through `agentNickname`/`agentRole`, not via fork affordances.
@MainActor
enum ThreadLineageMap {
    static func compute(sessions: [AppSessionSummary]) -> [ThreadKey: ThreadLineage] {
        guard !sessions.isEmpty else { return [:] }

        var byServerThreadId: [String: [String: AppSessionSummary]] = [:]
        for session in sessions {
            byServerThreadId[session.key.serverId, default: [:]][session.key.threadId] = session
        }

        var rootByKey: [ThreadKey: ThreadKey] = [:]
        for session in sessions {
            rootByKey[session.key] = root(for: session, in: byServerThreadId)
        }

        var groupsByRoot: [ThreadKey: [AppSessionSummary]] = [:]
        for session in sessions {
            let r = rootByKey[session.key] ?? session.key
            groupsByRoot[r, default: []].append(session)
        }

        var result: [ThreadKey: ThreadLineage] = [:]
        for (rootKey, group) in groupsByRoot {
            let sorted = group.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            let members = sorted.map {
                ThreadLineageMember(key: $0.key, title: HomeDashboardSupport.sessionTitle(for: $0))
            }
            for (idx, session) in sorted.enumerated() {
                let parentKey = sanitizedForkParentKey(for: session)
                let ancestors = ancestorChain(for: session, in: byServerThreadId)
                result[session.key] = ThreadLineage(
                    rootKey: rootKey,
                    parentKey: parentKey,
                    ancestors: ancestors,
                    members: members,
                    branchIndex: idx + 1,
                    branchTotal: members.count
                )
            }
        }
        return result
    }

    private static func sanitizedForkParentKey(for session: AppSessionSummary) -> ThreadKey? {
        guard let parentId = session.forkedFromId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentId.isEmpty
        else { return nil }
        return ThreadKey(serverId: session.key.serverId, threadId: parentId)
    }

    private static func root(
        for session: AppSessionSummary,
        in byServerThreadId: [String: [String: AppSessionSummary]]
    ) -> ThreadKey {
        var current = session
        var visited: Set<String> = [current.key.threadId]
        while let parentId = current.forkedFromId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentId.isEmpty,
              !visited.contains(parentId)
        {
            visited.insert(parentId)
            guard let parent = byServerThreadId[current.key.serverId]?[parentId] else {
                // Parent isn't in the loaded snapshot. Use its id as a
                // synthetic root key so siblings of an unloaded parent
                // still cluster together — otherwise A and B with
                // forkedFromId=P would each be their own root and the
                // search clusters would split.
                return ThreadKey(serverId: current.key.serverId, threadId: parentId)
            }
            current = parent
        }
        return current.key
    }

    private static func ancestorChain(
        for session: AppSessionSummary,
        in byServerThreadId: [String: [String: AppSessionSummary]]
    ) -> [ThreadLineageMember] {
        var chain: [ThreadLineageMember] = []
        var current = session
        var visited: Set<String> = [current.key.threadId]
        while let parentId = current.forkedFromId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentId.isEmpty,
              !visited.contains(parentId),
              let parent = byServerThreadId[current.key.serverId]?[parentId]
        {
            chain.insert(
                ThreadLineageMember(
                    key: parent.key,
                    title: HomeDashboardSupport.sessionTitle(for: parent)
                ),
                at: 0
            )
            visited.insert(parentId)
            current = parent
        }
        return chain
    }
}
