//
//  IntelHTTPMemoryIngestTests.swift
//  OsaurusCoreTests
//
//  `W-server-api` stage 4e (docs/SERVER_API_INTEL.md): `POST /memory/ingest`
//  on Intel's memory. Every case runs against an in-memory memory database
//  inside the test storage root; distillation is scripted through
//  `setDistillGenerateOverrideForTests`, never a real model.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IntelHTTPMemoryIngestTests {
    private static let distillReply = """
        {"episode": {"summary": "The user said they keep bees.", "topics": ["bees"], "decisions": [], \
        "action_items": [], "salience": 0.5}, "entities": [], "pinned_candidates": [], "identity_facts": []}
        """

    /// Memory on, an in-memory database, and optionally `agent` opted in to
    /// distillation (Intel's per-agent gate).
    private func withMemory(
        enabled: Bool = true, distillingAgent: UUID? = nil,
        _ body: @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await ChatHistoryTestStorage.run {
            MemoryConfigurationStore.invalidateCache()
            MemoryDatabase.shared.close()
            try MemoryDatabase.shared.openInMemory()
            var config = MemoryConfiguration.default
            config.enabled = enabled
            config.extractionMode = .manual
            // No embedder in tests: transcript vectors aren't what's tested.
            config.embeddingProvider = "none"
            if let distillingAgent { config.distillationEnabledAgents[distillingAgent.uuidString] = true }
            MemoryConfigurationStore.save(config)
            let reply = Self.distillReply
            await MemoryService.shared.setDistillGenerateOverrideForTests { _, _ in reply }
            defer {
                Task { await MemoryService.shared.setDistillGenerateOverrideForTests(nil) }
                MemoryDatabase.shared.close()
                MemoryConfigurationStore.invalidateCache()
            }
            try await body()
        }
    }

    private static func request(
        agent: String, conversation: String, skipExtraction: Bool? = nil
    ) -> HTTPHandler.MemoryIngestRequest {
        HTTPHandler.MemoryIngestRequest(
            agent_id: agent,
            conversation_id: conversation,
            turns: [
                .init(user: "I keep bees on my roof, three hives of them.", assistant: "Lovely, noted.", date: nil),
                .init(user: "They make about twenty kilos of honey a year.", assistant: "Impressive.", date: nil),
            ],
            session_date: nil,
            skip_extraction: skipExtraction
        )
    }

    // MARK: - HTTP gates

    @Test func rejectsBadBodiesTheBuiltInAgentAndDisabledMemory() async throws {
        try await withMemory(enabled: false) {
            let server = try await startIngestTestServer()
            defer { Task { await server.shutdown() } }
            let bad = try await server.post("/memory/ingest", "{}")
            #expect(bad.status == 400)
            #expect(bad.body.contains("Invalid request format"))

            let builtIn = try await server.post(
                "/memory/ingest",
                #"{"agent_id":"\#(Agent.defaultId.uuidString)","conversation_id":"c","turns":[]}"#)
            #expect(builtIn.status == 403, "\(builtIn.body)")

            let off = try await server.post(
                "/memory/ingest", #"{"agent_id":"\#(UUID().uuidString)","conversation_id":"c","turns":[]}"#)
            #expect(off.status == 503)
            #expect(off.body.contains("memory_disabled"))
        }
    }

    @Test func transcriptOnlyIngest_overHTTP() async throws {
        try await withMemory {
            let server = try await startIngestTestServer()
            defer { Task { await server.shutdown() } }
            let agent = UUID()
            let result = try await server.post(
                "/memory/ingest",
                #"{"agent_id":"\#(agent.uuidString.lowercased())","conversation_id":"conv-1","skip_extraction":true,"turns":[{"user":"hi","assistant":"hello"}]}"#
            )
            #expect(result.status == 200, "\(result.body)")
            #expect(result.body == #"{"status":"ok","turns_ingested":1}"#)
            // Stored under the canonical (uppercase) id recall reads.
            let turns = try MemoryDatabase.shared.loadTranscript(agentId: agent.uuidString)
            #expect(turns.map(\.role).sorted() == ["assistant", "user"])
            #expect(try MemoryDatabase.shared.loadPendingSignals(conversationId: "conv-1").isEmpty)
        }
    }

    // MARK: - Distillation outcome

    @Test func optedInAgent_isDistilledAndReportsTheEpisode() async throws {
        let agent = UUID()
        try await withMemory(distillingAgent: agent) {
            let (status, json) = await HTTPHandler.ingest(Self.request(agent: agent.uuidString, conversation: "conv-2"))
            #expect(status == .ok)
            let body = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(body["turns_ingested"] as? Int == 2)
            #expect(body["distillation"] as? String == "distilled", "\(json)")
            #expect(body["episode_id"] is Int)
            #expect(try MemoryDatabase.shared.loadEpisodes(agentId: agent.uuidString).count == 1)
            #expect(try MemoryDatabase.shared.loadTranscript(agentId: agent.uuidString).count == 4)
        }
    }

    /// Re-ingesting a conversation replaces it: one episode, one transcript
    /// (upstream I1).
    @Test func reingest_replacesTheConversation() async throws {
        let agent = UUID()
        try await withMemory(distillingAgent: agent) {
            _ = await HTTPHandler.ingest(Self.request(agent: agent.uuidString, conversation: "conv-3"))
            _ = await HTTPHandler.ingest(Self.request(agent: agent.uuidString, conversation: "conv-3"))
            let episodes = try MemoryDatabase.shared.loadEpisodes(agentId: agent.uuidString)
            let transcript = try MemoryDatabase.shared.loadTranscript(agentId: agent.uuidString)
            #expect(episodes.count == 1)
            #expect(transcript.count == 4)
        }
    }

    /// Intel's distillation is opt-in per agent: the transcript is stored,
    /// nothing is sent to a model, and the response says why.
    @Test func optedOutAgent_keepsTheTranscriptOnly() async throws {
        try await withMemory {
            let agent = UUID()
            let (status, json) = await HTTPHandler.ingest(Self.request(agent: agent.uuidString, conversation: "conv-4"))
            #expect(status == .ok)
            #expect(json.contains(#""distillation":"skipped:distillation_opted_out""#), "\(json)")
            let episodes = try MemoryDatabase.shared.loadEpisodes(agentId: agent.uuidString)
            let transcript = try MemoryDatabase.shared.loadTranscript(agentId: agent.uuidString)
            #expect(episodes.isEmpty)
            #expect(transcript.count == 4)
        }
    }

    @Test func distillOutcome_mapsToUpstreamsStatusTokens() {
        #expect(DistillOutcome.distilled(episodeId: 7, pinned: 0, identityFacts: 0).apiStatus == "distilled")
        #expect(DistillOutcome.distilled(episodeId: 7, pinned: 0, identityFacts: 0).episodeId == 7)
        #expect(DistillOutcome.noSignals.apiStatus == "no_signals")
        #expect(DistillOutcome.skipped(reason: "memory_disabled").apiStatus == "skipped:memory_disabled")
        #expect(DistillOutcome.deadLettered(attempts: 3).apiStatus == "dead_letter:3")
    }
}

// MARK: - Server fixture

private struct IngestResult { let status: Int; let body: String }

private struct IngestTestServer {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    let lease: HTTPServerTestLease
    let port: Int

    func post(_ path: String, _ body: String) async throws -> IngestResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: request)
        return IngestResult(
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

private func startIngestTestServer() async throws -> IngestTestServer {
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
        return IngestTestServer(group: group, channel: ch, lease: lease, port: ch.localAddress?.port ?? 0)
    } catch {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.shutdownGracefully { _ in cont.resume() }
        }
        await lease.release()
        throw error
    }
}
