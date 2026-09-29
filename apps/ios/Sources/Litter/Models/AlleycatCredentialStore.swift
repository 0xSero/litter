import Foundation
import Security

enum AlleycatCredentialStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode Alleycat token"
        case .decodingFailed:
            return "Failed to decode saved Alleycat token"
        case .keychain(let status):
            return "Keychain error (\(status))"
        }
    }
}

final class AlleycatCredentialStore {
    static let shared = AlleycatCredentialStore()

    private let service = "com.alleycat.token"

    private init() {}

    /// Tokens are read on every reconnect for every Kittylitter computer;
    /// keep them in memory after the first Keychain hit.
    private let cacheLock = NSLock()
    private var tokenCache: [String: String] = [:]

    func loadToken(nodeId: String) throws -> String? {
        let key = normalizedNodeId(nodeId)
        cacheLock.lock()
        let cached = tokenCache[key]
        cacheLock.unlock()
        if let cached { return cached }

        // Match device-only and iCloud items: a pre-release build could move
        // tokens to iCloud Keychain, and those must still be found.
        let query = baseQuery(nodeId: nodeId).merging([
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let data = attributes[kSecValueData as String] as? Data,
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw AlleycatCredentialStoreError.decodingFailed
            }
            if (attributes[kSecAttrSynchronizable as String] as? Bool) == true {
                moveToDeviceOnly(token, nodeId: nodeId)
            }
            cacheLock.lock()
            tokenCache[key] = token
            cacheLock.unlock()
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw AlleycatCredentialStoreError.keychain(status)
        }
    }

    /// Tokens are device-only: `AfterFirstUnlockThisDeviceOnly`, never
    /// synchronizable. Adds the item, or updates it in place if it exists,
    /// so a failed write never removes a working token.
    func saveToken(_ token: String, nodeId: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw AlleycatCredentialStoreError.encodingFailed
        }

        let query = baseQuery(nodeId: nodeId).merging([
            kSecAttrSynchronizable as String: false
        ]) { _, new in new }
        let attributes = query.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]) { _, new in new }

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw AlleycatCredentialStoreError.keychain(status)
        }
        cacheLock.lock()
        tokenCache[normalizedNodeId(nodeId)] = token
        cacheLock.unlock()
    }

    /// Moves a token that a pre-release build put in iCloud Keychain back to
    /// device-only. Writes the device-only copy first and deletes the iCloud
    /// copy only once that succeeded, so the token is never lost.
    private func moveToDeviceOnly(_ token: String, nodeId: String) {
        do {
            try saveToken(token, nodeId: nodeId)
        } catch {
            LLog.error("alleycat", "moving token to device-only keychain failed", error: error)
            return
        }
        let synced = baseQuery(nodeId: nodeId).merging([
            kSecAttrSynchronizable as String: true
        ]) { _, new in new }
        let status = SecItemDelete(synced as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            LLog.error("alleycat", "deleting iCloud keychain token failed", error: AlleycatCredentialStoreError.keychain(status))
        }
    }

    func deleteToken(nodeId: String) throws {
        cacheLock.lock()
        tokenCache[normalizedNodeId(nodeId)] = nil
        cacheLock.unlock()
        // Both the device-only item and any iCloud copy.
        let query = baseQuery(nodeId: nodeId).merging([
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]) { _, new in new }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AlleycatCredentialStoreError.keychain(status)
        }
    }

    // MARK: - iroh device secret key (one slot per device)

    private static let deviceKeyAccount = "__device_secret_key__"

    /// Load the persisted iroh device secret key bytes (32 bytes), or
    /// nil if not yet generated. Used by `AppRuntimeController` at app
    /// launch to feed the Rust client before any alleycat operation
    /// triggers the endpoint bind.
    func loadDeviceSecretKey() throws -> Data? {
        let query = deviceKeyQuery().merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw AlleycatCredentialStoreError.decodingFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw AlleycatCredentialStoreError.keychain(status)
        }
    }

    /// Persist the iroh device secret key bytes. Called once after the
    /// Rust client first generates a fresh key, so subsequent launches
    /// reuse the same `EndpointId`.
    func saveDeviceSecretKey(_ bytes: Data) throws {
        guard bytes.count == 32 else {
            throw AlleycatCredentialStoreError.encodingFailed
        }
        let query = deviceKeyQuery()
        let attributes = query.merging([
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: bytes
        ]) { _, new in new }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecValueData as String: bytes,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AlleycatCredentialStoreError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw AlleycatCredentialStoreError.keychain(status)
        }
    }

    private func deviceKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.alleycat.device_key",
            kSecAttrAccount as String: Self.deviceKeyAccount
        ]
    }

    private func baseQuery(nodeId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: normalizedNodeId(nodeId)
        ]
    }

    private func normalizedNodeId(_ nodeId: String) -> String {
        nodeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
