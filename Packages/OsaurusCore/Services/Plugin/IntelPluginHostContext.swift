//
//  IntelPluginHostContext.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2a (docs/UPSTREAM_SYNC.md, "Plugin host
//  safety"): upstream's `PluginHostContext` for Intel's slim plugin host
//  (`IntelPluginExecution`). Upstream's `PluginHostAPI.swift` stays
//  compiled out (its inference half needs upstream's chat engine), so this
//  file carries the parts that only need Foundation, copied verbatim from
//  upstream `bce907045`:
//
//  - the per-plugin context registry and the thread-local plugin / agent
//    scope the C trampolines read;
//  - `http_request`: SSRF checks on the URL and on every redirect, the
//    no-redirect session, per-(plugin, agent) rate limits, 50 MB caps;
//  - `file_read`: upstream's `{"path"}` contract, limited to the
//    artifacts folder;
//  - the dispatch rate limit, the bounded async bridges and the JSON
//    helpers.
//
//  Upstream keeps the database, dispatch, inference and task-event
//  callbacks on this class too. On Intel those still live in
//  `IntelPluginExecution` until their own stages port them.
//

#if OSAURUS_INTEL

import Foundation
import os

// MARK: - Per-Plugin Host Context

/// Holds per-plugin state needed by host API callbacks.
/// Registered in a global dictionary keyed by plugin ID so that
/// @convention(c) trampolines can look up the right context.
final class PluginHostContext: @unchecked Sendable {

    // MARK: - Context Registry (thread-safe)

    private nonisolated(unsafe) static var contexts: [String: PluginHostContext] = [:]
    private static let contextsLock = NSLock()

    static func getContext(for pluginId: String) -> PluginHostContext? {
        contextsLock.withLock { contexts[pluginId] }
    }

    static func setContext(_ ctx: PluginHostContext, for pluginId: String) {
        contextsLock.withLock { contexts[pluginId] = ctx }
    }

    static func removeContext(for pluginId: String) {
        contextsLock.withLock { _ = contexts.removeValue(forKey: pluginId) }
    }

    static func rekeyContext(from oldId: String, to newId: String) {
        contextsLock.withLock {
            if let ctx = contexts.removeValue(forKey: oldId) {
                contexts[newId] = ctx
            }
        }
    }

    /// Temporary fallback used only during plugin init — set right before
    /// the plugin's `init` / `osaurus_plugin_entry_v2` call and cleared
    /// right after, so trampolines fired from inside that frame can
    /// resolve the context before `setContext` has registered it under
    /// the plugin id. Plugin loads in `PluginManager` are sequential, so
    /// today there is no concurrent writer, but the unfair-lock wrapper
    /// keeps the path future-proof against a refactor that loads
    /// plugins in parallel and avoids the `nonisolated(unsafe)` hazard.
    private static let _currentContext = OSAllocatedUnfairLock<PluginHostContext?>(initialState: nil)
    static var currentContext: PluginHostContext? {
        get { _currentContext.withLock { $0 } }
        set { _currentContext.withLock { $0 = newValue } }
    }

    // MARK: - Instance Properties

    let pluginId: String

    // Intel: the host-API table (`hostAPIPtr` upstream) is owned by
    // `IntelLoadedPlugin`, which frees it at teardown.

    private struct HTTPTransportSessionState {
        let proxyKey: String
        let session: URLSession
    }

    private static let noRedirectSessionBox = OSAllocatedUnfairLock<HTTPTransportSessionState?>(initialState: nil)

    /// Shared URLSession that suppresses redirects. `http_request`
    /// follows redirects manually so every `Location` target can pass
    /// through the same SSRF guard before the host connects.
    static func noRedirectSession() -> URLSession {
        let proxyKey = currentHTTPTransportProxyKey()
        return noRedirectSessionBox.withLock { state in
            if let state, state.proxyKey == proxyKey {
                return state.session
            }

            state?.session.finishTasksAndInvalidate()
            let session = makeNoRedirectSession()
            state = HTTPTransportSessionState(proxyKey: proxyKey, session: session)
            return session
        }
    }

    private static func currentHTTPTransportProxyKey() -> String {
        GlobalProxySettings.currentConfiguration()?.redactedDescription ?? ""
    }

    private static func makeNoRedirectSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 10
        return GlobalProxySettings.makeSession(
            base: config,
            delegate: NoRedirectDelegate.shared,
            delegateQueue: nil
        )
    }

    private static let maxHTTPRedirects = 20

    /// Sliding window timestamps for dispatch rate limiting, keyed by agent ID.
    /// The bucket is **per (plugin, agent) pair** — each plugin keeps its own
    /// `PluginHostContext`, so two plugins running for the same agent each
    /// get an independent 10/min quota. This is intentional: it prevents a
    /// chatty plugin from starving another plugin's dispatches against the
    /// same agent. Plugin authors should size their dispatch cadence
    /// against the per-plugin budget, not against a notional global one.
    private let rateLimitLock = NSLock()
    private var dispatchTimestamps: [UUID: [Date]] = [:]
    private static let dispatchRateLimit = 10
    private static let dispatchRateWindow: TimeInterval = 60

    /// Sliding-window timestamps for `http_request` rate limiting,
    /// keyed by the resolved active agent so each agent's bucket is
    /// independent (matches the dispatch limiter's shape). Caps a
    /// chatty plugin's outbound HTTP traffic so it can't saturate the
    /// `httpSession` connection pool or trip third-party rate limits
    /// silently. Note: this is a *host-side* control to stop runaway
    /// plugins, not a substitute for the plugin's own backoff against
    /// upstream APIs.
    private var httpTimestamps: [UUID: [Date]] = [:]
    static let httpRateLimit = 60
    static let httpRateWindow: TimeInterval = 60

    // MARK: - Per-Request Agent Context

    /// Resolved agent ID for the current thread, or `nil` when no chat agent
    /// is bound to this invocation. Checks thread-local storage (set per-
    /// dispatch in `ExternalPlugin` wrappers); each invokeQueue / eventQueue
    /// thread gets its own value.
    ///
    /// The Default (built-in) agent is intentionally treated as "no agent
    /// context" for plugin operations: plugins MUST NOT silently inherit
    /// the Default agent's secret namespace, tool grants, or rate-limit
    /// quota when invoked without an explicit chat binding. That historical
    /// `?? Agent.defaultId` fallback leaked the Default agent's data and
    /// permissions to anonymous plugin paths.
    var resolvedAgentIdOrNil: UUID? {
        guard let id = Self.activeAgentId() else { return nil }
        return id == Agent.defaultId ? nil : id
    }

    /// Deterministic synthetic UUID used as the bucket key for per-agent rate
    /// limiting when the current invocation has no chat-bound agent context.
    /// Distinct from `Agent.defaultId` so anonymous plugin traffic doesn't
    /// share a bucket with — or accrue quota against — the Default agent.
    static let anonymousPluginRateBucketId = UUID(
        uuidString: "ffffffff-ffff-ffff-ffff-fffffffffff0"
    )!
    /// Intel: upstream's init also builds the plugin database and an
    /// inference engine factory; Intel's host keeps those in
    /// `IntelPluginExecution` for now.
    init(pluginId: String) throws {
        self.pluginId = pluginId
    }

    // MARK: - HTTP Client Callback

    func httpRequest(requestJSON: String) -> String {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = json["method"] as? String,
            let urlStr = json["url"] as? String,
            let url = URL(string: urlStr)
        else {
            return Self.jsonString(["error": "invalid_request", "message": "Missing required fields: method, url"])
        }

        if let ssrfError = Self.checkSSRF(url: url) {
            return Self.jsonString(["error": "ssrf_blocked", "message": ssrfError])
        }

        // Per-(plugin, agent) HTTP token bucket. Caps the host-side
        // outbound traffic a single plugin can emit; mirrors the
        // dispatch limiter's shape. Plugins that need higher
        // throughput should batch upstream or backoff on
        // `rate_limit_exceeded` like any other API client.
        //
        // Anonymous plugin traffic (no chat-bound agent) buckets against a
        // synthetic sentinel UUID — not `Agent.defaultId` — so its quota
        // is distinct from the Default agent's and the built-in agent's
        // identity isn't reused as a fairness key.
        let rateLimitAgentId = resolvedAgentIdOrNil ?? Self.anonymousPluginRateBucketId
        guard checkHttpRateLimit(agentId: rateLimitAgentId) else {
            return Self.jsonString([
                "error": "rate_limit_exceeded",
                "message":
                    "http_request rate limit (\(Self.httpRateLimit)/\(Int(Self.httpRateWindow))s) "
                    + "exceeded for this plugin and agent.",
                "retry_after_ms": Int(Self.httpRateWindow * 1000),
            ])
        }

        let timeoutMs = json["timeout_ms"] as? Int ?? 30000
        let clampedTimeout = min(timeoutMs, 300000)
        let followRedirects = json["follow_redirects"] as? Bool ?? true

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = TimeInterval(clampedTimeout) / 1000.0

        if let headers = json["headers"] as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = json["body"] as? String {
            let encoding = json["body_encoding"] as? String ?? "utf8"
            if encoding == "base64" {
                request.httpBody = Data(base64Encoded: body)
            } else {
                request.httpBody = Data(body.utf8)
            }

            if let bodyData = request.httpBody, bodyData.count > 50_000_000 {
                return Self.jsonString(["error": "request_too_large", "message": "Request body exceeds 50MB limit"])
            }
        }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let suffix = "Osaurus/\(appVersion) Plugin/\(pluginId)"
        let existing = request.value(forHTTPHeaderField: "User-Agent")
        request.setValue(existing.map { "\($0) \(suffix)" } ?? suffix, forHTTPHeaderField: "User-Agent")

        let finalRequest = request

        return Self.blockingAsync(fallback: Self.pluginHostTimeoutJSON(kind: "http_request")) {
            let startTime = Date()
            do {
                var currentRequest = finalRequest
                var redirectCount = 0

                while true {
                    let (responseData, urlResponse) = try await Self.noRedirectSession().data(for: currentRequest)
                    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

                    guard let httpResponse = urlResponse as? HTTPURLResponse else {
                        return Self.jsonString([
                            "error": "invalid_response", "message": "Non-HTTP response", "elapsed_ms": elapsed,
                        ])
                    }

                    if followRedirects {
                        let redirect = Self.checkedHTTPRedirectRequest(from: currentRequest, response: httpResponse)
                        if let ssrfError = redirect.ssrfError {
                            return Self.jsonString([
                                "error": "ssrf_blocked", "message": ssrfError, "elapsed_ms": elapsed,
                            ])
                        }
                        if let nextRequest = redirect.request {
                            redirectCount += 1
                            guard redirectCount <= Self.maxHTTPRedirects else {
                                return Self.jsonString([
                                    "error": "too_many_redirects",
                                    "message": "HTTP redirect limit exceeded",
                                    "elapsed_ms": elapsed,
                                ])
                            }
                            currentRequest = nextRequest
                            continue
                        }
                    }

                    if responseData.count > 50_000_000 {
                        return Self.jsonString([
                            "error": "response_too_large", "message": "Response body exceeds 50MB limit",
                            "elapsed_ms": elapsed,
                        ])
                    }

                    var responseHeaders: [String: String] = [:]
                    for (key, value) in httpResponse.allHeaderFields {
                        responseHeaders[String(describing: key).lowercased()] = String(describing: value)
                    }

                    let bodyStr: String
                    let bodyEncoding: String
                    if let str = String(data: responseData, encoding: .utf8) {
                        bodyStr = str
                        bodyEncoding = "utf8"
                    } else {
                        bodyStr = responseData.base64EncodedString()
                        bodyEncoding = "base64"
                    }

                    let response: [String: Any] = [
                        "status": httpResponse.statusCode,
                        "headers": responseHeaders,
                        "body": bodyStr,
                        "body_encoding": bodyEncoding,
                        "elapsed_ms": elapsed,
                    ]
                    return Self.jsonString(response)
                }
            } catch let error as URLError {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                let errorType: String
                switch error.code {
                case .timedOut: errorType = "connection_timeout"
                case .cannotConnectToHost: errorType = "connection_refused"
                case .cannotFindHost: errorType = "dns_failure"
                case .serverCertificateUntrusted, .secureConnectionFailed: errorType = "tls_error"
                case .httpTooManyRedirects: errorType = "too_many_redirects"
                default: errorType = "network_error"
                }
                return Self.jsonString([
                    "error": errorType, "message": error.localizedDescription, "elapsed_ms": elapsed,
                ])
            } catch {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return Self.jsonString([
                    "error": "network_error", "message": error.localizedDescription, "elapsed_ms": elapsed,
                ])
            }
        }
    }

    // MARK: - File Read Callback

    private static let fileReadMaxBytes = 50_000_000

    func fileRead(requestJSON: String) -> String {
        let data = Data(requestJSON.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let path = json["path"] as? String
        else {
            return Self.jsonString(["error": "invalid_request", "message": "Missing required field: path"])
        }

        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let allowedPrefix = OsaurusPaths.artifactsDir().standardizedFileURL.path + "/"

        guard fileURL.path.hasPrefix(allowedPrefix) else {
            return Self.jsonString(["error": "access_denied", "message": "File read restricted to artifact paths"])
        }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? Int
        else {
            return Self.jsonString(["error": "not_found", "message": "File does not exist"])
        }

        guard size <= Self.fileReadMaxBytes else {
            return Self.jsonString(["error": "file_too_large", "message": "File exceeds 50MB limit"])
        }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            return Self.jsonString(["error": "read_error", "message": "Failed to read file"])
        }

        let mimeType = SharedArtifact.mimeType(from: fileURL.lastPathComponent)
        return Self.jsonString([
            "data": fileData.base64EncodedString(),
            "size": size,
            "mime_type": mimeType,
        ])
    }

    /// Removes this context from the global registry (upstream). Intel's
    /// plugin database is closed by `IntelPluginExecution`.
    func teardown() {
        PluginHostContext.removeContext(for: pluginId)
    }
}

// MARK: - Rate Limiting

extension PluginHostContext {
    /// Sliding-window check: returns true and records `now` if there
    /// are fewer than `limit` recorded timestamps inside `window`,
    /// false otherwise. The timestamp array is rewritten in place
    /// under `rateLimitLock` (already held by the caller), so this is
    /// a pure helper — both `checkDispatchRateLimit` and
    /// `checkHttpRateLimit` route through it to keep their semantics
    /// in lockstep.
    private func consumeSlidingWindow(
        timestamps: inout [Date],
        limit: Int,
        window: TimeInterval
    ) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)
        timestamps.removeAll { $0 < cutoff }
        guard timestamps.count < limit else { return false }
        timestamps.append(now)
        return true
    }

    /// Returns true if the dispatch is allowed under the per-agent rate limit.
    func checkDispatchRateLimit(agentId: UUID) -> Bool {
        rateLimitLock.withLock {
            var timestamps = dispatchTimestamps[agentId, default: []]
            let allowed = consumeSlidingWindow(
                timestamps: &timestamps,
                limit: Self.dispatchRateLimit,
                window: Self.dispatchRateWindow
            )
            dispatchTimestamps[agentId] = timestamps
            return allowed
        }
    }

    /// Returns true if an `http_request` call from the current
    /// `(plugin, agent)` is under the sliding-window rate limit.
    /// Sharing the same `rateLimitLock` as dispatch keeps both
    /// counters consistent under concurrency without adding another
    /// lock.
    func checkHttpRateLimit(agentId: UUID) -> Bool {
        rateLimitLock.withLock {
            var timestamps = httpTimestamps[agentId, default: []]
            let allowed = consumeSlidingWindow(
                timestamps: &timestamps,
                limit: Self.httpRateLimit,
                window: Self.httpRateWindow
            )
            httpTimestamps[agentId] = timestamps
            return allowed
        }
    }
}

// MARK: - SSRF Protection

extension PluginHostContext {
    /// Returns an error message if the URL targets a private / loopback /
    /// link-local / IPv6-mapped-private address, nil if safe.
    ///
    /// **Known limitation:** this check operates on the URL string only —
    /// it does NOT resolve the hostname before deciding. A hostname that
    /// looks public (`evil.example.com`) but resolves to a private IP at
    /// connection time (DNS rebinding, attacker-controlled DNS, internal
    /// CNAME) WILL pass this check and the host will issue the request.
    /// Mitigating that requires a custom URLSession delegate that
    /// inspects the resolved IP at the network-layer (see
    /// `URLSessionDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
    /// + a `Network.framework` resolution step). Tracked separately;
    /// document it under HOST_API.md so plugin authors don't assume
    /// SSRF is end-to-end.
    static func checkSSRF(url: URL) -> String? {
        guard let rawHost = url.host?.lowercased() else { return "Missing host" }
        // URL.host strips the surrounding `[` `]` for IPv6 literals,
        // but be defensive in case a future call site passes them in.
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if host == "localhost" || host == "ip6-localhost" || host == "ip6-loopback" {
            return ssrfBlocked("localhost")
        }

        // IPv6 literal handling. URL.host returns the bracket-stripped
        // form (`::1`, `fe80::1`, `::ffff:127.0.0.1`). We catch the
        // common loopback / link-local / unique-local prefixes, plus
        // IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`)
        // forms that point at private IPv4 space — those are the
        // common SSRF bypass tricks against an IPv4-only blocklist.
        if host.contains(":") {
            if host == "::1" { return ssrfBlocked("loopback IPv6") }
            if host == "::" { return ssrfBlocked("unspecified IPv6") }
            if host.hasPrefix("fe80:") { return ssrfBlocked("link-local IPv6") }
            // Unique local (RFC 4193: fc00::/7 — fc00–fdff). We're
            // already inside the `host.contains(":")` IPv6 branch, so
            // an `fc`/`fd` prefix is unambiguously the literal — a
            // hostname like `fcc.gov` would have been routed to the
            // IPv4 branch above (no colon).
            if host.hasPrefix("fc") || host.hasPrefix("fd") {
                return ssrfBlocked("unique-local IPv6")
            }
            // IPv4-mapped (`::ffff:a.b.c.d`) and IPv4-compatible (`::a.b.c.d`):
            // extract the trailing IPv4 dotted-quad and re-run the IPv4 check.
            if let v4 = embeddedIPv4(in: host),
                let blocked = ssrfBlockedIPv4(v4)
            {
                return ssrfBlocked("IPv6-mapped \(blocked)")
            }
            // Any other IPv6 literal we didn't recognize — out of scope
            // for the IPv4-centric blocklist.
            return nil
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        if let blocked = ssrfBlockedIPv4(octets) {
            return ssrfBlocked(blocked)
        }
        return nil
    }

    /// Pulls the trailing dotted-quad out of an IPv6 literal that
    /// embeds an IPv4 address (`::ffff:127.0.0.1` or `::127.0.0.1`).
    /// Returns the four-octet form so the IPv4 blocklist can run.
    private static func embeddedIPv4(in host: String) -> [UInt8]? {
        guard let lastColon = host.lastIndex(of: ":") else { return nil }
        let tail = String(host[host.index(after: lastColon)...])
        let octets = tail.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets
    }

    /// Returns the human-readable block reason for a given IPv4
    /// dotted-quad, or nil when the address is public-routable. Pulled
    /// out so the IPv6-mapped path can reuse the same blocklist.
    private static func ssrfBlockedIPv4(_ octets: [UInt8]) -> String? {
        guard octets.count == 4 else { return nil }
        let (a, b) = (octets[0], octets[1])
        let dotted = "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        if a == 127 { return "IPv4 loopback (\(dotted))" }
        if a == 10 { return "RFC1918 10.0.0.0/8 (\(dotted))" }
        if a == 172 && b >= 16 && b <= 31 { return "RFC1918 172.16.0.0/12 (\(dotted))" }
        if a == 192 && b == 168 { return "RFC1918 192.168.0.0/16 (\(dotted))" }
        if a == 0 { return "RFC1122 \"this network\" 0.0.0.0/8 (\(dotted))" }
        if a == 169 && b == 254 {
            // 169.254.169.254 is the AWS / GCP / Azure / DO instance
            // metadata IP. The whole 169.254/16 link-local range is
            // already blocked, but call it out so the message is
            // diagnosable.
            return "link-local 169.254.0.0/16 (cloud metadata, \(dotted))"
        }
        if a == 100 && b >= 64 && b <= 127 { return "carrier-grade NAT 100.64.0.0/10 (\(dotted))" }
        if a >= 224 && a <= 239 { return "multicast 224.0.0.0/4 (\(dotted))" }
        return nil
    }

    private static func ssrfBlocked(_ target: String) -> String {
        "Requests to \(target) are blocked (SSRF protection)"
    }

    static func checkedHTTPRedirectRequest(
        from request: URLRequest,
        response: HTTPURLResponse
    ) -> (request: URLRequest?, ssrfError: String?) {
        guard (300 ... 399).contains(response.statusCode),
            let location = redirectLocation(from: response),
            let baseURL = response.url ?? request.url,
            let redirectURL = URL(string: location, relativeTo: baseURL)?.absoluteURL
        else {
            return (nil, nil)
        }

        if let ssrfError = checkSSRF(url: redirectURL) {
            return (nil, ssrfError)
        }

        var redirected = request
        redirected.url = redirectURL
        normalizeRedirectMethod(on: &redirected, originalRequest: request, statusCode: response.statusCode)
        stripCrossOriginCredentials(on: &redirected, originalURL: request.url, redirectURL: redirectURL)
        return (redirected, nil)
    }

    /// Extracts `Location` without depending on Foundation's header
    /// key casing. Some local test responses use lowercase while
    /// remote servers commonly title-case it.
    private static func redirectLocation(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard String(describing: key).lowercased() == "location" else { continue }
            return String(describing: value)
        }
        return nil
    }

    /// Matches normal user-agent redirect semantics for unsafe
    /// methods: 301/302/303 drop the request body and become GET,
    /// while 307/308 preserve method and body.
    private static func normalizeRedirectMethod(
        on request: inout URLRequest,
        originalRequest: URLRequest,
        statusCode: Int
    ) {
        let method = originalRequest.httpMethod?.uppercased()
        guard [301, 302, 303].contains(statusCode), method != "GET", method != "HEAD" else { return }
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
    }

    /// Cross-origin redirects should not carry credentials intended
    /// for the original host. `URLSession` does this for automatic
    /// redirects; manual redirect following has to preserve it here.
    private static func stripCrossOriginCredentials(
        on request: inout URLRequest,
        originalURL: URL?,
        redirectURL: URL
    ) {
        guard originFingerprint(originalURL) != originFingerprint(redirectURL) else { return }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
    }

    private static func originFingerprint(_ url: URL?) -> String? {
        guard let url,
            let scheme = url.scheme?.lowercased(),
            let host = url.host?.lowercased()
        else {
            return nil
        }
        return "\(scheme)://\(host):\(normalizedPort(for: url, scheme: scheme))"
    }

    private static func normalizedPort(for url: URL, scheme: String) -> Int {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return -1
        }
    }
}

// MARK: - No-Redirect URLSession Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Async Bridging Helpers

/// Thread-safe box for passing a result out of a Task closure in Swift 6
/// strict concurrency. Self-synchronizing via an internal lock so it doesn't
/// silently depend on an external semaphore as its only memory barrier — the
/// write happens on the bridge queue, the read on the parked trampoline
/// thread, so the lock makes the cross-thread handoff explicit and correct.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?

    func set(_ newValue: T) {
        lock.lock()
        _value = newValue
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}

extension PluginHostContext {
    /// Dedicated GCD queue used to run the inner async-bridge `Task` so that
    /// the cooperative thread pool's executor cannot deadlock with the
    /// outside semaphore wait. Concurrent so multiple plugin trampolines can
    /// progress in parallel; QoS matches a user-initiated request.
    ///
    /// Why this matters: `blockingAsync` parks the *trampoline thread* on a
    /// `DispatchSemaphore` while a Swift `Task` runs the async work. If that
    /// trampoline thread happened to be one of the cooperative pool's worker
    /// threads (e.g. a future refactor that calls `blockingAsync` from a
    /// `Task`), and the inner async work needs to await on something that
    /// also needs that pool, the system can deadlock — `sem.wait()` blocks
    /// the only thread the inner Task could resume on.
    ///
    /// We can't fully prevent that — `Task.detached` still uses the cooperative
    /// pool — but we *can* ensure that the inner Task never inherits
    /// the caller's actor or priority. Combined with the `!Thread.isMainThread`
    /// assert, this keeps the contract safe for plugin worker threads.
    private static let blockingBridgeQueue = DispatchQueue(
        label: "com.osaurus.pluginHost.blockingBridge",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Block the current (non-main) thread while running async work.
    /// Used by C trampolines that must return synchronously.
    ///
    /// Uses `Task.detached` so the inner work never inherits the caller's
    /// actor isolation or priority, and runs the signal on a dedicated
    /// concurrent GCD queue so the wakeup path doesn't depend on the
    /// cooperative pool having a free worker.
    ///
    /// Bounded: `sem.wait` carries a deadline so a wedged inner `Task`
    /// (cooperative-pool starvation, an inner `await` that never resumes,
    /// a hung downstream) can NOT hang the plugin worker thread forever.
    /// On timeout we cancel the inner work and return `fallback` instead of
    /// force-unwrapping a value that was never produced (the old `box.value!`
    /// could trap). The default ceiling is intentionally generous (30 min)
    /// so it never trips a legitimate long completion / embed, only a true
    /// deadlock; callers may shorten it.
    static func blockingAsync<T: Sendable>(
        timeout: DispatchTime = .now() + 1800,
        fallback: @autoclosure @escaping () -> T,
        onTaskCreated: (@Sendable (Task<Void, Never>) -> Void)? = nil,
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached(priority: .userInitiated) {
            let value = await work()
            blockingBridgeQueue.async {
                box.set(value)
                sem.signal()
            }
        }
        onTaskCreated?(task)
        guard sem.wait(timeout: timeout) == .success else {
            task.cancel()
            NSLog("[PluginHostAPI] blockingAsync timed out — cancelling inner work, returning fallback")
            return fallback()
        }
        return box.get() ?? fallback()
    }

    /// Block the current (non-main) thread while running @MainActor work.
    ///
    /// Bounded for the same reason as `blockingAsync`, but with a much
    /// shorter default deadline: the wrapped work is a quick MainActor hop
    /// (read task state, toggle a flag). The deadline is also the backstop
    /// for the load-time first-delivery path — if a plugin's
    /// `on_config_changed` calls a `blockingMainActor` host API while the
    /// main thread is parked in `ExternalPlugin.notifyConfigBatchSync`'s
    /// `configEventQueue.sync`, the wait can't acquire main; the timeout
    /// converts that would-be permanent deadlock into a bounded return.
    @discardableResult
    static func blockingMainActor<T: Sendable>(
        timeout: DispatchTime = .now() + 30,
        fallback: @autoclosure @escaping () -> T,
        _ work: @MainActor @escaping @Sendable () -> T
    ) -> T {
        assert(!Thread.isMainThread, "Host API trampoline must not be called from main thread")
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached(priority: .userInitiated) { @MainActor in
            let value = work()
            blockingBridgeQueue.async {
                box.set(value)
                sem.signal()
            }
        }
        guard sem.wait(timeout: timeout) == .success else {
            task.cancel()
            NSLog("[PluginHostAPI] blockingMainActor timed out — cancelling inner work, returning fallback")
            return fallback()
        }
        return box.get() ?? fallback()
    }

    /// Canonical error envelope returned when a host bridge times out, so a
    /// plugin sees a structured failure instead of an opaque empty string.
    static func pluginHostTimeoutJSON(kind: String) -> String {
        jsonString([
            "error": "host_timeout",
            "message": "Host \(kind) call exceeded its time budget and was cancelled.",
        ])
    }

    /// Serialize a dictionary to a JSON string. Falls back to "{}" on encoding failure.
    /// Uses canonical (sorted-keys) output so plugin-side prompt prefixes and
    /// chunk payloads stay byte-stable across calls.
    static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .osaurusCanonical)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse a JSON string back into a dictionary.
    static func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

// MARK: - C Trampoline Functions

/// These are @convention(c) functions that look up the active PluginHostContext
/// via thread-local storage (primary), a best-effort global fallback, or
/// `currentContext` (during init).
///
/// Context resolution order in `activeContext()`:
/// 1. Thread-local storage — set per-thread around each plugin call. This is
///    the primary and fully concurrent-safe mechanism, and the recommended
///    path for all plugin-initiated host calls.
/// 2. `lastDispatchedPluginId` — best-effort global fallback for background
///    threads that plugins spawn (e.g. `DispatchQueue.global().async`). The
///    value is protected by a lock so reads/writes are race-free, but the
///    *value itself* is the most-recently-dispatched plugin id, which is
///    racy when multiple plugins run simultaneously. The first time this
///    fallback resolves a context for a given plugin, the host emits a
///    one-shot warning so the plugin developer learns to do their own work
///    on a context-carrying thread (e.g. by capturing the host API pointer
///    on the dispatch thread and calling back from there).
/// 3. `currentContext` — temporary fallback used only during plugin init.
extension PluginHostContext {
    /// Thread-local storage for the active plugin ID during C callback dispatch
    private static let tlsKey: String = "ai.osaurus.plugin.active"

    /// Thread-local storage for the active agent ID during C callback dispatch.
    /// Set per-thread around each plugin call so concurrent requests for
    /// different agents on the same invokeQueue resolve the correct agent.
    private static let agentTlsKey: String = "ai.osaurus.plugin.agent"

    /// Best-effort fallback for plugin-spawned background threads that don't
    /// have TLS set. Protected by `fallbackLock` to avoid data races under
    /// concurrent execution. TLS (option 1) is the authoritative mechanism.
    private static let fallbackLock = NSLock()
    private nonisolated(unsafe) static var _lastDispatchedPluginId: String?

    private static var lastDispatchedPluginId: String? {
        get { fallbackLock.withLock { _lastDispatchedPluginId } }
        set { fallbackLock.withLock { _lastDispatchedPluginId = newValue } }
    }

    static func setActivePlugin(_ pluginId: String) {
        Thread.current.threadDictionary[tlsKey] = pluginId
        lastDispatchedPluginId = pluginId
    }

    static func clearActivePlugin() {
        Thread.current.threadDictionary.removeObject(forKey: tlsKey)
    }

    static func setActiveAgent(_ agentId: UUID) {
        Thread.current.threadDictionary[agentTlsKey] = agentId
    }

    static func clearActiveAgent() {
        Thread.current.threadDictionary.removeObject(forKey: agentTlsKey)
    }

    static func activeAgentId() -> UUID? {
        Thread.current.threadDictionary[agentTlsKey] as? UUID
    }

    /// Run `body` with the plugin TLS slots set to `pluginId` and
    /// `agentId`, then clear them on exit (success or throw). Collapses
    /// the set / defer-clear pattern repeated by `dispatchPluginCall`,
    /// `notifyConfigBatch`, and `notifyTaskEvent` in `ExternalPlugin`.
    static func withTLSScope<R>(pluginId: String, agentId: UUID?, _ body: () -> R) -> R {
        setActivePlugin(pluginId)
        if let agentId { setActiveAgent(agentId) }
        defer {
            clearActivePlugin()
            clearActiveAgent()
        }
        return body()
    }

    private static func activeContext() -> PluginHostContext? {
        if let pluginId = Thread.current.threadDictionary[tlsKey] as? String {
            return getContext(for: pluginId)
        }
        if let pluginId = lastDispatchedPluginId {
            warnFallbackOnce(pluginId: pluginId)
            return getContext(for: pluginId)
        }
        return currentContext
    }

    /// Emit a one-shot deprecation-style warning per plugin when a host
    /// callback resolves via the racy `lastDispatchedPluginId` fallback.
    /// Plugin authors should structure their code so host calls happen on
    /// a thread that has TLS set (e.g. inside the original `invoke` /
    /// `handle_route` call frame, or via `DispatchQueue.async` that
    /// captures the host pointer rather than relying on the global).
    private static func warnFallbackOnce(pluginId: String) {
        PluginOnceLogger.warnOnce(
            key: "\(pluginId)|fallback_context",
            "[PluginHostAPI] Plugin '%@' resolved a host context via the global "
                + "lastDispatchedPluginId fallback. This path is racy across plugins; "
                + "perform host API calls on a thread that carries the plugin context "
                + "(e.g. inside invoke / handle_route, or by capturing the host API "
                + "pointer on the dispatching thread). This warning is logged once "
                + "per plugin per process.",
            pluginId
        )
    }

    /// Structured JSON envelope returned by trampolines when no plugin
    /// context can be resolved for the calling thread. Replaces the older
    /// silent `nil` return so plugin developers see the failure in
    /// Insights and can recover programmatically (parse the `error` key).
    static let contextUnavailableJSON: String =
        #"{"error":"context_unavailable","message":"Plugin host API was called from a thread with no resolvable plugin context. This typically indicates the call originated from a background thread the host did not register; reconsider using thread-local context or call from an invokeQueue/eventQueue thread."}"#

    /// Allocates a fresh NUL-terminated C string the plugin owns and
    /// must free via `host->free_string` (v6+) or `libc free()`.
    ///
    /// We deliberately bounce through `withCString` instead of letting
    /// the compiler implicitly bridge `String → UnsafePointer<CChar>!`
    /// for `strdup`. The implicit bridge can route through NSString /
    /// the bridged buffer pool, and there are subtle interactions
    /// with autorelease and concurrent invocation that produced a
    /// `pointer being freed was not allocated` malloc abort in
    /// production when the plugin freed the returned pointer from a
    /// `@convention(c)` callback frame. The explicit pattern below
    /// guarantees:
    ///   1. `cStrPtr` is a stable, valid C-string pointer for the
    ///      duration of the `strdup` call (UTF-8 contiguous).
    ///   2. `strdup` runs against libc directly with no Foundation
    ///      bridging, returning a freshly malloc'd buffer.
    ///   3. The returned pointer is independent of any temporary
    ///      buffer the bridging step might have used, so the plugin
    ///      can free it from any thread / autorelease frame.
    /// `nil` only when `strdup` itself fails (process-wide OOM).
    private static func makeCString(_ str: String) -> UnsafePointer<CChar>? {
        str.withCString { cStrPtr -> UnsafePointer<CChar>? in
            guard let copy = Darwin.strdup(cStrPtr) else { return nil }
            return UnsafePointer(copy)
        }
    }

    /// Resolves the active plugin context for a JSON-returning trampoline
    /// that takes one `request_json` C string argument. Returns NULL when
    /// the plugin passed a NULL pointer (nothing to work on), and the
    /// `context_unavailable` envelope when the host can't find a plugin
    /// context for the current thread. Otherwise calls `body` with the
    /// resolved context and decoded request string.
    private static func withActiveContext(
        requestPtr: UnsafePointer<CChar>?,
        _ body: (_ ctx: PluginHostContext, _ json: String) -> UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>? {
        guard let requestPtr else { return nil }
        guard let ctx = activeContext() else {
            return makeCString(contextUnavailableJSON)
        }
        return body(ctx, String(cString: requestPtr))
    }

    /// Same as `withActiveContext(requestPtr:_:)` but for trampolines that
    /// take no arguments (e.g. `list_models`, `list_active_tasks`).
    private static func withActiveContext(
        _ body: (_ ctx: PluginHostContext) -> UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>? {
        guard let ctx = activeContext() else {
            return makeCString(contextUnavailableJSON)
        }
        return body(ctx)
    }

    // MARK: - Insights Logging Helpers

    private static func logPluginCall(
        pluginId: String,
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        requestBody: String? = nil,
        responseBody: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        InsightsService.logRequest(
            source: .plugin,
            method: method,
            path: path,
            statusCode: statusCode,
            durationMs: durationMs,
            requestBody: requestBody,
            responseBody: responseBody,
            pluginId: pluginId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    private static func measureMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// Extract a top-level string value from JSON without full deserialization.
    private static func extractJSONStringValue(from json: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]*)\""
        guard let range = json.range(of: pattern, options: .regularExpression) else { return nil }
        let match = json[range]
        guard let colonQuote = match.range(of: ":\\s*\"", options: .regularExpression)?.upperBound else { return nil }
        return String(match[colonQuote ..< match.index(before: match.endIndex)])
    }

    /// Maps a top-level `error` code in a host response envelope to the
    /// closest HTTP status for Insights/observability. Returns nil if the
    /// response does not contain a string-typed `error` key — used as the
    /// "is this response an error?" predicate everywhere we record status.
    private static func errorStatusCode(for json: String) -> Int? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = obj["error"] as? String
        else { return nil }
        switch code {
        case "invalid_request", "invalid_task_id":
            return 400
        case "unauthorized", "consent_required":
            return 401
        case "forbidden", "access_denied":
            return 403
        case "not_found":
            return 404
        case "rate_limit_exceeded", "plugin_busy", "task_limit_reached":
            return 429
        case "not_supported":
            return 501
        case "context_unavailable", "max_iterations_reached":
            return 500
        default:
            return 500
        }
    }

    // MARK: HTTP Client Trampoline

    static let trampolineHttpRequest: osr_http_request_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.httpRequest(requestJSON: json) }
            let method = extractJSONStringValue(from: json, key: "method") ?? "GET"
            let url = extractJSONStringValue(from: json, key: "url") ?? "?"
            let statusStr = extractJSONStringValue(from: result, key: "status")
            let statusCode = statusStr.flatMap { Int($0) } ?? (errorStatusCode(for: result) ?? 200)
            logPluginCall(
                pluginId: ctx.pluginId,
                method: method,
                path: "/host-api/http \u{2192} \(url)",
                statusCode: statusCode,
                durationMs: ms,
                requestBody: json,
                responseBody: result
            )
            return makeCString(result)
        }
    }

    // MARK: File Read Trampoline

    static let trampolineFileRead: osr_file_read_t = { requestPtr in
        withActiveContext(requestPtr: requestPtr) { ctx, json in
            var result = ""
            let ms = measureMs { result = ctx.fileRead(requestJSON: json) }
            let path = extractJSONStringValue(from: json, key: "path") ?? "?"
            logPluginCall(
                pluginId: ctx.pluginId,
                method: "GET",
                path: "/host-api/file_read \u{2192} \(path)",
                statusCode: errorStatusCode(for: result) ?? 200,
                durationMs: ms,
                requestBody: json,
                responseBody: nil
            )
            return makeCString(result)
        }
    }
}

#endif
