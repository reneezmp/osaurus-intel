//
//  IntelAppIntentsClientTests.swift
//  osaurusTests
//
//  W-app-intents (2026-10-10): Intel's in-process `OsaurusLocalClient`.
//  Only the checks that run before anything is dispatched are exercised
//  here; a real dispatch would start a headless agent run.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelAppIntentsClientTests {
    @Test func askRequiresAPrompt() async {
        await #expect(throws: OsaurusLocalClientError.self) {
            _ = try await OsaurusLocalClient.shared.runAgent(id: Agent.defaultId.uuidString, prompt: "   ")
        }
    }

    @Test func unknownAgentsAreRefusedBeforeDispatch() async {
        let missing = UUID().uuidString
        await #expect(throws: OsaurusLocalClientError.self) {
            _ = try await OsaurusLocalClient.shared.runAgent(id: missing, prompt: "hello")
        }
        await #expect(throws: OsaurusLocalClientError.self) {
            try await OsaurusLocalClient.shared.startAgent(id: missing, input: nil)
        }
        await #expect(throws: OsaurusLocalClientError.self) {
            try await OsaurusLocalClient.shared.startAgent(id: "not-a-uuid", input: "go")
        }
    }

    @Test func onlyTheIntentsClientOptsIntoBuiltInAgents() {
        // Every other dispatch source keeps the built-in guard.
        #expect(!DispatchRequest(prompt: "x", agentId: Agent.defaultId, source: .http).allowsBuiltInAgent)
        #expect(!DispatchRequest(prompt: "x", agentId: Agent.defaultId, source: .plugin).allowsBuiltInAgent)
    }

    @Test func errorsReadAsSentences() {
        let errors: [OsaurusLocalClientError] = [
            .agentNotFound, .emptyPrompt, .couldNotStart, .runFailed("boom"), .cancelled, .emptyReply,
        ]
        for error in errors {
            #expect(error.errorDescription?.hasSuffix(".") == true || error.errorDescription?.contains("boom") == true)
        }
    }
}
