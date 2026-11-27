//
//  IntelSecretPromptIntercept.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox, `sandbox_secret_set`).
//
//  Upstream Classic's chat view intercepts the `secret_prompt` marker that
//  `sandbox_secret_set` returns, shows `SecretPromptOverlay` through the
//  session's `PromptQueue` and replaces the result with stored/cancelled.
//  On Intel the tool loop runs inside `CloudChatEngine`, so the engine calls
//  `IntelSecretPromptIntercept.resolving` right after a tool returns (one
//  hook in each wire branch) and the chat session's own `promptQueue` shows
//  the card. The value is typed only in the secure field and written to the
//  Keychain by `SecretPromptState.submit`; it never enters a tool argument,
//  a result, the model's context, chat history, Insights or a log.
//
//  Also here: `SecretArgumentScrubber`, upstream's recording-side redaction
//  (Tools/SandboxSecretTools.swift). Intel's schema offers no `value`, but a
//  model can still send one; the engine records only the scrubbed view.
//

import Foundation

// MARK: - Prompt hook

enum IntelSecretPromptIntercept {
    /// Test seam: the queue the prompt goes to when no chat session is bound.
    @TaskLocal static var testingQueue: PromptQueue?

    /// Turns a `sandbox_secret_set` prompt marker into the stored/cancelled
    /// envelope after the user answered the secure dialog. Any other tool
    /// result, or a result that is not the marker, comes back unchanged.
    static func resolving(toolName: String, result: String) async -> String {
        guard SecretArgumentScrubber.isSecretSetToolName(toolName),
            let prompt = SecretPromptParser.parse(result)
        else { return result }
        let seam = testingQueue
        let queue: PromptQueue? = await MainActor.run {
            seam ?? ChatExecutionContext.currentChatSessionBox?.session?.promptQueue
        }
        // No chat to host the card (the tool already refuses these runs):
        // nothing is stored and the model is told so.
        guard let queue else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Secrets can only be collected in an open chat on this Mac. Tell the user to add `\(prompt.key)` in a chat with this agent.",
                tool: BuiltinSandboxTools.secretSet, retryable: false)
        }
        let answered = await MainActor.run { () -> (stream: AsyncStream<Bool>, id: ObjectIdentifier) in
            let (stream, continuation) = AsyncStream<Bool>.makeStream()
            let state = SecretPromptState(
                key: prompt.key, description: prompt.description,
                instructions: prompt.instructions, agentId: prompt.agentId
            ) { value in
                continuation.yield(value != nil)
                continuation.finish()
            }
            // The shared queue keeps a clarify card from popping over a
            // pending secret (and the other way round).
            queue.enqueue(.secret(state))
            return (stream, ObjectIdentifier(state))
        }
        let accepted: Bool = await withTaskCancellationHandler {
            for await value in answered.stream { return value }
            return false
        } onCancel: {
            // Stop pressed while the card is up: close it, store nothing.
            Task { @MainActor in queue.dismiss([answered.id]) }
        }
        guard accepted else { return SecretToolResult.cancelled(key: prompt.key) }
        // The card stores the value; confirm it really landed so the model is
        // never told a secret is available when the Keychain refused it
        // (upstream's direct path reports the same failure).
        guard let agentId = UUID(uuidString: prompt.agentId),
            AgentSecretsKeychain.getSecret(id: prompt.key, agentId: agentId) != nil
        else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Secret storage failed for `\(prompt.key)`: the Keychain write did not succeed, so the value will NOT be available to sandbox commands. Do not report the secret as stored.",
                tool: BuiltinSandboxTools.secretSet, retryable: false)
        }
        return SecretToolResult.stored(key: prompt.key)
    }
}

// MARK: - Recording-side scrubbing

/// Scrubs the secret `value` out of `sandbox_secret_set` tool-call arguments
/// before they land in recorded, model-visible or persisted material
/// (upstream Classic's `SecretArgumentScrubber`, same rules). Fails closed:
/// a malformed or non-serializable payload never re-emits the original.
enum SecretArgumentScrubber {
    static let redactedPlaceholder = "[REDACTED]"
    private static let allowedSecretSetKeys: Set<String> = ["key", "description", "instructions", "value"]
    static let failClosedArgumentsJSON = #"{"value":"[REDACTED]"}"#

    /// Arguments safe for chat history, Insights, logs and the model's next
    /// request. Other tools come back byte for byte.
    static func recordedArguments(toolName: String, argumentsJSON: String) -> String {
        guard isSecretSetToolName(toolName) else { return argumentsJSON }
        guard let data = argumentsJSON.data(using: .utf8),
            var args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return failClosedArgumentsJSON }
        // The schema forbids unknown fields; a stray or nested one could hide
        // a second copy of the secret.
        guard Set(args.keys).isSubset(of: allowedSecretSetKeys),
            args["key"] is String, args["description"] is String, args["instructions"] is String
        else { return failClosedArgumentsJSON }
        guard let rawValue = args["value"] else { return argumentsJSON }
        guard let value = rawValue as? String else { return failClosedArgumentsJSON }
        guard !value.isEmpty, value != redactedPlaceholder else { return argumentsJSON }
        // The model can copy the secret into another string field too.
        for key in ["key", "description", "instructions"] {
            if let string = args[key] as? String {
                args[key] = string.replacingOccurrences(of: value, with: redactedPlaceholder)
            }
        }
        args["value"] = redactedPlaceholder
        guard let scrubbed = try? JSONSerialization.data(withJSONObject: args, options: .osaurusCanonical),
            let json = String(data: scrubbed, encoding: .utf8)
        else { return failClosedArgumentsJSON }
        return json
    }

    static func isSecretSetToolName(_ toolName: String) -> Bool {
        toolName == BuiltinSandboxTools.secretSet
    }

    /// A raw provider response that names the tool may carry a secret `value`
    /// that cannot be rewritten in place; callers drop that snapshot.
    static func wireMentionsSecretSet(_ wire: Data) -> Bool {
        wire.range(of: Data(BuiltinSandboxTools.secretSet.utf8)) != nil
    }
}

extension IntelCodexResponsesCompletion {
    /// The Responses wire replays `outputItems` verbatim, so a secret-set
    /// call's arguments are scrubbed in both the call list and the replayed
    /// item (reasoning items stay exact).
    func scrubbingSecretSetArguments() -> IntelCodexResponsesCompletion {
        guard toolCalls.contains(where: { SecretArgumentScrubber.isSecretSetToolName($0.name) }) else { return self }
        let calls = toolCalls.map { call -> IntelCodexResponsesToolCall in
            IntelCodexResponsesToolCall(
                callID: call.callID, name: call.name,
                arguments: SecretArgumentScrubber.recordedArguments(toolName: call.name, argumentsJSON: call.arguments))
        }
        let items = outputItems.map { item -> [String: Any] in
            guard item["type"] as? String == "function_call",
                let name = item["name"] as? String, SecretArgumentScrubber.isSecretSetToolName(name)
            else { return item }
            var copy = item
            copy["arguments"] = SecretArgumentScrubber.recordedArguments(
                toolName: name, argumentsJSON: item["arguments"] as? String ?? "")
            return copy
        }
        return IntelCodexResponsesCompletion(outputItems: items, toolCalls: calls, usage: usage)
    }
}

extension IntelCodexResponsesFinalization {
    func scrubbingSecretSetArguments() -> IntelCodexResponsesFinalization {
        IntelCodexResponsesFinalization(emissions: emissions, completion: completion.scrubbingSecretSetArguments())
    }
}
