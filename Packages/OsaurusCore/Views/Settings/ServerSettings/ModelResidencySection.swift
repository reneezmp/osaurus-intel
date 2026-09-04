//
//  ModelResidencySection.swift
//  osaurus
//
//  Osaurus-owned model memory policy (eviction + idle residency) for
//  the Server → Settings tab. Persisted to `server.json`.
//
//  Local-inference-only: eviction/idle-residency policy governs when a
//  loaded MLX model is dropped from RAM. Intel is cloud-only and never
//  loads a local model, so this file (and its `.modelMemory` sidebar
//  anchor) isn't compiled there — this wasn't previously gated because
//  nothing on Intel used to reference `ServerSettingsSection.modelMemory`
//  at all; it does now that the Intel Settings tab is real.
//

#if !OSAURUS_INTEL
import SwiftUI

struct ModelResidencySection: View {
    @Binding var draft: ServerConfiguration
    @Environment(\.theme) private var theme

    var body: some View {
        ServerSettingsCard(
            section: .modelMemory,
            status: .hostOwned,
            blurb:
                "When to evict a loaded model from RAM, and how long to keep it warm after the last request.",
            spacing: 16
        ) {
            SettingsSubsection(label: "Eviction Policy") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $draft.modelEvictionPolicy) {
                        ForEach(ModelEvictionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(draft.modelEvictionPolicy.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            SettingsSubsection(label: "Keep Model Loaded") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $draft.modelIdleResidencyPolicy) {
                        ForEach(ModelIdleResidencyPolicy.presets, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(draft.modelIdleResidencyPolicy.description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }
}
#endif
