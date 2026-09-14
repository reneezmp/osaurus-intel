//
//  ExecutionContextFolderActivationTests.swift
//  osaurusTests
//
//  Scheduled and watcher work must carry its selected folder into the
//  session-scoped state that composes prompts and binds folder tools.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct ExecutionContextResponseEngine: ChatEngineProtocol {
    let response: String

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "folder-test-title",
            object: nil,
            created: nil,
            model: request.model,
            choices: [.init(
                index: 0,
                message: .init(
                    role: "assistant",
                    content: "Scheduled folder task",
                    tool_calls: nil,
                    reasoning_content: nil
                ),
                finish_reason: "stop"
            )],
            usage: nil
        )
    }
}

@Suite(.serialized)
@MainActor
struct ExecutionContextFolderActivationTests {
    @Test
    func freshDispatchMountsFolderOnItsChatSession() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

        let context = ExecutionContext(
            agentId: Agent.defaultId,
            folderPath: folder.path,
            source: .schedule
        )
        context.chatSession.chatEngineFactory = {
            ExecutionContextResponseEngine(response: "scheduled response")
        }

        await context.prepare()
        await context.start(prompt: "Inspect the scheduled folder")

        #expect(context.chatSession.folderState.rootPath == folder.standardizedFileURL)
        #expect(context.chatSession.folderState.persistedPath == folder.standardizedFileURL.path)
        #expect(await waitForAssistantResponse(in: context.chatSession, containing: "scheduled response"))
            context.cancel()
        }
    }

    @Test
    func reattachedDispatchUsesTheCurrentRequestFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let folder = try makeTemporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }

        let existing = ChatSessionData(
            agentId: Agent.defaultId,
            source: .watcher,
            externalSessionKey: "watcher-folder-regression"
        )
        let context = ExecutionContext(
            reattaching: existing,
            folderPath: folder.path
        )
        context.chatSession.chatEngineFactory = {
            ExecutionContextResponseEngine(response: "watcher response")
        }

        await context.prepare()
        await context.start(prompt: "Inspect the watched folder")

        #expect(context.chatSession.folderState.rootPath == folder.standardizedFileURL)
        #expect(context.chatSession.folderState.persistedPath == folder.standardizedFileURL.path)
        #expect(await waitForAssistantResponse(in: context.chatSession, containing: "watcher response"))
            context.cancel()
        }
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-execution-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL
    }

    private func waitForAssistantResponse(
        in session: ChatSession,
        containing expectedText: String
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while clock.now < deadline {
            if session.turns.contains(where: {
                $0.role == .assistant && $0.content.contains(expectedText)
            }) && !session.isStreaming {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        return false
    }
}
