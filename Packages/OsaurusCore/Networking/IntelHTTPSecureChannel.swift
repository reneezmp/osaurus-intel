//
//  IntelHTTPSecureChannel.swift
//  osaurus
//
//  Secure Channel (`W-identity-mobile` stage 2, docs/IDENTITY_MOBILE_INTEL.md;
//  upstream MOBILE_PROTOCOL §6.2):
//
//  - `POST /secure/session`: the handshake. Public (it grants nothing: every
//    inner request still needs its own Bearer) and rate-limited. The
//    transcript is signed with the key of the agent the phone pinned, or
//    with the Mac's connect identity, so the phone knows it reached the
//    address it paired with.
//  - `POST /secure/call`: an encrypted envelope. `channelRead` decrypts it
//    (`decryptSecureCall`) and swaps in the inner request before the access
//    gate; `SecureChannelResponseEncryptor` seals whatever the route writes.
//
//  Upstream's handlers, on Intel's route-extension pattern. Signs along the
//  agent's own key path (v1 or device-scoped v2, stage 7).
//

import Foundation
import LocalAuthentication
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// Handshakes get their own budget (upstream): a phone opens one per
    /// agent and route and again every hour, which must neither lock out its
    /// own pairing nor be locked out by someone spamming pairing codes.
    static let secureSessionRateLimiter = PairingRateLimiter(window: 60, maxPerWindow: 30, denialCooldown: 10)

    static func isSecureChannelPath(_ path: String) -> Bool {
        path == "/secure" || path.hasPrefix("/secure/")
    }

    func routeSecureChannelRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard head.method == .POST, path == "/secure/session" else { return false }
        serveSecureSession(context: context, head: head)
        return true
    }

    // MARK: - POST /secure/session

    private func serveSecureSession(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/secure/session"
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        stateRef.value.routeLogsItself = true
        let eventLoop = context.eventLoop

        @Sendable func reply(status: HTTPResponseStatus, body: String) {
            respondOnLoop(eventLoop, status: status, headers: jsonHeaders(), body: body)
            logRequest(
                method: "POST", path: path, userAgent: userAgent, requestBody: nil,
                responseBody: status == .ok ? "<server-hello>" : body, responseStatus: Int(status.code),
                startTime: startTime)
        }

        guard Self.secureSessionRateLimiter.allow(ip: remoteIP(context)) else {
            reply(status: .tooManyRequests, body: #"{"error":"Too many pairing attempts. Try again shortly."}"#)
            return
        }
        guard let hello = try? JSONDecoder().decode(SecureChannel.ClientHello.self, from: requestBodyData()) else {
            reply(status: .badRequest, body: #"{"error":"Invalid handshake request"}"#)
            return
        }
        guard hello.v == SecureChannel.version else {
            reply(status: .badRequest, body: #"{"error":"Unsupported secure channel version"}"#)
            return
        }

        runRequestTask {
            // Any agent with a derived identity can hold sessions; access
            // control happens on the inner request's Bearer, not here. The
            // Mac's connect identity also answers, so a phone paired to a Mac
            // with only the built-in agent still has a channel.
            let wanted = hello.agentAddress.lowercased()
            let agents = await MainActor.run { AgentManager.shared.agents }
            let agentKeyPath = agents.first(where: { $0.agentAddress?.lowercased() == wanted })?.agentKeyPath
            if agentKeyPath == nil {
                switch MobileConnectIdentity.matches(wanted) {
                case true?:
                    break
                case false?:
                    reply(status: .notFound, body: #"{"error":"Unknown agent address"}"#)
                    return
                case nil:
                    // The Keychain can't be read now: worth a retry, and not
                    // the 404 that makes a phone drop its pin.
                    reply(
                        status: .serviceUnavailable,
                        body: #"{"error":"Secure channel identity unavailable, try again"}"#)
                    return
                }
            }

            let result: (session: SecureChannelSession, serverHello: SecureChannel.ServerHello)
            do {
                result = try SecureChannel.establishServerSession(hello: hello) { transcript in
                    guard let agentKeyPath else {
                        let signature = try MobileConnectIdentity.withPrivateKey {
                            try signSecureChannelPayload(transcript, privateKey: $0)
                        }
                        guard let signature else { throw OsaurusIdentityError.keychainReadFailed }
                        return signature
                    }
                    let signContext = LAContext()
                    signContext.touchIDAuthenticationAllowableReuseDuration = 300
                    signContext.interactionNotAllowed = true
                    var masterKeyData = try MasterKey.getPrivateKey(context: signContext)
                    defer { masterKeyData.zeroOut() }
                    var childKey = AgentKey.derive(masterKey: masterKeyData, path: agentKeyPath)
                    defer { childKey.zeroOut() }
                    return try signSecureChannelPayload(transcript, privateKey: childKey)
                }
            } catch SecureChannelError.malformedHandshake {
                reply(status: .badRequest, body: #"{"error":"Malformed handshake"}"#)
                return
            } catch {
                reply(status: .internalServerError, body: #"{"error":"Failed to establish secure session"}"#)
                return
            }

            SecureSessionStore.shared.register(result.session)
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(result.serverHello))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"Encoding failed"}"#
            reply(status: .ok, body: json)
        }
    }

    // MARK: - POST /secure/call (decrypt)

    /// Decrypt a `POST /secure/call` envelope and rewrite it into its inner
    /// request (upstream). Returns the inner head, or `nil` after answering
    /// with an error. Runs on the event loop: the session lookup and the
    /// AEAD open are lock-guarded and cheap.
    func decryptSecureCall(head: HTTPRequestHead, context: ChannelHandlerContext) -> HTTPRequestHead? {
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        func reject(status: HTTPResponseStatus, code: String, message: String) {
            let body = #"{"error":{"code":"\#(code)","message":"\#(message)","type":"secure_channel_error"}}"#
            stateRef.value.routeLogsItself = true
            // `sendResponse` adds the request's CORS headers itself.
            sendResponse(context: context, status: status, headers: jsonHeaders(), body: body)
            logRequest(
                method: "POST", path: "/secure/call", userAgent: userAgent, requestBody: nil,
                responseBody: body, responseStatus: Int(status.code), startTime: startTime)
        }

        guard let encryptor = responseEncryptor else {
            reject(
                status: .internalServerError, code: "secure_channel_unavailable",
                message: "Secure channel is not available on this server")
            return nil
        }
        guard let call = try? JSONDecoder().decode(SecureChannel.CallRequest.self, from: requestBodyData()) else {
            reject(status: .badRequest, code: "secure_malformed", message: "Malformed secure call")
            return nil
        }
        guard let session = SecureSessionStore.shared.session(for: call.sid) else {
            // Distinct code so clients know to re-handshake rather than retry.
            reject(status: .unauthorized, code: "secure_session_unknown", message: "Unknown or expired secure session")
            return nil
        }
        stateRef.value.secureChannelAgentAddress = session.agentAddress

        let plaintext: Data
        let requestSeq: UInt64
        do {
            (plaintext, requestSeq) = try session.openCall(call)
        } catch SecureChannelError.replayedFrame {
            reject(status: .conflict, code: "secure_replay", message: "Replayed secure call rejected")
            return nil
        } catch SecureChannelError.sessionExpired {
            reject(status: .unauthorized, code: "secure_session_unknown", message: "Unknown or expired secure session")
            return nil
        } catch {
            reject(status: .badRequest, code: "secure_decrypt_failed", message: "Decryption failed")
            return nil
        }

        guard let inner = try? JSONDecoder().decode(SecureChannel.InnerRequest.self, from: plaintext),
            inner.path.hasPrefix("/"),
            // On the path as routed: `/v1/secure/call` normalises to
            // `/secure/call`, so checking the raw path alone lets one nest.
            !Self.isSecureChannelPath(normalize(extractPath(from: inner.path)))
        else {
            reject(status: .badRequest, code: "secure_malformed", message: "Malformed inner request")
            return nil
        }

        let innerBody = inner.body.flatMap { Data(base64urlEncoded: $0) } ?? Data()
        var newHead = HTTPRequestHead(version: head.version, method: HTTPMethod(rawValue: inner.method), uri: inner.path)
        var headers = HTTPHeaders()
        // Extra inner headers first, so the controlled transport and security
        // headers below always win. The relay-origin marker, Host and
        // Content-Length are never inner-controllable: an encrypted caller
        // must not suppress the relay marker (loopback-trust escalation) or
        // desync body framing.
        let reservedNames: Set<String> = [
            "host", "content-length", "connection", "authorization", "accept", "content-type",
            HTTPHandler.relayOriginHeaderName.lowercased(),
        ]
        for (name, value) in inner.headers ?? [:] where !reservedNames.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }
        if let host = head.headers.first(name: "Host") {
            headers.add(name: "Host", value: host)
        }
        // Keep the relay-origin marker so later header reads agree with
        // `isRelayOrigin` (set at `.head`).
        if head.headers.first(name: HTTPHandler.relayOriginHeaderName) != nil {
            headers.add(name: HTTPHandler.relayOriginHeaderName, value: "1")
        }
        if let userAgent, headers.first(name: "User-Agent") == nil {
            headers.add(name: "User-Agent", value: userAgent)
        }
        if let authorization = inner.authorization {
            headers.add(name: "Authorization", value: authorization)
        }
        if let accept = inner.accept { headers.add(name: "Accept", value: accept) }
        if let contentType = inner.contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        headers.add(name: "Content-Length", value: String(innerBody.count))
        newHead.headers = headers

        var bodyBuffer = context.channel.allocator.buffer(capacity: innerBody.count)
        bodyBuffer.writeBytes(innerBody)
        stateRef.value.requestBodyBuffer = bodyBuffer
        stateRef.value.normalizedPath = normalize(extractPath(from: inner.path))

        // From here on, everything the route writes is sealed for this call.
        encryptor.arm(sealer: session.makeResponseSealer(requestSeq: requestSeq))
        return newHead
    }
}
