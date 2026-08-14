import Foundation
import Observation

@MainActor
@Observable
final class SessionsModel {
    struct ThreadEphemeralState: Equatable {
        let hasTurnActive: Bool
        let updatedAt: Date
    }

    private struct Snapshot: Equatable {
        let derivedData: SessionsDerivedData
        let connectedServerOptions: [DirectoryPickerServerOption]
        let connectedServers: [HomeDashboardServer]
        let ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState]
        let activeThreadKey: ThreadKey?
        let frozenMostRecentThreadOrder: [ThreadKey]?
    }

    private(set) var derivedData: SessionsDerivedData = .empty
    private(set) var connectedServerOptions: [DirectoryPickerServerOption] = []
    private(set) var connectedServers: [HomeDashboardServer] = []
    private(set) var ephemeralStateByThreadKey: [ThreadKey: ThreadEphemeralState] = [:]
    private(set) var activeThreadKey: ThreadKey?

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var searchQuery = ""
    @ObservationIgnored private var selectedRuntimeKind: AgentRuntimeKind?
    @ObservationIgnored private var hasInitializedState = false
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var frozenMostRecentThreadOrder: [ThreadKey]?
    @ObservationIgnored private var lastPublishedSnapshot: Snapshot?

    func bind(appModel: AppModel, appState: AppState) {
        let needsRebind = self.appModel !== appModel || self.appState !== appState

        self.appModel = appModel
        self.appState = appState

        guard needsRebind || !hasInitializedState else { return }
        hasInitializedState = true
        refreshState()
    }

    func updateSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        refreshState()
    }

    func updateRuntimeKindFilter(_ kind: AgentRuntimeKind?) {
        guard kind != selectedRuntimeKind else { return }
        selectedRuntimeKind = kind
        refreshState()
    }

    private func refreshState() {
        #if DEBUG
        let deriveSignpostID = PerfAttribution.begin("SessionsDerive"); defer { PerfAttribution.end("SessionsDerive", deriveSignpostID) }
        #endif
        guard let appModel, let appState else {
            derivedData = .empty
            connectedServerOptions = []
            connectedServers = []
            ephemeralStateByThreadKey = [:]
            activeThreadKey = nil
            frozenMostRecentThreadOrder = nil
            lastPublishedSnapshot = nil
            return
        }

        let previousDisplayedOrder = derivedData.allThreadKeys
        let currentSearchQuery = searchQuery
        let currentRuntimeKindFilter = selectedRuntimeKind

        observationGeneration &+= 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            let selectedServerFilterId = appState.sessionsSelectedServerFilterId
            let showOnlyForks = appState.sessionsShowOnlyForks
            let workspaceSortMode = WorkspaceSortMode(rawValue: appState.sessionsWorkspaceSortModeRaw) ?? .mostRecent
            let appSnapshot = appModel.snapshot

            let nextConnectedServers = HomeDashboardSupport.sortedConnectedServers(
                from: appSnapshot?.servers ?? [],
                activeServerId: appSnapshot?.activeThread?.serverId
            )

            let nextConnectedServerOptions = nextConnectedServers.map {
                DirectoryPickerServerOption(
                    id: $0.id,
                    name: $0.displayName,
                    sourceLabel: $0.sourceLabel
                )
            }

            let nextEphemeralStateByThreadKey = (appSnapshot?.sessionSummaries ?? []).reduce(into: [ThreadKey: ThreadEphemeralState]()) { partialResult, session in
                partialResult[session.key] = ThreadEphemeralState(
                    hasTurnActive: session.hasActiveTurn,
                    updatedAt: session.updatedAtDate
                )
            }

            let nextFrozenMostRecentThreadOrder = resolvedFrozenMostRecentThreadOrder(
                sessionSummaries: appSnapshot?.sessionSummaries ?? [],
                workspaceSortMode: workspaceSortMode,
                previousDisplayedOrder: previousDisplayedOrder
            )

            let nextDerivedData = SessionsDerivation.build(
                sessions: appSnapshot?.sessionSummaries ?? [],
                selectedServerFilterId: selectedServerFilterId,
                showOnlyForks: showOnlyForks,
                selectedRuntimeKind: currentRuntimeKindFilter,
                workspaceSortMode: workspaceSortMode,
                searchQuery: currentSearchQuery,
                frozenMostRecentOrder: nextFrozenMostRecentThreadOrder
            )

            return Snapshot(
                derivedData: nextDerivedData,
                connectedServerOptions: nextConnectedServerOptions,
                connectedServers: nextConnectedServers,
                ephemeralStateByThreadKey: nextEphemeralStateByThreadKey,
                activeThreadKey: appSnapshot?.activeThread,
                frozenMostRecentThreadOrder: nextFrozenMostRecentThreadOrder
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.refreshState()
            }
        }

        let previousSnapshot = lastPublishedSnapshot
        guard previousSnapshot != snapshot else {
            frozenMostRecentThreadOrder = snapshot.frozenMostRecentThreadOrder
            return
        }

        frozenMostRecentThreadOrder = snapshot.frozenMostRecentThreadOrder
        lastPublishedSnapshot = snapshot

        if previousSnapshot?.connectedServerOptions != snapshot.connectedServerOptions {
            connectedServerOptions = snapshot.connectedServerOptions
        }
        if previousSnapshot?.connectedServers != snapshot.connectedServers {
            connectedServers = snapshot.connectedServers
        }
        if previousSnapshot?.ephemeralStateByThreadKey != snapshot.ephemeralStateByThreadKey {
            ephemeralStateByThreadKey = snapshot.ephemeralStateByThreadKey
        }
        if previousSnapshot?.activeThreadKey != snapshot.activeThreadKey {
            activeThreadKey = snapshot.activeThreadKey
        }
        if previousSnapshot?.derivedData != snapshot.derivedData {
            derivedData = snapshot.derivedData
        }
    }

    private func resolvedFrozenMostRecentThreadOrder(
        sessionSummaries: [AppSessionSummary],
        workspaceSortMode: WorkspaceSortMode,
        previousDisplayedOrder: [ThreadKey]
    ) -> [ThreadKey]? {
        guard workspaceSortMode == .mostRecent else {
            return nil
        }

        let hasActiveThread = sessionSummaries.contains(where: \.hasActiveTurn)
        guard hasActiveThread else {
            return nil
        }

        if let frozenMostRecentThreadOrder {
            return frozenMostRecentThreadOrder
        }

        if !previousDisplayedOrder.isEmpty {
            return previousDisplayedOrder
        }

        return sessionSummaries
            .sorted { $0.updatedAtDate > $1.updatedAtDate }
            .map(\.key)
    }
}
