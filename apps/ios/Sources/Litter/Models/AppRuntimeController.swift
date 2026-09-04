import Foundation
import Observation

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var voiceRuntime: VoiceRuntimeController?
    @ObservationIgnored private let lifecycle = AppLifecycleController()
    @ObservationIgnored private let liveActivities = TurnLiveActivityController()
    @ObservationIgnored private let reachability = NetworkReachabilityObserver()
    @ObservationIgnored private var pendingLiveActivitySync = false
    @ObservationIgnored private var lastLiveActivitySyncTime: CFAbsoluteTime = 0

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        self.appModel = appModel
        self.voiceRuntime = voiceRuntime
        lifecycle.requestNotificationPermissionIfNeeded()
        reachability.bind(appModel: appModel)
        reachability.start()
        loadAndPushAlleycatSecretKey(client: appModel.client)
    }

    /// Load the persisted iroh device secret key from the keychain (if
    /// any) and push it to the Rust client BEFORE any alleycat
    /// operation triggers the endpoint bind. After the first bind, the
    /// Rust side may have generated a fresh key — observe via
    /// `persistAlleycatSecretKeyIfNeeded`. Together these maintain a
    /// stable `EndpointId` across cold launches.
    private func loadAndPushAlleycatSecretKey(client: AppClient) {
        do {
            if let bytes = try AlleycatCredentialStore.shared.loadDeviceSecretKey() {
                client.setAlleycatSecretKey(secretKeyBytes: bytes)
                LLog.info("alleycat", "loaded persisted device secret key from keychain")
            }
        } catch {
            LLog.error("alleycat", "failed to load device secret key", error: error)
        }
    }

    /// After an alleycat operation has triggered the Rust endpoint
    /// bind, read back the actually-used bytes and persist them so the
    /// next cold launch reuses the same `EndpointId`. Idempotent — safe
    /// to call any time; if the bind hasn't happened yet, returns
    /// silently.
    func persistAlleycatSecretKeyIfNeeded() {
        guard let appModel else { return }
        guard let data = appModel.client.alleycatSecretKey() else { return }
        do {
            let existing = try AlleycatCredentialStore.shared.loadDeviceSecretKey()
            if existing == data { return }
            try AlleycatCredentialStore.shared.saveDeviceSecretKey(data)
            LLog.info("alleycat", "persisted device secret key to keychain")
        } catch {
            LLog.error("alleycat", "failed to persist device secret key", error: error)
        }
    }

    /// Best-effort graceful shutdown of the iroh endpoint. Wired from
    /// `applicationWillTerminate` (UIKit) — see comment on that hook
    /// in LitterApp.swift for reliability caveats. iroh sends a clean
    /// CONNECTION_CLOSE to peers instead of logging "Aborting
    /// ungracefully" when the static MobileClient slot is finally
    /// dropped at process exit.
    func shutdownAlleycatEndpoint() async {
        guard let appModel else { return }
        await appModel.client.shutdownAlleycatEndpoint()
    }

    func setDevicePushToken(_ token: Data) {
        lifecycle.setDevicePushToken(token)
    }

    func reconnectSavedServers() async {
        guard let appModel else { return }
        await lifecycle.reconnectSavedServers(appModel: appModel)
    }

    func reconnectServer(serverId: String) async -> String? {
        guard let appModel else { return nil }
        return await lifecycle.reconnectServer(serverId: serverId, appModel: appModel)
    }

    func replaceSshHostKey(serverId: String, fingerprint: String) async {
        guard let appModel else { return }
        await lifecycle.replaceSshHostKey(serverId: serverId, fingerprint: fingerprint, appModel: appModel)
    }

    func restoreMissingLocalAuthStateIfNeeded() async {
        guard let appModel else { return }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
    }

    func openThreadFromNotification(key: ThreadKey) async {
        guard let appModel else { return }
        LLog.info(
            "push",
            "runtime opening thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        lifecycle.markThreadOpenedFromNotification(key)
        appModel.activateThread(key)

        if let resolvedKey = await appModel.ensureThreadLoaded(key: key) {
            lifecycle.markThreadOpenedFromNotification(resolvedKey)
            LLog.info(
                "push",
                "notification thread resolved and activated",
                fields: ["serverId": resolvedKey.serverId, "threadId": resolvedKey.threadId]
            )
            appModel.activateThread(resolvedKey)
            await appModel.refreshThreadSnapshot(key: resolvedKey)
        } else {
            LLog.warn(
                "push",
                "notification thread could not be resolved",
                fields: ["serverId": key.serverId, "threadId": key.threadId]
            )
        }
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        syncLiveActivitiesIfNeeded(snapshot: snapshot)
    }

    /// Called from `.onChange(of: appModel.snapshotRevision)` so the
    /// top-level view body never reads `appModel.snapshot` directly (which
    /// would re-render the whole shell per streaming token). The revision
    /// change is the same signal; we just fetch the snapshot here instead.
    func handleSnapshotRevisionChange() {
        syncLiveActivitiesIfNeeded(snapshot: appModel?.snapshot)
    }

    private func syncLiveActivitiesIfNeeded(snapshot: AppSnapshotRecord?) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastLiveActivitySyncTime
        if elapsed >= 3.0 {
            lastLiveActivitySyncTime = now
            liveActivities.sync(snapshot)
        } else if !pendingLiveActivitySync {
            pendingLiveActivitySync = true
            let delay = 3.0 - elapsed
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pendingLiveActivitySync = false
                self.lastLiveActivitySyncTime = CFAbsoluteTimeGetCurrent()
                self.liveActivities.sync(self.appModel?.snapshot)
            }
        }
    }

    func appDidEnterBackground() {
        guard let appModel else { return }
        appModel.reconnectController.onAppEnteredBackground()
        lifecycle.appDidEnterBackground(
            snapshot: appModel.snapshot,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func appDidBecomeInactive() {
        guard let appModel else { return }
        appModel.reconnectController.onAppBecameInactive()
    }

    func appDidBecomeActive() {
        guard let appModel else { return }
        // Keep lifecycle state in sync even when foreground recovery exits early
        // for an already-running voice session.
        appModel.reconnectController.noteAppBecameActive()
        lifecycle.appDidBecomeActive(
            appModel: appModel,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func handleBackgroundPush() async {
        guard let appModel else { return }
        LLog.info("push", "runtime handling background push")
        await lifecycle.handleBackgroundPush(
            appModel: appModel,
            liveActivities: liveActivities
        )
        LLog.info("push", "runtime finished background push")
    }
}
