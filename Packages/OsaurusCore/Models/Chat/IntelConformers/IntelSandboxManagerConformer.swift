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
    }
}

#endif
