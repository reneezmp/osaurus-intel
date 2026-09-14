import Foundation
import Testing

@testable import OsaurusCore

@Suite("Default Orchestrator configuration", .serialized)
struct DefaultAgentConfigurationStoreTests {
    @Test("built-in Orchestrator keeps the upstream green identity")
    func builtInIdentityUsesGreenAvatar() {
        #expect(Agent.default.id == Agent.defaultId)
        #expect(Agent.default.isBuiltIn)
        #expect(Agent.default.avatar == "green")
    }

    @Test
    func roundTripUsesIsolatedStore() async {
        await StoragePathsTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-orchestrator-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            DefaultAgentConfigurationStore.overrideDirectory = directory
            DefaultAgentConfigurationStore.resetCacheForTests()
            defer {
                DefaultAgentConfigurationStore.overrideDirectory = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
            }

            let expected = DefaultAgentConfiguration(
                displayName: "Sunny",
                systemPrompt: "Be precise.",
                defaultModel: "provider/model",
                temperature: 0.4,
                maxTokens: 4096
            )
            DefaultAgentConfigurationStore.save(expected)
            DefaultAgentConfigurationStore.resetCacheForTests()

            #expect(DefaultAgentConfigurationStore.load() == expected)
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("default-agent.json").path
            ))
        }
    }

    @Test
    func missingFieldsDecodeAsInheritedDefaults() throws {
        let decoded = try JSONDecoder().decode(
            DefaultAgentConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(decoded == .default)
    }

    @Test
    func builtInRuntimeUsesOverridesAndThenRestoresInheritance() async {
        await StoragePathsTestLock.shared.run {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-orchestrator-runtime-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            DefaultAgentConfigurationStore.overrideDirectory = directory
            DefaultAgentConfigurationStore.resetCacheForTests()
            defer {
                DefaultAgentConfigurationStore.overrideDirectory = nil
                DefaultAgentConfigurationStore.resetCacheForTests()
            }

            AgentManager.shared.updateDefaultAgentConfiguration(
                DefaultAgentConfiguration(
                    displayName: "Runtime Sunny",
                    systemPrompt: "Orchestrate carefully.",
                    defaultModel: "provider/runtime-model",
                    temperature: 0.25,
                    maxTokens: 2048
                )
            )

            #expect(AgentManager.shared.agent(for: Agent.defaultId)?.name == "Runtime Sunny")
            #expect(AgentManager.shared.effectiveModel(for: Agent.defaultId) == "provider/runtime-model")
            #expect(AgentManager.shared.effectiveTemperature(for: Agent.defaultId) == 0.25)
            #expect(AgentManager.shared.effectiveMaxTokens(for: Agent.defaultId) == 2048)
            #expect(AgentManager.shared.effectiveSystemPrompt(for: Agent.defaultId) == "Orchestrate carefully.")

            AgentManager.shared.updateDefaultAgentConfiguration(.default)
            #expect(AgentManager.shared.effectiveModel(for: Agent.defaultId) == ChatConfigurationStore.load().defaultModel ?? "deepseek-v4-pro")
            #expect(AgentManager.shared.effectiveSystemPrompt(for: Agent.defaultId) == ChatConfigurationStore.load().systemPrompt)
        }
    }
}
