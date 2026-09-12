//
//  OrchestratorSettingsView.swift
//  osaurus
//
//  Intel-safe configuration for the built-in Orchestrator.
//

import SwiftUI

struct OrchestratorSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var displayName = ""
    @State private var systemPrompt = ""
    @State private var temperature = ""
    @State private var maxTokens = ""
    @State private var selectedModel: String?
    @State private var pickerItems: [ModelPickerItem] = []
    @State private var delegation = OrchestratorDelegationConfiguration.default
    @State private var showModelPicker = false
    @State private var showDelegationSheet = false
    @State private var showDeclarativeConfigurationSheet = false
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeaderWithActions(
                title: L("Orchestrator"),
                subtitle: L("Configure the built-in agent that sets up Osaurus and delegates work")
            ) {
                HeaderSecondaryButton("Restore Defaults", icon: "arrow.counterclockwise") {
                    restoreDefaults()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    capabilityStrip
                    identitySection
                    generationSection
                    delegationSection
                    declarativeConfigurationSection
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .sheet(isPresented: $showDelegationSheet) {
            OrchestratorDelegationSheet()
                .environment(\.theme, theme)
        }
        .sheet(isPresented: $showDeclarativeConfigurationSheet) {
            IntelOrchestratorConfigSheet()
                .environment(\.theme, theme)
        }
        .onAppear(perform: load)
        .onReceive(ModelPickerItemCache.shared.$items) { pickerItems = $0 }
        .onChange(of: formSnapshot) { _ in scheduleSave() }
        .onDisappear(perform: flushSave)
    }

    private var capabilityStrip: some View {
        HStack(alignment: .top, spacing: 12) {
            capabilityTile("slider.horizontal.3", "Configures Osaurus", "Its saved identity and generation settings drive new chats.")
            capabilityTile("point.3.connected.trianglepath.dotted", "Delegates one turn", "Only custom agents and remote cloud models you explicitly admit can run.")
            capabilityTile("person.text.rectangle", "Yours to shape", "Rename it and give it a persona below.")
        }
    }

    private func capabilityTile(_ icon: String, _ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(theme.accentColor)
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            Text(LocalizedStringKey(caption), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.cardBackground).overlay(
            RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1)
        ))
    }

    private var identitySection: some View {
        SettingsSection(title: "Identity", icon: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 18) {
                StyledSettingsTextField(
                    label: "Name", text: $displayName, placeholder: "Osaurus",
                    help: "Leave blank to use Osaurus. The name appears in the agent picker and chat header."
                )
                promptEditor
            }
        }
    }

    private var promptEditor: some View {
        SettingsField(label: "System Prompt", hint: "Optional persona appended to the Orchestrator's built-in instructions.") {
            ZStack(alignment: .topLeading) {
                if systemPrompt.isEmpty {
                    Text("Enter the Orchestrator's instructions...", bundle: .module)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.placeholderText)
                        .padding(14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground).overlay(
                RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
            ))
        }
    }

    private var generationSection: some View {
        SettingsSection(title: "Generation", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 18) {
                modelField
                SettingsSliderField(label: "Temperature", help: "Randomness from 0 to 2. Leave Restore Defaults to inherit global chat settings.", text: $temperature, range: 0 ... 2, step: 0.1, defaultValue: 0.7, formatString: "%.1f")
                SettingsStepperField(label: "Max Output Tokens", help: "Optional per-response cap. Blank inherits the active model default.", text: $maxTokens, range: 1 ... 65536, step: 1024, defaultValue: 16384)
            }
        }
    }

    private var modelField: some View {
        SettingsField(label: "Model", hint: "Leave inherited to use the current global chat model.") {
            Button { showModelPicker.toggle() } label: {
                HStack {
                    Image(systemName: "cloud.fill")
                    Text(selectedModel.map(formattedModelName) ?? L("Inherited from General"))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                }
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.inputBackground).overlay(
                    RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1)
                ))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView(
                    options: pickerItems,
                    selectedModel: $selectedModel,
                    agentId: Agent.defaultId,
                    onDismiss: { showModelPicker = false }
                )
            }
        }
    }

    private var delegationSection: some View {
        SettingsSection(title: "Delegation", icon: "point.3.connected.trianglepath.dotted") {
            OrchestratorDelegationSettings(
                configuration: $delegation,
                pickerItems: pickerItems,
                onPersist: saveDelegation,
                onRun: { showDelegationSheet = true }
            )
        }
    }

    private var declarativeConfigurationSection: some View {
        SettingsSection(title: "Declarative Configuration", icon: "list.bullet.rectangle.portrait") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Describe changes as JSON, inspect the exact before-and-after plan, and approve it explicitly before the Intel Orchestrator applies anything.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label("Gate 5 · bounded Intel scope", systemImage: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                    Button("Open Configuration…") {
                        showDeclarativeConfigurationSheet = true
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
        }
    }

    private struct FormSnapshot: Equatable {
        let name: String; let prompt: String; let model: String?; let temperature: String; let maxTokens: String
        let delegation: OrchestratorDelegationConfiguration
    }

    private var formSnapshot: FormSnapshot {
        FormSnapshot(
            name: displayName,
            prompt: systemPrompt,
            model: selectedModel,
            temperature: temperature,
            maxTokens: maxTokens,
            delegation: delegation
        )
    }

    private func load() {
        let config = DefaultAgentConfigurationStore.load()
        displayName = config.displayName ?? ""
        systemPrompt = config.systemPrompt ?? ""
        selectedModel = config.defaultModel
        temperature = config.temperature.map { String($0) } ?? ""
        maxTokens = config.maxTokens.map { String($0) } ?? ""
        delegation = config.delegation
        loaded = true
        Task { await ModelPickerItemCache.shared.prewarmModelCache() }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func flushSave() { saveTask?.cancel(); if loaded { save() } }

    private func save() {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let temp = Float(temperature.trimmingCharacters(in: .whitespacesAndNewlines)).map { min(2, max(0, $0)) }
        let tokens = Int(maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)).map { max(1, $0) }
        var config = DefaultAgentConfigurationStore.load()
        config.displayName = name.isEmpty ? nil : name
        config.systemPrompt = systemPrompt
        config.defaultModel = selectedModel
        config.temperature = temp
        config.maxTokens = tokens
        config.delegation = delegation
        AgentManager.shared.updateDefaultAgentConfiguration(config)
    }

    private func saveDelegation(_ delegation: OrchestratorDelegationConfiguration) {
        self.delegation = delegation
        var config = DefaultAgentConfigurationStore.load()
        config.delegation = delegation
        AgentManager.shared.updateDefaultAgentConfiguration(config)
    }

    private func restoreDefaults() {
        loaded = false
        displayName = ""; systemPrompt = ""; selectedModel = nil; temperature = ""; maxTokens = ""
        delegation = .default
        AgentManager.shared.updateDefaultAgentConfiguration(.default)
        loaded = true
    }

    private func formattedModelName(_ identifier: String) -> String {
        identifier.split(separator: "/").last.map(String.init) ?? identifier
    }
}
