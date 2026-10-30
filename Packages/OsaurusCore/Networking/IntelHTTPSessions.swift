//
//  IntelHTTPSessions.swift
//  osaurus
//
//  The Mac's chat history over HTTP (`W-server-api` stage 5a,
//  docs/SERVER_API_INTEL.md; upstream MOBILE_PROTOCOL §14), on Intel's
//  in-memory `ChatSessionsManager`:
//
//  - `GET /projects` — projects, plugins and workspaces for the history
//    filters.
//  - `GET /sessions` — the history list, with upstream's filters.
//  - `GET /sessions/{id}` — one chat, turns shaped like the Mac's blocks;
//    `PATCH` renames, archives or pins it; `DELETE` deletes it.
//  - `POST /sessions/{id}/truncate` — drop a turn and everything after it.
//  - `GET /sessions/{id}/turns/{turn id}/images/{index}` — one image a turn
//    carries.
//  - `GET /artifacts/{context id}/{filename}` — an image an agent shared.
//
//  All owner-only. Writes need the Secure Channel from a remote owner, and so
//  do reads (the owner-route gate); `/artifacts` refuses a remote caller
//  without the channel even for a read, as upstream.
//
//  Intel's stored turns don't record thinking time, per-call tool durations
//  or the run's start, so `thinking_duration_ms`, `duration_ms` and
//  `requested_at` are null and `ended_at` is the turn's completion time.
//  Intel has no workspaces (deferred), so `workspace_id` is always null and
//  the workspace filter matches nothing, as upstream for a chat without one.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    /// Upstream's routing order: projects, the list, a turn's image (before
    /// the `/sessions/{id}` catch-all), artifacts, truncate, then one chat.
    func routeSessionRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        if head.method == .GET, path == "/projects" {
            serveListProjects(context: context)
        } else if head.method == .GET, path == "/sessions" {
            serveListSessions(context: context, uri: head.uri)
        } else if head.method == .GET, path.hasPrefix("/sessions/"), path.contains("/images/") {
            serveSessionImage(context: context, path: path)
        } else if head.method == .GET, path.hasPrefix("/artifacts/") {
            serveArtifactFile(context: context, path: path)
        } else if head.method == .POST, path.hasPrefix("/sessions/"), path.hasSuffix("/truncate") {
            serveSessionTruncate(context: context, head: head, path: path)
        } else if [.GET, .PATCH, .DELETE].contains(head.method), path.hasPrefix("/sessions/") {
            serveSession(context: context, head: head, path: path)
        } else {
            return false
        }
        return true
    }

    // MARK: - GET /projects

    private struct ProjectDTO: Encodable {
        let id: String
        let name: String
    }

    private struct ProjectsResponse: Encodable {
        let projects: [ProjectDTO]
        /// Installed plugins, for the history's plugin filter.
        let plugins: [ProjectDTO]
        /// Joined router workspaces, for the history's workspace filter.
        /// Always empty on Intel (workspaces are deferred).
        let workspaces: [ProjectDTO]
    }

    /// GET /projects — the user's chat projects, for the history filter
    /// (§14.6). Owner-only.
    private func serveListProjects(context: ChannelHandlerContext) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let (projects, plugins) = await MainActor.run {
                (
                    ProjectManager.shared.projects.map { ProjectDTO(id: $0.id.uuidString, name: $0.name) },
                    PluginManager.shared.plugins
                        .map { ProjectDTO(id: $0.plugin.id, name: PluginDisplayNameResolver.displayName(for: $0.plugin.id)) }
                        .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(
                    ProjectsResponse(projects: projects, plugins: plugins, workspaces: [])))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"projects":[]}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - Session DTOs (upstream)

    /// One row of `GET /sessions`: everything the phone's history list needs
    /// without loading turns.
    struct SessionSummaryDTO: Encodable {
        let id: String
        let title: String
        let created_at: String
        let updated_at: String
        let agent_id: String?
        let selected_model: String?
        let source: String
        let archived: Bool
        let pinned: Bool
        /// `mac` for the user's own chats, `ios` for ones this phone started,
        /// otherwise the source (api, channel, …) — drives the row icon.
        let origin: String
        /// `vision | voice | code | search` badges the Mac shows.
        let capabilities: [String]
        /// Project this chat belongs to, when any.
        let project_id: String?
        /// Plugin that started this chat (`source == "plugin"`).
        let plugin_id: String?
        /// Router workspace this chat was served for, when any.
        let workspace_id: String?
    }

    private struct SessionsResponse: Encodable {
        let sessions: [SessionSummaryDTO]
    }

    /// One turn of `GET /sessions/{id}`, shaped like the Mac's own chat
    /// blocks so a client renders it identically.
    struct SessionTurnDTO: Encodable {
        struct ToolCallDTO: Encodable {
            let call_id: String
            let name: String
            let arguments: String?
            let result: String?
            let duration_ms: Int?
        }
        let id: String
        let role: String
        let content: String
        let thinking: String?
        let thinking_duration_ms: Int?
        /// A document attached to a user turn: what the model was given,
        /// so a client can show and open it.
        struct AttachmentDTO: Encodable {
            let filename: String
            let file_size: Int
            let content: String
        }
        /// An image attached to a turn. Listed, not inlined: a few camera
        /// photos would make the whole chat megabytes to open. The bytes are
        /// at `GET /sessions/{id}/turns/{turn id}/images/{index}`.
        struct ImageDTO: Encodable {
            let index: Int
            let byte_count: Int
        }
        let tool_calls: [ToolCallDTO]?
        let attachment_count: Int
        let attachments: [AttachmentDTO]?
        let images: [ImageDTO]?
        let created_at: String?
        let completed_at: String?
        /// The footer's "Worked for" span, to the millisecond (upstream). Intel
        /// stores no run start, so `requested_at` is null.
        let requested_at: String?
        let ended_at: String?
        let token_count: Int?
    }

    struct SessionDetailDTO: Encodable {
        let id: String
        let title: String
        let created_at: String
        let updated_at: String
        let agent_id: String?
        let selected_model: String?
        let source: String
        let archived: Bool
        let pinned: Bool
        let turns: [SessionTurnDTO]
    }

    private struct SessionPatchRequest: Decodable {
        let title: String?
        let archived: Bool?
        let pinned: Bool?
    }

    private struct SessionTruncateRequest: Decodable {
        let from_turn_id: String
    }

    /// Formatting-only use of a shared formatter: `ISO8601DateFormatter` is
    /// documented as thread-safe for formatting, and this one is never
    /// reconfigured after creation.
    nonisolated(unsafe) private static let sessionDateFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let sessionPreciseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - GET /sessions

    /// GET /sessions[?agent_id=&limit=&archived=&pinned=&origin=&project_id=
    /// &plugin_id=&workspace_id=&q=&capabilities=] — the Mac's chat history
    /// (§14). Owner-only: these are the user's chats.
    private func serveListSessions(context: ChannelHandlerContext, uri: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let query = Self.queryItems(from: uri)
        let agentFilter = query["agent_id"].flatMap { UUID(uuidString: $0) }
        let includeArchived = query["archived"] == "true"
        let pinnedOnly = query["pinned"] == "true"
        // `mac`, `ios`, or a SessionSource raw value (http, plugin, …).
        let originFilter = query["origin"].flatMap { $0.isEmpty ? nil : $0 }
        let projectFilter = query["project_id"].flatMap { UUID(uuidString: $0) }
        let pluginFilter = query["plugin_id"].flatMap { $0.isEmpty ? nil : $0 }
        let workspaceFilter = query["workspace_id"].flatMap { $0.isEmpty ? nil : $0 }
        let search = (query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Multi-select AND, as on the Mac: a chat must have every capability asked for.
        let requiredCapabilities: Set<SessionCapability> = Set(
            (query["capabilities"] ?? "")
                .split(separator: ",")
                .compactMap { SessionCapability(rawValue: String($0)) }
        )
        let limit = query["limit"].flatMap(Int.init).map { max(1, min($0, 500)) } ?? 200

        let eventLoop = context.eventLoop
        runRequestTask {
            let rows: [SessionSummaryDTO] = await MainActor.run {
                // Newest first, as the history list shows them.
                let sessions = ChatSessionsManager.shared.sessions.values.sorted { $0.updatedAt > $1.updatedAt }
                // Like the Mac's history search: title match, or the message
                // bodies contain the query.
                let contentMatches: Set<UUID> =
                    search.isEmpty ? [] : ChatHistoryList.sessionIds(withContentContaining: search)
                func matches(_ session: ChatSessionData) -> Bool {
                    if !includeArchived && session.archived { return false }
                    if pinnedOnly && !session.pinned { return false }
                    if let agentFilter, session.agentId != agentFilter { return false }
                    if let originFilter, Self.origin(of: session) != originFilter { return false }
                    if !requiredCapabilities.isSubset(of: session.capabilities) { return false }
                    if let projectFilter, session.projectId != projectFilter { return false }
                    if let pluginFilter {
                        if session.source != .plugin || session.sourcePluginId != pluginFilter { return false }
                    }
                    // Intel chats carry no workspace.
                    if workspaceFilter != nil { return false }
                    if !search.isEmpty {
                        if !session.title.lowercased().contains(search) && !contentMatches.contains(session.id) {
                            return false
                        }
                    }
                    return true
                }
                return sessions.lazy.filter(matches).prefix(limit).map { Self.summary(for: $0) }
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(SessionsResponse(sessions: rows)))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"sessions":[]}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - POST /sessions/{id}/truncate

    /// Drops a turn and everything after it, so a paired phone can retry a
    /// reply in a Mac chat (§14.8).
    private func serveSessionTruncate(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 3, let sessionId = UUID(uuidString: String(components[1])) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_session_id"}"#)
            return
        }
        guard let request = try? JSONDecoder().decode(SessionTruncateRequest.self, from: requestBodyData()),
            let turnId = UUID(uuidString: request.from_turn_id)
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {from_turn_id}"}"#)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome = await MainActor.run { RemoteSessionContinuation.truncate(sessionId, fromTurnId: turnId) }
            let status: HTTPResponseStatus
            let json: String
            switch outcome {
            case .removed(let count):
                status = .ok
                json = #"{"ok":true,"removed":\#(count)}"#
            case .sessionNotFound:
                status = .notFound
                json = #"{"error":"session_not_found"}"#
            case .turnNotFound:
                status = .notFound
                json = #"{"error":"turn_not_found"}"#
            case .busy:
                status = .conflict
                json = #"{"error":"session_busy"}"#
            }
            self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - GET, PATCH, DELETE /sessions/{id}

    private func serveSession(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 2, let sessionId = UUID(uuidString: String(components[1])) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_session_id"}"#)
            return
        }
        let eventLoop = context.eventLoop

        if head.method == .DELETE {
            runRequestTask {
                let deleted = await MainActor.run { RemoteSessionContinuation.delete(sessionId) }
                self.respondOnLoop(
                    eventLoop, status: deleted ? .ok : .notFound, headers: self.jsonHeaders(),
                    body: deleted ? #"{"ok":true}"# : #"{"error":"session_not_found"}"#)
            }
            return
        }

        if head.method == .PATCH {
            guard let patch = try? JSONDecoder().decode(SessionPatchRequest.self, from: requestBodyData()) else {
                sendResponse(
                    context: context, status: .badRequest, headers: jsonHeaders(),
                    body: #"{"error":"bad_request","message":"Expected {title?, archived?, pinned?}"}"#)
                return
            }
            runRequestTask {
                // Through the manager, as the sidebar does, then every window's
                // open copy — else its next save puts the old values back.
                let applied: Bool = await MainActor.run {
                    let manager = ChatSessionsManager.shared
                    guard manager.session(for: sessionId) != nil else { return false }
                    // Parenthesised so `map` runs on the optional, not on the
                    // string's characters.
                    let title = (patch.title?.trimmingCharacters(in: .whitespacesAndNewlines))
                        .map { String($0.prefix(200)) }
                    if let title, !title.isEmpty { manager.rename(id: sessionId, title: title) }
                    if let archived = patch.archived { manager.setArchived(id: sessionId, archived: archived) }
                    if let pinned = patch.pinned { manager.setPinned(id: sessionId, pinned: pinned) }
                    ChatWindowManager.shared.syncOpenSessions(id: sessionId) { session in
                        if let title, !title.isEmpty { session.title = title }
                        if let archived = patch.archived { session.archived = archived }
                        if let pinned = patch.pinned { session.pinned = pinned }
                    }
                    return true
                }
                self.respondOnLoop(
                    eventLoop, status: applied ? .ok : .notFound, headers: self.jsonHeaders(),
                    body: applied ? #"{"ok":true}"# : #"{"error":"session_not_found"}"#)
            }
            return
        }

        runRequestTask {
            let detail: SessionDetailDTO? = await MainActor.run {
                ChatSessionsManager.shared.session(for: sessionId).map(Self.detail(for:))
            }
            guard let detail else {
                self.respondOnLoop(
                    eventLoop, status: .notFound, headers: self.jsonHeaders(), body: #"{"error":"session_not_found"}"#)
                return
            }
            let json =
                (try? JSONEncoder.osaurusCanonical().encode(detail))
                .map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"encoding_failed"}"#
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    // MARK: - Session DTO mapping (upstream)

    /// `mac` for the user's own chats, `ios` for ones the phone started,
    /// otherwise the source's raw value.
    static func origin(of session: ChatSessionData) -> String {
        if RemoteSessionContinuation.isFromPairedPhone(session) { return "ios" }
        return session.source == .chat ? "mac" : session.source.rawValue
    }

    static func summary(for session: ChatSessionData) -> SessionSummaryDTO {
        SessionSummaryDTO(
            id: session.id.uuidString,
            title: session.title,
            created_at: sessionDateFormatter.string(from: session.createdAt),
            updated_at: sessionDateFormatter.string(from: session.updatedAt),
            agent_id: session.agentId.uuidString,
            selected_model: session.selectedModel,
            source: session.source.rawValue,
            archived: session.archived,
            pinned: session.pinned,
            origin: origin(of: session),
            capabilities: session.capabilities.map(\.rawValue).sorted(),
            project_id: session.projectId?.uuidString,
            plugin_id: session.source == .plugin ? session.sourcePluginId : nil,
            workspace_id: nil
        )
    }

    static func detail(for session: ChatSessionData) -> SessionDetailDTO {
        SessionDetailDTO(
            id: session.id.uuidString,
            title: session.title,
            created_at: sessionDateFormatter.string(from: session.createdAt),
            updated_at: sessionDateFormatter.string(from: session.updatedAt),
            agent_id: session.agentId.uuidString,
            selected_model: session.selectedModel,
            source: session.source.rawValue,
            archived: session.archived,
            pinned: session.pinned,
            turns: session.turns.compactMap(Self.turn(for:))
        )
    }

    /// Maps one stored turn. Tool-result turns are folded into the assistant
    /// turn that called them, so a client sees the Mac's block layout.
    static func turn(for turn: ChatTurnData) -> SessionTurnDTO? {
        guard turn.role != .tool else { return nil }
        let calls: [SessionTurnDTO.ToolCallDTO]? = turn.toolCalls?.map { call in
            SessionTurnDTO.ToolCallDTO(
                call_id: call.id,
                name: call.function.name,
                arguments: call.function.arguments,
                result: turn.toolResults[call.id],
                duration_ms: nil
            )
        }
        // Documents travel with their text (spilled ones are read back from
        // the blob store); a phone away from the Mac can then open them.
        let documents: [SessionTurnDTO.AttachmentDTO] = turn.attachments.compactMap { attachment in
            guard attachment.isDocument, let filename = attachment.filename,
                let content = attachment.loadDocumentContent()
            else { return nil }
            let size: Int
            switch attachment.kind {
            case .document(_, _, let fileSize), .documentRef(_, _, let fileSize): size = fileSize
            default: size = content.utf8.count
            }
            return SessionTurnDTO.AttachmentDTO(filename: filename, file_size: size, content: content)
        }
        // Images by position among the turn's images (attachments, then
        // generated ones), the index the image endpoint takes.
        let images = SessionTurnImages.entries(for: turn).enumerated().map { index, image in
            SessionTurnDTO.ImageDTO(index: index, byte_count: image.byteCount)
        }
        return SessionTurnDTO(
            id: turn.id.uuidString,
            role: turn.role.rawValue,
            content: turn.content,
            thinking: turn.thinking.isEmpty ? nil : turn.thinking,
            thinking_duration_ms: nil,
            tool_calls: (calls?.isEmpty ?? true) ? nil : calls,
            attachment_count: turn.attachments.count,
            attachments: documents.isEmpty ? nil : documents,
            images: images.isEmpty ? nil : images,
            created_at: sessionDateFormatter.string(from: turn.createdAt),
            completed_at: turn.completedAt.map(sessionDateFormatter.string(from:)),
            requested_at: nil,
            ended_at: turn.completedAt.map(sessionPreciseDateFormatter.string(from:)),
            token_count: turn.generationTokenCount
        )
    }

    // MARK: - Images

    /// GET /sessions/{id}/turns/{turn id}/images/{index} — one image a turn
    /// carries, as listed in `GET /sessions/{id}` (`images[].index`).
    /// Owner-only, like the chat it belongs to.
    private func serveSessionImage(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        let components = path.split(separator: "/")
        guard components.count == 6, components[0] == "sessions", components[2] == "turns",
            components[4] == "images",
            let sessionId = UUID(uuidString: String(components[1])),
            let turnId = UUID(uuidString: String(components[3])),
            let index = Int(components[5]), index >= 0
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_image_path"}"#)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let turn = await MainActor.run {
                ChatSessionsManager.shared.session(for: sessionId)?.turns.first { $0.id == turnId }
            }
            let images = turn.map(SessionTurnImages.entries(for:))
            guard let images, images.indices.contains(index), let data = images[index].load() else {
                self.respondOnLoop(
                    eventLoop, status: .notFound, headers: self.jsonHeaders(), body: #"{"error":"image_not_found"}"#)
                return
            }
            self.sendBytesOnLoop(eventLoop, data: data, contentType: Self.imageContentType(forData: data))
        }
    }

    /// GET /artifacts/{context id}/{filename} — an image an agent shared
    /// (`share_artifact`, the `image` tool), as its tool result names it.
    /// Owner-only, and over the Secure Channel only even though it is a
    /// read: a shared image can be anything the agent saw. Nothing but images
    /// in `~/.osaurus/artifacts/` is ever served (§14.12).
    private func serveArtifactFile(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else {
            sendOwnerOnlyForbidden(context: context)
            return
        }
        if sendSecureChannelUpgradeRequiredIfNeeded(context: context) { return }
        let components = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let eventLoop = context.eventLoop
        runRequestTask {
            let file =
                components.count == 3 && components[0] == "artifacts"
                ? SessionTurnImages.artifactImageFile(contextId: components[1], filename: components[2]) : nil
            guard let file, let data = try? Data(contentsOf: file) else {
                self.respondOnLoop(
                    eventLoop, status: .notFound, headers: self.jsonHeaders(), body: #"{"error":"artifact_not_found"}"#)
                return
            }
            self.sendBytesOnLoop(eventLoop, data: data, contentType: SharedArtifact.mimeType(from: file.lastPathComponent))
        }
    }

    /// A binary body, not cached (upstream's image responses).
    private func sendBytesOnLoop(_ eventLoop: EventLoop, data: Data, contentType: String) {
        let stateRef = self.stateRef
        eventLoop.execute {
            guard let context = stateRef.value.contextBox else { return }
            var head = HTTPResponseHead(version: .http1_1, status: .ok)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: String(data.count))
            headers.add(name: "Cache-Control", value: "no-store")
            for (name, value) in stateRef.value.corsHeaders { headers.add(name: name, value: value) }
            head.headers = headers
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    /// The image type from its first bytes: attachments carry no filename.
    static func imageContentType(forData data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], bytes[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        if bytes.count >= 12, bytes[4 ..< 8] == [0x66, 0x74, 0x79, 0x70] { return "image/heic" }
        return "application/octet-stream"
    }

    /// Parses `?a=b&c=d` from a request URI.
    static func queryItems(from uri: String) -> [String: String] {
        guard let range = uri.firstIndex(of: "?") else { return [:] }
        var result: [String: String] = [:]
        for pair in uri[uri.index(after: range)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            result[String(name)] = value.removingPercentEncoding ?? value
        }
        return result
    }
}
