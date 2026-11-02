//
//  IntelCodexCLIModels.swift
//  osaurus
//
//  The model side of the Server tab's "Use with Codex CLI" card on Intel
//  (`W-server-api` stage 8). Upstream offers the on-device models; Intel
//  offers the cloud models `/v1/models` lists, with their catalog context
//  windows, and flags Osaurus Router models (they spend credits, so a
//  key-less Codex needs Credits' local API opt-in).
//

import Foundation

@MainActor
enum IntelCodexCLIModels {
    /// The ids `/v1/models` lists, in its order, without repeats.
    static func servedModelIds() -> [String] {
        var seen: Set<String> = []
        return RemoteProviderManager.shared.getOpenAIModels().map(\.id).filter { seen.insert($0).inserted }
    }

    /// The picker's catalog context length for a served id (the same
    /// `provider-name/model` id), bounded as upstream bounds it (no
    /// on-device KV cap here).
    static func contextWindow(for modelId: String, items: [ModelPickerItem]? = nil) -> Int? {
        guard !modelId.isEmpty else { return nil }
        let catalog = (items ?? ModelPickerItemCache.shared.items).first { $0.id == modelId }?.contextLength
        return CodexCLIConfiguration.effectiveContextWindow(bundleContextLength: catalog, kvRetentionCap: nil)
    }

    /// The id prefix `getOpenAIModels` gives a provider's models.
    nonisolated static func servedIdPrefix(providerName: String) -> String {
        providerName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    /// Whether a served id belongs to the Osaurus Router provider.
    static func isOsaurusRouterModel(_ modelId: String, providers: [RemoteProvider]? = nil) -> Bool {
        let all = providers ?? RemoteProviderManager.shared.configuration.providers
        guard let router = all.first(where: { $0.id == RemoteProviderManager.osaurusRouterProviderId }) else {
            return false
        }
        return modelId.hasPrefix(servedIdPrefix(providerName: router.name) + "/")
    }
}
