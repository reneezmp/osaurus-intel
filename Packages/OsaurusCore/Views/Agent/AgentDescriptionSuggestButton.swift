//
//  AgentDescriptionSuggestButton.swift
//  osaurus
//
//  "Suggest from instructions" for the agent description (upstream #158).
//  Explicit, one cloud request per press; the suggestion is written into the
//  field for the user to edit or keep. See `IntelAgentDescriptionGenerator`.
//

import SwiftUI

struct AgentDescriptionSuggestButton: View {
    @Environment(\.theme) private var theme

    let systemPrompt: String
    let agentModel: String?
    let onSuggestion: (String) -> Void

    @State private var isWorking = false

    private var hasInstructions: Bool {
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Button {
            suggest()
        } label: {
            HStack(spacing: 5) {
                if isWorking {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                }
                Text("Suggest from instructions", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(ThemedBorderedButtonStyle())
        .controlSize(.small)
        .disabled(isWorking || !hasInstructions)
        .localizedHelp(
            "Asks your Core Model for a one-line summary of this agent's instructions. This sends a small request to your cloud provider."
        )
    }

    private func suggest() {
        isWorking = true
        let prompt = systemPrompt
        let model = agentModel
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let suggestion = try await IntelAgentDescriptionGenerator.suggest(
                    systemPrompt: prompt, agentModel: model)
                onSuggestion(suggestion)
            } catch {
                _ = ToastManager.shared.error(
                    L("Couldn't suggest a description"), message: error.localizedDescription)
            }
        }
    }
}

/// Why a description matters, shown under an empty description field.
struct AgentDescriptionHint: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text(
            "Add a short purpose so the Orchestrator and agent pickers know what this agent is for.",
            bundle: .module
        )
        .font(.system(size: 11))
        .foregroundColor(theme.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
}
