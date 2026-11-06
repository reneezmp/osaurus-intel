//
//  IntelPluginRepository.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2g-3 (docs/UPSTREAM_SYNC.md, "Plugin
//  installer, step 3"): the Intel pieces around upstream's
//  `PluginRepositoryService`.
//
//  - The registry is the Intel plugin repo, in upstream's format
//    (`plugins/<name>.json` specs with x86_64 artifacts signed with
//    minisign; docs/INTEL_PLUGIN_PUBLISHING.md). Upstream's
//    `osaurus-ai/osaurus-tools` ships arm64 builds only.
//  - `PluginState.requiresAppleSilicon` keeps Intel's badge for a spec with
//    no artifact for this build's architecture.
//

#if OSAURUS_INTEL

import Foundation
import OsaurusRepository

enum IntelPluginRegistry {
    /// The Intel plugin repo, read through upstream's source-archive refresh.
    static let repositoryURL = "https://github.com/reneezmp/osaurus-intel-plugins.git"

    /// Points upstream's registry manager at the Intel repo. Idempotent.
    static func configure() {
        CentralRepositoryManager.shared.central = CentralRepository(url: repositoryURL, branch: "main")
    }
}

extension PluginRepositoryService {
    /// Plugin ids whose registry spec has no artifact for this build's
    /// architecture, from the last refresh.
    @MainActor static var pluginIdsWithoutHostArtifact: Set<String> = []

    /// Records the specs this build can't install (no artifact for
    /// `CPUArch.host`).
    @MainActor static func recordHostArtifacts(of specs: [PluginSpec]) {
        let host = CPUArch.host.rawValue
        pluginIdsWithoutHostArtifact = Set(
            specs
                .filter { spec in !spec.versions.contains { $0.artifacts.contains { $0.arch == host } } }
                .map(\.plugin_id)
        )
    }
}

extension PluginState {
    /// True when the registry has no artifact for this Mac's architecture,
    /// so Install is disabled and the card shows "Apple Silicon".
    @MainActor var requiresAppleSilicon: Bool {
        PluginRepositoryService.pluginIdsWithoutHostArtifact.contains(pluginId)
    }
}

#endif
