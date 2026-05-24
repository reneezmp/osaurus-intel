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
        let id: UUID
        var name: String
        var host: String
        var providerProtocol: RemoteProviderProtocol = .https
        var authType: RemoteProviderAuthType = .none
        var token: String? = nil
        var port: Int? = nil
        var enabled: Bool = true
        var providerType: RemoteProviderType { .osaurus }
        var remoteAgentId: UUID? = nil
        var remoteAgentAddress: String? = nil
    }

    let configuration: RemoteProviderConfigInfoProtocol = Config()

    func isEphemeral(id: UUID) -> Bool { false }
    func updateProvider(_ provider: any RemoteProviderInfoProtocol, apiKey: String?) {}
    func connect(providerId: UUID) async throws {}
    func addProvider(_ provider: any RemoteProviderInfoProtocol, apiKey: String? = nil, isEphemeral: Bool = false) {}

    func addProvider(_ provider: RemoteProvider, apiKey: String?, isEphemeral: Bool) {
        let bridged = Provider(
            id: provider.id,
            name: provider.name,
            host: provider.host,
            providerProtocol: provider.providerProtocol,
            authType: provider.authType,
            port: provider.port,
            enabled: provider.enabled,
            remoteAgentId: provider.remoteAgentId,
            remoteAgentAddress: provider.remoteAgentAddress
        )
        addProvider(bridged as any RemoteProviderInfoProtocol, apiKey: apiKey, isEphemeral: isEphemeral)
    }
}

// MARK: - ToolRegistry (stub)

final class IntelToolRegistry: ToolRegistryProtocol, @unchecked Sendable {
    static let shared = IntelToolRegistry()

    func resolveExecutionMode(folderContext: FolderContext?, autonomousEnabled: Bool) -> ExecutionMode { .none }
    func execute(name: String, argumentsJSON: String) async throws -> String {
        "Tool '\(name)' executed."
    }
}

// MARK: - MemoryService (disabled on Intel)

final class IntelMemoryService: MemoryServiceProtocol, @unchecked Sendable {
    static let shared = IntelMemoryService()
    func bufferTurn(userMessage: String, assistantMessage: String?, agentId: String, conversationId: String, sessionDate: String? = nil) async {}
}

// MARK: - GenerativeGreeting (no-op on Intel)

final class IntelGreetingPool: GenerativeGreetingPoolProtocol, @unchecked Sendable {
    static let shared = IntelGreetingPool()
    func setActive(agent: any AgentInfoProtocol, model: String) async {}
    func popFresh(for agent: any AgentInfoProtocol, model: String) async -> GenerativeGreeting? { nil }
    func seed(_ cached: GenerativeGreeting, for agent: any AgentInfoProtocol, model: String) async {}
    func warmUp(for agent: any AgentInfoProtocol, model: String) async {}
}

final class IntelGreetingService: GenerativeGreetingServiceProtocol, @unchecked Sendable {
    static let shared = IntelGreetingService()
    func generate(agent: any AgentInfoProtocol, fallbackModel: String) async throws -> GenerativeGreeting { throw CancellationError() }
}

// MARK: - SharedArtifact (stub)

enum ArtifactContextType: String, Sendable {
    case work
    case chat
}

struct ProcessingResult: Sendable {
    let enrichedToolResult: String
}

enum IntelSharedArtifact: SharedArtifactProtocol {
    enum ResolutionFailure: Error {
        case markersMissing
        case noContentOrPath
        case destinationRejected(filename: String)
        case pathRejected(path: String)
        case fileNotFound(path: String, searchedLocations: [String])
        case copyFailed(source: String, detail: String)
    }

    static func fromEnrichedToolResult(_ resultText: String) -> Any? { nil }

    static func processToolResultDetailed(
        _ text: String,
        contextId: String,
        contextType: ArtifactContextType,
        executionMode: ExecutionMode,
        sandboxAgentName: String? = nil
    ) -> Result<ProcessingResult, ResolutionFailure> {
        .success(ProcessingResult(enrichedToolResult: text))
    }
}

typealias SpeechService = IntelSpeechService
typealias RemoteProviderManager = IntelRemoteProviderManager
typealias ToolRegistry = IntelToolRegistry
typealias MemoryService = IntelMemoryService
typealias GenerativeGreetingPool = IntelGreetingPool
typealias GenerativeGreetingService = IntelGreetingService
typealias SharedArtifact = IntelSharedArtifact

extension RemoteProvider: RemoteProviderInfoProtocol {}

#endif
