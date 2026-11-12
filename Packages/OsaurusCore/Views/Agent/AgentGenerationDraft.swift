import Foundation

/// Port of upstream Classic's `AgentGenerationDraft` (#3233, #3246) without the
/// chat-template parameters and speculation fields (local MLX controls,
/// Incompatible on Intel).
struct AgentGenerationFieldDraft: Equatable {
    var isCustom = false
    var text = ""

    init(_ value: String? = nil) {
        isCustom = value != nil
        text = value ?? ""
    }

    /// Start a new override from the inherited value without discarding an unsaved edit.
    mutating func setCustom(_ enabled: Bool, inheritedText: String? = nil) {
        isCustom = enabled
        if enabled, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let inheritedText
        {
            text = inheritedText
        }
    }

    func value(named name: String) throws -> String? {
        guard isCustom else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw ChatTurnOverrides.ValidationError.invalid(
                String(format: L("Enter a value for %@, or select Inherit to use defaults."), name)
            )
        }
        return raw
    }

    func float(named name: String) throws -> Float? {
        guard let raw = try value(named: name) else { return nil }
        guard let number = Float(raw), number.isFinite else {
            throw ChatTurnOverrides.ValidationError.invalid(
                String(format: L("%@ must be a finite number."), name))
        }
        return number
    }

    func integer(named name: String) throws -> Int? {
        guard let raw = try value(named: name) else { return nil }
        guard let number = Int(raw) else {
            throw ChatTurnOverrides.ValidationError.invalid(
                String(format: L("%@ must be an integer."), name))
        }
        return number
    }
}

/// Unsaved editor text is separate from the persisted agent. Invalid input never erases a saved value.
struct AgentGenerationDraft: Equatable {
    var temperature = AgentGenerationFieldDraft()
    var maxTokens = AgentGenerationFieldDraft()
    var topP = AgentGenerationFieldDraft()
    var topK = AgentGenerationFieldDraft()
    var minP = AgentGenerationFieldDraft()
    var repetitionPenalty = AgentGenerationFieldDraft()
    var frequencyPenalty = AgentGenerationFieldDraft()
    var presencePenalty = AgentGenerationFieldDraft()
    var seed = AgentGenerationFieldDraft()
    var stop = AgentGenerationFieldDraft()
    // Keep unsubmitted chip input in the draft so Save cannot drop it.
    var pendingStopSequence = ""
    var thinking = "inherit"
    var reasoningEffort = ""

    init(temperature: Float? = nil, maxTokens: Int? = nil, settings: AgentGenerationSettings? = nil) {
        self.temperature = .init(temperature.map { String($0) })
        self.maxTokens = .init(maxTokens.map { String($0) })
        topP = .init(settings?.topP.map { String($0) })
        topK = .init(settings?.topK.map { String($0) })
        minP = .init(settings?.minP.map { String($0) })
        repetitionPenalty = .init(settings?.repetitionPenalty.map { String($0) })
        frequencyPenalty = .init(settings?.frequencyPenalty.map { String($0) })
        presencePenalty = .init(settings?.presencePenalty.map { String($0) })
        seed = .init(settings?.seed.map { String($0) })
        thinking = settings?.enableThinking.map { $0 ? "on" : "off" } ?? "inherit"
        reasoningEffort = settings?.reasoningEffort ?? ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        stop = .init(settings?.stop.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Refresh untouched fields when another surface saves the agent. Keep
    /// local text, pending chips and reasoning edits until the user saves them.
    mutating func mergeSavedChanges(from previous: Self, to latest: Self) {
        for field in AgentGenerationField.allCases {
            if field == .stop, pendingStopSequence != previous.pendingStopSequence { continue }
            let path = field.path
            if self[keyPath: path] == previous[keyPath: path] {
                self[keyPath: path] = latest[keyPath: path]
            }
        }
        if thinking == previous.thinking, reasoningEffort == previous.reasoningEffort {
            thinking = latest.thinking
            reasoningEffort = latest.reasoningEffort
        }
    }

    var overrideCount: Int {
        AgentGenerationField.allCases.filter { self[keyPath: $0.path].isCustom }.count
            + (thinking == "inherit" ? 0 : 1) + (reasoningEffort.isEmpty ? 0 : 1)
    }

    func stopSequencesIncludingPending() throws -> [String] {
        let raw = try stop.value(named: "Stop sequences") ?? "[]"
        var values = try JSONDecoder().decode([String].self, from: Data(raw.utf8))
        if !pendingStopSequence.isEmpty { values.append(pendingStopSequence) }
        return values
    }

    mutating func commitStopSequence() throws {
        guard stop.isCustom, !pendingStopSequence.isEmpty else { return }
        try setStopSequences(stopSequencesIncludingPending())
        pendingStopSequence = ""
    }

    mutating func setStopSequences(_ values: [String]) throws {
        stop.text = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    /// Reuse the save-time rules for inline errors; never maintain a second validator.
    func validationMessage(for field: AgentGenerationField) -> String? {
        var isolated = AgentGenerationDraft()
        isolated[keyPath: field.path] = self[keyPath: field.path]
        if field == .stop { isolated.pendingStopSequence = pendingStopSequence }
        do { _ = try isolated.validated(); return nil } catch { return error.localizedDescription }
    }

    struct Values {
        var temperature: Float?
        var maxTokens: Int?
        var settings: AgentGenerationSettings?
    }

    func validated() throws -> Values {
        let temperature = try temperature.float(named: "Temperature")
        try ChatTurnOverrides(temperature: temperature).validate()
        let maxTokens = try maxTokens.integer(named: "Max Tokens")
        if let maxTokens, maxTokens < 1 {
            throw ChatTurnOverrides.ValidationError.invalid("Max Tokens must be a positive integer.")
        }
        let stops = stop.isCustom ? try stopSequencesIncludingPending() : nil
        let settings = AgentGenerationSettings(
            topP: try topP.float(named: "Top P"),
            topK: try topK.integer(named: "Top K"),
            minP: try minP.float(named: "Min P"),
            repetitionPenalty: try repetitionPenalty.float(named: "Repetition penalty"),
            frequencyPenalty: try frequencyPenalty.float(named: "Frequency penalty"),
            presencePenalty: try presencePenalty.float(named: "Presence penalty"),
            seed: try seed.integer(named: "Seed"),
            stop: stops,
            enableThinking: thinking == "inherit" ? nil : thinking == "on",
            reasoningEffort: reasoningEffort.isEmpty ? nil : reasoningEffort
        )
        try settings.validate()
        return Values(temperature: temperature, maxTokens: maxTokens, settings: settings.isEmpty ? nil : settings)
    }
}

/// Shared field identity for layout, inherited previews and existing save validation.
enum AgentGenerationField: String, CaseIterable {
    case temperature, maxTokens, topP, topK, minP, repetitionPenalty
    case frequencyPenalty, presencePenalty, seed, stop

    var path: WritableKeyPath<AgentGenerationDraft, AgentGenerationFieldDraft> {
        switch self {
        case .temperature: \.temperature
        case .maxTokens: \.maxTokens
        case .topP: \.topP
        case .topK: \.topK
        case .minP: \.minP
        case .repetitionPenalty: \.repetitionPenalty
        case .frequencyPenalty: \.frequencyPenalty
        case .presencePenalty: \.presencePenalty
        case .seed: \.seed
        case .stop: \.stop
        }
    }

    /// What an Inherit row shows. Intel's providers are remote, so the real
    /// default is the provider's own and is never guessed here (upstream shows
    /// the local runtime's resolved values, which Intel does not have).
    var inheritedText: String {
        switch self {
        case .stop: return L("No additional stop strings")
        case .seed: return L("Random")
        case .maxTokens: return L("Response default")
        case .repetitionPenalty, .frequencyPenalty, .presencePenalty: return L("Provider default (off)")
        case .temperature, .topP, .topK, .minP: return L("Provider default")
        }
    }

    /// Text a new Custom override starts from (never invented for providers).
    var seedText: String? { self == .stop ? "[]" : nil }
}
