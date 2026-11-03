//
//  IntelHTTPPairingTests.swift
//  OsaurusCoreTests
//
//  `W-identity-mobile` stage 1 (docs/IDENTITY_MOBILE_INTEL.md): the pairing
//  routes over a loopback server. A simulated phone runs SPAKE2 v2 against
//  `/pair/code` and `/pair/confirm` and opens the sealed payload. The code
//  and key are installed through the service's test seam, so no master key
//  or Keychain is touched; the pairing is undone at the end.
//

import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPPairingTests {

    private static func keyInfo() -> AccessKeyInfo {
        AccessKeyInfo(
            id: UUID(), label: MobilePairingService.keyLabel, prefix: "osk-v1.test", nonce: "pairing-test-nonce",
            cnt: 1, iss: "0x0000000000000000000000000000000000000001",
            aud: "0x0000000000000000000000000000000000000001", createdAt: Date(), expiration: .days90,
            expiresAt: Date().addingTimeInterval(90 * 86_400))
    }

    @Test func hello_saysWhetherACodeIsShowing() async throws {
        let server = try await startPairingTestServer()
        defer { Task { await server.shutdown() } }
        let service = MobilePairingService.shared
        service.cancelCode()

        let idle = try await server.send("GET", "/pair/hello")
        #expect(idle.status == 200)
        #expect(try idle.object()["pairing"] as? Bool == false)
        #expect(try idle.object()["v"] as? Int == MobilePairingService.wireVersion)

        service.installPendingCodeForTesting(
            PairingCode(code: "123456", issuedAt: Date()), fullKey: "osk-v1.test.secret", info: Self.keyInfo())
        defer { service.cancelCode() }
        #expect(try await server.send("GET", "/pair/hello").object()["pairing"] as? Bool == true)
    }

    @Test func v2Pairing_overHTTP() async throws {
        let server = try await startPairingTestServer()
        defer { Task { await server.shutdown() } }
        let service = MobilePairingService.shared
        let previous = service.pairedDevice
        #expect(previous == nil, "the test process should start unpaired")
        let info = Self.keyInfo()
        service.installPendingCodeForTesting(
            PairingCode(code: "246810", issuedAt: Date()), fullKey: "osk-v1.test.secret", info: info,
            connectAddress: "0x00000000000000000000000000000000000000aa")
        defer {
            service.cancelCode()
            service.revokeDevice()
        }

        // Step one: the phone's share.
        let phone = try PairingSPAKE2.Party(role: .phone, code: "246810")
        let start = try await server.send(
            "POST", "/pair/code",
            json: #"{"v":2,"deviceId":"phone-1","deviceName":"Test iPhone","share":"\#(phone.share.base64urlEncoded)"}"#)
        #expect(start.status == 200)
        let answer = try start.object()
        let exchange = try #require(answer["exchange"] as? String)
        let macShare = try #require((answer["share"] as? String).flatMap { Data(base64urlEncoded: $0) })
        let macConfirm = try #require((answer["confirm"] as? String).flatMap { Data(base64urlEncoded: $0) })

        let identity = PairingSPAKE2.phoneIdentity(deviceId: "phone-1", deviceName: "Test iPhone")
        let keys = try phone.finish(peerShare: macShare, phoneIdentity: identity)
        #expect(PairingSPAKE2.constantTimeEquals(macConfirm, keys.macConfirmation))

        // Step two: the phone's confirmation, answered with the payload.
        let confirm = try await server.send(
            "POST", "/pair/confirm",
            json: #"{"v":2,"exchange":"\#(exchange)","confirm":"\#(keys.phoneConfirmation.base64urlEncoded)"}"#)
        #expect(confirm.status == 200)
        let sealed = try #require(try confirm.object()["sealed"] as? String)
        let plaintext = try PairingSPAKE2.open(sealed, key: keys.sessionKey, deviceId: "phone-1")
        let payload = try JSONDecoder().decode(MobilePairPayload.self, from: plaintext)
        #expect(payload.apiKey == "osk-v1.test.secret")
        // No relay URLs on Intel until the relay is real (stage 4).
        #expect(payload.agents.allSatisfy { $0.relayURL == nil })

        #expect(service.pairedDevice?.deviceId == "phone-1")
        #expect(service.pairedDevice?.keyId == info.id)
        #expect(service.activeCode == nil)

        // The code is spent: a second exchange is refused.
        let again = try await server.send(
            "POST", "/pair/code",
            json: #"{"v":2,"deviceId":"phone-2","deviceName":"Other","share":"\#(phone.share.base64urlEncoded)"}"#)
        #expect(again.status == 401)
        #expect(again.body.contains("invalid_code"))
    }

    @Test func wrongCode_isRefusedUniformly() async throws {
        let server = try await startPairingTestServer()
        defer { Task { await server.shutdown() } }
        let service = MobilePairingService.shared
        service.installPendingCodeForTesting(
            PairingCode(code: "111111", issuedAt: Date()), fullKey: "osk-v1.test.secret", info: Self.keyInfo())
        defer { service.cancelCode() }

        let phone = try PairingSPAKE2.Party(role: .phone, code: "999999")
        let start = try await server.send(
            "POST", "/pair/code",
            json: #"{"v":2,"deviceId":"phone-1","deviceName":"Test iPhone","share":"\#(phone.share.base64urlEncoded)"}"#)
        #expect(start.status == 200)
        let answer = try start.object()
        let exchange = try #require(answer["exchange"] as? String)
        let macShare = try #require((answer["share"] as? String).flatMap { Data(base64urlEncoded: $0) })
        let keys = try phone.finish(
            peerShare: macShare,
            phoneIdentity: PairingSPAKE2.phoneIdentity(deviceId: "phone-1", deviceName: "Test iPhone"))
        let confirm = try await server.send(
            "POST", "/pair/confirm",
            json: #"{"v":2,"exchange":"\#(exchange)","confirm":"\#(keys.phoneConfirmation.base64urlEncoded)"}"#)
        #expect(confirm.status == 401)
        #expect(confirm.body.contains("invalid_code"))
        #expect(service.pairedDevice == nil)
    }

    @Test func badRequests_andUnpair() async throws {
        let server = try await startPairingTestServer()
        defer { Task { await server.shutdown() } }
        #expect(try await server.send("POST", "/pair/code", json: "{").status == 400)
        #expect(try await server.send("POST", "/pair/confirm", json: #"{"v":2}"#).status == 400)
        // No code showing: any exchange is the uniform 401.
        MobilePairingService.shared.cancelCode()
        let share = try PairingSPAKE2.Party(role: .phone, code: "123456").share.base64urlEncoded
        let none = try await server.send(
            "POST", "/pair/code", json: #"{"v":2,"deviceId":"p","deviceName":"n","share":"\#(share)"}"#)
        #expect(none.status == 401)
        // Only the paired phone's own key may unpair; a key-less local
        // caller is not it.
        let unpair = try await server.send("POST", "/pair/unpair")
        #expect(unpair.status == 403)
        #expect(unpair.body.contains("not_paired_device"))
    }
}

// MARK: - Server fixture

private struct PairingRouteResult {
    let status: Int
    let body: String
    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
    }
}

private struct PairingTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, json: String? = nil) async throws -> PairingRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return PairingRouteResult(
            status: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: String(decoding: data, as: UTF8.self))
    }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startPairingTestServer() async throws -> PairingTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
    // Every test pairs from 127.0.0.1; a wrong code in one test must not
    // leave the next inside the limiter's cooldown.
    PairingRateLimiter.shared.resetForTesting()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(configuration: .default, eventLoop: channel.eventLoop, trustLoopback: true))
                }
            }
        let ch = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return PairingTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
