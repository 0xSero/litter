import Foundation
import Combine
import WatchConnectivity

/// Observable state container for the watch app. Sourced from the iPhone
/// via `WatchSessionBridge`; starts empty and populates on first snapshot.
@MainActor
final class WatchAppStore: ObservableObject {
    @Published var tasks: [WatchTask] = []
    /// The task the user is currently drilled into. Purely local — the
    /// transcript for each task is carried inside the task itself, so this
    /// doesn't need to round-trip to the phone.
    @Published var focusedTaskId: String?
    @Published var pendingApproval: WatchApproval?
    @Published var voice: WatchVoiceState?
    @Published var isReachable: Bool = false
    @Published var lastSyncDate: Date?
    /// True while an approval reply is in flight. UI uses this to keep the
    /// approval card visible (with a "sending…" hint) until the phone
    /// confirms.
    @Published var approvalInFlight: Bool = false
    /// Transient error message from the most recent approval round-trip.
    /// Cleared by UI after a short timeout.
    @Published var approvalError: String?

    static let shared = WatchAppStore()

    var focusedTask: WatchTask? {
        if let id = focusedTaskId, let task = tasks.first(where: { $0.id == id }) {
            return task
        }
        return tasks.first
    }

    var runningTaskCount: Int {
        tasks.filter { $0.status == .running }.count
    }

    var approvalsTaskCount: Int {
        tasks.filter { $0.status == .needsApproval }.count
    }

    var hasData: Bool {
        lastSyncDate != nil
    }

    /// True when the persisted snapshot is older than 5 minutes. Used to
    /// surface a stale-data hint when the phone is unreachable.
    var lastSyncIsStale: Bool {
        guard let date = lastSyncDate else { return true }
        return Date().timeIntervalSince(date) > 5 * 60
    }

    /// Seed the store from the App Group on cold launch. Called before
    /// WCSession activation so the UI can render last-known state instead
    /// of an infinite "syncing…" placeholder.
    func hydrateFromAppGroupIfNeeded() {
        guard lastSyncDate == nil,
              let (payload, date) = WatchSnapshotStore.current()
        else { return }
        tasks = payload.tasks
        pendingApproval = payload.pendingApproval
        voice = payload.voice
        lastSyncDate = date
        if focusedTaskId == nil {
            focusedTaskId = payload.tasks.first?.id
        }
    }

    // MARK: - Outbound (watch → phone)

    func respond(approve: Bool) {
        guard let approval = pendingApproval, !approvalInFlight else { return }
        approvalInFlight = true
        approvalError = nil
        WatchSessionBridge.shared.sendApprovalDecision(
            requestId: approval.id,
            approve: approve
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .ok, .queued:
                self.pendingApproval = nil
                self.approvalInFlight = false
            case .failed(let reason):
                self.approvalInFlight = false
                self.approvalError = reason
            }
        }
    }

    /// Remember which task the user drilled into — local only.
    func focus(on task: WatchTask) {
        focusedTaskId = task.id
    }

    #if DEBUG
    static func previewStore() -> WatchAppStore {
        let store = WatchAppStore()
        store.tasks = WatchPreviewFixtures.tasks
        store.focusedTaskId = WatchPreviewFixtures.tasks.first?.id
        store.pendingApproval = WatchPreviewFixtures.approval
        store.voice = WatchPreviewFixtures.voice
        store.lastSyncDate = .now
        store.isReachable = true
        return store
    }
    #endif
}
