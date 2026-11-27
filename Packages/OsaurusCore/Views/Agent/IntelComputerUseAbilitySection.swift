//
//  IntelComputerUseAbilitySection.swift
//  osaurus
//
//  W-computer-use stage 5: a custom agent's switch for `computer_use`.
//  Upstream keeps it in the agent's Subagents tab; Intel mounts it in the
//  Abilities tab next to Browser Use. Custom agents only. The switch is off by
//  default and only the user's click turns it on; nothing here requests a
//  system permission (Accessibility is granted from Settings → Computer Use,
//  by a click on its Grant button).
//

import SwiftUI

struct IntelComputerUseAbilitySection: View {
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var pickerCache = ModelPickerItemCache.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    let agentId: UUID
    let theme: ThemeProtocol

    private static let capabilityId = SubagentCapabilityRegistry.computerUse.id
    private var settings: AgentSettings? { agentManager.agent(for: agentId)?.settings }

    var body: some View {
        AgentDetailSection(title: L("Computer Use"), icon: "cursorarrow.rays") {
            VStack(alignment: .leading, spacing: 10) {
                if agentId == Agent.defaultId {
                    note(
                        "The built-in agent never controls your Mac. Create an agent to use Computer Use."
                    )
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9).fill(theme.accentColor.opacity(0.10)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Computer Use"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(
                                L(
                                    "Let the agent control macOS apps for you: clicking, typing, and reading the screen. Reads and navigation run automatically; edits and anything consequential pause for your approval."
                                )
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { settings?.computerUseEnabled ?? false },
                                set: { value in update { $0.computerUseEnabled = value } }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(ThemedSwitchToggleStyle())
                        .accessibilityLabel(Text(L("Computer Use")))
                    }
                    if settings?.computerUseEnabled == true {
                        HStack(spacing: 12) {
                            Text(L("Model"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            Spacer(minLength: 12)
                            modelMenu
                        }
                        .padding(.leading, 46)
                        HStack(spacing: 12) {
                            Text(L("Autonomy ceiling"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                            Spacer(minLength: 12)
                            ceilingMenu
                        }
                        .padding(.leading, 46)
                        if !permissionService.cachedIsGranted(.accessibility) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.warningColor)
                                Text(
                                    L(
                                        "Computer Use cannot start until Accessibility is granted. Open Settings → Computer Use and click Grant."
                                    )
                                )
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button(L("Open Settings")) {
                                    AppDelegate.shared?.showManagementWindow(initialTab: .computerUse)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accentColor)
                            }
                        }
                        note(
                            "Works only in a chat you are present in; schedules and background runs never control your Mac. Stop ends a run at once. Passwords, payment details and system dialogs are never filled in or answered for you."
                        )
                    }
                }
            }
        }
    }

    private var modelMenu: some View {
        let current = settings?.subagentModelOverrides[Self.capabilityId]
        let label: String = {
            guard let current, !current.isEmpty else { return L("Use the chat's model") }
            return pickerCache.items.first(where: { $0.id == current })?.displayName ?? "\(current) (\(L("unavailable")))"
        }()
        return Menu {
            Button(L("Use the chat's model")) { update { $0.subagentModelOverrides[Self.capabilityId] = nil } }
            ForEach(pickerCache.items.filter(\.isLikelyChatCapable), id: \.id) { item in
                Button("\(item.displayName) · \(item.source.displayName)") {
                    update { $0.subagentModelOverrides[Self.capabilityId] = item.id }
                }
            }
        } label: {
            menuLabel(label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// "At most <preset>" caps how far this agent can act whatever the global
    /// policy says (strictest wins); "No ceiling" stores nil.
    private var ceilingMenu: some View {
        let ceiling = settings?.computerUseCeiling
        let selected = ceiling?.matchingPreset
        let label: String = {
            guard let ceiling else { return L("No ceiling") }
            if let preset = ceiling.matchingPreset { return String(format: L("At most: %@"), preset.displayLabel) }
            return L("Custom")
        }()
        return Menu {
            Button(L("No ceiling")) { update { $0.computerUseCeiling = nil } }
            Divider()
            ForEach(AutonomyPreset.allCases) { preset in
                Button(
                    (selected == preset ? "✓ " : "") + String(format: L("At most: %@"), preset.displayLabel)
                ) {
                    update { $0.computerUseCeiling = AutonomyCeiling.cappedAt(preset) }
                }
            }
        } label: {
            menuLabel(label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
    }

    private func update(_ change: (inout AgentSettings) -> Void) {
        guard var agent = agentManager.agent(for: agentId), !agent.isBuiltIn else { return }
        change(&agent.settings)
        agent.updatedAt = Date()
        agentManager.update(agent)
    }

    private func note(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
