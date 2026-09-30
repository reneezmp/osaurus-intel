//
//  ToolPermissionPolicy.swift
//  osaurus
//
//  Permission model for tools and optional capability requirements.
//

import Foundation

enum ToolPermissionPolicy: String, Codable, Sendable {
    case auto
    case ask
    case deny

    var displayName: String {
        switch self {
        case .auto: return L("Auto")
        case .ask: return L("Ask")
        case .deny: return L("Deny")
        }
    }
}

/// Optional extension protocol for tools that declare requirements and default policy.
protocol PermissionedTool {
    /// Capability/requirement identifiers, e.g. "permission:web", "permission:folder", "tool:browser"
    var requirements: [String] { get }
    /// Default policy suggested by the tool (host configuration may override)
    var defaultPermissionPolicy: ToolPermissionPolicy { get }
    /// True when the tool owns a stricter, caller-independent approval flow.
    /// Generic Ask prompts must not run in front of that dedicated review.
    var handlesOwnApproval: Bool { get }
}

extension PermissionedTool {
    var handlesOwnApproval: Bool { false }
}

/// A tool whose approval can never be pre-granted: every single call shows the
/// card, and "Always Allow" is not offered (upstream `PerCallApprovalTool`).
/// Used for deletions such as `calendar_delete_event` / `reminders_delete`:
/// an Always Allow taken for anything else must never silently authorise
/// removal. On Intel, `ToolRegistry.policyInfo` clamps these tools' effective
/// policy to Ask (Deny still wins) and `setPolicy(.auto, …)` is refused.
protocol PerCallApprovalTool {
    /// Marker only. Conformance is the whole contract.
    var requiresApprovalEveryCall: Bool { get }
}

extension PerCallApprovalTool {
    var requiresApprovalEveryCall: Bool { true }
}

/// Argument-aware variant of `PerCallApprovalTool` (upstream): the same tool
/// is pre-grantable for some arguments and per-call for others.
/// `mail_compose` / `mail_reply` create a draft by default (Always Allow may
/// cover that) but SEND with `send: true`, and a send on the user's behalf
/// must show its card every time. Must be side-effect free: it runs before
/// approval and before execution.
protocol ArgumentAwarePerCallApprovalTool {
    func requiresApprovalEveryCall(argumentsJSON: String) -> Bool
}

/// A tool whose approval card renders a domain-specific review surface
/// instead of the generic pretty-printed JSON arguments block.
///
/// Exists because a knowledge write cannot be consented to as JSON: the
/// decision needs paths, create-vs-replace, and a diff. Deliberately narrow —
/// one method, resolved next to `ContextualPermissionedTool` in the registry's
/// `.ask` branch — rather than a general "custom approval view" mechanism
/// nothing else needs yet.
protocol KnowledgeWritePreviewingTool {
    /// Build the manifest for this invocation. Must be side-effect free: it
    /// runs before approval and before execution. Returning nil falls back to
    /// the JSON block, so a preview that cannot be built never blocks the call
    /// from being reviewed at all.
    func approvalPreview(argumentsJSON: String) async -> KnowledgeWritePreview?
}
