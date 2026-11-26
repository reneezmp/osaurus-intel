//
//  IntelSandboxManagerConformer.swift
//  OsaurusCore
//
//  Intel-fork conformer for SandboxToolRegistrar.UnavailabilityReason.
//  (SandboxManager itself moved to Services/Sandbox/IntelSandboxManager.swift.)
//  Extend this conformer's surface when later phases un-body-swap
//  FloatingInputCard, AgentsView, OnboardingView, SandboxView,
//  ProvisioningJourneyView.
//

#if OSAURUS_INTEL

import Foundation

// SandboxManager (and State) now live in Services/Sandbox/IntelSandboxManager.swift.

// MARK: - SandboxToolRegistrar.UnavailabilityReason (Intel stub)
//
// FloatingInputCard's sandbox chip references this nested type. Upstream
// lives in the excluded `Services/Sandbox/SandboxToolRegistrar.swift`.
// Stubbed as a minimal enum so the type resolves; cases mirror upstream
// well enough for the chip's title/help-text switches to compile, even
// though the value stays nil on Intel.
extension SandboxToolRegistrar {
    enum UnavailabilityReason: Sendable, Equatable {
        case containerOffline
        case provisioningFailed(String)
        case missingDependencies
        case other(String)

        var title: String {
            switch self {
            case .containerOffline: return "Sandbox offline"
            case .provisioningFailed: return "Sandbox provisioning failed"
            case .missingDependencies: return "Sandbox missing dependencies"
            case .other: return "Sandbox unavailable"
            }
        }

        var help: String {
            switch self {
            case .containerOffline:
                return "The sandbox container isn't running."
            case .provisioningFailed(let detail):
                return detail
            case .missingDependencies:
                return "One or more sandbox dependencies aren't installed."
            case .other(let detail):
                return detail
            }
        }

        /// Plain-text body used in the chip's tooltip. Alias for `help`
        /// so callers that ask for `.message` (the upstream API) keep
        /// type-checking.
        var message: String { help }
    }
}

#endif
