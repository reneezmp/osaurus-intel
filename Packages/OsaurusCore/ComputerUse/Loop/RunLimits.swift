//
//  RunLimits.swift
//  osaurus
//
//  Upstream's `RunLimits` from `ComputerUseLoop.swift` (the Computer Use loop
//  itself comes with `W-computer-use`); the AppleScript loop uses it too
//  (docs/SUBAGENTS_INTEL.md, layer 2).
//

import Foundation

/// Termination knobs. Defaults are conservative; PR2/PR3 may tune them off
/// the eval sweep.
public struct RunLimits: Sendable {
    /// Hard cap on productive steps (perceive→act cycles).
    public var maxSteps: Int
    /// Consecutive invalid `agent_action` shapes before giving up (re-ask budget).
    public var maxConsecutiveInvalid: Int
    /// Consecutive reobserve attempts for the same target before it's a dead end.
    public var maxConsecutiveReobserve: Int
    /// Consecutive dead ends before the run terminates.
    public var maxConsecutiveDeadEnd: Int
    /// Wall-clock budget for the whole run.
    public var wallClockSeconds: TimeInterval
    /// Per-model-step inference budget. A single hung inference is aborted (and
    /// retried per `maxInferenceRetries`) instead of stalling until the whole
    /// `wallClockSeconds`. `<= 0` disables the per-step timeout.
    public var modelStepTimeoutSeconds: TimeInterval
    /// Extra attempts after a model-step throws/times out before the run fails.
    /// e.g. `2` means up to three tries total, with a short backoff between.
    public var maxInferenceRetries: Int
    /// Consecutive identical acting actions (same verb+target+payload) before
    /// the run dead-ends as stalled. `<= 0` disables stall detection. Verbs
    /// where repetition is legitimate progress (scroll/observe/wait/find) are
    /// exempt.
    public var maxRepeatedActions: Int
    /// When true (production default), a `done` after at least one acting
    /// step is only accepted once some step's verify (or a later observe /
    /// wait) saw the view change. Synthesized macOS input is fire-and-forget,
    /// so without this a run whose every click was silently dropped could
    /// still report success. The model gets ONE bounded challenge to observe
    /// and confirm; a second unverified `done` ends the run as `gaveUp`.
    /// Scripted evals that only exercise gate/parse contracts may turn it off.
    public var requireVerifiedChangeForDone: Bool

    public init(
        maxSteps: Int = 24,
        maxConsecutiveInvalid: Int = 3,
        maxConsecutiveReobserve: Int = 2,
        maxConsecutiveDeadEnd: Int = 3,
        wallClockSeconds: TimeInterval = 300,
        modelStepTimeoutSeconds: TimeInterval = 90,
        maxInferenceRetries: Int = 2,
        maxRepeatedActions: Int = 4,
        requireVerifiedChangeForDone: Bool = true
    ) {
        self.maxSteps = max(1, maxSteps)
        self.maxConsecutiveInvalid = max(1, maxConsecutiveInvalid)
        self.maxConsecutiveReobserve = max(1, maxConsecutiveReobserve)
        self.maxConsecutiveDeadEnd = max(1, maxConsecutiveDeadEnd)
        self.wallClockSeconds = wallClockSeconds
        self.modelStepTimeoutSeconds = modelStepTimeoutSeconds
        self.maxInferenceRetries = max(0, maxInferenceRetries)
        self.maxRepeatedActions = maxRepeatedActions
        self.requireVerifiedChangeForDone = requireVerifiedChangeForDone
    }
}
