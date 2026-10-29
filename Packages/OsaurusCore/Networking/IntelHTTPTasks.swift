//
//  IntelHTTPTasks.swift
//  osaurus
//
//  Background dispatch over the API (`W-server-api` stage 4b,
//  docs/SERVER_API_INTEL.md): `POST /agents/{id}/dispatch`,
//  `GET /tasks/{id}`, `DELETE /tasks/{id}`, `POST /tasks/{id}/clarify`.
//  Upstream's handlers, `DispatchTaskOwnership` and session-key scoping.
//
//  Intel differences: no workspace-minted keys or workspace audit log
//  (workspaces are deferred), so the workspace refusal and the audit
//  records are left out. A loopback dispatch to the built-in agent sets
//  Intel's `allowsBuiltInAgent`, the flag Intel's background runner uses
//  where upstream relaxes its guard for loopback callers.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    // MARK: - Upstream helpers

    nonisolated static func shouldBindExternalSurfaceForDispatch(isLoopback: Bool) -> Bool {
        !isLoopback
    }

    /// Scopes a caller-supplied reattachment key to the credential that
    /// sent it, so one key's task can't be resumed by another (upstream).
    static func dispatchSessionKey(_ supplied: String?, audience: String?, keyNonce: String?) -> String? {
        guard let supplied else { return nil }
        guard let audience else { return supplied }
        guard let keyNonce, !keyNonce.isEmpty else { return nil }
        // Encode a tuple: separators in user input cannot collide with scope.
        let data = try? JSONEncoder().encode([audience.lowercased(), keyNonce, supplied])
        return data.map { "credential:" + $0.base64EncodedString() }
    }

    /// Which access-key audience created each HTTP-dispatched background task,
    /// so `/tasks/{id}` (status / cancel / clarify) can be confined to the
    /// key that created the task. Only tasks created by an *agent-scoped* key
    /// are recorded; master-scoped and loopback callers are unrestricted and
    /// never recorded. Bounded FIFO so a chatty peer cannot grow it unbounded.
    /// (Upstream, verbatim.)
    final class DispatchTaskOwnership: @unchecked Sendable {
        static let shared = DispatchTaskOwnership(
            fileURL: OsaurusPaths.workspaces().appendingPathComponent("dispatch-owners.json")
        )

        private let lock = NSLock()
        private struct Owner: Codable {
            let audience: String
            let keyNonce: String
        }
        private var owners: [UUID: Owner] = [:]
        private var order: [UUID] = []
        private let capacity: Int
        private let fileURL: URL?

        init(capacity: Int = 4096, fileURL: URL? = nil) {
            self.capacity = max(1, capacity)
            self.fileURL = fileURL
            if let fileURL, let data = try? Data(contentsOf: fileURL),
                let saved = try? JSONDecoder().decode([UUID: Owner].self, from: data)
            {
                for id in saved.keys.sorted(by: { $0.uuidString < $1.uuidString }).suffix(self.capacity) {
                    owners[id] = saved[id]
                    order.append(id)
                }
            }
        }

        func record(taskId: UUID, audience: String, keyNonce: String) {
            lock.lock()
            defer { lock.unlock() }
            guard !keyNonce.isEmpty else { return }
            if owners.updateValue(Owner(audience: audience.lowercased(), keyNonce: keyNonce), forKey: taskId) == nil {
                order.append(taskId)
                while order.count > capacity {
                    let evicted = order.removeFirst()
                    owners.removeValue(forKey: evicted)
                }
            }
            persistLocked()
        }

        func owner(of taskId: UUID) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return owners[taskId]?.audience
        }

        /// `nil` when the caller may act on the task. A caller with no
        /// recorded audience or a master-scoped key is unrestricted; an
        /// agent-scoped key must have created the task itself.
        func rejection(
            taskId: UUID,
            authedAudience: String?,
            authedScopeIsMaster: Bool,
            keyNonce: String? = nil
        ) -> (code: String, message: String)? {
            guard let aud = authedAudience?.lowercased(), !authedScopeIsMaster else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard let keyNonce, !keyNonce.isEmpty,
                let owner = owners[taskId], owner.audience == aud, owner.keyNonce == keyNonce
            else {
                return (
                    "agent_scope_denied",
                    "This access key did not create the requested task."
                )
            }
            return nil
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            owners.removeAll()
            order.removeAll()
            persistLocked()
        }

        private func persistLocked() {
            guard let fileURL else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(owners).write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                // A missing persisted owner fails closed after relaunch.
                NSLog("[Osaurus] Could not persist remote task ownership: %@", String(describing: error))
            }
        }
    }

    // MARK: - Routing (upstream's order)

    /// Routes `/tasks/…`; false when the request isn't one of these.
    func routeTaskRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        guard path.hasPrefix("/tasks/") else { return false }
        if head.method == .GET, !path.hasSuffix("/clarify") {
            serveTaskStatus(context: context, path: path)
        } else if head.method == .DELETE {
            serveTaskCancel(context: context, path: path)
        } else if head.method == .POST, path.hasSuffix("/clarify") {
            serveTaskClarify(context: context, path: path)
        } else {
            return false
        }
        return true
    }

    private func sendJSONError(
        context: ChannelHandlerContext, status: HTTPResponseStatus, code: String, message: String
    ) {
        sendResponse(
            context: context, status: status, headers: jsonHeaders(),
            body: Self.jsonObjectString(["error": code, "message": message]))
    }

    // MARK: - POST /agents/{id}/dispatch

    func serveDispatch(context: ChannelHandlerContext, path: String) {
        // Same hard-require as `/agents/{id}/run`: remote dispatch must be
        // end-to-end encrypted.
        if sendSecureChannelUpgradeRequiredIfNeeded(context: context) { return }

        let components = path.split(separator: "/")
        guard components.count >= 3 else {
            sendJSONError(
                context: context, status: .badRequest, code: "invalid_agent",
                message: "Missing agent identifier in path")
            return
        }
        let agentIdentifier = String(components[1])
        let data = requestBodyData()

        // Loopback callers may dispatch to the built-in agent (upstream: App
        // Intents drive it as a background task); remote callers may not.
        let isLoopback = isLoopbackConnection(context)
        let authedAudience = stateRef.value.authedAudience
        let authedScopeIsMaster = stateRef.value.authedScopeIsMaster
        let authedKeyNonce: String? = isLoopback ? nil : inboundConnectionInfo()?.accessKeyId
        let eventLoop = context.eventLoop

        runRequestTask {
            func reply(_ status: HTTPResponseStatus, _ body: String) {
                self.respondOnLoop(eventLoop, status: status, headers: self.jsonHeaders(), body: body)
            }
            guard let agentId = await MainActor.run(body: { AgentManager.shared.resolveAgentId(agentIdentifier) })
            else {
                reply(.notFound, #"{"error":"agent_not_found","message":"No agent found for the given identifier"}"#)
                return
            }
            // Confine agent-scoped keys to their own agent.
            if let rejection = Self.agentScopeRejection(
                forAgentId: agentId, authedAudience: authedAudience, authedScopeIsMaster: authedScopeIsMaster)
            {
                reply(.forbidden, Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
                return
            }
            if !isLoopback,
                let rejection = Agent.rejectBuiltInForExternalSurface(agentId, source: "http/agents/dispatch")
            {
                reply(.forbidden, Self.jsonObjectString(["error": rejection.code, "message": rejection.message]))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let prompt = json["prompt"] as? String
            else {
                reply(.badRequest, #"{"error":"invalid_request","message":"Missing required field: prompt"}"#)
                return
            }
            // An empty prompt would leave the task running until the watchdog.
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply(.badRequest, #"{"error":"invalid_request","message":"Prompt is empty"}"#)
                return
            }

            let suppliedSessionKey = json["external_session_key"] as? String ?? json["session_id"] as? String
            let external = Self.shouldBindExternalSurfaceForDispatch(isLoopback: isLoopback)
            let request = DispatchRequest(
                id: UUID(),
                prompt: prompt,
                agentId: agentId,
                title: json["title"] as? String,
                showToast: true,
                source: .http,
                externalSessionKey: Self.dispatchSessionKey(
                    suppliedSessionKey,
                    audience: authedScopeIsMaster ? nil : authedAudience,
                    keyNonce: authedKeyNonce),
                allowsBuiltInAgent: isLoopback,
                externalSurface: external
            )
            let handle: DispatchHandle?
            if external {
                handle = await ChatExecutionContext.$isExternalSurface.withValue(true) {
                    await TaskDispatcher.shared.dispatch(request)
                }
            } else {
                handle = await TaskDispatcher.shared.dispatch(request)
            }
            guard let handle else {
                reply(
                    .tooManyRequests,
                    #"{"error":"task_limit_reached","message":"Maximum concurrent background tasks reached"}"#)
                return
            }
            // The resolved id: a matching `external_session_key` reattaches
            // to the existing session's task.
            if let authedAudience, !authedScopeIsMaster, let authedKeyNonce {
                DispatchTaskOwnership.shared.record(
                    taskId: handle.id, audience: authedAudience, keyNonce: authedKeyNonce)
            }
            let id = handle.id.uuidString
            reply(.accepted, Self.jsonObjectString(["id": id, "status": "running", "poll_url": "/v1/tasks/\(id)"]))
        }
    }

    // MARK: - /tasks/{id}

    /// Confines agent-scoped keys to the tasks they created (upstream).
    private func sendTaskOwnershipRejectionIfNeeded(taskId: UUID, context: ChannelHandlerContext) -> Bool {
        guard
            let rejection = DispatchTaskOwnership.shared.rejection(
                taskId: taskId,
                authedAudience: stateRef.value.authedAudience,
                authedScopeIsMaster: stateRef.value.authedScopeIsMaster,
                keyNonce: inboundConnectionInfo()?.accessKeyId
            )
        else { return false }
        sendJSONError(context: context, status: .forbidden, code: rejection.code, message: rejection.message)
        return true
    }

    private func taskId(in path: String, minimumComponents: Int, context: ChannelHandlerContext) -> UUID? {
        let components = path.split(separator: "/")
        guard components.count >= minimumComponents, let taskId = UUID(uuidString: String(components[1])) else {
            sendJSONError(
                context: context, status: .badRequest, code: "invalid_task_id", message: "Invalid task UUID in path")
            return nil
        }
        return sendTaskOwnershipRejectionIfNeeded(taskId: taskId, context: context) ? nil : taskId
    }

    func serveTaskStatus(context: ChannelHandlerContext, path: String) {
        guard let taskId = taskId(in: path, minimumComponents: 2, context: context) else { return }
        let eventLoop = context.eventLoop
        runRequestTask {
            let (body, found) = await MainActor.run { () -> (String, Bool) in
                guard let state = BackgroundTaskManager.shared.taskState(for: taskId) else {
                    return (#"{"error":"not_found","message":"Task not found"}"#, false)
                }
                return (PluginHostContext.serializeTaskState(id: taskId, state: state), true)
            }
            self.respondOnLoop(eventLoop, status: found ? .ok : .notFound, headers: self.jsonHeaders(), body: body)
        }
    }

    func serveTaskCancel(context: ChannelHandlerContext, path: String) {
        guard let taskId = taskId(in: path, minimumComponents: 2, context: context) else { return }
        let eventLoop = context.eventLoop
        let cors = stateRef.value.corsHeaders
        runRequestTask {
            await MainActor.run { BackgroundTaskManager.shared.cancelTask(taskId) }
            self.respondOnLoop(eventLoop, status: .noContent, headers: cors, body: "")
        }
    }

    /// Clarifications happen inline in the chat window now; the route stays
    /// so old callers get 410 rather than 404 (upstream).
    func serveTaskClarify(context: ChannelHandlerContext, path: String) {
        guard taskId(in: path, minimumComponents: 3, context: context) != nil else { return }
        guard let json = try? JSONSerialization.jsonObject(with: requestBodyData()) as? [String: Any],
            json["response"] is String
        else {
            sendJSONError(
                context: context, status: .badRequest, code: "invalid_request",
                message: "Missing required field: response")
            return
        }
        sendResponse(
            context: context, status: .gone, headers: jsonHeaders(),
            body:
                #"{"error":"not_supported","message":"clarify is no longer accepted over HTTP; the agent surfaces clarifications inline in the chat window"}"#
        )
    }
}
