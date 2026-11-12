//
//  AgentAbilityContextPreviewBar.swift
//  osaurus
//
//  The Abilities context readout (upstream #2053/#2306/#2323): a compact
//  status capsule at the trailing edge of the Abilities sub-tab bar showing
//  the agent's estimated startup context, with a popover that explains it
//  and splits it into instructions, enabled abilities, tool descriptions and
//  the memory budget. Priced by `AgentAbilityContextPreview` through the same
//  composer gates the next real send uses.
//
//  Intel: upstream's view, minus the tiny-window auto-disable notice (local
//  models only). Nothing here needs macOS 14: the controls are plain buttons
//  and the numeric transition is macOS 13.
//

import SwiftUI

/// Compact Abilities-navigation status. Details live in a popover instead of
/// expanding inline, preserving the destination's vertical workspace.
struct AgentAbilityContextPreviewBar: View {
    let preview: AgentAbilityContextPreview?
    let delta: Int?
    let enabledCount: Int
    let totalCount: Int

    @Environment(\.theme) private var theme
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(statusColor)
                Text("Context", bundle: .module)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText)

                if let delta {
                    deltaChip(delta)
                }

                Text(compactEstimateText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                Text(compactImpactLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor.opacity(0.11)))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(controlFill)
                .overlay(
                    Capsule()
                        .stroke(controlBorder, lineWidth: 1)
                )
        )
        .localizedHelp("Show how much model context this agent uses")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            contextPopover
        }
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(statusColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Context impact", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .fixedSize()
                        Text(abilityCountText)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.tertiaryBackground))
                    }
                    Text(summaryText)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(fullEstimateText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                    Text(impactLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(statusColor)
                }
            }

            if let preview {
                AgentAbilityContextDetailsView(preview: preview)
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private var compactEstimateText: String {
        guard let preview else { return "…" }
        let low = AgentAbilityContextPreview.format(tokens: preview.lowTokens)
        if preview.isRange {
            let high = AgentAbilityContextPreview.format(tokens: preview.highTokens)
            return "~\(low)–\(high)"
        }
        return "~\(low)"
    }

    private var fullEstimateText: String {
        guard preview != nil else { return L("Estimating…") }
        return L("\(compactEstimateText) tokens")
    }

    private var abilityCountText: String {
        totalCount == 1
            ? L("\(enabledCount) of 1 ability on")
            : L("\(enabledCount) of \(totalCount) abilities on")
    }

    private var summaryText: String {
        guard let preview else {
            return L("Estimating how much of the model's working space this agent uses.")
        }
        if let fraction = preview.usableWindowFraction {
            return L(
                "This agent uses \(windowPercent(fraction)) of the model's working space before you start chatting."
            )
        }
        return L("This setup is loaded into the model before you start chatting.")
    }

    private var statusColor: Color {
        guard let preview else { return theme.accentColor }
        switch preview.severity {
        case .normal: return theme.accentColor
        case .warning: return theme.warningColor
        case .critical: return theme.errorColor
        }
    }

    private var impactLabel: String {
        guard let preview else { return L("Estimating") }
        switch preview.severity {
        case .warning:
            return L("High impact")
        case .critical:
            return L("At the limit")
        case .normal:
            guard let fraction = preview.usableWindowFraction else {
                return L("Estimated")
            }
            return fraction < 0.10 ? L("Low impact") : L("Moderate impact")
        }
    }

    private var compactImpactLabel: String {
        guard let preview else { return "…" }
        switch preview.severity {
        case .warning: return L("High")
        case .critical: return L("Limit")
        case .normal:
            guard let fraction = preview.usableWindowFraction else { return L("Estimate") }
            return fraction < 0.10 ? L("Low") : L("Moderate")
        }
    }

    private var controlFill: Color {
        guard let preview else { return theme.cardBackground }
        switch preview.severity {
        case .normal: return theme.cardBackground
        case .warning: return theme.warningColor.opacity(0.055)
        case .critical: return theme.errorColor.opacity(0.055)
        }
    }

    private var controlBorder: Color {
        guard let preview else { return theme.cardBorder }
        switch preview.severity {
        case .normal: return theme.cardBorder
        case .warning: return theme.warningColor.opacity(0.45)
        case .critical: return theme.errorColor.opacity(0.45)
        }
    }

    private func deltaChip(_ delta: Int) -> some View {
        let magnitude = AgentAbilityContextPreview.format(tokens: abs(delta))
        let text = delta > 0 ? "+\(magnitude)" : "−\(magnitude)"
        let color = delta > 0 ? theme.warningColor : theme.accentColor
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func windowPercent(_ fraction: Double) -> String {
        let pct = fraction * 100
        return pct < 1 ? "<1%" : "\(Int(pct.rounded()))%"
    }
}

/// Plain-language explanation and grouped costs. Raw manifest labels such as
/// "Platform" and "Enabled Capabilities" are intentionally not user-facing.
private struct AgentAbilityContextDetailsView: View {
    let preview: AgentAbilityContextPreview

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().foregroundColor(theme.cardBorder)

            Text(
                "Context is the model's working space. Agent instructions and tool descriptions use some of it before your first message; memory can add more on each turn. A larger setup can slow the first reply and leave less room for a very long conversation.",
                bundle: .module
            )
            .font(.system(size: 10.5))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.displayRows) { row in
                    HStack(spacing: 8) {
                        Text(Self.label(for: row.id))
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                        Text(L("~\(AgentAbilityContextPreview.format(tokens: row.tokens)) tokens"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Text(toolModeExplanation)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func label(for id: String) -> String {
        switch id {
        case "instructions": return L("Agent instructions")
        case "abilities": return L("Enabled abilities")
        case "tools": return L("Tool descriptions")
        default: return L("Memory added per message (up to)")
        }
    }

    private var toolModeExplanation: String {
        switch preview.toolMode {
        case .auto:
            return L("Auto-discover keeps this smaller by loading other assigned tools only when they are needed.")
        case .manual:
            return L("Manual mode includes every assigned tool, so assigning more tools increases context use.")
        }
    }
}
