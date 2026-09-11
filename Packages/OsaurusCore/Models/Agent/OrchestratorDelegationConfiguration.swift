//
//  OrchestratorDelegationConfiguration.swift
//  OsaurusCore
//
//  Persistent, fail-closed policy for bounded text-only delegation.
//

import Foundation

/// A launcher/target pair. Permission is deliberately scoped to both IDs so
/// authorizing one custom agent never implicitly authorizes another launcher.
public struct OrchestratorDelegationPermissionScope: Codable, Hashable, Sendable {
    public let launcherAgentID: UUID
    public let targetAgentID: UUID

    public init(launcherAgentID: UUID, targetAgentID: UUID) {
        self.launcherAgentID = launcherAgentID
        self.targetAgentID = targetAgentID
    }

    fileprivate var storageKey: String {
        "\(launcherAgentID.uuidString.lowercased())/\(targetAgentID.uuidString.lowercased())"
    }
}

/// The durable user choice for a single launcher/target pair.
public enum OrchestratorDelegationPermission: String, Codable, Sendable, Equatable {
    /// Require an explicit approval token for each run.
    case ask
    /// Refuse this pair even when both the target and model are allowlisted.
    case deny
    /// Permit this pair while it remains otherwise admitted and revalidated.
    case alwaysAllow
}

/// Persistent policy for Gate 4. Empty allowlists are intentional: migration
/// never turns existing agents or cloud models into runnable child targets.
public struct OrchestratorDelegationConfiguration: Codable, Equatable, Sendable {
    public var customAgentAllowlist: Set<UUID>
    public var admittedCloudModelIDs: Set<String>
    public var permissionModes: [String: OrchestratorDelegationPermission]
    public var maximumChildTokens: Int
    public var maximumInputCharacters: Int
    public var maximumOutputCharacters: Int
    public var timeoutSeconds: UInt64

    public init(
        customAgentAllowlist: Set<UUID> = [],
        admittedCloudModelIDs: Set<String> = [],
        permissionModes: [String: OrchestratorDelegationPermission] = [:],
        maximumChildTokens: Int = 256,
        maximumInputCharacters: Int = 12_000,
        maximumOutputCharacters: Int = 8_192,
        timeoutSeconds: UInt64 = 30
    ) {
        self.customAgentAllowlist = customAgentAllowlist
        self.admittedCloudModelIDs = Self.normalizedModelIDs(admittedCloudModelIDs)
        self.permissionModes = permissionModes
        self.maximumChildTokens = max(1, maximumChildTokens)
        self.maximumInputCharacters = max(1, maximumInputCharacters)
        self.maximumOutputCharacters = max(1, maximumOutputCharacters)
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    /// Absence is Ask, never an implicit approval.
    public func permission(for scope: OrchestratorDelegationPermissionScope) -> OrchestratorDelegationPermission {
        permissionModes[scope.storageKey] ?? .ask
    }

    public mutating func setPermission(
        _ permission: OrchestratorDelegationPermission,
        for scope: OrchestratorDelegationPermissionScope
    ) {
        permissionModes[scope.storageKey] = permission
    }

    public func admits(modelID: String) -> Bool {
        guard let normalized = Self.normalizedModelID(modelID) else { return false }
        return admittedCloudModelIDs.contains(normalized)
    }

    public static let `default` = OrchestratorDelegationConfiguration()

    private enum CodingKeys: String, CodingKey {
        case customAgentAllowlist
        case admittedCloudModelIDs
        case permissionModes
        case maximumChildTokens
        case maximumInputCharacters
        case maximumOutputCharacters
        case timeoutSeconds
    }

    /// Gate 4 fields may be added to an existing Gate 1 configuration. Missing
    /// fields inherit conservative bounds and empty admission lists.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawAgentIDs = (try? container.decodeIfPresent(
            [String].self,
            forKey: .customAgentAllowlist
        )) ?? []
        let agentIDs = Set(rawAgentIDs.compactMap { UUID(uuidString: $0) })
        let rawModelIDs = (try? container.decodeIfPresent(
            [String].self,
            forKey: .admittedCloudModelIDs
        )) ?? []
        let modelIDs = Set(rawModelIDs)
        let rawPermissions =
            (try? container.decodeIfPresent([String: String].self, forKey: .permissionModes)) ?? [:]
        let permissions = rawPermissions.reduce(into: [String: OrchestratorDelegationPermission]()) { result, entry in
            if let permission = OrchestratorDelegationPermission(rawValue: entry.value) {
                result[entry.key] = permission
            }
        }
        let decodedTimeout =
            (try? container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)) ?? 30
        self.init(
            customAgentAllowlist: agentIDs,
            admittedCloudModelIDs: modelIDs,
            permissionModes: permissions,
            maximumChildTokens: (try? container.decodeIfPresent(Int.self, forKey: .maximumChildTokens)) ?? 256,
            maximumInputCharacters: (try? container.decodeIfPresent(Int.self, forKey: .maximumInputCharacters)) ?? 12_000,
            maximumOutputCharacters: (try? container.decodeIfPresent(Int.self, forKey: .maximumOutputCharacters)) ?? 8_192,
            timeoutSeconds: UInt64(max(1, decodedTimeout))
        )
    }

    private static func normalizedModelIDs(_ modelIDs: Set<String>) -> Set<String> {
        Set(modelIDs.compactMap(normalizedModelID))
    }

    static func normalizedModelID(_ modelID: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
