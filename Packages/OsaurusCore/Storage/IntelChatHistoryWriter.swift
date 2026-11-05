//
//  IntelChatHistoryWriter.swift
//  osaurus
//
//  `W-plugin-reliability` stage 2d (docs/UPSTREAM_SYNC.md, "Plugin
//  inference"): upstream's `ChatHistoryWriter.persist` for Intel's chat
//  store. Upstream writes plugin `complete` / `complete_stream`
//  conversations to its SQLCipher chat history so they show in the sidebar
//  with a plugin badge; Intel's chats live in `ChatSessionsManager`.
//
//  Same grouping: a call with a `session_id` (the external key) updates the
//  one chat for `(plugin, session_id, agent)`, replacing its turns with the
//  latest full conversation; a call without one adds a new chat.
//
//  Intel takes the turns ready-made: the plugin's messages as it sent them
//  plus the run's own turns, so the system prompt and the memory block the
//  host added are never saved (upstream strips them with
//  `InjectedContextSpans`, not on Intel).
//

#if OSAURUS_INTEL

import Foundation

@MainActor
enum ChatHistoryWriter {
    @discardableResult
    static func persist(
        source: SessionSource,
        sourcePluginId: String?,
        agentId: UUID?,
        externalKey: String?,
        turns: [ChatTurnData],
        model: String
    ) -> UUID? {
        guard !turns.isEmpty else { return nil }
        // Upstream stores a nil agent as NULL (the Default agent); Intel's
        // sessions always name one.
        let owner = agentId ?? Agent.defaultId
        let manager = ChatSessionsManager.shared
        let now = Date()

        let existing: ChatSessionData? = externalKey.flatMap { key in
            manager.sessions.values.first {
                $0.source == source && $0.sourcePluginId == sourcePluginId
                    && $0.externalSessionKey == key && $0.agentId == owner
            }
        }

        let session: ChatSessionData
        if var hit = existing {
            hit.turns = turns
            hit.updatedAt = now
            hit.selectedModel = model
            if hit.title == "New Chat" {
                hit.title = ChatSessionData.generateTitle(from: turns)
            }
            session = hit
        } else {
            session = ChatSessionData(
                id: UUID(),
                title: ChatSessionData.generateTitle(from: turns),
                createdAt: now,
                updatedAt: now,
                selectedModel: model,
                turns: turns,
                agentId: owner,
                source: source,
                sourcePluginId: source == .plugin ? sourcePluginId : nil,
                externalSessionKey: externalKey
            )
        }
        manager.save(session)
        return session.id
    }
}

#endif
