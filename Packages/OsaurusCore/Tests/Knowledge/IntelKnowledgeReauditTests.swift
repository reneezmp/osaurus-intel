//
//  IntelKnowledgeReauditTests.swift
//  osaurusTests
//
//  `W-cov-reaudit` stage 3d (docs/COV_REAUDIT.md): upstream's knowledge
//  fixes on Intel's own knowledge stack.
//  - #2338: non-reserved frontmatter (lists and nested objects included)
//    passes through to `read_knowledge` (upstream's parser cases, verbatim).
//  - #2132: the inferred category reaches the document readers
//    (`effectiveType`, "(inferred)").
//  - #2383: reads on an in-memory database stay on the writer connection.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelKnowledgeFrontmatterTests {
    @Test
    func preservesNonReservedFieldsAsExtrasInSourceOrder() {
        let markdown = """
            ---
            status: draft
            type: note
            title: Meeting Notes
            source: https://example.com/spec
            sensitivity: private
            tags: [ops]
            ---
            body
            """
        let (frontmatter, _) = KnowledgeDocumentParser.parse(markdown: markdown)
        #expect(frontmatter.docType == "note")
        #expect(
            frontmatter.extras == [
                KnowledgeFrontmatterField(key: "status", value: "draft"),
                KnowledgeFrontmatterField(key: "source", value: "https://example.com/spec"),
                KnowledgeFrontmatterField(key: "sensitivity", value: "private"),
            ]
        )
    }

    @Test
    func rendersListAndNestedExtras() {
        let markdown = """
            ---
            title: Doc
            aliases: [okf, knowledge]
            review:
              owner: sam
              due: 2026-09-01
            ---
            body
            """
        let (frontmatter, _) = KnowledgeDocumentParser.parse(markdown: markdown)
        #expect(frontmatter.extras.map(\.key) == ["aliases", "review"])
        #expect(frontmatter.extras[0].value == "okf, knowledge")
        #expect(frontmatter.extras[1].value == "due: 2026-09-01, owner: sam")
    }
}

@Suite(.serialized)
struct IntelKnowledgeInferredTypeTests {
    @Test
    func effectiveTypePrefersTheExplicitType() {
        func doc(_ type: String, _ inferred: String) -> KnowledgeDocument {
            KnowledgeDocument(
                id: 1, collectionId: "c", relPath: "recipes/a.md", title: "", docType: type, summary: "",
                tagsCSV: "", contentHash: "", sizeBytes: 0, modifiedAt: "", indexedAt: "", inferredType: inferred)
        }
        #expect(doc("", "recipes").effectiveType == "recipes")
        #expect(doc("", "recipes").isTypeInferred)
        #expect(doc("policy", "recipes").effectiveType == "policy")
        #expect(!doc("policy", "recipes").isTypeInferred)
        #expect(doc("", "").effectiveType.isEmpty)
    }

    @Test
    func readersCarryTheInferredType() throws {
        let db = KnowledgeDatabase()
        try db.openInMemory()
        defer { db.close() }
        _ = try db.upsertDocument(
            collectionId: "c", relPath: "recipes/pasta.md", title: "Pasta", docType: "", summary: "",
            tagsCSV: "", contentHash: "h1", sizeBytes: 1, modifiedAt: "", inferredType: "recipes")
        _ = try db.upsertDocument(
            collectionId: "c", relPath: "about.md", title: "About", docType: "profile", summary: "",
            tagsCSV: "", contentHash: "h2", sizeBytes: 1, modifiedAt: "")
        let listed = try db.listDocuments(collectionId: "c")
        let pasta = try #require(listed.first { $0.relPath == "recipes/pasta.md" })
        #expect(pasta.docType.isEmpty)
        #expect(pasta.effectiveType == "recipes")
        let fetched = try #require(try db.getDocument(collectionId: "c", relPath: "recipes/pasta.md"))
        #expect(fetched.isTypeInferred)
        #expect(try db.getDocument(collectionId: "c", relPath: "about.md")?.effectiveType == "profile")
        #expect(try db.getDocument(collectionId: "c", relPath: "missing.md") == nil)
    }
}
