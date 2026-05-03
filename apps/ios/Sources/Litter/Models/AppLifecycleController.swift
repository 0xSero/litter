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
        let results = await appModel.reconnectController.reconnectSavedServers()
        await appModel.refreshSnapshot()
        for result in results where result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: result.serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
        await appModel.refreshSnapshot()
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

        await reconnectSavedServers(appModel: appModel)
        let reloadKeys = keys.filter { !shouldTrustLiveThreadState(for: $0, appModel: appModel) }
        if !reloadKeys.isEmpty {
            await refreshTrackedThreads(appModel: appModel, keys: Array(reloadKeys))
        } else {
            LLog.info(
                "push",
                "background push skipped tracked thread reload because live IPC state is recent",
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
    }

    func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
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
                $0.serverId == key.serverId && $0.threadId == key.threadId
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
            await refreshTrackedThreads(appModel: appModel, keys: Array(reloadKeys))
            guard !Task.isCancelled else { return }
        } else if !keysToRefresh.isEmpty {
            LLog.info(
                "lifecycle",
                "performForegroundRecovery skipped thread reloads because live IPC state is already current",
                fields: ["refreshKeys": Array(keysToRefresh).map(\.debugLabel)]
            )
        }

        liveActivities.sync(appModel.snapshot)
        LLog.info("lifecycle", "performForegroundRecovery completed")
    }

    private func refreshTrackedThreads(appModel: AppModel, keys: [ThreadKey]) async {
        guard !keys.isEmpty else { return }
        let signpostID = OSSignpostID(log: appLifecycleSignpostLog)
        os_signpost(.begin, log: appLifecycleSignpostLog, name: "RefreshTrackedThreads", signpostID: signpostID)
        defer { os_signpost(.end, log: appLifecycleSignpostLog, name: "RefreshTrackedThreads", signpostID: signpostID) }
        LLog.info(
            "lifecycle",
            "refreshTrackedThreads started",
            fields: ["keys": keys.map(\.debugLabel)]
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
            await reloadTrackedThread(appModel: appModel, key: firstKey)
        }

        let remainingKeys = Array(orderedKeys.dropFirst())
        let serverIds = Set(remainingKeys.map(\.serverId))
        for serverId in serverIds {
            LLog.info("lifecycle", "refreshTrackedThreads listing threads", fields: ["serverId": serverId])
            do {
                _ = try await appModel.client.listThreads(
                    serverId: serverId,
                    params: AppListThreadsRequest(
                        cursor: nil,
                        limit: nil,
                        archived: nil,
                        cwd: nil,
                        searchTerm: nil
                    )
                )
                LLog.info("lifecycle", "refreshTrackedThreads listThreads completed", fields: ["serverId": serverId])
            } catch {
                LLog.error(
                    "lifecycle",
                    "refreshTrackedThreads listThreads failed",
                    error: error,
                    fields: ["serverId": serverId]
                )
            }
        }

        for key in remainingKeys {
            await reloadTrackedThread(appModel: appModel, key: key)
        }
        LLog.info("lifecycle", "refreshTrackedThreads completed", fields: ["keyCount": keys.count])
    }

    private func reloadTrackedThread(appModel: AppModel, key: ThreadKey) async {
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
        // IPC-vs-direct routing is now handled in Rust. Always refresh —
        // Rust's external_resume_thread will no-op if IPC data is already fresh.
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
