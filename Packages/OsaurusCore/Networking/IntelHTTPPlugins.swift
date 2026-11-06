//
//  IntelHTTPPlugins.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2f (docs/UPSTREAM_SYNC.md, "Plugin routes,
//  web apps and the tunnel"): upstream's plugin route handler
//  (`HTTPHandler.handlePluginRoute` and its helpers, `bce907045`), so
//  `/plugins/<id>/<subpath>` reaches a loaded plugin's `handle_route` or
//  its static web app. Intel differences, marked inline:
//  - the request task is Intel's `runRequestTask` (no per-connection task
//    registry, so a disconnect doesn't cancel plugin work);
//  - a synchronous error goes through Intel's `sendResponse`, which adds
//    the CORS headers itself;
//  - `executeOnLoop` checks Intel's stored channel context instead of
//    upstream's `_isChannelActive`.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// Routes `/plugins/…` (upstream dispatches it from `channelRead`).
    func routePluginRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard path.hasPrefix("/plugins/") else { return false }
        // Upstream logs every plugin response itself.
        stateRef.value.routeLogsItself = true
        handlePluginRoute(
            head: head,
            context: context,
            startTime: stateRef.value.requestStartedAt ?? Date(),
            userAgent: head.headers.first(name: "User-Agent"),
            isLoopback: isLoopbackConnection(context)
        )
        return true
    }

    /// Upstream's `executeOnLoop`, gated on Intel's channel context.
    private func executeOnLoop(_ loop: EventLoop, _ block: @escaping @Sendable () -> Void) {
        let stateRef = self.stateRef
        let run: @Sendable () -> Void = {
            guard stateRef.value.contextBox != nil else { return }
            block()
        }
        if loop.inEventLoop { run() } else { loop.execute { run() } }
    }

    // MARK: - Plugin Route Handler

    func handlePluginRoute(
        head: HTTPRequestHead,
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        isLoopback: Bool
    ) {
        let path = stateRef.value.normalizedPath
        let method = head.method.rawValue
        let corsHeaders = stateRef.value.corsHeaders

        // Parse: /plugins/<pluginId>/<subpath>
        let segments = path.dropFirst("/plugins/".count)
        guard let slashIdx = segments.firstIndex(of: "/") else {
            sendPluginError(
                context: context,
                head: head,
                status: .notFound,
                message: "Invalid plugin route",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }
        let pluginId = String(segments[..<slashIdx])
        let subpath = String(segments[slashIdx...])

        // Reject path traversal
        if pluginId.contains("..") || subpath.contains("..") {
            sendPluginError(
                context: context,
                head: head,
                status: .badRequest,
                message: "Invalid path",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        let loop = context.eventLoop
        let ctxBound = NIOLoopBound(context, eventLoop: loop)
        let bodyBuffer = stateRef.value.requestBodyBuffer
        let uri = head.uri
        let headersDict = Dictionary(
            head.headers.map { ($0.name.lowercased(), $0.value) },
            uniquingKeysWith: { $1 }
        )
        let version = head.version

        // All plugin route access requires an agent context.
        // Accept either the `X-Osaurus-Agent-Id` header (preferred for SDK
        // and tunnel callers) or the `osr_agent` query parameter (for
        // browser-launched web UIs that cannot set custom headers on the
        // top-level navigation). The injected `window.__osaurus` script
        // then carries the same id forward to the page's fetch calls.
        let queryAgent: String? = {
            guard let q = head.uri.split(separator: "?").dropFirst().first else { return nil }
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "osr_agent" {
                    return kv[1].removingPercentEncoding ?? kv[1]
                }
            }
            return nil
        }()
        let agentIdStr = headersDict["x-osaurus-agent-id"] ?? queryAgent
        guard let agentIdStr, let agentUUID = UUID(uuidString: agentIdStr) else {
            sendPluginError(
                context: context,
                head: head,
                status: .unauthorized,
                message:
                    "Plugin routes require an agent context (X-Osaurus-Agent-Id header or osr_agent query parameter)",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        // Narrow MainActor scope: only the few lookups that need it run on
        // MainActor. Route matching, auth, JSON encoding, plugin invocation,
        // and response handling all run off MainActor to avoid serializing
        // concurrent requests through the main thread.
        // Tie the plugin handler task to the channel lifecycle so a client
        // disconnect / idle-timeout cancels in-flight plugin work instead of
        // leaving it running (and the registry entry pinned) for a dead
        // connection. Mirrors `runRequestTask`.
        // Intel: `runRequestTask` (caller context bound); Intel has no
        // per-connection task registry, so a client disconnect doesn't
        // cancel the plugin work (upstream ties it to `channelCloseFuture`).
        runRequestTask {
            let loaded = await MainActor.run {
                PluginManager.shared.loadedPlugin(for: pluginId)
            }
            guard let loaded else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "Plugin not found: \(pluginId)",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            let manifest = loaded.plugin.manifest

            // Check for static web serving first. Segment-boundary matching
            // via the shared helper: mount `/ui` must NOT capture `/ui-other`
            // (a bare `hasPrefix` did, disagreeing with the load-time
            // web/route overlap validation in PluginManager).
            if let webSpec = loaded.webConfig {
                if PluginManifest.WebSpec.mountCaptures(subpath: subpath, mount: webSpec.mount) {
                    // Tunnel exposure gate: web UIs are loopback-only by
                    // default. Plugins must opt in via `capabilities.web.tunnel_exposed`
                    // for the static UI to be reachable over the tunnel.
                    // We return 404 (not 403) so the existence of the
                    // route is not advertised to outside callers.
                    if !isLoopback && !webSpec.isTunnelExposed {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .notFound,
                            message: "No matching route",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }
                    if webSpec.auth == .owner && !self.isValidOwnerAuth(headers: headersDict) {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .unauthorized,
                            message: "Authentication required",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    // Check for dev proxy configuration
                    if let proxyURL = Self.loadDevProxyURL(for: pluginId) {
                        let relPath = PluginManifest.WebSpec.relativeSubpath(
                            subpath: subpath,
                            mount: webSpec.mount
                        )
                        let targetPath = relPath.isEmpty ? "/" : relPath
                        // Forward the original method/headers/body so HMR,
                        // POST APIs, and any non-GET dev-server traffic
                        // works during plugin development.
                        let proxyBody: Data? = {
                            guard let buf = bodyBuffer, buf.readableBytes > 0 else { return nil }
                            return Data(buffer: buf)
                        }()
                        return await self.proxyToDevServer(
                            proxyBaseURL: proxyURL,
                            targetPath: targetPath,
                            pluginId: pluginId,
                            apiMount: webSpec.api_mount ?? "/api",
                            agentId: agentIdStr,
                            requestMethod: method,
                            requestHeaders: headersDict,
                            requestBody: proxyBody,
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    let relPath = PluginManifest.WebSpec.relativeSubpath(
                        subpath: subpath,
                        mount: webSpec.mount
                    )
                    let filePath: String
                    if relPath.isEmpty || relPath == "/" {
                        filePath = webSpec.entry
                    } else {
                        filePath = relPath.hasPrefix("/") ? String(relPath.dropFirst()) : relPath
                    }

                    let versionDir = URL(fileURLWithPath: loaded.plugin.bundlePath).deletingLastPathComponent()
                    let webDir = versionDir.appendingPathComponent(webSpec.static_dir, isDirectory: true)
                    let fileURL = webDir.appendingPathComponent(filePath)

                    guard
                        let resolvedFileURL = Self.containedPluginStaticFileURL(
                            for: fileURL,
                            webDirectory: webDir
                        )
                    else {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .forbidden,
                            message: "Access denied",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    let apiMount = webSpec.api_mount ?? "/api"
                    if FileManager.default.fileExists(atPath: resolvedFileURL.path) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: resolvedFileURL.path,
                            pluginId: pluginId,
                            apiMount: apiMount,
                            agentId: agentIdStr,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    // SPA fallback: serve entry point for non-file paths
                    let entryURL = webDir.appendingPathComponent(webSpec.entry)
                    guard
                        let resolvedEntryURL = Self.containedPluginStaticFileURL(
                            for: entryURL,
                            webDirectory: webDir
                        )
                    else {
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .forbidden,
                            message: "Access denied",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }
                    if FileManager.default.fileExists(atPath: resolvedEntryURL.path) {
                        return self.serveStaticFile(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            filePath: resolvedEntryURL.path,
                            pluginId: pluginId,
                            apiMount: apiMount,
                            agentId: agentIdStr,
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }

                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .notFound,
                        message: "File not found",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            }

            // Dynamic route matching with path-parameter extraction.
            guard let routeMatch = manifest.matchRouteWithParams(method: method, subpath: subpath) else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "No matching route",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
            let route = routeMatch.route

            // Tunnel exposure gate: dynamic routes are loopback-only by
            // default. Plugins must opt in via `tunnel_exposed: true` on
            // the route spec for it to be reachable over the tunnel.
            // We return 404 (not 403) so route existence isn't leaked.
            if !isLoopback && !route.isTunnelExposed {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notFound,
                    message: "No matching route",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            switch route.auth {
            case .owner:
                if !self.isValidOwnerAuth(headers: headersDict) {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .unauthorized,
                        message: "Authentication required",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            case .none, .verify:
                if !PluginRateLimiter.shared.allow(pluginId: pluginId) {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .tooManyRequests,
                        message: "Rate limit exceeded",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }
            }

            guard loaded.plugin.hasRouteHandler else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .notImplemented,
                    message: "Plugin does not support route handling",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            let queryParams = OsaurusHTTPRequest.parseQueryParams(from: uri)

            var bodyString = ""
            var bodyEncoding = "utf8"
            if let buf = bodyBuffer, buf.readableBytes > 0 {
                var readBuf = buf
                if let str = readBuf.readString(length: readBuf.readableBytes) {
                    bodyString = str
                } else {
                    let data = Data(buffer: buf)
                    bodyString = data.base64EncodedString()
                    bodyEncoding = "base64"
                }
            }

            let serverPort = self.configuration.port
            let localBaseURL = "http://127.0.0.1:\(serverPort)"

            // Second (and last) MainActor hop: resolve tunnel URL and agent address
            let (agentAddress, tunnelURL) = await MainActor.run {
                let address = AgentManager.shared.agent(for: agentUUID)?.agentAddress ?? ""
                let tunnel = Self.resolveTunnelBaseURL(for: agentUUID)
                return (address, tunnel)
            }

            let baseURL = tunnelURL ?? localBaseURL
            let pluginURL = "\(baseURL)/plugins/\(pluginId)"

            let request = OsaurusHTTPRequest(
                route_id: route.id,
                method: method,
                path: subpath,
                query: queryParams,
                path_params: routeMatch.pathParams,
                headers: headersDict,
                body: bodyString,
                body_encoding: bodyEncoding,
                remote_addr: "",
                plugin_id: pluginId,
                osaurus: .init(
                    base_url: baseURL,
                    plugin_url: pluginURL,
                    agent_address: agentAddress
                )
            )

            let encoder = JSONEncoder.osaurusCanonical()
            guard let requestData = try? encoder.encode(request),
                let requestJSON = String(data: requestData, encoding: .utf8)
            else {
                return self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .internalServerError,
                    message: "Failed to encode request",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }

            do {
                let responseJSON = try await loaded.plugin.handleRoute(requestJSON: requestJSON, agentId: agentUUID)

                guard let responseData = responseJSON.data(using: .utf8),
                    let response = try? JSONDecoder().decode(OsaurusHTTPResponse.self, from: responseData)
                else {
                    return self.sendPluginErrorFromTask(
                        loop: loop,
                        ctxBound: ctxBound,
                        version: version,
                        status: .internalServerError,
                        message: "Invalid plugin response",
                        corsHeaders: corsHeaders,
                        startTime: startTime,
                        method: method,
                        path: path,
                        userAgent: userAgent
                    )
                }

                let httpStatus = HTTPResponseStatus(statusCode: response.status)
                var responseHeaders: [(String, String)] = corsHeaders
                if let hdrs = response.headers {
                    for (k, v) in hdrs {
                        responseHeaders.append((k, v))
                    }
                }

                var responseBody = ""
                if let body = response.body {
                    if response.body_encoding == "base64" {
                        if let decoded = Data(base64Encoded: body) {
                            self.sendBinaryPluginResponse(
                                loop: loop,
                                ctxBound: ctxBound,
                                version: version,
                                status: httpStatus,
                                headers: responseHeaders,
                                body: decoded,
                                startTime: startTime,
                                method: method,
                                path: path,
                                userAgent: userAgent
                            )
                            return
                        }
                        // Plugin claimed base64 but the body did not decode.
                        // Surface the corruption rather than silently sending
                        // the raw string; binary clients would otherwise get
                        // garbage they cannot detect.
                        return self.sendPluginErrorFromTask(
                            loop: loop,
                            ctxBound: ctxBound,
                            version: version,
                            status: .badGateway,
                            message:
                                "Plugin response declared body_encoding=base64 but the body is not valid base64.",
                            corsHeaders: corsHeaders,
                            startTime: startTime,
                            method: method,
                            path: path,
                            userAgent: userAgent
                        )
                    }
                    responseBody = body
                }

                self.sendPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: httpStatus,
                    headers: responseHeaders,
                    body: responseBody,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            } catch {
                self.sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .internalServerError,
                    message: "Plugin error: \(error.localizedDescription)",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
        }
    }

    private func sendPluginError(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        // Intel's `sendResponse` adds the request's CORS headers itself.
        _ = corsHeaders
        let headers = [("Content-Type", "application/json; charset=utf-8")]
        let body = #"{"error":{"message":"\#(message)"}}"#
        sendResponse(context: context, status: status, headers: headers, body: body)
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    /// Core NIO response writer for plugin routes. All plugin response helpers funnel through this.
    private func writePluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        bodyWriter: @Sendable @escaping (ChannelHandlerContext) -> ByteBuffer
    ) {
        executeOnLoop(loop) {
            let context = ctxBound.value
            var responseHead = HTTPResponseHead(version: version, status: status)
            var nioHeaders = HTTPHeaders()
            for (name, value) in headers { nioHeaders.add(name: name, value: value) }
            let buffer = bodyWriter(context)
            nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
            nioHeaders.add(name: "Connection", value: "close")
            responseHead.headers = nioHeaders
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                ctxBound.value.close(promise: nil)
            }
        }
    }

    private func sendPluginErrorFromTask(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")] + corsHeaders
        let body = #"{"error":{"message":"\#(message)"}}"#
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func sendPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: body,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func sendBinaryPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: Data,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(loop: loop, ctxBound: ctxBound, version: version, status: status, headers: headers) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            return buffer
        }
        logRequest(
            method: method,
            path: path,
            userAgent: userAgent,
            requestBody: nil,
            responseBody: nil,
            responseStatus: Int(status.code),
            startTime: startTime
        )
    }

    private func serveStaticFile(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        filePath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .notFound,
                message: "File not found",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        let ext = (filePath as NSString).pathExtension
        let mimeType = MIMEType.forExtension(ext)
        var headers: [(String, String)] = corsHeaders
        headers.append(("Content-Type", mimeType))
        headers.append(("Cache-Control", "public, max-age=3600"))

        if ext == "html" || ext == "htm", var html = String(data: fileData, encoding: .utf8) {
            Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
            sendPluginResponse(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .ok,
                headers: headers,
                body: html,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        } else {
            sendBinaryPluginResponse(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .ok,
                headers: headers,
                body: fileData,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        }
    }

    /// Resolves symlinks before plugin static serving so path checks use the real filesystem boundary.
    static func containedPluginStaticFileURL(for candidateURL: URL, webDirectory: URL) -> URL? {
        let baseURL = webDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        let basePath = baseURL.path
        let resolvedPath = resolvedURL.path

        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            return nil
        }
        return resolvedURL
    }

    /// Validates a Bearer token from the Authorization header.
    /// Returns true if the token is a valid `osk-v1` access key.
    private func isValidOwnerAuth(headers: [String: String]) -> Bool {
        let authHeader = headers["authorization"] ?? ""
        let token = authHeader.hasPrefix("Bearer ") ? String(authHeader.dropFirst(7)) : ""
        if case .valid = apiKeyValidator.validate(rawKey: token) { return true }
        return false
    }

    /// Injects the `window.__osaurus` context object into an HTML string before `</head>`.
    /// Injects a small context object into the plugin's web HTML. Plugins
    /// can opt in to a custom API mount via `capabilities.web.api_mount`
    /// (e.g. `"/v2"`); the default `/api` is preserved when unset.
    /// `agentId` is propagated to the page so the plugin's `fetch()` calls
    /// can attach it as the `X-Osaurus-Agent-Id` header without re-entering
    /// the URL bar.
    private static func injectOsaurusContext(
        into html: inout String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil
    ) {
        let normalizedApiMount: String = {
            let trimmed = apiMount.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "/api" }
            return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        }()
        let agentField = agentId.map { #"agentId: "\#($0)","# } ?? ""
        let script = """
            <script>
            window.__osaurus = {
              pluginId: "\(pluginId)",
              baseUrl: "/plugins/\(pluginId)",
              apiUrl: "/plugins/\(pluginId)\(normalizedApiMount)",
              \(agentField)
              // Helper that wraps fetch with the X-Osaurus-Agent-Id header
              // so the page never accidentally drops the agent context.
              fetch: function(input, init) {
                init = init || {};
                init.headers = new Headers(init.headers || {});
                if (window.__osaurus.agentId && !init.headers.has("X-Osaurus-Agent-Id")) {
                  init.headers.set("X-Osaurus-Agent-Id", window.__osaurus.agentId);
                }
                return fetch(input, init);
              }
            };
            </script>
            """
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: "\n\(script)\n", at: headEnd.lowerBound)
        }
    }

    /// Loads the dev proxy URL for a plugin from the dev-proxy.json config file.
    private static func loadDevProxyURL(for pluginId: String) -> String? {
        let configFile = OsaurusPaths.config().appendingPathComponent("dev-proxy.json")
        guard let data = try? Data(contentsOf: configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let configPluginId = obj["plugin_id"] as? String,
            configPluginId == pluginId,
            let proxyURL = obj["web_proxy"] as? String
        else { return nil }
        return proxyURL
    }

    /// Proxies a web request to a local dev server for HMR support.
    private func proxyToDevServer(
        proxyBaseURL: String,
        targetPath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        requestMethod: String,
        requestHeaders: [String: String],
        requestBody: Data?,
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) async {
        let targetURL = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + targetPath
        guard let url = URL(string: targetURL) else {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .badGateway,
                message: "Invalid proxy URL",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = requestMethod
        request.timeoutInterval = 10
        // Forward the request body for non-GET methods so things like Vite
        // HMR pings, plugin POST APIs, and form submissions work.
        if let body = requestBody, !body.isEmpty {
            request.httpBody = body
        }
        // Forward most headers verbatim. Drop hop-by-hop and host-management
        // headers that URLSession should set for us, and the agent header
        // (which is host-internal context, not relevant to the dev server).
        let stripped: Set<String> = [
            "host", "content-length", "connection", "transfer-encoding",
            "x-osaurus-agent-id", "authorization",
        ]
        for (k, v) in requestHeaders where !stripped.contains(k.lowercased()) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                sendPluginErrorFromTask(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: .badGateway,
                    message: "Invalid response from dev server",
                    corsHeaders: corsHeaders,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var headers: [(String, String)] = corsHeaders
            headers.append(("Content-Type", contentType))
            headers.append(("Access-Control-Allow-Origin", "*"))

            if contentType.contains("text/html"), var html = String(data: data, encoding: .utf8) {
                Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
                sendPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers,
                    body: html,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            } else {
                sendBinaryPluginResponse(
                    loop: loop,
                    ctxBound: ctxBound,
                    version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers,
                    body: data,
                    startTime: startTime,
                    method: method,
                    path: path,
                    userAgent: userAgent
                )
            }
        } catch {
            sendPluginErrorFromTask(
                loop: loop,
                ctxBound: ctxBound,
                version: version,
                status: .badGateway,
                message: "Dev server unreachable: \(error.localizedDescription)",
                corsHeaders: corsHeaders,
                startTime: startTime,
                method: method,
                path: path,
                userAgent: userAgent
            )
        }
    }

    /// Resolves the tunnel base URL for a specific agent from RelayTunnelManager.
    @MainActor
    private static func resolveTunnelBaseURL(for agentId: UUID) -> String? {
        if case .connected(let url) = RelayTunnelManager.shared.agentStatuses[agentId] {
            return url
        }
        return nil
    }
}
