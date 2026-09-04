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
    // Fork-private Keychain service on Intel. A co-installed production Osaurus
    // on the same Mac (e.g. the dev box) uses "ai.osaurus.remote"; sharing it
    // means this build's save/delete could clobber the official app's keys —
    // exactly the bug that wiped a production key before. (The earlier Intel
    // isolation was reverted by the 9b79161b upstream sync; this restores it.
    // Reliability on Rosy is handled by upstream's non-interactive Keychain
    // access, so we keep using the Keychain, just under a private service.)
    #if OSAURUS_INTEL
    private static let service = "ai.osaurus.remote.intel"
    #else
    private static let service = "ai.osaurus.remote"
    #endif

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }

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
        return status == errSecSuccess
    }

    /// Retrieve an API key for a provider ID
    public static func getAPIKey(for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).apiKey"
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            // `errSecItemNotFound` is ordinary: no key has been saved yet.
            // Anything else means the item EXISTS but we could not read it —
            // typically the ACL not carrying across to a newly installed
            // binary. Because the query above sets `kSecUseAuthenticationUISkip`
            // the system never prompts, so this failure is otherwise completely
            // invisible: the provider silently loses its Authorization header,
            // every /models probe 401s, and the UI just shows an empty model
            // list. Log it loudly so the next occurrence is diagnosable, and so
            // "no key stored" is distinguishable from "key locked away".
            if status != errSecItemNotFound {
                NSLog(
                    "[RemoteProviderKeychain] Could not read API key for %@ — OSStatus %d. "
                        + "The item exists but is not readable by this build; re-saving the key "
                        + "in Settings → Providers will re-authorize it.",
                    account, Int(status)
                )
            }
            return nil
        }

        return apiKey
    }

    /// Delete an API key for a provider ID
    @discardableResult
    public static func deleteAPIKey(for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).apiKey"
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if an API key exists for a provider ID
    public static func hasAPIKey(for providerId: UUID) -> Bool {
        return getAPIKey(for: providerId) != nil
    }

    // MARK: - OAuth Token Management

    @discardableResult
    public static func saveOAuthTokens(_ tokens: RemoteProviderOAuthTokens, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).oauth.tokens"
        guard let tokenData = try? JSONEncoder().encode(tokens) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }

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
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]

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
