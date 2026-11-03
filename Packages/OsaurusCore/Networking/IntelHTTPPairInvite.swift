//
//  IntelHTTPPairInvite.swift
//  osaurus
//
//  `POST /pair-invite` (`W-identity-mobile` stage 5,
//  docs/IDENTITY_MOBILE_INTEL.md; upstream MOBILE_PROTOCOL §5). Public,
//  reachable through the relay, rate-limited per source like the other
//  pairing routes, and logged with its credentials redacted.
//
//  Upstream serves three handshakes here. Intel serves the owner's one:
//  - `{"owner_redeem": …}` — a device holding this Mac's own master
//    identity (an iPhone or Mac set up from the recovery phrase) gets an
//    agent-scoped key without a pairing code (`OwnerDeviceAccessHost`).
//  - `{"team_redeem": …}` (workspaces) and a signed agent invite
//    (`osaurus://…?pair=`, Mac-to-Mac sharing) belong to
//    `W-workspaces-sharing`, deferred until someone asks (Renée,
//    2026-11-03). They answer `501` saying so.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routePairInviteRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard head.method == .POST, path == "/pair-invite" else { return false }
        servePairInvite(context: context, head: head)
        return true
    }

    // MARK: - Request log redaction (upstream)

    /// Keys in a `/pair-invite` request body whose values are credentials or
    /// credential-adjacent material and must never land in the request log:
    /// the router membership attestation (bearer-like for its ~10 min TTL),
    /// the wallet/invite signatures, the invite's single-use nonce, and the
    /// redeemer's HPKE public key.
    static let pairInviteRedactedKeys: Set<String> = [
        "attestation", "wallet_signature", "sig", "signature", "nonce", "encPub", "enc_pub",
        // owner_redeem: the device id is a stable per-device identifier.
        "device_id",
    ]

    /// Redacted twin of a `/pair-invite` request body for the Insights request
    /// log. Walks the JSON (recursing into the `team_redeem` envelope) and
    /// replaces the values of `pairInviteRedactedKeys`. Non-JSON bodies are
    /// replaced wholesale rather than logged verbatim.
    static func redactedPairInviteRequestBody(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return data.isEmpty ? "" : "<redacted: non-JSON body>"
        }
        func redact(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in dict {
                    out[key] = pairInviteRedactedKeys.contains(key) ? "<redacted>" : redact(inner)
                }
                return out
            }
            if let array = value as? [Any] { return array.map(redact) }
            return value
        }
        let redacted = redact(object)
        guard
            let out = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
        else { return "<redacted>" }
        return String(decoding: out, as: UTF8.self)
    }

    /// Upstream's key-granted reply (`PairInviteResponse`).
    struct PairInviteResponse: Codable {
        let agentAddress: String
        let agentName: String
        let agentDescription: String?
        /// Workspaces handshake only upstream; set for owner redeem too.
        let agentModel: String?
        let relayBaseURL: String
        /// Empty for owner redeem: the key only travels sealed.
        let apiKey: String
        let sealedApiKey: PairingKeyEnvelope.Sealed?
        /// Secure Channel capability marker.
        let secureChannel: Bool
    }

    // MARK: - POST /pair-invite

    private func servePairInvite(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = "/pair-invite"
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")
        let eventLoop = context.eventLoop
        stateRef.value.routeLogsItself = true

        // Same per-source budget as the other pairing routes: public, does
        // signature checks, and mints keys (upstream).
        let pairingIP = remoteIP(context)
        let data = requestBodyData()
        let loggedRequest = Self.redactedPairInviteRequestBody(data)

        @Sendable func reply(_ status: HTTPResponseStatus, _ body: String, logged: String? = nil) {
            // A failed proof backs the source off, as `/pair` does on denial.
            if status == .unauthorized || status == .forbidden {
                PairingRateLimiter.shared.penalize(ip: pairingIP)
            }
            respondOnLoop(eventLoop, status: status, headers: jsonHeaders(), body: body)
            logRequest(
                method: "POST", path: path, userAgent: userAgent, requestBody: loggedRequest,
                responseBody: logged ?? body, responseStatus: Int(status.code), startTime: startTime)
        }

        guard PairingRateLimiter.shared.allow(ip: pairingIP) else {
            reply(.tooManyRequests, #"{"error":"Too many pairing attempts. Try again shortly."}"#)
            return
        }

        // Owner mode: a device holding this Mac's master identity. Proof is a
        // master-key signature over the host's nonce; no router, roster or
        // invite involved.
        if let envelope = try? JSONDecoder().decode(OwnerPairRedeemEnvelope.self, from: data) {
            let payload = envelope.ownerRedeem
            runRequestTask {
                switch await OwnerDeviceAccessHost.shared.handle(payload) {
                case .challenge(let nonce, let expiresIn):
                    let challenge = OwnerPairChallengeResponse(
                        ownerChallenge: .init(nonce: nonce, expiresIn: expiresIn))
                    let body =
                        (try? JSONEncoder.osaurusCanonical().encode(challenge))
                        .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"Encoding failed"}"#
                    reply(.ok, body, logged: #"{"owner_challenge":"<redacted>"}"#)
                case .rejected(let rejection):
                    let message = rejection.wireMessage
                        .replacingOccurrences(of: "\\", with: "")
                        .replacingOccurrences(of: "\"", with: "'")
                    reply(HTTPResponseStatus(statusCode: rejection.httpStatus), #"{"error":"\#(message)"}"#)
                case .granted(let grant):
                    func body(_ sealed: PairingKeyEnvelope.Sealed?) -> String {
                        let response = PairInviteResponse(
                            agentAddress: grant.agentAddress,
                            agentName: grant.agentName,
                            agentDescription: grant.agentDescription,
                            agentModel: grant.agentModel,
                            relayBaseURL: RelayTunnelManager.publicURL(forAddress: grant.agentAddress),
                            apiKey: "",
                            sealedApiKey: sealed,
                            secureChannel: true)
                        return (try? JSONEncoder.osaurusCanonical().encode(response))
                            .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"Encoding failed"}"#
                    }
                    MobileConnectLog.write("pair-invite: owner device redeemed a key for \(grant.agentAddress)")
                    reply(.ok, body(grant.sealedApiKey), logged: body(nil))
                }
            }
            return
        }

        // Workspace sign-ins and Mac-to-Mac agent invites are deferred.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let object, object["team_redeem"] != nil || object["addr"] != nil {
            reply(
                .notImplemented,
                #"{"error":"Workspaces and agent invites aren't available on this Mac yet"}"#)
            return
        }
        reply(.badRequest, #"{"error":"Invalid invite payload"}"#)
    }
}
