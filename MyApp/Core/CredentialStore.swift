import Foundation
import Security

/// S3 connection settings persisted to the Keychain as a single JSON blob.
nonisolated struct StoredS3Settings: Codable, Equatable, Sendable {
    var endpoint: URL
    var bucket: String
    var accessKey: String
    var secretKey: String
    var pathStyle: Bool
    var region: String
}

/// Thin Keychain wrapper storing S3 settings under one generic-password item.
nonisolated struct CredentialStore {
    enum StoreError: Error {
        case encodingFailed
        case unexpectedData
        case keychain(OSStatus)
    }

    var service: String = "video-transfer.s3"
    private static let account = "default"

    /// Persists `settings`, replacing any existing item (delete-then-add).
    func save(_ settings: StoredS3Settings) throws {
        guard let data = try? JSONEncoder().encode(settings) else {
            throw StoreError.encodingFailed
        }

        delete()

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        // Readable during background transfers once the device has been unlocked,
        // and never migrated to another device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
    }

    /// Returns the stored settings, or nil when no item exists.
    /// Throws for any other Keychain failure or if the blob fails to decode.
    func load() throws -> StoredS3Settings? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw StoreError.unexpectedData }
            return try JSONDecoder().decode(StoredS3Settings.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychain(status)
        }
    }

    /// Loads stored settings and bridges them to an S3Config; nil if nothing is stored.
    func makeS3Config() throws -> S3Config? {
        try load()?.makeS3Config()
    }

    /// Removes the stored settings; missing items are not an error.
    func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

nonisolated extension StoredS3Settings {
    /// Bridges stored settings into a request-building S3Config.
    func makeS3Config() -> S3Config {
        S3Config(endpoint: endpoint, bucket: bucket,
                 accessKey: accessKey, secretKey: secretKey,
                 style: pathStyle ? .path : .virtualHost,
                 region: region)
    }
}
