//
//  IntelRedactionToolExposureTests.swift
//  OsaurusCoreTests
//
//  W-privacy-filter stage 5 (upstream #2474 + #3307, #3135): who is offered
//  `detect_pii` / `redact_file` (a custom agent that switched Redaction Tools
//  on, in a host-folder chat), the forced `tool_choice` for redaction-shaped
//  requests, and the phone picker's `privacy` field. Synthetic data, isolated
//  storage.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Redaction tool exposure", .serialized)
struct IntelRedactionToolExposureTests {

    private static let redactionNames: Set<String> = ["detect_pii", "redact_file"]

    private static func folder() -> FolderContext {
        FolderContext(
            rootPath: URL(fileURLWithPath: "/tmp/redaction-exposure-folder"),
            projectType: .unknown,
            tree: "./\nnote.txt",
            manifest: nil,
            gitStatus: nil,
            isGitRepo: false,
            contextFiles: nil
        )
    }

    @MainActor
    private static func addAgent(redaction: Bool, mode: ToolSelectionMode = .auto) -> Agent {
        var agent = Agent(name: "redact-\(UUID().uuidString.prefix(6))", systemPrompt: "x", agentAddress: nil)
        agent.toolSelectionMode = mode
        agent.settings.redactionToolsEnabled = redaction
        AgentManager.shared.add(agent)
        return agent
    }

    @MainActor
    private static func offered(_ agentId: UUID, folder: FolderContext?) async -> Set<String> {
        FolderToolManager.shared.ensureFolderToolsRegistered()
        let context = await SystemPromptComposer.composeChatContext(
            agentId: agentId, query: "hi", folderContext: folder)
        return Set(context.tools.map(\.function.name))
    }

    // MARK: Settings

    @Test func settings_defaultOffRoundTripAndLegacyDecode() throws {
        #expect(!AgentSettings.defaultDisabled.redactionToolsEnabled)
        var settings = AgentSettings.defaultDisabled
        settings.redactionToolsEnabled = true
        let back = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.redactionToolsEnabled)
        let legacy = try JSONDecoder().decode(AgentSettings.self, from: Data(#"{"dbEnabled":false}"#.utf8))
        #expect(!legacy.redactionToolsEnabled)
    }

    @Test func declarativeKey_decodes() throws {
        let entry = try JSONDecoder().decode(
            AgentCapabilitiesEntry.self, from: Data(#"{"redaction_tools_enabled":true}"#.utf8))
        #expect(entry.redactionToolsEnabled == true)
    }

    @Test func registryNames_andExternalDeny() {
        #expect(ToolRegistry.redactionToolNames == Self.redactionNames)
        // The write tool never runs from an external surface (MCP, plain HTTP).
        #expect(ToolRegistry.externallyDeniedHostToolNames.contains("redact_file"))
    }

    // MARK: Composer

    @MainActor
    @Test func customAgent_isOfferedThemOnlyWithTheSwitchAndAHostFolder() async throws {
        try await ChatHistoryTestStorage.run {
            let off = Self.addAgent(redaction: false)
            let on = Self.addAgent(redaction: true)
            let folderNames = await Self.offered(off.id, folder: Self.folder())
            #expect(folderNames.contains("file_read"))
            #expect(folderNames.isDisjoint(with: Self.redactionNames))

            let onNames = await Self.offered(on.id, folder: Self.folder())
            #expect(Self.redactionNames.isSubset(of: onNames))

            // No host folder: nothing to scan, never offered.
            let noFolder = await Self.offered(on.id, folder: nil)
            #expect(noFolder.isDisjoint(with: Self.redactionNames))
            _ = await AgentManager.shared.delete(id: off.id)
            _ = await AgentManager.shared.delete(id: on.id)
        }
    }

    @MainActor
    @Test func manualToolAgent_keepsThemOutUntilTheSwitchIsOn() async throws {
        try await ChatHistoryTestStorage.run {
            let off = Self.addAgent(redaction: false, mode: .manual)
            let on = Self.addAgent(redaction: true, mode: .manual)
            let offNames = await Self.offered(off.id, folder: Self.folder())
            #expect(offNames.isDisjoint(with: Self.redactionNames))
            let onNames = await Self.offered(on.id, folder: Self.folder())
            #expect(Self.redactionNames.isSubset(of: onNames))
            _ = await AgentManager.shared.delete(id: off.id)
            _ = await AgentManager.shared.delete(id: on.id)
        }
    }

    @MainActor
    @Test func defaultAgent_neverGetsThemInAFolderChat() async throws {
        try await ChatHistoryTestStorage.run {
            let names = await Self.offered(Agent.defaultId, folder: Self.folder())
            #expect(names.contains("file_read"))
            #expect(names.isDisjoint(with: Self.redactionNames))
        }
    }

    @Test func folderPrompt_namesRedactFileOnlyWhenItIsCallable() {
        let withTool = SystemPromptTemplates.leanFolderContext(
            from: Self.folder(), toolNames: ["file_read", "redact_file", "detect_pii"])
        #expect(withTool.contains(SystemPromptTemplates.folderRedactionLine))
        let without = SystemPromptTemplates.leanFolderContext(from: Self.folder(), toolNames: ["file_read"])
        #expect(!without.contains("redact_file"))
    }

    // MARK: Forced tool_choice

    private static func tool(_ name: String) -> Tool {
        Tool(type: "function", function: ToolFunction(name: name, description: nil, parameters: nil))
    }

    private static func forcedName(_ choice: ToolChoiceOption?) -> String? {
        if case .function(let fn) = choice { return fn.function.name }
        return nil
    }

    @Test func redactionShapedRequest_forcesRedactFileOnTheFirstAttemptOnly() {
        let tools = [Self.tool("file_read"), Self.tool("redact_file")]
        let text = "Replace names with \"[REDACTED NAME]\" and emails with \"[REDACTED EMAIL]\" in note.txt"
        #expect(Self.forcedName(ChatToolChoicePolicy.resolve(tools: tools, userText: text, attempt: 1)) == "redact_file")
        #expect(Self.forcedName(ChatToolChoicePolicy.resolve(tools: tools, userText: text, attempt: 2)) == nil)
        // Not offered (the agent has Redaction Tools off): never forced.
        #expect(
            Self.forcedName(
                ChatToolChoicePolicy.resolve(tools: [Self.tool("file_edit")], userText: text, attempt: 1)) == nil)
    }

    @Test func ordinaryEditsAndNegatedRequests_areNotForced() {
        let tools = [Self.tool("file_edit"), Self.tool("redact_file")]
        for text in [
            "Replace the function name in app.py with a shorter one",
            "Replace the column names in the CSV header of data.csv with lowercase versions",
            "Replace every comma with a semicolon in note.txt",
            "Explain how to redact emails, without running redact_file or any other tools.",
        ] {
            #expect(Self.forcedName(ChatToolChoicePolicy.resolve(tools: tools, userText: text, attempt: 1)) == nil, "\(text)")
        }
    }

    // MARK: Phone picker

    @Test func picker_saysHowThePrivacyFilterTreatsACloudModel() {
        let providerId = UUID()
        let items: [ModelPickerItem] = [
            .fromRemoteModel(modelId: "other/qwen3-32b", providerName: "Other", providerId: providerId)
        ]
        func privacy(_ config: PrivacyFilterConfiguration) -> String? {
            HTTPHandler.pickerModels(from: items, privacyConfig: config).first?.privacy
        }
        var config = PrivacyFilterConfiguration.freshInstall()
        config.enabled = false
        #expect(privacy(config) == nil)
        config.enabled = true
        #expect(privacy(config) == "review")
        config.alwaysApproveByDefault = true
        #expect(privacy(config) == "auto")
        config.setProviderEnabled(providerId, enabled: false)
        #expect(privacy(config) == nil)
    }
}
