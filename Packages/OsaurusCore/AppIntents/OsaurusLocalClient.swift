#if !OSAURUS_INTEL
//
//  OsaurusLocalClient.swift
//  osaurus
//
//  Thin localhost HTTP client used by the App Intents provider surface.
//
//  Central invariant: intents are thin clients. All execution goes through
//  the existing local HTTP server (`/agents/{id}/run` and
//  `/agents/{id}/dispatch`). This type loads no models, opens no databases,
//  and holds no orchestration logic — it only speaks HTTP to `127.0.0.1` and
//  brings the embedded server up headlessly when needed.
//

import Foundation

/// Errors surfaced to the App Intents layer in a user-readable form.
public enum OsaurusLocalClientError: LocalizedError {
    case serverUnreachable
    case badResponse(status: Int, body: String)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .serverUnreachable:
            return "Osaurus isn't reachable. Open Osaurus and make sure its local server is running."
        case .badResponse(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Osaurus returned an unexpected response (HTTP \(status))."
            }
            return "Osaurus returned an error (HTTP \(status)): \(trimmed)"
        case .emptyReply:
            return "Osaurus didn't return a response."
        }
    }
}

/// Localhost client for the App Intents provider. See file header for the
/// central invariant this type upholds.
public final class OsaurusLocalClient: Sendable {
    public static let shared = OsaurusLocalClient()

    /// Fallback when neither the live nor persisted configuration yields a port.
    private static let defaultPort = 1337

    private init() {}

    // MARK: - Agent resolution

    /// The agent a fresh "Ask Osaurus" targets: the new-chat agent
    /// (`AgentManager.newChatAgentId` — the Orchestrator unless
    /// `new_chat_agent` was applied), restored from persistence on launch.
    /// Not the foreground chat's agent: a Siri/Shortcuts ask is a new
    /// conversation, so it follows the same default as ⌘N. This commonly
    /// resolves to the built-in "Osaurus" agent — which is why the
    /// run/dispatch endpoints relax their built-in guard for loopback callers.
    public func activeAgentID() async -> String {
        await MainActor.run { AgentManager.shared.newChatAgentId.uuidString }
    }

    // MARK: - Execution

    /// `POST /agents/{id}/run`. Sends the prompt as a single user message,
    /// reads the SSE stream to the `[DONE]` frame, and returns the
    /// concatenated assistant text (which includes the tool-loop
    /// budget-exhausted notice when the run hits its iteration cap).
    ///
    /// Note: `/run` is a streaming, connection-bound autonomous loop. A short
    /// ask completes well within an App Intent's time budget; an ask that
    /// triggers heavy tool use can exceed it. Tool-heavy work should prefer
    /// the fire-and-confirm `startAgent(id:input:)` path instead.
    public func runAgent(id: String, prompt: String?) async throws -> String {
        let base = try await ensureServerReachable()

        var request = URLRequest(url: base.appendingPathComponent("agents/\(id)/run"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": "default",
            "messages": [
                ["role": "user", "content": prompt ?? ""]
            ],
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Headers are sent as 200 once streaming starts, so a non-200 here
            // means the request was rejected before the stream began. Drain the
            // (small) error body for a readable message.
            var collected = ""
            for try await line in bytes.lines { collected += line }
            throw OsaurusLocalClientError.badResponse(status: http.statusCode, body: collected)
        }

        var reply = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8) else { continue }

            // In-band SSE error object — surface it rather than returning empty.
            if let err = try? JSONDecoder().decode(SSEErrorEnvelope.self, from: data),
                let message = err.error?.message
            {
                throw OsaurusLocalClientError.badResponse(status: 200, body: message)
            }

            if let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) {
                for choice in chunk.choices ?? [] {
                    if let content = choice.delta?.content { reply += content }
                }
            }
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OsaurusLocalClientError.emptyReply }
        return trimmed
    }

    /// Fire-and-confirm. `POST /agents/{id}/dispatch` starts a detached
    /// background run that survives this client disconnecting; progress and
    /// results surface through the app's own Work Mode and toasts. Returns as
    /// soon as the server accepts the task (HTTP 202).
    public func startAgent(id: String, input: String?) async throws {
        let base = try await ensureServerReachable()

        var request = URLRequest(url: base.appendingPathComponent("agents/\(id)/dispatch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `/dispatch` requires a non-empty prompt. When the intent supplies no
        // input, fall back to a minimal kickoff so the agent still starts.
        let trimmedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = trimmedInput.isEmpty ? "Begin." : trimmedInput
        let body: [String: Any] = ["prompt": prompt]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OsaurusLocalClientError.serverUnreachable
        }
        // Dispatch returns 202 Accepted on success.
        guard http.statusCode == 202 else {
            throw OsaurusLocalClientError.badResponse(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
    }

    // MARK: - Server reachability

    /// Returns the base URL once the local server answers `/health`. If it is
    /// not reachable, starts the embedded server in-process and retries with a
    /// short backoff for a couple of seconds before throwing.
    private func ensureServerReachable() async throws -> URL {
        let base = await resolveBaseURL()

        if await isHealthy(base) { return base }

        // Fast headless server-up path: bring the embedded server up on the
        // live controller instance (no-op if it is already starting).
        await ServerController.ensureRunning()

        // Retry with short backoff (~2s total). The port may change once the
        // server actually binds, so re-resolve the base URL on each attempt.
        let delaysMs: [UInt64] = [150, 250, 400, 500, 700]
        for delay in delaysMs {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            let candidate = await resolveBaseURL()
            if await isHealthy(candidate) { return candidate }
        }

        throw OsaurusLocalClientError.serverUnreachable
    }

    private func isHealthy(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Builds `http://127.0.0.1:<port>` from the live server configuration when
    /// available, then the persisted config, then the default port.
    private func resolveBaseURL() async -> URL {
        let port = await resolvePort()
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private func resolvePort() async -> Int {
        if let live = await ServerController.sharedConfiguration()?.port, live > 0 {
            return live
        }
        if let stored = await MainActor.run(body: { ServerConfigurationStore.load()?.port }), stored > 0 {
            return stored
        }
        return Self.defaultPort
    }

    // MARK: - SSE decoding

    private struct SSEChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    private struct SSEErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }
}
#else

// MARK: - Intel: in-process client (W-app-intents, 2026-10-10)
//
// Upstream's intents are thin HTTP clients of `/agents/{id}/run` and
// `/agents/{id}/dispatch`. Intel's server has neither route (`W-server-api`),
// but App Intents run inside the app process, so this client hands the same
// requests straight to `TaskDispatcher`. That is the path the server's
// dispatch route and plugin `dispatch` take, so behaviour matches:
//
//  - `runAgent` (Ask Osaurus) runs the agent's full tool loop headlessly and
//    waits for its reply. Like upstream's loopback-trusted `/run`, it may
//    target the built-in Default agent (`allowsBuiltInAgent`). Difference:
//    the run is saved as a chat (source "HTTP") instead of being
//    connection-bound.
//  - `startAgent` (Run Agent) is fire-and-confirm, like `/dispatch`:
//    custom agents only, and the result surfaces as a toast.

import Foundation

/// Errors surfaced to the App Intents layer in a user-readable form.
public enum OsaurusLocalClientError: LocalizedError {
    case agentNotFound
    case emptyPrompt
    case couldNotStart
    case runFailed(String)
    case cancelled
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .agentNotFound:
            return "That Osaurus agent no longer exists."
        case .emptyPrompt:
            return "Tell Osaurus what to ask."
        case .couldNotStart:
            return "Osaurus couldn't start the request. Too many tasks may be running; try again shortly."
        case .runFailed(let reason):
            return "Osaurus couldn't finish the request: \(reason)"
        case .cancelled:
            return "The request was cancelled."
        case .emptyReply:
            return "Osaurus didn't return a response."
        }
    }
}

public final class OsaurusLocalClient: Sendable {
    public static let shared = OsaurusLocalClient()

    private init() {}

    // MARK: - Agent resolution

    /// The agent a fresh "Ask Osaurus" targets: the new-chat agent, as upstream
    /// (a Siri/Shortcuts ask is a new conversation, like ⌘N).
    public func activeAgentID() async -> String {
        await MainActor.run { AgentManager.shared.newChatAgentId.uuidString }
    }

    // MARK: - Execution

    /// Runs the agent on `prompt` and returns its final reply text.
    public func runAgent(id: String, prompt: String?) async throws -> String {
        let text = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw OsaurusLocalClientError.emptyPrompt }
        let agentId = try await resolveAgent(id)
        let request = DispatchRequest(
            prompt: text,
            agentId: agentId,
            title: String(text.prefix(60)),
            showToast: false,
            source: .http,
            allowsBuiltInAgent: true
        )
        let reply = try await Self.dispatchAndWait(request)
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OsaurusLocalClientError.emptyReply }
        return trimmed
    }

    /// Fire-and-confirm: starts a background run of a custom agent and returns
    /// once it is accepted. Progress and results surface as toasts.
    public func startAgent(id: String, input: String?) async throws {
        let agentId = try await resolveAgent(id)
        // Upstream `/dispatch` needs a non-empty prompt; with no input, a
        // minimal kickoff still starts the agent.
        let trimmedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = trimmedInput.isEmpty ? "Begin." : trimmedInput
        let request = DispatchRequest(prompt: prompt, agentId: agentId, showToast: true, source: .http)
        guard await TaskDispatcher.shared.dispatch(request) != nil else { throw OsaurusLocalClientError.couldNotStart }
    }

    // MARK: - Helpers

    private func resolveAgent(_ id: String) async throws -> UUID {
        guard let uuid = UUID(uuidString: id) else { throw OsaurusLocalClientError.agentNotFound }
        let exists = await MainActor.run { AgentManager.shared.agents.contains { $0.id == uuid } }
        guard exists else { throw OsaurusLocalClientError.agentNotFound }
        return uuid
    }

    @MainActor
    private static func dispatchAndWait(_ request: DispatchRequest) async throws -> String {
        guard let handle = await TaskDispatcher.shared.dispatch(request) else {
            throw OsaurusLocalClientError.couldNotStart
        }
        switch await TaskDispatcher.shared.awaitCompletion(handle) {
        case .completed(let sessionId):
            return finalReply(taskId: handle.id, sessionId: sessionId)
        case .cancelled:
            throw OsaurusLocalClientError.cancelled
        case .failed(let reason):
            throw OsaurusLocalClientError.runFailed(reason)
        }
    }

    /// The last non-empty assistant message of the finished run: from the live
    /// task while it is still registered, else from the saved chat.
    @MainActor
    static func finalReply(taskId: UUID, sessionId: UUID?) -> String {
        if let turns = BackgroundTaskManager.shared.taskState(for: taskId)?.chatSession?.turns,
            let text = turns.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
        {
            return text
        }
        if let sessionId,
            let saved = ChatSessionsManager.shared.session(for: sessionId)?.turns,
            let text = saved.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content
        {
            return text
        }
        return ""
    }
}

#endif
