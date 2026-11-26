//
//  Stage6BatchBTests.swift
//  osaurusTests
//
//  Upstream #2505 (global Disable Tools switch removed; old value ignored),
//  #2647 (duplicate copies capability configuration), #2625 (hallucinated
//  fetch-tool steering) and #2632 (dynamic tool classification snapshot).
//  Storage tests run in `ChatHistoryTestStorage`'s temp root only.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct Stage6BatchBTests {

    // MARK: #2505

    @Test("A stale disableTools key in chat.json is ignored and not written back")
    func staleGlobalDisableToolsIsIgnored() async throws {
        try await ChatHistoryTestStorage.run {
            let file = OsaurusPaths.chatConfigFile()
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"disableTools": true, "maxToolAttempts": 7}"#.utf8).write(to: file)

            let cfg = ChatConfiguration()
            cfg.loadFromDiskIfPresent()
            // Other keys still load; the old one has no effect anywhere.
            #expect(cfg.maxToolAttempts == 7)
            cfg.persistToDisk()
            let rewritten = try String(contentsOf: file, encoding: .utf8)
            #expect(!rewritten.contains("disableTools"))

            let agent = Agent(name: "Tools Agent")
            AgentManager.shared.add(agent)
            #expect(!AgentManager.shared.effectiveToolsDisabled(for: agent.id))
            #expect(!AgentManager.shared.effectiveToolsDisabled(for: Agent.defaultId))

            var off = Agent(name: "Tools Off")
            off.disableTools = true
            AgentManager.shared.add(off)
            #expect(AgentManager.shared.effectiveToolsDisabled(for: off.id))
        }
    }

    // MARK: #2647

    @Test("Duplicate keeps a manual agent manual, with its tools, grants and switches")
    func duplicateCopiesCapabilityConfiguration() {
        var source = Agent(name: "Manual")
        source.toolSelectionMode = .manual
        source.manualToolNames = ["web_search", "file_read"]
        source.disableTools = true
        source.disableMemory = true
        source.pluginInstructions = ["com.example": "be brief"]
        source.avatar = "star"
        source.autoSpeak = true
        source.ttsVoice = "voice-1"
        source.settings.webSearchEnabled = true

        let copy = AgentManager.duplicateRecord(from: source, name: "Manual Copy")
        #expect(copy.id != source.id)
        #expect(copy.name == "Manual Copy")
        #expect(!copy.isBuiltIn)
        #expect(copy.toolSelectionMode == .manual)
        #expect(copy.manualToolNames == ["web_search", "file_read"])
        #expect(copy.disableTools == true)
        #expect(copy.disableMemory == true)
        #expect(copy.pluginInstructions == ["com.example": "be brief"])
        #expect(copy.avatar == "star")
        #expect(copy.autoSpeak == true)
        #expect(copy.ttsVoice == "voice-1")
        #expect(copy.settings.webSearchEnabled)
    }

    // MARK: #2625

    @Test("Fetch names from other harnesses steer to search_and_extract only when it is offered")
    func hallucinatedFetchSteering() {
        func envelope(_ name: String, offered: Set<String>, registered: Bool = false) -> String {
            IntelToolScopeGate.envelope(
                forUnofferedCall: name, offeredNames: offered, agentId: UUID(),
                catalog: .empty, isRegistered: registered)
        }
        let withExtract = envelope("web_fetch", offered: ["web_search", "search_and_extract"])
        #expect(withExtract.contains("search_and_extract"))
        #expect(withExtract.contains("\"retryable\":true") || withExtract.contains("retryable"))
        #expect(envelope("Fetch_URL", offered: ["search_and_extract"]).contains("search_and_extract"))

        // Opaque when the request does not expose the target (nothing leaked).
        #expect(!envelope("web_fetch", offered: ["web_search"]).contains("search_and_extract"))
        #expect(!envelope("web_fetch", offered: []).contains("search_and_extract"))
        // A real registration is never steered; browser/shell intent is not steered.
        #expect(!envelope("web_fetch", offered: ["search_and_extract"], registered: true).contains("search_and_extract"))
        #expect(!envelope("open_url", offered: ["search_and_extract"]).contains("search_and_extract"))
        #expect(!envelope("curl", offered: ["search_and_extract"]).contains("search_and_extract"))
    }

    // MARK: #2632

    @Test("The dynamic snapshot holds registered non-built-in tools only")
    func dynamicSnapshotExcludesBuiltIns() {
        let snapshot = ToolRegistry.shared.dynamicToolNameSnapshot()
        #expect(!snapshot.contains("web_search"))
        #expect(!snapshot.contains("search_and_extract"))
        #expect(!snapshot.contains("todo"))
    }
}
