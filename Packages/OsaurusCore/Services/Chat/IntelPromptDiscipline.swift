//
//  IntelPromptDiscipline.swift
//  osaurus
//
//  Upstream's static discipline sections for Intel's chat composer
//  (`SystemPromptComposer.composeChatContext` in IntelDataConformers).
//  Upstream's composer (`SystemPromptComposer.swift`, not compiled on Intel)
//  appends them in this order and with these gates (#1317, #1430; texts at
//  `bce907045`):
//  - Model family guidance: any chat with tools on, picked by the model id.
//  - Grounding: any non-empty tool schema. The discovery-aware variant names
//    `capabilities_discover`; Intel offers the `capabilities` gateway, so it
//    gets the base variant, as upstream's gateway schemas do.
//  - Code style: a file-authoring tool is offered.
//  - Risk-aware actions: a tool that edits files or runs commands is offered.
//  - Agent loop: `todo`, `complete`, `clarify` or `share_artifact` is offered.
//
//  Lean path (#2250): none of these render for a custom agent or a folder
//  chat; see `usesLeanPath`.
//
//  Not here: Secret handling, Self-improvement and the sandbox discovery
//  ladder are sandbox-only (no containers on Intel); Bulk edits names
//  `redact_file` / `detect_pii` and lands with `W-privacy-filter`. Intel
//  doesn't size models by context class, so the compact variants (upstream:
//  small local windows) are never chosen.
//

import Foundation

enum IntelPromptDiscipline {
    struct Section: Equatable {
        let id: String
        let label: String
        let text: String
    }

    /// Upstream `SystemPromptComposer.mutationToolNames` (Intel has no
    /// sandbox tools; the names stay so the sets read the same).
    static let mutationToolNames: Set<String> = [
        "sandbox_write_file", "sandbox_exec", "sandbox_install",
        "file_write", "file_edit", "shell_run",
    ]

    /// Upstream `SystemPromptComposer.codeEditToolNames`.
    static let codeEditToolNames: Set<String> = [
        "sandbox_write_file", "file_write", "file_edit",
    ]

    /// Upstream `SystemPromptComposer.agentLoopToolNames` (Intel's
    /// `ToolRegistry.agentLoopToolNames` also holds time and calculate).
    static let agentLoopToolNames: Set<String> = [
        "todo", "complete", "clarify", "share_artifact",
    ]

    /// Upstream #2250 (`appendGatedSections`): any custom agent, and any chat
    /// with a working folder, takes the lean prompt and skips these sections
    /// (and the registry guidance, Apple apps, knowledge and agent DB
    /// onboarding blocks). Only the built-in Default agent without a folder
    /// keeps the full set. Upstream also takes the lean path for sandbox
    /// chats; Intel has no sandbox.
    static func usesLeanPath(agentId: UUID, hasFolder: Bool) -> Bool {
        agentId != Agent.defaultId || hasFolder
    }

    /// The sections for one request, in upstream's order. `toolsOff` is the
    /// global or per-agent Disable Tools switch; `toolNames` is the final
    /// schema the request offers.
    static func sections(
        modelId: String?, toolNames: Set<String>, toolsOff: Bool, lean: Bool = false
    ) -> [Section] {
        guard !toolsOff, !lean else { return [] }
        var out: [Section] = []
        if let family = ModelFamilyGuidance.guidance(forModelId: modelId) {
            out.append(Section(id: "modelFamilyGuidance", label: "Model Family Guidance", text: family))
        }
        guard !toolNames.isEmpty else { return out }
        out.append(
            Section(
                id: "grounding",
                label: "Grounding",
                text: SystemPromptTemplates.groundingDirective(
                    discoveryAvailable: toolNames.contains("capabilities_discover"))
            ))
        if !toolNames.isDisjoint(with: codeEditToolNames) {
            out.append(Section(id: "codeStyle", label: "Code Style", text: SystemPromptTemplates.codeStyleGuidance))
        }
        if !toolNames.isDisjoint(with: mutationToolNames) {
            out.append(
                Section(id: "riskAware", label: "Risk-Aware Actions", text: SystemPromptTemplates.riskAwareGuidance))
        }
        if !toolNames.isDisjoint(with: agentLoopToolNames) {
            out.append(
                Section(
                    id: "agentLoopGuidance",
                    label: "Agent Loop",
                    text: SystemPromptTemplates.agentLoopGuidance(
                        compact: false,
                        includeShareArtifact: toolNames.contains("share_artifact"))
                ))
        }
        return out
    }
}
