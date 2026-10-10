//
//  CloudChatEngine.swift
//  OsaurusCore
//
//  M10 Phase 1: cloud-backed ChatEngine for Intel fork.
//  Replaces the excluded ChatEngine.swift and ChatEngineProtocol.swift.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - Protocol (mirrors excluded ChatEngineProtocol.swift)

protocol ChatEngineProtocol: Sendable {
    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error>
    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse
}

// MARK: - Response type (mirrors excluded OpenAIAPI.swift)

struct ChatCompletionResponse: Codable, Sendable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable, Sendable {
        let index: Int?
        let message: ResponseMessage?
        let finish_reason: String?
    }

    struct ResponseMessage: Codable, Sendable {
        let role: String?
        let content: String?
        let tool_calls: [ToolCall]?
        let reasoning_content: String?

        private enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, reasoning_content
        }

        init(
            role: String?,
            content: String?,
            tool_calls: [ToolCall]?,
            reasoning_content: String?
        ) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.reasoning_content = reasoning_content
        }

        /// The Router's Qwen completion can return visible text as content
        /// parts. Accept only its exact text-part shape; malformed, tool, and
        /// media parts must remain decoding failures rather than becoming an
        /// empty distillation.
        private struct TextContentPart: Decodable {
            let text: String

            private enum CodingKeys: String, CodingKey { case type, text }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                guard type == "text" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Only text content parts are supported in chat completions"
                    )
                }
                text = try container.decode(String.self, forKey: .text)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role)
            tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
            reasoning_content = try container.decodeIfPresent(String.self, forKey: .reasoning_content)

            guard container.contains(.content), try !container.decodeNil(forKey: .content) else {
                content = nil
                return
            }
            do {
                content = try container.decode(String.self, forKey: .content)
            } catch DecodingError.typeMismatch(_, _) {
                let parts = try container.decode([TextContentPart].self, forKey: .content)
                content = parts.map(\.text).joined()
            }
        }
    }

    struct Usage: Codable, Sendable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

// MARK: - Errors

/// Surfaced when the provider returns a non-2xx HTTP status. Previously the
/// streaming path logged the status but then fell into the SSE parse loop,
/// found no `data:` lines in the JSON error body, reported "0 chunks", and
/// finished silently — the user saw an empty "poof" turn with no explanation.
enum CloudChatError: LocalizedError {
    case httpError(provider: String, status: Int, message: String)
    case outputLimit(provider: String, diagnostic: String)
    case responseDecoding(provider: String, message: String, diagnostic: String)

    var errorDescription: String? {
        switch self {
        case let .httpError(provider, status, message):
            let detail = message.isEmpty ? "no details returned" : message
            return "\(provider) API error \(status): \(detail)"
        case let .outputLimit(provider, diagnostic):
            return "\(provider) exhausted its output-token limit before returning assistant text. Response diagnostic (metadata only): \(diagnostic)"
        case let .responseDecoding(provider, message, diagnostic):
            return "\(provider) returned an unsupported completion response (\(message)). Response diagnostic (privacy-filtered, capped): \(diagnostic)"
        }
    }
}

/// An enabled managed Router owns its qualified `osaurus/...` models even
/// before its signed catalog finishes loading after a cold launch. This narrow
/// rule is shared by endpoint routing and Memory model resolution.
enum IntelRemoteModelEligibility {
    static func providerPrefix(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    static func canRouteQualifiedModelDuringDiscovery(
        _ model: String,
        through provider: RemoteProvider
    ) -> Bool {
        guard provider.enabled, provider.providerType == .osaurusRouter else { return false }
        return model.lowercased().hasPrefix(providerPrefix(provider.name) + "/")
    }

    /// The Router is a managed provider. During a cold launch its provider
    /// record is installed asynchronously, while Memory orphan recovery can
    /// begin immediately. A persisted `osaurus/...` selection must therefore
    /// remain routable in that small window. This does not bless arbitrary
    /// provider-prefixed names: only the managed Router's exact prefix is
    /// eligible, and only while the Router is enabled.
    static func canRouteManagedRouterModelDuringColdLaunch(_ model: String) -> Bool {
        guard OsaurusRouter.isEnabled else { return false }
        return model.lowercased().hasPrefix(providerPrefix("Osaurus") + "/")
    }

    static func provisionalManagedRouterProvider() -> RemoteProvider {
        RemoteProvider(
            id: UUID(uuidString: "2CFBD528-62FD-4EF0-A143-3FE532F03840")!,
            name: "Osaurus",
            host: OsaurusRouter.defaultBaseURL.host ?? "router.osaurus.ai",
            providerProtocol: OsaurusRouter.defaultBaseURL.scheme == "http" ? .http : .https,
            port: OsaurusRouter.defaultBaseURL.port,
            basePath: "",
            authType: .none,
            providerType: .osaurusRouter,
            enabled: true,
            autoConnect: true,
            timeout: 120
        )
    }
}

/// Pull a human-readable message out of an OpenAI-style error body
/// (`{"error":{"message":"…"}}`), falling back to the raw text.
func extractAPIErrorMessage(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        if let err = json["error"] as? [String: Any],
            var msg = err["message"] as? String, !msg.isEmpty
        {
            // OpenRouter wraps the upstream reason in `metadata.raw`
            // behind a generic "Provider returned error" (upstream #3051).
            if let upstream = openRouterUpstreamMessage(err) {
                msg = "\(msg): \(upstream)"
            }
            if let code = err["code"] as? String { return "\(msg) (code: \(code))" }
            if let code = err["code"] as? Int { return "\(msg) (code: \(code))" }
            return msg
        }
        if let msg = json["message"] as? String, !msg.isEmpty { return msg }
    }
    return trimmed
}

/// The upstream provider's message from an OpenRouter error's
/// `metadata.raw`, which is usually a JSON string with its own `message`
/// (or `error.message`) but can be plain text. Upstream
/// `RemoteProviderService.openRouterUpstreamMessage` (#3055).
func openRouterUpstreamMessage(_ error: [String: Any]) -> String? {
    guard let metadata = error["metadata"] as? [String: Any],
        let raw = metadata["raw"] as? String,
        !raw.isEmpty
    else { return nil }
    if let inner = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
        if let message = inner["message"] as? String { return message }
        if let nested = inner["error"] as? [String: Any],
            let message = nested["message"] as? String
        {
            return message
        }
    }
    return raw.count > 300 ? String(raw.prefix(300)) + "..." : raw
}

// MARK: - Cloud Chat Engine

actor ChatEngine: Sendable, ChatEngineProtocol {
    private let source: InferenceSource
    private let model: String
    private let apiBase: String
    private let providerOverride: RemoteProvider?
    private let session: URLSession
    private let credentials: IntelCodexCredentials
    private var codexResponsesLiteSessionIds: [String: String] = [:]
    private var codexResponsesLiteSessionOrder: [String] = []

    // MARK: Insights attribution (upstream CoreModelService / #2964)

    /// Machine label for a one-shot request (`chat_title`,
    /// `memory_distillation`, `compaction`…). Bound by the caller; the row's
    /// path becomes `/internal/<purpose>` as upstream's `CoreModelService`
    /// logs it, and `compaction` rows get the compaction category.
    @TaskLocal static var activityPurpose: String?
    /// Who drives the request when it isn't the engine's own `source`
    /// (delegated helper sessions log as Agent, upstream #2964).
    @TaskLocal static var activitySource: RequestSource?
    /// The orchestrator turn that dispatched a delegated helper, recorded as
    /// `parent_turn_id` (upstream `loggedParentTurnId`).
    @TaskLocal static var activityParentTurnId: UUID?

    /// Upstream logs one-shots as `.system` with no turn, so a title or
    /// memory request made during a reply never answers that reply's
    /// Inspect response (`focus(turnId:)` takes the newest matching row).
    private static func loggedSource(default engineSource: RequestSource) -> RequestSource {
        activitySource ?? (activityPurpose == nil ? engineSource : .system)
    }

    private static var loggedTurnId: UUID? {
        activityPurpose == nil ? ChatExecutionContext.currentAssistantTurnId : nil
    }

    private static func loggedPath(endpointURL: String) -> String {
        if let purpose = activityPurpose { return "/internal/\(purpose)" }
        return URL(string: endpointURL)?.path ?? "/chat/completions"
    }

    init(
        source: InferenceSource = .httpAPI,
        model: String = "deepseek-v4-pro",
        provider: RemoteProvider? = nil,
        session: URLSession = .shared,
        credentials: IntelCodexCredentials = .shared
    ) {
        self.source = source
        self.model = model
        self.providerOverride = provider
        self.session = session
        self.credentials = credentials
        self.apiBase = "https://api.deepseek.com/v1/chat/completions"
    }

    /// Keep Intel's replacement engine visible in Insights just like the
    /// upstream engine. Runtime-only request fields are already excluded by
    /// `ChatCompletionRequest.CodingKeys`.
    fileprivate static func serializeRequestForInsights(_ request: ChatCompletionRequest) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(request),
            let s = String(data: data, encoding: .utf8)
        else { return nil }
        // Upstream: inline images (attachments, screenshots) are replaced by a
        // short marker so the activity log never keeps the base64 bytes.
        return redactInlineImagePayloads(in: s)
    }

    /// Upstream `ChatEngine.redactInlineImagePayloads`, verbatim: replace
    /// each `;base64,<payload>` (64+ chars) with a size marker, keeping the
    /// request shape and ordinary text intact.
    static func redactInlineImagePayloads(in json: String) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: "(;base64,)([A-Za-z0-9+/=]{64,})")
        else { return json }
        let matches = regex.matches(
            in: json,
            range: NSRange(location: 0, length: (json as NSString).length)
        )
        guard !matches.isEmpty else { return json }
        var result = json as NSString
        // Apply replacements back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            let payload = match.range(at: 2)
            guard payload.location != NSNotFound else { continue }
            result =
                result.replacingCharacters(
                    in: payload,
                    with: "[redacted \(payload.length)-char image]"
                ) as NSString
        }
        return result as String
    }

    fileprivate static func estimatedInputTokens(_ request: ChatCompletionRequest) -> Int {
        let messageCharacters = request.messages.reduce(0) { partial, message in
            partial + (message.content?.count ?? 0)
                + (message.tool_calls?.reduce(0) {
                    $0 + $1.function.name.count + $1.function.arguments.count
                } ?? 0)
        }
        let toolCharacters = request.tools?.reduce(0) {
            $0 + $1.function.name.count + ($1.function.description?.count ?? 0)
        } ?? 0
        return max(1, (messageCharacters + toolCharacters) / 4)
    }

    /// Accumulates one streamed tool call across DeepSeek's incremental
    /// `delta.tool_calls` fragments (id + name arrive first, arguments stream
    /// in pieces, keyed by `index`).
    private struct PartialToolCall {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    /// Serialize a ChatMessage into the OpenAI-compatible request shape,
    /// INCLUDING `tool_calls` (assistant) and `tool_call_id` (tool results) —
    /// the original Intel engine dropped both, so multi-turn tool context was
    /// lost. (M12 Gap 3.)
    private func encodeMessage(_ msg: ChatMessage) -> [String: Any] {
        var m: [String: Any] = ["role": msg.role]
        m["content"] = msg.content ?? ""
        if let calls = msg.tool_calls, !calls.isEmpty {
            m["tool_calls"] = calls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    ],
                ]
            }
        }
        if let tcid = msg.tool_call_id { m["tool_call_id"] = tcid }
        return m
    }

    /// Repair a (possibly restored) wire-message sequence so it satisfies
    /// DeepSeek's strict tool-call schema. Sessions persisted by earlier Intel
    /// builds could drop `tool_call_id` on tool-result turns; DeepSeek then
    /// rejects the ENTIRE request with `400 … messages[N]: missing field
    /// tool_call_id`, permanently bricking that conversation. We rebuild a
    /// valid sequence:
    ///   • each `assistant.tool_calls` entry is guaranteed a non-empty id;
    ///   • each following `tool` message is matched, in order, to a pending
    ///     call id (preserving an already-valid id, backfilling a missing one);
    ///   • a `tool` message with no pending call is demoted to plain user text
    ///     so its content survives without breaking the schema;
    ///   • an `assistant.tool_calls` left unanswered gets synthetic empty tool
    ///     results so it isn't a dangling call.
    static func sanitizeToolSequence(_ input: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var pending: [String] = []  // call ids awaiting a tool result, in order
        // Deterministic counter for backfilling missing call ids (see below).
        var synthCounter = 0

        func flushPending() {
            for id in pending {
                out.append(["role": "tool", "tool_call_id": id, "content": "(no result)"])
            }
            pending.removeAll()
        }

        for var msg in input {
            switch msg["role"] as? String {
            case "assistant":
                flushPending()
                if var calls = msg["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    var ids: [String] = []
                    for i in calls.indices {
                        var id = (calls[i]["id"] as? String) ?? ""
                        if id.isEmpty {
                            // DETERMINISTIC synthetic id. This used to be a random
                            // UUID, regenerated on EVERY resend — so a tool-call
                            // message with a missing id (e.g. a conversation restored
                            // from an older build that dropped ids) produced different
                            // bytes each request, and DeepSeek's prefix cache missed on
                            // everything after the first tool call, re-billing the whole
                            // conversation every turn. A position-stable id keeps the
                            // resent history byte-identical so the cache holds.
                            // (Renée, 2026-06-12 — 11M cache-miss tokens.)
                            id = "call_synth_\(synthCounter)"
                            synthCounter += 1
                        }
                        calls[i]["id"] = id
                        ids.append(id)
                    }
                    msg["tool_calls"] = calls
                    pending = ids
                }
                out.append(msg)
            case "tool":
                let existing = (msg["tool_call_id"] as? String) ?? ""
                if !existing.isEmpty, let idx = pending.firstIndex(of: existing) {
                    pending.remove(at: idx)
                    out.append(msg)  // already valid
                } else if !pending.isEmpty {
                    msg["tool_call_id"] = pending.removeFirst()
                    out.append(msg)  // backfilled
                } else {
                    // Orphan tool result — preserve content as user text.
                    let content = (msg["content"] as? String) ?? ""
                    out.append(["role": "user", "content": content.isEmpty ? "(tool result)" : content])
                }
            default:
                flushPending()
                out.append(msg)
            }
        }
        flushPending()
        return out
    }

    /// OpenAI-compatible `tools` array from the request's tool specs. The
    /// JSON-Schema `parameters` come through `JSONValue.anyValue`.
    static func encodeTools(_ tools: [Tool]?) -> [[String: Any]]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { tool in
            var fn: [String: Any] = ["name": tool.function.name]
            if let desc = tool.function.description { fn["description"] = desc }
            let params =
                tool.function.parameters?.withEmptyPropertiesIfMissing
                ?? .object(["type": .string("object"), "properties": .object([:])])
            fn["parameters"] = params.anyValue
            return ["type": "function", "function": fn]
        }
    }

    private func applyReasoningMode(
        _ request: ChatCompletionRequest, endpoint: ResolvedEndpoint, into body: inout [String: Any]
    ) {
        // DSV4 reasoning-mode translation (see RemoteProviderService.dsv4RemoteEffort).
        let effort = request.modelOptions?["reasoningEffort"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let offForm = Self.reasoningOffForm(
            providerType: endpoint.provider?.providerType,
            host: URL(string: endpoint.url)?.host ?? "",
            isOsaurusRouter: endpoint.isOsaurusRouter)
        if request.modelOptions?["disableThinking"]?.boolValue == true {
            Self.applyReasoningOff(offForm, into: &body)
            return
        }
        switch effort {
        case "instruct", "chat", "none", "no_think", "nothink", "off", "disabled", "false":
            Self.applyReasoningOff(offForm, into: &body)
        case .some(let nonEmpty) where !nonEmpty.isEmpty:
            body["reasoning_effort"] = nonEmpty
        case .some, .none:
            Self.applyReasoningOff(offForm, into: &body)
        }
    }

    /// How "reasoning off" reaches the wire for a host (upstream #3042,
    /// `RemoteReasoningPolicy.reasoningOffControls`).
    enum ReasoningOffForm: Equatable {
        /// DeepSeek's `thinking: {"type": "disabled"}`.
        case deepSeekThinking
        /// Self-hosted servers (vLLM, SGLang, llama.cpp, LM Studio) read
        /// `chat_template_kwargs.enable_thinking` and ignore a DeepSeek flag.
        case templateKwargs
        /// Strict hosted schemas reject unknown fields: send nothing.
        case none
    }

    /// Hosted OpenAI-compatible APIs with strict request schemas (unknown
    /// fields are rejected) or their own reasoning switch (upstream list).
    nonisolated static let strictSchemaHosts = [
        "openai.com", "mistral.ai", "groq.com", "x.ai", "perplexity.ai", "googleapis.com",
        "anthropic.com", "cohere", "cerebras.ai", "venice.ai", "deepseek.com",
        "fireworks.ai", "openrouter.ai",
    ]

    /// Intel differences from upstream: the built-in DeepSeek path (no
    /// provider) and any `deepseek` host keep `thinking: disabled` for every
    /// model (Intel always sent it; upstream limits it to DSV4 models), and
    /// the Osaurus Router keeps it too (upstream sends nothing there; Intel's
    /// Router turns have always carried it, and dropping it could turn
    /// reasoning back on for Router models).
    nonisolated static func reasoningOffForm(
        providerType: RemoteProviderType?, host: String, isOsaurusRouter: Bool
    ) -> ReasoningOffForm {
        guard let providerType else { return .deepSeekThinking }
        if isOsaurusRouter || providerType == .osaurusRouter { return .deepSeekThinking }
        switch providerType {
        case .openaiLegacy:
            let lowered = host.lowercased()
            if lowered.contains("deepseek") { return .deepSeekThinking }
            if strictSchemaHosts.contains(where: { lowered.contains($0) }) { return .none }
            return .templateKwargs
        case .azureOpenAI, .anthropic, .openResponses, .openAICodex, .gemini, .osaurus, .osaurusRouter:
            return .none
        }
    }

    private static func applyReasoningOff(_ form: ReasoningOffForm, into body: inout [String: Any]) {
        switch form {
        case .deepSeekThinking: body["thinking"] = ["type": "disabled"]
        case .templateKwargs: body["chat_template_kwargs"] = ["enable_thinking": false]
        case .none: break
        }
    }

    /// Resolve the API key. Order: the `DEEPSEEK_API_KEY` env var (dev
    /// convenience on the build machine), then the key the user saved in
    /// Settings → Providers (stored in the Keychain via RemoteProviderKeychain).
    /// The provider fallback is what lets a double-clicked app — e.g. on Rosy —
    /// work without launching from a terminal with an env var.
    private func resolveAPIKey() async -> String? {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
            !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        return await MainActor.run {
            let providers = RemoteProviderManager.shared.configuration.providers.filter { $0.enabled }
            // Prefer a provider pointed at this engine's host (DeepSeek); fall
            // back to any enabled provider that has a stored key.
            let ordered = providers.sorted { a, b in
                a.host.localizedCaseInsensitiveContains("deepseek")
                    && !b.host.localizedCaseInsensitiveContains("deepseek")
            }
            for p in ordered {
                if let key = RemoteProviderKeychain.getAPIKey(for: p.id),
                    !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return key
                }
            }
            return nil
        }
    }

    /// The resolved HTTP target for a chat request: which URL to POST to and
    /// the auth/extra headers to send.
    private struct ResolvedEndpoint {
        let url: String
        var headers: [String: String]
        let providerLabel: String
        let modelId: String
        /// When true, the request body must be EIP-191 wallet-signed via
        /// `OsaurusRouterAuthSigner` (the hosted Osaurus Router uses signed
        /// `x-wallet-*` headers instead of a Bearer key).
        var isOsaurusRouter: Bool = false
        var provider: RemoteProvider? = nil
        var isCodex: Bool { provider?.providerType == .openAICodex || provider?.authType == .openAICodexOAuth }
    }

    /// Resolve the endpoint + headers for `model`. On Intel a request can route
    /// to EITHER the built-in DeepSeek path (hardcoded URL + `DEEPSEEK_API_KEY`
    /// / saved key) OR any user-configured provider that lists `model` in its
    /// `manualModelIds`. The latter is what lets a local llama.cpp server
    /// (Bonsai) or any OpenAI-compatible endpoint actually receive the request
    /// instead of it silently going to DeepSeek. Order:
    ///   1. An enabled provider that declares `model` wins — its baseURL +
    ///      per-`authType` headers. A no-auth local server is fine (no key).
    ///   2. Otherwise the built-in DeepSeek fallback.
    /// Returns nil only when neither a provider endpoint nor a DeepSeek key is
    /// available, so the caller can surface a clear error.
    private func resolveEndpoint(forModel model: String) async throws -> ResolvedEndpoint? {
        if let provider = providerOverride {
            let path = provider.authType == .openAICodexOAuth ? "/codex/responses" : provider.providerType.chatEndpoint
            guard let url = provider.url(for: path) else { throw EngineError(message: "Invalid provider URL") }
            return ResolvedEndpoint(url: url.absoluteString, headers: [:], providerLabel: provider.name,
                                    modelId: Self.bareModelId(model, for: provider),
                                    isOsaurusRouter: provider.providerType == .osaurusRouter, provider: provider)
        }
        let providerEndpoint: ResolvedEndpoint? = await MainActor.run {
            let manager = RemoteProviderManager.shared
            let providers = manager.configuration.providers.filter { $0.enabled }
            // Match the selected model against each provider's known ids:
            // live-discovered (`/models` probe) ∪ user-typed `manualModelIds`.
            let matchingProviders = providers.filter { provider in
                let discovered = manager.providerStates[provider.id]?.discoveredModels ?? []
                let bare = Self.bareModelId(model, for: provider)
                return discovered.contains(bare)
                    || provider.manualModelIds.contains(bare)
                    || IntelRemoteModelEligibility.canRouteQualifiedModelDuringDiscovery(
                        model,
                        through: provider
                    )
            }
            let owner: RemoteProvider?
            if model.contains("/") {
                owner = matchingProviders.first {
                    model.lowercased().hasPrefix(Self.providerPrefix($0.name) + "/")
                }
            } else {
                // Backward compatibility for old bare-id sessions. Route only
                // when ownership is unambiguous; duplicate ids stay inert until
                // the picker saves a provider-qualified id.
                owner = matchingProviders.count == 1 ? matchingProviders[0] : nil
            }
            // Use the provider's own chat endpoint, not a hardcoded path: the
            // Osaurus Router serves OpenAI-compatible inference under `/v1/...`
            // (its account API lives at root) while its provider `basePath` is
            // empty, so the `/v1` must come from `chatEndpoint`. Standard
            // OpenAI-compatible providers still resolve to `/chat/completions`
            // with any `/v1` carried by their own `basePath`.
            guard let owner else { return nil }
            let path = owner.authType == .openAICodexOAuth ? "/codex/responses" : owner.providerType.chatEndpoint
            guard let url = owner.url(for: path) else { return nil }

            // Credential reads happen after leaving MainActor, below.
            return ResolvedEndpoint(
                url: url.absoluteString,
                headers: [:],
                providerLabel: owner.name,
                modelId: Self.bareModelId(model, for: owner),
                isOsaurusRouter: owner.providerType == .osaurusRouter,
                provider: owner
            )
        }
        if var providerEndpoint {
            providerEndpoint.headers = try await requestHeaders(for: providerEndpoint)
            NSLog(
                "[CloudChatEngine] Routing model=\(model) → provider '\(providerEndpoint.providerLabel)' @ \(providerEndpoint.url)"
            )
            return providerEndpoint
        }
        // The managed Router's provider record is installed asynchronously at
        // launch. Memory recovery may run before that task has populated the
        // manager, so route a persisted qualified Router model through the
        // same managed endpoint rather than falsely falling back to DeepSeek
        // or declaring it unavailable. The signer still enforces identity and
        // the Router still validates the selected model.
        if IntelRemoteModelEligibility.canRouteManagedRouterModelDuringColdLaunch(model) {
            let provider = IntelRemoteModelEligibility.provisionalManagedRouterProvider()
            let path = provider.providerType.chatEndpoint
            guard let url = provider.url(for: path) else { return nil }
            var endpoint = ResolvedEndpoint(
                url: url.absoluteString,
                headers: [:],
                providerLabel: provider.name,
                modelId: Self.bareModelId(model, for: provider),
                isOsaurusRouter: true,
                provider: provider
            )
            endpoint.headers = try await requestHeaders(for: endpoint)
            return endpoint
        }
        // Built-in DeepSeek fallback.
        guard let key = await resolveAPIKey() else { return nil }
        return ResolvedEndpoint(
            url: apiBase,
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(key)"],
            providerLabel: "DeepSeek",
            modelId: model.split(separator: "/", maxSplits: 1).last.map(String.init) ?? model
        )
    }

    private nonisolated static func providerPrefix(_ name: String) -> String {
        IntelRemoteModelEligibility.providerPrefix(name)
    }

    private nonisolated static func bareModelId(_ model: String, for provider: RemoteProvider) -> String {
        let prefix = providerPrefix(provider.name) + "/"
        guard model.lowercased().hasPrefix(prefix) else { return model }
        return String(model.dropFirst(prefix.count))
    }

    private func requestHeaders(for endpoint: ResolvedEndpoint) async throws -> [String: String] {
        guard let provider = endpoint.provider else { return endpoint.headers }
        if endpoint.isCodex {
            let tokens = try await credentials.tokens(for: provider.id)
            var headers = await provider.resolvedHeadersOffMainActor()
            // Use the refreshed value, not an independently cached token.
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
            headers["chatgpt-account-id"] = tokens.accountId
            headers["OpenAI-Beta"] = "responses=experimental"
            headers["originator"] = "codex_cli_rs"
            headers["User-Agent"] = OpenAICodexOAuthService.codexUserAgent()
            headers["Accept"] = "text/event-stream"
            headers["Content-Type"] = "application/json"
            return headers
        }
        var headers = await provider.resolvedHeadersOffMainActor()
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        return headers
    }

    /// Reasoning effort for a Codex request. An explicit choice wins ("off"
    /// and friends send none). With no choice, a reasoning model gets the
    /// default its picker already shows: Codex only streams a reasoning
    /// summary (the chat's "Thinking") when a `reasoning` object is sent, so a
    /// fresh model such as GPT-6 otherwise answers with no Thinking at all.
    static func codexReasoningEffort(
        modelId: String,
        options: [String: ModelOptionValue]?
    ) -> String? {
        if let raw = options?["reasoningEffort"]?.stringValue {
            let effort = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !effort.isEmpty, !["off", "disabled", "false", "none"].contains(effort) else {
                return nil
            }
            return effort
        }
        return ModelProfileRegistry.defaults(for: modelId)["reasoningEffort"]?.stringValue?.lowercased()
    }

    private func codexResponsesLiteSessionId(for sourceKey: String?) -> String {
        let key = sourceKey.flatMap { $0.isEmpty ? nil : $0 } ?? "request-\(UUID().uuidString)"
        if let existing = codexResponsesLiteSessionIds[key] { return existing }
        if codexResponsesLiteSessionIds.count >= 1_024,
            let oldest = codexResponsesLiteSessionOrder.first
        {
            codexResponsesLiteSessionIds.removeValue(forKey: oldest)
            codexResponsesLiteSessionOrder.removeFirst()
        }
        let generated = Self.makeUUIDv7()
        codexResponsesLiteSessionIds[key] = generated
        codexResponsesLiteSessionOrder.append(key)
        return generated
    }

    static func makeUUIDv7(now: Date = Date(), randomUUID: UUID = UUID()) -> String {
        var bytes = withUnsafeBytes(of: randomUUID.uuid) { Array($0) }
        let milliseconds = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        bytes[0] = UInt8((milliseconds >> 40) & 0xff)
        bytes[1] = UInt8((milliseconds >> 32) & 0xff)
        bytes[2] = UInt8((milliseconds >> 24) & 0xff)
        bytes[3] = UInt8((milliseconds >> 16) & 0xff)
        bytes[4] = UInt8((milliseconds >> 8) & 0xff)
        bytes[5] = UInt8(milliseconds & 0xff)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return "\(hex[0...3].joined())-\(hex[4...5].joined())-\(hex[6...7].joined())-\(hex[8...9].joined())-\(hex[10...15].joined())"
    }

    func streamChat(request: ChatCompletionRequest) async throws -> AsyncThrowingStream<String, Error> {
        let resolvedModel = request.model ?? model
        if IntelClaudeCodeService.handles(resolvedModel) {
            return try await IntelClaudeCodeService.shared.streamChat(request: request)
        }
        let toolSpecs = Self.encodeTools(request.tools)

        guard let endpoint = try await resolveEndpoint(forModel: resolvedModel) else {
            throw EngineError(
                message:
                    "No endpoint for model \"\(resolvedModel)\". Add a provider (and key, if it needs one) in Settings → Providers, or set the DEEPSEEK_API_KEY env var."
            )
        }
        let usesResponsesLite = endpoint.isCodex
            && OpenAICodexOAuthService.usesResponsesLite(modelId: endpoint.modelId)
        let responsesLiteSessionId = usesResponsesLite
            ? codexResponsesLiteSessionId(for: request.session_id)
            : nil

        NSLog("[CloudChatEngine] Starting streamChat — model=\(resolvedModel), via=\(endpoint.providerLabel), messages=\(request.messages.count), tools=\(request.tools?.count ?? 0)")

        // Insights attribution (upstream #1350 / #2964): ChatView binds the
        // assistant turn, agent and chat around `streamChat`; capture them
        // here, since task-locals aren't reliable on the stream's end path.
        let loggedTurnId = Self.loggedTurnId
        let loggedPath = Self.loggedPath(endpointURL: endpoint.url)
        let loggedSource = Self.loggedSource(default: source)
        let loggedParentTurnId = Self.activityParentTurnId
        let loggedAgentId = ChatExecutionContext.currentAgentId
        let loggedSessionId = ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:))
        let connection = RequestConnectionInfo(
            providerId: endpoint.provider?.id,
            remoteEndpoint: endpoint.url,
            transport: .direct,
            mode: .remoteInference
        )
        // Intel builds its own requests (upstream's RemoteProviderService
        // isn't compiled), so it feeds the probe directly: the first round's
        // request bytes and the raw response stream, as upstream records them.
        let wireProbe = WireTransportProbe()

        return AsyncThrowingStream { continuation in
            let task = Task {
                let inferenceStartedAt = Date()
                let requestBody = Self.serializeRequestForInsights(request)
                var responseText = ""
                var promptTokens: Int?
                var completionTokens: Int?
                var insightToolCalls: [ToolCallLog] = []
                var didLogInference = false

                // Automatic tool discovery (docs/TOOL_DISCOVERY_INTEL.md):
                // `capabilities` loads tools mid-run; they join the request
                // (and so the offered-tool check) from the next round on.
                var activeTools: [Tool]? = request.tools
                var liveToolSpecs = toolSpecs
                let loadBuffer = CapabilityLoadBuffer()

                func captureResponseText(_ emission: String) {
                    guard !StreamingToolHint.isSentinel(emission),
                        StreamingReasoningHint.decode(emission) == nil,
                        StreamingStatsHint.decode(emission) == nil
                    else { return }
                    responseText += emission
                }

                func logInference(error: Error? = nil) {
                    guard !didLogInference else { return }
                    didLogInference = true
                    let outputTokens = completionTokens
                        ?? max(responseText.isEmpty ? 0 : 1, responseText.count / 4)
                    let wire = wireProbe.snapshot()
                    InsightsService.logInference(
                        source: loggedSource,
                        turnId: loggedTurnId,
                        parentTurnId: loggedParentTurnId,
                        model: resolvedModel,
                        inputTokens: promptTokens ?? Self.estimatedInputTokens(request),
                        outputTokens: outputTokens,
                        durationMs: Date().timeIntervalSince(inferenceStartedAt) * 1_000,
                        temperature: request.temperature.map(Float.init),
                        maxTokens: request.max_tokens ?? 0,
                        toolCalls: insightToolCalls.isEmpty ? nil : insightToolCalls,
                        finishReason: error == nil ? .stop : .error,
                        errorMessage: error?.localizedDescription,
                        requestBody: requestBody,
                        responseBody: responseText.isEmpty ? nil : responseText,
                        wireRequestBody: wire.request,
                        wireResponseBody: wire.response.isEmpty ? nil : wire.response,
                        connection: connection,
                        path: loggedPath,
                        agentId: loggedAgentId,
                        sessionId: loggedSessionId
                    )
                }

                do {
                    // Running conversation as wire dicts. We append the
                    // assistant tool-call message + tool-result messages after
                    // each tool round so the continuation request carries the
                    // full context. (M12 Gap 3 — engine-side agent loop, since
                    // the upstream RemoteProviderService tool path is amputated
                    // on Intel.)
                    var wireMessages = Self.sanitizeToolSequence(
                        request.messages.map { self.encodeMessage($0) }
                    )
                    var codexReplayItems: [[String: Any]] = []
                    let maxToolRounds = 12
                    var round = 0
                    var totalChunks = 0

                    while round < maxToolRounds {
                        try Task.checkCancellation()
                        round += 1

                        var body: [String: Any] = [
                            "model": endpoint.modelId,
                            "messages": wireMessages,
                            "stream": true,
                        ]
                        if let liveToolSpecs {
                            body["tools"] = liveToolSpecs
                            body["tool_choice"] = "auto"
                        }
                        if endpoint.isCodex {
                            if let effort = Self.codexReasoningEffort(
                                modelId: endpoint.modelId, options: request.modelOptions)
                            {
                                body["reasoning_effort"] = effort
                            }
                            body = try IntelCodexResponsesAdapter.makeRequest(
                                chatCompletions: body,
                                responsesLiteSessionId: responsesLiteSessionId
                            )
                            var input = body["input"] as? [[String: Any]] ?? []
                            input.append(contentsOf: codexReplayItems)
                            body["input"] = input
                        } else {
                            // Ask for a final usage chunk so the prompt-cache hit/miss
                            // split is observable per request (logged below).
                            body["stream_options"] = ["include_usage": true]
                            Self.applyPromptCacheRouting(
                                provider: endpoint.provider,
                                sessionId: request.session_id,
                                into: &body
                            )
                            self.applyReasoningMode(request, endpoint: endpoint, into: &body)
                        }

                        var urlRequest = URLRequest(url: URL(string: endpoint.url)!)
                        urlRequest.httpMethod = "POST"
                        for (k, v) in try await self.requestHeaders(for: endpoint) { urlRequest.setValue(v, forHTTPHeaderField: k) }
                        if let responsesLiteSessionId {
                            urlRequest.setValue(responsesLiteSessionId, forHTTPHeaderField: "session-id")
                            urlRequest.setValue(responsesLiteSessionId, forHTTPHeaderField: "x-session-affinity")
                            urlRequest.setValue(OpenAICodexOAuthService.codexClientVersion, forHTTPHeaderField: "version")
                            urlRequest.setValue("true", forHTTPHeaderField: "x-openai-internal-codex-responses-lite")
                        }
                        urlRequest.timeoutInterval = 300
                        // CANONICAL (sorted-key) serialization — bare JSONSerialization emits
        // keys in hash order, which differs across app launches (and can differ
        // per nested dict), changing the request bytes for a logically-identical
        // conversation. DeepSeek's prompt cache only matches a BYTE-identical
        // prefix, so non-canonical bytes meant every request missed the cache and
        // re-billed the whole history. Matches upstream's osaurusCanonical wire
        // contract (JSONDeterminism.swift). (Renée, 2026-06-13 — 11M cache miss.)
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: .osaurusCanonical)
        // Authored tool property order (upstream `ToolWirePropertyOrder`,
        // applied by RemoteProviderService right before send): constrained
        // decoders can only emit keys in declared order, so `file_edit`'s
        // `old_string` must precede `new_string`. Before any Router signing.
        urlRequest.httpBody = urlRequest.httpBody.map { ToolWirePropertyOrder.apply(to: $0) }
                        // Osaurus Router: EIP-191 wallet-sign the request body.
                        if endpoint.isOsaurusRouter {
                            try await OsaurusRouterAuthSigner().sign(
                                request: &urlRequest, body: urlRequest.httpBody)
                        }
                        NSLog("[CloudChatEngine] Request body: model=\(resolvedModel) round=\(round) tools=\(liveToolSpecs?.count ?? 0)")
                        if let httpBody = urlRequest.httpBody { wireProbe.recordRequestBody(httpBody) }

                        let (asyncBytes, response) = try await self.session.bytes(for: urlRequest)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        NSLog("[CloudChatEngine] HTTP status: \(statusCode)")
                        if !(200...299).contains(statusCode) {
                            // Non-2xx: the body is a JSON error, not an SSE
                            // stream. Drain it, log it, and surface it so the
                            // user sees WHY instead of a silent empty turn.
                            var errorBody = ""
                            for try await line in asyncBytes.lines { errorBody += line }
                            wireProbe.appendResponseChunk(Data(errorBody.utf8))
                            let message = extractAPIErrorMessage(errorBody)
                            NSLog("[CloudChatEngine] HTTP \(statusCode) error body: \(message)")
                            let httpError = CloudChatError.httpError(
                                provider: endpoint.providerLabel, status: statusCode, message: message)
                            // The failed request is on the record too (it reached
                            // the provider), with its wire bytes.
                            logInference(error: httpError)
                            continuation.finish(throwing: httpError)
                            return
                        }

                        var assistantContent = ""
                        var partials: [Int: PartialToolCall] = [:]
                        var announcedNames: Set<Int> = []

                        // Router billing (upstream `RemoteProviderService`):
                        // however this round's stream ends, a connected Router
                        // stream that never delivered its summary frame may
                        // still have been charged, and the local balance
                        // decrement never ran. Ask for a debounced
                        // server-truth refresh.
                        var routerSummarySeen = false
                        defer {
                            if endpoint.isOsaurusRouter, !routerSummarySeen {
                                Task { @MainActor in
                                    OsaurusRouterAccountService.shared.reconcileAfterStreamWithoutSummary()
                                }
                            }
                        }

                        if endpoint.isCodex {
                            let allowedTools = Set(activeTools?.map { $0.function.name } ?? [])
                            var decoder = IntelCodexResponsesSSEDecoder(allowedToolNames: allowedTools)
                            var buffer = Data()
                            for try await byte in asyncBytes {
                                try Task.checkCancellation()
                                buffer.append(byte)
                                if buffer.count >= 2_048 {
                                    wireProbe.appendResponseChunk(buffer)
                                    for emission in try decoder.append(buffer) {
                                        totalChunks += 1
                                        captureResponseText(emission)
                                        continuation.yield(emission)
                                    }
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            }
                            if !buffer.isEmpty {
                                wireProbe.appendResponseChunk(buffer)
                                for emission in try decoder.append(buffer) {
                                    totalChunks += 1
                                    captureResponseText(emission)
                                    continuation.yield(emission)
                                }
                            }
                            let finalized = try decoder.finish()
                            for emission in finalized.emissions {
                                totalChunks += 1
                                captureResponseText(emission)
                                continuation.yield(emission)
                            }
                            if finalized.completion.toolCalls.isEmpty {
                                NSLog("[CloudChatEngine] Codex stream finished — \(totalChunks) chunks, \(round) round(s)")
                                logInference()
                                continuation.finish()
                                return
                            }

                            var results: [IntelCodexResponsesToolResult] = []
                            var runEndedByTool = false
                            for rawCall in finalized.completion.toolCalls {
                                try Task.checkCancellation()
                                let call = IntelCodexResponsesToolCall(
                                    callID: rawCall.callID,
                                    name: Self.resolvedOfferedToolName(rawCall.name, offered: activeTools),
                                    arguments: rawCall.arguments
                                )
                                guard activeTools?.contains(where: { $0.function.name == call.name }) == true else {
                                    continuation.yield(
                                        StreamingToolHint.encodeDone(
                                            callId: call.callID,
                                            name: call.name,
                                            arguments: call.arguments,
                                            result: Self.unofferedToolResult(call.name)
                                        )
                                    )
                                    throw EngineError(message: "The provider requested a tool that was not offered: \(call.name)")
                                }
                                // Upstream checks arguments before its permission gate: a call
                                // that cannot run is never put in front of the user. Treated
                                // as Auto here; `execute` returns the `invalid_args` envelope.
                                let preflightRejected = await ToolRegistry.shared.preflightRejection(
                                    name: call.name, argumentsJSON: call.arguments) != nil
                                let policy = preflightRejected ? .auto : ToolRegistry.shared.effectivePolicy(
                                    for: call.name, argumentsJSON: call.arguments)
                                let ownsApproval = ToolRegistry.shared.handlesOwnApproval(for: call.name)
                                let approved: Bool
                                switch policy {
                                case .deny: approved = false
                                case .auto: approved = true
                                case .ask:
                                    if ownsApproval {
                                        approved = true
                                        break
                                    }
                                    // Upstream #2241: the global auto-allow switch
                                    // replaces the card, except for per-call tools.
                                    if ToolApprovalSettings.skipsApprovalCard(
                                        perCallRequired: ToolRegistry.shared.requiresApprovalEveryCall(
                                            call.name, argumentsJSON: call.arguments))
                                    {
                                        approved = true
                                        break
                                    }
                                    let description = activeTools?.first(where: { $0.function.name == call.name })?.function.description ?? ""
                                    approved = await ToolPermissionPromptService.requestApproval(
                                        toolName: call.name,
                                        description: description,
                                        argumentsJSON: call.arguments,
                                        knowledgeWritePreview: await ToolRegistry.shared.knowledgeWritePreview(
                                            for: call.name, argumentsJSON: call.arguments)
                                    )
                                }
                                let result: String
                                if !approved {
                                    let reason = policy == .deny
                                        ? "blocked by your tool permissions (Deny)"
                                        : "you declined to run it this time"
                                    result = "⛔️ “\(call.name)” was not run — \(reason)."
                                } else {
                                    do {
                                        // Tools that bind UI to their call (`speak`)
                                        // read the call id from the task-local.
                                        result = try await ChatExecutionContext.$currentToolCallId.withValue(
                                            call.callID
                                        ) {
                                            try await CapabilityLoadBuffer.$current.withValue(loadBuffer) {
                                                try await ToolRegistry.shared.execute(
                                                    name: call.name,
                                                    argumentsJSON: call.arguments
                                                )
                                            }
                                        }
                                    } catch {
                                        result = ToolEnvelope.fromError(error, tool: call.name)
                                    }
                                }
                                continuation.yield(
                                    StreamingToolHint.encodeDone(
                                        callId: call.callID,
                                        name: call.name,
                                        arguments: call.arguments,
                                        result: result
                                    )
                                )
                                if let adopted = await Self.adoptingLoadedTools(from: loadBuffer, into: activeTools) {
                                    activeTools = adopted
                                    liveToolSpecs = Self.encodeTools(adopted)
                                }
                                insightToolCalls.append(
                                    ToolCallLog(
                                        name: call.name,
                                        arguments: call.arguments,
                                        result: result,
                                        isError: result.hasPrefix("⛔️")
                                    )
                                )
                                results.append(.init(callID: call.callID, output: result))
                                if AgentLoopRunEnd.endsRun(toolName: call.name, result: result) {
                                    runEndedByTool = true
                                }
                            }
                            // `complete` / `clarify` / `prompt_working_folder`
                            // end the run: the chat reacts to their result
                            // cards instead of asking the model again.
                            if runEndedByTool {
                                NSLog("[CloudChatEngine] Run ended by an agent-loop tool")
                                logInference()
                                continuation.finish()
                                return
                            }
                            codexReplayItems.append(
                                contentsOf: try finalized.completion.replayInputItems(toolResults: results)
                            )
                            continue
                        }

                        for try await line in asyncBytes.lines {
                            try Task.checkCancellation()
                            wireProbe.appendResponseChunk(Data((line + "\n").utf8))
                            guard line.hasPrefix("data: ") else { continue }
                            let dataStr = String(line.dropFirst(6))
                            if dataStr == "[DONE]" { break }

                            guard let chunkData = dataStr.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any]
                            else {
                                // Shape only — never log payload bytes; SSE frames carry
                                // the user's conversation content.
                                NSLog(
                                    "[CloudChatEngine] Skipped unparseable SSE frame (\(dataStr.utf8.count) bytes)"
                                )
                                continue
                            }

                            // DeepSeek's final usage chunk (from stream_options) carries
                            // the prompt-cache split. Log it so cache hit/miss is
                            // measurable per request in Console.app.
                            if let usage = json["usage"] as? [String: Any] {
                                promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                                completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
                                let hit = usage["prompt_cache_hit_tokens"] as? Int ?? -1
                                let miss = usage["prompt_cache_miss_tokens"] as? Int ?? -1
                                let promptTok = usage["prompt_tokens"] as? Int ?? -1
                                NSLog(
                                    "[CloudChatEngine] CACHE prompt=\(promptTok) hit=\(hit) miss=\(miss) round=\(round)"
                                )
                            }

                            // Router billing summary (`{"osaurus": {…}}`): update
                            // the balance and hand the charge to the chat as a
                            // hidden hint (upstream). Router endpoints only.
                            if endpoint.isOsaurusRouter,
                                let summary = Self.routerSummary(fromFrame: json, data: chunkData)
                            {
                                routerSummarySeen = true
                                Task { @MainActor in
                                    OsaurusRouterAccountService.shared.noteRouterSummary(summary)
                                }
                                continuation.yield(StreamingBillingHint.encode(RouterBillingSummary(summary)))
                                continue
                            }

                            guard let choices = json["choices"] as? [[String: Any]],
                                let delta = choices.first?["delta"] as? [String: Any]
                            else {
                                // Expected for usage-only frames; also the shape the
                                // Osaurus Router's billing-summary frame arrives in.
                                // Log top-level keys only — never the payload.
                                NSLog(
                                    "[CloudChatEngine] Non-delta SSE frame keys=\(json.keys.sorted().joined(separator: ","))"
                                )
                                continue
                            }

                            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                                totalChunks += 1
                                continuation.yield(StreamingReasoningHint.encode(reasoning))
                            }
                            if let content = delta["content"] as? String, !content.isEmpty {
                                totalChunks += 1
                                assistantContent += content
                                responseText += content
                                continuation.yield(content)
                            }
                            // Accumulate streamed tool calls (M12 Gap 3).
                            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                                for tc in tcs {
                                    let idx = tc["index"] as? Int ?? 0
                                    var partial = partials[idx] ?? PartialToolCall()
                                    if let id = tc["id"] as? String, !id.isEmpty { partial.id = id }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let n = fn["name"] as? String, !n.isEmpty { partial.name += n }
                                        // Surface the tool name once, BEFORE
                                        // streaming args, so the call card
                                        // appears immediately and the query
                                        // fills into it live (mirrors upstream:
                                        // card-with-query first, result later).
                                        if !partial.name.isEmpty, !announcedNames.contains(idx) {
                                            announcedNames.insert(idx)
                                            continuation.yield(StreamingToolHint.encode(partial.name))
                                        }
                                        if let a = fn["arguments"] as? String, !a.isEmpty {
                                            partial.arguments += a
                                            // Stream the args into the pending
                                            // card so the user sees the query
                                            // build up — not just a bare name.
                                            continuation.yield(StreamingToolHint.encodeArgs(a))
                                        }
                                    }
                                    partials[idx] = partial
                                }
                            }
                        }

                        // No tools requested this round → the assistant's final
                        // answer has streamed; we're done.
                        if partials.isEmpty {
                            NSLog("[CloudChatEngine] Stream finished — \(totalChunks) chunks, \(round) round(s), no tool calls")
                            logInference()
                            continuation.finish()
                            return
                        }

                        // Echo the assistant's tool-call message into the
                        // continuation context.
                        let orderedCalls = partials.sorted { $0.key < $1.key }.map { entry in
                            var call = entry.value
                            call.name = Self.resolvedOfferedToolName(call.name, offered: activeTools)
                            return call
                        }
                        wireMessages.append([
                            "role": "assistant",
                            "content": assistantContent,
                            "tool_calls": orderedCalls.map { call in
                                [
                                    "id": call.id,
                                    "type": "function",
                                    "function": ["name": call.name, "arguments": call.arguments],
                                ]
                            },
                        ])

                        // Execute each tool, surface the result card, and feed
                        // the result back as a tool message.
                        var runEndedByTool = false
                        for call in orderedCalls {
                            try Task.checkCancellation()
                            let callId = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(20))" : call.id
                            guard activeTools?.contains(where: { $0.function.name == call.name }) == true else {
                                // A stale provider-side tool choice is still a
                                // security rejection, but the card already
                                // exists because its name/arguments streamed
                                // earlier. Terminate that card before failing
                                // the turn so Ventura does not display an
                                // eternal in-progress call.
                                continuation.yield(
                                    StreamingToolHint.encodeDone(
                                        callId: callId,
                                        name: call.name,
                                        arguments: call.arguments,
                                        result: Self.unofferedToolResult(call.name)
                                    )
                                )
                                throw EngineError(message: "The provider requested a tool that was not offered: \(call.name)")
                            }
                            let result: String
                            let toolStart = Date()

                            // Enforce the user's per-tool permission policy
                            // (Tools / Permissions tab). Deny blocks the tool;
                            // Ask shows a confirmation before running; Auto runs.
                            // Upstream checks arguments before its permission gate (see
                            // the batch path above).
                            let preflightRejected = await ToolRegistry.shared.preflightRejection(
                                name: call.name, argumentsJSON: call.arguments) != nil
                            let policy = preflightRejected ? .auto : ToolRegistry.shared.effectivePolicy(
                                for: call.name, argumentsJSON: call.arguments)
                            let ownsApproval = ToolRegistry.shared.handlesOwnApproval(for: call.name)
                            let approved: Bool
                            switch policy {
                            case .deny:
                                approved = false
                            case .auto:
                                approved = true
                            case .ask:
                                if ownsApproval {
                                    approved = true
                                    break
                                }
                                // Upstream #2241: the global auto-allow switch
                                // replaces the card, except for per-call tools.
                                if ToolApprovalSettings.skipsApprovalCard(
                                    perCallRequired: ToolRegistry.shared.requiresApprovalEveryCall(
                                        call.name, argumentsJSON: call.arguments))
                                {
                                    approved = true
                                    break
                                }
                                // Real upstream permission card (ToolPermissionView via
                                // ToolPermissionPromptService) — Allow / Deny / Always Allow.
                                // "Always Allow" persists the policy internally.
                                let toolDescription =
                                    activeTools?
                                    .first(where: { $0.function.name == call.name })?
                                    .function.description ?? ""
                                approved = await ToolPermissionPromptService.requestApproval(
                                    toolName: call.name,
                                    description: toolDescription,
                                    argumentsJSON: call.arguments,
                                    knowledgeWritePreview: await ToolRegistry.shared.knowledgeWritePreview(
                                        for: call.name, argumentsJSON: call.arguments))
                            }

                            if !approved {
                                let reason =
                                    policy == .deny
                                    ? "blocked by your tool permissions (Deny)"
                                    : "you declined to run it this time"
                                NSLog("[CloudChatEngine] tool '\(call.name)' not run — \(reason)")
                                result = "⛔️ “\(call.name)” was not run — \(reason)."
                            } else {
                                NSLog("[CloudChatEngine] executing tool '\(call.name)' args=\(call.arguments.prefix(200))")
                                do {
                                    result = try await ChatExecutionContext.$currentToolCallId.withValue(callId) {
                                        try await CapabilityLoadBuffer.$current.withValue(loadBuffer) {
                                            try await ToolRegistry.shared.execute(
                                                name: call.name,
                                                argumentsJSON: call.arguments
                                            )
                                        }
                                    }
                                    NSLog("[CloudChatEngine] tool '\(call.name)' finished in \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s (result \(result.count) chars)")
                                } catch {
                                    NSLog("[CloudChatEngine] tool '\(call.name)' THREW after \(String(format: "%.1f", Date().timeIntervalSince(toolStart)))s: \(error.localizedDescription)")
                                    result = ToolEnvelope.fromError(error, tool: call.name)
                                }
                            }
                            continuation.yield(
                                StreamingToolHint.encodeDone(
                                    callId: callId,
                                    name: call.name,
                                    arguments: call.arguments,
                                    result: result
                                )
                            )
                            if let adopted = await Self.adoptingLoadedTools(from: loadBuffer, into: activeTools) {
                                activeTools = adopted
                                liveToolSpecs = Self.encodeTools(adopted)
                            }
                            insightToolCalls.append(
                                ToolCallLog(
                                    name: call.name,
                                    arguments: call.arguments,
                                    result: result,
                                    durationMs: Date().timeIntervalSince(toolStart) * 1_000,
                                    isError: result.hasPrefix("⛔️")
                                )
                            )
                            wireMessages.append([
                                "role": "tool",
                                "tool_call_id": callId,
                                "content": result,
                            ])
                            if AgentLoopRunEnd.endsRun(toolName: call.name, result: result) {
                                runEndedByTool = true
                            }
                        }
                        // `complete` / `clarify` / `prompt_working_folder` end
                        // the run after this round: every call in the round
                        // has its result card, and the chat reacts to them.
                        if runEndedByTool {
                            NSLog("[CloudChatEngine] Run ended by an agent-loop tool")
                            logInference()
                            continuation.finish()
                            return
                        }
                        // Loop: send the continuation request with tool results.
                    }

                    NSLog("[CloudChatEngine] Tool loop hit max rounds (\(maxToolRounds))")
                    let error = EngineError(message: "Tool-call limit reached before the response completed.")
                    logInference(error: error)
                    continuation.finish(throwing: error)
                } catch {
                    NSLog("[CloudChatEngine] Stream error: \(error.localizedDescription)")
                    logInference(error: error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func completeChat(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        let resolvedModel = request.model ?? model
        if IntelClaudeCodeService.handles(resolvedModel) {
            return try await IntelClaudeCodeService.shared.completeChat(request: request)
        }
        guard let endpoint = try await resolveEndpoint(forModel: resolvedModel) else {
            throw EngineError(
                message:
                    "No endpoint for model \"\(resolvedModel)\". Add a provider (and key, if it needs one) in Settings → Providers, or set the DEEPSEEK_API_KEY env var."
            )
        }

        if endpoint.isCodex {
            let stream = try await streamChat(request: request)
            var content = ""
            for try await delta in stream where !StreamingToolHint.isSentinel(delta) {
                content += delta
            }
            return ChatCompletionResponse(
                id: "codex-\(UUID().uuidString)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: resolvedModel,
                choices: [
                    .init(
                        index: 0,
                        message: .init(
                            role: "assistant", content: content,
                            tool_calls: nil, reasoning_content: nil
                        ),
                        finish_reason: "stop"
                    )
                ],
                usage: nil
            )
        }

        var urlRequest = URLRequest(url: URL(string: endpoint.url)!)
        urlRequest.httpMethod = "POST"
        for (k, v) in try await requestHeaders(for: endpoint) { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.timeoutInterval = 300

        var body: [String: Any] = [
            "model": endpoint.modelId,
            "messages": request.messages.map { msg -> [String: Any] in
                var m: [String: Any] = ["role": msg.role]
                if let content = msg.content { m["content"] = content }
                return m
            },
            "stream": false,
        ]
        // Honor max_tokens + temperature, and apply reasoning control. Without
        // this a reasoning core model could spend the whole budget on
        // reasoning_content and return empty content — which is exactly why
        // model-generated chat titles came back blank. With no modelOptions,
        // applyReasoningMode disables thinking (fast, deterministic for titles).
        if let maxTokens = request.max_tokens { body["max_tokens"] = maxTokens }
        // OpenAI reasoning models (o-series, gpt-5*, gpt-6*) reject
        // `temperature`; upstream strips it on the same predicate.
        if let temperature = request.temperature, !Self.rejectsSamplingTemperature(modelId: endpoint.modelId) {
            body["temperature"] = temperature
        }
        applyReasoningMode(request, endpoint: endpoint, into: &body)
        Self.applyPromptCacheRouting(provider: endpoint.provider, sessionId: request.session_id, into: &body)

        // CANONICAL (sorted-key) serialization — bare JSONSerialization emits
        // keys in hash order, which differs across app launches (and can differ
        // per nested dict), changing the request bytes for a logically-identical
        // conversation. DeepSeek's prompt cache only matches a BYTE-identical
        // prefix, so non-canonical bytes meant every request missed the cache and
        // re-billed the whole history. Matches upstream's osaurusCanonical wire
        // contract (JSONDeterminism.swift). (Renée, 2026-06-13 — 11M cache miss.)
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body, options: .osaurusCanonical)
        // Authored tool property order (upstream `ToolWirePropertyOrder`,
        // applied by RemoteProviderService right before send): constrained
        // decoders can only emit keys in declared order, so `file_edit`'s
        // `old_string` must precede `new_string`. Before any Router signing.
        urlRequest.httpBody = urlRequest.httpBody.map { ToolWirePropertyOrder.apply(to: $0) }
        // Osaurus Router: EIP-191 wallet-sign the request body.
        if endpoint.isOsaurusRouter {
            try await OsaurusRouterAuthSigner().sign(request: &urlRequest, body: urlRequest.httpBody)
        }

        // Insights: one row per one-shot request (titles, follow-ups, memory,
        // compaction, delegation…), as upstream's `CoreModelService` logs
        // them. Captured before the await; task-locals are the caller's.
        let activity = OneShotActivity(
            source: Self.loggedSource(default: source),
            turnId: Self.loggedTurnId,
            parentTurnId: Self.activityParentTurnId,
            agentId: ChatExecutionContext.currentAgentId,
            sessionId: ChatExecutionContext.currentSessionId.flatMap(UUID.init(uuidString:)),
            model: resolvedModel,
            path: Self.loggedPath(endpointURL: endpoint.url),
            connection: RequestConnectionInfo(
                providerId: endpoint.provider?.id,
                remoteEndpoint: endpoint.url,
                transport: .direct,
                mode: .remoteInference
            ),
            request: request,
            wireRequestBody: urlRequest.httpBody
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            activity.finish(response: nil, wireResponse: nil, error: error)
            throw error
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(statusCode) {
            let message = extractAPIErrorMessage(String(data: data, encoding: .utf8) ?? "")
            NSLog("[CloudChatEngine] completeChat HTTP \(statusCode) error body: \(message)")
            let error = CloudChatError.httpError(
                provider: endpoint.providerLabel, status: statusCode, message: message)
            activity.finish(response: nil, wireResponse: data, error: error)
            throw error
        }
        do {
            let decoded = try Self.decodeCompletionResponse(data)
            activity.finish(response: decoded, wireResponse: data, error: nil)
            return decoded
        } catch DecodingError.dataCorrupted(let context)
            where context.debugDescription == "Completion SSE reached its output-token limit before assistant text" {
            let error = CloudChatError.outputLimit(
                provider: endpoint.providerLabel,
                diagnostic: Self.safeResponseDiagnostic(data)
            )
            activity.finish(response: nil, wireResponse: data, error: error)
            throw error
        } catch {
            let wrapped = CloudChatError.responseDecoding(
                provider: endpoint.providerLabel,
                message: error.localizedDescription,
                diagnostic: Self.safeResponseDiagnostic(data)
            )
            activity.finish(response: nil, wireResponse: data, error: wrapped)
            throw wrapped
        }
    }

    /// The facts a `completeChat` row needs, captured before the request.
    private struct OneShotActivity: Sendable {
        let source: RequestSource
        let turnId: UUID?
        let parentTurnId: UUID?
        let agentId: UUID?
        let sessionId: UUID?
        let model: String
        let path: String
        let connection: RequestConnectionInfo
        let request: ChatCompletionRequest
        let wireRequestBody: Data?
        let started = Date()

        func finish(response: ChatCompletionResponse?, wireResponse: Data?, error: Error?) {
            let text = response?.choices.first?.message?.content
            InsightsService.logInference(
                source: source,
                turnId: turnId,
                parentTurnId: parentTurnId,
                model: model,
                inputTokens: response?.usage?.prompt_tokens ?? ChatEngine.estimatedInputTokens(request),
                outputTokens: response?.usage?.completion_tokens ?? ((text?.count ?? 0) / 4),
                durationMs: Date().timeIntervalSince(started) * 1_000,
                temperature: request.temperature.map(Float.init),
                maxTokens: request.max_tokens ?? 0,
                finishReason: error == nil ? .stop : .error,
                errorMessage: error?.localizedDescription,
                requestBody: ChatEngine.serializeRequestForInsights(request),
                responseBody: text,
                wireRequestBody: wireRequestBody,
                wireResponseBody: wireResponse,
                connection: connection,
                path: path,
                agentId: agentId,
                sessionId: sessionId
            )
        }
    }

    /// Decode a nominally non-streaming completion. Some managed Router models
    /// ignore `"stream": false` and still return an SSE body. Accept that wire
    /// format by folding its text deltas into the same response shape used by
    /// Memory, titles, and bounded delegation. A malformed or textless stream
    /// remains a visible failure; it must never become an empty successful
    /// distillation.
    nonisolated static func decodeCompletionResponse(_ data: Data) throws -> ChatCompletionResponse {
        if let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
            return response
        }

        let raw = String(decoding: data, as: UTF8.self)
        let lines = raw.split(whereSeparator: \Character.isNewline)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("data:") }) else {
            return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        }

        var id: String?
        var object: String?
        var created: Int?
        var model: String?
        var role: String?
        var content = ""
        var reasoning = ""
        var finishReason: String?
        var usage: ChatCompletionResponse.Usage?
        var sawChoice = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", !payload.isEmpty else { continue }
            guard let frameData = payload.data(using: .utf8),
                  let frame = try JSONSerialization.jsonObject(with: frameData) as? [String: Any]
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Invalid JSON in completion SSE frame"
                ))
            }

            id = frame["id"] as? String ?? id
            object = frame["object"] as? String ?? object
            created = frame["created"] as? Int ?? created
            model = frame["model"] as? String ?? model
            if let rawUsage = frame["usage"] as? [String: Any] {
                usage = .init(
                    prompt_tokens: rawUsage["prompt_tokens"] as? Int,
                    completion_tokens: rawUsage["completion_tokens"] as? Int,
                    total_tokens: rawUsage["total_tokens"] as? Int
                )
            }

            guard let choice = (frame["choices"] as? [[String: Any]])?.first else { continue }
            sawChoice = true
            finishReason = choice["finish_reason"] as? String ?? finishReason
            let message = choice["delta"] as? [String: Any]
                ?? choice["message"] as? [String: Any]
                ?? [:]
            role = message["role"] as? String ?? role
            if let text = try completionText(from: message["content"]) {
                content += text
            }
            if let text = message["reasoning_content"] as? String {
                reasoning += text
            }
        }

        guard sawChoice, !content.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: finishReason == "length"
                    ? "Completion SSE reached its output-token limit before assistant text"
                    : "Completion SSE contained no assistant text"
            ))
        }
        return ChatCompletionResponse(
            id: id,
            object: object,
            created: created,
            model: model,
            choices: [.init(
                index: 0,
                message: .init(
                    role: role ?? "assistant",
                    content: content,
                    tool_calls: nil,
                    reasoning_content: reasoning.isEmpty ? nil : reasoning
                ),
                finish_reason: finishReason
            )],
            usage: usage
        )
    }

    /// An MCP server's own descriptions name its tools canonically (`abc`),
    /// while Intel offers them prefixed (`xyz_abc`). When the model follows
    /// the server's documented workflow, map the canonical name to the one
    /// OFFERED tool publishing it (upstream `fb2efe4db`). Only offered tools
    /// can match, so the not-offered rejection, permission policy, and
    /// approval prompt all still run — on the resolved name. A name that is
    /// itself offered, or ambiguous across offered providers, is unchanged.
    nonisolated static func resolvedOfferedToolName(_ name: String, offered: [Tool]?) -> String {
        guard let offered, !offered.contains(where: { $0.function.name == name }) else { return name }
        let offeredNames = Set(offered.map(\.function.name))
        let candidates = ToolRegistry.shared.mcpExposedNames(forCanonical: name)
            .filter { offeredNames.contains($0) }
        return candidates.count == 1 ? candidates[0] : name
    }

    nonisolated static func rejectsSamplingTemperature(modelId: String) -> Bool {
        OpenAIGPT6ReasoningProfile.matches(modelId: modelId)
            || OpenAIReasoningProfile.matches(modelId: modelId)
    }

    // MARK: Prompt-cache routing (upstream 9b3336d68)

    /// Whether a provider accepts `prompt_cache_key`. Allowlisted only:
    /// third-party OpenAI-compatible gateways can reject unknown fields.
    /// The Router forwards the key to keyed upstream caches; genuine OpenAI
    /// hosts, Azure, and OpenRouter accept it directly.
    /// The Osaurus Router's billing summary frame (`{"osaurus": {…}}`), or
    /// nil for any other SSE frame. The cheap key check keeps ordinary
    /// chunks from paying for a failed decode (upstream).
    nonisolated static func routerSummary(
        fromFrame json: [String: Any], data: Data
    ) -> OsaurusRouterSummaryEvent.Summary? {
        guard json["osaurus"] != nil,
            let event = try? JSONDecoder().decode(OsaurusRouterSummaryEvent.self, from: data)
        else { return nil }
        return event.osaurus
    }

    nonisolated static func supportsPromptCacheKey(providerType: RemoteProviderType, host: String) -> Bool {
        switch providerType {
        case .osaurusRouter, .azureOpenAI:
            return true
        case .openaiLegacy, .openResponses:
            let normalizedHost = host.lowercased()
            return normalizedHost == "api.openai.com" || normalizedHost.hasSuffix(".openai.com")
                || isOpenRouterHost(normalizedHost)
        case .anthropic, .gemini, .openAICodex, .osaurus:
            return false
        }
    }

    /// Stable per conversation so every turn and tool round of one chat hits
    /// the same upstream cache shard. The Router validates
    /// `[A-Za-z0-9._:-]{1,200}`; chat ids are UUIDs.
    nonisolated static func promptCacheKey(forSession sessionId: String) -> String {
        "osaurus-session-\(sessionId)"
    }

    nonisolated static func isOpenRouterHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost == OpenRouterOAuthService.Attribution.host
            || normalizedHost.hasSuffix("." + OpenRouterOAuthService.Attribution.host)
    }

    /// Adds the session cache key (allowlisted providers) and OpenRouter's
    /// `session_id` sticky routing. No field is added without a chat id, so
    /// one-off requests (titles, Memory) stay byte-identical to before.
    nonisolated static func applyPromptCacheRouting(
        provider: RemoteProvider?,
        sessionId: String?,
        into body: inout [String: Any]
    ) {
        guard let provider, let sessionId, !sessionId.isEmpty else { return }
        if supportsPromptCacheKey(providerType: provider.providerType, host: provider.host) {
            body["prompt_cache_key"] = promptCacheKey(forSession: sessionId)
        }
        if provider.providerType == .openaiLegacy, isOpenRouterHost(provider.host) {
            body["session_id"] = sessionId
        }
    }

    /// The request's tools plus anything `capabilities` loaded during the
    /// last call, or nil when nothing was loaded
    /// (docs/TOOL_DISCOVERY_INTEL.md).
    nonisolated static func adoptingLoadedTools(
        from buffer: CapabilityLoadBuffer, into tools: [Tool]?
    ) async -> [Tool]? {
        let names = await buffer.drain()
        guard !names.isEmpty else { return nil }
        var current = tools ?? []
        for spec in ToolRegistry.shared.openAISpecs(named: names)
        where !current.contains(where: { $0.function.name == spec.function.name }) {
            current.append(spec)
        }
        return current
    }

    nonisolated static func unofferedToolResult(_ name: String) -> String {
        "⛔️ “\(name)” was not run — it is not offered in this turn."
    }

    private nonisolated static func completionText(from value: Any?) throws -> String? {
        if value == nil || value is NSNull { return nil }
        if let text = value as? String { return text }
        guard let parts = value as? [[String: Any]] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Completion content was neither text nor text parts"
            ))
        }
        return try parts.map { part in
            guard part["type"] as? String == "text", let text = part["text"] as? String else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "Only text content parts are supported in completion SSE"
                ))
            }
            return text
        }.joined()
    }

    /// Retain enough raw response data to diagnose an envelope mismatch while
    /// preventing credentials or an unbounded payload from entering the local
    /// Memory processing log.
    nonisolated static func safeResponseDiagnostic(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let sseLines = raw.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.hasPrefix("data:") }
        if !sseLines.isEmpty {
            var frames = 0
            var choices = 0
            var invalid = 0
            var deltaKeys = Set<String>()
            var contentKinds = Set<String>()
            var finishReasons = Set<String>()
            var unknownDeltaKeys = 0
            let knownKeys: Set<String> = ["role", "content", "reasoning_content", "tool_calls", "function_call", "refusal"]
            for line in sseLines {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]", !payload.isEmpty else { continue }
                frames += 1
                guard let frameData = payload.data(using: .utf8),
                      let frame = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any]
                else {
                    invalid += 1
                    continue
                }
                guard let choice = (frame["choices"] as? [[String: Any]])?.first else { continue }
                choices += 1
                if let reason = choice["finish_reason"] as? String {
                    finishReasons.insert(["stop", "length", "tool_calls", "content_filter"].contains(reason) ? reason : "other")
                }
                let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
                for key in delta.keys {
                    if knownKeys.contains(key) { deltaKeys.insert(key) }
                    else { unknownDeltaKeys += 1 }
                }
                if let content = delta["content"] {
                    if content is String { contentKinds.insert("string") }
                    else if content is [[String: Any]] { contentKinds.insert("parts") }
                    else if content is NSNull { contentKinds.insert("null") }
                    else { contentKinds.insert("other") }
                }
            }
            return "SSE shape: frames=\(frames), choices=\(choices), invalidFrames=\(invalid), deltaKeys=\(deltaKeys.sorted()), unknownDeltaKeys=\(unknownDeltaKeys), contentKinds=\(contentKinds.sorted()), finishReasons=\(finishReasons.sorted())"
        }
        let redacted = InsightsService.redactCredentials(raw)
        let limit = 4_096
        guard redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit)) + "…[truncated]"
    }

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

#endif
