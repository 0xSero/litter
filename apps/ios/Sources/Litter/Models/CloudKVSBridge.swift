import Foundation

/// iCloud KVS settings sync. Subscribes to
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` for inbound
/// updates from other devices, observes a small set of UserDefaults keys
/// for outbound updates, and delegates the merge envelope + last-write-wins
/// policy to the shared Rust `cloud_sync` module.
///
/// The Rust side is the source of truth for the syncable key list (see
/// `cloudSyncPlatformKeys()`) and for `mobile_prefs.json`. Swift only owns
/// the Apple platform glue: NSUbiquitousKeyValueStore, UserDefaults
/// observation, and a small per-device identifier persisted alongside other
/// preferences.
@MainActor
final class CloudKVSBridge {
    static let shared = CloudKVSBridge()

    /// CBOR envelope written to KVS under this key.
    private static let envelopeKey = "litter.cloud_sync_envelope_v1"
    /// Locally-persisted device identifier for `source_device` tagging in
    /// the envelope. Stable across launches but not synced.
    private static let deviceIdKey = "litter.cloud_sync_device_id"
    /// Debounce window for outbound writes to avoid storm-writing KVS on
    /// rapid local changes.
    private static let debounceInterval: TimeInterval = 0.5

    private let store = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private let preferencesDirectory: String
    private let deviceId: String
    private var observers: [NSObjectProtocol] = []
    private var defaultsObservers: [DefaultsObserver] = []
    private var pendingExportTask: Task<Void, Never>?
    private var lastAppliedEnvelopeHash: Int?
    /// Set while we're applying a remote envelope so the UserDefaults
    /// writebacks we perform do not feed back into another export.
    private var isApplyingRemoteUpdate = false
    private var started = false

    private init() {
        self.preferencesDirectory = MobilePreferencesDirectory.path
        self.deviceId = Self.resolveDeviceId(defaults: .standard)
    }

    /// Wire up KVS + UserDefaults observation. Idempotent. Call from app
    /// launch.
    func start() {
        guard !started else { return }
        started = true

        // Inbound: another device pushed an envelope.
        let externalChange = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleExternalChange(notification: notification)
            }
        }
        observers.append(externalChange)

        // Outbound: observe each Swift-owned UserDefaults key. The list
        // comes from Rust so both platforms agree on the exact set.
        for key in cloudSyncPlatformKeys() {
            let observer = DefaultsObserver(key: key) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleLocalDefaultsChange(key: key)
                }
            }
            defaultsObservers.append(observer)
        }

        // Pull whatever is currently in KVS (in case we missed external
        // notifications while the app was suspended) and kick off an
        // initial sync.
        store.synchronize()
        applyEnvelopeFromStore()
        scheduleExport()
    }

    /// Notify the bridge that a Rust-owned preference (pinned/hidden
    /// threads, home selection) just changed locally — we need to push the
    /// new state to KVS. Call this from the existing `SavedThreadsStore` /
    /// `SavedProjectStore` mutation paths.
    func notifyRustPreferencesChanged() {
        scheduleExport()
    }

    // MARK: - Inbound

    private func handleExternalChange(notification: Notification) {
        let reasonRaw = notification
            .userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        if let reasonRaw {
            // 0 = ServerChange, 1 = InitialSyncChange, 2 = QuotaViolationChange,
            // 3 = AccountChange. We treat all as "re-pull and merge".
            LLog.info(
                "cloud_sync",
                "kvs external change",
                fields: ["reason": reasonRaw]
            )
        }
        applyEnvelopeFromStore()
    }

    private func applyEnvelopeFromStore() {
        guard let bytes = store.data(forKey: Self.envelopeKey) else {
            return
        }
        let hash = bytes.hashValue
        if hash == lastAppliedEnvelopeHash {
            return
        }
        do {
            let writebacks = try cloudSyncApplySnapshot(
                directory: preferencesDirectory,
                bytes: bytes
            )
            applyWritebacks(writebacks)
            lastAppliedEnvelopeHash = hash
            NotificationCenter.default.post(name: .litterThreadPreferencesDidChange, object: nil)
        } catch {
            LLog.warn(
                "cloud_sync",
                "apply snapshot failed",
                fields: ["error": String(describing: error)]
            )
        }
    }

    private func applyWritebacks(_ writebacks: [PlatformWriteback]) {
        guard !writebacks.isEmpty else { return }
        isApplyingRemoteUpdate = true
        defer { isApplyingRemoteUpdate = false }

        for writeback in writebacks {
            guard let data = writeback.valueJson.data(using: .utf8) else { continue }
            let value: Any?
            do {
                value = try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            } catch {
                LLog.warn(
                    "cloud_sync",
                    "writeback decode failed",
                    fields: ["key": writeback.key, "error": error.localizedDescription]
                )
                continue
            }

            if value is NSNull {
                defaults.removeObject(forKey: writeback.key)
            } else {
                defaults.set(value, forKey: writeback.key)
            }
        }
    }

    // MARK: - Outbound

    private func handleLocalDefaultsChange(key: String) {
        guard !isApplyingRemoteUpdate else { return }
        let value = defaults.object(forKey: key)
        let valueJson: String
        if let value, !(value is NSNull) {
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed]
                )
                valueJson = String(data: data, encoding: .utf8) ?? "null"
            } catch {
                LLog.warn(
                    "cloud_sync",
                    "encode defaults change failed",
                    fields: ["key": key, "error": error.localizedDescription]
                )
                return
            }
        } else {
            valueJson = "null"
        }

        do {
            try cloudSyncUpdatePlatformValue(key: key, valueJson: valueJson)
        } catch {
            LLog.warn(
                "cloud_sync",
                "rust update_platform_value failed",
                fields: ["key": key, "error": String(describing: error)]
            )
            return
        }

        scheduleExport()
    }

    private func scheduleExport() {
        pendingExportTask?.cancel()
        pendingExportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.exportNow()
        }
    }

    /// Builds the envelope (file read + CBOR encode in Rust) off the main
    /// actor; only the KVS write and hash bookkeeping hop back to main.
    private func exportNow() async {
        let directory = preferencesDirectory
        let deviceId = deviceId
        do {
            let bytes = try await Task.detached(priority: .utility) {
                try cloudSyncExportSnapshot(directory: directory, deviceId: deviceId)
            }.value
            guard !Task.isCancelled else { return }
            // Avoid bouncing our own writes back through external-change
            // notifications: track the hash of what we just pushed.
            lastAppliedEnvelopeHash = bytes.hashValue
            store.set(bytes, forKey: Self.envelopeKey)
            store.synchronize()
        } catch {
            LLog.warn(
                "cloud_sync",
                "export snapshot failed",
                fields: ["error": String(describing: error)]
            )
        }
    }

    // MARK: - Device id

    private static func resolveDeviceId(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdKey)
        return fresh
    }
}

/// KVO-style helper around `UserDefaults.standard` that ignores the value
/// payload (we re-read on every change to avoid Foundation-level coercion
/// surprises). Lives only as long as the owning array entry.
private final class DefaultsObserver: NSObject, @unchecked Sendable {
    private let key: String
    private let onChange: () -> Void

    init(key: String, onChange: @escaping () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(
            self,
            forKeyPath: key,
            options: [.new],
            context: nil
        )
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key, context: nil)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == key else { return }
        onChange()
    }
}
