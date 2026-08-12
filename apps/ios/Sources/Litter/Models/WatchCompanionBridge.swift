import Foundation
import UserNotifications
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
    // Per-server complication slices keyed by serverId — read by the
    // widget configuration intent when the user has pinned a complication
    // to a single server (Task #7).
    private static let perServerComplicationKey = "complication.per-server.v1"
    // Connected-server picker list populated by `ServerEntityQuery` so the
    // watch face edit sheet can show real servers.
    private static let serverListKey = "servers.v1"
    private static let complicationKinds = [
        "LitterCircularComplication",
        "LitterCornerComplication",
        "LitterRectangularComplication",
    ]

    private let delegate = WatchCompanionSessionDelegate()
    private var lastPushedPayload: WatchSnapshotPayload?
    private var lastPushedComplication: Data?
    private var pushThrottle: Task<Void, Never>?
    private var themeObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    /// Request ids the bridge has already scheduled an approval push for.
    /// Used to avoid duplicate banners when the snapshot tracker re-fires for
    /// unrelated mutations.
    private var notifiedApprovalIds: Set<String> = []

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
        observeThemeChanges()
        observeHomePreferencesChanges()
    }

    /// Pin/hide changes don't mutate `AppModel.snapshot` so the snapshot
    /// observation tracker won't notice them. Fire a re-push whenever the
    /// SavedThreadsStore notifies preferences changed (CloudKV sync, local
    /// pin/hide actions, watch-originated hide).
    private func observeHomePreferencesChanges() {
        guard preferencesObserver == nil else { return }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .litterThreadPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastPushedPayload = nil
                self.lastPushedComplication = nil
                self.pushIfChanged()
            }
        }
    }

    /// Theme changes don't touch `AppModel.snapshot`, so the observation
    /// tracker above won't fire. Listen for `.themeDidChange` and force a
    /// re-push by clearing the diff state, then go through the same throttle
    /// path the snapshot pump uses.
    private func observeThemeChanges() {
        guard themeObserver == nil else { return }
        themeObserver = NotificationCenter.default.addObserver(
            forName: .themeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastPushedPayload = nil
                self.pushIfChanged()
            }
        }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
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
            push(payload: payload)
        }

        if complication != lastPushedComplication {
            lastPushedComplication = complication
            writeComplication(complication)
        }

        // Per-server complication slices + server picker list. These power
        // the watch face configuration intent (Task #7). They're cheap to
        // compute and small, so just re-publish on every change rather
        // than diffing — keeps the bridge state surface from growing.
        writePerServerComplicationSnapshots()
        writeServerListPayload()

        scheduleApprovalNotificationsIfNeeded()
    }

    // MARK: - Approval notifications

    /// Diff the current pending approvals against `notifiedApprovalIds`. For
    /// every newly arrived approval, schedule a local push with Allow/Deny
    /// inline actions so the watch can surface them on the long-look.
    private func scheduleApprovalNotificationsIfNeeded() {
        let pending = AppModel.shared.snapshot?.pendingApprovals ?? []
        let summaries = AppModel.shared.snapshot?.sessionSummaries ?? []
        let summaryByKey = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.key, $0) }
        )
        let currentIds = Set(pending.map(\.id))

        for approval in pending where !notifiedApprovalIds.contains(approval.id) {
            // Skip mcp elicitations — same rule as the home projection.
            guard approval.kind != .mcpElicitation else { continue }
            let summary: AppSessionSummary? = approval.threadId.flatMap {
                summaryByKey[ThreadKey(serverId: approval.serverId, threadId: $0)]
            }
            let serverName = summary?.serverDisplayName ?? approval.serverId
            let threadTitle = summary?.title.isEmpty == false ? summary?.title : nil
            let request = Self.makeApprovalNotificationRequest(
                approval: approval,
                serverName: serverName,
                threadTitle: threadTitle
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    LLog.error(
                        "watch",
                        "approval notification add failed: \(error.localizedDescription)"
                    )
                }
            }
            notifiedApprovalIds.insert(approval.id)
        }

        // Drop ids for approvals that are no longer pending so the set can't
        // grow without bound and so a re-issued id (rare, but possible after
        // a reconnect) re-notifies.
        notifiedApprovalIds.formIntersection(currentIds)
    }

    /// Build the `UNNotificationRequest` for an approval. Exposed as a static
    /// pure function so tests can assert the wire-format without standing up
    /// a notification center.
    static func makeApprovalNotificationRequest(
        approval: PendingApproval,
        serverName: String,
        threadTitle: String?
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Approval needed"
        content.subtitle = serverName
        content.body = approvalBody(approval: approval, threadTitle: threadTitle)
        content.sound = .default
        content.categoryIdentifier = WatchApprovalNotification.categoryIdentifier
        // Grouping by server keeps multiple pending approvals stacked under
        // a single watch banner instead of fragmenting per-thread.
        content.threadIdentifier = approval.serverId
        var info: [String: Any] = [
            WatchApprovalNotification.requestIdKey: approval.id,
            WatchApprovalNotification.serverIdKey: approval.serverId,
        ]
        if let threadId = approval.threadId {
            info[WatchApprovalNotification.threadIdKey] = threadId
        }
        content.userInfo = info

        return UNNotificationRequest(
            identifier: "litter.approval.\(approval.id)",
            content: content,
            trigger: nil
        )
    }

    private static func approvalBody(
        approval: PendingApproval,
        threadTitle: String?
    ) -> String {
        let detail: String
        switch approval.kind {
        case .command:
            detail = approval.command ?? "Run command"
        case .fileChange:
            detail = approval.path.map { "Edit \($0)" } ?? "Apply file change"
        case .permissions:
            detail = approval.reason ?? "Grant permissions"
        case .mcpElicitation:
            detail = approval.reason ?? "Input requested"
        }
        if let threadTitle, !threadTitle.isEmpty {
            return "\(threadTitle) — \(detail)"
        }
        return detail
    }

    // MARK: - Projection

    func currentPayload() -> WatchSnapshotPayload {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []

        // Mirror what the iPhone home actually displays — pin/hide rules from
        // SavedThreadsStore. Watch home stays in sync with phone home.
        let pinned = SavedThreadsStore.pinnedKeys()
        let hidden = SavedThreadsStore.hiddenKeys()
        let visibleSummaries = WatchProjection.homeFilteredSummaries(
            summaries: summaries,
            pinned: pinned,
            hidden: hidden
        )

        let projected = WatchProjection.tasks(
            summaries: visibleSummaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )
        // In pinned mode, the iPhone home shows pins in pin order. The watch
        // overlays its status-priority sort on top (running/needsApproval
        // surface to the top of each pin group).
        let tasks = WatchProjection.applyPinOrder(projected, pinned: pinned)

        // Hidden slice: summaries whose key is in `hidden`, projected with
        // the same shape as visible tasks so the watch hidden screen can
        // render them with the same row.
        let hiddenSet = Set(hidden)
        let hiddenSummaries = summaries.filter {
            hiddenSet.contains(PinnedThreadKey(threadKey: $0.key))
        }
        let hiddenTasks = WatchProjection.tasks(
            summaries: hiddenSummaries,
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
            ),
            theme: WatchProjection.theme(from: ThemeManager.shared),
            hiddenTasks: hiddenTasks.isEmpty ? nil : hiddenTasks
        )
    }

    func currentComplicationSnapshot() -> Data? {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []
        let connectedCount = (snapshot?.servers ?? [])
            .filter { $0.transportState == .connected }.count

        // Same home-visibility filter + pin-order overlay as the WC payload —
        // hidden tasks shouldn't bleed into watch face complications either.
        let pinned = SavedThreadsStore.pinnedKeys()
        let hidden = SavedThreadsStore.hiddenKeys()
        let visibleSummaries = WatchProjection.homeFilteredSummaries(
            summaries: summaries,
            pinned: pinned,
            hidden: hidden
        )

        let projected = WatchProjection.tasks(
            summaries: visibleSummaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )
        let tasks = WatchProjection.applyPinOrder(projected, pinned: pinned)
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

    // MARK: - Per-server complication slices

    /// Build a `LitterComplicationPayload` Data slice per known server. The
    /// widget configuration intent picks the right slice when the user has
    /// pinned a complication to a single server. Servers not present in
    /// the map (or `nil` server selection) fall back to the aggregate
    /// `complication.snapshot.v1` write.
    func currentPerServerComplicationSnapshots() -> [String: Data] {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []
        let servers = snapshot?.servers ?? []

        // Same offline gate as the aggregate path — when the watch isn't
        // reachable, every server slice surfaces offline so the picker
        // selection still renders something sane.
        let offline: Bool = transport.activationState != .activated
            || !transport.isPaired
            || !transport.isWatchAppInstalled

        let pinned = SavedThreadsStore.pinnedKeys()
        let hidden = SavedThreadsStore.hiddenKeys()
        let visibleSummaries = WatchProjection.homeFilteredSummaries(
            summaries: summaries,
            pinned: pinned,
            hidden: hidden
        )
        let allTasks = WatchProjection.applyPinOrder(
            WatchProjection.tasks(
                summaries: visibleSummaries,
                threads: threads,
                pendingApprovals: pendingApprovals
            ),
            pinned: pinned
        )

        var out: [String: Data] = [:]
        for server in servers {
            let serverId = server.serverId
            let connected = server.transportState == .connected
            let serverTasks = allTasks.filter { $0.serverId == serverId }
            let runningTask = serverTasks.first { $0.status == .running }
                ?? serverTasks.first { $0.status == .needsApproval }

            let mode: LitterComplicationEntry.Mode
            let title: String
            let toolLine: String
            let progress: Double
            var taskId: String?
            var lastTurnStartMsEpoch: Int64?

            if offline {
                mode = .offline
                title = "phone unreachable"
                toolLine = "tap to open"
                progress = 0
            } else if let task = runningTask {
                mode = .running
                title = task.title
                toolLine = task.subtitle ?? "working"
                let total = max(task.steps.count, 1)
                let done = task.steps.filter({ $0.state == .done }).count
                progress = total > 0 ? Double(done) / Double(total) : 0.5
                taskId = task.id
                if task.status == .running,
                   let summary = summaries.first(where: {
                       $0.key.serverId == task.serverId && $0.key.threadId == task.threadId
                   }),
                   let started = summary.lastTurnStartMs {
                    lastTurnStartMsEpoch = started
                }
            } else if serverTasks.isEmpty {
                mode = .idle
                title = connected
                    ? "\(server.displayName) ready"
                    : "\(server.displayName) offline"
                toolLine = "tap to open"
                progress = 1
            } else {
                mode = .idle
                title = "\(serverTasks.count) task\(serverTasks.count == 1 ? "" : "s")"
                toolLine = serverTasks.first?.title ?? ""
                progress = 1
            }

            let payload = LitterComplicationPayload(
                mode: mode,
                lastTurnStartMsEpoch: lastTurnStartMsEpoch,
                taskId: taskId,
                progress: progress,
                title: title,
                toolLine: toolLine,
                // Per-server slice always reports 1 — the picker scoped to
                // a single server. The aggregate path still reports the
                // global connected count for the unselected default.
                serverCount: connected ? 1 : 0
            )
            if let data = try? JSONEncoder().encode(payload) {
                out[serverId] = data
            }
        }
        return out
    }

    /// Build the picker payload the watch face configuration intent reads.
    /// Returns every server the iOS app currently knows about, regardless
    /// of transport state — the user might want to pin a complication to a
    /// known-but-disconnected server so the slot is reserved for when it
    /// reconnects.
    func currentServerListPayload() -> LitterServerListPayload {
        let servers = (AppModel.shared.snapshot?.servers ?? []).map {
            LitterServerListPayload.Server(
                id: $0.serverId,
                displayName: $0.displayName
            )
        }
        return LitterServerListPayload(servers: servers)
    }

    private func writePerServerComplicationSnapshots() {
        let map = currentPerServerComplicationSnapshots()
        guard let defaults = UserDefaults(suiteName: Self.appGroupSuite) else { return }
        defaults.set(map, forKey: Self.perServerComplicationKey)
    }

    private func writeServerListPayload() {
        let payload = currentServerListPayload()
        guard
            let defaults = UserDefaults(suiteName: Self.appGroupSuite),
            let data = try? JSONEncoder().encode(payload)
        else { return }
        defaults.set(data, forKey: Self.serverListKey)
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
        guard transport.isPaired else { return }

        // Throttle: coalesce rapid mutations into a single
        // updateApplicationContext call. Kept at 150ms — fast enough that
        // the watch feels live, slow enough to coalesce a turn-burst.
        pushThrottle?.cancel()
        pushThrottle = Task { @MainActor [weak self, transport] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                try transport.updateApplicationContext(["litter.snapshot": data])
                self?.lastPushedPayload = payload
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

        case "home.hide":
            return handleHomeHide(message)

        case "home.unhide":
            return handleHomeUnhide(message)

        default:
            return nil
        }
    }

    // MARK: Inbound — home visibility

    private func handleHomeHide(_ message: [String: Any]) -> [String: Any] {
        guard let key = threadKey(from: message) else {
            return ["ok": false, "error": "invalid hide payload"]
        }
        SavedThreadsStore.hide(PinnedThreadKey(threadKey: key))
        // The preferences observer fires a re-push; reply immediately so the
        // watch's swipe action feels snappy.
        return ["ok": true]
    }

    private func handleHomeUnhide(_ message: [String: Any]) -> [String: Any] {
        guard let key = threadKey(from: message) else {
            return ["ok": false, "error": "invalid unhide payload"]
        }
        SavedThreadsStore.unhide(PinnedThreadKey(threadKey: key))
        return ["ok": true]
    }

    private func threadKey(from message: [String: Any]) -> ThreadKey? {
        guard
            let serverId = (message["serverId"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
            let threadId = (message["threadId"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
        else { return nil }
        return ThreadKey(serverId: serverId, threadId: threadId)
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
                // Pin so the thread shows on the (pinned-only) home — same
                // behavior as the iPhone home composer, voice, and sessions
                // start-thread paths.
                SavedThreadsStore.add(PinnedThreadKey(threadKey: key))
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
