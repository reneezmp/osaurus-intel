//
//  IntelFrozenUserPrefixTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3c-3 (docs/COV_REAUDIT.md): upstream #1798's frozen
//  user-turn prefix. Memory and the time block are recorded on the user turn
//  they were first sent with and replayed byte for byte afterwards, so a
//  provider's prompt cache keeps the whole earlier exchange. Also #2089's
//  skill slug lookups and keyword search.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel frozen user prefix")
@MainActor
struct IntelFrozenUserPrefixTests {
    @Test("Memory comes first, the time block last, each with its separator")
    func prefixOrder() throws {
        let prefix = try #require(
            SystemPromptComposer.composeInjectedUserPrefix(memorySection: " a fact ", timeContext: "[Current Time] noon"))
        #expect(prefix == "[Memory]\na fact\n[/Memory]\n\n[Current Time] noon\n\n")
        #expect(SystemPromptComposer.composeInjectedUserPrefix(memorySection: nil, timeContext: "  ") == nil)
        #expect(
            SystemPromptComposer.composeInjectedUserPrefix(memorySection: "x", timeContext: nil)
                == "[Memory]\nx\n[/Memory]\n\n")
    }

    @Test("The block is frozen once; later sends keep the first bytes")
    func freezesOnce() async throws {
        try await ChatHistoryTestStorage.run {
            let session = ChatSession()
            let first = ChatTurn(role: .user, content: "What's on today?")
            session.turns = [first]
            session.freezeInjectedContextOntoLatestUserTurn(memorySection: "likes tea")
            let frozen = try #require(first.injectedContextPrefix)
            #expect(frozen.hasPrefix("[Memory]\nlikes tea\n[/Memory]\n\n"))
            // A regenerate of the same turn keeps it.
            session.freezeInjectedContextOntoLatestUserTurn(memorySection: "likes coffee")
            #expect(first.injectedContextPrefix == frozen)
            // The next user turn gets its own; the first one is unchanged.
            let reply = ChatTurn(role: .assistant, content: "Tea at four.")
            let second = ChatTurn(role: .user, content: "And tomorrow?")
            session.turns.append(contentsOf: [reply, second])
            session.freezeInjectedContextOntoLatestUserTurn(memorySection: "likes coffee")
            #expect(first.injectedContextPrefix == frozen)
            #expect(second.injectedContextPrefix?.contains("likes coffee") == true)
        }
    }

    @Test("Replay prepends the bytes, and a media message gets a leading text part")
    func replay() throws {
        let text = ChatSession.applyingFrozenInjectedPrefix("P\n\n", to: ChatMessage(role: "user", content: "hi"))
        #expect(text.content == "P\n\nhi")
        let untouched = ChatSession.applyingFrozenInjectedPrefix(nil, to: ChatMessage(role: "user", content: "hi"))
        #expect(untouched.content == "hi")
        let media = ChatMessage(role: "user", text: "look", imageData: [Data([0x89, 0x50])])
        let withPrefix = ChatSession.applyingFrozenInjectedPrefix("P\n\n", to: media)
        let parts = try #require(withPrefix.contentParts)
        guard case .text(let first) = try #require(parts.first) else {
            Issue.record("first part is not text")
            return
        }
        #expect(first == "P\n\n")
    }

    @Test("The frozen block is saved with the chat")
    func persists() throws {
        let turn = ChatTurn(role: .user, content: "q")
        turn.injectedContextPrefix = "[Memory]\nm\n[/Memory]\n\n"
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.injectedContextPrefix == turn.injectedContextPrefix)
        #expect(ChatTurn(from: decoded).injectedContextPrefix == turn.injectedContextPrefix)
        let legacy = try JSONDecoder().decode(
            ChatTurnData.self,
            from: Data(#"{"id":"\#(UUID().uuidString)","role":"user","content":"q","createdAt":0}"#.utf8))
        #expect(legacy.injectedContextPrefix == nil)
    }
}

@Suite("Intel skill lookups (#2089)")
struct IntelSkillLookupTests {
    private static let catalog = CapabilityCatalog(
        tools: [],
        skills: [
            .init(name: "Code Reviewer", description: "Reviews code", keywords: ["lint", "pr"]),
            .init(name: "Notes", description: "Takes notes", keywords: [], directoryName: "meeting-notes"),
        ],
        groups: [])

    @Test("A slug names the skill; the display name wins")
    func slugLookup() {
        #expect(Self.catalog.skill(named: "code-reviewer")?.name == "Code Reviewer")
        #expect(Self.catalog.skill(named: "CODE REVIEWER")?.name == "Code Reviewer")
        #expect(Self.catalog.skill(named: "meeting-notes")?.name == "Notes")
        #expect(Self.catalog.skill(named: "unknown") == nil)
        #expect(Skill.agentSkillsSlug(for: "Code_Reviewer  Pro!") == "code-reviewer-pro")
    }

    @Test("Search finds a skill by its keywords")
    func keywordSearch() async {
        let hits = await CapabilitySearch.search("lint", in: Self.catalog, embedder: nil)
        #expect(hits.first?.id == "skill/Code Reviewer")
    }

    @Test("Top-level frontmatter keywords are kept on import")
    func topLevelKeywords() throws {
        let markdown = """
            ---
            name: code-reviewer
            description: Reviews code
            keywords: lint, pr
            ---
            Review the diff.
            """
        let skill = try Skill.parseAgentSkillsFormat(from: markdown)
        #expect(skill.keywords == ["lint", "pr"])
    }

    @Test("The editor's keyword field splits on commas")
    func editorKeywords() {
        #expect(SkillEditorSheet.parseKeywords(" a, b ,,c ") == ["a", "b", "c"])
    }
}
