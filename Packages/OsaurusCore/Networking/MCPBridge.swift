//
//  MCPBridge.swift
//  OsaurusCore
//
//  Intel fork — minimal MCP server with demo tools. M5 milestone.
//

import Foundation
import MCP
import Logging

@MainActor
final class MCPBridge {
    static let shared = MCPBridge()

    private var server: MCP.Server?
    private var transport: StatelessHTTPServerTransport?

    private init() {}

    // MARK: - Start / Stop

    func start() async throws {
        guard server == nil else { return }

        let capabilities = MCP.Server.Capabilities(
            tools: MCP.Server.Capabilities.Tools(listChanged: false)
        )

        let srv = MCP.Server(
            name: "Osaurus (Intel)",
            version: "0.1.0",
            capabilities: capabilities
        )

        await registerHandlers(on: srv)

        let transport = StatelessHTTPServerTransport(
            logger: Logger(label: "com.osaurus.mcp")
        )

        self.transport = transport
        self.server = srv

        // Start the server's message loop in a detached task.
        // The server calls transport.connect() internally.
        Task.detached(priority: .userInitiated) { [srv, transport] in
            do {
                try await srv.start(transport: transport)
                print("[MCPBridge] MCP server loop ended")
            } catch {
                print("[MCPBridge] Server start failed: \(error)")
            }
        }

        // Give the task a moment to start processing
        try await Task.sleep(nanoseconds: 100_000_000)
        print("[MCPBridge] MCP server started (stateless HTTP)")
    }

    func stop() async {
        if let server {
            await server.stop()
            self.server = nil
        }
        if let transport {
            await transport.disconnect()
            self.transport = nil
        }
    }

    nonisolated func handleMCPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard await getTransport() != nil else {
            return .error(statusCode: 503, .internalError("MCP transport not ready"))
        }
        let t = await getTransport()
        guard let t else {
            return .error(statusCode: 503, .internalError("MCP transport not ready"))
        }
        return await t.handleRequest(request)
    }

    private func getTransport() -> StatelessHTTPServerTransport? {
        transport
    }

    // MARK: - Tool Registration

    private func registerHandlers(on server: MCP.Server) async {
        await server.withMethodHandler(MCP.ListTools.self) { _ in
            return MCP.ListTools.Result(tools: [
                MCP.Tool(
                    name: "echo",
                    description: "Echoes back the input message.",
                    inputSchema: .object([
                        "message": .string("The message to echo back."),
                    ])
                ),
                MCP.Tool(
                    name: "get_time",
                    description: "Returns the current date and time.",
                    inputSchema: .object([:])
                ),
                MCP.Tool(
                    name: "os_info",
                    description: "Returns information about this Osaurus Intel server.",
                    inputSchema: .object([:])
                ),
            ])
        }

        await server.withMethodHandler(MCP.CallTool.self) { params in
            switch params.name {
            case "echo":
                let msg: String
                if let args = params.arguments,
                   case let .string(s) = args["message"] {
                    msg = s
                } else {
                    msg = "(no message)"
                }
                return .init(content: [.text(text: "Echo: \(msg)", annotations: nil, _meta: nil)], isError: false)

            case "get_time":
                let df = ISO8601DateFormatter()
                let now = df.string(from: Date())
                return .init(content: [.text(text: "Current time: \(now)", annotations: nil, _meta: nil)], isError: false)

            case "os_info":
                let info = """
                Osaurus (Intel Fork)
                Platform: x86_64
                macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
                Host: \(ProcessInfo.processInfo.hostName)
                MCP: stateless HTTP transport
                """
                return .init(content: [.text(text: info, annotations: nil, _meta: nil)], isError: false)

            default:
                return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
            }
        }
    }
}
