//
//  Project.swift
//  osaurus
//
//  A user-facing container that groups chat sessions around a topic.
//  Orthogonal to agents: a project can hold conversations from any agent.
//
//  Intel fork note: upstream also carries `knowledgeCollectionIds` here
//  (Projects group instructions + knowledge + memory). This fork has no
//  Knowledge base, so that dimension is dropped entirely — Intel Projects
//  are shared instructions + memory + chat grouping only.
//

import Foundation

/// A named grouping of chat sessions with optional shared instructions.
public struct Project: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Free-form instructions prepended to the system prompt of every chat
    /// in this project. Empty string means no extra context.
    public var instructions: String
    /// Agent that new chats started from this project's page use. nil (or a
    /// since-deleted agent) → the window's current agent, as before. A
    /// nudge toward one-agent projects, never a restriction: chats from any
    /// agent can still be moved in.
    public var defaultAgentId: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        defaultAgentId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.defaultAgentId = defaultAgentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        defaultAgentId = try c.decodeIfPresent(UUID.self, forKey: .defaultAgentId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, defaultAgentId, createdAt, updatedAt
    }
}
