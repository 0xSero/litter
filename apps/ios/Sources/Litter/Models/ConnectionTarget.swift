import Foundation
import Security

enum ConnectionTarget: Equatable {
    case local
    case remote(host: String, port: UInt16)
    case remoteURL(URL)
    case sshThenRemote(host: String, credentials: SSHCredentials)
}

enum SSHCredentials: Equatable {
    case password(username: String, password: String, unlockMacosKeychain: Bool)
    case key(username: String, privateKey: String, passphrase: String?)
}

enum SavedSSHAuthMethod: String, Codable {
    case password
    case key
}

struct SavedSSHCredential: Codable {
    let username: String
    let method: SavedSSHAuthMethod
    let password: String?
    let privateKey: String?
    let passphrase: String?
    let unlockMacosKeychain: Bool?
}

enum SSHCredentialStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode credentials"
        case .decodingFailed:
            return "Failed to decode saved credentials"
        case .keychain(let status):
            return "Keychain error (\(status))"
        }
    }
}

final class SSHCredentialStore {
    static let shared = SSHCredentialStore()

    private let service = "com.litter.ssh.credentials"

    private init() {}

    func load(host: String, port: Int = 22) throws -> SavedSSHCredential? {
        let query = baseQuery(host: host, port: port).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw SSHCredentialStoreError.decodingFailed }
            guard let decoded = try? JSONDecoder().decode(SavedSSHCredential.self, from: data) else {
                throw SSHCredentialStoreError.decodingFailed
            }
            return decoded
        case errSecItemNotFound:
            return nil
        default:
            throw SSHCredentialStoreError.keychain(status)
        }
    }

    func save(_ credential: SavedSSHCredential, host: String, port: Int = 22) throws {
        guard let data = try? JSONEncoder().encode(credential) else {
            throw SSHCredentialStoreError.encodingFailed
        }

        let account = serverAccount(host: host, port: port)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updates: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SSHCredentialStoreError.keychain(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw SSHCredentialStoreError.keychain(status)
        }
    }

    func delete(host: String, port: Int = 22) throws {
        let status = SecItemDelete(baseQuery(host: host, port: port) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(host: String, port: Int) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverAccount(host: host, port: port)
        ]
    }

    private func serverAccount(host: String, port: Int) -> String {
        "\(normalizedHost(host).lowercased()):\(port)"
    }

    private func normalizedHost(_ host: String) -> String {
        var normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }
        return normalized
    }
}
