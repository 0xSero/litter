import Foundation
import Observation

/// Generated UniFFI records don't carry Swift-only conformances. Lifting
/// `SavedApp` to `Identifiable` lets SwiftUI `.sheet(item:)`/`ForEach` use
/// its UUIDv4 as the stable identity.
extension SavedApp: Identifiable {}

/// Lightweight shared navigation signal that various surfaces emit and
/// the root navigation observes. `pendingOpenAppId` opens a saved-app
/// detail; `pendingConversationThreadId` pops back and pushes the origin
/// conversation (used by the "View Conversation" button on the detail view).
@MainActor
@Observable
final class SavedAppsNavigation {
    static let shared = SavedAppsNavigation()

    private(set) var pendingOpenAppId: String?
    private(set) var pendingConversationThreadId: String?

    private init() {}

    func requestOpen(appId: String) {
        pendingOpenAppId = appId
    }

    func consumeRequest() -> String? {
        let id = pendingOpenAppId
        pendingOpenAppId = nil
        return id
    }

    func requestConversation(threadId: String) {
        pendingConversationThreadId = threadId
    }

    func consumeConversationRequest() -> String? {
        let id = pendingConversationThreadId
        pendingConversationThreadId = nil
        return id
    }
}

/// Thin Swift wrapper around the Rust `saved_app_*` functions. Rust owns the
/// on-disk format (split `saved_apps.json` index + per-app html/state files)
/// and the `update_saved_app` orchestration; Swift just picks the directory
/// and exposes an observable, Swift-shaped API to the rest of the app.
///
/// Mutations that change metadata (`promote`, `rename`, `delete`,
/// `replaceHtml`) tickle the iCloud KVS bridge via
/// `notifyRustPreferencesChanged()`. State saves do not — the inner
/// `state_json` blob is intentionally kept out of the small KVS envelope.
@MainActor
@Observable
final class SavedAppsStore {
    static let shared = SavedAppsStore()

    private(set) var apps: [SavedApp] = []

    @ObservationIgnored private let directory: String = SavedAppsDirectory.path
    @ObservationIgnored private var saveStateDebouncers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingStateSaves: [String: PendingStateSave] = [:]

    private struct PendingStateSave {
        let stateJson: String
        let schemaVersion: UInt32
    }

    private init() {
        reload()
    }

    // MARK: - Metadata

    func reload() {
        apps = savedAppsList(directory: directory).apps
    }

    func app(id: String) -> SavedApp? {
        apps.first(where: { $0.id == id })
    }

    /// Slug → SavedApp resolution within the given origin thread. If `threadId`
    /// is nil, falls back to any app matching the slug (for legacy widgets
    /// surfaced without a known origin).
    func app(slug: String, threadId: String?) -> SavedApp? {
        if let threadId {
            if let match = apps.first(where: { $0.appId == slug && $0.originThreadId == threadId }) {
                return match
            }
        }
        return apps.first(where: { $0.appId == slug })
    }

    func getWithPayload(id: String) -> SavedAppWithPayload? {
        savedAppGet(directory: directory, appId: id)
    }

    @discardableResult
    func promote(
        title: String,
        widgetHTML: String,
        width: Double,
        height: Double,
        originThreadId: String?
    ) throws -> SavedApp {
        let app = try savedAppPromote(
            directory: directory,
            title: title,
            widgetHtml: widgetHTML,
            width: width,
            height: height,
            originThreadId: originThreadId
        )
        reload()
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
        return app
    }

    @discardableResult
    func rename(id: String, title: String) throws -> SavedApp {
        let app = try savedAppRename(directory: directory, appId: id, title: title)
        reload()
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
        return app
    }

    func delete(id: String) throws {
        try savedAppDelete(directory: directory, appId: id)
        // Drop any in-flight debounced save for this app.
        saveStateDebouncers.removeValue(forKey: id)?.cancel()
        pendingStateSaves.removeValue(forKey: id)
        reload()
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
    }

    // MARK: - State (debounced)

    /// Debounced per-app_id state save. Coalesces bursts (e.g. from a
    /// dragging slider) into one write on a 250 ms trailing edge. Errors
    /// from the Rust layer (including `SavedAppError.StateTooLarge`) are
    /// logged and swallowed — the app keeps working; the oversized save
    /// is just rejected.
    func saveState(id: String, stateJson: String, schemaVersion: UInt32) {
        pendingStateSaves[id] = PendingStateSave(
            stateJson: stateJson,
            schemaVersion: schemaVersion
        )
        saveStateDebouncers[id]?.cancel()
        saveStateDebouncers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushStateSave(id: id)
        }
    }

    private func flushStateSave(id: String) {
        guard let pending = pendingStateSaves.removeValue(forKey: id) else { return }
        saveStateDebouncers.removeValue(forKey: id)
        do {
            _ = try savedAppSaveState(
                directory: directory,
                appId: id,
                stateJson: pending.stateJson,
                schemaVersion: pending.schemaVersion
            )
        } catch {
            LLog.warn(
                "saved_apps",
                "save_state failed",
                fields: ["app_id": id, "error": String(describing: error)]
            )
        }
    }

    // MARK: - Update flow

    enum UpdateError: Error, LocalizedError {
        case rustError(String)

        var errorDescription: String? {
            switch self {
            case .rustError(let message): return message
            }
        }
    }

    /// Ask the shared Rust client to regenerate this saved app's HTML using
    /// the active server. Rust internally inherits the origin thread's
    /// model / reasoning settings when that thread is still known to the
    /// store. When those settings are missing, Rust falls back to
    /// gpt-5.3-codex-spark, low reasoning, and fast service tier. It also
    /// forces full-access permissions for the edit. Returns the refreshed
    /// `SavedApp` metadata on success; throws
    /// `UpdateError.rustError` on failure.
    func requestUpdate(id: String, serverId: String, prompt: String) async throws -> SavedApp {
        let result = await AppModel.shared.client.updateSavedApp(
            serverId: serverId,
            directory: directory,
            appId: id,
            userPrompt: prompt
        )
        switch result {
        case .success(let app):
            reload()
            CloudKVSBridge.shared.notifyRustPreferencesChanged()
            return app
        case .error(let message):
            throw UpdateError.rustError(message)
        }
    }
}
