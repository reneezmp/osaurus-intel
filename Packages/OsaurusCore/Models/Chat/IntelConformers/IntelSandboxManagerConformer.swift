//
//  IntelSandboxManagerConformer.swift
//  OsaurusCore
//
//  Intel-fork conformer for SandboxManager + nested State.
//  Scope: Phase 8A — satisfies NativeBlockViews call sites only.
//  All values are no-op defaults. Sandbox subsystem is amputated on Intel.
//  Extend this conformer's surface when later phases un-body-swap
//  FloatingInputCard, AgentsView, OnboardingView, SandboxView,
//  ProvisioningJourneyView.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - SandboxManager

enum SandboxManager {
    @MainActor
    final class State: ObservableObject {
        static let shared = State()

        @Published var availability: SandboxAvailability = .unavailable(reason: "Intel — sandbox not supported")
        @Published var status: ContainerStatus = .notProvisioned
        @Published var provisioningPhase: String? = nil
        @Published var provisioningProgress: Double? = nil
        @Published var isProvisioning: Bool = false
        /// Phase 8C surface — FloatingInputCard's sandbox chip reads this
        /// to flip the chip red + show a tooltip when the active agent's
        /// sandbox provisioning failed. Always nil on Intel (no sandbox
        /// = no failure reason).
        @Published var activeAgentUnavailability: SandboxToolRegistrar.UnavailabilityReason? = nil
    }
}

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
