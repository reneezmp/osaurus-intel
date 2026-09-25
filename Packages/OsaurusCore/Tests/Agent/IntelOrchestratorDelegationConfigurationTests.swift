import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel orchestrator delegation configuration", .serialized)
struct IntelOrchestratorDelegationConfigurationTests {
    @Test
    func olderConfigurationDecodesWithFailClosedDelegationDefaults() throws {
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: Data(
                #"{"displayName":"Legacy","systemPrompt":"Keep going.","defaultModel":"cloud/legacy","maxTokens":512}"#.utf8
            )
        )

        #expect(decoded.displayName == "Legacy")
        #expect(decoded.systemPrompt == "Keep going.")
        #expect(decoded.defaultModel == "cloud/legacy")
        #expect(decoded.maxTokens == 512)
        #expect(decoded.delegation == .default)
        #expect(decoded.delegation.customAgentAllowlist.isEmpty)
        #expect(decoded.delegation.admittedCloudModelIDs.isEmpty)
        #expect(decoded.delegation.permission(for: scope()) == .ask)
    }

    @Test
    func delegationConfigurationPersistsThroughAnIsolatedStore() async throws {
        try await StoragePathsTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-orchestrator-delegation-\(UUID().uuidString)")
            defer {
                DefaultAgentConfigurationStore.overrideDirectory = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
                try? FileManager.default.removeItem(at: directory)
            }

            DefaultAgentConfigurationStore.overrideDirectory = directory
            DefaultAgentConfigurationStore.resetCacheForTests()

            let permissionScope = scope()
            var delegation = OrchestratorDelegationConfiguration(
                customAgentAllowlist: [permissionScope.targetAgentID],
                admittedCloudModelIDs: [" cloud/child ", "   "],
                maximumChildTokens: 37,
                maximumInputCharacters: 91,
                maximumOutputCharacters: 43,
                timeoutSeconds: 7
            )
            delegation.setPermission(.alwaysAllow, for: permissionScope)
            let expected = DefaultAgentConfiguration(
                displayName: "Gate 4",
                systemPrompt: "Parent prompt",
                defaultModel: "cloud/parent",
                temperature: 0.25,
                maxTokens: 256,
                delegation: delegation
            )

            DefaultAgentConfigurationStore.save(expected)
            DefaultAgentConfigurationStore.resetCacheForTests()

            #expect(DefaultAgentConfigurationStore.load() == expected)
            let file = directory.appendingPathComponent("default-agent.json")
            let persisted = try JSONSerialization.jsonObject(
                with: Data(contentsOf: file)
            ) as? [String: Any]
            let persistedDelegation = persisted?["delegation"] as? [String: Any]
            #expect(persistedDelegation?["maximumChildTokens"] as? Int == 37)
            #expect(persistedDelegation?["maximumInputCharacters"] as? Int == 91)
            #expect(persistedDelegation?["maximumOutputCharacters"] as? Int == 43)
            #expect(persistedDelegation?["timeoutSeconds"] as? Int == 7)
        }
    }

    @Test
    func policyNormalizesModelIDsAndClampsUnsafeBounds() {
        let policy = OrchestratorDelegationConfiguration(
            admittedCloudModelIDs: [" cloud/model ", "", "   "],
            maximumChildTokens: 0,
            maximumInputCharacters: -1,
            maximumOutputCharacters: 0,
            timeoutSeconds: 0
        )

        #expect(policy.admittedCloudModelIDs == Set(["cloud/model"]))
        #expect(policy.admits(modelID: " cloud/model "))
        #expect(!policy.admits(modelID: ""))
        #expect(policy.maximumChildTokens == 1)
        #expect(policy.maximumInputCharacters == 1)
        #expect(policy.maximumOutputCharacters == 1)
        #expect(policy.timeoutSeconds == 1)
    }

    @Test("admitted agent and exact persisted model resolve to one target; mismatch is diagnosed")
    func admittedPairResolvesAfterSerialization() throws {
        let agent = Agent(name: "Rosy Helper", defaultModel: "router/helper")
        let configuration = DefaultAgentConfiguration(delegation: .init(
            customAgentAllowlist: [agent.id],
            admittedCloudModelIDs: ["router/helper"]
        ))
        let saved = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        let ready = IntelOrchestratorAdmission.evaluate(
            configuration: saved.delegation,
            agents: [Agent.default, agent],
            effectiveModel: { $0 == agent.id ? agent.defaultModel : nil },
            availableModelIDs: ["router/helper"]
        )
        #expect(ready.targets.map(\.id) == [agent.id])
        #expect(ready.targets.first?.modelID == "router/helper")

        let mismatched = IntelOrchestratorAdmission.evaluate(
            configuration: saved.delegation,
            agents: [agent],
            effectiveModel: { _ in "router/other" },
            availableModelIDs: ["router/helper", "router/other"]
        )
        #expect(mismatched.targets.isEmpty)
        #expect(mismatched.blocked.contains { $0.contains("not an admitted model") })

        let duplicate = IntelOrchestratorAdmission.evaluate(
            configuration: saved.delegation,
            agents: [agent, agent],
            effectiveModel: { _ in "router/helper" },
            availableModelIDs: ["router/helper"]
        )
        #expect(duplicate.targets.isEmpty)
        #expect(duplicate.blocked.contains { $0.contains("duplicate identity") })
    }

    @Test
    func malformedDelegationEntriesFailClosedWithoutDiscardingParentConfiguration() throws {
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: Data(
                #"{"displayName":"Still Sunny","systemPrompt":"Keep me.","delegation":{"customAgentAllowlist":["not-a-uuid"],"admittedCloudModelIDs":["   "],"permissionModes":{"bad/scope":"surprise"},"maximumChildTokens":0,"maximumInputCharacters":-2,"maximumOutputCharacters":0,"timeoutSeconds":-1}}"#.utf8
            )
        )

        #expect(decoded.displayName == "Still Sunny")
        #expect(decoded.systemPrompt == "Keep me.")
        #expect(decoded.delegation.customAgentAllowlist.isEmpty)
        #expect(decoded.delegation.admittedCloudModelIDs.isEmpty)
        #expect(decoded.delegation.permission(for: scope()) == .ask)
        #expect(decoded.delegation.maximumChildTokens == 1)
        #expect(decoded.delegation.maximumInputCharacters == 1)
        #expect(decoded.delegation.maximumOutputCharacters == 1)
        #expect(decoded.delegation.timeoutSeconds == 1)
    }

    private func scope() -> OrchestratorDelegationPermissionScope {
        OrchestratorDelegationPermissionScope(
            launcherAgentID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            targetAgentID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
    }
}
