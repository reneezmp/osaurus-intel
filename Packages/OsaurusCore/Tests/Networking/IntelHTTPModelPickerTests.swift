//
//  IntelHTTPModelPickerTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 5b (docs/SERVER_API_INTEL.md): the owner's model
//  picker, model options, favourites and credits over HTTP. Option and
//  favourite writes land in the test process's own defaults and are undone
//  by each case; nothing reaches a provider or the Router.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPModelPickerTests {

    // MARK: - Picker mapping

    @Test func pickerModels_followTheMacTabsAndSkipMediaAndEmbeddings() {
        let osaurusId = RemoteProviderManager.osaurusRouterProviderId
        let otherId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "other/qwen3-32b", providerName: "Other", providerId: otherId),
            .fromRemoteModel(modelId: "osaurus/zeta", providerName: "Osaurus", providerId: osaurusId),
            .fromRemoteModel(modelId: "osaurus/alpha", providerName: "Osaurus", providerId: osaurusId),
            .fromRemoteModel(modelId: "other/text-embedding-3-small", providerName: "Other", providerId: otherId),
        ]
        let models = HTTPHandler.pickerModels(from: items)
        // Osaurus pinned first, models by name; embeddings left out.
        #expect(models.map(\.name) == ["alpha", "zeta", "qwen3-32b"])
        #expect(models[0].tab == "remote-\(osaurusId.uuidString)")
        #expect(models[0].tabTitle == "Osaurus")
        #expect(models.allSatisfy { $0.kind == "chat" && $0.source == "remote" && $0.available })
        // A remote chat model takes images unless it looks like an embedder,
        // and Qwen3's profile offers Thinking.
        #expect(models[2].vision)
        #expect(models[2].thinking)
        #expect(!models[0].thinking)
        #expect(models[2].favoriteKey == items[0].favoriteKey)
    }

    @Test func picker_answersFavoritesAndModels() async throws {
        let server = try await startPickerTestServer()
        defer { Task { await server.shutdown() } }
        let result = try await server.send("GET", "/models/picker")
        #expect(result.status == 200)
        let object = try result.object()
        #expect(object["favorites"] is [Any])
        #expect(object["models"] is [Any])
    }

    // MARK: - Favourites

    @Test func favorites_addAndRemoveAKey() async throws {
        let server = try await startPickerTestServer()
        defer { Task { await server.shutdown() } }
        let key = "remote-\(UUID().uuidString)|fixture/model"
        defer { FavoriteModelsStore.shared.remove(key) }

        let added = try await server.send("PUT", "/models/favorites", json: #"{"key":"\#(key)","favorite":true}"#)
        #expect(added.status == 200)
        #expect((try added.object()["favorites"] as? [String])?.contains(key) == true)
        #expect(FavoriteModelsStore.shared.favoriteKeys.contains(key))

        let removed = try await server.send("PUT", "/models/favorites", json: #"{"key":"\#(key)","favorite":false}"#)
        #expect((try removed.object()["favorites"] as? [String])?.contains(key) == false)
        let bad = try await server.send("PUT", "/models/favorites", json: #"{"key":"","favorite":true}"#)
        #expect(bad.status == 400)
    }

    // MARK: - Model options

    @Test func options_readAndWriteThinkingAsTheComposerDoes() async throws {
        let server = try await startPickerTestServer()
        defer { Task { await server.shutdown() } }
        let model = "fixture/qwen3-\(UUID().uuidString.prefix(8))"
        defer { ModelOptionsStore.shared.saveOptions([:], for: model) }

        let read = try await server.send("POST", "/models/options", json: #"{"model":"\#(model)"}"#)
        #expect(read.status == 200)
        let thinking = try #require(try read.object()["thinking"] as? [String: Any])
        #expect(thinking["explicit"] as? Bool == false)
        #expect(thinking["enabled"] as? Bool == false)
        #expect(thinking["tristate"] as? Bool == false)
        // Thinking is the profile's only option, so no other rows.
        #expect((try read.object()["options"] as? [Any])?.isEmpty == true)

        let on = try await server.send(
            "PUT", "/models/options", json: #"{"model":"\#(model)","option":"thinking","value":true}"#)
        #expect(on.status == 200)
        let after = try #require(try on.object()["thinking"] as? [String: Any])
        #expect(after["explicit"] as? Bool == true)
        #expect(after["enabled"] as? Bool == true)
        // Stored the way the composer stores it: the inverted raw option.
        #expect(ModelOptionsStore.shared.loadOptions(for: model)?["disableThinking"] == .bool(false))

        let reset = try await server.send(
            "PUT", "/models/options", json: #"{"model":"\#(model)","option":"thinking","value":null}"#)
        #expect((try reset.object()["thinking"] as? [String: Any])?["explicit"] as? Bool == false)

        let unknown = try await server.send(
            "PUT", "/models/options", json: #"{"model":"\#(model)","option":"nope","value":true}"#)
        #expect(unknown.status == 404)
        let invalid = try await server.send(
            "PUT", "/models/options", json: #"{"model":"\#(model)","option":"thinking","value":"loud"}"#)
        #expect(invalid.status == 400)
        let noOption = try await server.send("PUT", "/models/options", json: #"{"model":"\#(model)"}"#)
        #expect(noOption.status == 400)
    }

    @Test func optionsWrite_tellsOpenChatsToReload() async throws {
        let model = "fixture/qwen3-\(UUID().uuidString.prefix(8))"
        defer { ModelOptionsStore.shared.saveOptions([:], for: model) }
        final class Heard: @unchecked Sendable { var model: String? }
        let heard = Heard()
        let observer = NotificationCenter.default.addObserver(forName: .modelOptionsChanged, object: nil, queue: nil) {
            heard.model = $0.object as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try ModelOptionsSnapshot.apply(model: model, optionId: "thinking", value: .bool(true))
        #expect(heard.model == model)
    }

    // MARK: - Credits

    @Test func credits_needAKeyOrTheOptIn() async throws {
        let server = try await startPickerTestServer()
        defer { Task { await server.shutdown() } }
        let defaults = UserDefaults.standard
        let key = OsaurusRouter.allowUnkeyedLoopbackSpendDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        let refused = try await server.send("GET", "/credits/balance")
        #expect(refused.status == 403)
        #expect(refused.body.contains("credits_access_not_authorized"))

        // A browser page is refused even with the opt-in.
        defaults.set(true, forKey: key)
        let browser = try await server.send("GET", "/credits/balance", headers: ["Origin": "https://example.com"])
        #expect(browser.status == 403)
    }
}

// MARK: - Server fixture

private struct PickerRouteResult {
    let status: Int
    let body: String
    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] ?? [:]
    }
}

private struct PickerTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(
        _ method: String, _ path: String, json: String? = nil, headers: [String: String] = [:]
    ) async throws -> PickerRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        return PickerRouteResult(
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

private func startPickerTestServer() async throws -> PickerTestServer {
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
        return PickerTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
