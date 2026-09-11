//
//  DefaultAgentConfiguration.swift
//  osaurus
//
//  Durable overrides for the built-in Orchestrator agent.
//

import Foundation

/// Settings owned by the built-in Orchestrator (`Agent.defaultId`). They are
/// intentionally separate from `ChatConfiguration`: a nil value continues to
/// inherit the corresponding global chat setting, while a non-nil value is an
/// explicit Orchestrator-only override.
public struct DefaultAgentConfiguration: Codable, Equatable, Sendable {
    /// Cosmetic custom name. Nil or blank renders the built-in “Osaurus”.
    public var displayName: String?
    /// Nil inherits the global system prompt. An empty string is an explicit
    /// request for no Orchestrator-specific prompt.
    public var systemPrompt: String?
    /// Nil inherits the global selected model.
    public var defaultModel: String?
    /// Nil inherits the global temperature.
    public var temperature: Float?
    /// Nil inherits the global maximum-token setting.
    public var maxTokens: Int?
    /// The fail-closed policy for the bounded Intel delegation runtime. Missing
    /// from older `default-agent.json` files means no target or model is
    /// admitted, and every possible launcher/target pair defaults to Ask.
    public var delegation: OrchestratorDelegationConfiguration

    public init(
        displayName: String? = nil,
        systemPrompt: String? = nil,
        defaultModel: String? = nil,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        delegation: OrchestratorDelegationConfiguration = .default
    ) {
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.defaultModel = defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.delegation = delegation
    }

    /// A trimmed custom name, or nil when the built-in name should render.
    public var resolvedDisplayName: String? {
        guard let displayName else { return nil }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static let `default` = DefaultAgentConfiguration()

    private enum CodingKeys: String, CodingKey {
        case displayName
        case systemPrompt
        case defaultModel
        case temperature
        case maxTokens
        case delegation
    }

    /// Older Gate 1 files have no delegation field. Decode them as a
    /// fail-closed Gate 4 policy instead of treating the whole configuration
    /// file as corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        delegation = try container.decodeIfPresent(
            OrchestratorDelegationConfiguration.self,
            forKey: .delegation
        ) ?? .default
    }
}
