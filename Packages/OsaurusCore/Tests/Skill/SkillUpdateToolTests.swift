//
//  SkillUpdateToolTests.swift
//  OsaurusCoreTests
//
//  `update_skill` contract:
//
//   * an approved edit lands in the skill's stored instructions and the
//     result echoes the updated text, so the agent can verify what it saved
//     instead of assuming (stale in-conversation copies are called out).
//   * built-in and plugin skills fail EXPLICITLY rather than tripping
//     `SkillManager.update`'s silent guard — success over a write that never
//     happened is the fabricated "Done" the tool exists to eliminate.
//   * edit failures (no match) are retryable without re-approval, and a
//     no-op edit reports "nothing saved" rather than success theater.
//   * surface gating: denied externally, excluded from spawned children.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillUpdateToolTests {

    private static func execute(_ arguments: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        return try await SkillUpdateTool().execute(
            argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    @Test @MainActor
    func editLandsInStoredInstructionsAndEchoesResult() async throws {
        try await Self.withTempSkillStorage {
            let skill = await SkillManager.shared.create(
                name: "Plain English",
                instructions: "Explain concepts in plain English. Use Canadian English."
            )

            let result = try await Self.execute([
                "skill": "plain english",
                "edits": [["find": "Canadian English", "replace": "American English"]],
                "rationale": "user prefers American spelling",
            ])

            #expect(result.contains("\"ok\":true") || result.contains("\"ok\": true"))
            #expect(result.contains("American English"))
            let stored = SkillManager.shared.skill(for: skill.id)
            #expect(stored?.instructions == "Explain concepts in plain English. Use American English.")
        }
    }

    @Test @MainActor
    func builtInSkillIsRejectedExplicitly() async throws {
        try await Self.withTempSkillStorage {
            let builtIn = try #require(Skill.builtInSkills.first)
            let result = try await Self.execute([
                "skill": builtIn.id.uuidString,
                "edits": [["find": "a", "replace": "b"]],
            ])
            #expect(ToolEnvelope.failureMessage(result).contains("built-in"))
        }
    }

    @Test @MainActor
    func pluginSkillIsRejectedExplicitly() async throws {
        try await Self.withTempSkillStorage {
            var pluginSkill = Skill(name: "Plugin Provided", instructions: "Original.")
            pluginSkill.pluginId = "com.example.plugin"
            await SkillManager.shared.registerPluginSkill(pluginSkill)

            let result = try await Self.execute([
                "skill": "Plugin Provided",
                "edits": [["find": "Original", "replace": "Changed"]],
            ])
            #expect(ToolEnvelope.failureMessage(result).contains("plugin"))
            #expect(SkillManager.shared.skill(for: pluginSkill.id)?.instructions == "Original.")
        }
    }

    @Test @MainActor
    func unknownSkillIsNotFound() async throws {
        try await Self.withTempSkillStorage {
            let result = try await Self.execute([
                "skill": "No Such Skill",
                "edits": [["find": "a", "replace": "b"]],
            ])
            #expect(result.contains("not_found"))
        }
    }

    @Test @MainActor
    func unmatchedFindIsRetryableAndWritesNothing() async throws {
        try await Self.withTempSkillStorage {
            let skill = await SkillManager.shared.create(
                name: "Stable", instructions: "Keep this text.")

            let result = try await Self.execute([
                "skill": "Stable",
                "edits": [["find": "text that is not there", "replace": "x"]],
            ])
            #expect(result.contains("\"retryable\":true") || result.contains("\"retryable\": true"))
            #expect(ToolEnvelope.failureMessage(result).contains("rather than substituting"))
            #expect(SkillManager.shared.skill(for: skill.id)?.instructions == "Keep this text.")
        }
    }

    @Test @MainActor
    func noOpEditReportsNothingSaved() async throws {
        try await Self.withTempSkillStorage {
            _ = await SkillManager.shared.create(name: "Idempotent", instructions: "Same. Same.")
            let result = try await Self.execute([
                "skill": "Idempotent",
                "edits": [["find": "Same", "replace": "Same", "all": true]],
            ])
            #expect(result.contains("Nothing was saved"))
        }
    }

    // MARK: - Surface gating

    @Test
    func deniedExternally() {
        #expect(ToolRegistry.externallyDeniedToolNames.contains("update_skill"))
    }

    // MARK: - On-demand exposure

    /// Kept OUT of the default tool list on purpose: a spec in every request is
    /// a spec in every user's cached prompt prefix, and most users never edit
    /// a skill from chat. It is sent only when asked for by name (Intel:
    /// `openAISpecs(named:)`; upstream: `capabilities` load).
    @Test @MainActor
    func absentFromDefaultSpecsButAvailableByName() {
        #expect(ToolRegistry.onDemandBuiltInToolNames.contains("update_skill"))

        let baseline = Set(ToolRegistry.shared.openAISpecs(for: UUID()).map { $0.function.name })
        #expect(!baseline.contains("update_skill"))

        let named = ToolRegistry.shared.openAISpecs(named: ["update_skill"]).map { $0.function.name }
        #expect(named == ["update_skill"])
    }

    // MARK: - Slash-command path

    /// The slash wrapper forbids discovery ("use only the tools exposed in
    /// this request"), so an on-demand tool can only reach a slash-invoked
    /// turn by being pre-loaded with the skill. Without this, "update this
    /// skill" produced a claimed update with nothing saved (0.24.7 report).
    @Test
    func slashInvocationPreloadsUpdateSkillForUserSkillsOnly() throws {
        let user = Skill(name: "Plain English", instructions: "Use `some_mcp_tool` here.")
        let preloaded = SkillManager.preloadedToolNames(
            for: user, body: user.instructions, dynamicCandidates: ["some_mcp_tool", "other"])
        #expect(preloaded.contains("update_skill"))
        #expect(preloaded.contains("some_mcp_tool"))
        #expect(!preloaded.contains("other"))

        let builtIn = try #require(Skill.builtInSkills.first)
        #expect(
            !SkillManager.preloadedToolNames(
                for: builtIn, body: builtIn.instructions, dynamicCandidates: []
            ).contains("update_skill"))

        var plugin = Skill(name: "Plugin Skill", instructions: "x")
        plugin.pluginId = "com.example.plugin"
        #expect(
            !SkillManager.preloadedToolNames(for: plugin, body: "x", dynamicCandidates: [])
                .contains("update_skill"))
    }

    /// The wrapper only advertises editing when the tool is really exposed,
    /// and never for a skill the tool would reject.
    @Test @MainActor
    func activeSkillWrapperAdvertisesEditingOnlyWhenEditable() {
        let editable = SkillManager.activeSkillPromptSection(
            name: "Plain English", body: "Body.", editable: true)
        #expect(editable.contains("call `update_skill`"))
        #expect(editable.contains("Never state that the skill was updated"))
        #expect(editable.contains("Body."))

        // A read-only skill says so, without naming the tool: asked to change
        // a built-in, GPT-5.6 otherwise answered "Updated preference: ..."
        // which reads like a saved edit.
        let readOnly = SkillManager.activeSkillPromptSection(
            name: "Web Researcher", body: "Body.", editable: false)
        #expect(!readOnly.contains("update_skill"))
        #expect(readOnly.contains("cannot be edited"))
        #expect(readOnly.contains("duplicating it as a custom skill"))
        #expect(readOnly.contains("Body."))
    }

    // MARK: - Harness

    private static func withTempSkillStorage(
        _ body: @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-update-tool-\(UUID().uuidString)"
            )
            let previousRoot = OsaurusPaths.overrideRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            await SkillManager.shared.refresh()

            let result: Result<Void, Error>
            do {
                try await body()
                result = .success(())
            } catch {
                result = .failure(error)
            }

            OsaurusPaths.overrideRoot = previousRoot
            try? FileManager.default.removeItem(at: root)
            await SkillManager.shared.refresh()
            try result.get()
        }
    }
}
