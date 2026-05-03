import Foundation
import WatchConnectivity
import WidgetKit

/// Watch-side WatchConnectivity bridge. Receives snapshots from the iOS
/// app via `updateApplicationContext` and forwards user actions back via
/// `sendMessage` (approval decisions, voice prompts).
@MainActor
final class WatchSessionBridge: NSObject, WCSessionDelegate {
    static let shared = WatchSessionBridge()

    private override init() { super.init() }

    /// Hash of the complication-relevant subset of the most recent snapshot.
    /// Used to skip widget reloads when nothing the complication renders has
    /// actually changed.
    private var lastComplicationDigest: Int?

    func start() {
        // Seed last-known state from the App Group before WCSession
        // activates — gives the UI something to render immediately on
        // cold launch even when the phone is unreachable.
        WatchAppStore.shared.hydrateFromAppGroupIfNeeded()

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    enum ApprovalResult {
        case ok
        case queued
        case failed(String)
    }

    func sendApprovalDecision(
        requestId: String,
        approve: Bool,
        completion: @escaping (ApprovalResult) -> Void = { _ in }
    ) {
        let payload: [String: Any] = [
            "kind": "approval.decision",
            "requestId": requestId,
            "approve": approve
        ]
        sendMessageWithReply(payload) { result in
            switch result {
            case .sent: completion(.ok)
            case .queued: completion(.queued)
            case .failed(let reason): completion(.failed(reason))
            }
        }
    }

    /// Outcome of a prompt send round-trip. `queued` means the watch fell
    /// back to `transferUserInfo` because the phone wasn't reachable.
    enum PromptResult {
        case sent(threadId: String?)
        case queued
        case failed(String)
    }

    /// Send a dictated prompt to the phone. Includes the focused task's
    /// `(serverId, threadId)` so the phone can route to the correct thread.
    /// Surfaces the iOS reply via `completion`.
    func sendPrompt(
        _ text: String,
        serverId: String? = nil,
        threadId: String? = nil,
        completion: @escaping (PromptResult) -> Void = { _ in }
    ) {
        var payload: [String: Any] = [
            "kind": "prompt.send",
            "text": text
        ]
        if let serverId { payload["serverId"] = serverId }
        if let threadId { payload["threadId"] = threadId }
        sendMessageWithReply(payload, completion: completion)
    }

    /// Trigger a fresh snapshot push from the phone.
    func requestSnapshot() {
        sendMessage(["kind": "snapshot.request"])
    }

    // MARK: - Realtime voice control

    func sendVoiceStart(serverId: String, threadId: String? = nil) {
        var payload: [String: Any] = [
            "kind": "voice.start",
            "serverId": serverId
        ]
        if let threadId { payload["threadId"] = threadId }
        sendMessage(payload)
    }

    func sendVoiceStop() {
        sendMessage(["kind": "voice.stop"])
    }

    func sendVoiceToggleMute() {
        sendMessage(["kind": "voice.toggleMute"])
    }

    func sendVoiceBargeIn() {
        sendMessage(["kind": "voice.bargeIn"])
    }

    private func sendMessage(_ payload: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            // Fallback: queue via transferUserInfo so the phone receives it
            // when it wakes up.
            WCSession.default.transferUserInfo(payload)
        }
    }

    /// Send a message expecting a reply. When the phone is unreachable,
    /// falls back to `transferUserInfo` and surfaces `.queued`. The reply
    /// payload may include a `threadId` (for prompt routing).
    private func sendMessageWithReply(
        _ payload: [String: Any],
        completion: @escaping (PromptResult) -> Void
    ) {
        guard WCSession.default.activationState == .activated else {
            completion(.failed("watch not active"))
            return
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: { reply in
                let ok = reply["ok"] as? Bool ?? false
                let threadId = reply["threadId"] as? String
                let error = reply["error"] as? String
                Task { @MainActor in
                    if ok {
                        completion(.sent(threadId: threadId))
                    } else {
                        completion(.failed(error ?? "send failed"))
                    }
                }
            }, errorHandler: { error in
                Task { @MainActor in
                    completion(.failed(error.localizedDescription))
                }
            })
        } else {
            WCSession.default.transferUserInfo(payload)
            completion(.queued)
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in
            WatchAppStore.shared.isReachable = reachable
            guard state == .activated else {
                if let error {
                    print("[watch] WCSession activation failed: \(error.localizedDescription)")
                }
                return
            }
            self.requestSnapshot()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchAppStore.shared.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private func reloadComplicationsIfChanged(store: WatchAppStore) {
        var hasher = Hasher()
        hasher.combine(store.runningTaskCount)
        hasher.combine(store.approvalsTaskCount)
        hasher.combine(store.focusedTaskId)
        let digest = hasher.finalize()
        guard digest != lastComplicationDigest else { return }
        lastComplicationDigest = digest

        let center = WidgetCenter.shared
        center.reloadTimelines(ofKind: "LitterCircularComplication")
        center.reloadTimelines(ofKind: "LitterCornerComplication")
        center.reloadTimelines(ofKind: "LitterRectangularComplication")
    }

    private nonisolated func handle(_ payload: [String: Any]) {
        guard
            let raw = payload["litter.snapshot"] as? Data,
            let snapshot = try? JSONDecoder().decode(WatchSnapshotPayload.self, from: raw)
        else { return }

        Task { @MainActor in
            let store = WatchAppStore.shared
            store.tasks = snapshot.tasks
            store.pendingApproval = snapshot.pendingApproval
            store.voice = snapshot.voice
            // Keep local focus if it's still valid, otherwise pick first task.
            if let id = store.focusedTaskId,
               !snapshot.tasks.contains(where: { $0.id == id }) {
                store.focusedTaskId = snapshot.tasks.first?.id
            } else if store.focusedTaskId == nil {
                store.focusedTaskId = snapshot.tasks.first?.id
            }
            store.lastSyncDate = .now
            self.reloadComplicationsIfChanged(store: store)
        }
    }
}

