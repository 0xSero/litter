import Foundation
import Observation
import UIKit
import UserNotifications
import os

private let appLifecycleSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.sigkitten.litter",
    category: "lifecycle"
)

@MainActor
final class AppLifecycleController {
    static let notificationServerIdKey = "litter.notification.serverId"
    static let notificationThreadIdKey = "litter.notification.threadId"

    struct BackgroundTurnReconciliation {
        let remainingKeys: Set<ThreadKey>
        let activeThreads: [AppThreadSnapshot]
        let completedNotificationThread: AppThreadSnapshot?
    }

    private let pushProxy = PushProxyClient()
    private var pushProxyRegistrationId: String?
    private var devicePushToken: Data?
    private var backgroundedTurnKeys: Set<ThreadKey> = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgWakeCount: Int = 0
    private var notificationPermissionRequested = false
    private var hasRecoveredCurrentForegroundSession = false
    private var hasEnteredBackgroundSinceLaunch = false
    private var foregroundRecoveryTask: Task<Void, Never>?
    private var foregroundRecoveryID: UUID?
    private var notificationActivatedThreadKey: ThreadKey?
    private var notificationActivatedAt: Date?
    /// Wall-clock timestamp of the most recent `appDidEnterBackground`.
    /// Used to decide whether the existing alleycat `Connection` is
    /// almost certainly dead by the time we resume — see
    /// `LONG_RESUME_THRESHOLD` and `on_long_resume`.
    private var lastBackgroundedAt: Date?

    /// Threshold for triggering proactive `Connection::close()` on
    /// resume. Tied to iroh's per-path idle timeout (default 15s): if
    /// we were suspended for longer than that, the existing path is
    /// almost certainly dead and waiting on iroh's connection-level
    /// 30s idle timer would make the next user request hang for the
    /// remainder of that window.
    private static let longResumeThreshold: TimeInterval = 15

    func setDevicePushToken(_ token: Data) {
        devicePushToken = token
    }

    func reconnectSavedServers(appModel: AppModel) async {
        let servers = SavedServerStore.reconnectRecords(
            localDisplayName: appModel.resolvedLocalServerDisplayName(),
            rememberedOnly: true
        )
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(servers: servers)
        // Hint iroh-backed sessions about a possible network change before
        // running reconnect — healthy alleycat sessions can recover via
        // path migration without paying the full reconnect handshake.
        await appModel.reconnectController.notifyNetworkChange()
        let results = await appModel.reconnectController.reconnectSavedServers()
        await appModel.refreshSnapshot()
        for result in results where result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: result.serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
        await appModel.refreshSnapshot()
        // If reconnecting saved alleycat servers triggered the iroh
        // endpoint bind, the Rust side may have generated a fresh
        // device secret key. Persist it so the next cold launch reuses
        // the same `EndpointId`.
        AppRuntimeController.shared.persistAlleycatSecretKeyIfNeeded()
    }

    func markThreadOpenedFromNotification(_ key: ThreadKey) {
        notificationActivatedThreadKey = key
        notificationActivatedAt = Date()
    }

    func reconnectServer(serverId: String, appModel: AppModel) async {
        let servers = SavedServerStore.reconnectRecords(
            localDisplayName: appModel.resolvedLocalServerDisplayName()
        )
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(servers: servers)
        let result = await appModel.reconnectController.reconnectServer(serverId: serverId)
        await appModel.refreshSnapshot()
        if result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
        await appModel.refreshSnapshot()
    }

    func appDidEnterBackground(
        snapshot: AppSnapshotRecord?,
        hasActiveVoiceSession: Bool,
        liveActivities: TurnLiveActivityController
    ) {
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "AppDidEnterBackground", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "AppDidEnterBackground", signpostID: signpostID) }
        hasEnteredBackgroundSinceLaunch = true
        hasRecoveredCurrentForegroundSession = false
        lastBackgroundedAt = Date()
        foregroundRecoveryTask?.cancel()
        foregroundRecoveryTask = nil
        foregroundRecoveryID = nil
        LLog.info(
            "lifecycle",
            "app did enter background",
            fields: [
                "hasActiveVoiceSession": hasActiveVoiceSession,
                "existingTrackedTurnCount": snapshot?.threadsWithTrackedTurns.count ?? 0
            ]
        )
        guard !hasActiveVoiceSession else { return }
        let activeThreads = snapshot?.threadsWithTrackedTurns ?? []
        guard !activeThreads.isEmpty else { return }

        backgroundedTurnKeys = Set(activeThreads.map(\.key))
        LLog.info(
            "lifecycle",
            "tracking background turn keys",
            fields: [
                "trackedKeys": activeThreads.map(\.key.debugLabel)
            ]
        )
        bgWakeCount = 0
        liveActivities.sync(snapshot)
        registerPushProxy()

        let bgID = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self else { return }
            let expiredID = self.backgroundTaskID
            self.backgroundTaskID = .invalid
            UIApplication.shared.endBackgroundTask(expiredID)
        }
        backgroundTaskID = bgID
    }

    func appDidBecomeActive(
        appModel: AppModel,
        hasActiveVoiceSession: Bool,
        liveActivities: TurnLiveActivityController
    ) {
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "AppDidBecomeActive", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "AppDidBecomeActive", signpostID: signpostID) }
        deregisterPushProxy()
        endBackgroundTaskIfNeeded()
        guard !hasActiveVoiceSession else { return }
        guard !hasRecoveredCurrentForegroundSession else { return }
        hasRecoveredCurrentForegroundSession = true
        let needsInitialReconnect = !hasEnteredBackgroundSinceLaunch
        let currentSnapshot = appModel.snapshot
        let backgroundedKeys = backgroundedTurnKeys
        backgroundedTurnKeys.removeAll()
        let keysToRefresh = foregroundRecoveryKeys(
            snapshot: currentSnapshot,
            backgroundedKeys: backgroundedKeys
        )
        LLog.info(
            "lifecycle",
            "app did become active",
            fields: [
                "needsInitialReconnect": needsInitialReconnect,
                "backgroundedKeyCount": backgroundedKeys.count,
                "refreshKeyCount": keysToRefresh.count,
                "refreshKeys": Array(keysToRefresh).map(\.debugLabel)
            ]
        )

        foregroundRecoveryTask?.cancel()
        let recoveryID = UUID()
        foregroundRecoveryID = recoveryID

        foregroundRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.foregroundRecoveryID == recoveryID {
                    self.foregroundRecoveryTask = nil
                    self.foregroundRecoveryID = nil
                }
            }

            await self.performForegroundRecovery(
                appModel: appModel,
                liveActivities: liveActivities,
                needsInitialReconnect: needsInitialReconnect,
                keysToRefresh: keysToRefresh
            )
        }
    }

    func handleBackgroundPush(
        appModel: AppModel,
        liveActivities: TurnLiveActivityController
    ) async {
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "HandleBackgroundPush", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "HandleBackgroundPush", signpostID: signpostID) }
        guard UIApplication.shared.applicationState != .active else {
            LLog.info("push", "skipping background push reconciliation because app is active")
            return
        }
        bgWakeCount += 1
        let keys = backgroundedTurnKeys
        LLog.info(
            "push",
            "handling background push wake",
            fields: [
                "wakeCount": bgWakeCount,
                "trackedKeyCount": keys.count,
                "trackedKeys": Array(keys).map(\.debugLabel)
            ]
        )
        guard !keys.isEmpty else { return }

        // Do NOT proactively close the alleycat Connection on every push
        // wake. The 30s push cadence matches iroh's idle window — closing
        // the connection here tears down the very transport iOS just
        // thawed us to use, costing a reconnect handshake out of our 30s
        // budget. If the path is actually dead, the next request will
        // fail and the transport's own reconnect logic will rebuild it
        // (and `connect_remote_over_alleycat` short-circuits when a
        // healthy session already exists). The longer foreground-resume
        // path still uses `onLongResume` because there iroh's per-path
        // idle has plausibly killed the path silently.
        await reconnectSavedServers(appModel: appModel)
        // refreshTrackedThreads uses the force-authoritative path so the
        // store reconciles `active_turn_id` against the server's view and
        // repairs items whose events crossed the transport while iOS was
        // suspended. On paginated remotes the resume runs with
        // `excludeTurns: true`, followed by a tiny status probe and a
        // bounded repair page for a previously active turn; on legacy
        // remotes the resume falls back to the embedded turn list. The
        // RPC also re-attaches the new `ConnectionId` to the per-thread
        // subscription set so subsequent live events route correctly.
        let reloadKeys = keys.filter { !shouldTrustLiveThreadState(for: $0, appModel: appModel) }
        if !reloadKeys.isEmpty {
            await refreshTrackedThreads(
                appModel: appModel,
                keys: Array(reloadKeys),
                forceAuthoritative: true
            )
        } else {
            LLog.info(
                "push",
                "background push skipped tracked thread reload because live state is recent",
                fields: ["trackedKeys": Array(keys).map(\.debugLabel)]
            )
        }

        guard let snapshot = appModel.snapshot else { return }
        let trustedLiveKeys = Set(keys.filter { shouldTrustLiveThreadState(for: $0, appModel: appModel) })
        let reconciliation = reconcileBackgroundedTurns(
            snapshot: snapshot,
            trackedKeys: keys,
            trustedLiveKeys: trustedLiveKeys
        )
        backgroundedTurnKeys = reconciliation.remainingKeys
        LLog.info(
            "push",
            "background push reconciliation finished",
            fields: [
                "remainingKeyCount": reconciliation.remainingKeys.count,
                "remainingKeys": Array(reconciliation.remainingKeys).map(\.debugLabel),
                "activeThreadCount": reconciliation.activeThreads.count,
                "completedNotificationThread": reconciliation.completedNotificationThread?.key.debugLabel ?? ""
            ]
        )

        for thread in reconciliation.activeThreads {
            liveActivities.updateBackgroundWake(for: thread, pushCount: bgWakeCount)
        }

        if let thread = reconciliation.completedNotificationThread {
            liveActivities.endCurrent(phase: .completed, snapshot: snapshot)
            postLocalNotificationIfNeeded(
                model: thread.resolvedModel,
                threadPreview: thread.resolvedPreview,
                threadKey: thread.key
            )
        }

        if backgroundedTurnKeys.isEmpty {
            deregisterPushProxy()
        }

        // Refresh the suspension marker so the next push wake (or
        // foreground) measures from the end of this work, not from the
        // original backgrounding. Otherwise a series of push wakes
        // during one background session would tear down healthy
        // connections every time.
        lastBackgroundedAt = Date()
    }

    func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-conversation-display") {
            notificationPermissionRequested = true
            return
        }
        #endif
        notificationPermissionRequested = true
        LLog.info("push", "requesting notification permission")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func reconcileBackgroundedTurns(
        snapshot: AppSnapshotRecord,
        trackedKeys: Set<ThreadKey>,
        trustedLiveKeys: Set<ThreadKey> = []
    ) -> BackgroundTurnReconciliation {
        var remainingKeys: Set<ThreadKey> = []
        var activeThreads: [AppThreadSnapshot] = []
        var completedThreads: [AppThreadSnapshot] = []

        for key in trackedKeys {
            guard let thread = snapshot.threadSnapshot(for: key) else {
                // Keep tracking until we can observe a definitive thread state again.
                LLog.info(
                    "push",
                    "background turn reconciliation missing thread snapshot",
                    fields: ["key": key.debugLabel]
                )
                remainingKeys.insert(key)
                continue
            }

            let hasActiveTurn = thread.hasActiveTurn
            let hasPendingApproval = snapshot.pendingApprovals.contains(where: {
                $0.serverId == key.serverId && $0.threadId == key.threadId
            })
            let hasPendingUserInput = snapshot.pendingUserInputs.contains(where: {
                $0.isRelevant(to: key)
            })
            let hasRecentLiveUpdate = trustedLiveKeys.contains(key)
            let remainsTracked = hasActiveTurn || hasPendingApproval || hasPendingUserInput || hasRecentLiveUpdate
            LLog.info(
                "push",
                "background turn reconciliation evaluated thread",
                fields: [
                    "key": key.debugLabel,
                    "hasActiveTurn": hasActiveTurn,
                    "hasPendingApproval": hasPendingApproval,
                    "hasPendingUserInput": hasPendingUserInput,
                    "hasRecentLiveUpdate": hasRecentLiveUpdate,
                    "remainsTracked": remainsTracked
                ]
            )
            if remainsTracked {
                remainingKeys.insert(key)
                activeThreads.append(thread)
            } else {
                completedThreads.append(thread)
            }
        }

        let completedNotificationThread: AppThreadSnapshot?
        if remainingKeys.isEmpty {
            completedNotificationThread = completedThreads.first(where: {
                $0.info.parentThreadId == nil
            }) ?? completedThreads.first
        } else {
            completedNotificationThread = nil
        }

        return BackgroundTurnReconciliation(
            remainingKeys: remainingKeys,
            activeThreads: activeThreads,
            completedNotificationThread: completedNotificationThread
        )
    }

    func foregroundRecoveryKeys(
        snapshot: AppSnapshotRecord?,
        backgroundedKeys: Set<ThreadKey>
    ) -> Set<ThreadKey> {
        var keys = backgroundedKeys
        if let activeKey = snapshot?.activeThread {
            keys.insert(activeKey)
        }
        return keys
    }

    private func performForegroundRecovery(
        appModel: AppModel,
        liveActivities: TurnLiveActivityController,
        needsInitialReconnect: Bool,
        keysToRefresh: Set<ThreadKey>
    ) async {
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "PerformForegroundRecovery", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "PerformForegroundRecovery", signpostID: signpostID) }
        LLog.info(
            "lifecycle",
            "performForegroundRecovery started",
            fields: [
                "needsInitialReconnect": needsInitialReconnect,
                "refreshKeyCount": keysToRefresh.count,
                "refreshKeys": Array(keysToRefresh).map(\.debugLabel)
            ]
        )
        // Always attempt to reconnect saved servers on foreground return.
        // The ReconnectController skips servers whose health != .disconnected,
        // so this is cheap when everything is still connected.
        let servers = SavedServerStore.reconnectRecords(
            localDisplayName: appModel.resolvedLocalServerDisplayName(),
            rememberedOnly: true
        )
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(servers: servers)

        // If we were suspended longer than iroh's per-path idle timeout,
        // the existing alleycat Connection is almost certainly dead. Kill
        // it before the user can issue a request — otherwise the worker's
        // first request would wait the full 30s connection-idle timeout
        // for iroh to declare the path dead. Fires BEFORE
        // `onAppBecameActive` so the close lands before the
        // network-change hint and saved-server reconnect.
        let backgroundDuration = lastBackgroundedAt.map { Date().timeIntervalSince($0) }
        if let duration = backgroundDuration, duration > Self.longResumeThreshold {
            LLog.info(
                "lifecycle",
                "long resume — abandoning live alleycat connections",
                fields: ["backgroundDurationSec": Int(duration)]
            )
            await appModel.reconnectController.onLongResume()
        }
        lastBackgroundedAt = nil

        let results = await appModel.reconnectController.onAppBecameActive()
        await appModel.refreshSnapshot()
        for result in results where result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: result.serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()

        guard !Task.isCancelled else { return }

        let trustedLiveKeys = Set(keysToRefresh.filter {
            shouldTrustLiveThreadState(for: $0, appModel: appModel, within: 4)
        })
        let notificationActivationAge = notificationActivatedAt.map { Date().timeIntervalSince($0) }
        let reloadKeys = foregroundRecoveryKeysNeedingReload(
            keysToRefresh,
            activeThread: appModel.snapshot?.activeThread,
            trustedLiveKeys: trustedLiveKeys,
            notificationActivatedKey: notificationActivatedThreadKey,
            notificationActivationAge: notificationActivationAge
        )
        if !reloadKeys.isEmpty {
            // A long iOS suspension may miss both item events and the
            // terminal turn event. Reconcile the active-turn status, then
            // repair the bounded current page so running tools and completed
            // output reappear immediately.
            await refreshTrackedThreads(
                appModel: appModel,
                keys: Array(reloadKeys),
                forceAuthoritative: true
            )
            guard !Task.isCancelled else { return }
        } else if !keysToRefresh.isEmpty {
            LLog.info(
                "lifecycle",
                "performForegroundRecovery skipped thread reloads because live state is already current",
                fields: ["refreshKeys": Array(keysToRefresh).map(\.debugLabel)]
            )
        }

        liveActivities.sync(appModel.snapshot)
        // Capture any freshly-generated alleycat device secret key from
        // this foreground's reconnect cycle.
        AppRuntimeController.shared.persistAlleycatSecretKeyIfNeeded()
        LLog.info("lifecycle", "performForegroundRecovery completed")
    }

    private func refreshTrackedThreads(
        appModel: AppModel,
        keys: [ThreadKey],
        forceAuthoritative: Bool = false
    ) async {
        guard !keys.isEmpty else { return }
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "RefreshTrackedThreads", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "RefreshTrackedThreads", signpostID: signpostID) }
        LLog.info(
            "lifecycle",
            "refreshTrackedThreads started",
            fields: [
                "keys": keys.map(\.debugLabel),
                "forceAuthoritative": forceAuthoritative
            ]
        )

        let activeKey = appModel.snapshot?.activeThread
        var orderedKeys: [ThreadKey] = []
        if let activeKey, keys.contains(activeKey) {
            orderedKeys.append(activeKey)
        }
        orderedKeys.append(contentsOf: keys.filter { key in
            guard let activeKey else { return true }
            return key != activeKey
        })

        if let firstKey = orderedKeys.first {
            await reloadTrackedThread(
                appModel: appModel,
                key: firstKey,
                forceAuthoritative: forceAuthoritative
            )
        }

        let remainingKeys = Array(orderedKeys.dropFirst())
        for key in remainingKeys {
            await reloadTrackedThread(
                appModel: appModel,
                key: key,
                forceAuthoritative: forceAuthoritative
            )
        }
        LLog.info("lifecycle", "refreshTrackedThreads completed", fields: ["keyCount": keys.count])
    }

    private func reloadTrackedThread(
        appModel: AppModel,
        key: ThreadKey,
        forceAuthoritative: Bool = false
    ) async {
        // After a long resume / push wake the locally-cached snapshot may
        // have missed `TurnCompleted` events — the in-flight turn fired
        // those while the app was frozen, no client connection was
        // attached to the per-thread subscription set, and the events
        // were dropped. The regular `reloadThread` short-circuits via
        // the direct-resume marker, so we'd keep showing the stale
        // active turn until the user manually refreshes. Force-
        // authoritative bypasses both short-circuits and feeds
        // `reconcile_active_turn` from a turn-status list (embedded on
        // legacy remotes; via a small `thread/turns/list` probe on
        // paginated remotes — see `forceRefreshThreadAuthoritative`).
        if forceAuthoritative {
            LLog.info(
                "lifecycle",
                "reloadTrackedThread started (authoritative)",
                fields: ["key": key.debugLabel]
            )
            do {
                try await appModel.forceRefreshThreadAuthoritative(key: key)
                await appModel.refreshThreadSnapshot(key: key)
                LLog.info(
                    "lifecycle",
                    "reloadTrackedThread completed (authoritative)",
                    fields: ["key": key.debugLabel]
                )
            } catch {
                LLog.error(
                    "lifecycle",
                    "reloadTrackedThread (authoritative) failed",
                    error: error,
                    fields: ["key": key.debugLabel]
                )
            }
            return
        }

        let snapshot = appModel.snapshot
        let existing = snapshot?.threadSnapshot(for: key)
        let cwd = existing?.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = AppThreadLaunchConfig(
            model: existing?.resolvedModel,
            approvalPolicy: nil,
            sandbox: nil,
            developerInstructions: nil,
            persistExtendedHistory: true
        )
        LLog.info(
            "lifecycle",
            "reloadTrackedThread started",
            fields: [
                "key": key.debugLabel,
                "cwdOverride": cwd?.isEmpty == false ? (cwd ?? "") : ""
            ]
        )
        do {
            let resolvedKey = try await appModel.reloadThread(
                key: key,
                launchConfig: config,
                cwdOverride: cwd?.isEmpty == false ? cwd : nil
            )
            await appModel.refreshThreadSnapshot(key: resolvedKey)
            LLog.info("lifecycle", "reloadTrackedThread completed", fields: ["key": key.debugLabel])
        } catch {
            LLog.error(
                "lifecycle",
                "reloadTrackedThread failed",
                error: error,
                fields: ["key": key.debugLabel]
            )
        }
    }

    private func registerPushProxy() {
        guard let tokenData = devicePushToken else { return }
        guard pushProxyRegistrationId == nil else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        LLog.info("push", "registering push proxy")
        Task {
            do {
                let regId = try await pushProxy.register(pushToken: token, interval: 30, ttl: 7200)
                await MainActor.run {
                    self.pushProxyRegistrationId = regId
                    LLog.info("push", "push proxy registered", fields: ["registrationId": regId])
                }
            } catch {
                await MainActor.run {
                    LLog.error("push", "push proxy registration failed", error: error)
                }
            }
        }
    }

    private func deregisterPushProxy() {
        guard let regId = pushProxyRegistrationId else { return }
        pushProxyRegistrationId = nil
        LLog.info("push", "deregistering push proxy", fields: ["registrationId": regId])
        Task {
            do {
                try await pushProxy.deregister(registrationId: regId)
                await MainActor.run {
                    LLog.info("push", "push proxy deregistered", fields: ["registrationId": regId])
                }
            } catch {
                await MainActor.run {
                    LLog.error(
                        "push",
                        "push proxy deregistration failed",
                        error: error,
                        fields: ["registrationId": regId]
                    )
                }
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func shouldTrustLiveThreadState(
        for key: ThreadKey,
        appModel: AppModel,
        within interval: TimeInterval = 3
    ) -> Bool {
        // Always refresh tracked threads after lifecycle transitions; Rust
        // will no-op when the state is already fresh.
        false
    }

    func foregroundRecoveryKeysNeedingReload(
        _ keys: Set<ThreadKey>,
        activeThread: ThreadKey?,
        trustedLiveKeys: Set<ThreadKey>,
        notificationActivatedKey: ThreadKey?,
        notificationActivationAge: TimeInterval?
    ) -> Set<ThreadKey> {
        keys.filter { key in
            guard trustedLiveKeys.contains(key) else { return true }
            if activeThread == key {
                return false
            }
            guard notificationActivatedKey == key,
                  let notificationActivationAge else {
                return true
            }
            return notificationActivationAge > 6
        }
    }

    static func notificationThreadKey(from userInfo: [AnyHashable: Any]) -> ThreadKey? {
        guard let serverId = userInfo[notificationServerIdKey] as? String,
              let threadId = userInfo[notificationThreadIdKey] as? String else {
            return nil
        }

        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty, !trimmedThreadId.isEmpty else { return nil }

        return ThreadKey(serverId: trimmedServerId, threadId: trimmedThreadId)
    }

    private func postLocalNotificationIfNeeded(
        model: String,
        threadPreview: String?,
        threadKey: ThreadKey
    ) {
        guard UIApplication.shared.applicationState != .active else {
            LLog.info(
                "push",
                "skipping local notification because app is active",
                fields: ["threadKey": threadKey.debugLabel]
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Turn completed"
        var bodyParts: [String] = []
        if let preview = threadPreview, !preview.isEmpty { bodyParts.append(preview) }
        if !model.isEmpty { bodyParts.append(model) }
        content.body = bodyParts.joined(separator: " - ")
        content.sound = .default
        content.categoryIdentifier = "litter.task.complete"
        content.userInfo = [
            Self.notificationServerIdKey: threadKey.serverId,
            Self.notificationThreadIdKey: threadKey.threadId
        ]
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        LLog.info(
            "push",
            "posting local completion notification",
            fields: [
                "threadKey": threadKey.debugLabel,
                "model": model,
                "hasPreview": threadPreview?.isEmpty == false
            ]
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private extension ThreadKey {
    var debugLabel: String {
        "\(serverId):\(threadId)"
    }
}
