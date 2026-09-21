import Foundation
import Security

/// S3 connection settings for one server. Persisted to the Keychain as part
/// of the `ServerProfile` list.
nonisolated struct StoredS3Settings: Codable, Equatable, Sendable {
    var endpoint: URL
    var bucket: String
    var accessKey: String
    var secretKey: String
    var pathStyle: Bool
    var region: String
}

/// Thin Keychain wrapper storing the server list under one generic-password
/// item (`account = "servers"`, a JSON array of `ServerProfile`).
///
/// Before multi-server support the app kept a single `StoredS3Settings` blob
/// under `account = "default"`. `loadServers` migrates that item into a
/// one-entry list on first read (and deletes it), so an upgrade keeps the
/// user's connection; the migrated profile's id is reported back so the
/// caller can move that server's local state (queue file, watch config) too.
nonisolated struct CredentialStore {
    enum StoreError: Error {
        case encodingFailed
        case unexpectedData
        case keychain(OSStatus)
    }

    /// Result of `loadServers`: the list, plus the id of a profile that was
    /// just created from the legacy single-settings item (nil normally).
    struct LoadResult {
        var servers: [ServerProfile]
        var migratedLegacyServerID: UUID?
    }

    var service: String = "video-transfer.s3"
    private static let serversAccount = "servers"
    private static let legacyAccount = "default"

    /// Persists the whole list, replacing any existing item (delete-then-add).
    func saveServers(_ servers: [ServerProfile]) throws {
        guard let data = try? JSONEncoder().encode(servers) else {
            throw StoreError.encodingFailed
        }
        try write(data, account: Self.serversAccount)
    }

    /// Returns the stored servers (empty when nothing is stored), migrating
    /// the legacy single-settings item if that is all that exists. Throws
    /// for any Keychain failure other than "not found", or if a blob fails
    /// to decode.
    func loadServers() throws -> LoadResult {
        if let data = try read(account: Self.serversAccount) {
            return LoadResult(servers: try JSONDecoder().decode([ServerProfile].self, from: data),
                              migratedLegacyServerID: nil)
        }
        guard let legacyData = try read(account: Self.legacyAccount) else {
            return LoadResult(servers: [], migratedLegacyServerID: nil)
        }
        let legacy = try JSONDecoder().decode(StoredS3Settings.self, from: legacyData)
        let profile = ServerProfile(name: ServerProfile.migratedName(for: legacy), settings: legacy)
        try saveServers([profile])
        delete(account: Self.legacyAccount)
        return LoadResult(servers: [profile], migratedLegacyServerID: profile.id)
    }

    /// Removes every item this store owns; missing items are not an error.
    func deleteAll() {
        delete(account: Self.serversAccount)
        delete(account: Self.legacyAccount)
    }

    // MARK: - Keychain plumbing

    private func write(_ data: Data, account: String) throws {
        delete(account: account)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        // Readable during background transfers once the device has been unlocked,
        // and never migrated to another device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw StoreError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.keychain(status)
        }
    }

    private func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
