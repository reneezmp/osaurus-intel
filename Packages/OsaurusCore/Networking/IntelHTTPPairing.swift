//
//  IntelHTTPPairing.swift
//  osaurus
//
//  Mobile pairing routes (`W-identity-mobile` stage 1,
//  docs/IDENTITY_MOBILE_INTEL.md; upstream MOBILE_PROTOCOL §11):
//
//  - `GET /pair/hello` — "is there an Osaurus here?" for a phone whose
//    Bonjour is blocked. Public, LAN only.
//  - `POST /pair/code` — v2 (SPAKE2) step one, or a v1 redeem (code plus an
//    HPKE key). Public, LAN only, rate-limited per IP.
//  - `POST /pair/confirm` — v2 step two: the phone's confirmation, answered
//    with the payload sealed under the session key.
//  - `POST /pair/unpair` — the paired phone unpairs itself (its own key
//    only). An owner-channel route: a remote phone needs the Secure Channel
//    (stage 2).
//
//  Upstream's handlers and replies; the code, device id and sealed key are
//  never logged.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routePairingRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        switch (head.method, path) {
        case (.GET, "/pair/hello"): servePairHello(context: context)
        case (.POST, "/pair/code"), (.POST, "/pair/confirm"): servePairCode(context: context, head: head, path: path)
        case (.POST, "/pair/unpair"): servePairUnpair(context: context, head: head)
        default: return false
        }
        return true
    }

    /// Answers and logs a pairing reply without the request body.
    private func sendPairingReply(
        context: ChannelHandlerContext, head: HTTPRequestHead, path: String, status: HTTPResponseStatus,
        body: String, logBody: String? = nil
    ) {
        stateRef.value.routeLogsItself = true
        sendResponse(context: context, status: status, headers: jsonHeaders(), body: body)
        logRequest(
            method: head.method.rawValue, path: path, userAgent: head.headers.first(name: "User-Agent"),
            requestBody: "<redacted>", responseBody: logBody ?? body, responseStatus: Int(status.code),
            startTime: stateRef.value.requestStartedAt ?? Date())
    }

    // MARK: - GET /pair/hello

    private func servePairHello(context: ChannelHandlerContext) {
        MobileConnectLog.write("pair/hello: probed from \(remoteIP(context))")
        guard !stateRef.value.isRelayOrigin else {
            sendResponse(context: context, status: .forbidden, headers: jsonHeaders(), body: #"{"error":"lan_only"}"#)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let (name, pairing, version) = await MainActor.run {
                (
                    Host.current().localizedName ?? "Osaurus",
                    MobilePairingService.shared.activeCode != nil,
                    MobilePairingService.wireVersion
                )
            }
            let body =
                (try? JSONSerialization.data(withJSONObject: ["v": version, "name": name, "pairing": pairing]))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"v":1}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
        }
    }

    // MARK: - POST /pair/code, /pair/confirm

    private func servePairCode(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard !stateRef.value.isRelayOrigin else {
            MobileConnectLog.write("pair/code: refused a relay-origin request (LAN only)")
            sendPairingReply(
                context: context, head: head, path: path, status: .forbidden,
                body: #"{"error":"lan_only","message":"Pair on the same network as this Mac."}"#)
            return
        }
        let pairingIP = remoteIP(context)
        MobileConnectLog.write("pair/code: request from \(pairingIP)")
        guard PairingRateLimiter.shared.allow(ip: pairingIP) else {
            sendPairingReply(
                context: context, head: head, path: path, status: .tooManyRequests,
                body: #"{"error":"Too many pairing attempts. Try again shortly."}"#)
            return
        }

        let data = requestBodyData()
        // v1 sends the code and a key to seal to; v2 (SPAKE2) never sends
        // the code, and confirms in a second step on `/pair/confirm`.
        struct Version: Decodable { let v: Int }
        let decoder = JSONDecoder()
        let redeem: @MainActor @Sendable () -> MobilePairingService.RedeemOutcome
        if path == "/pair/confirm", let request = try? decoder.decode(MobilePairConfirmRequest.self, from: data) {
            redeem = { MobilePairingService.shared.confirmExchange(request) }
        } else if path == "/pair/code", (try? decoder.decode(Version.self, from: data))?.v == PairingSPAKE2.version,
            let request = try? decoder.decode(MobilePairStartRequest.self, from: data)
        {
            redeem = { MobilePairingService.shared.startExchange(request) }
        } else if path == "/pair/code", let request = try? decoder.decode(MobilePairRequest.self, from: data) {
            redeem = { MobilePairingService.shared.redeem(request) }
        } else {
            sendPairingReply(
                context: context, head: head, path: path, status: .badRequest,
                body: #"{"error":"bad_request","message":"Invalid pairing request"}"#)
            return
        }

        stateRef.value.routeLogsItself = true
        let eventLoop = context.eventLoop
        let userAgent = head.headers.first(name: "User-Agent")
        let startTime = stateRef.value.requestStartedAt ?? Date()
        runRequestTask {
            let outcome = await MainActor.run { redeem() }
            let status: HTTPResponseStatus
            let body: String
            var logBody: String?
            switch outcome {
            case .paired(let response, _):
                MobileConnectLog.write("pair/code: paired a phone from \(pairingIP)")
                status = .ok
                body =
                    (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                    ?? #"{"error":"encoding_failed"}"#
                logBody = #"{"v":1,"sealed":"<redacted>"}"#
            case .answered(let answer, let redacted):
                MobileConnectLog.write("\(path): answered a v2 pairing step from \(pairingIP)")
                status = .ok
                body = answer
                logBody = redacted
            case .invalidCode:
                MobileConnectLog.write("pair/code: wrong or expired code from \(pairingIP)")
                PairingRateLimiter.shared.penalize(ip: pairingIP)
                status = .unauthorized
                body = #"{"error":"invalid_code","message":"That code is wrong or has expired."}"#
            case .badRequest(let message):
                MobileConnectLog.write("pair/code: bad request from \(pairingIP): \(message)")
                status = .badRequest
                body =
                    (try? JSONEncoder().encode(["error": "bad_request", "message": message]))
                    .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"bad_request"}"#
            }
            self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: body)
            self.logRequest(
                method: "POST", path: path, userAgent: userAgent, requestBody: "<redacted>",
                responseBody: logBody ?? body, responseStatus: Int(status.code), startTime: startTime)
        }
    }

    // MARK: - POST /pair/unpair

    /// The paired phone unpairs itself: only the key minted for the current
    /// paired device is accepted (upstream).
    private func servePairUnpair(context: ChannelHandlerContext, head: HTTPRequestHead) {
        if requiresOwnerChannel(head: head, context: context) { return }
        let keyNonce = inboundConnectionInfo()?.accessKeyId
        let eventLoop = context.eventLoop
        runRequestTask {
            let unpaired: Bool
            if let keyNonce {
                unpaired = await MainActor.run { MobilePairingService.shared.unpairIfCaller(keyNonce: keyNonce) }
            } else {
                unpaired = false
            }
            self.respondOnLoop(
                eventLoop, status: unpaired ? .ok : .forbidden, headers: self.jsonHeaders(),
                body: unpaired
                    ? #"{"ok":true}"#
                    : #"{"error":"not_paired_device","message":"Only the paired phone can unpair itself."}"#)
        }
    }
}
