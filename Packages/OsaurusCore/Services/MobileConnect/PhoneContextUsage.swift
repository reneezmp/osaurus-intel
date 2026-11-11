//
//  PhoneContextUsage.swift
//  osaurus
//
//  The chat composer's context ring for a phone chat (MOBILE_PROTOCOL
//  §14.13, upstream #3209): the same breakdown and budget math the Mac's own
//  chip runs (`FloatingInputCard.contextBudget`), priced for the next send
//  from the saved session, the agent's prompt and tools, and its memory.
//  Typing and attachments aren't counted: the phone hasn't sent them.
//
//  Intel: priced with `IntelContextBudget` and the Intel restored-session
//  preview (persona + registered tools, as `ChatView` builds it). Saved chats
//  don't carry a compaction summary here, so there is no summary row.
//

import Foundation

@MainActor
enum PhoneContextUsage {

    struct Response: Encodable, Equatable {
        /// Estimated tokens the next send occupies.
        let tokens: Int
        /// The effective budget the runtime trims against (window x safety
        /// margin): the ring's denominator. Nil when the window is unknown.
        let usable_tokens: Int?
        /// The model's full context window.
        let max_tokens: Int?
        /// `tokens` over `usable_tokens`; nil when the window is unknown.
        let ratio: Double?
        /// At or past 85% of the budget: older messages will be compacted.
        let near_limit: Bool
        /// The prompt, tools and memory alone don't fit the window.
        let hard_overflow: Bool
        /// Where the window came from: `model_catalog`, `provider_metadata`
        /// or `user_setting`.
        let window_source: String?
        /// The popover's rows, as the Mac's chip lists them: prompt sections,
        /// memory and tools, then the conversation, input and output.
        let context: [Entry]
        let messages: [Entry]
        /// Set when the model's window is too small for tools or memory, which
        /// the composer then leaves out.
        let auto_disabled: AutoDisabled?
    }

    struct Entry: Encodable, Equatable {
        let id: String
        let label: String
        let tokens: Int
        /// `ContextBreakdown.Tint`: purple, blue, orange, green, gray, cyan,
        /// teal or indigo.
        let tint: String

        init(_ entry: ContextBreakdown.Entry) {
            id = entry.id
            label = entry.label
            tokens = entry.tokens
            tint = entry.tint.rawValue
        }
    }

    struct AutoDisabled: Encodable, Equatable {
        let tools: Bool
        let memory: Bool
        let model: String?
        let context_length: Int?
    }

    static func compute(sessionId: UUID?, agentId: UUID, model: String?) async -> Response {
        let saved = sessionId.flatMap { ChatSessionsManager.shared.session(for: $0) }
        // A long chat is hundreds of turns to rebuild and price: off the
        // main thread, which the phone would otherwise stall on every refresh.
        let turnData = saved?.turns ?? []
        let priced = await Task.detached(priority: .userInitiated) { priceConversation(turnData) }.value

        let model = model ?? AgentManager.shared.effectiveModel(for: agentId)
        let persona = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        let tools = ChatConfiguration.shared.disableTools ? [] : ToolRegistry.shared.openAISpecs()
        var sections: [PromptSection] = []
        if !persona.isEmpty {
            sections.append(PromptSection(id: "persona", label: "Persona", text: persona, tint: .purple))
        }
        let preview = ComposedContext(prompt: persona, tools: tools, promptSections: sections)
        let breakdown = ContextBreakdown.from(
            context: preview,
            conversationTokens: priced.conversation,
            inputTokens: 0,
            outputTokens: priced.output,
            fallbackMemoryTokens: await memoryTokens(for: agentId)
        )

        let resolution = IntelContextBudget.resolveWindow(modelId: model)
        let window = resolution?.tokens
        let assessment =
            window.map {
                IntelContextBudget.assess(
                    breakdown: breakdown,
                    contextWindow: $0,
                    maxResponseTokens: AgentManager.shared.effectiveMaxTokens(for: agentId)
                )
            } ?? .empty
        return Response(
            tokens: breakdown.total,
            usable_tokens: window.map(IntelContextBudget.effectiveBudget(contextWindow:)),
            max_tokens: window,
            ratio: assessment.usageRatio,
            near_limit: assessment.nearLimit,
            hard_overflow: assessment.hardOverflow,
            window_source: resolution.map { sourceName($0.source) },
            context: breakdown.context.map(Entry.init),
            messages: breakdown.messages.map(Entry.init),
            auto_disabled: nil
        )
    }

    private static func sourceName(_ source: IntelContextBudget.WindowSource) -> String {
        switch source {
        case .modelCatalog: return "model_catalog"
        case .providerMetadata: return "provider_metadata"
        case .userSetting: return "user_setting"
        }
    }

    /// The saved chat's share of the next send: its turns and the assistant's
    /// output among them.
    private nonisolated static func priceConversation(
        _ data: [ChatTurnData]
    ) -> (conversation: Int, output: Int) {
        guard !data.isEmpty else { return (0, 0) }
        let turns = data.map(ChatTurn.init(from:))
        let output = ContextBudgetManager.estimateOutputTokens(for: turns)
        return (ContextBudgetManager.estimateTokens(for: turns) - output, output)
    }

    /// The memory snippet the next send would carry, as the chip prices it.
    private static func memoryTokens(for agentId: UUID) async -> Int {
        guard !AgentManager.shared.effectiveMemoryDisabled(for: agentId) else { return 0 }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: agentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        return ContextBudgetManager.estimateTokens(for: context)
    }
}
