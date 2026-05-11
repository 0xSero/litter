import Foundation
import Security

final class OpenAIApiKeyStore {
    static let shared = OpenAIApiKeyStore()

    private let service = "com.sigkitten.litter.openai-api-key"
    private let apiKeyAccount = "default"
    private let baseURLAccount = "openai-base-url"
    private let apiKeyEnvKey = "OPENAI_API_KEY"
    private let baseURLEnvKey = "OPENAI_BASE_URL"

    private init() {}

    var hasStoredKey: Bool {
        (try? load())?.isEmpty == false
    }

    var hasStoredBaseURL: Bool {
        (try? loadBaseURL())?.isEmpty == false
    }

    func load() throws -> String? {
        try load(account: apiKeyAccount)
    }

    func loadBaseURL() throws -> String? {
        try load(account: baseURLAccount)
    }

    private func load(account: String) throws -> String? {
        let query = baseQuery(account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"]
            )
        }
    }

    func save(_ key: String) throws {
        try save(value: key, account: apiKeyAccount)
        applyToEnvironment()
    }

    func saveBaseURL(_ baseURL: String) throws {
        try save(value: baseURL, account: baseURLAccount)
        applyToEnvironment()
    }

    private func save(value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = baseQuery(account: account).merging([
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]) { _, new in new }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, updates as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(updateStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(updateStatus))"]
                )
            }
            return
        }

        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"]
            )
        }
    }

    func clear() throws {
        try clear(account: apiKeyAccount)
        unsetenv(apiKeyEnvKey)
    }

    func clearBaseURL() throws {
        try clear(account: baseURLAccount)
        unsetenv(baseURLEnvKey)
    }

    private func clear(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain error (\(status))"]
            )
        }
    }

    func applyToEnvironment() {
        if let key = (try? load()) ?? nil, !key.isEmpty {
            setenv(apiKeyEnvKey, key, 1)
        } else {
            unsetenv(apiKeyEnvKey)
        }

        if let baseURL = (try? loadBaseURL()) ?? nil, !baseURL.isEmpty {
            setenv(baseURLEnvKey, baseURL, 1)
        } else {
            unsetenv(baseURLEnvKey)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
