//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//  Intel fork — cloud proxy with SSE streaming. M4 milestone.
//

import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - OpenAI-compatible types

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
    let tool_calls: [ToolCall]?
    let tool_call_id: String?
    let reasoning_content: String?
    /// Multimodal parts (upstream): set when the message carries images,
    /// audio or video. `content` keeps the joined text.
    var contentParts: [MessageContentPart]? = nil

    init(role: String, content: String? = nil, tool_calls: [ToolCall]? = nil,
         tool_call_id: String? = nil, reasoning_content: String? = nil,
         contentParts: [MessageContentPart]? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
        self.contentParts = contentParts
    }

    /// Image URLs carried by the parts (data: or http(s):), upstream.
    var imageUrls: [String] {
        (contentParts ?? []).compactMap { part in
            if case .imageUrl(let url, _) = part { return url }
            return nil
        }
    }

    var hasMediaParts: Bool { contentParts?.contains(where: \.isMedia) == true }

    private enum CodingKeys: String, CodingKey {
        case role, content, tool_calls, tool_call_id, reasoning_content
    }

    /// Upstream: `content` may be a string or an OpenAI array of parts.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.tool_calls = try? container.decode([ToolCall].self, forKey: .tool_calls)
        self.tool_call_id = try? container.decode(String.self, forKey: .tool_call_id)
        self.reasoning_content = try? container.decode(String.self, forKey: .reasoning_content)
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            self.content = stringContent
            self.contentParts = nil
        } else if let parts = try? container.decode([MessageContentPart].self, forKey: .content) {
            self.contentParts = parts
            let texts = parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            self.content = texts.isEmpty ? nil : texts.joined()
        } else {
            self.content = nil
            self.contentParts = nil
        }
    }

    /// Upstream: parts with media encode as an array, otherwise the string.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let parts = contentParts, parts.contains(where: \.isMedia) {
            try container.encode(parts, forKey: .content)
        } else if let content {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        try container.encodeIfPresent(reasoning_content, forKey: .reasoning_content)
    }
}

struct ToolCall: Codable, Sendable {
    let id: String
    let type: String?
    let function: ToolCallFunction
    var geminiThoughtSignature: String? = nil

    init(id: String = "", type: String? = nil, function: ToolCallFunction = ToolCallFunction(), geminiThoughtSignature: String? = nil) {
        self.id = id
        self.type = type
        self.function = function
        self.geminiThoughtSignature = geminiThoughtSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.function = try container.decodeIfPresent(ToolCallFunction.self, forKey: .function) ?? ToolCallFunction()
        self.geminiThoughtSignature = try container.decodeIfPresent(String.self, forKey: .geminiThoughtSignature)
    }
}

struct ToolCallFunction: Codable, Sendable {
    let name: String
    let arguments: String

    init(name: String = "", arguments: String = "") {
        self.name = name
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
    }
}

struct ChatCompletionRequest: Codable, Sendable {
    let model: String?
    let messages: [ChatMessage]
    var temperature: Double?
    var max_tokens: Int?
    var stream: Bool?
    var top_p: Double?
    var stream_options: StreamOptions? = nil
    var frequency_penalty: Double?
    var presence_penalty: Double?
    var stop: [String]?
    var n: Int?
    var tools: [Tool]?
    var tool_choice: ToolChoiceOption?
    var session_id: String?
    var samplingParametersAreImplicit: Bool = false
    var modelOptions: [String: ModelOptionValue]? = nil
    /// Intel (docs/SUBAGENTS_INTEL.md): a desktop subagent's model step. The
    /// engine ends the stream at the first round that proposes tool calls,
    /// yielding them as one `StreamingToolHint.encodeProposed` sentinel,
    /// instead of running them. Not encoded.
    var stopAtToolCalls: Bool = false
    /// Intel (`W-server-api`): an API request. The engine ends the stream
    /// with a `StreamingUsageHint` when the provider reported usage. Not
    /// encoded.
    var reportsUsage: Bool = false

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature, max_tokens, top_p
        case stream_options, frequency_penalty, presence_penalty, stop, n
        case tools, tool_choice, session_id
    }

    var ttftTrace: TTFTTrace? = nil
}

struct StreamOptions: Codable, Sendable {
    let include_usage: Bool?
}

/// OpenAI-compatible model object
struct OpenAIModel: Codable, Sendable {
    let id: String
    var object: String = "model"
    var created: Int = 0
    var owned_by: String = "osaurus"
    var permission: [ModelPermission]? = nil
    var root: String? = nil
    var parent: String? = nil
    var name: String? = nil
    var model: String? = nil
    var modified_at: String? = nil
    var size: Int? = nil
    var digest: String? = nil
    var details: ModelDetails? = nil

    /// Initialize from a model name (for local models)
    init(modelName: String) {
        self.id = modelName
        self.object = "model"
        self.created = Int(Date().timeIntervalSince1970)
        self.owned_by = "osaurus"
        self.root = modelName
    }

    /// Full initializer
    init(
        id: String,
        object: String = "model",
        created: Int = 0,
        owned_by: String = "osaurus",
        permission: [ModelPermission]? = nil,
        root: String? = nil,
        parent: String? = nil,
        name: String? = nil,
        model: String? = nil,
        modified_at: String? = nil,
        size: Int? = nil,
        digest: String? = nil,
        details: ModelDetails? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.owned_by = owned_by
        self.permission = permission
        self.root = root
        self.parent = parent
        self.name = name
        self.model = model
        self.modified_at = modified_at
        self.size = size
        self.digest = digest
        self.details = details
    }

    // Explicit Codable implementation to avoid ambiguity
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object) ?? "model"
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        owned_by = try container.decodeIfPresent(String.self, forKey: .owned_by) ?? "unknown"
        permission = try container.decodeIfPresent([ModelPermission].self, forKey: .permission)
        root = try container.decodeIfPresent(String.self, forKey: .root)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        modified_at = try container.decodeIfPresent(String.self, forKey: .modified_at)
        // Some OpenAI-compatible servers expose provider-local metadata in
        // `size` as a fractional value. That field is informational for
        // Osaurus model discovery, so preserve the model row instead of
        // rejecting the whole `/models` response.
        size = try? container.decodeIfPresent(Int.self, forKey: .size)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        details = try container.decodeIfPresent(ModelDetails.self, forKey: .details)
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, created, owned_by, permission, root, parent
        case name, model, modified_at, size, digest, details
    }
}

/// Model permission object (OpenAI format)
struct ModelPermission: Codable, Sendable {
    var id: String?
    var object: String?
    var created: Int?
    var allow_create_engine: Bool?
    var allow_sampling: Bool?
    var allow_logprobs: Bool?
    var allow_search_indices: Bool?
    var allow_view: Bool?
    var allow_fine_tuning: Bool?
    var organization: String?
    var group: String?
    var is_blocking: Bool?
}

struct ModelDetails: Codable, Sendable {
    let parent_model: String?
    let format: String?
    let family: String?
    let families: [String]?
    let parameter_size: String?
    let quantization_level: String?
}

// Upstream's `ModelDetails.localMLXModelDetails` is MLX-only (no local
// models on Intel), so it is left out.

/// Response for /models endpoint
struct ModelsResponse: Codable, Sendable {
    var object: String = "list"
    let data: [OpenAIModel]

    private enum CodingKeys: String, CodingKey {
        case object, data
    }

    /// Memberwise initializer
    init(object: String = "list", data: [OpenAIModel]) {
        self.object = object
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Make object optional for providers like OpenRouter that don't include it
        self.object = try container.decodeIfPresent(String.self, forKey: .object) ?? "list"
        self.data = try container.decode([OpenAIModel].self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(data, forKey: .data)
    }
}

// MARK: - HTTP Handler

private final class SendableBool: @unchecked Sendable {
    private var _value: Bool
    private let _lock = NSLock()
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

/// Thread-safe holder for the inbound request's attribution metadata
/// (paired-key nonce + audience + transport). The auth gate sets it on the
/// event loop; the request log can be emitted off-loop, where touching the
/// `NIOLoopBound` `RequestState` would trap (upstream).
private final class SendableConnectionBox: @unchecked Sendable {
    private var _value: RequestConnectionInfo?
    private let _lock = NSLock()
    var value: RequestConnectionInfo? {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

/// Off-loop-readable client address for the current request (upstream).
private final class SendableClientIPBox: @unchecked Sendable {
    private var _value: String = "unknown"
    private let _lock = NSLock()
    var value: String {
        get { _lock.withLock { _value } }
        set { _lock.withLock { _value = newValue } }
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, returning value: Value) -> Bool {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return false
        }
        didResume = true
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }
}

/// Carries a request's async work into its task (upstream
/// `RequestTaskOperation`): the work runs once, on that task.
private final class RequestTaskOperation: @unchecked Sendable {
    private let operation: () async -> Void
    init(_ operation: @escaping () async -> Void) { self.operation = operation }
    func run() async { await operation() }
}

/// SwiftNIO HTTP request handler.
///
/// Intel (`W-server-api` stage 1, docs/SERVER_API_INTEL.md): upstream's
/// request intake, limits, CORS and access-key gate in front of Intel's
/// routes. Upstream's route bodies arrive stage by stage.
final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let configuration: ServerConfiguration
    private let apiKeyValidatorProvider: @Sendable () -> APIKeyValidator
    private var apiKeyValidator: APIKeyValidator { apiKeyValidatorProvider() }
    private let trustLoopback: Bool
    /// Engine override for tests (upstream injects `chatEngine` the same way).
    private let injectedChatEngine: (any ChatEngineProtocol)?
    private let _isChannelActive = SendableBool(false)
    /// Off-loop-readable mirror of the current request's inbound attribution
    /// (set by the auth gate, cleared on each `.head`).
    private let _inboundConnection = SendableConnectionBox()
    /// Off-loop-readable mirror of the current request's client address.
    private let _clientIP = SendableClientIPBox()

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Internal marker header stamped by `RelayTunnelManager` on every request
    /// it proxies from the relay tunnel to the loopback server. Such requests
    /// arrive over 127.0.0.1 but ORIGINATE from the public internet, so they
    /// must never inherit the loopback auth/CORS trust that genuine local
    /// callers (CLI, App Intents) get (upstream).
    static let relayOriginHeaderName = "X-Osaurus-Relay-Origin"

    final class RequestState {
        var requestHead: HTTPRequestHead?
        var requestBodyBuffer: ByteBuffer?
        var corsHeaders: [(String, String)] = []
        var normalizedPath: String = ""
        var isStreaming = false
        var streamingDone = false
        var contextBox: ChannelHandlerContext?
        /// Wall-clock when the request head arrived, for request duration.
        var requestStartedAt: Date?
        /// Set by routes that write their own Insights row (with model and
        /// finish reason), so `sendResponse` doesn't add a second one.
        var routeLogsItself = false
        /// Cached body-size cap for the current request (route-aware).
        var bodyByteLimit: Int = Int.max
        /// Running total of accumulated body bytes, so a chunked client
        /// cannot bypass the Content-Length check.
        var bodyBytesSeen: Int = 0
        /// Set when the request has already been rejected (413 / 431) so any
        /// subsequent `.body` / `.end` parts are dropped.
        var rejectedTooLarge: Bool = false
        /// Set at `.head` when the request carries the relay-origin marker.
        /// Forces `isLoopbackConnection` to report `false`.
        var isRelayOrigin: Bool = false
        /// The validated access key's audience (lowercased). `nil` means the
        /// caller was loopback-trusted or hit a public route.
        var authedAudience: String?
        /// `true` when `authedAudience` is the master address.
        var authedScopeIsMaster: Bool = false
        /// `true` when the caller presented a Bearer token that validated.
        var callerHasVerifiedAccessKey: Bool = false
        /// `true` when that verified key is master-scoped.
        var callerAccessKeyIsMaster: Bool = false
        /// Set by the auth gate when `LocalAPIKeyPolicy` made a loopback
        /// caller present an agent-scoped key: that caller is held to the
        /// remote contract, so `isLoopbackConnection` reports `false`.
        var loopbackTrustWithdrawn: Bool = false
    }

    /// Paths whose handler logs its own Insights row (see
    /// `RequestLog.mediaCategory(forPath:)`); in-process emitters on the same
    /// code path skip when `ChatExecutionContext.currentRequestSource` is
    /// `.httpAPI`. Upstream, verbatim; Intel serves none of these paths yet,
    /// so nothing binds the guard.
    static func handlerWritesOwnActivityRow(path: String) -> Bool {
        RequestLog.mediaCategory(forPath: path) != nil
    }

    /// Row facts for `/v1/embeddings` and `/api/embed`. Never the texts.
    /// Upstream, verbatim (no Intel endpoint yet).
    static func embeddingActivityDetails(texts: [String], dimensions: Int?) -> [String: String] {
        var details: [String: String] = [
            "texts": String(texts.count),
            "chars": String(texts.reduce(0) { $0 + $1.count }),
        ]
        if let dimensions { details["dims"] = String(dimensions) }
        return details
    }

    let stateRef: NIOLoopBound<RequestState>

    /// Live read of the owner's "share my models for inference with paired
    /// agents" switch. Upstream reads `PeerInferenceSharing`, part of
    /// workspace sharing (deferred on Intel), so it is off here; injectable
    /// for the gate's tests.
    private let peerInferenceSharingProvider: @Sendable () -> Bool
    private var peerInferenceEnabled: Bool { peerInferenceSharingProvider() }

    /// Live read of the owner's "require an access key from this Mac too"
    /// switch (`LocalAPIKeyPolicy`, upstream #3178), injectable.
    private let localKeyRequiredProvider: @Sendable () -> Bool

    private func localKeyRequired(for normalizedPath: String) -> Bool {
        LocalAPIKeyPolicy.isProtectedRoute(normalizedPath) && localKeyRequiredProvider()
    }

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator = .empty,
        apiKeyValidatorProvider: (@Sendable () -> APIKeyValidator)? = nil,
        eventLoop: EventLoop,
        trustLoopback: Bool = true,
        chatEngine: (any ChatEngineProtocol)? = nil,
        peerInferenceSharingProvider: @escaping @Sendable () -> Bool = { false },
        localKeyRequiredProvider: @escaping @Sendable () -> Bool = { LocalAPIKeyPolicy.isEnabled() }
    ) {
        self.configuration = configuration
        self.apiKeyValidatorProvider = apiKeyValidatorProvider ?? { apiKeyValidator }
        self.trustLoopback = trustLoopback
        self.injectedChatEngine = chatEngine
        self.peerInferenceSharingProvider = peerInferenceSharingProvider
        self.localKeyRequiredProvider = localKeyRequiredProvider
        self.stateRef = NIOLoopBound(RequestState(), eventLoop: eventLoop)
    }

    func channelActive(context: ChannelHandlerContext) {
        _isChannelActive.value = true
        stateRef.value.contextBox = context
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        _isChannelActive.value = false
        stateRef.value.contextBox = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log and close the connection to avoid NIO debug preconditions
        // crashing the app (upstream).
        print("[Osaurus][NIO] errorCaught: \(error)")
        context.close(promise: nil)
    }

    /// Runs a request's async work with the caller's auth proof bound as
    /// `HTTPCallerContext` (upstream `runRequestTask`, minus its task
    /// registry, which arrives with the routes that need it).
    @discardableResult
    func runRequestTask(_ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let callerContext = HTTPCallerContext(
            hasVerifiedAccessKey: stateRef.value.callerHasVerifiedAccessKey,
            isSecureChannel: false
        )
        let operationBox = RequestTaskOperation(operation)
        // Activity-log double-write guard (upstream): routes that write their
        // own Insights row keep the in-process emitters they call
        // (transcription, embeddings, media) quiet for this task.
        let activityGuard: RequestSource? =
            Self.handlerWritesOwnActivityRow(path: stateRef.value.normalizedPath) ? .httpAPI : nil
        return Task {
            await HTTPCallerContext.$current.withValue(callerContext) {
                await ChatExecutionContext.$currentRequestSource.withValue(activityGuard) {
                    await operationBox.run()
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            stateRef.value.requestHead = head
            stateRef.value.requestStartedAt = Date()
            stateRef.value.routeLogsItself = false
            stateRef.value.isStreaming = false
            stateRef.value.streamingDone = false
            stateRef.value.bodyBytesSeen = 0
            stateRef.value.rejectedTooLarge = false
            stateRef.value.authedAudience = nil
            stateRef.value.authedScopeIsMaster = false
            stateRef.value.callerHasVerifiedAccessKey = false
            stateRef.value.callerAccessKeyIsMaster = false
            stateRef.value.loopbackTrustWithdrawn = false
            // Clear last request's attribution so a keep-alive connection's
            // next (possibly loopback / public) request can't inherit it.
            _inboundConnection.value = nil
            // Detect relay-proxied traffic before computing CORS / loopback
            // trust so the relay marker can strip loopback privileges.
            stateRef.value.isRelayOrigin =
                head.headers.first(name: HTTPHandler.relayOriginHeaderName) != nil
            _clientIP.value = remoteIP(context)
            stateRef.value.corsHeaders = computeCORSHeaders(
                for: head,
                isPreflight: false,
                isLoopback: isLoopbackConnection(context),
                explicitOriginsOnly: localKeyRequired(for: normalize(extractPath(from: head.uri)))
            )
            stateRef.value.bodyByteLimit = bodyByteLimit(for: head)

            // Header DoS guard: reject pathological header sets before any
            // further per-header work.
            var headerCount = 0
            var headerBytes = 0
            for (name, value) in head.headers {
                headerCount += 1
                headerBytes += name.utf8.count + value.utf8.count
                if headerCount > Self.maxRequestHeaderCount
                    || headerBytes > Self.maxRequestHeaderBytes
                {
                    rejectHeadersTooLarge(context: context, head: head)
                    return
                }
            }

            // Reject before allocating the body buffer so a client lying
            // about Content-Length can't force a huge allocation up front.
            if let lengthStr = head.headers.first(name: "Content-Length") {
                guard let length = Int(lengthStr), length >= 0 else {
                    sendBadRequest(context: context)
                    stateRef.value.requestHead = nil
                    stateRef.value.requestBodyBuffer = nil
                    return
                }
                if length > stateRef.value.bodyByteLimit {
                    rejectPayloadTooLarge(
                        context: context,
                        head: head,
                        declaredLength: length,
                        limit: stateRef.value.bodyByteLimit
                    )
                    return
                }
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: length)
            } else {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }

        case .body(var buffer):
            if stateRef.value.rejectedTooLarge { return }
            if stateRef.value.requestBodyBuffer == nil {
                stateRef.value.requestBodyBuffer = context.channel.allocator.buffer(
                    capacity: buffer.readableBytes
                )
            }
            stateRef.value.bodyBytesSeen += buffer.readableBytes
            if stateRef.value.bodyBytesSeen > stateRef.value.bodyByteLimit,
                let head = stateRef.value.requestHead
            {
                rejectPayloadTooLarge(
                    context: context,
                    head: head,
                    declaredLength: stateRef.value.bodyBytesSeen,
                    limit: stateRef.value.bodyByteLimit
                )
                return
            }
            if var existing = stateRef.value.requestBodyBuffer {
                existing.writeBuffer(&buffer)
                stateRef.value.requestBodyBuffer = existing
            }

        case .end:
            if stateRef.value.rejectedTooLarge {
                stateRef.value.requestHead = nil
                stateRef.value.requestBodyBuffer = nil
                return
            }
            guard let head = stateRef.value.requestHead else {
                sendBadRequest(context: context)
                return
            }
            guard admit(context: context, head: head) else {
                stateRef.value.requestHead = nil
                stateRef.value.requestBodyBuffer = nil
                return
            }
            handleRequest(context: context, head: head)
        }
    }

    // MARK: - Access gate (upstream)

    /// CORS preflight, `LocalAPIKeyPolicy`, the access-key gate and the
    /// agent-scope confinement, in upstream's order. Returns `false` when it
    /// already answered the request.
    private func admit(context: ChannelHandlerContext, head: HTTPRequestHead) -> Bool {
        let path = normalize(extractPath(from: head.uri))
        stateRef.value.normalizedPath = path
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let method = head.method.rawValue
        let userAgent = head.headers.first(name: "User-Agent")

        // CORS preflight (OPTIONS): answered here, not logged.
        if head.method == .OPTIONS {
            let cors = computeCORSHeaders(
                for: head,
                isPreflight: true,
                isLoopback: isLoopbackConnection(context),
                explicitOriginsOnly: localKeyRequired(for: path)
            )
            sendGateResponse(context: context, head: head, status: .noContent, headers: cors, body: "")
            return false
        }

        func refuse(_ status: HTTPResponseStatus, _ body: String, message: String? = nil) -> Bool {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            sendGateResponse(context: context, head: head, status: status, headers: headers, body: body)
            logRequest(
                method: method,
                path: path,
                userAgent: userAgent,
                requestBody: nil,
                responseBody: body,
                responseStatus: Int(status.code),
                startTime: startTime,
                errorMessage: message
            )
            return false
        }

        // `LocalAPIKeyPolicy`: on a protected route, a browser origin not
        // listed by name is refused outright (key or not), and the
        // in-process app token stands in for a key over physical loopback.
        let localKeyRequired = localKeyRequired(for: path)
        var presentedAppToken = false
        if localKeyRequired {
            stateRef.value.corsHeaders = computeCORSHeaders(
                for: head,
                isPreflight: false,
                isLoopback: false,
                explicitOriginsOnly: true
            )
            if let origin = head.headers.first(name: "Origin"),
                !LocalAPIKeyPolicy.isExplicitlyAllowedOrigin(origin, allowedOrigins: configuration.allowedOrigins)
            {
                let message =
                    "Browser requests to this route are refused. Add the origin to Allowed Origins (CORS) to permit it."
                return refuse(
                    .forbidden,
                    #"{"error":{"code":"browser_origin_refused","message":"\#(message)","type":"permission_error"}}"#,
                    message: message
                )
            }
            presentedAppToken =
                isPhysicalLoopbackConnection(context)
                && LocalAPIKeyPolicy.isAppSessionToken(head.headers.first(name: LocalAPIKeyPolicy.appTokenHeaderName))
        }

        // Access key authentication gate. Loopback connections (CLI / local
        // tools) are trusted without a token unless `LocalAPIKeyPolicy` asks
        // for one. Upstream's plugin, channel and harness exemptions arrive
        // with those routes (`W-plugin-reliability`, channels, harnesses).
        let publicPaths: Set<String> = [
            "/", "/health", "/pair", "/pair/hello", "/pair/challenge", "/pair/code", "/pair/confirm", "/pair-invite",
            "/secure/session",
        ]
        let isLoopback = isLoopbackConnection(context)

        if !publicPaths.contains(path) && (!isLoopback || (localKeyRequired && !presentedAppToken)) {
            let authHeader = head.headers.first(name: "Authorization") ?? ""
            let token = authHeader.hasPrefix("Bearer ") ? String(authHeader.dropFirst(7)) : ""

            let message: String
            if !apiKeyValidator.hasKeys {
                message = "No access keys configured. Create one in Osaurus settings."
            } else {
                switch apiKeyValidator.validate(rawKey: token) {
                case .valid(_, let audience, let keyNonce):
                    message = ""
                    stateRef.value.callerHasVerifiedAccessKey = true
                    stateRef.value.authedAudience = audience.lowercased()
                    stateRef.value.authedScopeIsMaster = apiKeyValidator.isMasterScoped(audience: audience)
                    stateRef.value.callerAccessKeyIsMaster = stateRef.value.authedScopeIsMaster
                    // A local owner key keeps loopback behavior; a local
                    // agent-scoped key gets exactly what it gets remotely.
                    stateRef.value.loopbackTrustWithdrawn = isLoopback && !stateRef.value.authedScopeIsMaster
                    _inboundConnection.value = RequestConnectionInfo(
                        transport: .direct,
                        accessKeyId: keyNonce,
                        audience: audience.lowercased()
                    )
                case .expired:
                    message = "Access key has expired"
                case .revoked:
                    message = "Access key has been revoked"
                case .invalid(let reason):
                    message = "Invalid access key: \(reason)"
                }
            }

            if !message.isEmpty {
                return refuse(.unauthorized, #"{"error":{"message":"\#(message)","type":"authentication_error"}}"#)
            }

            // Confinement for agent-scoped keys: route policy by key origin,
            // plus the cross-agent `X-Osaurus-Agent-Id` check. Workspace-
            // minted keys don't exist on Intel yet (deferred), so every
            // agent-scoped key takes the legacy pairing policy.
            let rejection =
                Self.agentScopedRouteRejection(
                    method: head.method,
                    path: path,
                    authedAudience: stateRef.value.authedAudience,
                    authedScopeIsMaster: stateRef.value.authedScopeIsMaster,
                    isWorkspaceMintedKey: false,
                    peerInferenceEnabled: peerInferenceEnabled
                )
                ?? Self.agentHeaderScopeRejection(
                    headerValue: head.headers.first(name: "X-Osaurus-Agent-Id"),
                    authedAudience: stateRef.value.authedAudience,
                    authedScopeIsMaster: stateRef.value.authedScopeIsMaster
                )
            if let rejection {
                return refuse(
                    .forbidden,
                    #"{"error":{"code":"\#(rejection.code)","message":"\#(rejection.message)","type":"permission_error"}}"#,
                    message: rejection.message
                )
            }
        }

        // Loopback callers skip the gate, but some downstream gates need
        // proof of a key. Validate a volunteered Bearer token
        // opportunistically: never rejecting, never setting `authedAudience`.
        if isLoopback, !stateRef.value.callerHasVerifiedAccessKey {
            let authHeader = head.headers.first(name: "Authorization") ?? ""
            if authHeader.hasPrefix("Bearer ") {
                let token = String(authHeader.dropFirst(7))
                if case .valid(_, let audience, _) = apiKeyValidator.validate(rawKey: token) {
                    stateRef.value.callerHasVerifiedAccessKey = true
                    stateRef.value.callerAccessKeyIsMaster = apiKeyValidator.isMasterScoped(audience: audience)
                }
            }
        }

        // Simple HEAD (upstream answers it before routing).
        if head.method == .HEAD {
            var headers = [("Content-Type", "text/plain; charset=utf-8")]
            headers.append(contentsOf: stateRef.value.corsHeaders)
            sendGateResponse(context: context, head: head, status: .noContent, headers: headers, body: "")
            logRequest(
                method: method,
                path: path,
                userAgent: userAgent,
                requestBody: nil,
                responseBody: "",
                responseStatus: 204,
                startTime: startTime
            )
            return false
        }
        return true
    }

    // MARK: - Request Dispatch

    private func handleRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = stateRef.value.normalizedPath

        switch (head.method, path) {
        case (.GET, "/health"):
            serveHealth(context: context)
        case (.GET, "/"):
            serveRoot(context: context)
        case (.GET, "/models"):
            serveModels(context: context)
        case (.GET, "/tags"):
            serveTags(context: context)
        case (.POST, "/show"):
            serveShow(context: context)
        case (.POST, "/chat/completions"):
            serveChatCompletions(context: context, head: head)
        case (.POST, "/completions"):
            serveLegacyCompletions(context: context)
        case (.POST, "/embeddings"):
            serveEmbeddings(context: context, head: head, ollamaFormat: false)
        case (.POST, "/embed"):
            serveEmbeddings(context: context, head: head, ollamaFormat: true)
        case (.POST, "/audio/transcriptions"):
            serveAudioTranscription(context: context, head: head)
        case (.POST, "/messages"):
            serveAnthropicMessages(context: context, head: head)
        case (.POST, "/chat"):
            serveOllama(.chat, context: context, head: head)
        case (.POST, "/generate"):
            serveOllama(.generate, context: context, head: head)
        case (.POST, "/mcp"):
            serveMCP(context: context)
        default:
            // Upstream answers unknown routes 404 (Intel's old router
            // answered every path 200 "ok").
            sendResponse(context: context, status: .notFound, headers: textHeaders(), body: "Not Found")
        }
    }

    // MARK: - Gate helpers (upstream)

    private func extractPath(from uri: String) -> String {
        if let queryIndex = uri.firstIndex(of: "?") {
            return String(uri[..<queryIndex])
        }
        return uri
    }

    /// Normalize common provider prefixes so we cover /, /v1, /api, /v1/api.
    private func normalize(_ path: String) -> String {
        Router.normalizeStatic(path)
    }

    private func sendBadRequest(context: ChannelHandlerContext) {
        sendGateResponse(
            context: context,
            head: nil,
            status: .badRequest,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: "Bad Request"
        )
    }

    /// Body-byte cap for the request based on its route: the unauthenticated
    /// pairing / handshake routes get the tighter pairing limit.
    private func bodyByteLimit(for head: HTTPRequestHead) -> Int {
        let path = normalize(extractPath(from: head.uri))
        if path == "/pair" || path == "/pair/code" || path == "/pair/confirm" || path == "/pair-invite"
            || path == "/secure/session"
        {
            return configuration.maxPairingBodyBytes
        }
        return configuration.maxRequestBodyBytes
    }

    /// Upper bound on the number of request headers we accept.
    static let maxRequestHeaderCount = 200
    /// Upper bound on the total bytes across all header names+values.
    static let maxRequestHeaderBytes = 1 * 1024 * 1024
    /// Maximum structural nesting depth we hand to a JSON decoder.
    static let maxJSONNestingDepth = 256

    /// Reply 431 and close, before any body allocation or routing.
    private func rejectHeadersTooLarge(context: ChannelHandlerContext, head: HTTPRequestHead) {
        stateRef.value.rejectedTooLarge = true
        stateRef.value.requestBodyBuffer = nil
        let path = normalize(extractPath(from: head.uri))
        let body =
            #"{"error":{"message":"Request header fields too large","type":"request_header_fields_too_large"}}"#
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        let status = HTTPResponseStatus(statusCode: 431, reasonPhrase: "Request Header Fields Too Large")
        sendGateResponse(context: context, head: head, status: status, headers: headers, body: body)
        logRequest(
            method: head.method.rawValue,
            path: path,
            userAgent: head.headers.first(name: "User-Agent"),
            requestBody: nil,
            responseBody: body,
            responseStatus: 431,
            startTime: stateRef.value.requestStartedAt ?? Date()
        )
        stateRef.value.requestHead = nil
    }

    /// Reply 413, log it, drop the rest of the body and close. Runs before
    /// the auth gate so an unauthenticated client cannot OOM the server.
    private func rejectPayloadTooLarge(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        declaredLength: Int,
        limit: Int
    ) {
        stateRef.value.rejectedTooLarge = true
        stateRef.value.requestBodyBuffer = nil
        let path = normalize(extractPath(from: head.uri))
        let body =
            #"{"error":{"message":"Request body too large (\#(declaredLength) > \#(limit) bytes)","type":"payload_too_large"}}"#
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: stateRef.value.corsHeaders)
        sendGateResponse(context: context, head: head, status: .payloadTooLarge, headers: headers, body: body)
        logRequest(
            method: head.method.rawValue,
            path: path,
            userAgent: head.headers.first(name: "User-Agent"),
            requestBody: nil,
            responseBody: body,
            responseStatus: 413,
            startTime: stateRef.value.requestStartedAt ?? Date()
        )
    }

    /// Gate replies (upstream `sendResponse`): written and the connection
    /// closed, never routed through Intel's logging `sendResponse`.
    private func sendGateResponse(
        context: ChannelHandlerContext,
        head: HTTPRequestHead?,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        var responseHead = HTTPResponseHead(version: head?.version ?? .http1_1, status: status)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        var nioHeaders = HTTPHeaders()
        for (name, value) in headers {
            nioHeaders.add(name: name, value: value)
        }
        nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
        nioHeaders.add(name: "Connection", value: "close")
        responseHead.headers = nioHeaders
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Bucketing key for the client address (upstream). Relay traffic keys on
    /// the first `X-Forwarded-For` hop; it is a hint, never an identity claim.
    private func remoteIP(_ context: ChannelHandlerContext) -> String {
        let socketIP = context.channel.remoteAddress?.ipAddress ?? "unknown"
        guard stateRef.value.isRelayOrigin else { return socketIP }
        return Self.relayRateLimitKey(
            forwardedFor: stateRef.value.requestHead?.headers.first(name: "X-Forwarded-For"),
            socketIP: socketIP
        )
    }

    /// Pure helper behind `remoteIP` for relay-origin requests.
    static func relayRateLimitKey(forwardedFor: String?, socketIP: String) -> String {
        let firstHop =
            forwardedFor?
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            ?? ""
        let bounded = String(firstHop.prefix(64))
        return bounded.isEmpty ? "relay:\(socketIP)" : "relay:\(bounded)"
    }

    /// Whether the inbound connection is a trusted local caller. Both the
    /// auth gate and CORS auto-trust use this predicate. Relay traffic and
    /// a local agent-scoped key never count.
    private func isLoopbackConnection(_ context: ChannelHandlerContext) -> Bool {
        guard !stateRef.value.isRelayOrigin, !stateRef.value.loopbackTrustWithdrawn else { return false }
        return trustLoopback && (context.channel.remoteAddress?.isLoopback ?? false)
    }

    /// Whether the connection physically arrived over 127.0.0.1 / ::1,
    /// independent of the `trustLoopback` policy flag.
    private func isPhysicalLoopbackConnection(_ context: ChannelHandlerContext) -> Bool {
        guard !stateRef.value.isRelayOrigin else { return false }
        return context.channel.remoteAddress?.isLoopback ?? false
    }

    // MARK: - Agent-scope policy (upstream)

    /// Enforce that an agent-scoped access key only addresses its own agent.
    /// Returns a rejection when the validated key's audience is an agent
    /// address that does not match the target agent. Loopback callers,
    /// master-scoped keys, and public routes (no recorded audience) pass
    /// through unrestricted. An unknown agent→address mapping is denied so a
    /// scoped key cannot reach an agent we can't prove it owns.
    private func agentScopeRejection(forAgentId agentId: UUID) -> (code: String, message: String)? {
        Self.agentScopeRejection(
            forAgentId: agentId,
            authedAudience: stateRef.value.authedAudience,
            authedScopeIsMaster: stateRef.value.authedScopeIsMaster
        )
    }

    /// Pure core of the agent-scope check so it can run inside detached request
    /// tasks (which must not touch the event-loop-bound `stateRef`). Callers
    /// capture `authedAudience` / `authedScopeIsMaster` on the event loop and
    /// pass them in.
    static func agentScopeRejection(
        forAgentId agentId: UUID,
        authedAudience: String?,
        authedScopeIsMaster: Bool
    ) -> (code: String, message: String)? {
        guard let aud = authedAudience, !authedScopeIsMaster else { return nil }
        guard let target = AgentIdentityRegistry.shared.address(forAgentId: agentId), aud == target
        else {
            return (
                "agent_scope_denied",
                "This access key is not scoped to the requested agent."
            )
        }
        return nil
    }

    /// Route-level confinement for agent-scoped access keys, by key origin.
    ///
    /// An agent-scoped key grants access to ONE agent, but historically only
    /// `/agents/{id}*` consulted the key's audience. Two classes of key exist
    /// and they get different policies so shipped integrations are not
    /// disrupted:
    ///
    /// **Workspace-minted keys** (Workspaces attestation handshake; strict
    /// default-deny allowlist — nothing shipped depends on more):
    /// - `GET /models` — the teammate client probes it for model discovery.
    /// - `GET /agents/{id}`, `POST /agents/{id}/run`
    ///   — the per-agent check (`agentScopeRejection`) still applies inside.
    /// - `POST /chat/completions` only while the owner shares inference
    ///   (`PeerInferenceSharing`), so a teammate can use this host as a plain
    ///   OpenAI-compatible backend (Mode 1) on the owner's say-so.
    /// Detached dispatch and task routes are unavailable to workspace keys.
    ///
    /// **Legacy pairing / `AgentInvite` keys** keep their pre-existing surface
    /// minus server administration (`/admin/*`) — a paired peer must never be
    /// able to change how this host runs — and minus the inference routes
    /// (`peerInferenceRouteRejection`) unless the owner shares inference.
    /// Cross-agent reach is closed separately by `agentHeaderScopeRejection`
    /// and `DispatchTaskOwnership`, neither of which a same-agent client ever
    /// trips.
    ///
    /// Scope rejections use the same `agent_scope_denied` shape the per-agent
    /// check uses; an inference route refused because the owner has not opted
    /// in reports `peer_inference_disabled` so the peer's UI can explain it.
    /// Master-scoped keys and callers with no recorded audience (loopback
    /// trust, public routes) are unrestricted. `HEAD` is treated like `GET`.
    static func agentScopedRouteRejection(
        method: HTTPMethod,
        path: String,
        authedAudience: String?,
        authedScopeIsMaster: Bool,
        isWorkspaceMintedKey: Bool,
        peerInferenceEnabled: Bool
    ) -> (code: String, message: String)? {
        guard authedAudience != nil, !authedScopeIsMaster else { return nil }
        if let inferenceRejection = Self.peerInferenceRouteRejection(
            method: method, path: path, peerInferenceEnabled: peerInferenceEnabled
        ) {
            return inferenceRejection
        }
        let allowed =
            isWorkspaceMintedKey
            ? Self.workspaceKeyMayReach(method: method, path: path, peerInferenceEnabled: peerInferenceEnabled)
            : Self.legacyAgentScopedKeyMayReach(method: method, path: path)
        if allowed { return nil }
        return (
            "agent_scope_denied",
            "This access key is scoped to a single agent and cannot access \(path)."
        )
    }

    /// The routes that run this host's models on a caller's behalf — text
    /// generation, embeddings, and media generation. `path` is normalized (no
    /// `/v1` / `/api` prefix, no query string). Model *listing* (`/models`,
    /// `/tags`) is deliberately not here: peers may still call it, and the
    /// handlers answer with an empty catalog while sharing is off
    /// (`peerModelCatalogIsHidden`) so the peer client keeps connecting for
    /// Mode 2 instead of tripping its "peer rejected the connection" path.
    static func isPeerInferenceRoute(method: HTTPMethod, path: String) -> Bool {
        guard method == .POST else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let root = components.first else { return false }
        switch (root, components.count) {
        case ("chat", 1), ("completions", 1), ("generate", 1), ("messages", 1), ("responses", 1),
            ("embeddings", 1), ("embed", 1), ("systemone", 1):
            return true
        case ("chat", 2):
            return components[1] == "completions"
        case ("audio", 2):
            return components[1] == "transcriptions"
        case ("images", 2):
            return ["generations", "edits", "upscale"].contains(components[1])
        case ("videos", 2):
            return ["quote", "generations"].contains(components[1])
        default:
            return false
        }
    }

    /// Owner opt-in gate for every agent-scoped key (workspace-minted or
    /// legacy): while the owner has not shared inference, the inference
    /// routes are refused regardless of key origin. Callers pass the live
    /// setting so the pure policy stays unit-testable.
    static func peerInferenceRouteRejection(
        method: HTTPMethod,
        path: String,
        peerInferenceEnabled: Bool
    ) -> (code: String, message: String)? {
        guard !peerInferenceEnabled, Self.isPeerInferenceRoute(method: method, path: path) else { return nil }
        return (
            "peer_inference_disabled",
            "This Osaurus does not share its models for inference with paired agents. "
                + "Ask the owner to enable it in Server → Overview."
        )
    }

    /// Whether the model catalog (`/models`, `/tags`) should be answered with
    /// an empty list: the caller holds an agent-scoped key (a paired peer) and
    /// the owner has not shared inference. Loopback-trusted callers and
    /// master-scoped keys always see the real catalog.
    static func peerModelCatalogIsHidden(
        authedAudience: String?,
        authedScopeIsMaster: Bool,
        peerInferenceEnabled: Bool
    ) -> Bool {
        guard authedAudience != nil, !authedScopeIsMaster else { return false }
        return !peerInferenceEnabled
    }

    /// Cross-agent header check for agent-scoped keys: when a request names an
    /// agent via `X-Osaurus-Agent-Id` (chat-completions history/memory
    /// attribution, `/memory/*`, `/mcp/call`), that agent must be the one the
    /// key is scoped to. A same-agent client (the relay tunnel stamps the
    /// tunnel's own agent) is unaffected. The built-in Default agent id is
    /// ignored here because the handlers already drop it for external callers.
    /// Malformed values are left to the handlers' existing 4xx paths.
    static func agentHeaderScopeRejection(
        headerValue: String?,
        authedAudience: String?,
        authedScopeIsMaster: Bool,
        resolveAddress: (UUID) -> String? = { AgentIdentityRegistry.shared.address(forAgentId: $0) }
    ) -> (code: String, message: String)? {
        guard let aud = authedAudience, !authedScopeIsMaster else { return nil }
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
            let agentId = UUID(uuidString: raw), agentId != Agent.defaultId
        else { return nil }
        if let target = resolveAddress(agentId), target.lowercased() == aud.lowercased() {
            return nil
        }
        return (
            "agent_scope_denied",
            "X-Osaurus-Agent-Id names an agent this access key is not scoped to."
        )
    }

    /// Legacy pairing / invite keys: everything they could reach before, minus
    /// server administration and the owner's account data (`/credits/*`).
    /// `path` is normalized (no `/v1` / `/api` prefix, no query string).
    static func legacyAgentScopedKeyMayReach(method: HTTPMethod, path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return components.first != "admin" && components.first != "credits"
    }

    /// Strict allowlist for workspace-minted keys. `path` is already
    /// normalized (no `/v1` / `/api` prefix, no query string).
    /// `peerInferenceEnabled` adds `POST /chat/completions` (the teammate
    /// client's Mode 1 route) when the owner shares inference.
    static func workspaceKeyMayReach(
        method: HTTPMethod,
        path: String,
        peerInferenceEnabled: Bool = false
    ) -> Bool {
        let effectiveMethod: HTTPMethod = method == .HEAD ? .GET : method
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let root = components.first else { return false }
        switch root {
        case "models":
            return effectiveMethod == .GET && components.count == 1
        case "chat":
            return peerInferenceEnabled && effectiveMethod == .POST
                && components.count == 2 && components[1] == "completions"
        case "agents":
            guard components.count >= 2, !components[1].isEmpty else { return false }
            if components.count == 2 { return effectiveMethod == .GET }
            if components.count == 3, effectiveMethod == .POST {
                return components[2] == "run"
            }
            return false
        default:
            return false }
    }

    // MARK: - CORS (upstream)

    /// Loopback callers always get `Access-Control-Allow-Origin: *` (issue
    /// #952): a request reaching us via 127.0.0.1 / ::1 is by definition on
    /// the user's machine, so it gets the same trust the auth gate already
    /// grants. Non-loopback callers respect `configuration.allowedOrigins`:
    /// a literal `"*"` matches everything; otherwise the request `Origin`
    /// header must appear in the list verbatim, in which case it's echoed
    /// back with `Vary: Origin`.
    ///
    /// `explicitOriginsOnly` (routes protected by `LocalAPIKeyPolicy`) drops
    /// both the loopback grant and the `"*"` wildcard: only an origin listed
    /// by name is echoed.
    private func computeCORSHeaders(
        for head: HTTPRequestHead,
        isPreflight: Bool,
        isLoopback: Bool,
        explicitOriginsOnly: Bool = false
    ) -> [(String, String)] {
        let origin = head.headers.first(name: "Origin")
        var headers: [(String, String)] = []

        let allowsAny =
            !explicitOriginsOnly && (isLoopback || configuration.allowedOrigins.contains("*"))
        if allowsAny {
            headers.append(("Access-Control-Allow-Origin", "*"))
        } else if let origin,
            !origin.contains("\r"), !origin.contains("\n"),
            LocalAPIKeyPolicy.isExplicitlyAllowedOrigin(origin, allowedOrigins: configuration.allowedOrigins)
        {
            headers.append(("Access-Control-Allow-Origin", origin))
            headers.append(("Vary", "Origin"))
        } else {
            // Not allowed; for preflight return no CORS headers which will cause browser to block
            return []
        }

        if isPreflight {
            // Methods
            let reqMethod = head.headers.first(name: "Access-Control-Request-Method")
            let allowMethods = sanitizeTokenList(reqMethod ?? "GET, POST, OPTIONS, HEAD")
            headers.append(("Access-Control-Allow-Methods", allowMethods))
            // Headers
            let reqHeaders = head.headers.first(name: "Access-Control-Request-Headers")
            let allowHeaders = sanitizeTokenList(reqHeaders ?? "Content-Type, Authorization")
            headers.append(("Access-Control-Allow-Headers", allowHeaders))
            headers.append(("Access-Control-Max-Age", "600"))
        }
        return headers
    }

    /// Allow only RFC7230 token characters plus comma and space for reflected header lists
    private func sanitizeTokenList(_ value: String) -> String {
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~ ,")
        var result = String()
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39,  // 0-9
                0x41 ... 0x5A,  // A-Z
                0x61 ... 0x7A:  // a-z
                result.unicodeScalars.append(scalar)
            default:
                let ch = Character(scalar)
                if allowedPunctuation.contains(ch) {
                    result.append(ch)
                }
            }
        }
        // Trim leading/trailing spaces and collapse runs of spaces around commas
        let collapsed = result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return collapsed
    }

    // MARK: - Request logging (upstream `logRequest`)

    /// Log a request the gate (or a gate-shaped reply) answered. Intel's
    /// routes log through `sendResponse`; both stamp the access-key
    /// attribution the gate recorded.
    func logRequest(
        method: String,
        path: String,
        userAgent: String?,
        requestBody: String?,
        responseBody: String? = nil,
        responseStatus: Int,
        startTime: Date,
        model: String? = nil,
        finishReason: RequestLog.FinishReason? = nil,
        errorMessage: String? = nil,
        details: [String: String]? = nil
    ) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        InsightsService.logAsync(
            method: method,
            path: path,
            clientIP: _clientIP.value,
            userAgent: userAgent,
            requestBody: requestBody,
            responseBody: responseBody,
            responseStatus: responseStatus,
            durationMs: durationMs,
            model: model,
            finishReason: finishReason,
            errorMessage: errorMessage,
            connection: inboundConnectionInfo(),
            details: details
        )
    }

    /// Attribution metadata for an inbound request, built by the auth gate.
    /// Nil for loopback / public routes that carried no token.
    private func inboundConnectionInfo() -> RequestConnectionInfo? {
        let info = _inboundConnection.value
        return (info?.isEmpty == true) ? nil : info
    }

    // MARK: - Health / Root

    private func serveHealth(context: ChannelHandlerContext) {
        let body = #"{"status":"healthy","timestamp":"\#(ISO8601DateFormatter().string(from: Date()))"}"#
        sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: body)
    }

    private func serveRoot(context: ChannelHandlerContext) {
        let body = "Osaurus (Intel) is running! \u{1F995}"
        sendResponse(context: context, status: .ok, headers: textHeaders(), body: body)
    }

    // MARK: - Models

    /// Answer from a request task: hop to the event loop and write through
    /// the connection's context (Intel's counterpart of upstream's `hop`).
    func respondOnLoop(
        _ eventLoop: EventLoop,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        let stateRef = self.stateRef
        eventLoop.execute {
            guard let ctx = stateRef.value.contextBox else { return }
            self.sendResponse(context: ctx, status: status, headers: headers, body: body)
        }
    }

    func requestBodyData() -> Data {
        guard let body = stateRef.value.requestBodyBuffer else { return Data() }
        return Data(body.readableBytesView)
    }

    /// Whether the catalog is hidden from this caller: a paired peer
    /// (agent-scoped key) sees nothing until the owner shares inference
    /// (upstream `peerModelCatalogIsHidden`).
    var hideCatalogFromPeer: Bool {
        Self.peerModelCatalogIsHidden(
            authedAudience: stateRef.value.authedAudience,
            authedScopeIsMaster: stateRef.value.authedScopeIsMaster,
            peerInferenceEnabled: peerInferenceEnabled
        )
    }

    /// `GET /models` (upstream). Intel has no local models (MLX and Apple's
    /// Foundation model need Apple Silicon), so the list is the remote
    /// models the owner exposed in Server › Models.
    private func serveModels(context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        let hide = hideCatalogFromPeer
        runRequestTask {
            let models = hide ? [] : await Self.remoteOpenAIModelsSnapshot()
            let response = ModelsResponse(data: models)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    /// `GET /tags` (Ollama, upstream): the same catalog with Ollama fields.
    private func serveTags(context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        let hide = hideCatalogFromPeer
        runRequestTask {
            let now = Date().ISO8601Format()
            var models: [OpenAIModel] = []
            let remoteModels = hide ? [] : await Self.remoteOpenAIModelsSnapshot()
            for var remoteModel in remoteModels {
                remoteModel.modified_at = now
                remoteModel.size = 0
                remoteModel.digest = ""
                remoteModel.name = remoteModel.id
                remoteModel.model = remoteModel.id
                remoteModel.details = ModelDetails(
                    parent_model: "",
                    format: "remote",
                    family: remoteModel.owned_by,
                    families: [remoteModel.owned_by],
                    parameter_size: "",
                    quantization_level: ""
                )
                models.append(remoteModel)
            }
            let payload = ["models": models]
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(payload)).map { String(decoding: $0, as: UTF8.self) }
                ?? "{}"
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    /// `POST /show` (Ollama, upstream). The Foundation model is never
    /// available on Intel; other ids answer from `ModelInfo` when known.
    private func serveShow(context: ChannelHandlerContext) {
        struct ShowRequest: Decodable {
            let model: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let model = try container.decodeIfPresent(String.self, forKey: .model) {
                    self.model = model
                } else {
                    self.model = try container.decode(String.self, forKey: .name)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case model, name
            }
        }

        guard let req = try? JSONDecoder().decode(ShowRequest.self, from: requestBodyData()) else {
            let errorBody =
                #"{"error":{"message":"Invalid request: expected {\"model\": \"<model_id>\"}","type":"invalid_request_error"}}"#
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: errorBody)
            return
        }
        let modelName = req.model
        if modelName.lowercased() == "foundation" || modelName.lowercased() == "default" {
            let errorBody = #"{"error":{"message":"Foundation model not available","type":"invalid_request_error"}}"#
            sendResponse(context: context, status: .notFound, headers: jsonHeaders(), body: errorBody)
            return
        }
        guard let modelInfo = ModelInfo.load(modelId: modelName) else {
            let errorBody = #"{"error":{"message":"Model not found: \#(modelName)","type":"invalid_request_error"}}"#
            sendResponse(context: context, status: .notFound, headers: jsonHeaders(), body: errorBody)
            return
        }
        let jsonData = (try? JSONEncoder.osaurusCanonical().encode(modelInfo.toShowResponse())) ?? Data("{}".utf8)
        sendResponse(
            context: context, status: .ok, headers: jsonHeaders(), body: String(decoding: jsonData, as: UTF8.self))
    }

    /// Remote models without waiting long on the main actor (upstream):
    /// provider startup may be blocked on Keychain auth.
    private static func remoteOpenAIModelsSnapshot(timeoutNanoseconds: UInt64 = 250_000_000) async
        -> [OpenAIModel]
    {
        await withCheckedContinuation { continuation in
            let once = OneShotContinuation<[OpenAIModel]>()
            let modelsTask = Task {
                let models = await MainActor.run {
                    RemoteProviderManager.shared.getOpenAIModels()
                }
                _ = once.resume(continuation, returning: models)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                if once.resume(continuation, returning: []) {
                    modelsTask.cancel()
                }
            }
        }
    }

    // MARK: - Chat Completions (upstream, on Intel's engine)

    /// The engine API requests run on (`InferenceSource.httpAPI`).
    func makeInferenceEngine() -> any ChatEngineProtocol {
        injectedChatEngine ?? ChatEngine(source: .httpAPI)
    }

    /// `POST /chat/completions` (upstream's contract on Intel's engine): any
    /// configured model, one model round, the client's tools returned as
    /// `tool_calls` rather than run. Streams OpenAI chunks when asked.
    private func serveChatCompletions(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        func reject(_ status: HTTPResponseStatus, _ message: String) {
            let body = Self.errorBody(.openai(type: "invalid_request_error"), message: message)
            sendResponse(context: context, status: status, headers: jsonHeaders(), body: body)
        }

        guard let request = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data),
            let model = request.model, !model.isEmpty
        else {
            reject(.badRequest, "Invalid request format")
            return
        }
        // Upstream rejects what it can't honor instead of silently ignoring it.
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let unsupported = RequestValidator.unsupportedSamplerReason(
            n: request.n,
            responseFormatType: (raw["response_format"] as? [String: Any])?["type"] as? String,
            logprobs: raw["logprobs"] as? Bool,
            topLogprobs: raw["top_logprobs"] as? Int
        ) {
            reject(.badRequest, unsupported)
            return
        }

        let accept = head.headers.first(name: "Accept") ?? ""
        let wantsSSE = (request.stream ?? false) || accept.contains("text/event-stream")
        stateRef.value.routeLogsItself = true
        let created = Int(Date().timeIntervalSince1970)
        let responseId = Self.shortId(prefix: "chatcmpl-", length: 12)
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        let cors = stateRef.value.corsHeaders
        let engine = makeInferenceEngine()

        func log(status: Int, responseBody: String?, finish: RequestLog.FinishReason?, error: String?) {
            logRequest(
                method: "POST", path: "/chat/completions", userAgent: userAgent,
                requestBody: requestBodyString, responseBody: responseBody, responseStatus: status,
                startTime: startTime, model: model, finishReason: finish, errorMessage: error)
        }

        guard wantsSSE else {
            runRequestTask {
                do {
                    let collected = try await IntelHTTPInference.collect(engine: engine, request: request)
                    let body = try Self.chatCompletionBody(
                        collected, id: responseId, created: created, model: model)
                    self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
                    log(status: 200, responseBody: body, finish: collected.finishReason, error: nil)
                } catch {
                    let mapped = Self.inferenceHTTPStatus(for: error)
                    let body = Self.errorBody(.openai(type: mapped.type), message: error.localizedDescription)
                    self.respondOnLoop(eventLoop, status: mapped.status, headers: self.jsonHeaders(), body: body)
                    log(status: Int(mapped.status.code), responseBody: body, finish: .error, error: error.localizedDescription)
                }
            }
            return
        }

        // Streaming: the head goes out now; the task writes chunks on the
        // event loop and stops when the client disconnects.
        stateRef.value.isStreaming = true
        let includeUsage = request.stream_options?.include_usage == true
        let writer = SSEResponseWriter()
        writer.writeHeaders(context, extraHeaders: cors)
        writer.writeRole("assistant", model: model, responseId: responseId, created: created, context: context)
        let onLoop: @Sendable (@escaping @Sendable (ChannelHandlerContext) -> Void) -> Void = { body in
            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                body(ctx)
            }
        }
        let task = runRequestTask {
            // SSE keepalive (upstream): a comment line every 15 s so proxies
            // don't idle out long reasoning or tool pauses.
            let keepalive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { break }
                    onLoop { writer.writePing($0) }
                }
            }
            defer { keepalive.cancel() }
            var collected = IntelHTTPInference.Collected()
            do {
                for try await event in try await IntelHTTPInference.events(engine: engine, request: request) {
                    try Task.checkCancellation()
                    collected.consume(event)
                    switch event {
                    case .content(let text):
                        onLoop { writer.writeContent(text, model: model, responseId: responseId, created: created, context: $0) }
                    case .reasoning(let text):
                        onLoop { writer.writeReasoning(text, model: model, responseId: responseId, created: created, context: $0) }
                    case .toolCalls, .stats, .usage:
                        break
                    }
                }
                let finished = collected
                onLoop { ctx in
                    for (index, call) in finished.toolCalls.enumerated() {
                        writer.writeToolCall(
                            call, index: index, model: model, responseId: responseId, created: created, context: ctx)
                    }
                    writer.writeFinishWithReason(
                        finished.finishReason.rawValue, model: model, responseId: responseId, created: created,
                        context: ctx)
                    // Upstream: the `include_usage` chunk only when the
                    // provider measured usage.
                    if includeUsage, let usage = finished.usage {
                        writer.writeUsageChunk(
                            promptTokens: usage.prompt, completionTokens: usage.completion,
                            model: model, responseId: responseId, created: created, context: ctx)
                    }
                    writer.writeEnd(ctx)
                }
                log(status: 200, responseBody: nil, finish: finished.finishReason, error: nil)
            } catch {
                // The 200 head is out: the failure is an in-band error chunk.
                onLoop { ctx in
                    writer.writeErrorFromThrown(error, context: ctx)
                    writer.writeEnd(ctx)
                }
                log(status: 200, responseBody: nil, finish: .error, error: error.localizedDescription)
            }
        }
        context.channel.closeFuture.whenComplete { _ in task.cancel() }
    }

    /// Upstream's non-streaming body (`chatCompletionsHTTPBody`): the
    /// assistant message and finish reason; `usage` only when the provider
    /// measured it.
    static func chatCompletionBody(
        _ collected: IntelHTTPInference.Collected,
        id: String,
        created: Int,
        model: String
    ) throws -> String {
        let toolCalls: [ToolCall]? =
            collected.toolCalls.isEmpty
            ? nil
            : collected.toolCalls.map {
                ToolCall(
                    id: IntelHTTPInference.callId($0), type: "function",
                    function: ToolCallFunction(name: $0.name, arguments: $0.arguments))
            }
        let assistant = ChatMessage(
            role: "assistant",
            content: collected.content.isEmpty && toolCalls != nil ? nil : collected.content,
            tool_calls: toolCalls,
            tool_call_id: nil,
            reasoning_content: collected.reasoning.isEmpty ? nil : collected.reasoning
        )
        let message = try JSONSerialization.jsonObject(with: JSONEncoder.osaurusCanonical().encode(assistant))
        var object: [String: Any] = [
            "id": id, "object": "chat.completion", "created": created, "model": model,
            "choices": [["index": 0, "message": message, "finish_reason": collected.finishReason.rawValue]],
        ]
        if let usage = collected.usage {
            object["usage"] = [
                "prompt_tokens": usage.prompt, "completion_tokens": usage.completion,
                "total_tokens": usage.prompt + usage.completion,
            ]
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: .osaurusCanonical), as: UTF8.self)
    }

    // MARK: - Legacy completions (upstream validation; local-only route)

    /// `POST /completions`: upstream runs the raw prompt through the local
    /// MLX runtime, bypassing the chat template (fill-in-the-middle). Intel
    /// has no local models, so after upstream's validation it answers 404
    /// saying so; a remote model was never served here upstream either.
    private func serveLegacyCompletions(context: ChannelHandlerContext) {
        func fail(_ status: HTTPResponseStatus, _ type: String, _ message: String) {
            sendResponse(
                context: context, status: status, headers: jsonHeaders(),
                body: Self.errorBody(.openai(type: type), message: message))
        }
        guard let req = try? JSONDecoder().decode(CompletionRequest.self, from: requestBodyData()) else {
            fail(.badRequest, "invalid_request_error", "Invalid request format: 'prompt' is required")
            return
        }
        if let unsupported = req.unsupportedFIMReason {
            fail(.badRequest, "invalid_request_error", unsupported)
            return
        }
        guard !req.prompt.isEmpty else {
            fail(.badRequest, "invalid_request_error", "Invalid request format: 'prompt' is required")
            return
        }
        fail(
            .notFound, "invalid_request_error",
            "Raw completions run on local models, which need a Mac with Apple silicon. Use /v1/chat/completions with a cloud model."
        )
    }

    // MARK: - MCP

    private func serveMCP(context: ChannelHandlerContext) {
        guard let bodyBuffer = stateRef.value.requestBodyBuffer,
              let bodyData = bodyBuffer.getBytes(at: 0, length: bodyBuffer.readableBytes).map({ Data($0) }) else {
            sendJSONError(context: context, status: .badRequest, message: "Empty body")
            return
        }

        guard let head = stateRef.value.requestHead else {
            sendEmptyResponse(context: context, status: .badRequest)
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = value
        }

        let mcpRequest = HTTPRequest(
            method: "POST",
            headers: headers,
            body: bodyData,
            path: "/mcp"
        )

        let eventLoop = context.eventLoop
        let stateRef = self.stateRef

        runRequestTask {
            let response = await MCPBridge.shared.handleMCPRequest(mcpRequest)

            eventLoop.execute {
                guard let ctx = stateRef.value.contextBox else { return }
                switch response {
                case .data(let data, _):
                    if let json = String(data: data, encoding: .utf8) {
                        self.sendResponse(context: ctx, status: .ok, headers: self.jsonHeaders(), body: json)
                    } else {
                        self.sendEmptyResponse(context: ctx, status: .internalServerError)
                    }
                case .error(let code, _, _, _):
                    if let body = response.bodyData, let json = String(data: body, encoding: .utf8) {
                        self.sendResponse(context: ctx, status: HTTPResponseStatus(statusCode: code), headers: self.jsonHeaders(), body: json)
                    } else {
                        self.sendEmptyResponse(context: ctx, status: HTTPResponseStatus(statusCode: code))
                    }
                case .accepted:
                    self.sendEmptyResponse(context: ctx, status: .accepted)
                case .ok:
                    self.sendEmptyResponse(context: ctx, status: .ok)
                case .stream:
                    self.sendJSONError(context: ctx, status: .notImplemented, message: "SSE MCP not supported")
                default:
                    self.sendEmptyResponse(context: ctx, status: .internalServerError)
                }
            }
        }
    }

    // MARK: - Response Helpers

    func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String
    ) {
        var responseHeaders = HTTPHeaders()
        for (name, value) in headers {
            responseHeaders.add(name: name, value: value)
        }
        // CORS for the current request, computed at `.head` (upstream).
        for (name, value) in stateRef.value.corsHeaders {
            responseHeaders.add(name: name, value: value)
        }
        responseHeaders.add(name: "content-length", value: String(body.utf8.count))
        responseHeaders.add(name: "connection", value: "keep-alive")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: responseHeaders)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        // M13 (Insights): record this request so the Insights tab shows real
        // server traffic. Covers every non-streaming endpoint (health, models,
        // MCP, router, non-stream chat); SSE streaming chat bypasses this sink.
        // The in-app chat uses CloudChatEngine directly, so this reflects
        // external API/MCP clients hitting the local server.
        if let head = stateRef.value.requestHead {
            let started = stateRef.value.requestStartedAt
            let durationMs = started.map { Date().timeIntervalSince($0) * 1000 } ?? 0
            if stateRef.value.routeLogsItself { return }
            _ = durationMs
            logRequest(
                method: head.method.rawValue,
                path: stateRef.value.normalizedPath,
                userAgent: head.headers.first(name: "User-Agent"),
                requestBody: nil,
                responseStatus: Int(status.code),
                startTime: started ?? Date()
            )
        }
    }

    private func sendEmptyResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let head = HTTPResponseHead(version: .http1_1, status: status)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendJSONError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        let body = "{\"error\":{\"message\":\"\(message)\"}}"
        let hs: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
        sendResponse(context: context, status: status, headers: hs, body: body)
    }

    func jsonHeaders() -> [(String, String)] {
        [("Content-Type", "application/json; charset=utf-8")]
    }

    func textHeaders() -> [(String, String)] {
        [("Content-Type", "text/plain; charset=utf-8")]
    }
}
