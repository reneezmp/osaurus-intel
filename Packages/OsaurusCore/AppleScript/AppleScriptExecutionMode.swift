//
//  AppleScriptExecutionMode.swift
//  osaurus
//
//  Upstream's execution-mode enum from `AppleScriptModelCatalog.swift`. The
//  rest of that file names the curated on-device AppleScript models (MLX),
//  which Intel cannot run (docs/SUBAGENTS_INTEL.md).
//

import Foundation


/// How a generated AppleScript is gated before it runs. Per-agent (and a
/// global default for the Default / main chat agent). `confirmEach` is the
/// safe default: every state-CHANGING script is shown in the live chat feed
/// for explicit approval before it executes (classified read-only scripts
/// auto-run — they change nothing). `autoRunWithWarning` runs each mutating
/// script automatically but emits a prominent warning event (showing the
/// script) so the user can still see exactly what ran.
public enum AppleScriptExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Pause and show each state-changing AppleScript for explicit approval
    /// before it runs (default, safest). Read-only scripts auto-run.
    case confirmEach
    /// Run automatically, emitting a prominent warning (showing the script)
    /// before each mutating run.
    case autoRunWithWarning

    /// The conservative default applied when nothing is configured.
    public static var `default`: AppleScriptExecutionMode { .confirmEach }

    /// Tolerant decode of a stored raw value so a malformed/legacy string
    /// resolves to the safe default rather than refusing the whole config.
    public init(storedValue raw: String?) {
        self = raw.flatMap(AppleScriptExecutionMode.init(rawValue:)) ?? .default
    }

    /// Short label for pickers.
    public var displayName: String {
        switch self {
        case .confirmEach: return L("Confirm each script")
        case .autoRunWithWarning: return L("Auto-run with warning")
        }
    }

    /// One-line caption describing the safety trade-off.
    public var caption: String {
        switch self {
        case .confirmEach:
            return L(
                "Each script that changes anything is shown for your approval before it runs. Read-only scripts run automatically."
            )
        case .autoRunWithWarning:
            return L(
                "Scripts run automatically. A warning showing the script appears in the chat each time."
            )
        }
    }
}
