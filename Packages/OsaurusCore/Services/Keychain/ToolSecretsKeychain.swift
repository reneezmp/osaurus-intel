//
//  ToolSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for plugin secrets (API keys, tokens, etc.).
//

import Foundation
import Security

/// Keychain wrapper for secure plugin secret storage.
/// All config is agent-scoped: account format is `"{agentId}.{pluginId}.{key}"`.
public enum ToolSecretsKeychain {
    private static let service = "ai.osaurus.tools"
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    // MARK: - Presence memoization

    // `hasSecret` runs on view-body call paths (e.g. the chat context
    // estimate resolving Discord auto-destinations via `hasBotToken`), and
    // each call is a full `SecItemCopyMatching` round-trip through securityd
    // including item decryption — observed as multi-second main-thread hangs
    // when the daemon is slow. Presence only changes through this type's own
    // save/delete paths, so it's cached per account and updated there.
    // External edits via Keychain Access are not tracked; a stale presence
    // bit there costs one failed plugin call, not a hang.
    private static let presenceLock = NSLock()
    private nonisolated(unsafe) static var presenceCache: [String: Bool] = [:]

    private static func notePresence(_ present: Bool, account: String) {
        presenceLock.lock()
        presenceCache[account] = present
        presenceLock.unlock()
    }

    private static func clearPresenceCache() {
        presenceLock.lock()
        presenceCache.removeAll(keepingCapacity: true)
        presenceLock.unlock()
    }

    // MARK: - Agent-Scoped Secret Management

    @discardableResult
    public static func saveSecret(_ value: String, id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { testStore[account] = value }
            return true
        }
        guard let valueData = value.data(using: .utf8) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }

        deleteSecret(id: id, for: pluginId, agentId: agentId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        let succeeded = status == errSecSuccess
        if succeeded { notePresence(true, account: account) }
        return succeeded
    }

    public static func getSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock { testStore[account] }
        }
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

    public static func hasSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return getSecret(id: id, for: pluginId, agentId: agentId) != nil
        }
        presenceLock.lock()
        if let cached = presenceCache[account] {
            presenceLock.unlock()
            return cached
        }
        presenceLock.unlock()

        let present = getSecret(id: id, for: pluginId, agentId: agentId) != nil
        notePresence(present, account: account)
        return present
    }

    @discardableResult
    public static func deleteSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        let deleted = status == errSecSuccess || status == errSecItemNotFound
        notePresence(false, account: account)
        return deleted
    }

    public static func deleteAllSecrets(for pluginId: String, agentId: UUID) {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)
        deleteAllMatchingPrefix(accountPrefix)
    }

    /// Delete all agent-scoped secrets for a plugin across every agent.
    public static func deleteAllSecretsAllAgents(for pluginId: String) {
        clearPresenceCache()
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        let suffix = ".\(pluginId)."
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.contains(suffix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    /// Delete every per-agent secret across all plugins for the given
    /// `agentId`. Called from `AgentManager.delete(id:)` so deleting an
    /// agent does not leave stale `bot_token` / OAuth credentials /
    /// per-agent webhook URLs accumulating in Keychain Access. Sweeps
    /// any account whose prefix is `"{agentId}."`.
    public static func deleteAllSecrets(forAgent agentId: UUID) {
        deleteAllMatchingPrefix("\(agentId.uuidString).")
    }

    public static func getAllSecrets(for pluginId: String, agentId: UUID) -> [String: String] {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)

        let allItems = fetchAllItems(attributesOnly: true)
        var secrets: [String: String] = [:]
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix)
            else { continue }
            let secretId = String(account.dropFirst(accountPrefix.count))
            if let value = getSecret(id: secretId, for: pluginId, agentId: agentId) {
                secrets[secretId] = value
            }
        }

        return secrets
    }

    /// Per-agent secrets merged on top of `Agent.defaultId` (Plugins-tab
    /// writes act as global defaults; Agents-tab writes override per-key).
    public static func resolvedSecretsWithDefaults(pluginId: String, agentId: UUID) -> [String: String] {
        resolvedSecretsMerging(pluginId: pluginId, primary: agentId, defaults: Agent.defaultId)
    }

    /// Two-id merge primitive: `primary` agent's secrets overlaid on `defaults`.
    public static func resolvedSecretsMerging(pluginId: String, primary: UUID, defaults: UUID) -> [String: String] {
        let defaultDict = getAllSecrets(for: pluginId, agentId: defaults)
        if primary == defaults { return defaultDict }
        let primaryDict = getAllSecrets(for: pluginId, agentId: primary)
        var merged = defaultDict
        for (k, v) in primaryDict { merged[k] = v }
        return merged
    }

    public static func hasAllRequiredSecrets(specs: [PluginManifest.SecretSpec], for pluginId: String, agentId: UUID)
        -> Bool
    {
        for spec in specs where spec.required {
            if !hasSecret(id: spec.id, for: pluginId, agentId: agentId) {
                return false
            }
        }
        return true
    }

    public static func getMissingRequiredSecrets(
        specs: [PluginManifest.SecretSpec],
        for pluginId: String,
        agentId: UUID
    ) -> [PluginManifest.SecretSpec] {
        return specs.filter { spec in
            spec.required && !hasSecret(id: spec.id, for: pluginId, agentId: agentId)
        }
    }

    // MARK: - Legacy Cleanup (non-agent-scoped entries)

    /// Delete all legacy (non-agent-scoped) entries matching `"{pluginId}.*"`.
    /// Used during plugin uninstall to clean up any remaining pre-migration data.
    public static func deleteAllSecrets(for pluginId: String) {
        deleteAllMatchingPrefix("\(pluginId).")
    }

    // MARK: - Migration Support

    /// Returns all legacy (non-agent-scoped) keychain entries for a given plugin.
    /// Legacy accounts match `"{pluginId}.{key}"` but NOT `"{uuid}.{pluginId}.{key}"`.
    public static func legacySecrets(for pluginId: String) -> [String: String] {
        let legacyPrefix = "\(pluginId)."
        let allItems = fetchAllItems(attributesOnly: false)

        var secrets: [String: String] = [:]
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(legacyPrefix),
                !isAgentScopedAccount(account),
                let data = item[kSecValueData as String] as? Data,
                let value = String(data: data, encoding: .utf8)
            else { continue }

            secrets[String(account.dropFirst(legacyPrefix.count))] = value
        }
        return secrets
    }

    /// Delete all legacy (non-agent-scoped) entries for a plugin.
    public static func deleteLegacySecrets(for pluginId: String) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let legacyPrefix = "\(pluginId)."
        let allItems = fetchAllItems(attributesOnly: true)

        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(legacyPrefix),
                !isAgentScopedAccount(account)
            else { continue }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    // MARK: - Internal Helpers

    private static func agentAccount(agentId: UUID, pluginId: String, key: String) -> String {
        "\(agentId.uuidString).\(pluginId).\(key)"
    }

    private static func agentAccountPrefix(agentId: UUID, pluginId: String) -> String {
        "\(agentId.uuidString).\(pluginId)."
    }

    /// UUID pattern: 8-4-4-4-12 hex at the start of the account string.
    private static func isAgentScopedAccount(_ account: String) -> Bool {
        let uuidLength = 36  // "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        guard account.count > uuidLength,
            account[account.index(account.startIndex, offsetBy: uuidLength)] == "."
        else { return false }
        let prefix = String(account.prefix(uuidLength))
        return UUID(uuidString: prefix) != nil
    }

    private static func fetchAllItems(attributesOnly: Bool) -> [[String: Any]] {
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock {
                testStore.map { account, value in
                    var item: [String: Any] = [kSecAttrAccount as String: account]
                    if !attributesOnly {
                        item[kSecValueData as String] = Data(value.utf8)
                    }
                    return item
                }
            }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return [] }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        if !attributesOnly {
            query[kSecReturnData as String] = true
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items
    }

    private static func deleteAllMatchingPrefix(_ prefix: String) {
        // Bulk deletes are rare (plugin uninstall, agent deletion); dropping
        // the whole presence cache is simpler than prefix-matching it.
        clearPresenceCache()
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock {
                let matchingAccounts = testStore.keys.filter { $0.hasPrefix(prefix) }
                for account in matchingAccounts {
                    testStore.removeValue(forKey: account)
                }
            }
            return
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}
