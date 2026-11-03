import Foundation
import Security

enum CredentialStoreError: Error, LocalizedError {
    case invalidBundle
    case itemNotFound
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidBundle: "The credential export is incomplete or invalid."
        case .itemNotFound: "No saved Google credential bundle was found."
        case .keychain(let status):
            status == errSecInteractionNotAllowed
                ? "Keychain is locked or interaction was denied."
                : "Keychain operation failed (OSStatus \(status))."
        }
    }
}

struct KeychainCredentialStore: Sendable {
    private let service = "com.tagtrail.credentials"

    func save(_ data: Data, account: String = "google") throws {
        try Self.validate(data)
        try store(data, account: account)
    }

    func load(account: String = "google") throws -> Data {
        let data = try loadRaw(account: account)
        try Self.validate(data)
        return data
    }

    func saveWorkerUpdate(_ data: Data) throws {
        try Self.validateWorkerUpdate(data)
        guard let incoming = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialStoreError.invalidBundle
        }
        var merged: [String: Any]
        do {
            let existing = try loadRaw(account: "google")
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CredentialStoreError.invalidBundle
            }
            merged = object
        } catch CredentialStoreError.itemNotFound {
            merged = [:]
        }
        merged = Self.merge(merged, incoming)
        let updated = try JSONSerialization.data(withJSONObject: merged)
        try Self.validateWorkerUpdate(updated)
        try store(updated, account: "google")
    }

    private func loadRaw(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw CredentialStoreError.itemNotFound }
        guard status == errSecSuccess, let data = result as? Data else { throw CredentialStoreError.keychain(status) }
        return data
    }

    func delete(account: String = "google") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
    }

    func deleteConnectionItems() throws {
        var firstError: Error?
        for account in ["google", "google-setup"] {
            do { try delete(account: account) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    func saveSetupUsername(_ username: String) throws {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 320, value.contains("@"),
              let data = try? JSONSerialization.data(withJSONObject: ["username": value]) else {
            throw CredentialStoreError.invalidBundle
        }
        try store(data, account: "google-setup")
    }

    func loadAuthenticationBundle() throws -> Data? {
        do {
            let data = try loadRaw(account: "google")
            try Self.validateWorkerUpdate(data)
            return data
        } catch CredentialStoreError.itemNotFound {
            guard let username = try loadSetupUsername() else { return nil }
            return try JSONSerialization.data(withJSONObject: ["username": username])
        }
    }

    func deleteSetupUsername() throws { try delete(account: "google-setup") }

    static func validate(_ data: Data) throws {
        guard data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              nonemptyString(root, "username"),
              nonemptyString(root, "aas_token"),
              let fcm = root["fcm_credentials"] as? [String: Any],
              let gcm = fcm["gcm"] as? [String: Any],
              ["android_id", "security_token"].allSatisfy({ (gcm[$0] as? String).map { !$0.isEmpty && $0.allSatisfy(\.isNumber) } == true }),
              ["app_id", "token"].allSatisfy({ nonemptyString(gcm, $0) }),
              let fcmState = fcm["fcm"] as? [String: Any],
              let registration = fcmState["registration"] as? [String: Any],
              nonemptyString(registration, "token"),
              let installation = fcmState["installation"] as? [String: Any],
              nonemptyString(installation, "token"),
              nonemptyString(installation, "refresh_token"),
              let keys = fcm["keys"] as? [String: Any],
              ["private", "public", "secret"].allSatisfy({ nonemptyString(keys, $0) }),
              validKey(root["owner_key"]) || validKey(root["shared_key"]) else {
            throw CredentialStoreError.invalidBundle
        }
        for key in ["owner_key", "shared_key"] where root[key] != nil {
            guard validKey(root[key]) else { throw CredentialStoreError.invalidBundle }
        }
    }

    static func validateWorkerUpdate(_ data: Data) throws {
        let recognizedKeys = ["username", "aas_token", "fcm_credentials", "owner_key", "shared_key"]
        guard data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !root.isEmpty,
              root.keys.contains(where: recognizedKeys.contains) else {
            throw CredentialStoreError.invalidBundle
        }
        if let username = root["username"] as? String, username.isEmpty || username.count > 320 {
            throw CredentialStoreError.invalidBundle
        }
        if root["username"] != nil, !(root["username"] is String) {
            throw CredentialStoreError.invalidBundle
        }
        if root["aas_token"] != nil, !nonemptyString(root, "aas_token") {
            throw CredentialStoreError.invalidBundle
        }
        if root["fcm_credentials"] != nil, !(root["fcm_credentials"] is [String: Any]) {
            throw CredentialStoreError.invalidBundle
        }
        for key in ["owner_key", "shared_key"] where root[key] != nil {
            guard validKey(root[key]) else { throw CredentialStoreError.invalidBundle }
        }
    }

    private static func merge(_ current: [String: Any], _ update: [String: Any]) -> [String: Any] {
        var result = current
        for (key, value) in update {
            if let currentObject = result[key] as? [String: Any],
               let updateObject = value as? [String: Any] {
                result[key] = merge(currentObject, updateObject)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func nonemptyString(_ object: [String: Any], _ key: String) -> Bool {
        guard let value = object[key] as? String else { return false }
        return !value.isEmpty
    }

    private static func validKey(_ value: Any?) -> Bool {
        guard let encoded = value as? String, encoded.count.isMultiple(of: 2),
              encoded.allSatisfy(\.isHexDigit), let decoded = decodeHex(encoded) else { return false }
        return [16, 24, 32].contains(decoded.count)
    }

    private static func decodeHex(_ encoded: String) -> Data? {
        var result = Data(capacity: encoded.count / 2)
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let next = encoded.index(index, offsetBy: 2)
            guard let byte = UInt8(encoded[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private func loadSetupUsername() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "google-setup",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let username = object["username"] else {
            throw status == errSecSuccess ? CredentialStoreError.invalidBundle : CredentialStoreError.keychain(status)
        }

        return username
    }

    private func store(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

}
