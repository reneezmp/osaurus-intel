//
//  IntelStubConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel stub conformers — concretized (no existential protocol types).
//  All types use concrete types matching the Apple Silicon originals byte-for-byte.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - SpeechService (no-op on Intel)

final class SpeechService: @unchecked Sendable {
    static let shared = SpeechService()
    let isRecording: Bool = false

    func stopStreamingTranscription() async {}
    func clearTranscription() {}
}

// MARK: - RemoteProviderManager (cloud-only, concretized)

final class RemoteProviderManager: @unchecked Sendable {
    static let shared = RemoteProviderManager()

    private var _providers: [RemoteProvider] = []

    var configuration: RemoteProviderConfiguration {
        var cfg = RemoteProviderConfiguration()
        return cfg
    }

    func isEphemeral(id: UUID) -> Bool { false }
    func updateProvider(_ provider: RemoteProvider, apiKey: String?) {}
    func connect(providerId: UUID) async throws {}
    func addProvider(_ provider: RemoteProvider, apiKey: String? = nil, isEphemeral: Bool = false) {}
}

// MARK: - ToolRegistry (stub)

final class ToolRegistry: @unchecked Sendable {
    static let shared = ToolRegistry()

    func resolveExecutionMode(folderContext: FolderContext?, autonomousEnabled: Bool) -> ExecutionMode { .none }
    func execute(name: String, argumentsJSON: String) async throws -> String {
        "Tool '\(name)' executed."
    }
}

// MARK: - MemoryService (disabled on Intel)

final class MemoryService: @unchecked Sendable {
    static let shared = MemoryService()
    func bufferTurn(userMessage: String, assistantMessage: String?, agentId: String, conversationId: String, sessionDate: String? = nil) async {}
}

// MARK: - GenerativeGreeting (no-op on Intel)

final class GenerativeGreetingPool: @unchecked Sendable {
    static let shared = GenerativeGreetingPool()
    func setActive(agent: Agent, model: String) async {}
    func popFresh(for agent: Agent, model: String) async -> GenerativeGreeting? { nil }
    func seed(_ cached: GenerativeGreeting, for agent: Agent, model: String) async {}
    func warmUp(for agent: Agent, model: String) async {}
}

final class GenerativeGreetingService: @unchecked Sendable {
    static let shared = GenerativeGreetingService()
    func generate(agent: Agent, fallbackModel: String) async throws -> GenerativeGreeting { throw CancellationError() }
}

// MARK: - SharedArtifact (stub)

enum ArtifactContextType: String, Sendable {
    case work
    case chat
}

struct ProcessingResult: Sendable {
    let enrichedToolResult: String
}

enum SharedArtifact {
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

#endif
