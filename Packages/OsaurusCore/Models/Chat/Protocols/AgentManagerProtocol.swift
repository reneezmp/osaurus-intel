//
//  AgentManagerProtocol.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surface ChatView accesses on AgentManager.
//

import Foundation

protocol AgentManagerProtocol: AnyObject {
    func agent(for id: UUID) -> (any AgentInfoProtocol)?
    func agentsList() -> [any AgentInfoProtocol]
    func updateDefaultModel(for agentId: UUID, model: String)
    func effectiveModel(for agentId: UUID) -> String?
    func effectiveMemoryDisabled(for agentId: UUID) -> Bool
    func effectiveAutonomousExec(for agentId: UUID) -> AgentAutoExecInfo?
    func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode?
    func effectiveMaxTokens(for agentId: UUID) -> Int?
    func effectiveTemperature(for agentId: UUID) -> Double?
    func ttsVoice(for agentId: UUID) -> Any?
}

protocol AgentInfoProtocol: Identifiable, Sendable {
    var id: UUID { get }
    var name: String { get }
    var isBuiltIn: Bool { get }
    var autoSpeak: Bool? { get }
    var ttsVoice: String? { get }
}

struct AgentAutoExecInfo: Sendable {
    let enabled: Bool
}
