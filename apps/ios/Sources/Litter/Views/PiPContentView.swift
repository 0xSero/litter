import SwiftUI

/// Body rendered into the PiP sample-buffer layer on every tick.
///
/// Wraps the home dashboard's level-4 `SessionCanvasLine` so PiP shows the
/// exact same card the user sees at max zoom on the home page. We rebuild
/// the `HomeDashboardRecentSession` for the active thread directly from
/// `AppModel.shared.snapshot` rather than reaching into a `HomeDashboardModel`
/// instance — the model is owned by `HomeNavigationView` (`@State`) and isn't
/// reachable from the PiP host without injection.
struct PiPContentView: View {
    /// Fixed PiP canvas width. Height is whatever the card needs (clamped to
    /// [minHeight, maxHeight]). PiP picks up the aspect from each sample
    /// buffer's format description and resizes the floating window to match.
    static let canvasWidth: CGFloat = 360
    static let minHeight: CGFloat = 160
    static let maxHeight: CGFloat = 720

    /// Cached derivation of the active session, keyed off
    /// `AppModel.snapshotRevision` (~8 fps while streaming) and the resolved
    /// active thread key. `body` re-evaluates on every ImageRenderer tick
    /// (up to 30 fps), and the derivation re-sorts, rebuilds dictionaries and
    /// scans threads — far too expensive to repeat per tick. With the cache,
    /// the derivation only re-runs when the snapshot actually moved or the
    /// pin/active thread changed; `body` otherwise reads the derived result.
    @MainActor
    private func activeSession() -> HomeDashboardRecentSession? {
        let revision = AppModel.shared.snapshotRevision
        let activeKey = StreamingPiPController.shared.pinnedThreadKey
            ?? AppModel.shared.snapshot?.activeThread
        if ActiveSessionCache.revision == revision,
           ActiveSessionCache.activeKey == activeKey {
            return ActiveSessionCache.session
        }
        let session = computeActiveSession(activeKey: activeKey)
        ActiveSessionCache.revision = revision
        ActiveSessionCache.activeKey = activeKey
        ActiveSessionCache.session = session
        return session
    }

    @MainActor
    private func computeActiveSession(activeKey: ThreadKey?) -> HomeDashboardRecentSession? {
        guard let snapshot = AppModel.shared.snapshot, let activeKey = activeKey else { return nil }
        let servers = HomeDashboardSupport.sortedConnectedServers(
            from: snapshot.servers,
            savedServers: [],
            activeServerId: activeKey.serverId
        )
        let serversById = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        let sessions = HomeDashboardSupport.recentConnectedSessions(
            from: snapshot.sessionSummaries,
            serversById: serversById,
            limit: nil
        )
        guard let base = sessions.first(where: { $0.key == activeKey }) else { return nil }
        // The summary's `model` (and runtime kind) can be stale relative to
        // what the user actually selected for the active thread — the
        // conversation header reads from the live AppThreadSnapshot. Mirror
        // that here so PiP always shows the truly-current model.
        let liveThread = snapshot.threads.first { $0.key == activeKey }
        let liveModel = liveThread?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveRuntime = liveThread?.agentRuntimeKind
        return base.overriding(
            model: (liveModel?.isEmpty == false) ? liveModel : nil,
            agentRuntimeKindString: liveRuntime
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let session = activeSession() {
                SessionCanvasLine(
                    session: session,
                    isOpening: false,
                    isHydrating: false,
                    isCancelling: false,
                    zoomLevel: 4
                )
                .padding(.top, 12)
                .frame(width: Self.canvasWidth, alignment: .topLeading)
            } else {
                Text("no active thread")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(
                        width: Self.canvasWidth,
                        height: Self.minHeight,
                        alignment: .center
                    )
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(width: Self.canvasWidth)
        .frame(minHeight: Self.minHeight, maxHeight: Self.maxHeight, alignment: .topLeading)
        .background(Color.black)
        .clipped()
    }
}

/// File-scoped cache for the PiP card's derived session. `StreamingPiPController`
/// reassigns `renderer.content = PiPContentView()` on every render tick, so a
/// per-instance cache never survives between body evaluations. Keyed by
/// (snapshot revision, resolved active thread key) — see `activeSession()`.
@MainActor
private enum ActiveSessionCache {
    static var revision: UInt64?
    static var activeKey: ThreadKey?
    static var session: HomeDashboardRecentSession?
}

private extension HomeDashboardRecentSession {
    /// Returns a copy with selected fields overridden from a fresher source.
    /// Nil overrides leave the original value intact.
    func overriding(model: String?, agentRuntimeKindString: String?) -> HomeDashboardRecentSession {
        // AgentRuntimeKind is a typealias for String.
        let nextRuntime: AgentRuntimeKind = agentRuntimeKindString.flatMap {
            $0.isEmpty ? nil : $0
        } ?? agentRuntimeKind
        return HomeDashboardRecentSession(
            key: key,
            serverId: serverId,
            serverDisplayName: serverDisplayName,
            agentRuntimeKind: nextRuntime,
            isLocal: isLocal,
            sessionTitle: sessionTitle,
            preview: preview,
            cwd: cwd,
            model: model ?? self.model,
            agentLabel: agentLabel,
            updatedAt: updatedAt,
            hasTurnActive: hasTurnActive,
            isResumed: isResumed,
            isSubagent: isSubagent,
            isFork: isFork,
            forkedFromId: forkedFromId,
            lineage: lineage,
            lastResponsePreview: lastResponsePreview,
            lastResponseTurnId: lastResponseTurnId,
            lastUserMessage: lastUserMessage,
            lastToolLabel: lastToolLabel,
            stats: stats,
            tokenUsage: tokenUsage,
            goal: goal,
            recentToolLog: recentToolLog,
            lastTurnStart: lastTurnStart,
            lastTurnEnd: lastTurnEnd
        )
    }
}
