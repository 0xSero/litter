import Foundation
import Observation

// MARK: - Snapshot Observation

/// Default coalescing window for `AppSnapshotObserver`, matching the ~8 fps
/// cadence at which `AppModel` publishes snapshot revisions while streaming.
/// File-scoped rather than a static member so it can be used as a default
/// argument without crossing the observer's main-actor isolation.
private let appSnapshotObserverDefaultCoalesce: UInt64 = 120_000_000

/// Body-free observer for `AppModel.snapshot`.
///
/// `AppModel.snapshot` and `snapshotRevision` are bumped in lockstep at
/// roughly 8 fps while a turn streams, so *any* SwiftUI `body` that reads
/// either one — directly, or transitively through an `AppModel` helper such as
/// `threadSnapshot(for:)` / `serverSnapshot(for:)` / `sessionSummary(for:)` —
/// re-renders at that rate.
///
/// Views that only need a small, slow-moving projection of the snapshot (the
/// server list, one thread, one server) install this observer from `.task`
/// and mirror what they need into `@State`. The observation edge then lives
/// here — `withObservationTracking`, the same pattern as
/// `OverlayProjectionModel` — instead of in a view body, so the view
/// re-renders only when the mirrored `@State` actually changes.
///
/// Usage:
/// ```
/// @State private var snapshotObserver = AppSnapshotObserver()
/// ...
/// .task { snapshotObserver.start(appModel: appModel) { refreshProjection() } }
/// .onDisappear { snapshotObserver.stop() }
/// ```
/// `refresh` runs once immediately on `start`, then again — coalesced — after
/// each snapshot revision. It must write `@State` only when a value actually
/// changed, otherwise the body churn simply moves here.
///
/// Lives in this file only because adding a new source file would require
/// regenerating `Litter.xcodeproj`; it is not settings-specific.
@MainActor
final class AppSnapshotObserver {
    /// Bumped by `start`/`stop` so tracking callbacks armed by a previous
    /// registration are ignored instead of resurrecting a stale refresh.
    private var generation = 0
    private var rearmTask: Task<Void, Never>?
    private var refresh: (@MainActor () -> Void)?
    private var coalesceNanoseconds = appSnapshotObserverDefaultCoalesce

    // No `deinit` cleanup is needed: the pending re-arm task only holds a weak
    // reference back here, so it no-ops once the observer is released.

    /// Runs `refresh` now and on every later snapshot revision. Calling
    /// `start` again replaces the previous registration, so it is safe to
    /// call from `.task(id:)` as well as plain `.task`.
    func start(
        appModel: AppModel,
        coalesceNanoseconds: UInt64 = appSnapshotObserverDefaultCoalesce,
        refresh: @escaping @MainActor () -> Void
    ) {
        generation &+= 1
        rearmTask?.cancel()
        rearmTask = nil
        self.refresh = refresh
        self.coalesceNanoseconds = coalesceNanoseconds
        arm(appModel: appModel)
    }

    func stop() {
        generation &+= 1
        rearmTask?.cancel()
        rearmTask = nil
        refresh = nil
    }

    private func arm(appModel: AppModel) {
        let generation = self.generation
        withObservationTracking({
            _ = appModel.snapshotRevision
        }, onChange: { [weak self] in
            // `onChange` fires on `willSet`; hop to the next main-actor turn so
            // the refresh reads the committed snapshot.
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.scheduleRearm(appModel: appModel)
            }
        })
        refresh?()
    }

    private func scheduleRearm(appModel: AppModel) {
        let generation = self.generation
        let delay = coalesceNanoseconds
        rearmTask?.cancel()
        rearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  self.generation == generation else { return }
            // Re-arming also refreshes, so revisions that landed during the
            // coalescing window are picked up.
            self.arm(appModel: appModel)
        }
    }
}
