//
//  IntelHTTPAgents.swift
//  osaurus
//
//  Agent management over the API (`W-server-api` stage 4a,
//  docs/SERVER_API_INTEL.md): `GET /agents`, `GET /agents/{id}`,
//  `POST /agents`, `PATCH|DELETE /agents/{id}`, `PUT /agents/{id}/model`,
//  `GET /agents/{id}/avatar`, `GET /agents/{id}/tools`,
//  `POST /agents/{id}/tools/preset`, `PATCH /agents/{id}/tools/{name}`.
//  Upstream's handlers and DTOs (docs/MOBILE_PROTOCOL.md §13–§14, §17);
//  edits go through upstream's `PhoneAgentEditing`.
//
//  Intel differences: no phone connect identity yet (`W-identity-mobile`),
//  so the built-in agent lists no address; the relay URL follows Intel's
//  relay manager (a stub: always off); the Orchestrator sends no
//  configure-oriented quick actions (Intel's chat shows the ordinary ones);
//  and image support is judged from Intel's picker items (remote models
//  accept images unless they are embedding models).
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    // MARK: - Routing (upstream's order)

    /// Routes `/agents…`; false when the request isn't one of these.
    func routeAgentRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        let method = head.method
        let isAgentPath = path.hasPrefix("/agents/")
        if method == .PUT, isAgentPath, path.hasSuffix("/model") {
            serveSetAgentModel(context: context, head: head, path: path)
        } else if method == .POST, path == "/agents" {
            serveCreateAgent(context: context, head: head)
        } else if method == .GET, path == "/agents" {
            serveListAgents(context: context)
        } else if method == .POST, isAgentPath, path.hasSuffix("/tools/preset") {
            serveAgentToolPreset(context: context, head: head, path: path)
        } else if method == .PATCH || method == .DELETE, isAgentPath, path.split(separator: "/").count == 2 {
            serveEditAgent(context: context, head: head, path: path)
        } else if method == .PATCH, isAgentPath, path.contains("/tools/") {
            serveUpdateAgentTool(context: context, head: head, path: path)
        } else if method == .GET, isAgentPath, path.hasSuffix("/tools") {
            serveAgentTools(context: context, path: path)
        } else if method == .GET, isAgentPath, path.hasSuffix("/avatar") {
            serveAgentAvatar(context: context, path: path)
        } else if method == .GET, isAgentPath {
            serveGetAgent(context: context, path: path)
        } else if method == .POST, isAgentPath, path.hasSuffix("/dispatch") {
            serveDispatch(context: context, path: path)
        } else {
            return false
        }
        return true
    }

    // MARK: - DTOs (upstream)

    struct AgentListItem: Codable {
        let id: String
        let name: String
        let description: String
        let generated_description: String?
        let avatar: String?
        let chat_quick_actions: [AgentQuickAction]?
        let default_model: String?
        let effective_model: String?
        let supports_thinking: Bool
        let supports_vision: Bool
        let is_built_in: Bool
        let memory_entry_count: Int
        let created_at: String
        let updated_at: String
        let address: String?
        let relay_url: String?
        let custom_avatar: Bool?
        var system_prompt: String?
        var settings: PhoneAgentEditing.Settings? = nil
    }

    struct AgentListResponse: Codable {
        let agents: [AgentListItem]
        var features: [String] = HTTPHandler.connectFeatures
    }

    /// `session_create`: a run may start a chat with `osaurus_create_session`
    /// (upstream). Intel advertises nothing until its runs can do that.
    static let connectFeatures: [String] = []

    /// An agent's own Action Bar, or nil for the client's chat defaults.
    static func clientQuickActions(for agent: Agent) -> [AgentQuickAction]? {
        agent.chatQuickActions
    }

    /// Relay base URL for an agent address (upstream
    /// `RelayTunnelManager.publicURL(forAddress:)`).
    static func relayPublicURL(forAddress address: String) -> String {
        "https://\(address.lowercased()).agent.osaurus.ai"
    }

    /// Upstream `ChatSession.modelSupportsImages`, on Intel's picker items.
    static func modelSupportsImages(modelId: String, pickerItems: [ModelPickerItem]) -> Bool {
        guard let option = pickerItems.first(where: { $0.id == modelId }) else { return false }
        if option.mediaModel?.kind == .imageToVideo { return true }
        if option.isVLM { return true }
        if case .remote = option.source { return !ModelPickerItem.isLikelyEmbeddingOrRerankerID(option.id) }
        return false
    }

    /// `/agents/{id}`-style path component: a UUID or the agent's address.
    static func resolveAgentId(_ component: Substring) -> UUID? {
        UUID(uuidString: String(component)) ?? AgentIdentityRegistry.shared.agentId(forAddress: String(component))
    }

    @MainActor
    private static func agentListItem(
        _ agent: Agent, memoryCount: Int, pickerItems: [ModelPickerItem], formatter: ISO8601DateFormatter
    ) -> AgentListItem {
        let modelId = AgentManager.shared.effectiveModel(for: agent.id) ?? agent.defaultModel
        let relayOn = RelayTunnelManager.shared.isTunnelEnabled(for: agent.id)
        return AgentListItem(
            id: agent.id.uuidString,
            name: agent.name,
            description: agent.description,
            generated_description: agent.generatedDescription,
            avatar: agent.avatar,
            chat_quick_actions: clientQuickActions(for: agent),
            default_model: agent.defaultModel,
            effective_model: modelId,
            supports_thinking: modelId.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption } != nil,
            supports_vision: modelId.map { modelSupportsImages(modelId: $0, pickerItems: pickerItems) } ?? false,
            is_built_in: agent.isBuiltIn,
            memory_entry_count: memoryCount,
            created_at: formatter.string(from: agent.createdAt),
            updated_at: formatter.string(from: agent.updatedAt),
            address: agent.id == Agent.defaultId ? nil : agent.agentAddress?.lowercased(),
            relay_url: relayOn ? agent.agentAddress.map(relayPublicURL(forAddress:)) : nil,
            custom_avatar: agent.customAvatarURL != nil ? true : nil,
            system_prompt: nil
        )
    }

    private static func encoded(_ value: some Encodable, fallback: String) -> String {
        (try? JSONEncoder.osaurusCanonical().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? fallback
    }

    // MARK: - GET /agents, GET /agents/{id}

    func serveListAgents(context: ChannelHandlerContext) {
        let ownerCaller = callerOwnsThisMac(context)
        let eventLoop = context.eventLoop
        runRequestTask {
            // Built-in agents (the Orchestrator) are listed for the owner only.
            var memoryCounts: [String: Int] = [:]
            let db = MemoryDatabase.shared
            if db.isOpen {
                for (agentId, count) in (try? db.agentIdsWithPinnedFacts()) ?? [] {
                    memoryCounts[agentId, default: 0] += count
                }
                for (agentId, count) in (try? db.agentIdsWithEpisodes()) ?? [] {
                    memoryCounts[agentId, default: 0] += count
                }
            }
            let counts = memoryCounts
            let items: [AgentListItem] = await MainActor.run {
                let pickerItems = ModelPickerItemCache.shared.items
                let formatter = ISO8601DateFormatter()
                return AgentManager.shared.agents.filter { ownerCaller || !$0.isBuiltIn }.map {
                    Self.agentListItem(
                        $0, memoryCount: counts[$0.id.uuidString] ?? 0, pickerItems: pickerItems, formatter: formatter)
                }
            }
            let json = Self.encoded(AgentListResponse(agents: items), fallback: #"{"agents":[]}"#)
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    func serveGetAgent(context: ChannelHandlerContext, path: String) {
        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "agents", let agentId = Self.resolveAgentId(components[1]) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#)
            return
        }
        let ownerCaller = callerOwnsThisMac(context)
        // An agent-scoped key reads only its own agent (upstream).
        if let rejection = agentScopeRejection(forAgentId: agentId) {
            sendResponse(
                context: context, status: .forbidden, headers: jsonHeaders(),
                body: Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let memoryCount: Int = {
                let db = MemoryDatabase.shared
                guard db.isOpen else { return 0 }
                return ((try? db.episodeCount(agentId: agentId.uuidString)) ?? 0)
                    + ((try? db.pinnedFactCount(agentId: agentId.uuidString)) ?? 0)
            }()
            let item: AgentListItem? = await MainActor.run {
                // Built-ins are 404 to anyone but the owner (upstream).
                guard let agent = AgentManager.shared.agent(for: agentId), ownerCaller || !agent.isBuiltIn else {
                    return nil
                }
                var item = Self.agentListItem(
                    agent, memoryCount: memoryCount, pickerItems: ModelPickerItemCache.shared.items,
                    formatter: ISO8601DateFormatter())
                if ownerCaller {
                    item.system_prompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
                    item.settings = PhoneAgentEditing.settings(for: agent)
                }
                return item
            }
            guard let item else {
                self.respondOnLoop(
                    eventLoop, status: .notFound, headers: self.jsonHeaders(),
                    body: #"{"error":"agent_not_found","message":"No agent found for the given ID"}"#)
                return
            }
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: Self.encoded(item, fallback: "{}"))
        }
    }

    // MARK: - POST /agents

    func serveCreateAgent(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        if requiresOwnerChannel(head: head, context: context) { return }
        struct CreateAgentRequest: Decodable {
            let name: String
            let description: String?
            let system_prompt: String?
            let model: String?
        }
        guard let request = try? JSONDecoder().decode(CreateAgentRequest.self, from: requestBodyData()) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {name, description?, system_prompt?, model?}"}"#)
            return
        }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"name must not be empty"}"#)
            return
        }
        let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let systemPrompt = request.system_prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventLoop = context.eventLoop
        runRequestTask {
            let body: String = await MainActor.run {
                let agent = AgentManager.shared.createFromPhone(
                    name: String(name.prefix(80)), description: description, systemPrompt: systemPrompt,
                    defaultModel: (model?.isEmpty ?? true) ? nil : model)
                return Self.jsonObjectString(["id": agent.id.uuidString, "name": agent.name])
            }
            self.respondOnLoop(eventLoop, status: .created, headers: self.jsonHeaders(), body: body)
        }
    }

    // MARK: - PATCH / DELETE /agents/{id}

    static func agentEditFailure(_ error: PhoneAgentEditing.EditError) -> (status: HTTPResponseStatus, json: String) {
        let reply = error.reply
        return (HTTPResponseStatus(statusCode: reply.status), jsonObjectString(["error": reply.code, "message": reply.message]))
    }

    func serveEditAgent(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 2, let agentId = UUID(uuidString: String(components[1])) else {
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_agent_id"}"#)
            return
        }
        let body = requestBodyData()
        let isDelete = head.method == .DELETE
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome: (status: HTTPResponseStatus, json: String)
            do {
                if isDelete {
                    // No Secure Channel on Intel yet, so no connection agent
                    // to protect (`connectedThrough`).
                    let deleted = try await PhoneAgentEditing.delete(agentId)
                    outcome =
                        deleted
                        ? (.ok, #"{"ok":true}"#)
                        : (.internalServerError, Self.jsonObjectString(["error": "delete_failed", "message": "Couldn't delete the agent."]))
                } else {
                    let patch = try PhoneAgentEditing.patch(from: body)
                    try await PhoneAgentEditing.apply(patch, to: agentId)
                    outcome = (.ok, #"{"ok":true}"#)
                }
            } catch let error as PhoneAgentEditing.EditError {
                outcome = Self.agentEditFailure(error)
            } catch {
                outcome = (.internalServerError, Self.jsonObjectString(["error": "edit_failed", "message": error.localizedDescription]))
            }
            self.respondOnLoop(eventLoop, status: outcome.status, headers: self.jsonHeaders(), body: outcome.json)
        }
    }

    // MARK: - PUT /agents/{id}/model

    func serveSetAgentModel(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == "agents", let agentId = Self.resolveAgentId(components[1]) else {
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_agent_id"}"#)
            return
        }
        struct SetAgentModelRequest: Decodable { let model: String? }
        guard let request = try? JSONDecoder().decode(SetAgentModelRequest.self, from: requestBodyData()) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {\"model\": \"…\"}"}"#)
            return
        }
        let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (model?.isEmpty ?? true) ? nil : model
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome: (HTTPResponseStatus, String) = await MainActor.run {
                // The Orchestrator may be retuned; other built-ins stay read-only.
                guard let agent = AgentManager.shared.agent(for: agentId),
                    !agent.isBuiltIn || agent.id == Agent.defaultId
                else { return (.notFound, #"{"error":"agent_not_found"}"#) }
                AgentManager.shared.updateDefaultModel(for: agentId, model: normalized)
                let effective = AgentManager.shared.effectiveModel(for: agentId) ?? ""
                return (.ok, Self.jsonObjectString(["ok": true, "effective_model": effective]))
            }
            self.respondOnLoop(eventLoop, status: outcome.0, headers: self.jsonHeaders(), body: outcome.1)
        }
    }

    // MARK: - GET /agents/{id}/avatar

    static func imageContentType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/jpeg"
        }
    }

    func serveAgentAvatar(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == "agents", let agentId = Self.resolveAgentId(components[1]) else {
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_agent_id"}"#)
            return
        }
        let eventLoop = context.eventLoop
        let stateRef = self.stateRef
        runRequestTask {
            let url = await MainActor.run { AgentManager.shared.agent(for: agentId)?.customAvatarURL }
            guard let url, let data = try? Data(contentsOf: url) else {
                self.respondOnLoop(eventLoop, status: .notFound, headers: self.jsonHeaders(), body: #"{"error":"no_custom_avatar"}"#)
                return
            }
            let contentType = Self.imageContentType(forPathExtension: url.pathExtension)
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
                context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?)), promise: nil)
            }
        }
    }

    // MARK: - Tools (upstream §14.4, §14.7, §14.12)

    struct AgentToolDTO: Encodable {
        let name: String
        let description: String
        let enabled: Bool
        /// `auto | ask | deny`
        let policy: String
        /// False when running it would raise an approval card on the Mac, or
        /// the surface blocks it outright.
        let remote_safe: Bool
        let blocked_by: [String]?
        let built_in: Bool
        let agent_enabled: Bool
    }

    struct AgentToolsResponse: Encodable {
        let tools: [AgentToolDTO]
    }

    struct ToolPatch: Equatable {
        let enabled: Bool?
        let policy: ToolPermissionPolicy?
        let agentEnabled: Bool?
    }

    /// Parses a §14.7 body; nil when it carries nothing or anything invalid.
    static func toolPatch(from data: Data) -> ToolPatch? {
        struct Request: Decodable {
            let enabled: Bool?
            let policy: String?
            let agent_enabled: Bool?
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
            request.enabled != nil || request.policy != nil || request.agent_enabled != nil
        else { return nil }
        var policy: ToolPermissionPolicy?
        if let raw = request.policy {
            guard let parsed = ToolPermissionPolicy(rawValue: raw) else { return nil }
            policy = parsed
        }
        return ToolPatch(enabled: request.enabled, policy: policy, agentEnabled: request.agent_enabled)
    }

    @MainActor
    static func agentToolDTO(for entry: ToolRegistry.ToolEntry, agent: Agent?) -> AgentToolDTO {
        let registry = ToolRegistry.shared
        let info = registry.policyInfo(for: entry.name)
        let policy = info?.effectivePolicy ?? .auto
        let missingGrants = (info?.grantsByRequirement ?? [:]).filter { !$0.value }.map(\.key)
        let missingSystem = (info?.systemPermissionStates ?? [:]).filter { !$0.value }.map(\.key.rawValue)
        let blocked = (missingGrants + missingSystem).sorted()
        // Remote callers run as an external surface.
        let deniedRemotely = ToolRegistry.externallyDeniedToolNames.contains(entry.name)
        return AgentToolDTO(
            name: entry.name,
            description: entry.description,
            enabled: entry.enabled,
            policy: policy.rawValue,
            remote_safe: policy == .auto && blocked.isEmpty && !deniedRemotely && entry.enabled,
            blocked_by: blocked.isEmpty ? nil : blocked,
            built_in: PhoneAgentEditing.isBuiltInTool(entry.name),
            agent_enabled: agent.map { PhoneAgentEditing.agentHasTool(entry.name, agent: $0) } ?? true
        )
    }

    @MainActor
    private static func toolsJSON(for agentId: UUID?) -> String {
        let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }
        let tools = ToolRegistry.shared.listTools().map { agentToolDTO(for: $0, agent: agent) }
        return encoded(AgentToolsResponse(tools: tools), fallback: #"{"tools":[]}"#)
    }

    func serveAgentTools(context: ChannelHandlerContext, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        let agentId = path.split(separator: "/").dropFirst().first.flatMap { UUID(uuidString: String($0)) }
        let eventLoop = context.eventLoop
        runRequestTask {
            let json = await MainActor.run { Self.toolsJSON(for: agentId) }
            self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: json)
        }
    }

    func serveAgentToolPreset(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        if requiresOwnerChannel(head: head, context: context) { return }
        struct PresetRequest: Decodable { let preset: String }
        let components = path.split(separator: "/")
        guard components.count == 4, let agentId = UUID(uuidString: String(components[1])),
            let raw = try? JSONDecoder().decode(PresetRequest.self, from: requestBodyData()),
            let preset = PhoneAgentEditing.ToolPreset(rawValue: raw.preset)
        else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {preset: all, essential or none}"}"#)
            return
        }
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome: (status: HTTPResponseStatus, json: String) = await MainActor.run {
                do {
                    try PhoneAgentEditing.apply(preset, to: agentId)
                } catch let error as PhoneAgentEditing.EditError {
                    return Self.agentEditFailure(error)
                } catch {
                    return Self.agentEditFailure(.notEditable)
                }
                return (.ok, Self.toolsJSON(for: agentId))
            }
            self.respondOnLoop(eventLoop, status: outcome.status, headers: self.jsonHeaders(), body: outcome.json)
        }
    }

    func serveUpdateAgentTool(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) {
        guard callerOwnsThisMac(context) else { return sendOwnerOnlyForbidden(context: context) }
        if requiresOwnerChannel(head: head, context: context) { return }
        let components = path.split(separator: "/")
        guard components.count == 4, components[0] == "agents", components[2] == "tools",
            let toolName = String(components[3]).removingPercentEncoding, !toolName.isEmpty
        else {
            sendResponse(context: context, status: .badRequest, headers: jsonHeaders(), body: #"{"error":"invalid_tool"}"#)
            return
        }
        guard let patch = Self.toolPatch(from: requestBodyData()) else {
            sendResponse(
                context: context, status: .badRequest, headers: jsonHeaders(),
                body: #"{"error":"bad_request","message":"Expected {enabled?, agent_enabled?, policy?}"}"#)
            return
        }
        let agentId = UUID(uuidString: String(components[1]))
        let eventLoop = context.eventLoop
        runRequestTask {
            let outcome: (HTTPResponseStatus, String) = await MainActor.run {
                let registry = ToolRegistry.shared
                guard registry.entry(named: toolName) != nil else { return (.notFound, #"{"error":"tool_not_found"}"#) }
                if let agentEnabled = patch.agentEnabled {
                    guard let agentId else { return (.badRequest, #"{"error":"invalid_agent_id"}"#) }
                    do {
                        try PhoneAgentEditing.setTool(toolName, enabled: agentEnabled, for: agentId)
                    } catch {
                        let failure = Self.agentEditFailure(error as? PhoneAgentEditing.EditError ?? .notEditable)
                        return (failure.status, failure.json)
                    }
                }
                // Only after the agent's own change, which can still be refused.
                if let enabled = patch.enabled { registry.setEnabled(enabled, for: toolName) }
                if let policy = patch.policy { registry.setPolicy(policy, for: toolName) }
                guard let entry = registry.entry(named: toolName) else {
                    return (.notFound, #"{"error":"tool_not_found"}"#)
                }
                let agent = agentId.flatMap { AgentManager.shared.agent(for: $0) }
                return (.ok, Self.encoded(Self.agentToolDTO(for: entry, agent: agent), fallback: #"{"ok":true}"#))
            }
            self.respondOnLoop(eventLoop, status: outcome.0, headers: self.jsonHeaders(), body: outcome.1)
        }
    }
}
