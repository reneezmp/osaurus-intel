//
//  IntelHTTPSessionsTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 5a (docs/SERVER_API_INTEL.md): the Mac's chat
//  history over HTTP, on Intel's `ChatSessionsManager`. Every case runs in
//  the test storage root with its own saved chats; no window is open, so
//  edits go through the manager as they would for a closed chat.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPSessionsTests {
    /// The smallest PNG header the content sniffer recognises.
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    private func withChats(
        _ body: @MainActor @Sendable (_ server: SessionsTestServer, _ chats: [ChatSessionData]) async throws -> Void
    ) async throws {
        try await ChatHistoryTestStorage.run {
            ChatSessionsManager.shared.refresh()
            defer { ChatSessionsManager.shared.refresh() }
            let older = ChatSessionData(
                title: "Groceries",
                updatedAt: Date(timeIntervalSinceNow: -60),
                turns: [
                    ChatTurnData(
                        id: UUID(), role: .user, content: "buy saffron",
                        attachments: [.image(Self.pngBytes)], createdAt: Date()),
                    ChatTurnData(id: UUID(), role: .assistant, content: "Added.", createdAt: Date()),
                ],
                agentId: Agent.defaultId)
            let newer = ChatSessionData(
                title: "Taxes",
                turns: [
                    ChatTurnData(id: UUID(), role: .user, content: "file the forms", createdAt: Date()),
                    ChatTurnData(id: UUID(), role: .assistant, content: "Done.", createdAt: Date()),
                    ChatTurnData(id: UUID(), role: .user, content: "thanks", createdAt: Date()),
                ],
                agentId: Agent.defaultId)
            var archived = ChatSessionData(title: "Old plan", agentId: Agent.defaultId)
            archived.archived = true
            let chats = [older, newer, archived]
            for chat in chats { ChatSessionsManager.shared.save(chat) }
            // Other suites share this storage root: leave nothing behind.
            defer { for chat in chats { ChatSessionsManager.shared.delete(id: chat.id) } }

            let server = try await startSessionsTestServer()
            defer { Task { await server.shutdown() } }
            try await body(server, chats)
        }
    }

    @Test func list_newestFirstWithFiltersAndSearch() async throws {
        try await withChats { server, chats in
            // Other suites may have saved chats in this root too: look only
            // at this test's own.
            let ours = Set(chats.map(\.id.uuidString))
            func titles(_ result: SessionsRouteResult) throws -> [String] {
                let rows = try result.object()["sessions"] as? [[String: Any]] ?? []
                return rows.filter { ours.contains($0["id"] as? String ?? "") }.compactMap { $0["title"] as? String }
            }
            let list = try await server.send("GET", "/sessions")
            #expect(list.status == 200)
            #expect(try titles(list) == ["Taxes", "Groceries"], "\(list.body)")
            #expect(list.body.contains(#""origin":"mac""#))

            let withArchived = try await server.send("GET", "/sessions?archived=true")
            #expect(try titles(withArchived).count == 3, "\(withArchived.body)")

            // Message text matches, as the Mac's history search does.
            let search = try await server.send("GET", "/sessions?q=saffron")
            #expect(try titles(search) == ["Groceries"], "\(search.body)")

            let limited = try await server.send("GET", "/sessions?limit=1")
            #expect((try limited.object()["sessions"] as? [[String: Any]])?.count == 1)
            let workspace = try await server.send("GET", "/sessions?workspace_id=w1")
            #expect(workspace.body == #"{"sessions":[]}"#)
        }
    }

    @Test func detail_mapsTurnsAndServesTheirImages() async throws {
        try await withChats { server, chats in
            let chat = chats[0]
            let detail = try await server.send("GET", "/sessions/\(chat.id.uuidString)")
            #expect(detail.status == 200)
            let object = try detail.object()
            #expect(object["title"] as? String == "Groceries")
            let turns = try #require(object["turns"] as? [[String: Any]])
            #expect(turns.count == 2)
            let images = try #require(turns[0]["images"] as? [[String: Any]])
            #expect(images.first?["index"] as? Int == 0)
            #expect(images.first?["byte_count"] as? Int == Self.pngBytes.count)

            let turnId = chat.turns[0].id.uuidString
            let image = try await server.send("GET", "/sessions/\(chat.id.uuidString)/turns/\(turnId)/images/0")
            #expect(image.status == 200)
            #expect(image.contentType == "image/png")
            #expect(image.data == Self.pngBytes)
            let missing = try await server.send("GET", "/sessions/\(chat.id.uuidString)/turns/\(turnId)/images/1")
            #expect(missing.status == 404)
            let bad = try await server.send("GET", "/sessions/\(chat.id.uuidString)/turns/x/images/0")
            #expect(bad.status == 400)

            let unknown = try await server.send("GET", "/sessions/\(UUID().uuidString)")
            #expect(unknown.status == 404)
            let invalid = try await server.send("GET", "/sessions/nope")
            #expect(invalid.status == 400)
        }
    }

    @Test func patch_renamesArchivesAndPins() async throws {
        try await withChats { server, chats in
            let id = chats[1].id
            let patch = try await server.send(
                "PATCH", "/sessions/\(id.uuidString)", json: #"{"title":"  Tax return  ","pinned":true,"archived":true}"#)
            #expect(patch.status == 200)
            let stored = try #require(ChatSessionsManager.shared.session(for: id))
            #expect(stored.title == "Tax return")
            #expect(stored.pinned)
            #expect(stored.archived)
            let blank = try await server.send("PATCH", "/sessions/\(id.uuidString)", json: #"{"title":"   "}"#)
            #expect(blank.status == 200)
            #expect(ChatSessionsManager.shared.session(for: id)?.title == "Tax return")
            let unknown = try await server.send("PATCH", "/sessions/\(UUID().uuidString)", json: #"{"pinned":true}"#)
            #expect(unknown.status == 404)
            let bad = try await server.send("PATCH", "/sessions/\(id.uuidString)", json: "nope")
            #expect(bad.status == 400)
        }
    }

    @Test func truncate_dropsTheTurnAndEverythingAfter() async throws {
        try await withChats { server, chats in
            let chat = chats[1]
            let result = try await server.send(
                "POST", "/sessions/\(chat.id.uuidString)/truncate",
                json: #"{"from_turn_id":"\#(chat.turns[1].id.uuidString)"}"#)
            #expect(result.status == 200)
            #expect(result.body == #"{"ok":true,"removed":2}"#)
            #expect(ChatSessionsManager.shared.session(for: chat.id)?.turns.map(\.content) == ["file the forms"])

            let gone = try await server.send(
                "POST", "/sessions/\(chat.id.uuidString)/truncate", json: #"{"from_turn_id":"\#(UUID().uuidString)"}"#)
            #expect(gone.status == 404)
            #expect(gone.body.contains("turn_not_found"))
            let bad = try await server.send("POST", "/sessions/\(chat.id.uuidString)/truncate", json: "{}")
            #expect(bad.status == 400)
        }
    }

    @Test func delete_removesTheChat() async throws {
        try await withChats { server, chats in
            let id = chats[0].id
            let deleted = try await server.send("DELETE", "/sessions/\(id.uuidString)")
            #expect(deleted.status == 200)
            #expect(ChatSessionsManager.shared.session(for: id) == nil)
            let again = try await server.send("DELETE", "/sessions/\(id.uuidString)")
            #expect(again.status == 404)
        }
    }

    @Test func projectsAndArtifacts() async throws {
        try await withChats { server, _ in
            let projects = try await server.send("GET", "/projects")
            #expect(projects.status == 200)
            let object = try projects.object()
            #expect(object["projects"] is [Any])
            #expect(object["plugins"] is [Any])
            #expect((object["workspaces"] as? [Any])?.isEmpty == true)

            // Only images in the artifacts folder, by plain names.
            let missing = try await server.send("GET", "/artifacts/ctx/nothing.png")
            #expect(missing.status == 404)
            let traversal = try await server.send("GET", "/artifacts/..%2F..%2Fetc/passwd")
            #expect(traversal.status == 404)
            let notAnImage = try await server.send("GET", "/artifacts/ctx/notes.txt")
            #expect(notAnImage.status == 404)
        }
    }

    @Test func contentTypeSniffing() {
        #expect(HTTPHandler.imageContentType(forData: Data([0xFF, 0xD8, 0xFF, 0xE0])) == "image/jpeg")
        #expect(HTTPHandler.imageContentType(forData: Self.pngBytes) == "image/png")
        #expect(HTTPHandler.imageContentType(forData: Data("GIF89a".utf8)) == "image/gif")
        #expect(HTTPHandler.imageContentType(forData: Data([1, 2, 3])) == "application/octet-stream")
    }
}

// MARK: - Server fixture

struct SessionsRouteResult {
    let status: Int
    let data: Data
    let contentType: String?
    var body: String { String(decoding: data, as: UTF8.self) }
    func object() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}

struct SessionsTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func send(_ method: String, _ path: String, json: String? = nil) async throws -> SessionsRouteResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        let http = resp as? HTTPURLResponse
        return SessionsRouteResult(
            status: http?.statusCode ?? -1, data: data, contentType: http?.value(forHTTPHeaderField: "Content-Type"))
    }

    func shutdown() async {
        _ = try? await channel.close()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
    }
}

private func startSessionsTestServer() async throws -> SessionsTestServer {
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
        return SessionsTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
