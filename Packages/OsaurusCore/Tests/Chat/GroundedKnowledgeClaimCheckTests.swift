//
//  GroundedKnowledgeClaimCheckTests.swift
//  osaurusTests
//
//  Coverage for the knowledge grounding advisory: a final answer that
//  states counts / dates / contents of a knowledge collection while every
//  knowledge tool call this run failed (and none succeeded) gets the
//  factual `[System Notice]` staged and ONE bounded regeneration. The loop
//  never stops on it, and a successful knowledge read anywhere in the run
//  grounds the answer.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GroundedKnowledgeClaimCheckTests {

    // MARK: containsCollectionContentClaim

    /// The reported answer, verbatim.
    @Test
    func reportedFabricatedSummary_trips() {
        #expect(
            GroundedKnowledgeClaimCheck.containsCollectionContentClaim(
                "The Obsidian Vault contains 20 documents — 20 of them, all dated 2025. "
                    + "The last entry is 20250318."
            )
        )
    }

    @Test
    func countPhrasings_trip() {
        for text in [
            "There are 312 notes in the vault.",
            "The collection has 5 folders and 48 markdown files.",
            "I found a total of 20 entries.",
            "The knowledge base is organised into three top-level folders.",
            "The newest note is dated March 2025.",
            "It returned 50 files, so the vault holds roughly 50 documents.",
        ] {
            #expect(GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func honestFailure_doesNotTrip() {
        for text in [
            "I could not read the collection: list_knowledge rejected the collection name.",
            "The knowledge tool failed, so I cannot say how many documents the vault contains.",
            "Nothing was returned from the vault — no documents were listed.",
            "The listing is unavailable right now; I was unable to access the Obsidian Vault.",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func intentAndQuestions_doNotTrip() {
        for text in [
            "Let me list the documents in the vault first.",
            "I'll check how many notes the collection has.",
            "How many documents does the vault contain?",
            "Should I summarise all 20 folders?",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    @Test
    func unrelatedNumbers_doNotTrip() {
        for text in [
            "The meeting is at 10 and there are 3 agenda points.",
            "Python 3.12 has 4 new features worth noting.",
            "Here is the summary you asked for.",
        ] {
            #expect(!GroundedKnowledgeClaimCheck.containsCollectionContentClaim(text), "\(text)")
        }
    }

    // MARK: Outcome classification

    private static let failedListEnvelope = ToolEnvelope.failure(
        kind: .invalidArgs,
        message: "Unknown collection `knowledge`. Granted collections: Obsidian Vault.",
        field: "collection",
        expected: "one of the agent's granted collection names",
        tool: "list_knowledge",
        retryable: true
    )

    @Test
    func outcomeClassification() {
        #expect(
            GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(
                toolName: "list_knowledge", result: Self.failedListEnvelope))
        #expect(
            !GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(
                toolName: "list_knowledge", result: Self.failedListEnvelope))
        let ok = ToolEnvelope.success(tool: "list_knowledge", text: "Found 3 knowledge document(s):")
        #expect(GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(toolName: "list_knowledge", result: ok))
        #expect(!GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(toolName: "list_knowledge", result: ok))
        // Other tools never count either way.
        #expect(
            !GroundedKnowledgeClaimCheck.isFailedKnowledgeOutcome(
                toolName: "file_read",
                result: ToolEnvelope.failure(kind: .notFound, message: "x", tool: "file_read")))
        #expect(
            !GroundedKnowledgeClaimCheck.isGroundedKnowledgeOutcome(
                toolName: "file_read", result: ToolEnvelope.success(tool: "file_read", text: "x")))
    }

    // MARK: Granted names from the failure envelope

    @Test
    func grantedNamesParsedFromEnvelope() {
        #expect(
            GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: Self.failedListEnvelope)
                == ["Obsidian Vault"])
        let two = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "Unknown collection `x`. Granted collections: Obsidian Vault, Runbooks v2.1.",
            tool: "list_knowledge"
        )
        #expect(
            GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: two)
                == ["Obsidian Vault", "Runbooks v2.1"])
        let none = ToolEnvelope.failure(
            kind: .rejected, message: "Knowledge tools require an active agent context.",
            tool: "list_knowledge")
        #expect(GroundedKnowledgeClaimCheck.grantedCollectionNames(inFailure: none).isEmpty)
    }

    @Test
    func noticeNamesTheGrantedCollectionAndTheTool() {
        let notice = GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
            tool: "list_knowledge", grantedNames: ["Obsidian Vault"])
        #expect(notice.hasPrefix("[System Notice]"))
        #expect(notice.contains("`Obsidian Vault`"))
        #expect(notice.contains("`list_knowledge`"))
        #expect(notice.contains("do not estimate"))
        let bare = GroundedKnowledgeClaimCheck.ungroundedKnowledgeClaimNotice(
            tool: "search_knowledge", grantedNames: [])
        #expect(bare.contains("omitted"))
    }
}

// Intel: upstream's driver-behavior cases run `AgentToolLoop`, which Intel's
// cloud engine replaces. The same scenarios (bounded noticed retry, grounded
// outcomes accepted, surfaces without the hooks unaffected) are covered by
// `IntelGroundedClaimGuardTests` and the engine cases in
// `IntelLoopHarnessTests`.
