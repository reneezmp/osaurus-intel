//
//  IntelSubagentResidency.swift
//  osaurus
//
//  Intel's stand-in for upstream's `SubagentResidency.swift` and
//  `ResidencyHandoff.swift` (docs/SUBAGENTS_INTEL.md). Upstream decides
//  whether a local MLX subagent model can share the GPU with the resident
//  chat model, and wraps the run in unload/restore handoffs. Every subagent
//  on Intel runs on a cloud model, so the answer is always "remote, nothing
//  to hand off". The names and signatures are upstream's, so the kinds
//  compile unchanged.
//

import Foundation

/// Upstream's residency plan; on Intel only `.none` occurs.
struct ResidencyPlan: Sendable {
    var shouldUnload: Bool
    var requiredBytes: Int64 = 0
    var ramSafetyEnabled: Bool = false
    var maxElapsedSeconds: Int = 0
    var coexists: Bool = false

    static let none = ResidencyPlan(shouldUnload: false)

    var mode: String { "none" }
}

struct SubagentResidencyDecision: Sendable {
    let isLocal: Bool
    let plan: ResidencyPlan
}

enum SubagentResidency {
    /// Upstream resolves an installed local bundle; Intel has none, so every
    /// model is remote.
    static func resolve(
        modelName: String,
        config: SubagentConfiguration,
        idleWaitSeconds: Int,
        deniedMessage: String,
        invokingParentModelName: String?
    ) async throws -> SubagentResidencyDecision {
        SubagentResidencyDecision(isLocal: false, plan: .none)
    }

    static func refreshedPlan(
        for resolved: ResolvedModel,
        invokingParentModelName: String?,
        idleWaitSeconds: Int,
        deniedMessage: String
    ) async throws -> ResidencyPlan {
        guard resolved.isLocal else { return .none }
        throw SubagentError.unavailable("Local models need an Apple Silicon Mac.")
    }

    static func handoff(for plan: ResidencyPlan) -> SubagentHandoff {
        PassthroughHandoff()
    }

    static func admissionClass(isLocal: Bool, plan: ResidencyPlan) -> SubagentAdmissionClass {
        if plan.shouldUnload || plan.coexists { return .localExclusive }
        return isLocal ? .localInPlace : .remote
    }
}
