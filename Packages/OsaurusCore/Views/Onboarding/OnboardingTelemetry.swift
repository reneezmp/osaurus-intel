//
//  OnboardingTelemetry.swift
//  osaurus
//
//  Intel: upstream maps onboarding funnel moments onto `TelemetryService`
//  (Aptabase). Intel sends no telemetry, so this keeps upstream's call
//  surface as no-ops and the onboarding views can stay as upstream wrote
//  them.
//

import Foundation

@MainActor
enum OnboardingTelemetry {
    static func started() {}
    static func stepViewed(_ step: OnboardingStep) {}
    static func brainSourceSelected(_ source: BrainSource, downloadStarted: Bool? = nil) {}
    static func stepSkipped(_ step: OnboardingStep) {}
    static func completed(lastStep: OnboardingStep, via: Completion) {}

    enum Completion: String {
        /// Finished the flow through Configure AI.
        case finishButton = "finish_button"
        /// Closed early via the header X button.
        case closeButton = "close_button"
    }
}
