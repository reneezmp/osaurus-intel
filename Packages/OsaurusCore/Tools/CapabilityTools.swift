//
//  CapabilityTools.swift
//  osaurus
//
//  Automatic tool discovery on Intel (upstream "Design C"; see
//  docs/TOOL_DISCOVERY_INTEL.md). In Auto mode a custom agent starts with its
//  fixed built-in set plus one gateway tool, `capabilities`, and an "Enabled
//  capabilities" manifest in the prompt. Plugin and MCP tools (and skills)
//  the agent is allowed to use are loaded on demand:
//
//    capabilities({"ids": ["tool/<name>" | "plugin/<id>" | "skill/<name>"]})
//    capabilities({"query": "<what you need>"})   // search
//    capabilities({})                             // list what is enabled
//
//  Intel adaptations:
//    * Upstream searches a persisted hybrid index (SQLite FTS BM25 +
//      VecturaKit embeddings, Apple Silicon). Intel's catalog is small and
//      built live from the registry, so `CapabilitySearch` ranks it in memory:
//      BM25 over names/descriptions, fused with the local static embedder
//      Memory uses when that model is on disk. Nothing leaves the Mac.
//    * Upstream delivers a loaded schema inside the tool result and folds it
//      into `<tools>` at the next compose (KV-cache reasons). Intel's
//      `CloudChatEngine` runs the tool loop itself, so it drains
//      `CapabilityLoadBuffer` after each call and adds the loaded tools to the
//      request for the next round — the offered-tool check then admits them.
//    * The load is authorised here against the agent's live catalog (its
//      Tools-tab allowlist ∩ registered plugin/MCP tools), and every call is
//      still checked by `ToolRegistry.runtimeCapabilityDenial`.
//

import Foundation

// MARK: - CapabilityLoadBuffer

/// Tool names `capabilities` loaded during one engine run. The engine binds
/// `current` around its tool loop and drains after every call.
actor CapabilityLoadBuffer {
    @TaskLocal static var current: CapabilityLoadBuffer?

    private var pending: [String] = []

    func add(_ names: [String]) {
        for name in names where !pending.contains(name) {
            pending.append(name)
        }
    }

    func drain() -> [String] {
        defer { pending = [] }
        return pending
    }
}

// MARK: - Catalog

/// What an agent may load right now: its allowed plugin/MCP tools, grouped by
/// plugin or provider, and its enabled skills.
struct CapabilityCatalog: Sendable {
    struct ToolItem: Sendable, Equatable {
        let name: String
        let description: String
        let groupId: String?
    }

    struct SkillItem: Sendable, Equatable {
        let name: String
        let description: String
    }

    struct Group: Sendable, Equatable {
        /// Slug used in `plugin/<id>`.
        let id: String
        let display: String
        var tools: [ToolItem]
    }

    var tools: [ToolItem]
    var skills: [SkillItem]
    var groups: [Group]

    var isEmpty: Bool { tools.isEmpty && skills.isEmpty }

    static let empty = CapabilityCatalog(tools: [], skills: [], groups: [])

    /// The live catalog for `agentId`. Empty for the built-in agent (it has a
    /// fixed surface) and when the agent's tools are off.
    @MainActor
    static func build(agentId: UUID) -> CapabilityCatalog {
        let manager = AgentManager.shared
        guard agentId != Agent.defaultId, manager.agent(for: agentId) != nil,
            !manager.effectiveToolsDisabled(for: agentId)
        else { return .empty }

        let registry = ToolRegistry.shared
        let allowlist = manager.effectiveEnabledToolNames(for: agentId).map(Set.init)
        var tools: [ToolItem] = []
        var groupsById: [String: Group] = [:]
        var groupOrder: [String] = []
        for spec in registry.openAISpecs(for: agentId) {
            let name = spec.function.name
            guard registry.isLoadableDynamicTool(name) else { continue }
            if let allowlist, !allowlist.contains(name) { continue }
            let display = registry.groupName(for: name)
            let groupId = display.map(slug)
            let item = ToolItem(
                name: name,
                description: oneLine(spec.function.description ?? ""),
                groupId: groupId
            )
            tools.append(item)
            if let groupId, let display {
                if groupsById[groupId] == nil {
                    groupsById[groupId] = Group(id: groupId, display: display, tools: [])
                    groupOrder.append(groupId)
                }
                groupsById[groupId]?.tools.append(item)
            }
        }

        let skillAllowlist = manager.effectiveEnabledSkillNames(for: agentId).map(Set.init)
        let skills = SkillManager.shared.skills
            .filter { $0.enabled && (skillAllowlist?.contains($0.name) ?? true) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { SkillItem(name: $0.name, description: oneLine($0.description)) }

        let groups = groupOrder.compactMap { groupsById[$0] }
            .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
        return CapabilityCatalog(tools: tools, skills: skills, groups: groups)
    }

    func tool(named name: String) -> ToolItem? {
        tools.first { $0.name == name }
    }

    func skill(named name: String) -> SkillItem? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func group(id: String) -> Group? {
        let wanted = Self.slug(id)
        return groups.first { $0.id == wanted }
    }

    /// Every id the model may pass, in list order.
    var allIds: [(id: String, description: String)] {
        var rows: [(String, String)] = []
        for group in groups {
            rows.append(("plugin/\(group.id)", "\(group.display) — \(group.tools.count) tool(s)"))
        }
        for tool in tools { rows.append(("tool/\(tool.name)", tool.description)) }
        for skill in skills { rows.append(("skill/\(skill.name)", skill.description)) }
        return rows
    }

    nonisolated static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    nonisolated static func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSentenceEnd = flat.range(of: ". ") else {
            return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
        }
        let sentence = String(flat[..<firstSentenceEnd.lowerBound]) + "."
        return sentence.count <= limit ? sentence : String(sentence.prefix(limit)) + "…"
    }
}

// MARK: - Search

/// In-memory ranking over a catalog: BM25 on names, groups and descriptions,
/// fused (reciprocal rank) with cosine similarity from the local static
/// embedder when its model is on disk. Upstream uses a persisted SQLite FTS
/// index plus VecturaKit; Intel's catalog is small enough to rank live.
enum CapabilitySearch {
    struct Hit: Sendable, Equatable {
        let id: String
        let description: String
    }

    static let defaultLimit = 8

    static func search(
        _ query: String,
        in catalog: CapabilityCatalog,
        limit: Int = defaultLimit,
        embedder: (any EmbeddingBackend)? = localEmbedder()
    ) async -> [Hit] {
        let docs: [(id: String, text: String, description: String)] =
            catalog.tools.map { tool in
                let group = tool.groupId.flatMap { id in catalog.groups.first { $0.id == id }?.display } ?? ""
                return ("tool/\(tool.name)", "\(tool.name) \(group) \(tool.description)", tool.description)
            }
            + catalog.skills.map { ("skill/\($0.name)", "\($0.name) \($0.description)", $0.description) }
        guard !docs.isEmpty else { return [] }

        let bm25 = bm25Scores(query: query, documents: docs.map(\.text))
        var fused = [Double](repeating: 0, count: docs.count)
        var matched = [Bool](repeating: false, count: docs.count)
        for (rank, index) in rankedIndices(bm25, minimum: 0.0001).enumerated() {
            fused[index] += 1.0 / Double(60 + rank + 1)
            matched[index] = true
        }
        if let embedder,
            let vectors = try? await embedder.embed([query] + docs.map(\.text)),
            vectors.count == docs.count + 1
        {
            let q = vectors[0]
            let cosines = vectors.dropFirst().map { Double(zip(q, $0).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            for (rank, index) in rankedIndices(Array(cosines), minimum: 0.3).enumerated() {
                fused[index] += 1.0 / Double(60 + rank + 1)
                matched[index] = true
            }
        }
        return rankedIndices(fused, minimum: 0.0000001)
            .filter { matched[$0] }
            .prefix(limit)
            .map { Hit(id: docs[$0].id, description: docs[$0].description) }
    }

    /// The Memory static embedder, only when its model is already on disk
    /// (tool search never downloads or calls a cloud embedder).
    static func localEmbedder() -> (any EmbeddingBackend)? {
        guard StaticEmbeddingModel.isAvailable else { return nil }
        return cachedEmbedder.withLock { cached in
            if let cached { return cached }
            let loaded = try? StaticEmbedder(modelDirectory: StaticEmbeddingModel.cacheDirectory)
            cached = loaded
            return loaded
        }
    }

    private static let cachedEmbedder = NSLockedValue<StaticEmbedder?>(nil)

    static func tokens(_ text: String) -> [String] {
        // Split snake_case, kebab-case and camelCase names into words.
        var spaced = ""
        var previous: Character?
        for character in text {
            if let previous, previous.isLowercase, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "can", "you", "are", "use",
        "tool", "tools", "a", "an", "to", "of", "in", "on", "or", "by", "is", "it", "my", "me",
    ]

    static func bm25Scores(query: String, documents: [String], k1: Double = 1.2, b: Double = 0.75) -> [Double] {
        let queryTerms = Set(tokens(query))
        let docTokens = documents.map(tokens)
        let avgLength = max(1, Double(docTokens.reduce(0) { $0 + $1.count }) / Double(max(docTokens.count, 1)))
        var documentFrequency: [String: Int] = [:]
        for doc in docTokens {
            for term in Set(doc) where queryTerms.contains(term) { documentFrequency[term, default: 0] += 1 }
        }
        let n = Double(docTokens.count)
        return docTokens.map { doc in
            var counts: [String: Int] = [:]
            for term in doc where queryTerms.contains(term) { counts[term, default: 0] += 1 }
            let length = Double(doc.count)
            return counts.reduce(0.0) { score, entry in
                let df = Double(documentFrequency[entry.key] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(entry.value)
                return score + idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * length / avgLength))
            }
        }
    }

    private static func rankedIndices(_ scores: [Double], minimum: Double) -> [Int] {
        scores.indices.filter { scores[$0] >= minimum }.sorted { scores[$0] > scores[$1] }
    }
}

/// Minimal lock box (Intel's deployment target predates `Mutex`).
final class NSLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Manifest

/// The "Enabled capabilities" prompt section (upstream
/// `SystemPromptTemplates.enabledCapabilitiesManifest`, verbose form, with
/// the `capabilities` gateway names) and the discovery guidance.
enum CapabilityManifest {
    static let toolCap = 70
    static let skillCap = 30

    static func render(_ catalog: CapabilityCatalog) -> String? {
        guard !catalog.isEmpty else { return nil }
        var blocks: [String] = []
        var toolLines = 0

        func toolLine(_ tool: CapabilityCatalog.ToolItem) -> String {
            "  tool/\(tool.name) — \(tool.description.isEmpty ? "(no description)" : tool.description)"
        }

        for group in catalog.groups {
            let remaining = max(toolCap - toolLines, 0)
            var lines = ["<plugin: \(group.display)> (load all: plugin/\(group.id))"]
            let shown = Array(group.tools.prefix(remaining))
            toolLines += shown.count
            lines.append(contentsOf: shown.map(toolLine))
            if group.tools.count > shown.count {
                lines.append("  +\(group.tools.count - shown.count) more tool(s) — search with `capabilities` to list them.")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        let ungrouped = catalog.tools.filter { $0.groupId == nil }
        if !ungrouped.isEmpty {
            let remaining = max(toolCap - toolLines, 0)
            let shown = Array(ungrouped.prefix(remaining))
            var lines = ["<other tools>"]
            lines.append(contentsOf: shown.map(toolLine))
            if ungrouped.count > shown.count {
                lines.append("  +\(ungrouped.count - shown.count) more tool(s) — search with `capabilities` to list them.")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        if !catalog.skills.isEmpty {
            let shown = Array(catalog.skills.prefix(skillCap))
            var lines = ["<skills>"]
            lines.append(
                contentsOf: shown.map { "  skill/\($0.name) — \($0.description.isEmpty ? "Skill." : $0.description)" })
            if catalog.skills.count > shown.count {
                lines.append("  +\(catalog.skills.count - shown.count) more skill(s) — search with `capabilities` to list them.")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        let intro = """
            ## Enabled capabilities

            These capabilities are enabled for this session. Each line begins \
            with a capability id, not a callable function name; they must be \
            loaded before use. To load one, call `capabilities` with its id \
            exactly as shown (e.g. `capabilities({"ids": ["tool/<name>"]})`); \
            `plugin/<id>` loads that whole group. Loaded tools are callable from \
            your next step on. Capabilities installed after this list was written \
            are still found by searching with `capabilities` — use search only \
            when no exact listed id fits, and check it before declaring something \
            unavailable.
            """
        return intro + "\n\n" + blocks.joined(separator: "\n")
    }

    /// Upstream's discovery nudge and capability-claim grounding, for the
    /// single `capabilities` gateway.
    static let discoveryGuidance = """
        ## Discovering more tools

        Your current tool list is a fixed starting set, not the full enabled set. \
        Ids in the Enabled capabilities list can be pulled in on demand with \
        `capabilities`. When a capability seems missing and is not listed, \
        `capabilities({"query": "<what you need>"})` searches the enabled set and \
        returns exact ids you can load the same way.

        - Do not invent tool names — use ids from the list or from a search.
        - "I don't have a tool for X" must be backed by the Enabled capabilities \
        list or a `capabilities` search that came back empty, never by X being \
        absent from your current tool schema.
        """
}

// MARK: - capabilities

/// The single capability gateway (upstream `CapabilitiesTool`; same schema
/// and description). Loads by id, searches by query, or lists the enabled set.
final class CapabilitiesTool: OsaurusTool, @unchecked Sendable {
    static let toolName = "capabilities"
    let name = CapabilitiesTool.toolName
    let description =
        "Search for or load optional capabilities. Values beginning `plugin/`, `tool/`, "
        + "`skill/`, or `method/` are capability IDs for the `ids` argument, never callable "
        + "function names. When an exact ID is listed or returned, pass it in `ids`; use "
        + "`query` only when no exact available ID fits."

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "What optional capability is needed; use only when no exact capability ID is available"
                ),
            ]),
            "ids": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "Exact capability IDs from the enabled list or an earlier search; IDs are values, not function names"
                ),
            ]),
            "list": .object([
                "type": .string("string"),
                "enum": .array([.string("enabled")]),
                "description": .string(
                    "Pass \"enabled\" to list this agent's enabled capability IDs (paginated)."
                ),
            ]),
            "page": .object([
                "type": .string("integer"),
                "description": .string("Page of the enabled list (default 1)."),
            ]),
        ]),
    ])

    static let pageSize = 40

    /// Catalog source; tests inject their own.
    let catalogProvider: @Sendable (UUID) async -> CapabilityCatalog

    init(
        catalogProvider: @escaping @Sendable (UUID) async -> CapabilityCatalog = { agentId in
            await MainActor.run { CapabilityCatalog.build(agentId: agentId) }
        }
    ) {
        self.catalogProvider = catalogProvider
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        guard let agentId = ChatExecutionContext.currentAgentId else {
            return ToolEnvelope.failure(
                kind: .unavailable, message: "Capability discovery needs an agent chat.", tool: name)
        }
        let catalog = await catalogProvider(agentId)

        if let ids = Self.recoveredIds(from: args), !ids.isEmpty {
            return await load(ids: ids, catalog: catalog)
        }
        if let query = args["query"] as? String,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return await search(query: query, catalog: catalog)
        }
        let page = (args["page"] as? Int) ?? Int(args["page"] as? String ?? "") ?? 1
        return list(catalog: catalog, page: max(page, 1))
    }

    // MARK: Load

    private func load(ids: [String], catalog: CapabilityCatalog) async -> String {
        var toolNames: [String] = []
        var skillNames: [String] = []
        var unknown: [String] = []

        func addTool(_ tool: String) {
            if !toolNames.contains(tool) { toolNames.append(tool) }
        }

        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let (prefix, value) = Self.split(id)
            switch prefix {
            case "tool":
                if catalog.tool(named: value) != nil { addTool(value) } else { unknown.append(id) }
            case "plugin":
                if let group = catalog.group(id: value) {
                    group.tools.forEach { addTool($0.name) }
                } else {
                    unknown.append(id)
                }
            case "skill":
                if let skill = catalog.skill(named: value) {
                    if !skillNames.contains(skill.name) { skillNames.append(skill.name) }
                } else {
                    unknown.append(id)
                }
            default:
                // A bare name: models often drop the prefix.
                if catalog.tool(named: value) != nil {
                    addTool(value)
                } else if let skill = catalog.skill(named: value) {
                    if !skillNames.contains(skill.name) { skillNames.append(skill.name) }
                } else if let group = catalog.group(id: value) {
                    group.tools.forEach { addTool($0.name) }
                } else {
                    unknown.append(id)
                }
            }
        }

        guard !toolNames.isEmpty || !skillNames.isEmpty else {
            var suggestions: [String] = []
            for id in unknown {
                let hits = await CapabilitySearch.search(Self.split(id).value, in: catalog, limit: 3)
                suggestions.append(contentsOf: hits.map(\.id).filter { !suggestions.contains($0) })
            }
            let hint =
                suggestions.isEmpty
                ? "Call `capabilities` with no arguments to list the enabled ids."
                : "Closest enabled ids: \(suggestions.joined(separator: ", "))."
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "No enabled capability matches \(unknown.joined(separator: ", ")). \(hint)",
                field: "ids",
                expected: "exact ids from the Enabled capabilities list or a search",
                tool: name
            )
        }

        if !toolNames.isEmpty {
            await CapabilityLoadBuffer.current?.add(toolNames)
            if let sessionId = ChatExecutionContext.currentSessionId {
                await SessionToolStateStore.shared.appendLoadedTools(
                    sessionId, names: toolNames, fallbackPreflight: nil, fallbackAlwaysLoadedNames: nil)
            }
        }

        var skillPayloads: [[String: Any]] = []
        for skillName in skillNames {
            let instructions: String? = await { @MainActor in
                guard let skill = SkillManager.shared.skill(named: skillName) else { return nil }
                return await SkillManager.shared.buildFullInstructions(for: skill, referenceBudget: 24_000)
            }()
            if let instructions {
                skillPayloads.append(["name": skillName, "instructions": instructions])
            }
        }

        var parts: [String] = []
        if !toolNames.isEmpty {
            parts.append(
                "Loaded \(toolNames.count) tool(s): \(toolNames.joined(separator: ", ")). "
                    + "Call them directly from your next step.")
        }
        if !skillPayloads.isEmpty {
            parts.append("Follow the loaded skill instructions below.")
        }
        if !unknown.isEmpty {
            parts.append("Not found: \(unknown.joined(separator: ", ")).")
        }
        var result: [String: Any] = [
            "kind": "capabilities_loaded",
            "loaded_tools": toolNames,
            "message": parts.joined(separator: " "),
        ]
        if !skillPayloads.isEmpty { result["skills"] = skillPayloads }
        if !unknown.isEmpty { result["not_found"] = unknown }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: Search / list

    private func search(query: String, catalog: CapabilityCatalog) async -> String {
        let hits = await CapabilitySearch.search(query, in: catalog)
        guard !hits.isEmpty else {
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "capabilities_search",
                    "results": [[String: Any]](),
                    "message":
                        "No enabled capability matches \"\(query)\". Work with the tools you have, "
                        + "or tell the user this capability is not enabled for this agent.",
                ])
        }
        return ToolEnvelope.success(
            tool: name,
            result: [
                "kind": "capabilities_search",
                "results": hits.map { ["id": $0.id, "description": $0.description] },
                "message": "Load with capabilities({\"ids\": [\"<id>\"]}).",
            ])
    }

    private func list(catalog: CapabilityCatalog, page: Int) -> String {
        let rows = catalog.allIds
        guard !rows.isEmpty else {
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "capabilities_list",
                    "results": [[String: Any]](),
                    "message": "No optional capabilities are enabled for this agent; use the tools you have.",
                ])
        }
        let start = (page - 1) * Self.pageSize
        let slice = start < rows.count ? Array(rows[start..<min(start + Self.pageSize, rows.count)]) : []
        var result: [String: Any] = [
            "kind": "capabilities_list",
            "results": slice.map { ["id": $0.id, "description": $0.description] },
            "page": page,
            "message": "Load with capabilities({\"ids\": [\"<id>\"]}).",
        ]
        if start + Self.pageSize < rows.count {
            result["next"] = "Next page: {\"list\": \"enabled\", \"page\": \(page + 1)}"
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: Helpers

    static func split(_ id: String) -> (prefix: String, value: String) {
        guard let slash = id.firstIndex(of: "/") else { return ("", id) }
        let prefix = id[..<slash].lowercased()
        guard ["tool", "plugin", "skill", "method"].contains(prefix) else { return ("", id) }
        return (prefix, String(id[id.index(after: slash)...]))
    }

    /// Upstream's argument recovery: `ids` as an array, a bare string, a
    /// stringified array, or the singular `id`.
    static func recoveredIds(from args: [String: Any]) -> [String]? {
        func parse(_ value: Any?) -> [String]? {
            if let array = value as? [String] {
                let trimmed = array
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return trimmed.isEmpty ? nil : trimmed
            }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if trimmed.hasPrefix("["),
                    let data = trimmed.data(using: .utf8),
                    let decoded = try? JSONSerialization.jsonObject(with: data) as? [String]
                {
                    return parse(decoded)
                }
                return [trimmed]
            }
            return nil
        }
        return parse(args["ids"]) ?? parse(args["id"])
    }
}
