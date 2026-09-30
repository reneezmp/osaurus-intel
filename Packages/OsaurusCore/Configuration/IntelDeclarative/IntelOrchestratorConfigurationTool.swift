import Foundation

#if OSAURUS_INTEL

struct IntelOrchestratorConfigurationTool: OsaurusTool, PermissionedTool {
    static let toolName = "orchestrator_config"
    private static let maximumDocumentBytes = 65_536
    private static let sharedService = IntelDeclarativeConfigurationService()

    let name = Self.toolName
    let description =
        "Validate, plan, or apply the built-in Orchestrator's bounded Intel configuration. "
        + "Only default_agent, delegation, and new_chat_agent (the agent id new chats open with, or \"orchestrator\") "
        + "are supported. Apply always pauses for an exact user-reviewed diff. "
        + "find_setting searches every Settings page and returns the exact path to quote to the user."
    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy = .auto
    let handlesOwnApproval = true
    let bypassRegistryTimeout = true

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "operation": .object([
                "type": .string("string"),
                "enum": .array([.string("schema"), .string("plan"), .string("apply"), .string("find_setting")]),
                "description": .string(
                    "schema and find_setting are read-only; plan previews paths; apply requires the user's review."),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("Words describing the setting, for find_setting (e.g. \"spell check\")."),
            ]),
            "document": .object([
                "type": .string("string"),
                "description": .string("Strict version-1 JSON document. Required for plan and apply."),
            ]),
        ]),
        "required": .array([.string("operation")]),
    ])

    private let service: IntelDeclarativeConfigurationService
    private let approvalRequester: @Sendable (IntelDeclarativeConfigurationPlan) async -> IntelConfigApprovalOutcome

    init(
        service: IntelDeclarativeConfigurationService = Self.sharedService,
        approvalRequester: @escaping @Sendable (IntelDeclarativeConfigurationPlan) async -> IntelConfigApprovalOutcome = {
            await IntelConfigApprovalService.requestApproval(plan: $0)
        }
    ) {
        self.service = service
        self.approvalRequester = approvalRequester
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard ChatExecutionContext.currentAgentId == Agent.defaultId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "This configuration tool is available only to the built-in Orchestrator.",
                tool: name
            )
        }
        let requirement = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let arguments) = requirement else {
            return requirement.failureEnvelope ?? ""
        }
        guard let operation = arguments["operation"] as? String else {
            return ToolEnvelope.failure(kind: .invalidArgs, message: "operation is required.", field: "operation", tool: name)
        }

        do {
            switch operation {
            case "schema":
                return ToolEnvelope.success(tool: name, result: schemaResult())
            case "find_setting":
                let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !query.isEmpty else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "query is required for find_setting.", field: "query", tool: name)
                }
                return ToolEnvelope.success(tool: name, result: Self.findSettingResult(query: query))
            case "plan", "apply":
                guard let document = arguments["document"] as? String else {
                    return ToolEnvelope.failure(kind: .invalidArgs, message: "document is required for \(operation).", field: "document", tool: name)
                }
                let data = Data(document.utf8)
                guard data.count <= Self.maximumDocumentBytes else {
                    return ToolEnvelope.failure(kind: .invalidArgs, message: "document exceeds the 64 KiB limit.", field: "document", tool: name)
                }
                if case let .set(id) = try IntelDeclarativeConfigurationDocument.decode(json: data).newChatAgent {
                    let exists = await MainActor.run { AgentManager.shared.agent(for: id) != nil }
                    guard exists else {
                        return ToolEnvelope.failure(
                            kind: .invalidArgs, message: "new_chat_agent must be an existing agent's id, or \"orchestrator\".",
                            field: "document", tool: name)
                    }
                }
                let plan = try await service.plan(json: data)
                if operation == "plan" || plan.isNoOp {
                    return ToolEnvelope.success(tool: name, result: modelPlanResult(plan, status: plan.isNoOp ? "no_changes" : "planned"))
                }
                switch await approvalRequester(plan) {
                case .approved:
                    let approval = await service.approve(plan)
                    _ = try await service.apply(plan, approval: approval)
                    return ToolEnvelope.success(tool: name, result: modelPlanResult(plan, status: "applied"))
                case .denied:
                    return ToolEnvelope.failure(kind: .userDenied, message: "The user cancelled this configuration plan.", tool: name, retryable: false)
                case .timedOut:
                    return ToolEnvelope.failure(kind: .timeout, message: "The configuration review expired without approval.", tool: name, retryable: true)
                case .cancelled:
                    return ToolEnvelope.failure(kind: .rejected, message: "The configuration review was cancelled or no chat review surface was available.", tool: name, retryable: true)
                }
            default:
                return ToolEnvelope.failure(kind: .invalidArgs, message: "operation must be schema, plan, apply, or find_setting.", field: "operation", tool: name)
            }
        } catch {
            return ToolEnvelope.fromError(error, tool: name)
        }
    }

    /// Grounded Settings lookup (upstream #49): results come from the same
    /// Intel-authored index the Settings search field uses, so the model can
    /// quote a real path instead of guessing menus or shortcuts.
    static func findSettingResult(query: String, limit: Int = 5) -> [String: Any] {
        let lookup = findSettings(query)
        let matches = lookup.entries.prefix(limit)
        var result: [String: Any] = [
            "query": query,
            "matches": matches.map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "path": entry.breadcrumbPath,
                    "page": entry.tab.label,
                    "setting": entry.title,
                    "open_with": "Osaurus menu › Settings… (⌘,), then \(entry.tab.label) in the sidebar",
                ]
                if let note = entry.disambiguation { row["note"] = note }
                return row
            },
            "guidance": matches.isEmpty
                ? "No Settings entry matches. Say so; do not invent a menu path."
                : "Quote the path as shown. The user can also type the setting name into Search Settings.",
        ]
        if let relaxed = lookup.relaxedQuery { result["relaxed_query"] = relaxed }
        return result
    }

    /// Words a user (or the model relaying the user) wraps around a setting
    /// name that never appear in a catalog title or keyword: intent verbs,
    /// on/off state, and filler. Stripped only for the second, relaxed pass
    /// (upstream #2936).
    static let findIntentWords: Set<String> = [
        "turn", "on", "off", "the", "a", "an", "my", "setting", "settings", "option",
        "toggle", "switch", "where", "is", "are", "how", "to", "do", "i", "change",
        "set", "find", "for", "in", "of", "can", "you", "please", "enable", "disable",
        "enabled", "disabled", "stop", "start", "make", "it", "me", "up", "get",
    ]

    /// The index matcher needs every query token inside one title, section or
    /// keyword, so "turn off memory" misses the Enable Memory row. When the
    /// strict pass is empty, retry without intent/state words and report the
    /// query that matched. The Settings search field is unchanged: it matches
    /// what the user typed.
    static func findSettings(_ query: String) -> (entries: [SettingsSearchEntry], relaxedQuery: String?) {
        let strict = SettingsSearchIndex.search(query)
        if !strict.isEmpty { return (strict, nil) }
        let kept = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !findIntentWords.contains($0) }
        guard !kept.isEmpty else { return ([], nil) }
        let relaxed = kept.joined(separator: " ")
        guard relaxed != query.lowercased() else { return ([], nil) }
        let hits = SettingsSearchIndex.search(relaxed)
        return (hits, hits.isEmpty ? nil : relaxed)
    }

    private func schemaResult() -> [String: Any] {
        [
            "version": 1,
            "supported_domains": ["default_agent", "delegation", "new_chat_agent"],
            "list_semantics": "delegation.allowed_agent_ids and admitted_cloud_model_ids replace the whole list",
            "unsupported_domains_fail_closed": true,
            "secrets_and_external_references": "rejected",
            "maximum_document_bytes": Self.maximumDocumentBytes,
            "apply": "requires a fresh, exact user-reviewed plan",
        ]
    }

    /// The model receives paths and fingerprints only. Current private prompt
    /// values stay in the local review card and never become tool output.
    private func modelPlanResult(_ plan: IntelDeclarativeConfigurationPlan, status: String) -> [String: Any] {
        var result: [String: Any] = [
            "status": status,
            "plan_id": plan.id.uuidString,
            "current_fingerprint": plan.currentStateFingerprint,
            "target_fingerprint": plan.targetStateFingerprint,
            "changed_paths": plan.changes.map(\.path),
        ]
        if !plan.warnings.isEmpty { result["warnings"] = plan.warnings }
        return result
    }
}

#endif
