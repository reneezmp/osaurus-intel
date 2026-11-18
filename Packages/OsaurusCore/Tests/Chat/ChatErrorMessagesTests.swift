//
//  ChatErrorMessagesTests.swift
//  OsaurusCoreTests
//
//  Stage 5c row 13: upstream Classic's `ChatErrorMessagesTests`, credits and
//  passthrough cases (the workspace and system-resource cases are not on
//  Intel; a workspace 402 must keep its raw text).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Chat error messages")
struct ChatErrorMessagesTests {
    @Test func insufficientFundsGetsAddCreditsMessage() {
        let error = NSError(
            domain: "RemoteProviderService",
            code: 402,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Request failed: HTTP 402: {\"error\":{\"code\":\"INSUFFICIENT_FUNDS\",\"message\":\"balance below estimated max cost\"}}"
            ]
        )

        let message = ChatErrorMessages.assistantMessage(for: error)

        #expect(message == "Error: You're out of credits. Add credits to continue.")
    }

    @Test func intelRouterHttpErrorIsClassified() {
        let error = CloudChatError.httpError(
            provider: "Osaurus Router",
            status: 402,
            message: "{\"error\":{\"code\":\"INSUFFICIENT_FUNDS\"}}"
        )
        #expect(ChatErrorMessages.assistantMessage(for: error).contains("out of credits"))
    }

    @Test func workspacePoolFailureIsNotTreatedAsPersonalCredits() {
        let error = NSError(
            domain: "RemoteProviderService",
            code: 402,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 402: {\"error\":{\"code\":\"WORKSPACE_INSUFFICIENT_FUNDS\"}}"]
        )
        let message = ChatErrorMessages.assistantMessage(for: error)
        #expect(!message.contains("Add credits"))
        #expect(message.contains("WORKSPACE_INSUFFICIENT_FUNDS"))
    }

    @Test func ordinaryRuntimeErrorsKeepOriginalText() {
        let error = NSError(
            domain: "ModelRuntime",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported model type: gemma4_unified"]
        )

        #expect(
            ChatErrorMessages.assistantMessage(for: error)
                == "Error: Unsupported model type: gemma4_unified"
        )
    }
}
