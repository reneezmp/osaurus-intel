import Foundation

#if OSAURUS_INTEL

struct IntelOrchestratorConfigurationTool: OsaurusTool, PermissionedTool {
    static let toolName = "orchestrator_config"
    private static let maximumDocumentBytes = 65_536
    private static let sharedService = IntelDeclarativeConfigurationService()

    let name = Self.toolName
    let description =
        "Validate, plan, or apply the built-in Orchestrator's bounded Intel configuration. "
        + "Only default_agent and delegation are supported. Apply always pauses for an exact user-reviewed diff."
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
                "enum": .array([.string("schema"), .string("plan"), .string("apply")]),
                "description": .string("schema is read-only; plan previews paths; apply requires the user's review."),
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
            case "plan", "apply":
                guard let document = arguments["document"] as? String else {
                    return ToolEnvelope.failure(kind: .invalidArgs, message: "document is required for \(operation).", field: "document", tool: name)
                }
                let data = Data(document.utf8)
                guard data.count <= Self.maximumDocumentBytes else {
                    return ToolEnvelope.failure(kind: .invalidArgs, message: "document exceeds the 64 KiB limit.", field: "document", tool: name)
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
                return ToolEnvelope.failure(kind: .invalidArgs, message: "operation must be schema, plan, or apply.", field: "operation", tool: name)
            }
        } catch {
            return ToolEnvelope.fromError(error, tool: name)
        }
    }

    private func schemaResult() -> [String: Any] {
        [
            "version": 1,
            "supported_domains": ["default_agent", "delegation"],
            "unsupported_domains_fail_closed": true,
            "secrets_and_external_references": "rejected",
            "maximum_document_bytes": Self.maximumDocumentBytes,
            "apply": "requires a fresh, exact user-reviewed plan",
        ]
    }

    /// The model receives paths and fingerprints only. Current private prompt
    /// values stay in the local review card and never become tool output.
    private func modelPlanResult(_ plan: IntelDeclarativeConfigurationPlan, status: String) -> [String: Any] {
        [
            "status": status,
            "plan_id": plan.id.uuidString,
            "current_fingerprint": plan.currentStateFingerprint,
            "target_fingerprint": plan.targetStateFingerprint,
            "changed_paths": plan.changes.map(\.path),
        ]
    }
}

#endif
