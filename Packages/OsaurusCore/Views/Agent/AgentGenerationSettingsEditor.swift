import SwiftUI

/// Custom-agent generation overrides: temperature, Top P/K, Min P, penalties,
/// seed, stop sequences, Max Tokens, Thinking and reasoning effort.
///
/// Port of upstream Classic's `AgentGenerationSettingsEditor` (#3233, #3245,
/// #3246) for Intel (`W-agent-generation-overrides`). Differences, all forced by
/// Ventura or by Intel having only remote providers:
/// - no `onGeometryChange` / two-value `onChange` (macOS 14): the layout is one
///   column and `savedDraft` changes use the single-value form;
/// - `ThemedSegmentedPicker` instead of native segmented pickers;
/// - Inherit rows read "Provider default": upstream resolves the local MLX
///   runtime's defaults for them, which Intel does not have;
/// - reasoning choices come from the provider catalog and model profiles
///   (`AgentGenerationReasoningChoices`), not local MLX discovery;
/// - no chat-template parameters, speculation, or native-diffusion notice.
///
/// Editing never writes the shared per-model option store.
struct AgentGenerationSettingsEditor: View {
    @Environment(\.theme) private var theme
    let modelID: String?
    let savedTemperature: Float?
    let savedMaxTokens: Int?
    let savedSettings: AgentGenerationSettings?
    let onSave: (AgentGenerationDraft.Values) -> Void

    @State private var draft = AgentGenerationDraft()
    @State private var lastSavedDraft = AgentGenerationDraft()
    @State private var error: String?

    private var savedDraft: AgentGenerationDraft {
        .init(temperature: savedTemperature, maxTokens: savedMaxTokens, settings: savedSettings)
    }

    private var choices: AgentGenerationReasoningChoices? {
        modelID.map { AgentGenerationReasoningChoices.resolve(modelID: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            group(L("Sampling"), subtitle: L("How tokens are chosen")) {
                parameter(
                    L("Temperature"),
                    description: L("Randomness of token choice. Lower is more focused, higher is more varied."),
                    field: .temperature)
                parameter(
                    L("Top P"),
                    description: L("Sample only from tokens within this cumulative probability (0–1)."),
                    field: .topP)
                parameter(
                    L("Top K"), description: L("Sample only from the K most likely tokens."), field: .topK)
                parameter(
                    L("Min P"),
                    description: L("Drop tokens below this fraction of the most likely token's probability."),
                    field: .minP)
            }
            group(L("Length & reasoning"), subtitle: L("How much and when to stop")) {
                parameter(
                    L("Max Tokens"),
                    description: L("Upper limit on tokens generated in one response, including reasoning."),
                    field: .maxTokens)
                reasoningControls
                stopSequences
            }
            group(L("Repetition"), subtitle: L("Discourage repeated text")) {
                parameter(
                    L("Repetition penalty"),
                    description: L("Multiplicative penalty on tokens already used. 1.0 means off."),
                    field: .repetitionPenalty)
                parameter(
                    L("Frequency penalty"),
                    description: L("Penalizes tokens in proportion to how often they've appeared."),
                    field: .frequencyPenalty)
                parameter(
                    L("Presence penalty"),
                    description: L("Penalizes tokens that have appeared at least once."),
                    field: .presencePenalty)
            }
            group(L("Reproducibility"), subtitle: "") {
                parameter(
                    L("Seed"),
                    description: L("A fixed seed requests repeatable sampling; results also depend on the provider."),
                    field: .seed)
            }

            if let error,
                !AgentGenerationField.allCases.contains(where: { draft.validationMessage(for: $0) == error })
            {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Reset to inherited")) {
                    draft = AgentGenerationDraft()
                    save()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                Spacer()
                Button(L("Save generation defaults"), action: save)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
        }
        .onAppear {
            let saved = savedDraft
            draft = saved
            lastSavedDraft = saved
            error = nil
        }
        // Single-value `onChange` (Ventura): remember the previous saved draft
        // by hand so an edit from another surface merges into untouched rows.
        .onChange(of: savedDraft) { latest in
            draft.mergeSavedChanges(from: lastSavedDraft, to: latest)
            lastSavedDraft = latest
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    L(
                        "Available settings inherit the model and provider defaults. Switch a setting to Custom to override it for this agent only."
                    )
                )
                .font(.system(size: 12)).foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(String(format: L("Overrides: %d"), draft.overrideCount))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(theme.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.accentColor.opacity(0.10), in: Capsule())
                    .fixedSize()
            }
            Text(
                L(
                    "Each provider only receives the settings it accepts. If a provider cannot use a setting, the send stops with a message naming it."
                )
            )
            .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(
        _ title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold)).tracking(0.7).foregroundColor(theme.accentColor)
                Spacer()
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundColor(theme.tertiaryText)
                }
            }
            Divider().overlay(theme.cardBorder)
            content()
        }
    }

    private func rowLabel(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.primaryText)
            if !description.isEmpty {
                Text(description).font(.system(size: 11)).foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Parameter rows

    private func modePicker(field: AgentGenerationField) -> some View {
        ThemedSegmentedPicker(
            selection: Binding(
                get: { draft[keyPath: field.path].isCustom },
                set: { draft[keyPath: field.path].setCustom($0, inheritedText: field.seedText) }
            ),
            options: [(value: false, title: L("Inherit")), (value: true, title: L("Custom"))]
        )
        .frame(width: 168)
    }

    private func inheritedValue(_ field: AgentGenerationField) -> some View {
        HStack(spacing: 6) {
            Text(field.inheritedText).font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                    theme.inputBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func parameter(_ title: String, description: String, field: AgentGenerationField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLabel(title, description)
            HStack(alignment: .top, spacing: 12) {
                modePicker(field: field)
                parameterValue(title, field: field)
            }
            if let message = draft.validationMessage(for: field) { validation(message) }
        }
    }

    @ViewBuilder
    private func parameterValue(_ title: String, field: AgentGenerationField) -> some View {
        if draft[keyPath: field.path].isCustom {
            StyledTextField(
                placeholder: L("Value"),
                text: Binding(
                    get: { draft[keyPath: field.path].text },
                    set: { draft[keyPath: field.path].text = $0 })
            )
            .accessibilityLabel(Text(title))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(
                    draft.validationMessage(for: field) == nil ? Color.clear : .red, lineWidth: 1)
            )
        } else {
            inheritedValue(field)
        }
    }

    private func validation(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundColor(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Reasoning

    @ViewBuilder
    private var reasoningControls: some View {
        if modelID == nil {
            Text(L("Choose a model to detect its reasoning controls."))
                .font(.system(size: 11)).foregroundColor(theme.tertiaryText)
        } else if let choices {
            if choices.hasEfforts {
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel(L("Reasoning effort"), "")
                    ThemedSegmentedPicker(
                        selection: $draft.reasoningEffort,
                        options: [(value: "", title: L("Inherit"))]
                            + choices.efforts.map { (value: $0.id, title: $0.label) }
                    )
                    if !draft.reasoningEffort.isEmpty,
                        !choices.efforts.contains(where: { $0.id == draft.reasoningEffort })
                    {
                        unsupportedReasoning
                    }
                }
            } else if !draft.reasoningEffort.isEmpty {
                unsupportedReasoning
            }
            if choices.showsThinkingControl {
                VStack(alignment: .leading, spacing: 8) {
                    rowLabel(
                        L("thinking.mode.label"),
                        L("Let the model reason before answering, on models that support it."))
                    ThemedSegmentedPicker(
                        selection: $draft.thinking,
                        options: [
                            (value: "inherit", title: L("Inherit")), (value: "on", title: L("On")),
                            (value: "off", title: L("Off")),
                        ]
                    )
                    .frame(width: 252)
                }
            } else if draft.thinking != "inherit" {
                unsupportedReasoning
            }
        }
    }

    private var unsupportedReasoning: some View {
        HStack {
            Text(L("Saved reasoning choices are not supported by the selected model."))
                .font(.system(size: 11)).foregroundColor(.orange)
            Button(L("Use Inherit")) {
                draft.reasoningEffort = ""
                draft.thinking = "inherit"
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(theme.accentColor)
        }
    }

    // MARK: - Stop sequences

    private var stopSequences: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowLabel(
                L("Stop sequences"),
                L("Generation ends when any additional stop string is produced. Model end-of-turn tokens still apply."))
            HStack(alignment: .top, spacing: 12) {
                modePicker(field: .stop)
                if !draft.stop.isCustom { inheritedValue(.stop) }
            }
            if draft.stop.isCustom {
                VStack(alignment: .leading, spacing: 8) {
                    let values = (try? JSONDecoder().decode([String].self, from: Data(draft.stop.text.utf8))) ?? []
                    // Adaptive columns keep long exact strings reachable at narrow widths.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                        alignment: .leading, spacing: 6
                    ) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            HStack(spacing: 8) {
                                Text(String(reflecting: value)).font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2).help(value)
                                Spacer(minLength: 0)
                                Button {
                                    var edited = values
                                    edited.remove(at: index)
                                    do { try draft.setStopSequences(edited) } catch {
                                        self.error = error.localizedDescription
                                    }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    Text(String(format: L("Remove stop sequence %d"), index + 1)))
                            }.padding(8)
                                .background(theme.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
                        }
                    }
                    HStack {
                        StyledTextField(
                            placeholder: L("Type a sequence, press Enter"),
                            text: $draft.pendingStopSequence
                        )
                        .accessibilityLabel(Text(L("New stop sequence")))
                        .onSubmit(commitStopSequence)
                        Button(L("Add"), action: commitStopSequence)
                            .buttonStyle(.plain).foregroundColor(theme.accentColor)
                            .disabled(draft.pendingStopSequence.isEmpty)
                    }
                    Text(L("Text is kept exactly as entered. Saving also adds a pending sequence."))
                        .font(.system(size: 10)).foregroundColor(theme.tertiaryText)
                }
            }
            if let message = draft.validationMessage(for: .stop) { validation(message) }
        }
    }

    private func commitStopSequence() {
        do { try draft.commitStopSequence() } catch { self.error = error.localizedDescription }
    }

    // MARK: - Save

    private func save() {
        do {
            try draft.commitStopSequence()
            let values = try draft.validated()
            if let settings = values.settings, settings.hasReasoningOverride {
                guard let choices else {
                    throw ChatTurnOverrides.ValidationError.invalid(
                        L("Choose a model to save reasoning controls."))
                }
                try choices.validate(settings: settings)
            }
            onSave(values)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
