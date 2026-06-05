//
//  RemoteProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for remote OpenAI-compatible provider credentials.
//

import Foundation
import Security

public struct RemoteProviderOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountId: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
    }

    public var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

/// Keychain wrapper for secure remote provider credential storage
public enum RemoteProviderKeychain {
    private static let service = "ai.osaurus.remote"

    public static func runOffCooperativeExecutor<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: operation())
            }
        }
    }

    // MARK: - API Key Management

    /// Save an API key for a provider ID
    @discardableResult
    public static func saveAPIKey(_ apiKey: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).apiKey"
        guard let keyData = apiKey.data(using: .utf8) else { return false }

        // Delete any existing key first
        deleteAPIKey(for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        #if OSAURUS_INTEL
        // Mirror to a file so it always reads back on ad-hoc / no-Secure-Enclave
        // Macs (Rosy) where the Keychain read can silently fail. The file is the
        // source of truth on Intel, so report success even if SecItemAdd didn't.
        intelWriteKeyFile(apiKey, account: account)
        return true
        #else
        return status == errSecSuccess
        #endif
    }

    /// Retrieve an API key for a provider ID
    public static func getAPIKey(for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).apiKey"

        #if OSAURUS_INTEL
        // Prefer the file-backed value (reliable on ad-hoc/no-Secure-Enclave
        // builds); fall through to the Keychain for keys saved by older builds.
        if let fileKey = intelReadKeyFile(account: account) { return fileKey }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return apiKey
    }

    /// Delete an API key for a provider ID
    @discardableResult
    public static func deleteAPIKey(for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).apiKey"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        #if OSAURUS_INTEL
        intelDeleteKeyFile(account: account)
        #endif
        return status == errSecSuccess || status == errSecItemNotFound
    }

    #if OSAURUS_INTEL
    // MARK: - File-backed fallback (Intel fork)
    //
    // On ad-hoc-signed builds running on Macs without a Secure Enclave (e.g.
    // Rosy — the 2017 Intel Air on OCLP), Keychain reads of app-written items
    // can fail silently, so a saved API key reads back as nil. We mirror the key
    // to a 0600 file under ~/.osaurus/.secrets so it ALWAYS reads back. Plaintext
    // on the user's own device — the local-first tradeoff for reliability.
    private static func intelKeyFileURL(account: String) -> URL {
        OsaurusPaths.root()
            .appendingPathComponent(".secrets", isDirectory: true)
            .appendingPathComponent("\(service).\(account)")
    }

    private static func intelWriteKeyFile(_ value: String, account: String) {
        let url = intelKeyFileURL(account: account)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if let data = value.data(using: .utf8) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func intelReadKeyFile(account: String) -> String? {
        guard let data = try? Data(contentsOf: intelKeyFileURL(account: account)),
            let s = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intelDeleteKeyFile(account: String) {
        try? FileManager.default.removeItem(at: intelKeyFileURL(account: account))
    }
    #endif

    /// Check if an API key exists for a provider ID
    public static func hasAPIKey(for providerId: UUID) -> Bool {
        return getAPIKey(for: providerId) != nil
    }

    // MARK: - OAuth Token Management

    @discardableResult
    public static func saveOAuthTokens(_ tokens: RemoteProviderOAuthTokens, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).oauth.tokens"
        guard let tokenData = try? JSONEncoder().encode(tokens) else { return false }

        deleteOAuthTokens(for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    public static func saveOAuthTokensOffMainActor(_ tokens: RemoteProviderOAuthTokens, for providerId: UUID) async
        -> Bool
    {
        await runOffCooperativeExecutor {
            saveOAuthTokens(tokens, for: providerId)
        }
    }

    public static func getOAuthTokens(for providerId: UUID) -> RemoteProviderOAuthTokens? {
        let account = "\(providerId.uuidString).oauth.tokens"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let tokens = try? JSONDecoder().decode(RemoteProviderOAuthTokens.self, from: data)
        else {
            return nil
        }

        return tokens
    }

    @discardableResult
    public static func deleteOAuthTokens(for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).oauth.tokens"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func hasOAuthTokens(for providerId: UUID) -> Bool {
        getOAuthTokens(for: providerId) != nil
    }

    // MARK: - Header Secret Management

    /// Save a secret header value for a provider
    @discardableResult
    public static func saveHeaderSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).header.\(key)"
        guard let valueData = value.data(using: .utf8) else { return false }

        // Delete any existing value first
        deleteHeaderSecret(key: key, for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a secret header value for a provider
    public static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).header.\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    /// Delete a secret header value for a provider
    @discardableResult
    public static func deleteHeaderSecret(key: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).header.\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete all secrets for a provider (API key + all header secrets)
    public static func deleteAllSecrets(for providerId: UUID) {
        // Delete API key
        deleteAPIKey(for: providerId)
        deleteOAuthTokens(for: providerId)

        // Delete all header secrets by querying with prefix
        let accountPrefix = "\(providerId.uuidString)."

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let items = result as? [[String: Any]]
        else {
            return
        }

        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix)
            {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
    }
}
