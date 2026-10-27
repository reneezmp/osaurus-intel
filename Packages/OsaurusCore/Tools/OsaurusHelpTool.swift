//
//  OsaurusHelpTool.swift
//  osaurus
//
//  `osaurus_help`: the bundled Osaurus guide (`Resources/Guide/guide-*.md`,
//  loaded by `OsaurusGuide`) and the settings catalog, for the built-in
//  Orchestrator. Actions: `topics` (index), `read` (one topic), `find`
//  (Settings breadcrumbs from the same catalog as Settings search).
//
//  Intel (2026-10-27, `W-ui-misc` in-app guide): upstream's tool lives in
//  `ConfigurationTools.swift` beside `osaurus_inspect`, which Intel doesn't
//  compile. Same contract; Intel's guide corpus describes this Intel build
//  (see `docs/GUIDE_INTEL.md`). `find` reuses the Orchestrator config
//  tool's relaxed catalog lookup (upstream #2936), and rows carry Intel's
//  "open with" hint instead of upstream's declarative-section fields.
//

import Foundation

struct OsaurusHelpTool: OsaurusTool {
    static let toolName = "osaurus_help"

    let name = Self.toolName
    let description =
        "Bundled Osaurus user guide and settings catalog for this Intel Mac — answers questions about what "
        + "Osaurus is, how its features work, what this Intel build does and doesn't include, and where a "
        + "setting lives. `action`: topics (index of topic ids with summaries), read (needs `topic` id; "
        + "returns the full topic text), find (needs `query`; returns Settings breadcrumbs from the same "
        + "catalog as in-app settings search). Answer from the topic or find results; never guess menu paths."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([.string("topics"), .string("read"), .string("find")]),
                "description": .string(
                    "Operation: list all topics, read one topic, or find a setting by name."
                ),
            ]),
            "topic": .object([
                "type": .string("string"),
                "description": .string(
                    "Topic id from the `topics` index (e.g. getting-started, intel-mac). Required for read."
                ),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "Natural-language setting name (e.g. context length, memory). Required for find."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "The Osaurus guide tool is available only to the built-in Orchestrator.",
                tool: name
            )
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(args, allowed: ["topics", "read", "find"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "topics":
            let items = OsaurusGuide.topics.map { topic -> [String: Any] in
                ["id": topic.id, "title": topic.title, "summary": topic.summary]
            }
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "topics": items,
                    "note": "Call osaurus_help({action: 'read', topic: '<id>'}) for the full text, "
                        + "or osaurus_help({action: 'find', query: '<setting name>'}) to locate a control.",
                ]
            )
        case "read":
            let topicReq = requireString(args, "topic", expected: "topic id", tool: name)
            guard case .value(let topicId) = topicReq else { return topicReq.failureEnvelope ?? "" }
            guard let topic = OsaurusGuide.topic(id: topicId) else {
                let known = OsaurusGuide.topics.map { $0.id }.joined(separator: ", ")
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No guide topic `\(topicId)`. Known topics: \(known).",
                    field: "topic",
                    tool: name
                )
            }
            return ToolEnvelope.success(
                tool: name,
                result: ["id": topic.id, "title": topic.title, "content": topic.body]
            )
        case "find":
            let queryReq = requireString(args, "query", expected: "setting query", tool: name)
            guard case .value(let query) = queryReq else { return queryReq.failureEnvelope ?? "" }
            let lookup = Self.findSettings(query)
            let hits = lookup.entries.prefix(8).map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "id": entry.id,
                    "title": entry.title,
                    "path": entry.breadcrumbPath,
                    "open_with": "Osaurus menu › Settings… (⌘,), then \(entry.tab.label) in the sidebar",
                ]
                if let note = entry.disambiguation { row["not_this"] = note }
                return row
            }
            var result: [String: Any] = [
                "query": query,
                "matches": Array(hits),
                "note": hits.isEmpty
                    ? "No catalog match. Try another name, or action 'topics' then 'read'. "
                        + "Do not invent a menu path, and do not claim you changed a setting."
                    : "Quote the `path` breadcrumb. Only orchestrator_config can change settings, and only "
                        + "its own; for anything else tell the user to open that path.",
            ]
            if let relaxed = lookup.relaxedQuery { result["relaxed_query"] = relaxed }
            return ToolEnvelope.success(tool: name, result: result)
        default:
            return actionReq.failureEnvelope ?? ""
        }
    }

    /// Catalog lookup with upstream's relaxed second pass (intent and
    /// on/off words stripped when the strict match is empty).
    static func findSettings(_ query: String) -> (entries: [SettingsSearchEntry], relaxedQuery: String?) {
        IntelOrchestratorConfigurationTool.findSettings(query)
    }
}
