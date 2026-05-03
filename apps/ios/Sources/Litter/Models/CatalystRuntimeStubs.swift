#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        self.appModel = appModel
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
        let results = await appModel.reconnectController.reconnectSavedServers()
        await appModel.refreshSnapshot()
        for result in results where result.needsLocalAuthRestore {
            await appModel.restoreStoredLocalAuthState(serverId: result.serverId)
        }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
        await appModel.refreshSnapshot()
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
    func appDidEnterBackground() {}
    func appDidBecomeInactive() {}

    func appDidBecomeActive() {
        guard !hasRecoveredOnForeground else { return }
        hasRecoveredOnForeground = true
        Task { [weak self] in
            await self?.reconnectSavedServers()
        }
    }

    func handleBackgroundPush() async {}

    @ObservationIgnored private var hasRecoveredOnForeground = false
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
