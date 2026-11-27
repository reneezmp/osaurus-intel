//
//  IntelSandboxSecretTools.swift
//  osaurus
//
//  Intel fork: upstream Classic's `Tools/SandboxSecretTools.swift`
//  (W-seatbelt-sandbox stage 3), narrowed on purpose.
//
//  - `sandbox_secret_check` is upstream's, unchanged in behaviour.
//  - `sandbox_secret_set` supports ONLY the prompt path: the tool returns
//    the secure-dialog marker, `CloudChatEngine` shows the dialog
//    (`IntelSecretPromptIntercept`) and the card stores what the user types.
//    Upstream's direct `value` argument is not in the schema: it would put a
//    credential into the model's tool call. A model that sends one anyway is
//    scrubbed from every recording (`SecretArgumentScrubber`) and the value
//    is ignored. The secret value never enters the conversation.
//  - Output scrubbing of stored secret values (#2157) is
//    `SecretScrubber`, applied by `sandbox_exec`.
//

import Foundation

// MARK: - sandbox_secret_check

struct SandboxSecretCheckTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.secretCheck
    let description =
        "Check whether a named secret exists for the current agent. Returns whether the secret is "
        + "stored — never reveals the value. Useful before a command that needs the secret as an "
        + "env var (so you can `sandbox_secret_set` first if missing)."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name to check (e.g. `NOTION_API_KEY`)."),
                ])
            ]),
            "required": .array([.string("key")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let keyReq = requireString(
            args, "key", expected: "secret name (e.g. `NOTION_API_KEY`)", tool: name)
        guard case .value(let key) = keyReq else { return keyReq.failureEnvelope ?? "" }
        let exists = AgentSecretsKeychain.getSecret(id: key, agentId: context.agentId) != nil
        return ToolEnvelope.success(tool: name, result: ["key": key, "exists": exists])
    }
}

// MARK: - sandbox_secret_set

/// Marker action `sandbox_secret_set` returns; the chat view intercepts it,
/// shows the secure input and replaces the result with stored/cancelled.
enum SecretPromptAction {
    static let actionKey = "secret_prompt"
}

struct SandboxSecretSetTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.secretSet
    let description =
        "Ask the user for a secret (API key, token) and store it securely for the current agent. The user "
        + "gets a secure input dialog and the secret never enters the conversation. Never ask the user to "
        + "paste a secret into chat. Stored secrets are available to `sandbox_exec` as environment "
        + "variables named by `key`."

    var requirements: [String] { [] }
    /// Opens a dialog the user answers, so no extra approval card on top.
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "key": .object([
                    "type": .string("string"),
                    "description": .string("Secret name (e.g. `NOTION_API_KEY`)."),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string("Human-readable description of what this secret is."),
                ]),
                "instructions": .object([
                    "type": .string("string"),
                    "description": .string("Instructions shown to the user on how to obtain this secret."),
                ]),
            ]),
            "required": .array([.string("key"), .string("description"), .string("instructions")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let keyReq = requireString(args, "key", expected: "secret name (e.g. `NOTION_API_KEY`)", tool: name)
        guard case .value(let key) = keyReq else { return keyReq.failureEnvelope ?? "" }
        let descReq = requireString(
            args, "description", expected: "human-readable description of the secret", tool: name)
        guard case .value(let desc) = descReq else { return descReq.failureEnvelope ?? "" }
        let instReq = requireString(
            args, "instructions", expected: "instructions for the user on how to obtain the secret", tool: name)
        guard case .value(let instructions) = instReq else { return instReq.failureEnvelope ?? "" }

        // A run from the owner's paired phone never reaches the chat view
        // that shows the dialog: ask the phone directly (upstream,
        // MOBILE_PROTOCOL section 16.5) and store what it sends.
        if ChatExecutionContext.hasRemoteReviewer {
            let value = await RemoteSecretPromptQueue.shared.request(
                key: key, description: desc, instructions: instructions)
            guard let value, !value.isEmpty else { return SecretToolResult.cancelled(key: key) }
            guard AgentSecretsKeychain.saveSecret(value, id: key, agentId: context.agentId) else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message:
                        "Secret storage failed for `\(key)`: the Keychain write did not succeed, so the value will NOT be available to sandbox commands. Do not report the secret as stored.",
                    tool: name, retryable: false)
            }
            return SecretToolResult.stored(key: key)
        }
        // A run with no chat view to host the dialog (HTTP, background,
        // schedule) cannot collect the secret: say so rather
        // than returning a marker nobody will turn into a prompt.
        guard ChatExecutionContext.interactiveChatRun || SandboxToolContext.testingContext != nil else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Secrets can only be collected in an open chat on this Mac. Tell the user to add `\(key)` in a chat with this agent, or continue there.",
                tool: name, retryable: false)
        }
        return SecretToolResult.encode([
            "action": SecretPromptAction.actionKey,
            "key": key,
            "description": desc,
            "instructions": instructions,
            "agent_id": context.agentId.uuidString,
        ])
    }
}

// MARK: - Shared result encoding

/// Helpers for the secret tools' unusual results: `stored` / `cancelled` use
/// the envelope shape; `encode` is the bare JSON of the prompt marker
/// (deliberately not an envelope: `SecretPromptParser` keys off `action` at
/// the JSON root).
enum SecretToolResult {
    static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical),
            let json = String(data: data, encoding: .utf8)
        else { return "{\"error\":\"Failed to encode result\"}" }
        return json
    }

    static func stored(key: String) -> String {
        ToolEnvelope.success(tool: BuiltinSandboxTools.secretSet, result: ["stored": true, "key": key])
    }

    static func cancelled(key: String) -> String {
        ToolEnvelope.failure(
            kind: .userDenied,
            message: "User cancelled the secret prompt for `\(key)`.",
            tool: BuiltinSandboxTools.secretSet,
            retryable: false
        )
    }
}

/// Parses the marker `sandbox_secret_set` returns. The chat view intercepts
/// it, opens the secure overlay and replaces the tool result.
struct SecretPromptParser {
    let key: String
    let description: String
    let instructions: String
    let agentId: String

    static func parse(_ resultText: String) -> SecretPromptParser? {
        guard let data = resultText.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = json["action"] as? String,
            action == SecretPromptAction.actionKey,
            let key = json["key"] as? String,
            let desc = json["description"] as? String,
            let instructions = json["instructions"] as? String,
            let agentId = json["agent_id"] as? String
        else { return nil }
        return SecretPromptParser(key: key, description: desc, instructions: instructions, agentId: agentId)
    }
}
