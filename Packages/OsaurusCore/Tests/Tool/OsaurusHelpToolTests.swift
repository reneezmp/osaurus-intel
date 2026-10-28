//
//  OsaurusHelpToolTests.swift
//  OsaurusCoreTests
//
//  Intel (2026-10-27): upstream's `OsaurusHelpToolTests`, adapted. The
//  loader and tool cases are upstream's; the corpus cases pin Intel's guide
//  (docs/GUIDE_INTEL.md): its topic set, the topics left out because this
//  build lacks the feature, and upstream-only claims that must not return.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Guide corpus

struct OsaurusGuideTests {

    @Test
    func topics_loadFromBundleWithFrontMatter() {
        let topics = OsaurusGuide.topics
        #expect(!topics.isEmpty, "Guide corpus missing from OsaurusCore bundle")
        for topic in topics {
            #expect(!topic.id.isEmpty)
            #expect(!topic.title.isEmpty, "\(topic.id): missing title")
            #expect(!topic.summary.isEmpty, "\(topic.id): missing summary")
            #expect(!topic.body.isEmpty, "\(topic.id): missing body")
        }
        #expect(Set(topics.map { $0.id }).count == topics.count)
    }

    @Test
    func topics_coverIntelsFeatureAreas() {
        let ids = Set(OsaurusGuide.topics.map { $0.id })
        for required in [
            "getting-started", "intel-mac", "cloud-providers", "agents", "orchestrator",
            "chat", "commands", "skills", "plugins", "mcp", "schedules", "watchers",
            "agent-db", "memory", "knowledge", "server-api", "voice", "themes",
            "privacy-storage", "identity", "insights", "troubleshooting", "images",
        ] {
            #expect(ids.contains(required), "guide topic `\(required)` missing")
        }
    }

    @Test
    func topicsForFeaturesThisBuildLacksAreLeftOut() {
        let ids = Set(OsaurusGuide.topics.map { $0.id })
        for absent in ["local-models", "channels", "automation", "workspaces", "config", "settings"] {
            #expect(!ids.contains(absent), "`\(absent)` describes a feature this Intel build doesn't have")
        }
    }

    @Test
    func corpusMakesNoUpstreamOnlyClaims() {
        let corpus = OsaurusGuide.topics.filter { $0.id != "intel-mac" }.map(\.body).joined(separator: "\n")
        #expect(corpus.contains("⌘,"), "guide should tell the user Settings… is ⌘,")
        for upstreamOnly in [
            "osaurus_config", "osaurus_inspect", "osaurus_list", "Parakeet", "PocketTTS", "Pocket TTS",
            "MLXModels", "Privacy → Activity Log", "Apple Silicon (M-series)", "No account or cloud required",
            "Download a local model",
        ] {
            #expect(!corpus.contains(upstreamOnly), "guide still says `\(upstreamOnly)`")
        }
    }

    @Test
    func topics_areSortedByOrderThenId() {
        let topics = OsaurusGuide.topics
        let resorted = topics.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        #expect(topics.map { $0.id } == resorted.map { $0.id })
        #expect(topics.first?.id == "getting-started")
    }

    @Test
    func topicLookup_isCaseAndPrefixTolerant() {
        #expect(OsaurusGuide.topic(id: "getting-started") != nil)
        #expect(OsaurusGuide.topic(id: "Getting-Started") != nil)
        #expect(OsaurusGuide.topic(id: "guide-getting-started") != nil)
        #expect(OsaurusGuide.topic(id: "getting-started.md") != nil)
        #expect(OsaurusGuide.topic(id: " getting-started ") != nil)
        #expect(OsaurusGuide.topic(id: "no-such-topic") == nil)
    }

    @Test
    func parseTopic_handlesFrontMatterAndMalformedInput() {
        let valid = """
            ---
            title: Test Topic
            summary: A one-liner.
            order: 42
            ---

            Body text here.
            """
        let parsed = OsaurusGuide.parseTopic(id: "test", contents: valid)
        #expect(parsed?.title == "Test Topic")
        #expect(parsed?.summary == "A one-liner.")
        #expect(parsed?.order == 42)
        #expect(parsed?.body == "Body text here.")
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "Just body text") == nil)
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\ntitle: T\nbody") == nil)
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\nsummary: s\n---\nbody") == nil)
        #expect(OsaurusGuide.parseTopic(id: "x", contents: "---\ntitle: T\n---\n\n") == nil)
    }
}

// MARK: - osaurus_help tool

struct OsaurusHelpToolTests {

    private func parse(_ envelope: String) throws -> [String: Any] {
        let data = try #require(envelope.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func run(_ json: String) async throws -> [String: Any] {
        let envelope = try await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            try await OsaurusHelpTool().execute(argumentsJSON: json)
        }
        return try parse(envelope)
    }

    @Test
    func topics_returnsIndexWithSummaries() async throws {
        let dict = try await run(#"{"action": "topics"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let topics = try #require(result["topics"] as? [[String: Any]])
        #expect(topics.contains { $0["id"] as? String == "intel-mac" })
        for row in topics {
            #expect(row["id"] as? String != nil)
            #expect(row["summary"] as? String != nil)
            #expect(row["content"] == nil)
        }
    }

    @Test
    func read_returnsOneTopicBody() async throws {
        let dict = try await run(#"{"action": "read", "topic": "intel-mac"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["id"] as? String == "intel-mac")
        let content = try #require(result["content"] as? String)
        #expect(content.contains("Local models"))
    }

    @Test
    func read_unknownTopicFailsTypedAndNamesKnownTopics() async throws {
        let dict = try await run(#"{"action": "read", "topic": "flux-capacitor"}"#)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect((dict["message"] as? String)?.contains("getting-started") == true)
    }

    @Test
    func read_missingTopicArgumentFailsTyped() async throws {
        let dict = try await run(#"{"action": "read"}"#)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "topic")
    }

    @Test
    func find_returnsTheContextLengthBreadcrumb() async throws {
        let dict = try await run(#"{"action": "find", "query": "context window"}"#)
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let matches = try #require(result["matches"] as? [[String: Any]])
        let row = try #require(matches.first { $0["id"] as? String == "settings.chat.contextLength" })
        #expect((row["path"] as? String)?.contains("Context Length") == true)
        #expect((row["open_with"] as? String)?.contains("⌘,") == true)
    }

    @Test
    func find_relaxedPassReportsTheQueryThatMatched() async throws {
        let dict = try await run(#"{"action": "find", "query": "please turn off memory"}"#)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["relaxed_query"] as? String == "memory")
        #expect(!((result["matches"] as? [[String: Any]]) ?? []).isEmpty)
    }

    @Test
    func find_missingQueryFailsTyped() async throws {
        let dict = try await run(#"{"action": "find"}"#)
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["field"] as? String == "query")
    }

    @Test
    func execute_isGatedToTheOrchestrator() async throws {
        let asCustom = try await ChatExecutionContext.$currentAgentId.withValue(UUID()) {
            try await OsaurusHelpTool().execute(argumentsJSON: #"{"action": "topics"}"#)
        }
        #expect(try parse(asCustom)["kind"] as? String == "unavailable")
        let noContext = try await OsaurusHelpTool().execute(argumentsJSON: #"{"action": "topics"}"#)
        #expect(try parse(noContext)["kind"] as? String == "unavailable")
    }

    @Test
    func onlyTheOrchestratorIsOfferedTheTool() async {
        let orchestrator = await SystemPromptComposer.composeChatContext(agentId: Agent.defaultId, toolsDisabled: false)
        #expect(orchestrator.tools.contains { $0.function.name == OsaurusHelpTool.toolName })
        #expect(orchestrator.prompt.contains("osaurus_help"))
        #expect(ToolRegistry.orchestratorOnlyToolNames.contains(OsaurusHelpTool.toolName))
    }
}
