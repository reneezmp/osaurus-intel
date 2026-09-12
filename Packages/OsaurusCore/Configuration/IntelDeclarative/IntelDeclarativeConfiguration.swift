//
//  IntelDeclarativeConfiguration.swift
//  OsaurusCore
//
//  A deliberately small, fail-closed declarative surface for the built-in
//  Orchestrator. It owns one atomic persistence file only.
//

import CryptoKit
import CoreFoundation
import Foundation

public enum IntelDeclarativeConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidJSON
    case invalidVersion
    case unsupportedDomain(String)
    case unknownField(path: String)
    case invalidValue(path: String)
    case secretReference(path: String)
    case stalePlan
    case invalidApproval
    case replayedApproval
    case persistenceVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "The configuration document must be a JSON object."
        case .invalidVersion: "Only declarative configuration version 1 is supported."
        case let .unsupportedDomain(domain): "The \(domain) domain is not available in the Intel configuration plane."
        case let .unknownField(path): "\(path) is not a supported configuration field."
        case let .invalidValue(path): "\(path) has an invalid value."
        case let .secretReference(path): "\(path) may contain a secret and is not accepted here."
        case .stalePlan: "Configuration changed after this plan was reviewed. Create and review a new plan."
        case .invalidApproval: "This approval does not belong to the current configuration plan."
        case .replayedApproval: "This approval was already used. Create and review a new plan."
        case .persistenceVerificationFailed: "The configuration could not be verified after saving."
        }
    }
}

public enum IntelDeclarativeField<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case clear
    case set(Value)
}

public struct IntelDeclarativeDefaultAgentPatch: Sendable, Equatable {
    public var displayName: IntelDeclarativeField<String> = .unchanged
    public var systemPrompt: IntelDeclarativeField<String> = .unchanged
    public var defaultModel: IntelDeclarativeField<String> = .unchanged
    public var temperature: IntelDeclarativeField<Float> = .unchanged
    public var maxTokens: IntelDeclarativeField<Int> = .unchanged
}

public struct IntelDeclarativeDelegationPatch: Sendable, Equatable {
    public var customAgentAllowlist: IntelDeclarativeField<Set<UUID>> = .unchanged
    public var admittedCloudModelIDs: IntelDeclarativeField<Set<String>> = .unchanged
    public var permissionModes: IntelDeclarativeField<[String: OrchestratorDelegationPermission]> = .unchanged
    public var maximumChildTokens: IntelDeclarativeField<Int> = .unchanged
    public var maximumInputCharacters: IntelDeclarativeField<Int> = .unchanged
    public var maximumOutputCharacters: IntelDeclarativeField<Int> = .unchanged
    public var timeoutSeconds: IntelDeclarativeField<UInt64> = .unchanged
}

/// Versioned JSON document. There is intentionally no support for prune,
/// secrets, external references, or other upstream configuration domains.
public struct IntelDeclarativeConfigurationDocument: Sendable, Equatable {
    public static let version = 1

    public var defaultAgent: IntelDeclarativeDefaultAgentPatch?
    public var delegation: IntelDeclarativeDelegationPatch?

    public init(
        defaultAgent: IntelDeclarativeDefaultAgentPatch? = nil,
        delegation: IntelDeclarativeDelegationPatch? = nil
    ) {
        self.defaultAgent = defaultAgent
        self.delegation = delegation
    }

    public static func decode(json data: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw IntelDeclarativeConfigurationError.invalidJSON }
        try rejectSecretShapedKeys(in: root, path: "$")
        try requireOnly(root, keys: ["version", "default_agent", "delegation"], path: "$")
        guard let version = root["version"] as? Int, version == Self.version else {
            throw IntelDeclarativeConfigurationError.invalidVersion
        }

        var result = Self()
        if let value = root["default_agent"] {
            guard let object = value as? [String: Any] else {
                throw IntelDeclarativeConfigurationError.invalidValue(path: "default_agent")
            }
            result.defaultAgent = try decodeDefaultAgent(object)
        }
        if let value = root["delegation"] {
            guard let object = value as? [String: Any] else {
                throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation")
            }
            result.delegation = try decodeDelegation(object)
        }
        return result
    }

    public func applying(to current: DefaultAgentConfiguration) -> DefaultAgentConfiguration {
        var target = current
        if let patch = defaultAgent {
            target.displayName = apply(patch.displayName, to: target.displayName)
            target.systemPrompt = apply(patch.systemPrompt, to: target.systemPrompt)
            target.defaultModel = apply(patch.defaultModel, to: target.defaultModel)
            target.temperature = apply(patch.temperature, to: target.temperature)
            target.maxTokens = apply(patch.maxTokens, to: target.maxTokens)
        }
        if let patch = delegation {
            target.delegation.customAgentAllowlist = apply(patch.customAgentAllowlist, to: target.delegation.customAgentAllowlist)
            target.delegation.admittedCloudModelIDs = apply(patch.admittedCloudModelIDs, to: target.delegation.admittedCloudModelIDs)
            target.delegation.permissionModes = apply(patch.permissionModes, to: target.delegation.permissionModes)
            target.delegation.maximumChildTokens = apply(patch.maximumChildTokens, to: target.delegation.maximumChildTokens)
            target.delegation.maximumInputCharacters = apply(patch.maximumInputCharacters, to: target.delegation.maximumInputCharacters)
            target.delegation.maximumOutputCharacters = apply(patch.maximumOutputCharacters, to: target.delegation.maximumOutputCharacters)
            target.delegation.timeoutSeconds = apply(patch.timeoutSeconds, to: target.delegation.timeoutSeconds)
        }
        return target
    }

    private static func decodeDefaultAgent(_ object: [String: Any]) throws -> IntelDeclarativeDefaultAgentPatch {
        try requireOnly(object, keys: ["name", "system_prompt", "model", "temperature", "max_tokens"], path: "default_agent")
        var patch = IntelDeclarativeDefaultAgentPatch()
        patch.displayName = try optionalString(object, key: "name", path: "default_agent.name")
        patch.systemPrompt = try optionalString(object, key: "system_prompt", path: "default_agent.system_prompt")
        patch.defaultModel = try optionalString(object, key: "model", path: "default_agent.model")
        patch.temperature = try optionalFloat(object, key: "temperature", path: "default_agent.temperature")
        patch.maxTokens = try optionalPositiveInt(object, key: "max_tokens", path: "default_agent.max_tokens")
        return patch
    }

    private static func decodeDelegation(_ object: [String: Any]) throws -> IntelDeclarativeDelegationPatch {
        try requireOnly(object, keys: ["allowed_agent_ids", "admitted_cloud_model_ids", "permissions", "max_child_tokens", "max_input_characters", "max_output_characters", "timeout_seconds"], path: "delegation")
        var patch = IntelDeclarativeDelegationPatch()
        if let value = object["allowed_agent_ids"] {
            guard let values = value as? [String] else { throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.allowed_agent_ids") }
            let ids = try values.map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else { throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.allowed_agent_ids") }
                return id
            }
            patch.customAgentAllowlist = .set(Set(ids))
        }
        if let value = object["admitted_cloud_model_ids"] {
            guard let values = value as? [String], values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.admitted_cloud_model_ids")
            }
            patch.admittedCloudModelIDs = .set(Set(values))
        }
        if let value = object["permissions"] {
            guard let values = value as? [String: String] else { throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.permissions") }
            var permissions: [String: OrchestratorDelegationPermission] = [:]
            for (scope, rawPermission) in values {
                guard validScope(scope), let permission = OrchestratorDelegationPermission(rawValue: rawPermission) else {
                    throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.permissions")
                }
                permissions[scope.lowercased()] = permission
            }
            patch.permissionModes = .set(permissions)
        }
        patch.maximumChildTokens = try requiredPositiveInt(object, key: "max_child_tokens", path: "delegation.max_child_tokens")
        patch.maximumInputCharacters = try requiredPositiveInt(object, key: "max_input_characters", path: "delegation.max_input_characters")
        patch.maximumOutputCharacters = try requiredPositiveInt(object, key: "max_output_characters", path: "delegation.max_output_characters")
        if let value = object["timeout_seconds"] {
            guard let integer = value as? Int, integer > 0 else { throw IntelDeclarativeConfigurationError.invalidValue(path: "delegation.timeout_seconds") }
            patch.timeoutSeconds = .set(UInt64(integer))
        }
        return patch
    }

    private static func validScope(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && UUID(uuidString: String(parts[1])) != nil
    }

    private static func requireOnly(_ object: [String: Any], keys: Set<String>, path: String) throws {
        for key in object.keys where !keys.contains(key) {
            if path == "$" { throw IntelDeclarativeConfigurationError.unsupportedDomain(key) }
            throw IntelDeclarativeConfigurationError.unknownField(path: "\(path).\(key)")
        }
    }

    private static func rejectSecretShapedKeys(in object: [String: Any], path: String) throws {
        for (key, value) in object {
            let lower = key.lowercased()
            let exactSecretKeys: Set<String> = [
                "secret", "token", "password", "api_key", "apikey",
                "credential", "credentials", "keychain", "env",
                "access_token", "auth_token", "refresh_token",
            ]
            let secretSuffixes = ["_secret", "_password", "_api_key", "_credential", "_access_token", "_auth_token", "_refresh_token"]
            if exactSecretKeys.contains(lower) || secretSuffixes.contains(where: lower.hasSuffix) {
                throw IntelDeclarativeConfigurationError.secretReference(path: "\(path).\(key)")
            }
            if let string = value as? String,
               string.lowercased().hasPrefix("env:") || string.lowercased().hasPrefix("keychain:") {
                throw IntelDeclarativeConfigurationError.secretReference(path: "\(path).\(key)")
            }
            if let nested = value as? [String: Any] {
                try rejectSecretShapedKeys(in: nested, path: "\(path).\(key)")
            }
            if let array = value as? [Any] {
                for (index, element) in array.enumerated() {
                    if let nested = element as? [String: Any] {
                        try rejectSecretShapedKeys(in: nested, path: "\(path).\(key)[\(index)]")
                    }
                }
            }
        }
    }

    private static func optionalString(_ object: [String: Any], key: String, path: String) throws -> IntelDeclarativeField<String> {
        guard let value = object[key] else { return .unchanged }
        if value is NSNull { return .clear }
        guard let string = value as? String else { throw IntelDeclarativeConfigurationError.invalidValue(path: path) }
        return .set(string)
    }

    private static func optionalFloat(_ object: [String: Any], key: String, path: String) throws -> IntelDeclarativeField<Float> {
        guard let value = object[key] else { return .unchanged }
        if value is NSNull { return .clear }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              (0 ... 2).contains(number.doubleValue)
        else { throw IntelDeclarativeConfigurationError.invalidValue(path: path) }
        return .set(number.floatValue)
    }

    private static func optionalPositiveInt(_ object: [String: Any], key: String, path: String) throws -> IntelDeclarativeField<Int> {
        guard let value = object[key] else { return .unchanged }
        if value is NSNull { return .clear }
        guard let integer = value as? Int, (1 ... 65_536).contains(integer) else { throw IntelDeclarativeConfigurationError.invalidValue(path: path) }
        return .set(integer)
    }

    private static func requiredPositiveInt(_ object: [String: Any], key: String, path: String) throws -> IntelDeclarativeField<Int> {
        guard let value = object[key] else { return .unchanged }
        guard let integer = value as? Int, integer > 0 else { throw IntelDeclarativeConfigurationError.invalidValue(path: path) }
        return .set(integer)
    }

    private func apply<Value: Sendable & Equatable>(_ field: IntelDeclarativeField<Value>, to current: Value?) -> Value? {
        switch field { case .unchanged: current; case .clear: nil; case let .set(value): value }
    }

    private func apply<Value: Sendable & Equatable>(_ field: IntelDeclarativeField<Value>, to current: Value) -> Value {
        switch field { case .unchanged, .clear: current; case let .set(value): value }
    }
}

public struct IntelDeclarativeConfigurationChange: Sendable, Equatable, Identifiable {
    public let path: String
    public let before: String
    public let after: String
    public var id: String { path }
}

public struct IntelDeclarativeConfigurationPlan: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let currentStateFingerprint: String
    public let targetStateFingerprint: String
    public let changes: [IntelDeclarativeConfigurationChange]
    public let target: DefaultAgentConfiguration

    public var isNoOp: Bool { changes.isEmpty }
}

public struct IntelDeclarativeConfigurationApproval: Sendable, Equatable {
    fileprivate let planID: UUID
    fileprivate let currentStateFingerprint: String
    fileprivate let targetStateFingerprint: String
    fileprivate let nonce: UUID
}

public protocol IntelDeclarativeDefaultAgentStore: Sendable {
    func load() -> DefaultAgentConfiguration
    func loadFresh() throws -> DefaultAgentConfiguration
    func save(_ configuration: DefaultAgentConfiguration) throws
}

public struct IntelDeclarativeProductionDefaultAgentStore: IntelDeclarativeDefaultAgentStore {
    public init() {}
    public func load() -> DefaultAgentConfiguration { DefaultAgentConfigurationStore.load() }
    public func loadFresh() throws -> DefaultAgentConfiguration { try DefaultAgentConfigurationStore.loadFreshFromDisk() }
    public func save(_ configuration: DefaultAgentConfiguration) throws {
        try DefaultAgentConfigurationStore.saveChecked(configuration)
#if OSAURUS_INTEL
        // Refresh already-open Intel chats after the checked write. This
        // repeats the same atomic save through the established manager seam.
        AgentManager.shared.updateDefaultAgentConfiguration(configuration)
#endif
    }
}

/// Actor-isolated planner and applier. A receipt is deliberately minted only
/// after the caller presents the exact plan to the user; it is single-use and
/// checked against a fresh disk state before any persistence occurs.
public actor IntelDeclarativeConfigurationService {
    private let store: any IntelDeclarativeDefaultAgentStore
    private var consumedApprovalNonces: Set<UUID> = []

    public init(store: any IntelDeclarativeDefaultAgentStore = IntelDeclarativeProductionDefaultAgentStore()) {
        self.store = store
    }

    public func plan(json data: Data) throws -> IntelDeclarativeConfigurationPlan {
        let document = try IntelDeclarativeConfigurationDocument.decode(json: data)
        return makePlan(document: document, current: store.load())
    }

    /// Exports the entire supported Intel slice as strict version-1 JSON. This
    /// is a snapshot only: it never includes credentials or references to them.
    public func exportJSON() throws -> Data {
        let configuration = store.load()
        let delegation = configuration.delegation
        let defaultAgent: [String: Any] = [
            "name": configuration.displayName as Any? ?? NSNull(),
            "system_prompt": configuration.systemPrompt as Any? ?? NSNull(),
            "model": configuration.defaultModel as Any? ?? NSNull(),
            "temperature": configuration.temperature as Any? ?? NSNull(),
            "max_tokens": configuration.maxTokens as Any? ?? NSNull(),
        ]
        let delegationObject: [String: Any] = [
            "allowed_agent_ids": delegation.customAgentAllowlist.map(\.uuidString).sorted(),
            "admitted_cloud_model_ids": delegation.admittedCloudModelIDs.sorted(),
            "permissions": delegation.permissionModes.mapValues(\.rawValue),
            "max_child_tokens": delegation.maximumChildTokens,
            "max_input_characters": delegation.maximumInputCharacters,
            "max_output_characters": delegation.maximumOutputCharacters,
            "timeout_seconds": delegation.timeoutSeconds,
        ]
        let object: [String: Any] = [
            "version": IntelDeclarativeConfigurationDocument.version,
            "default_agent": defaultAgent,
            "delegation": delegationObject,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public func approve(_ plan: IntelDeclarativeConfigurationPlan) -> IntelDeclarativeConfigurationApproval {
        IntelDeclarativeConfigurationApproval(
            planID: plan.id,
            currentStateFingerprint: plan.currentStateFingerprint,
            targetStateFingerprint: plan.targetStateFingerprint,
            nonce: UUID()
        )
    }

    @discardableResult
    public func apply(
        _ plan: IntelDeclarativeConfigurationPlan,
        approval: IntelDeclarativeConfigurationApproval
    ) throws -> DefaultAgentConfiguration {
        guard approval.planID == plan.id,
              approval.currentStateFingerprint == plan.currentStateFingerprint,
              approval.targetStateFingerprint == plan.targetStateFingerprint
        else { throw IntelDeclarativeConfigurationError.invalidApproval }
        guard !consumedApprovalNonces.contains(approval.nonce) else {
            throw IntelDeclarativeConfigurationError.replayedApproval
        }
        let live = store.load()
        guard fingerprint(of: live) == plan.currentStateFingerprint else {
            throw IntelDeclarativeConfigurationError.stalePlan
        }
        consumedApprovalNonces.insert(approval.nonce)
        guard !plan.isNoOp else { return live }
        try store.save(plan.target)
        guard let reloaded = try? store.loadFresh() else {
            throw IntelDeclarativeConfigurationError.persistenceVerificationFailed
        }
        guard reloaded == plan.target else { throw IntelDeclarativeConfigurationError.persistenceVerificationFailed }
        return reloaded
    }

    private func makePlan(
        document: IntelDeclarativeConfigurationDocument,
        current: DefaultAgentConfiguration
    ) -> IntelDeclarativeConfigurationPlan {
        let target = document.applying(to: current)
        let currentFingerprint = fingerprint(of: current)
        let targetFingerprint = fingerprint(of: target)
        let changes = Self.changes(from: current, to: target)
        let id = planID(currentFingerprint: currentFingerprint, targetFingerprint: targetFingerprint)
        return IntelDeclarativeConfigurationPlan(
            id: id,
            currentStateFingerprint: currentFingerprint,
            targetStateFingerprint: targetFingerprint,
            changes: changes,
            target: target
        )
    }

    private func fingerprint(of configuration: DefaultAgentConfiguration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(configuration)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func planID(currentFingerprint: String, targetFingerprint: String) -> UUID {
        let characters = Array((currentFingerprint + targetFingerprint).prefix(32))
        let value = String(characters[0 ..< 8]) + "-" + String(characters[8 ..< 12]) + "-" +
            String(characters[12 ..< 16]) + "-" + String(characters[16 ..< 20]) + "-" +
            String(characters[20 ..< 32])
        // SHA-256 always supplies 64 lowercase hexadecimal characters.
        return UUID(uuidString: value)!
    }

    private static func changes(from before: DefaultAgentConfiguration, to after: DefaultAgentConfiguration) -> [IntelDeclarativeConfigurationChange] {
        var result: [IntelDeclarativeConfigurationChange] = []
        append("default_agent.name", before.displayName, after.displayName, into: &result)
        append("default_agent.system_prompt", before.systemPrompt, after.systemPrompt, into: &result)
        append("default_agent.model", before.defaultModel, after.defaultModel, into: &result)
        append("default_agent.temperature", before.temperature, after.temperature, into: &result)
        append("default_agent.max_tokens", before.maxTokens, after.maxTokens, into: &result)
        append("delegation.allowed_agent_ids", before.delegation.customAgentAllowlist.map(\.uuidString).sorted(), after.delegation.customAgentAllowlist.map(\.uuidString).sorted(), into: &result)
        append("delegation.admitted_cloud_model_ids", before.delegation.admittedCloudModelIDs.sorted(), after.delegation.admittedCloudModelIDs.sorted(), into: &result)
        appendPermissions(before.delegation.permissionModes, after.delegation.permissionModes, into: &result)
        append("delegation.max_child_tokens", before.delegation.maximumChildTokens, after.delegation.maximumChildTokens, into: &result)
        append("delegation.max_input_characters", before.delegation.maximumInputCharacters, after.delegation.maximumInputCharacters, into: &result)
        append("delegation.max_output_characters", before.delegation.maximumOutputCharacters, after.delegation.maximumOutputCharacters, into: &result)
        append("delegation.timeout_seconds", before.delegation.timeoutSeconds, after.delegation.timeoutSeconds, into: &result)
        return result
    }

    private static func append<Value: Equatable>(_ path: String, _ before: Value, _ after: Value, into changes: inout [IntelDeclarativeConfigurationChange]) {
        guard before != after else { return }
        changes.append(.init(path: path, before: boundedDescription(before), after: boundedDescription(after)))
    }

    /// Approval cards and tool results must stay reviewable even when a prompt
    /// or allowlist is large. The fingerprints still bind the complete values;
    /// only the human-facing preview is shortened.
    private static func boundedDescription<Value>(_ value: Value) -> String {
        let flattened = String(describing: value)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard flattened.count > 240 else { return flattened }
        return String(flattened.prefix(237)) + "…"
    }

    private static func appendPermissions(
        _ before: [String: OrchestratorDelegationPermission],
        _ after: [String: OrchestratorDelegationPermission],
        into changes: inout [IntelDeclarativeConfigurationChange]
    ) {
        guard before != after else { return }
        let render: ([String: OrchestratorDelegationPermission]) -> String = { permissions in
            permissions.keys.sorted().map { "\($0)=\(permissions[$0]!.rawValue)" }.joined(separator: ", ")
        }
        changes.append(.init(path: "delegation.permissions", before: render(before), after: render(after)))
    }
}
