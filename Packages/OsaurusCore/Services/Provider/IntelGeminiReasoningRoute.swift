//
//  IntelGeminiReasoningRoute.swift
//  OsaurusCore — Intel fork
//
//  Upstream #3115 attaches Gemini reasoning levels to a picker item only when
//  the item's provider forwards the effort intact
//  (`GeminiReasoningContract.routeHonorsContract`). Intel's picker options
//  come from `ModelProfileRegistry`, which sees only the model id, so the
//  composer asks here: the owning provider is resolved from the
//  provider-qualified id the way `CloudChatEngine.resolveEndpoint` does.
//

import Foundation

enum IntelGeminiReasoningRoute {
    /// Whether the composer may offer the reasoning-effort control for
    /// `modelId`. Always true for models outside the Gemini contract (their
    /// own profiles decide); for a Gemini text model, true only when its
    /// provider forwards the effort. An id with no provider prefix match is
    /// treated as not forwarding, so nothing it can't use is shown.
    @MainActor
    static func offersEffort(forModelId modelId: String) -> Bool {
        offersEffort(forModelId: modelId, providers: RemoteProviderManager.shared.configuration.providers)
    }

    static func offersEffort(forModelId modelId: String, providers: [RemoteProvider]) -> Bool {
        guard GeminiReasoningContract.entry(forModelId: modelId) != nil else { return true }
        let lowered = modelId.lowercased()
        let owner = providers
            .filter(\.enabled)
            .first { lowered.hasPrefix(IntelRemoteModelEligibility.providerPrefix($0.name) + "/") }
        guard let owner else { return false }
        return GeminiReasoningContract.routeHonorsContract(providerType: owner.providerType, host: owner.host)
    }
}
