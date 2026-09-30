//
//  IntelToolDiscoveryTests.swift
//  OsaurusCoreTests
//
//  `W-tool-discovery` (docs/TOOL_DISCOVERY_INTEL.md): Auto mode keeps plugin
//  tools out of the schema until `capabilities` loads them, the manifest and
//  search find them, loads are limited to the agent's allowlist, and the
//  engine offers a loaded tool from the next round on. Isolated storage; the
//  engine test talks to an in-process HTTP fixture.
//

import Foundation
import Testing

@testable import OsaurusCore

private struct FixturePluginTool: OsaurusTool, PermissionedTool {
    let name: String
    let description: String
    let parameters: JSONValue? = .object(["type": .string("object"), "properties": .object([:])])
    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    func execute(argumentsJSON: String) async throws -> String {
        ToolEnvelope.success(tool: name, text: "ran \(name)")
    }
}

@Suite("Intel tool discovery", .serialized)
struct IntelToolDiscoveryTests {
    /// Registers two plugin tools under one group, runs `body`, unregisters.
    private static func withPluginTools<T: Sendable>(
        _ body: @Sendable (_ weather: String, _ stocks: String, _ group: String) async throws -> T
    ) async throws -> T {
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let weather = "fixture_weather_forecast_\(suffix)"
        let stocks = "fixture_stock_quote_\(suffix)"
        let group = "Fixture Plugin \(suffix)"
        ToolRegistry.shared.registerPluginTool(
            FixturePluginTool(name: weather, description: "Get the weather forecast for a city. Returns daily highs."),
            group: group)
        ToolRegistry.shared.registerPluginTool(
            FixturePluginTool(name: stocks, description: "Look up a stock price quote by ticker symbol."),
            group: group)
        defer { ToolRegistry.shared.unregister(names: [weather, stocks]) }
        return try await body(weather, stocks, group)
    }

    @MainActor
    private static func addAgent(mode: ToolSelectionMode, allow: [String]?) -> Agent {
        var agent = Agent(name: "disc-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
        agent.toolSelectionMode = mode
        agent.manualToolNames = allow
        AgentManager.shared.add(agent)
        return agent
    }

    private static func object(_ envelope: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: Search and helpers

    @Test("Keyword search ranks the matching tool first and splits snake_case names")
    func search() async {
        let catalog = CapabilityCatalog(
            tools: [
                .init(name: "weather_forecast", description: "Daily forecast for a city.", groupId: nil),
                .init(name: "stock_quote", description: "Price of a ticker symbol.", groupId: nil),
            ],
            skills: [.init(name: "Trip Planner", description: "Plan a trip itinerary.")],
            groups: [])
        let weather = await CapabilitySearch.search("what's the forecast in Lisbon", in: catalog, embedder: nil)
        #expect(weather.first?.id == "tool/weather_forecast")
        let trip = await CapabilitySearch.search("plan my trip", in: catalog, embedder: nil)
        #expect(trip.first?.id == "skill/Trip Planner")
        #expect(await CapabilitySearch.search("knitting patterns", in: catalog, embedder: nil).isEmpty)
        #expect(CapabilitySearch.tokens("getStockQuote_v2") == ["get", "stock", "quote", "v2"])
        #expect(CapabilityCatalog.slug("My MCP: Server!") == "my-mcp-server")
        #expect(CapabilitiesTool.split("tool/x") == ("tool", "x"))
        #expect(CapabilitiesTool.split("http://x") == ("", "http://x"))
    }

    // MARK: Composition

    @MainActor
    @Test("Auto mode: plugin tools wait behind capabilities and the manifest; loads come back")
    func autoModeComposition() async throws {
        try await ChatHistoryTestStorage.run {
            try await Self.withPluginTools { weather, stocks, group in
                let agent = await Self.addAgent(mode: .auto, allow: nil)
                let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
                let names = Set(context.tools.map(\.function.name))
                #expect(!names.contains(weather) && !names.contains(stocks))
                #expect(names.contains(CapabilitiesTool.toolName))
                #expect(ToolRegistry.agentLoopToolNames.isSubset(of: names))  // built-ins stay
                #expect(context.prompt.contains("## Enabled capabilities"))
                #expect(context.prompt.contains("tool/\(weather)"))
                #expect(context.prompt.contains("plugin/\(CapabilityCatalog.slug(group))"))

                let later = await SystemPromptComposer.composeChatContext(
                    agentId: agent.id, query: "hi", additionalToolNames: [weather])
                let laterNames = Set(later.tools.map(\.function.name))
                #expect(laterNames.contains(weather) && !laterNames.contains(stocks))
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }

    @MainActor
    @Test("Manual mode sends the enabled tools directly, without discovery")
    func manualModeComposition() async throws {
        try await ChatHistoryTestStorage.run {
            try await Self.withPluginTools { weather, stocks, _ in
                let agent = await Self.addAgent(mode: .manual, allow: [weather])
                let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "hi")
                let names = Set(context.tools.map(\.function.name))
                #expect(names.contains(weather) && !names.contains(stocks))
                #expect(!names.contains(CapabilitiesTool.toolName))
                #expect(!context.prompt.contains("## Enabled capabilities"))
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }

    // MARK: The gateway

    @MainActor
    @Test("capabilities loads allowed ids, refuses others, searches and lists")
    func gateway() async throws {
        try await ChatHistoryTestStorage.run {
            try await Self.withPluginTools { weather, stocks, group in
                // The allowlist admits only the weather tool.
                let agent = await Self.addAgent(mode: .auto, allow: [weather])
                let sessionId = "disc-\(UUID().uuidString)"
                let buffer = CapabilityLoadBuffer()
                let tool = CapabilitiesTool()
                func call(_ args: String) async throws -> String {
                    try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                        try await ChatExecutionContext.$currentSessionId.withValue(sessionId) {
                            try await CapabilityLoadBuffer.$current.withValue(buffer) {
                                try await ToolRegistry.shared.execute(
                                    name: CapabilitiesTool.toolName, argumentsJSON: args)
                            }
                        }
                    }
                }

                let loaded = try await call(#"{"ids":["tool/\#(weather)"]}"#)
                #expect(Self.object(loaded)["ok"] as? Bool == true, "\(loaded)")
                #expect(await buffer.drain() == [weather])
                #expect(await SessionToolStateStore.shared.get(sessionId)?.loadedToolNames == [weather])

                // Not on the allowlist: not loadable, even by exact id or group.
                let refused = try await call(#"{"ids":["tool/\#(stocks)"]}"#)
                #expect(Self.object(refused)["ok"] as? Bool == false)
                let viaGroup = try await call(#"{"ids":["plugin/\#(CapabilityCatalog.slug(group))"]}"#)
                #expect(Self.object(viaGroup)["ok"] as? Bool == true)
                #expect(await buffer.drain() == [weather])

                let found = try await call(#"{"query":"weather forecast"}"#)
                #expect(found.contains("tool/\(weather)") && !found.contains(stocks))
                let listed = try await call("{}")
                #expect(listed.contains("tool/\(weather)") && !listed.contains(stocks))
                _ = tool
                _ = await AgentManager.shared.delete(id: agent.id)
                await SessionToolStateStore.shared.invalidate(sessionId)
            }
        }
    }

    @MainActor
    @Test("capabilities is refused for the built-in agent and in Manual mode")
    func gatewayGating() async throws {
        try await ChatHistoryTestStorage.run {
            let manual = Self.addAgent(mode: .manual, allow: ["file_read"])
            for agentId in [Agent.defaultId, manual.id] {
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agentId) {
                    try await ToolRegistry.shared.execute(name: CapabilitiesTool.toolName, argumentsJSON: "{}")
                }
                #expect(Self.object(result)["ok"] as? Bool == false, "\(result)")
            }
            _ = await AgentManager.shared.delete(id: manual.id)
        }
    }

    @MainActor
    @Test("A skill loads its instructions; slash-selected skills resolve again")
    func skills() async throws {
        try await ChatHistoryTestStorage.run {
            let skill = await SkillManager.shared.create(
                name: "Pantry Planner",
                description: "Plan weekly meals from the pantry.",
                instructions: "Always list rice first.")
            // (The store may re-case a name on reload, so compare ids.)
            #expect(SkillManager.shared.skill(for: skill.id)?.id == skill.id)
            // The `/` popup offers it (upstream `allCommands`).
            let slashHits = SlashCommandRegistry.shared.filtered(query: "pantry-planner")
            #expect(slashHits.contains { $0.kind == .skill && $0.id == skill.id })
            let agent = Self.addAgent(mode: .auto, allow: nil)
            let result = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                try await ToolRegistry.shared.execute(
                    name: CapabilitiesTool.toolName, argumentsJSON: #"{"ids":["skill/\#(skill.name)"]}"#)
            }
            #expect(result.contains("Always list rice first."), "\(result)")
            _ = await SkillManager.shared.delete(id: skill.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: Engine

    private static func toolCallStream(name: String, arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\"", with: "\\\"")
        return """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_\(UUID().uuidString.prefix(4))","type":"function","function":{"name":"\(name)","arguments":"\(escaped)"}}]},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
    }

    private static let textStream = """
        data: {"choices":[{"index":0,"delta":{"content":"Sunny."},"finish_reason":null}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

    @MainActor
    @Test("The engine offers a tool loaded by capabilities from the next round and runs it")
    func engineAdoptsLoadedTools() async throws {
        try await ChatHistoryTestStorage.run {
            try await Self.withPluginTools { weather, _, _ in
                let agent = await Self.addAgent(mode: .auto, allow: nil)
                DiscoveryFixtureProtocol.configure(responses: [
                    Self.toolCallStream(name: CapabilitiesTool.toolName, arguments: #"{"ids":["tool/\#(weather)"]}"#),
                    Self.toolCallStream(name: weather, arguments: "{}"),
                    Self.textStream,
                ])
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [DiscoveryFixtureProtocol.self]
                let provider = RemoteProvider(
                    name: "Fixture", host: "discovery-fixture.invalid", providerProtocol: .https,
                    port: nil, basePath: "/v1", customHeaders: [:], authType: .none,
                    providerType: .openaiLegacy, enabled: true, autoConnect: false, timeout: 5)
                let engine = ChatEngine(provider: provider, session: URLSession(configuration: configuration))
                let context = await SystemPromptComposer.composeChatContext(agentId: agent.id, query: "weather?")
                var request = ChatCompletionRequest(
                    model: "fixture-model", messages: [ChatMessage(role: "user", content: "Weather in Lisbon?")])
                request.tools = context.tools
                #expect(!(request.tools ?? []).contains { $0.function.name == weather })

                var results: [String: String] = [:]
                let stream = try await ChatExecutionContext.$currentAgentId.withValue(agent.id) {
                    try await engine.streamChat(request: request)
                }
                for try await delta in stream {
                    if let done = StreamingToolHint.decodeDone(delta) { results[done.name] = done.result }
                }
                #expect(results[CapabilitiesTool.toolName]?.contains("\"ok\":true") == true)
                #expect(results[weather]?.contains("ran \(weather)") == true, "\(results)")
                let bodies = DiscoveryFixtureProtocol.bodies
                #expect(bodies.count == 3)
                #expect(!(bodies.first ?? "").contains(weather + "\""))  // not offered in round 1
                #expect(bodies.dropFirst().first?.contains("\"name\":\"\(weather)\"") == true)
                _ = await AgentManager.shared.delete(id: agent.id)
            }
        }
    }
}

private final class DiscoveryFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String] = []
    nonisolated(unsafe) private static var recorded: [String] = []
    static var bodies: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func configure(responses: [String]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses; recorded = []
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "discovery-fixture.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append(String(decoding: body, as: UTF8.self))
        let text = Self.queue.isEmpty ? "data: [DONE]\n\n" : Self.queue.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
