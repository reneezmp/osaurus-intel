//
//  GenerativeGreetingProtocols.swift
//  OsaurusCore
//
//  M10 Phase 4b: Protocol surfaces ChatView accesses on greeting infra.
//

import Foundation

protocol GenerativeGreetingPoolProtocol: AnyObject {
    func setActive(agent: any AgentInfoProtocol, model: String) async
    func popFresh(for agent: any AgentInfoProtocol, model: String) async -> GenerativeGreeting?
    func seed(_ cached: GenerativeGreeting, for agent: any AgentInfoProtocol, model: String) async
    func warmUp(for agent: any AgentInfoProtocol, model: String) async
}

protocol GenerativeGreetingServiceProtocol: AnyObject {
    func generate(agent: any AgentInfoProtocol, fallbackModel: String) async throws -> GenerativeGreeting
}
