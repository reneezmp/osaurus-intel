//
//  IntelHTTPMCP.swift
//  osaurus
//
//  Minimal MCP-style endpoints on the API port (`W-server-api` stage 3,
//  docs/SERVER_API_INTEL.md): `GET /mcp/health`, `GET /mcp/tools`,
//  `POST /mcp/call`. They back the `osaurus mcp` stdio proxy. Upstream's
//  handlers, minus the harness agent-token branches (`W-harness-runtimes`).
//
//  External callers never see or run the app-only tool classes
//  (`ToolRegistry.externallyDeniedToolNames`), and a call runs as an
//  external surface: `.ask` tools are refused rather than prompting.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func serveMCPHealth(context: ChannelHandlerContext) {
        sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: #"{"status":"ok"}"#)
    }

    func serveMCPListTools(context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        runRequestTask {
            let entries = await MainActor.run {
                ToolRegistry.shared.listTools().filter {
                    ExternalMCPToolPolicy.isToolVisibleToExternalMCP(name: $0.name, enabled: $0.enabled)
                }
            }
            let tools = entries.map { entry -> [String: Any] in
                var object: [String: Any] = ["name": entry.name, "description": entry.description]
                if let parameters = entry.parameters { object["inputSchema"] = parameters.anyValue }
                return object
            }
            // Sorted keys: external MCP clients may byte-compare schemas.
            let data = (try? JSONSerialization.data(withJSONObject: ["tools": tools], options: .osaurusCanonical))
                ?? Data("{}".utf8)
            self.respondOnLoop(
                eventLoop, status: .ok, headers: self.jsonHeaders(), body: String(decoding: data, as: UTF8.self))
        }
    }

    static func mcpResultBody(_ text: String, isError: Bool) -> String {
        let payload: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: .osaurusCanonical))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func serveMCPCallTool(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let data = requestBodyData()
        let requestBodyString = String(decoding: data, as: UTF8.self)
        let startTime = stateRef.value.requestStartedAt ?? Date()
        let userAgent = head.headers.first(name: "User-Agent")

        func refuse(_ code: String, _ message: String) {
            sendResponse(
                context: context, status: .forbidden, headers: jsonHeaders(),
                body: #"{"error":"\#(code)","message":"\#(Self.escapeJSONString(message))"}"#)
        }

        // A PRESENT agent header must name a valid custom agent (a malformed
        // value used to skip the guard upstream). Unattributed calls run
        // with no agent bound, so they never act as the built-in agent.
        if let header = head.headers.first(name: "X-Osaurus-Agent-Id") {
            guard let agentUUID = UUID(uuidString: header) else {
                refuse("invalid_agent", "X-Osaurus-Agent-Id must be a valid agent UUID.")
                return
            }
            if let rejection = Agent.rejectBuiltInForExternalSurface(agentUUID, source: "http/mcp/call") {
                refuse(rejection.code, rejection.message)
                return
            }
        }

        struct CallBody: Decodable {
            let name: String
            let arguments: [String: JSONValue]?
        }
        guard let req = try? JSONDecoder().decode(CallBody.self, from: data) else {
            sendResponse(context: context, status: .badRequest, headers: textHeaders(), body: "Invalid request format")
            return
        }
        let argsJSON = (try? JSONEncoder.osaurusCanonical().encode(req.arguments ?? [:]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        if let message = ExternalMCPToolPolicy.externalMCPDenialMessage(for: req.name) {
            refuse("tool_not_exposable", message)
            return
        }

        stateRef.value.routeLogsItself = true
        let toolName = req.name
        let eventLoop = context.eventLoop
        runRequestTask {
            let toolStart = Date()
            func finish(_ text: String, isError: Bool) {
                let body = Self.mcpResultBody(text, isError: isError)
                self.respondOnLoop(eventLoop, status: .ok, headers: self.jsonHeaders(), body: body)
                let toolLog = ToolCallLog(
                    name: toolName, arguments: argsJSON, result: text,
                    durationMs: Date().timeIntervalSince(toolStart) * 1000, isError: isError)
                self.logRequest(
                    method: "POST", path: "/mcp/call", userAgent: userAgent, requestBody: requestBodyString,
                    responseBody: body, responseStatus: 200, startTime: startTime,
                    finishReason: isError ? .error : .stop, errorMessage: isError ? text : nil,
                    toolCalls: [toolLog])
            }
            do {
                // MCP transport stays HTTP 200; a tool-level failure is
                // `isError` (upstream). The registry validates arguments.
                let result = try await ExternalMCPToolPolicy.executeToolAsExternalMCP(
                    name: toolName, argumentsJSON: argsJSON)
                finish(result, isError: ToolEnvelope.isError(result))
            } catch {
                finish(error.localizedDescription, isError: true)
            }
        }
    }
}
