//
//  OsaurusConfigTool.swift
//  osaurus
//
//  `osaurus_config` — THE configuration surface for the Default agent
//  (the Orchestrator). One declarative YAML document describes Osaurus
//  (memory, default agent, custom agents, tools, delegation, commands,
//  MCP servers, plugins, cloud providers, search providers, schedules,
//  watchers); the tool exports it, plans a diff against current state, and
//  applies it. Server runtime, chat behavior, and app shell settings are
//  Settings-UI-only (scope reduction 2).
//
//  Intel port (W-declarative-config stage 4, upstream Classic): replaces
//  Intel's `orchestrator_config`. Omitted because Intel lacks the feature
//  behind them: `template` / `overrides` / `templates` / `save_as` (no
//  TemplateStore, AgentTemplate or ConfigTemplateStore), the eval-lane and
//  unattended-dispatch task locals (not on Intel), and `ConfigurationToolBase`
//  / `ConfigDeclarativeDomain` (no ConfigurationDomainRegistry).
//
//  Security invariants:
//   - Secrets NEVER travel through the document, the tool arguments, or
//     the results. Creating a cloud provider opens the native credential
//     sheet; keyed MCP/search providers come back `needs_user_action`
//     pointing at the right Settings pane.
//   - EVERY apply waits for the user's approval of the exact plan in the
//     in-chat `ConfigApprovalModal` (or on the owner's paired phone). A
//     headless, external, scheduled or background run is refused, never
//     auto-approved; a timeout or cancel applies nothing. High-risk plans
//     (auto tool policies, computer/browser use, relay exposure, prune
//     deletions, new MCP endpoints/stdio commands) are listed in the modal.
//   - Only Default-agent chat turns may call it (runtime gate).
//

import Foundation
import Yams

public final class OsaurusConfigTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    public static let toolName = "osaurus_config"
    public let name = OsaurusConfigTool.toolName
    // The first sentence must stay ≤180 chars: the Default agent's compact
    // bootstrap schema keeps only that sentence.
    public let description =
        "Configure Osaurus via a declarative YAML document: agents, "
        + "plugins, MCP, providers, schedules, watchers, tools, memory, delegation, commands. "
        + "`action`: schema (the YAML reference — read it when unsure of a key), "
        + "export (current state as YAML; optional `sections` filter), "
        + "apply (validate + plan + execute in one step, gated by the native one-tap approval "
        + "card — the normal way to make a change; plus optional `prune` to delete entries not "
        + "listed in the document's declared sections — destructive, use only when the user wants "
        + "an exact mirror), "
        + "plan (dry-run diff of `yaml` against current state; changes nothing — "
        + "use it to preview a big or destructive change, then apply). "
        + "Documents are merge-by-default: absent keys stay untouched, explicit null clears an "
        + "override. Entities match by name. plan/apply accept YAML or JSON; export/schema take "
        + "format: \"json\" for machine-readable output. "
        + "`delegation.spawnable_agents` is the list of custom agents the Orchestrator may delegate "
        + "to (it replaces the whole list); admitting a cloud model for them stays in Settings → Orchestrator. "
        + "Secrets never travel through the document — creating a "
        + "cloud provider opens the secure credential sheet, and keyed MCP/search providers report "
        + "needs_user_action for Settings. Never put an API key, token, or password in the YAML."
    public let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array([
                    .string("schema"), .string("export"), .string("plan"),
                    .string("apply"),
                ]),
                "description": .string("Operation to perform."),
            ]),
            "yaml": .object([
                "type": .string("string"),
                "description": .string("The YAML document for plan / apply."),
            ]),
            "sections": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string(
                    "For export / schema: only include these sections "
                        + "(e.g. [\"agents\", \"schedules\"])."),
            ]),
            "prune": .object([
                "type": .string("boolean"),
                "description": .string(
                    "For plan / apply: delete entries NOT listed in the document's declared "
                        + "sections. Destructive — defaults to false."),
            ]),
            "format": .object([
                "type": .string("string"),
                "enum": .array([.string("yaml"), .string("json")]),
                "description": .string(
                    "For export / schema: output format. Default yaml. plan / apply "
                        + "auto-accept both (JSON is a YAML subset)."),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    /// Apply can open user-paced credential sheets and approval prompts,
    /// so the tool opts out of the registry's 120s wall-clock budget.
    public var bypassRegistryTimeout: Bool { true }

    // Intel has no `configure_osaurus` capability grant; the single human
    // gate is the plan-review card below (as for `orchestrator_config`).
    public var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    /// Applies are gated by the dedicated in-chat plan-review card (see
    /// `handleApply`), which shows the actual diff — so the generic
    /// args-JSON approval panel is skipped to avoid a double prompt.
    var handlesOwnApproval: Bool { true }

    /// Documents larger than this are rejected outright.
    static let maxDocumentBytes = 512 * 1024

    /// Test seam: answers the approval in place of the modal. Honored ONLY
    /// under `RuntimeEnvironment.isUnderTests`, so no production path (and no
    /// model) can pre-approve a plan through it.
    @TaskLocal static var approvalOverrideForTests:
        (@Sendable (ConfigPlan, Bool) async -> ConfigApprovalOutcome)?

    public init() {}

    /// Last-line runtime gate: only a Default-agent chat turn may configure
    /// Osaurus (same wording as upstream's `ConfigurationToolBase`).
    static func defaultAgentGateFailure(tool: String) -> String? {
        guard let agentId = ChatExecutionContext.currentAgentId else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Configuration tools require a chat session context. "
                    + "They are only available from the Default agent inside Osaurus.",
                tool: tool,
                retryable: false
            )
        }
        if agentId != Agent.defaultId {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Configuration tools are only available to the Default agent. "
                    + "Switch to the Default agent in the sidebar to configure Osaurus.",
                tool: tool,
                retryable: false
            )
        }
        return nil
    }

    public func execute(argumentsJSON: String) async throws -> String {
        if let gate = Self.defaultAgentGateFailure(tool: name) {
            return gate
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireAction(
            args, allowed: ["schema", "export", "plan", "apply"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "schema": return handleSchema(args)
        case "export": return await handleExport(args)
        case "plan": return await handlePlan(args)
        case "apply": return await handleApply(args)
        default: return actionReq.failureEnvelope ?? ""
        }
    }

    // MARK: - schema

    private enum SectionsFilterParse {
        case success(Set<ConfigSectionID>?)
        case failure(String)
    }

    /// Parse an optional `sections` array argument into section ids, with a
    /// closest-match suggestion on unknown names. `nil` means no filter.
    private func parseSectionsFilter(
        _ args: [String: Any]
    ) -> SectionsFilterParse {
        // Models send both `["agents"]` and the bare string `"agents"` (or
        // `"agents, schedules"`); silently ignoring the string form hands a
        // small model the full schema blob it was trying to avoid.
        let names: [String]
        if let raw = args["sections"] as? [Any] {
            names = raw.compactMap { $0 as? String }
        } else if let raw = args["sections"] as? String {
            names = raw.split(whereSeparator: { ", ".contains($0) }).map(String.init)
        } else {
            return .success(nil)
        }
        var resolved = Set<ConfigSectionID>()
        for candidate in names {
            guard let id = ConfigSectionID.parse(candidate) else {
                var message = "Unknown section `\(candidate)`."
                if let suggestion = Self.closestSectionName(to: candidate) {
                    message += " Did you mean `\(suggestion)`?"
                } else {
                    message += " Valid: " + ConfigSectionID.allNames.joined(separator: ", ") + "."
                }
                return .failure(
                    ToolEnvelope.failure(
                        kind: .invalidArgs, message: message, field: "sections", tool: name))
            }
            resolved.insert(id)
        }
        return .success(resolved.isEmpty ? nil : resolved)
    }

    /// Best section-name suggestion for a miss. Curated aliases first (the
    /// misses models actually make), then prefix containment.
    static func closestSectionName(to candidate: String) -> String? {
        let lowered = candidate.lowercased()
        let aliases: [String: String] = [
            "mcp": "mcp_servers",
            "mcps": "mcp_servers",
            "provider": "providers",
            "model": "models",
            "agent": "agents",
            "schedule": "schedules",
            "command": "commands",
            "channel": "channels",
            "knowledge": "knowledge_collections",
        ]
        if let alias = aliases[lowered] { return alias }
        return ConfigSectionID.allNames.first {
            $0.hasPrefix(lowered) || lowered.hasPrefix($0)
        }
    }

    private static let schemaNextStep =
        "Compose the YAML for the section(s) you need and call action `apply` "
        + "(plan first is optional — apply plans and asks the user itself)."

    private func handleSchema(_ args: [String: Any]) -> String {
        guard let format = ConfigDocumentFormat.parse(args["format"] as? String) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`format` must be yaml or json.",
                field: "format", tool: name)
        }
        // Models routinely scope the ask ("sections": ["models"]); honoring
        // the filter keeps the reply inside a small model's budget instead
        // of returning the full multi-section blob it then re-requests.
        let filter: Set<ConfigSectionID>?
        switch parseSectionsFilter(args) {
        case .failure(let envelope): return envelope
        case .success(let resolved): filter = resolved
        }
        switch format {
        case .yaml:
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "schema": ConfigSchemaReference.text(sections: filter),
                    "sections": ConfigSectionID.allNames,
                    "next_step": Self.schemaNextStep,
                ]
            )
        case .json:
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "json_schema": ConfigManifest.jsonSchema(),
                    "sections": ConfigSectionID.allNames,
                    "next_step": Self.schemaNextStep,
                ]
            )
        }
    }

    // MARK: - export

    private func handleExport(_ args: [String: Any]) async -> String {
        let filter: Set<ConfigSectionID>?
        switch parseSectionsFilter(args) {
        case .failure(let envelope): return envelope
        case .success(let resolved): filter = resolved
        }

        guard let format = ConfigDocumentFormat.parse(args["format"] as? String) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`format` must be yaml or json.",
                field: "format", tool: name)
        }

        let document = await MainActor.run { ConfigExporter.export(sections: filter) }
        var result: [String: Any] = [:]
        do {
            switch format {
            case .yaml: result["yaml"] = try ConfigYAML.encode(document)
            case .json: result["json"] = try ConfigJSON.encode(document)
            }
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Failed to render the document: \(error.localizedDescription)",
                tool: name
            )
        }

        // The settings-section read path (inspect's unknown-scope redirect)
        // lands here; without an outright next move small models re-export
        // or ask the user instead of applying.
        result["next_step"] =
            "These are the CURRENT values. To change them, call action `apply` with a "
            + "minimal document containing only the keys to change (same shape as this "
            + "export). If the user only asked a question, answer from these values."
        // A scoped export also carries the section's full key roster: the
        // exported YAML omits empty maps (e.g. `tools.policies` with no
        // entries), and models read that omission as "the key doesn't
        // exist" and invent alternatives.
        if let filter {
            result["yaml_shape"] = ConfigManifest.renderedSchemaSections(only: filter)
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - plan

    private func handlePlan(_ args: [String: Any]) async -> String {
        let prune = coerceBool(args["prune"]) ?? false
        let document: OsaurusConfigDocument
        switch await loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc): document = doc
        }

        do {
            let plan = try await MainActor.run { [document] in
                try ConfigPlanner.plan(document: document, prune: prune)
            }
            var result = plan.payload()
            // The dry-run marker rides on the summary itself: models read
            // the summary, mistake it for an outcome, and narrate success
            // without ever calling apply. `status` is the typed twin.
            result["summary"] =
                plan.isEmpty
                ? plan.summaryText()
                : "[DRY RUN — nothing changed yet] " + plan.summaryText()
            result["status"] = plan.isEmpty ? "no_changes" : "dry_run_not_applied"
            result["prune"] = prune
            if plan.hasHighRiskChanges {
                result["note"] =
                    "This plan contains high-risk changes — apply will require explicit user approval."
            }
            // Small models stall here, re-planning the same document
            // instead of executing it (or asking the user "shall I?" —
            // approval is a native one-tap card, never a chat question);
            // say the next move outright.
            result["next_step"] =
                plan.isEmpty
                ? "No changes — the current state already matches this document."
                : "Dry run only — NOTHING was changed. If the plan is right, call action "
                    + "`apply` with this same document NOW, in this same turn. The user "
                    + "approves via a native one-tap card — do not ask for confirmation in chat."
            return ToolEnvelope.success(tool: name, result: result)
        } catch let issues as ConfigPlanIssues {
            return invalidDocumentEnvelope(issues)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: error.localizedDescription, tool: name)
        }
    }

    // MARK: - apply

    private func handleApply(_ args: [String: Any]) async -> String {
        let prune = coerceBool(args["prune"]) ?? false
        let document: OsaurusConfigDocument
        switch await loadDocument(args) {
        case .failure(let envelope): return envelope
        case .success(let doc): document = doc
        }

        let plan: ConfigPlan
        do {
            plan = try await MainActor.run { [document] in
                try ConfigPlanner.plan(document: document, prune: prune)
            }
        } catch let issues as ConfigPlanIssues {
            return invalidDocumentEnvelope(issues)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError, message: error.localizedDescription, tool: name)
        }

        if plan.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "status": "no_changes",
                    "summary": plan.summaryText(),
                ]
            )
        }

        // EVERY apply gets the dedicated plan-review approval — the in-chat
        // card renders the structured diff (with risks highlighted and a
        // prune warning) and its answer resolves this await. This is the
        // single human gate for config changes: the tool opts out of the
        // generic registry approval panel (`handlesOwnApproval`), so the
        // headless task locals are re-checked HERE, mirroring
        // `ToolRegistry.runPermissionGate`: external/headless surfaces are
        // auto-denied (never park a card nobody can answer). Intel has no
        // eval lane to auto-approve and no `isUnattendedDispatch` flag, so
        // an attended run is exactly an interactive chat turn
        // (`interactiveChatRun`) or the owner's paired phone; schedules,
        // watchers and background dispatches are refused, never reconfigure
        // the app on their own (owner policy, 2026-11-18). The owner's paired
        // phone is attended: its runs park the plan for the phone to answer
        // (`GET /config/approvals`, MOBILE_PROTOCOL §16.3), with longer to
        // read it than the Mac's card gives.
        let approval: ConfigApprovalOutcome
        if RuntimeEnvironment.isUnderTests, let override = Self.approvalOverrideForTests {
            approval = await override(plan, prune)
        } else if ChatExecutionContext.denyUnapprovedToolPrompts
            || (ChatExecutionContext.isExternalSurface && !ChatExecutionContext.hasRemoteReviewer)
            || !(ChatExecutionContext.interactiveChatRun || ChatExecutionContext.hasRemoteReviewer)
        {
            // Nobody was asked, so the model must not be told the user said
            // no: that reads as a decision and ends the setup it was doing.
            return ToolEnvelope.failure(
                kind: .permissionDenied,
                message: "Configuration changes need the user's approval in the Osaurus app, "
                    + "and this run has no way to show it. Nothing was applied.",
                tool: name,
                retryable: false
            )
        } else if ChatExecutionContext.hasRemoteReviewer {
            approval = await ConfigApprovalQueue.shared.requestApproval(
                plan: plan,
                prune: prune,
                fromPairedPhone: true,
                timeout: .seconds(300)
            )
        } else {
            approval = await ConfigApprovalService.requestApproval(plan: plan, prune: prune)
        }
        switch approval {
        case .approved:
            break
        case .denied:
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "User declined the configuration changes. Nothing was applied.",
                tool: name,
                retryable: false
            )
        case .timedOut:
            return ToolEnvelope.failure(
                kind: .timeout,
                message: "Configuration review timed out. Nothing was applied.",
                tool: name,
                retryable: false
            )
        case .cancelled:
            return ToolEnvelope.failure(
                kind: .userDenied,
                message: "Configuration review was cancelled. Nothing was applied.",
                tool: name,
                retryable: false
            )
        }

        let results = await ConfigApplier.apply(document: document, prune: prune)
        if Task.isCancelled {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Apply was cancelled; some changes may already have been made — "
                    + "run osaurus_config({action: 'plan', ...}) to see the remaining diff.",
                tool: name,
                retryable: false
            )
        }

        let failed = results.filter { $0.status == .failed }
        let cancelled = results.filter { $0.status == .cancelled }
        let needsAction = results.filter { $0.status == .needsUserAction }
        let started = results.filter { $0.status == .started }
        // "applied" must mean everything landed. Long-running work (model
        // downloads) is only STARTED at return time; say so at the top level
        // instead of letting a fire-and-forget download read as complete.
        // A user-cancelled step (e.g. dismissing the credential sheet) is
        // NOT applied either — report partial, never a clean success.
        let status: String
        if !failed.isEmpty || !cancelled.isEmpty {
            status = "partial"
        } else if !started.isEmpty {
            status = "applied_downloads_running"
        } else {
            status = "applied"
        }
        var result: [String: Any] = [
            "status": status,
            "results": results.map { $0.payload },
        ]
        var notes: [String] = []
        // Prune honesty: models remove an imagined entry by applying an
        // imagined keep-list, which CREATES the phantom entries and deletes
        // nothing — then they narrate a removal. Say what really happened.
        if prune {
            let deletes = plan.actions.filter { $0.kind == .delete }
            if deletes.isEmpty {
                notes.append(
                    "prune: true deleted NOTHING — no entry outside your keep-list existed. "
                        + "If you meant to remove an entry, it was not configured; tell the "
                        + "user that instead of reporting a removal.")
            }
            let creates = plan.actions.filter { $0.kind == .create }
            if !creates.isEmpty {
                notes.append(
                    "This apply CREATED \(creates.count) new entr\(creates.count == 1 ? "y" : "ies") "
                        + "(\(creates.map { $0.target }.joined(separator: ", "))) that were in "
                        + "your document but not previously configured — do not describe these "
                        + "as pre-existing or as survivors of a removal.")
            }
        }
        if !failed.isEmpty {
            notes.append("\(failed.count) change(s) failed — see results for messages.")
        }
        if !cancelled.isEmpty {
            notes.append(
                "\(cancelled.count) change(s) were cancelled by the user and did not land.")
        }
        if !needsAction.isEmpty {
            notes.append(
                "\(needsAction.count) change(s) need the user to finish a step in Settings "
                    + "(credentials never travel through this tool).")
        }
        if !started.isEmpty {
            notes.append(
                "\(started.count) download(s) started — poll osaurus_inspect({action: 'status'}).")
        }
        if !notes.isEmpty { result["notes"] = notes }
        // A clean success must SAY it is terminal. Every other action ends
        // with a next_step, and `plan`'s is "apply this document NOW" — so a
        // success with no next move trained small models that every envelope
        // implies another call. Observed live: an 8B orchestrator re-created
        // a just-created Watcher under variant names, twice, after a clean
        // apply. Name what landed and say stop.
        //
        // Gated on needsAction being empty as well: `status` stays "applied"
        // when a change merely needs the user to finish a step in Settings
        // (credentials), and a DONE-and-stop instruction there would tell the
        // model to bury exactly the step the notes surface. That case gets a
        // truthful next_step naming the outstanding user step instead.
        if status == "applied" {
            let landed = results.map { "\($0.section)[\($0.target)]" }
                .joined(separator: ", ")
            if needsAction.isEmpty {
                result["next_step"] =
                    "DONE — all changes landed"
                    + (landed.isEmpty ? "" : " (\(landed))")
                    + ". Report this to the user and stop. Do not plan or apply again "
                    + "unless the user asks for something different."
            } else {
                result["next_step"] =
                    "Changes landed, but \(needsAction.count) of them need the user to "
                    + "finish a step in Settings (see notes). Tell the user exactly which "
                    + "step remains, then stop — do not plan or apply again."
            }
        }
        return ToolEnvelope.success(tool: name, result: result)
    }

    // MARK: - Document loading

    private enum DocumentLoad {
        case success(OsaurusConfigDocument)
        case failure(String)
    }

    /// Models that fill every argument send `yaml: "{}"`; an empty document
    /// carries nothing, so it counts as absent.
    static func isEmptyDocument(_ yaml: String) -> Bool {
        ["", "{}", "null", "~"].contains(yaml.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func loadDocument(_ args: [String: Any]) async -> DocumentLoad {
        let trimmedYAML = (args["yaml"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let yaml = trimmedYAML.flatMap({ Self.isEmptyDocument($0) ? nil : $0 }) else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Provide the document as `yaml` (inline). "
                        + "Call {action: 'schema'} for the YAML reference.",
                    tool: name))
        }
        if yaml.utf8.count > Self.maxDocumentBytes {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Document too large (max \(Self.maxDocumentBytes / 1024) KB).",
                    field: "yaml",
                    tool: name))
        }
        do {
            return .success(try ConfigYAML.decode(yaml))
        } catch let error as ConfigYAMLError {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Document is invalid — nothing was changed:\n"
                        + error.messages.map { "• \($0)" }.joined(separator: "\n"),
                    field: "yaml",
                    tool: name))
        } catch {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Could not parse YAML: \(error.localizedDescription)",
                    field: "yaml",
                    tool: name))
        }
    }


    private func invalidDocumentEnvelope(_ issues: ConfigPlanIssues) -> String {
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Document is invalid — nothing was changed:\n"
                + issues.issues.map { "• \($0)" }.joined(separator: "\n"),
            field: "yaml",
            tool: name
        )
    }
}
