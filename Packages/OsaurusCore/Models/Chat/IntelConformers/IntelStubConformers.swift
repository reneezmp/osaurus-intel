//
//  IntelStubConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel stub conformers — no-op/cloud-only implementations.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - SpeechService (no-op on Intel)

final class IntelSpeechService: SpeechServiceProtocol, @unchecked Sendable {
    static let shared = IntelSpeechService()
    let isRecording: Bool = false

    func stopStreamingTranscription() async {}
    func clearTranscription() {}
}

// MARK: - RemoteProviderManager (cloud-only)

final class IntelRemoteProviderManager: RemoteProviderManagerProtocol, @unchecked Sendable {
    static let shared = IntelRemoteProviderManager()

    struct Config: RemoteProviderConfigInfoProtocol {
        var providers: [any RemoteProviderInfoProtocol] = []
    }

    struct Provider: RemoteProviderInfoProtocol {
        let id: String
        var name: String
        var host: String
        var authType: ProviderAuthType = .apiKey
        var token: String?
    }
    
    enum ProviderAuthType: Sendable { case apiKey, bearerToken, oauth }

    let configuration: RemoteProviderConfigInfoProtocol = Config()

    func isEphemeral(id: String) -> Bool { false }
    func updateProvider(_ provider: any RemoteProviderInfoProtocol, apiKey: String? = nil) {}
    func connect(providerId: String) async throws {}
    func addProvider(_ provider: any RemoteProviderInfoProtocol, isEphemeral: Bool) {}
}

// MARK: - ToolRegistry (stub)

final class IntelToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    static let shared = IntelToolRegistry()

    func resolveExecutionMode(folderContext: Any?, autonomousEnabled: Bool) -> Any? { nil }
    func execute(name: String, argumentsJSON: String) async throws -> String {
        "Tool '\(name)' executed."
    }
}

// MARK: - MemoryService (disabled on Intel)

final class IntelMemoryService: MemoryServiceProtocol, @unchecked Sendable {
    static let shared = IntelMemoryService()
    func bufferTurn(userMessage: String, assistantMessage: String, agentId: UUID, conversationId: UUID, sessionDate: Date) async {}
}

// MARK: - GenerativeGreeting (no-op on Intel)

final class IntelGreetingPool: GenerativeGreetingPoolProtocol, @unchecked Sendable {
    static let shared = IntelGreetingPool()
    func setActive(agent: any AgentInfoProtocol, model: String) async {}
    func popFresh(for agent: any AgentInfoProtocol, model: String) async -> String? { nil }
    func seed(_ cached: [String], for agent: any AgentInfoProtocol, model: String) async {}
    func warmUp(for agent: any AgentInfoProtocol, model: String) async {}
}

final class IntelGreetingService: GenerativeGreetingServiceProtocol, @unchecked Sendable {
    static let shared = IntelGreetingService()
    func generate(agent: any AgentInfoProtocol, fallbackModel: String) async throws -> String? { nil }
}

// MARK: - SharedArtifact (stub)

enum IntelSharedArtifact: SharedArtifactProtocol {
    static func processToolResultDetailed(_ text: String, contextId: String, contextType: String, executionMode: Any?, sandboxAgentName: String?) -> String {
        text
    }
    static func fromEnrichedToolResult(_ resultText: String) -> Any? { nil }
}

typealias SpeechService = IntelSpeechService
typealias RemoteProviderManager = IntelRemoteProviderManager
typealias RemoteProvider = IntelRemoteProviderManager.Provider
typealias ToolRegistry = IntelToolRegistry
typealias MemoryService = IntelMemoryService
typealias GenerativeGreetingPool = IntelGreetingPool
typealias GenerativeGreetingService = IntelGreetingService
typealias SharedArtifact = IntelSharedArtifact

#endif
