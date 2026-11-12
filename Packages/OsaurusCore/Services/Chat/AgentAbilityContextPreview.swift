//
//  AgentAbilityContextPreview.swift
//  osaurus
//
//  Prices an agent's DRAFT ability state for the Abilities readout (upstream
//  #2053/#2306/#2323): the editor's local toggle values are folded into an
//  `IntelAgentConfigSnapshot` (before the debounced save lands) and run
//  through the same `composePreviewContext` pipeline the chat Context Budget
//  popover uses, so the readout can never disagree with the next real send's
//  gates.
//
//  The headline number is the "estimated startup context": the static system
//  prompt plus the resolved tool schema a fresh chat would ship. It is not a
//  tokenizer-accurate count (everything rides on the shared chars/4
//  heuristic). Memory is a per-turn, query-dependent injection, so it is
//  surfaced as an upper bound (`memoryUpperTokens`, the configured memory
//  budget) that widens the estimate into a range.
//
//  Intel (stage 5b slice 5): upstream's tiny/small-window auto-disable
//  (`ContextDisableInfo`) is local-model only, so the readout has no
//  "turned off" notice; the draft covers the four switches Intel's Abilities
//  tab holds as local state (Tools, Memory, Database, Web Search) and every
//  other ability is read from the saved agent.
//

import Foundation

/// Result of pricing a draft ability state.
struct AgentAbilityContextPreview: Equatable {

    /// The editor's local values. Everything else comes from the saved agent.
    struct Draft: Equatable {
        var toolsEnabled: Bool
        var memoryEnabled: Bool
        var dbEnabled: Bool
        var webSearchEnabled: Bool
        /// The editor's local model selection (nil = the agent's effective model).
        var model: String?
    }

    /// Per-section breakdown (same shape the chat popover renders).
    let breakdown: ContextBreakdown
    /// Static prefix cost: system prompt sections + tool schema tokens.
    let staticTokens: Int
    /// Upper bound for the per-turn memory injection (0 when memory is off).
    /// Query-dependent at runtime, so this is the configured
    /// `memoryBudgetTokens` cap, not a prediction.
    let memoryUpperTokens: Int
    /// The resolved model's context window, when known.
    let contextWindow: Int?
    /// Effective selection mode used to compose the tool surface.
    let toolMode: ToolSelectionMode

    enum Severity: Equatable {
        case normal
        case warning
        case critical
    }

    /// Best-case startup tokens (no memory injected this turn).
    var lowTokens: Int { staticTokens }
    /// Worst-case startup tokens (memory budget fully used).
    var highTokens: Int { staticTokens + memoryUpperTokens }
    /// Whether the estimate is a range rather than a single value.
    var isRange: Bool { memoryUpperTokens > 0 }

    /// Runtime-safe portion of the model window (the remaining 15% absorbs
    /// tokenizer-estimation error, matching `ContextBudgetManager`).
    var usableContextWindow: Int? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return Int(Double(contextWindow) * ContextBudgetManager.safetyMargin)
    }

    /// Startup share of the usable window: how much room is consumed before
    /// conversation and output. Nil when the window is unknown.
    var usableWindowFraction: Double? {
        guard let usableContextWindow, usableContextWindow > 0 else { return nil }
        return min(1.0, Double(highTokens) / Double(usableContextWindow))
    }

    /// Restrained on purpose: a warning means the fixed startup payload
    /// already takes a quarter of the usable context; critical is a real
    /// safety-limit collision.
    var severity: Severity {
        guard let fraction = usableWindowFraction else { return .normal }
        if fraction >= 1 { return .critical }
        if fraction >= 0.25 { return .warning }
        return .normal
    }

    init(
        breakdown: ContextBreakdown,
        staticTokens: Int,
        memoryUpperTokens: Int,
        contextWindow: Int?,
        toolMode: ToolSelectionMode = .auto
    ) {
        self.breakdown = breakdown
        self.staticTokens = staticTokens
        self.memoryUpperTokens = memoryUpperTokens
        self.contextWindow = contextWindow
        self.toolMode = toolMode
    }

    static func == (lhs: AgentAbilityContextPreview, rhs: AgentAbilityContextPreview) -> Bool {
        lhs.staticTokens == rhs.staticTokens
            && lhs.memoryUpperTokens == rhs.memoryUpperTokens
            && lhs.contextWindow == rhs.contextWindow
            && lhs.toolMode == rhs.toolMode
            && lhs.breakdown.context == rhs.breakdown.context
    }

    /// Compact "2.1K"-style token formatting shared by the readout and the
    /// delta chip.
    static func format(tokens: Int) -> String {
        if tokens >= 1000 {
            let value = Double(tokens) / 1000.0
            return value >= 10
                ? "\(Int(value.rounded()))K"
                : String(format: "%.1fK", value)
        }
        return "\(tokens)"
    }

    /// The readout's three plain-language rows from a breakdown (upstream
    /// hides raw labels such as "Platform" and "Enabled Capabilities").
    struct DisplayRow: Equatable, Identifiable {
        let id: String
        let tokens: Int
    }

    var displayRows: [DisplayRow] {
        let entries = breakdown.context
        let instructions = entries.filter { $0.id == "platform" || $0.id == "persona" }
            .reduce(0) { $0 + $1.tokens }
        let tools = entries.filter { $0.id == "tools" }.reduce(0) { $0 + $1.tokens }
        let abilities = entries.filter {
            $0.id != "platform" && $0.id != "persona" && $0.id != "tools" && $0.id != "memory"
        }.reduce(0) { $0 + $1.tokens }
        var rows: [DisplayRow] = []
        if instructions > 0 { rows.append(DisplayRow(id: "instructions", tokens: instructions)) }
        if abilities > 0 { rows.append(DisplayRow(id: "abilities", tokens: abilities)) }
        if tools > 0 { rows.append(DisplayRow(id: "tools", tokens: tools)) }
        if memoryUpperTokens > 0 { rows.append(DisplayRow(id: "memory", tokens: memoryUpperTokens)) }
        return rows
    }

    /// Price `draft` against the saved agent. MainActor because the compose
    /// pipeline reads `AgentManager` / `ToolRegistry`. Call from state-change
    /// reactions (`.task(id:)`), never from a view body.
    @MainActor
    static func compute(agentId: UUID, draft: Draft) -> AgentAbilityContextPreview {
        var snapshot = IntelAgentConfigSnapshot.capture(agentId: agentId, projectId: nil)
        let isDefault = agentId == Agent.defaultId
        snapshot.agentToolsDisabled = !draft.toolsEnabled
        snapshot.databaseEnabled = !isDefault && draft.dbEnabled
        snapshot.webSearchEnabled = draft.webSearchEnabled
        // The global memory switch can veto a locally-flipped toggle.
        let memoryConfig = MemoryConfigurationStore.load()
        let memoryOn = draft.memoryEnabled && memoryConfig.enabled
        snapshot.memoryDisabled = !memoryOn

        let model = draft.model ?? AgentManager.shared.effectiveModel(for: agentId)
        let context = SystemPromptComposer.composePreviewContext(
            snapshot: snapshot,
            model: model,
            toolsDisabled: ChatConfiguration.shared.disableTools
        )
        var breakdown = ContextBreakdown.from(context: context)
        // The agent database state rides Intel's per-turn prefix and prices
        // as the memory rail in a preview; the readout shows the memory
        // budget separately, so keep it out of the static figure.
        breakdown.context.removeAll { $0.id == "memory" }

        return AgentAbilityContextPreview(
            breakdown: breakdown,
            staticTokens: breakdown.total,
            memoryUpperTokens: memoryOn ? memoryConfig.memoryBudgetTokens : 0,
            contextWindow: IntelContextBudget.resolveWindow(modelId: model)?.tokens,
            toolMode: snapshot.toolMode
        )
    }
}
