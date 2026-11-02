//
//  IntelHTTPMediaTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 6 (docs/SERVER_API_INTEL.md): the image and video
//  routes and the picker's cloud image rows. Every case stops before a
//  provider is called: refusals, on-device paths (501 on Intel), unknown
//  providers, unknown quotes and jobs. Nothing reaches the network or spends.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPMediaTests {

    // MARK: - Picker rows

    private static func media(
        _ kind: MediaGenerationKind,
        backend: MediaGenerationBackend,
        offline: Bool = false
    ) -> ModelPickerItem {
        let providerId: UUID
        if case .remoteProvider(let id) = backend { providerId = id } else { providerId = UUID() }
        return .fromMediaModel(
            MediaModelInfo(
                target: MediaModelTarget(backend: backend, modelID: "\(kind.rawValue)-model"),
                displayName: "Media \(kind.rawValue)",
                providerName: "Venice",
                kind: kind,
                constraints: MediaModelConstraints(
                    aspectRatios: ["1:1", "16:9"], defaultAspectRatio: "1:1", resolutions: ["1K"],
                    defaultResolution: "1K"),
                pricing: MediaModelPricing(generation: MediaPrice(usd: 0.04)),
                privacy: "private",
                offline: offline
            ),
            providerId: providerId
        )
    }

    @Test func picker_listsAvailableCloudImageModelsWithTheirControls() throws {
        let venice = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "venice/llama", providerName: "Venice", providerId: venice),
            Self.media(.image, backend: .remoteProvider(venice)),
            Self.media(.textToVideo, backend: .remoteProvider(venice)),
            Self.media(.image, backend: .osaurusCloud),
            Self.media(.image, backend: .remoteProvider(venice), offline: true),
        ]
        let models = HTTPHandler.pickerModels(from: items)
        // The chat model and the two available image models; video and the
        // offline image model are left out (upstream).
        #expect(models.count == 3)
        let images = models.filter { $0.kind == "image" }
        #expect(images.count == 2)
        let veniceImage = try #require(images.first { $0.cloud?.target.backend == "remote_provider" })
        #expect(veniceImage.cloud?.target.providerId == venice.uuidString)
        #expect(veniceImage.cloud?.target.model == "image-model")
        #expect(veniceImage.cloud?.aspectRatios == ["1:1", "16:9"])
        #expect(veniceImage.cloud?.maxCount == 4)
        #expect(veniceImage.cloud?.formats == ImageOutputFormat.allCases.map(\.rawValue))
        #expect(veniceImage.cloud?.minPriceUSD == 0.04)
        #expect(veniceImage.cloud?.priceLabel?.hasPrefix("From ") == true)
        #expect(!veniceImage.thinking && !veniceImage.edits)
        let cloudImage = try #require(images.first { $0.cloud?.target.backend == "osaurus_cloud" })
        #expect(cloudImage.cloud?.target.providerId == nil)
        let chat = try #require(models.first { $0.kind == "chat" })
        #expect(chat.cloud == nil)

        // The wire shape: snake_case controls under `cloud`, absent on chat rows.
        let json = try #require(
            String(data: try JSONEncoder.osaurusCanonical().encode(veniceImage), encoding: .utf8))
        #expect(json.contains(#""provider_id":"\#(venice.uuidString)""#))
        #expect(json.contains(#""aspect_ratios""#))
        let chatJSON = try #require(String(data: try JSONEncoder.osaurusCanonical().encode(chat), encoding: .utf8))
        #expect(!chatJSON.contains(#""cloud""#))
    }

    // MARK: - Helpers

    @Test func remoteBatchFieldsAreRefusedBeforeAnySpend() throws {
        let plain = try JSONDecoder().decode(
            ImageGenerationRequestDTO.self, from: Data(#"{"prompt":"a cat"}"#.utf8))
        try HTTPHandler.validateRemoteImageBatch(plain)
        let seeded = try JSONDecoder().decode(
            ImageGenerationRequestDTO.self, from: Data(#"{"prompt":"a cat","seeds":[1,2]}"#.utf8))
        #expect(throws: ImageGenerationError.self) { try HTTPHandler.validateRemoteImageBatch(seeded) }
    }

    @Test func helpers_matchUpstream() {
        #expect(HTTPHandler.resolveImageSize(size: "512x768", width: nil, height: nil) == (512, 768))
        #expect(HTTPHandler.resolveImageSize(size: "512x768", width: 64, height: 64) == (64, 64))
        #expect(HTTPHandler.imageOutputFormat("JPG") == .jpeg)
        #expect(HTTPHandler.imageOutputFormat(nil) == .png)
        #expect(HTTPHandler.mediaErrorStatus(MediaGenerationError.insufficientFunds).code == 402)
        #expect(HTTPHandler.mediaErrorStatus(MediaGenerationError.unsupported("x")) == .notImplemented)
        #expect(HTTPHandler.mediaErrorStatus(MediaGenerationError.transport("x")) == .badGateway)
        let redacted = HTTPHandler.redactedMediaRequestBody(#"{"prompt":"p","source_image":"AAAA"}"#)
        #expect(redacted?.contains("[REDACTED IMAGE]") == true)
        #expect(redacted?.contains("AAAA") == false)
        let id = UUID()
        #expect(HTTPHandler.videoJobID(fromPath: "/videos/jobs/\(id.uuidString)") == id)
        #expect(HTTPHandler.videoJobID(fromPath: "/videos/jobs/\(id.uuidString)/content", suffix: "/content") == id)
        #expect(HTTPHandler.videoJobID(fromPath: "/videos/jobs/\(id.uuidString)/x") == nil)
    }

    @Test func cancelStopsARunningImageRequest() async {
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        HTTPHandler.runningImageJobs.insert("img-test", task)
        #expect(HTTPHandler.runningImageJobs.cancel("img-test"))
        #expect(task.isCancelled)
        #expect(!HTTPHandler.runningImageJobs.cancel("img-test"))
    }

    // MARK: - Image routes

    @Test func imageModels_isEmptyOnIntel() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let result = try await server.send("GET", "/images/models")
        #expect(result.status == 200)
        #expect(try result.object()["object"] as? String == "list")
        #expect((try result.object()["data"] as? [Any])?.isEmpty == true)
    }

    @Test func imageGenerations_refusals() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let venice = UUID().uuidString
        let target = #""target":{"backend":"remote_provider","provider_id":"\#(venice)","model":"m"}"#

        let bad = try await server.send("POST", "/images/generations", json: "{")
        #expect(bad.status == 400)

        // A bare model is an on-device model upstream: MLX, so 501 here.
        let local = try await server.send("POST", "/images/generations", json: #"{"prompt":"a cat","model":"flux"}"#)
        #expect(local.status == 501)
        #expect(local.body.contains("Apple Silicon"))

        let noSpend = try await server.send("POST", "/images/generations", json: #"{"prompt":"a cat",\#(target)}"#)
        #expect(noSpend.status == 403)
        #expect(noSpend.body.contains("allow_remote_media_spend"))

        let seeds = try await server.send(
            "POST", "/images/generations",
            json: #"{"prompt":"a cat","seeds":[1],"allow_remote_media_spend":true,\#(target)}"#)
        #expect(seeds.status == 400)

        // An unknown provider fails before any request leaves the Mac.
        let unknown = try await server.send(
            "POST", "/images/generations", json: #"{"prompt":"a cat","allow_remote_media_spend":true,\#(target)}"#)
        #expect(unknown.status == 404)
        #expect((try unknown.object()["error"] as? [String: Any])?["type"] as? String == "invalid_request_error")
    }

    @Test func imageGenerations_streamAnswersAsSSE() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let target = #""target":{"backend":"remote_provider","provider_id":"\#(UUID().uuidString)","model":"m"}"#
        let result = try await server.send(
            "POST", "/images/generations",
            json: #"{"prompt":"a cat","stream":true,"allow_remote_media_spend":true,\#(target)}"#)
        #expect(result.status == 200)
        let events = result.body.components(separatedBy: "\n\n").filter { $0.hasPrefix("data: ") }
        #expect(events.count == 3)
        #expect(events.first?.contains(#""type":"queued""#) == true)
        #expect(events.first?.contains(#""job_id":"img"#) == true)
        #expect(events.dropFirst().first?.contains(#""type":"error""#) == true)
        #expect(events.last == "data: [DONE]")
    }

    @Test func editsAndUpscale_needTheOnDeviceEngine() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()

        let noSource = try await server.send("POST", "/images/edits", json: #"{"prompt":"p"}"#)
        #expect(noSource.status == 400)
        let mask = try await server.send(
            "POST", "/images/edits", json: #"{"prompt":"p","image":"\#(png)","mask":"\#(png)"}"#)
        #expect(mask.status == 501)
        #expect(mask.body.contains("mask"))
        let edit = try await server.send("POST", "/images/edits", json: #"{"prompt":"p","image":"\#(png)"}"#)
        #expect(edit.status == 501)
        #expect(edit.body.contains("Apple Silicon"))

        let badUpscale = try await server.send("POST", "/images/upscale", json: #"{"model":"m"}"#)
        #expect(badUpscale.status == 400)
        let badFormat = try await server.send(
            "POST", "/images/upscale", json: #"{"model":"m","image":"\#(png)","output_format":"gif"}"#)
        #expect(badFormat.status == 400)
        let upscale = try await server.send("POST", "/images/upscale", json: #"{"model":"m","image":"\#(png)"}"#)
        #expect(upscale.status == 501)
    }

    @Test func cancelAndJobEvents() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let cancel = try await server.send("POST", "/images/cancel", json: #"{"job_id":"img-unknown"}"#)
        #expect(cancel.status == 200)
        #expect(try cancel.object()["type"] as? String == "cancelled")
        #expect(try cancel.object()["job_id"] as? String == "img-unknown")
        let bad = try await server.send("POST", "/images/cancel", json: "{}")
        #expect(bad.status == 400)
        let events = try await server.send("GET", "/images/jobs/abc/events")
        #expect(events.status == 404)
        #expect(events.body.contains("job_not_found"))
    }

    // MARK: - Video routes

    @Test func videoQuoteAndGeneration_refusals() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let remote = #""target":{"backend":"remote_provider","provider_id":"\#(UUID().uuidString)","model":"v"}"#

        let bad = try await server.send("POST", "/videos/quote", json: #"{"prompt":"waves"}"#)
        #expect(bad.status == 400)
        let local = try await server.send(
            "POST", "/videos/quote",
            json: #"{"prompt":"waves","duration":"5s","target":{"backend":"local","model":"wan"}}"#)
        #expect(local.status == 501)
        // A source image may never be a file on this Mac.
        let fileSource = try await server.send(
            "POST", "/videos/quote",
            json: #"{"prompt":"waves","duration":"5s","source_image":"file:///etc/hosts",\#(remote)}"#)
        #expect(fileSource.status == 400)

        let noToken = try await server.send(
            "POST", "/videos/generations", json: #"{"prompt":"waves","duration":"5s",\#(remote)}"#)
        #expect(noToken.status == 400)
        let noSpend = try await server.send(
            "POST", "/videos/generations",
            json: #"{"prompt":"waves","duration":"5s","quote_token":"t",\#(remote)}"#)
        #expect(noSpend.status == 403)
        let unknownQuote = try await server.send(
            "POST", "/videos/generations",
            json: #"{"prompt":"waves","duration":"5s","quote_token":"t","allow_remote_media_spend":true,\#(remote)}"#)
        #expect(unknownQuote.status == 400)
        #expect(unknownQuote.body.contains("quote"))
    }

    @Test func videoJobs_unknownAndMalformed() async throws {
        let server = try await startMediaTestServer()
        defer { Task { await server.shutdown() } }
        let id = UUID().uuidString
        #expect(try await server.send("GET", "/videos/jobs/not-a-uuid").status == 400)
        #expect(try await server.send("GET", "/videos/jobs/\(id)").status == 404)
        #expect(try await server.send("GET", "/videos/jobs/\(id)/content").status == 404)
        #expect(try await server.send("GET", "/videos/jobs/x/content").status == 400)
    }
}

// MARK: - Server fixture

private struct MediaRouteResult {
    let status: Int
    let body: String
    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
    }
}

private struct MediaTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, json: String? = nil) async throws -> MediaRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return MediaRouteResult(
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

private func startMediaTestServer() async throws -> MediaTestServer {
    let lease = await HTTPServerTestLock.shared.acquire()
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
        return MediaTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
