//
//  IntelMediaGenerationTests.swift
//  osaurus
//
//  Intel's side of `W-media-generation`: Venice media discovery inside
//  Intel's own provider probe, and the coordinator's Intel guards (local
//  MLX targets refused, Cloud fails closed without its catalog). No test
//  reaches the network.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel media generation")
struct IntelMediaGenerationTests {
    private static func provider(host: String) -> RemoteProvider {
        RemoteProvider(
            name: "Venice",
            host: host,
            basePath: "/api/v1",
            customHeaders: [:],
            authType: .none,
            providerType: .openaiLegacy
        )
    }

    @Test func veniceIsRecognisedByExactHost() {
        #expect(IntelProviderDiscoveryExtras.isVeniceProvider(Self.provider(host: "api.venice.ai")))
        #expect(IntelProviderDiscoveryExtras.isVeniceProvider(Self.provider(host: "API.Venice.AI")))
        #expect(!IntelProviderDiscoveryExtras.isVeniceProvider(Self.provider(host: "venice.ai")))
        #expect(!IntelProviderDiscoveryExtras.isVeniceProvider(Self.provider(host: "api.openai.com")))
    }

    @Test func veniceDiscoveryAsksForAllTypesAndSplitsChatFromMedia() async throws {
        let provider = Self.provider(host: "api.venice.ai")
        let seen = RequestBox()
        let body = Data(
            """
            {"data":[
              {"id":"llama-chat","type":"text"},
              {"id":"flux-image","type":"image","model_spec":{"name":"Flux"}},
              {"id":"wan-t2v","type":"video","model_spec":{"constraints":{"model_type":"text-to-video","durations":["5s"]}}}
            ]}
            """.utf8)
        let discovery = await IntelProviderDiscoveryExtras.fetchVeniceModelsDiscovery(
            provider: provider,
            headers: ["Authorization": "Bearer test-key"],
            transport: { request in
                seen.request = request
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
        )
        let result = try #require(discovery)
        #expect(result.chatModelIDs == ["llama-chat"])
        #expect(result.mediaModels.map(\.target.modelID).sorted() == ["flux-image", "wan-t2v"])
        #expect(result.mediaModels.allSatisfy { $0.target.backend == .remoteProvider(provider.id) })
        let url = try #require(seen.request?.url)
        #expect(url.path == "/api/v1/models")
        #expect(url.query == "type=all")
        #expect(seen.request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func veniceDiscoveryFallsBackOnHTTPError() async {
        let discovery = await IntelProviderDiscoveryExtras.fetchVeniceModelsDiscovery(
            provider: Self.provider(host: "api.venice.ai"),
            headers: [:],
            transport: { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"error":"bad key"}"#.utf8), response)
            }
        )
        #expect(discovery == nil)
    }

    @Test func localImageTargetsAreRefusedOnIntel() async throws {
        let (coordinator, root) = Self.coordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = MediaImageGenerationRequest(
            target: MediaModelTarget(backend: .local, modelID: "flux-local"),
            prompt: "A lighthouse", negativePrompt: nil, width: nil, height: nil,
            aspectRatio: nil, resolution: nil, quality: nil, steps: nil, guidance: nil,
            seed: nil, count: 1, format: .png)
        await #expect(
            throws: MediaGenerationError.unsupported(MediaGenerationCoordinator.intelLocalUnsupported)
        ) {
            _ = try await coordinator.generateImage(request)
        }
    }

    @Test func localVideoTargetsAreRefusedOnIntel() async throws {
        let (coordinator, root) = Self.coordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = MediaVideoGenerationRequest(
            target: MediaModelTarget(backend: .local, modelID: "wan-local"),
            prompt: "Waves", negativePrompt: nil, sourceImage: nil, sourceImageMIMEType: nil,
            duration: "5s", aspectRatio: nil, resolution: nil, audio: nil)
        await #expect(
            throws: MediaGenerationError.unsupported(MediaGenerationCoordinator.intelLocalUnsupported)
        ) {
            _ = try await coordinator.quoteVideo(request)
        }
    }

    @Test func cloudFailsClosedWithoutItsCatalog() async throws {
        let (coordinator, root) = Self.coordinator()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await coordinator.cachedCloudModels().isEmpty)
        let request = MediaImageGenerationRequest(
            target: MediaModelTarget(backend: .osaurusCloud, modelID: "cloud-image"),
            prompt: "A lighthouse", negativePrompt: nil, width: nil, height: nil,
            aspectRatio: nil, resolution: nil, quality: nil, steps: nil, guidance: nil,
            seed: nil, count: 1, format: .png)
        await #expect(throws: MediaGenerationError.modelUnavailable("cloud-image")) {
            _ = try await coordinator.generateImage(request)
        }
    }

    private static func coordinator() -> (MediaGenerationCoordinator, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-intel-media-\(UUID().uuidString)", isDirectory: true)
        let coordinator = MediaGenerationCoordinator(
            jobs: MediaJobStore(fileURL: root.appendingPathComponent("jobs.json")))
        return (coordinator, root)
    }
}

private final class RequestBox: @unchecked Sendable {
    var request: URLRequest?
}
