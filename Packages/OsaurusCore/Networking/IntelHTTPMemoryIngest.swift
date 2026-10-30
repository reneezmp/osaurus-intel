//
//  IntelHTTPMemoryIngest.swift
//  osaurus
//
//  `POST /memory/ingest` (`W-server-api` stage 4e, docs/SERVER_API_INTEL.md):
//  bulk-load conversation turns into an agent's memory, as upstream does for
//  benchmarks and imports. Upstream's checks and order:
//
//  1. Body `{agent_id, conversation_id, turns: [{user, assistant, date?}],
//     session_date?, skip_extraction?}`, else 400.
//  2. The built-in agent's memory is never written over HTTP (403).
//  3. Memory off → 503 `memory_disabled`; database not open within 8 s →
//     503 `memory_database_unavailable`.
//  4. The conversation's transcript is replaced; unless `skip_extraction`,
//     its pending signals and episodes are cleared first and every turn is
//     buffered for distillation.
//  5. Unless `skip_extraction`, distillation runs now and the response
//     reports its outcome (`distillation`, `episode_id`).
//
//  Intel differences: distillation runs on the cloud model the user chats
//  with (no residency gate), and stays opt-in per agent (`MEMORY_PLAN.md`
//  Phase 3), so an agent without it reports `skipped:distillation_opted_out`
//  and keeps only the transcript. Intel's request log records no request
//  bodies, so the turns are never logged.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routeMemoryIngestRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard head.method == .POST, path == "/memory/ingest" else { return false }
        serveMemoryIngest(context: context)
        return true
    }

    /// Request body for the `/memory/ingest` endpoint.
    struct MemoryIngestRequest: Codable {
        let agent_id: String
        let conversation_id: String
        let turns: [MemoryIngestTurn]
        let session_date: String?
        let skip_extraction: Bool?
    }

    struct MemoryIngestTurn: Codable {
        let user: String
        let assistant: String
        let date: String?
    }

    /// Bulk-ingest conversation turns into the memory system.
    private func serveMemoryIngest(context: ChannelHandlerContext) {
        guard let req = try? JSONDecoder().decode(MemoryIngestRequest.self, from: requestBodyData()) else {
            sendResponse(
                context: context, status: .badRequest, headers: textHeaders(),
                body: "Invalid request format. Expected {agent_id, conversation_id, turns: [{user, assistant}]}")
            return
        }

        // Memory writes against the built-in agent must not be reachable from
        // HTTP. The in-app chat is the only sanctioned writer for it.
        if let agentUUID = UUID(uuidString: req.agent_id),
            let rejection = Agent.rejectBuiltInForExternalSurface(agentUUID, source: "http/memory/ingest")
        {
            sendResponse(
                context: context, status: .forbidden, headers: jsonHeaders(),
                body: Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
            return
        }

        guard MemoryConfigurationStore.load().enabled else {
            sendResponse(
                context: context, status: .serviceUnavailable, headers: jsonHeaders(),
                body: #"{"error":"memory_disabled","message":"Memory is disabled"}"#)
            return
        }

        let eventLoop = context.eventLoop
        runRequestTask {
            let body = await Self.ingest(req)
            self.respondOnLoop(eventLoop, status: body.status, headers: self.jsonHeaders(), body: body.json)
        }
    }

    /// The ingest itself, off the event loop: transcript, buffering, then the
    /// awaited distillation. Returns the HTTP status and JSON body.
    static func ingest(_ req: MemoryIngestRequest) async -> (status: HTTPResponseStatus, json: String) {
        let db = MemoryDatabase.shared
        guard await MemoryDatabase.waitForSharedOpen(timeoutSeconds: 8) else {
            return (
                .serviceUnavailable,
                #"{"error":"memory_database_unavailable","message":"Memory database is not ready"}"#
            )
        }

        let skipExtraction = req.skip_extraction ?? false

        // Agent-id canonicalization (upstream I3): recall and the per-agent
        // vector index key off Swift's uppercase `UUID.uuidString`, so a
        // lowercase UUID ingested verbatim would write where recall never
        // reads. Non-UUID ids pass through unchanged.
        let canonicalAgentId = UUID(uuidString: req.agent_id)?.uuidString ?? req.agent_id

        do {
            try db.deleteTranscriptForConversation(req.conversation_id)

            // Idempotency (upstream I1): `episodes` has no
            // `UNIQUE(conversation_id)`, so re-ingesting a conversation would
            // otherwise stack duplicate episodes and pending signals. Only
            // when extraction runs: `skip_extraction` callers want
            // transcript-only storage, with the rest untouched.
            if !skipExtraction {
                try db.deletePendingSignalsForConversation(req.conversation_id)
                try db.deleteEpisodesForConversation(req.conversation_id)
            }

            for (i, turn) in req.turns.enumerated() {
                let turnDate = turn.date ?? req.session_date
                let pairs: [(role: String, content: String, index: Int)] = [
                    ("user", turn.user, i * 2),
                    ("assistant", turn.assistant, i * 2 + 1),
                ]
                for (role, content, chunkIndex) in pairs {
                    let tokens = TokenEstimator.estimate(content)
                    try db.insertTranscriptTurn(
                        agentId: canonicalAgentId,
                        conversationId: req.conversation_id,
                        chunkIndex: chunkIndex,
                        role: role,
                        content: content,
                        tokenCount: tokens,
                        createdAt: turnDate
                    )
                    await MemorySearchService.shared.indexTranscriptTurn(
                        TranscriptTurn(
                            conversationId: req.conversation_id,
                            chunkIndex: chunkIndex,
                            role: role,
                            content: content,
                            tokenCount: tokens,
                            agentId: canonicalAgentId
                        ))
                }

                if !skipExtraction {
                    await MemoryService.shared.bufferTurn(
                        userMessage: turn.user,
                        assistantMessage: turn.assistant,
                        agentId: canonicalAgentId,
                        conversationId: req.conversation_id,
                        sessionDate: turnDate
                    )
                }
            }
        } catch {
            MemoryLogger.service.error("memory/ingest: transcript write failed: \(error)")
            return (
                .internalServerError,
                #"{"error":"memory_ingest_failed","message":"Memory transcript write failed"}"#
            )
        }

        // Ingestion means "done with this conversation batch": distill now
        // and report the outcome rather than a blind ok (upstream #1632).
        var distillation: DistillOutcome?
        if !skipExtraction {
            distillation = await MemoryService.shared.flushSessionAndWait(
                agentId: canonicalAgentId,
                conversationId: req.conversation_id,
                sessionDate: req.session_date
            )
        }

        // JSONSerialization so the distillation detail (which can carry an
        // arbitrary error message) is always escaped.
        var payload: [String: Any] = ["status": "ok", "turns_ingested": req.turns.count]
        if let distillation {
            payload["distillation"] = distillation.apiStatus
            if let episodeId = distillation.episodeId { payload["episode_id"] = episodeId }
        }
        let json =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"status\":\"ok\",\"turns_ingested\":\(req.turns.count)}"
        return (.ok, json)
    }
}
