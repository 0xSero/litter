import Foundation
import Observation

/// Throttled projection of the handful of `AppModel.snapshot`-derived values
/// that `ContentView.standardOverlays` needs. Instead of reading
/// `appModel.snapshot` directly in `body` (which re-renders the entire
/// top-level shell on every streaming token), views observe this model and
/// only re-render when the *projected* values actually change — at most
/// ~8 fps thanks to the coalesced snapshot revision.
///
/// The projection is cheap: it reads the snapshot once per revision tick,
/// derives `PetAvatarState`, the pet message, and the active non-MCP
/// approval, and publishes only those three values.
@MainActor
@Observable
final class OverlayProjectionModel {
    private static let refreshDelayNanoseconds: UInt64 = 100_000_000 // ~10 fps

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var petOverlay: PetOverlayController?
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private(set) var petAvatarState: PetAvatarState = .idle
    private(set) var petAvatarMessage: String?
    private(set) var pendingApproval: PendingApproval?

    func bind(appModel: AppModel, petOverlay: PetOverlayController) {
        // Invalidate any prior observation generation so stale tracking
        // closures from a previous bind() are ignored.
        observationGeneration &+= 1
        self.appModel = appModel
        self.petOverlay = petOverlay
        observeRevision()
    }

    /// Start observing `snapshotRevision` and `PetOverlayController` state
    /// outside of any SwiftUI `body` so the observation edge lives here
    /// rather than in a view body. Pet overlay state (loading, dragging)
    /// can change independently of snapshot revisions, so we track both.
    private func observeRevision() {
        guard let appModel else { return }
        let generation = observationGeneration
        let revision = withObservationTracking({
            // Track snapshot revisions for approval/pending changes.
            appModel.snapshotRevision
            // Track pet overlay state changes (loading, dragging, direction)
            // that can happen without a snapshot bump.
            if let petOverlay {
                _ = petOverlay.isLoading
                _ = petOverlay.isDragging
            }
        }) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.scheduleRefresh()
            }
        }
        _ = revision
        refreshProjection()
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshDelayNanoseconds)
            guard let self else { return }
            self.observeRevision()
        }
    }

    private func refreshProjection() {
        guard let appModel, let petOverlay else { return }
        let snapshot = appModel.snapshot

        let nextPetState = petOverlay.avatarState(snapshot: snapshot)
        let nextPetMessage = petOverlay.avatarMessage(snapshot: snapshot)
        let nextApproval = snapshot?.pendingApprovals.first(where: {
            $0.kind != .mcpElicitation
        })

        // Only publish when something changed — avoids needless body re-evals.
        if petAvatarState != nextPetState {
            petAvatarState = nextPetState
        }
        if petAvatarMessage != nextPetMessage {
            petAvatarMessage = nextPetMessage
        }
        if pendingApproval != nextApproval {
            pendingApproval = nextApproval
        }
    }
}
