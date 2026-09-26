#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private let reachability = NetworkReachabilityObserver()

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        self.appModel = appModel
        reachability.bind(appModel: appModel)
        reachability.start()
        do {
            if let bytes = try AlleycatCredentialStore.shared.loadDeviceSecretKey() {
                appModel.client.setAlleycatSecretKey(secretKeyBytes: bytes)
            }
        } catch {
            NSLog("[ALLEYCAT_DEVICE_KEY] load failed: %@", error.localizedDescription)
        }
    }

    /// Catalyst-side mirror of the iOS persist hook. Called from the
    /// lifecycle stub after reconnect cycles so freshly-generated
    /// device secret keys land in the keychain.
    func persistAlleycatSecretKeyIfNeeded() {
        guard let appModel else { return }
        guard let data = appModel.client.alleycatSecretKey() else { return }
        do {
            let existing = try AlleycatCredentialStore.shared.loadDeviceSecretKey()
            if existing == data { return }
            try AlleycatCredentialStore.shared.saveDeviceSecretKey(data)
        } catch {
            NSLog("[ALLEYCAT_DEVICE_KEY] save failed: %@", error.localizedDescription)
        }
    }

    /// Best-effort graceful shutdown of the iroh endpoint. Wired from
    /// `applicationWillTerminate` on Catalyst (NSApplicationDelegate
    /// fires this reliably; iOS proper does not on swipe-up-to-kill).
    func shutdownAlleycatEndpoint() async {
        guard let appModel else { return }
        await appModel.client.shutdownAlleycatEndpoint()
    }

    func setDevicePushToken(_ token: Data) {}

    func reconnectSavedServers() async {
        guard let appModel else { return }
        let servers = SavedServerStore.reconnectRecords(
            localDisplayName: appModel.resolvedLocalServerDisplayName(),
            rememberedOnly: true
        )
        appModel.reconnectController.setMultiClankerAndQuicEnabled(enabled: true)
        appModel.reconnectController.syncSavedServers(servers: servers)
        await appModel.reconnectController.notifyNetworkChange()
        let results = await appModel.reconnectController.reconnectSavedServers()
        await appModel.refreshSnapshot()
        SavedServerReconnectState.shared.finish()
        for result in results where result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: result.serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
        await appModel.refreshSnapshot()
        persistAlleycatSecretKeyIfNeeded()
    }

    func reconnectServer(serverId: String) async {
        guard let appModel else { return }
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

    func restoreMissingLocalAuthStateIfNeeded() async {
        guard let appModel else { return }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
    }

    func openThreadFromNotification(key: ThreadKey) async {
        guard let appModel else { return }
        appModel.activateThread(key)
        await appModel.refreshSnapshot()
        if let resolvedKey = await appModel.ensureThreadLoaded(key: key) {
            appModel.activateThread(resolvedKey)
            await appModel.refreshSnapshot()
        }
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {}
    func appDidEnterBackground() {
        lastBackgroundedAt = Date()
    }
    func appDidBecomeInactive() {}

    func appDidBecomeActive() {
        guard !hasRecoveredOnForeground else { return }
        hasRecoveredOnForeground = true
        let backgroundDuration = lastBackgroundedAt.map { Date().timeIntervalSince($0) }
        lastBackgroundedAt = nil
        Task { [weak self, backgroundDuration] in
            guard let self else { return }
            // Same long-resume short-circuit as iOS: if we were
            // suspended longer than iroh's per-path idle, kill the
            // existing alleycat Connection so the worker rebuilds
            // before any user request lands.
            if let appModel = self.appModel,
               let duration = backgroundDuration,
               duration > Self.longResumeThreshold
            {
                await appModel.reconnectController.onLongResume()
            }
            await self.reconnectSavedServers()
        }
    }

    func handleBackgroundPush() async {}

    @ObservationIgnored private var hasRecoveredOnForeground = false
    @ObservationIgnored private var lastBackgroundedAt: Date?
    private static let longResumeThreshold: TimeInterval = 15
}

@MainActor
final class AppLifecycleController {
    static let notificationServerIdKey = "litter.notification.serverId"
    static let notificationThreadIdKey = "litter.notification.threadId"

    static func notificationThreadKey(from userInfo: [AnyHashable: Any]) -> ThreadKey? {
        guard let serverId = userInfo[notificationServerIdKey] as? String,
              let threadId = userInfo[notificationThreadIdKey] as? String,
              !serverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ThreadKey(serverId: serverId, threadId: threadId)
    }
}

@MainActor
@Observable
final class VoiceRuntimeController {
    static let shared = VoiceRuntimeController()
    static let localServerID = "local"
    static let persistedLocalVoiceThreadIDKey = "litter.voice.local.thread_id"

    private(set) var activeVoiceSession: VoiceSessionState?
    var handoffModel: String?
    var handoffEffort: String?
    var handoffFastMode = false

    func bind(appModel: AppModel) {}
    @discardableResult
    func startPinnedLocalVoiceCall(
        cwd: String,
        model: String?,
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) async throws -> ThreadKey {
        throw NSError(
            domain: "Litter",
            code: 9999,
            userInfo: [NSLocalizedDescriptionKey: "Voice not available on Catalyst"]
        )
    }
    func stopActiveVoiceSession() async {}
    func toggleActiveVoiceSessionSpeaker() async throws {}
}

struct VoiceSessionState: Identifiable, Equatable {
    let id: String
    let threadKey: ThreadKey
}

@MainActor
@Observable
final class StableSafeAreaInsets {
    var bottomInset: CGFloat = 0
    func start(fallback: CGFloat) {
        bottomInset = fallback
    }
}

@MainActor
final class OrientationResponder {
    static let shared = OrientationResponder()
    func start() {}
}

@MainActor
final class WatchCompanionBridge {
    static let shared = WatchCompanionBridge()
    func start() {}
}
#endif
