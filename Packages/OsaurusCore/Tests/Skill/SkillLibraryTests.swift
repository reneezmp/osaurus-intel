//
//  SkillLibraryTests.swift
//  OsaurusCoreTests
//
//  Upstream #2050 (universal skills library) on Intel: skills have no enabled
//  flag and no per-agent allow-list; legacy data still decodes; built-ins are
//  upstream Classic's set; name collisions resolve deterministically.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SkillLibraryTests {

    // MARK: - Legacy data

    @Test
    func legacyManualSkillNamesDecodeAsIgnoredData() throws {
        let agent = Agent(name: "LegacySkills", description: "d", systemPrompt: "p", manualToolNames: ["file_read"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var dict = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(agent)) as? [String: Any]
        )
        dict["manualSkillNames"] = ["Research Analyst", "Data Keeper"]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Agent.self, from: data)
        #expect(decoded.manualToolNames == ["file_read"])
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: try encoder.encode(decoded)) as? [String: Any]
        )
        #expect(reencoded["manualSkillNames"] == nil)
    }

    @Test
    func legacyEnabledFlagInSkillFileIsIgnored() throws {
        let md = """
            ---
            name: Old Disabled
            description: was switched off
            enabled: false
            ---
            Body.
            """
        let skill = try Skill.parse(from: md)
        #expect(skill.name == "Old Disabled")
        #expect(!skill.toAgentSkillsFormat().contains("enabled:"))
    }

    // MARK: - Built-ins

    @Test
    func builtInsAreClassicSetWithStableDirectoryNames() {
        let slugs = Set(Skill.builtInSkills.compactMap(\.directoryName))
        #expect(slugs.contains("web-researcher"))
        #expect(slugs.contains("content-summarizer"))
        #expect(slugs.contains("mac-automator"))
        #expect(Skill.builtInSkills.allSatisfy { $0.isBuiltIn && $0.directoryName != nil })
        #expect(!Skill.builtInSkills.contains { $0.name == "Research Analyst" })
        #expect(Set(Skill.builtInSkills.map(\.id)).count == Skill.builtInSkills.count)
    }

    // MARK: - Name collisions

    @Test @MainActor
    func namedLookupPrefersUserSkillOverBuiltIn() async throws {
        try await Self.withTempSkillStorage {
            let builtIn = try #require(Skill.builtInSkills.first)
            let userSkill = await SkillManager.shared.create(
                name: builtIn.name,
                description: "user variant",
                instructions: "From the user."
            )
            #expect(SkillManager.shared.skills(named: builtIn.name).count == 2)
            #expect(SkillManager.shared.skill(named: builtIn.name)?.id == userSkill.id)
            #expect(SkillManager.shared.skill(named: builtIn.name.lowercased())?.id == userSkill.id)
        }
    }

    // MARK: - Slash commands and catalog

    @Test @MainActor
    func everyInstalledSkillSurfacesAsSlashCommandAndInCatalog() async throws {
        try await Self.withTempSkillStorage {
            let skills = SkillManager.shared.skills
            #expect(!skills.isEmpty)
            let ids = Set(SlashCommandRegistry.shared.filtered(query: "").filter { $0.kind == .skill }.map(\.id))
            for skill in skills { #expect(ids.contains(skill.id), "\(skill.name) missing") }

            let catalog = CapabilityCatalog.build(agentId: Agent.defaultId)
            let names = Set(catalog.skills.map(\.name))
            for skill in skills { #expect(names.contains(skill.name), "\(skill.name) not in catalog") }
        }
    }

    // MARK: - Fixtures

    private static func withTempSkillStorage(
        _ body: @Sendable @MainActor () async throws -> Void
    ) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-skill-library-\(UUID().uuidString)"
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
