import Foundation
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Thin transport seam over `WCSession` so unit tests can drive
/// `WatchCompanionBridge` without a real WatchConnectivity stack. Production
/// uses the default `WCSession.default` conformance below.
@MainActor
protocol WatchTransport {
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
}

extension WCSession: WatchTransport {}

/// iOS side of the Watch companion pipeline.
///
/// - Observes `AppModel.shared.snapshot` and whenever it changes, projects
///   the relevant slice into a `WatchSnapshotPayload` and pushes it to the
///   paired watch via `WCSession.updateApplicationContext`.
/// - Writes a lightweight complication snapshot to the shared App Group so
///   the watchOS complications can read it even when the app isn't active.
/// - Receives inbound messages from the watch (approval decisions,
///   dictated prompts, voice control) and dispatches them back into
///   `AppStore` / composer / `VoiceRuntimeController`.
///
/// Kept thin: no state reducer logic here. Just projection + plumbing.
@MainActor
final class WatchCompanionBridge: NSObject {
    static let shared = WatchCompanionBridge()

    private static let appGroupSuite = "group.com.sigkitten.litter"
    private static let snapshotKey = "watch.snapshot.v1"
    private static let snapshotTimestampKey = "watch.snapshot.v1.timestamp"
    private static let complicationSnapshotKey = "complication.snapshot.v1"
    private static let complicationKinds = [
        "LitterCircularComplication",
        "LitterCornerComplication",
        "LitterRectangularComplication",
    ]

    private let delegate = WatchCompanionSessionDelegate()
    private var lastPushedPayload: WatchSnapshotPayload?
    private var lastPushedComplication: Data?
    private var pushThrottle: Task<Void, Never>?

    /// Injected WatchConnectivity surface. Tests pass a fake; production
    /// uses `WCSession.default` via the conformance above.
    var transport: WatchTransport

    private override convenience init() {
        self.init(transport: WCSession.default)
    }

    init(transport: WatchTransport) {
        self.transport = transport
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        observe()
    }

    // MARK: - Observation

    /// Observe the canonical Rust-backed `AppModel.shared.snapshot` via
    /// `withObservationTracking`. Each `onChange` re-arms a fresh tracker on
    /// the main actor, which is the same pattern `HomeDashboardModel` uses.
    private func observe() {
        withObservationTracking {
            // Touch every field that participates in the watch payload or
            // complication entry so a mutation to any of them schedules a
            // push. `pushIfChanged()` is the single sink that diffs against
            // the last successful push.
            _ = AppModel.shared.snapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pushIfChanged()
                self.observe()
            }
        }
        // Run an initial push so first-launch state lands on the watch
        // even before the snapshot mutates.
        pushIfChanged()
    }

    private func pushIfChanged() {
        let payload = currentPayload()
        let complication = currentComplicationSnapshot()

        if payload != lastPushedPayload {
            lastPushedPayload = payload
            push(payload: payload)
        }

        if complication != lastPushedComplication {
            lastPushedComplication = complication
            writeComplication(complication)
        }
    }

    // MARK: - Projection

    func currentPayload() -> WatchSnapshotPayload {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []

        let tasks = WatchProjection.tasks(
            summaries: summaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )

        return WatchSnapshotPayload(
            tasks: tasks,
            pendingApproval: pendingApprovals
                .first(where: { $0.kind != .mcpElicitation })
                .map(WatchProjection.approval),
            voice: WatchProjection.voice(
                from: snapshot,
                isMuted: VoiceRuntimeController.shared.isMicrophoneMuted
            )
        )
    }

    func currentComplicationSnapshot() -> Data? {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []
        let connectedCount = (snapshot?.servers ?? [])
            .filter { $0.transportState == .connected }.count

        let tasks = WatchProjection.tasks(
            summaries: summaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )
        let runningTask = tasks.first { $0.status == .running }
            ?? tasks.first { $0.status == .needsApproval }

        // B3: when WatchConnectivity isn't usable, surface offline mode.
        let offline: Bool = transport.activationState != .activated
            || !transport.isPaired
            || !transport.isWatchAppInstalled

        let mode: String
        let title: String
        let toolLine: String
        let progress: Double
        var taskId: String?
        var lastTurnStartMsEpoch: Int64?

        if offline {
            mode = "offline"
            title = "phone unreachable"
            toolLine = "tap to open"
            progress = 0
        } else if let task = runningTask {
            mode = "running"
            title = task.title
            toolLine = task.subtitle ?? "working"
            let total = max(task.steps.count, 1)
            let done = task.steps.filter({ $0.state == .done }).count
            progress = total > 0 ? Double(done) / Double(total) : 0.5
            taskId = task.id
            // Real wall-clock turn start, used by the timeline provider to
            // compute live elapsed seconds. Only running tasks tick, so we
            // only emit it when status == .running.
            if task.status == .running,
               let summary = summaries.first(where: {
                   $0.key.serverId == task.serverId && $0.key.threadId == task.threadId
               }),
               let started = summary.lastTurnStartMs {
                lastTurnStartMsEpoch = started
            }
        } else if tasks.isEmpty {
            mode = "idle"
            title = "\(connectedCount) servers ready"
            toolLine = "tap to open"
            progress = 1
        } else {
            mode = "idle"
            title = "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
            toolLine = tasks.first?.title ?? ""
            progress = 1
        }

        var dict: [String: Any] = [
            "mode": mode,
            "progress": progress,
            "title": title,
            "toolLine": toolLine,
            "serverCount": connectedCount,
        ]
        if let taskId { dict["taskId"] = taskId }
        if let lastTurnStartMsEpoch { dict["lastTurnStartMsEpoch"] = lastTurnStartMsEpoch }

        return try? JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Outbound

    private func push(payload: WatchSnapshotPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }

        // Cold-launch hydration: even if the watch isn't currently paired,
        // write the latest snapshot to the App Group so the watch can seed
        // from disk on next launch (A4).
        if let defaults = UserDefaults(suiteName: Self.appGroupSuite) {
            defaults.set(data, forKey: Self.snapshotKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.snapshotTimestampKey)
        }

        guard transport.activationState == .activated else { return }
        guard transport.isPaired && transport.isWatchAppInstalled else { return }

        // Throttle: coalesce rapid mutations into a single
        // updateApplicationContext call. Kept at 150ms — fast enough that
        // the watch feels live, slow enough to coalesce a turn-burst.
        pushThrottle?.cancel()
        pushThrottle = Task { @MainActor [transport] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                try transport.updateApplicationContext(["litter.snapshot": data])
            } catch {
                LLog.error("watch", "push failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeComplication(_ data: Data?) {
        guard let data,
              let defaults = UserDefaults(suiteName: Self.appGroupSuite)
        else { return }
        defaults.set(data, forKey: Self.complicationSnapshotKey)

        #if canImport(WidgetKit)
        for kind in Self.complicationKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        #endif
    }

    // MARK: - Inbound

    /// Called by the `WCSessionDelegate` proxy on the main actor.
    /// Returns a reply payload (`{ok, error?, ...}`) that the delegate
    /// forwards back through `replyHandler`. Returning `nil` means there's
    /// no specific result for this kind — the delegate will reply with a
    /// generic ack.
    func handleInbound(_ message: [String: Any]) async -> [String: Any]? {
        guard let kind = message["kind"] as? String else {
            return nil
        }
        switch kind {
        case "approval.decision":
            return await handleApprovalDecision(message)

        case "prompt.send":
            return await handlePromptSend(message)

        case "snapshot.request":
            lastPushedPayload = nil
            lastPushedComplication = nil
            pushIfChanged()
            return ["ok": true]

        case "voice.start":
            return await handleVoiceStart(message)

        case "voice.stop":
            return await handleVoiceStop()

        case "voice.toggleMute":
            return await handleVoiceToggleMute()

        case "voice.bargeIn":
            return await handleVoiceBargeIn()

        default:
            return nil
        }
    }

    // MARK: Inbound — approvals

    private func handleApprovalDecision(_ message: [String: Any]) async -> [String: Any] {
        guard
            let requestId = message["requestId"] as? String,
            let approve = message["approve"] as? Bool
        else {
            return ["ok": false, "error": "invalid approval payload"]
        }
        do {
            try await AppModel.shared.store.respondToApproval(
                requestId: requestId,
                decision: approve ? .accept : .decline
            )
            return ["ok": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    // MARK: Inbound — prompt

    private func handlePromptSend(_ message: [String: Any]) async -> [String: Any] {
        guard let text = (message["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return ["ok": false, "error": "empty prompt"]
        }
        let serverId = (message["serverId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let threadId = (message["threadId"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // 1) explicit (serverId, threadId) — drop on that thread if known.
        if let serverId, let threadId {
            let key = ThreadKey(serverId: serverId, threadId: threadId)
            if AppModel.shared.snapshot?.sessionSummaries.contains(where: { $0.key == key }) == true ||
               AppModel.shared.snapshot?.threads.contains(where: { $0.key == key }) == true {
                AppModel.shared.queueComposerPrefill(threadKey: key, text: text)
                return ["ok": true, "threadId": threadId]
            }
        }

        // 2) serverId only — start a new thread on that server, prefill composer.
        if let serverId, threadId == nil {
            do {
                let cwd = preferredCwd(for: serverId)
                let request = AppThreadLaunchConfig(
                    model: nil,
                    approvalPolicy: nil,
                    sandbox: nil,
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ).threadStartRequest(
                    cwd: cwd,
                    dynamicTools: AppModel.shared.localGenerativeUiToolSpecs(for: serverId)
                )
                let key = try await AppModel.shared.client.startThread(
                    serverId: serverId,
                    params: request
                )
                AppModel.shared.store.setActiveThread(key: key)
                AppModel.shared.queueComposerPrefill(threadKey: key, text: text)
                return ["ok": true, "threadId": key.threadId]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        }

        // 3) fall back to the iOS-active thread.
        if let key = AppModel.shared.snapshot?.activeThread {
            AppModel.shared.queueComposerPrefill(threadKey: key, text: text)
            return ["ok": true, "threadId": key.threadId]
        }

        return ["ok": false, "error": "no active task"]
    }

    private func preferredCwd(for serverId: String) -> String {
        if let recent = RecentDirectoryStore.shared.recentDirectories(for: serverId, limit: 1).first {
            return recent.path
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.path ?? "/"
    }

    // MARK: Inbound — voice

    private func voiceFeatureGate() -> [String: Any]? {
        guard ExperimentalFeatures.shared.isEnabled(.realtimeVoice) else {
            return ["ok": false, "error": "realtime voice disabled"]
        }
        return nil
    }

    private func handleVoiceStart(_ message: [String: Any]) async -> [String: Any] {
        if let blocked = voiceFeatureGate() { return blocked }
        guard let serverId = (message["serverId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !serverId.isEmpty else {
            return ["ok": false, "error": "missing serverId"]
        }
        let threadId = (message["threadId"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }

        let controller = VoiceRuntimeController.shared
        controller.bind(appModel: AppModel.shared)

        do {
            if let threadId {
                let resolved = try await controller.startVoiceOnThread(
                    ThreadKey(serverId: serverId, threadId: threadId)
                )
                return ["ok": true, "threadId": resolved.threadId]
            } else {
                let cwd = preferredCwd(for: serverId)
                let resolved = try await controller.startPinnedLocalVoiceCall(
                    cwd: cwd,
                    model: nil,
                    approvalPolicy: nil,
                    sandboxMode: nil
                )
                return ["ok": true, "threadId": resolved.threadId]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func handleVoiceStop() async -> [String: Any] {
        if let blocked = voiceFeatureGate() { return blocked }
        await VoiceRuntimeController.shared.stopActiveVoiceSession()
        return ["ok": true]
    }

    private func handleVoiceToggleMute() async -> [String: Any] {
        if let blocked = voiceFeatureGate() { return blocked }
        let controller = VoiceRuntimeController.shared
        guard controller.activeVoiceSession != nil else {
            return ["ok": false, "error": "no active voice session"]
        }
        controller.setMicrophoneMuted(!controller.isMicrophoneMuted)
        // Force a fresh push so the watch's `WatchVoiceState.isMuted`
        // reflects the new state on the next pump.
        lastPushedPayload = nil
        pushIfChanged()
        return ["ok": true, "isMuted": controller.isMicrophoneMuted]
    }

    private func handleVoiceBargeIn() async -> [String: Any] {
        // Same situation as mute: there's no client-side cancel-response
        // entry point yet. Reply with an error so the watch UI can hide the
        // affordance.
        return [
            "ok": false,
            "error": "barge-in not yet wired into iOS realtime session",
        ]
    }
}

/// WCSessionDelegate proxy. Declared as a separate class so the bridge can
/// own a single activation + delegate lifecycle.
final class WatchCompanionSessionDelegate: NSObject, WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        // Bail unless the session actually came up clean. `inactive` and
        // `notActivated` show up during a watch app reinstall or pairing
        // change; firing a re-push then would race against an unsettled
        // session and either drop on the floor or surface an error.
        guard state == .activated, error == nil else { return }
        Task { @MainActor in
            // On activation, re-push so the watch gets current state.
            _ = await WatchCompanionBridge.shared.handleInbound(["kind": "snapshot.request"])
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            _ = await WatchCompanionBridge.shared.handleInbound(["kind": "snapshot.request"])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            _ = await WatchCompanionBridge.shared.handleInbound(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            let reply = await WatchCompanionBridge.shared.handleInbound(message)
            replyHandler(reply ?? ["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            _ = await WatchCompanionBridge.shared.handleInbound(userInfo)
        }
    }
}
