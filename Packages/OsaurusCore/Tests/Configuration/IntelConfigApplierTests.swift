//
//  IntelConfigApplierTests.swift
//  osaurusTests
//
//  Intel-only behaviour of the declarative planner/applier port
//  (`W-declarative-config` stages 2-3): what the applier does where Intel lacks
//  a feature; the provider credential sheet is upstream's (stage 3), driven here
//  through its `bypassUI` hook. Nothing here touches the real keychain (the
//  gate disables it) or the network.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelConfigApplierTests {

    private static func anthropicDocument(named name: String) -> OsaurusConfigDocument {
        var entry = ProviderEntry(name: name)
        entry.provider = "anthropic"
        var document = OsaurusConfigDocument()
        document.providers = [entry]
        return document
    }

    @Test("a keyed provider without api_key_ref opens the credential sheet; dismissing it creates nothing")
    func keyedProvider_withoutRef_sheetDismissed_createsNothing() async throws {
        ProviderCredentialPromptService.bypassUI = { _ in .cancelled }
        defer { ProviderCredentialPromptService.bypassUI = nil }
        let name = "Intel Probe \(UUID().uuidString.prefix(6))"

        let results = await ConfigApplier.apply(document: Self.anthropicDocument(named: name), prune: false)
        let result = try #require(results.first { $0.target == name })
        #expect(result.status == .cancelled)
        #expect(!RemoteProviderManager.shared.configuration.providers.contains { $0.name == name })
    }

    @Test("a key typed in the sheet creates the provider; the key never appears in the result")
    func keyedProvider_sheetKey_createsProvider() async throws {
        let secret = "sk-test-\(UUID().uuidString)"
        var requestedPreset: ProviderPreset?
        ProviderCredentialPromptService.bypassUI = { request in
            requestedPreset = request.preset
            return .apiKey(key: secret)
        }
        defer { ProviderCredentialPromptService.bypassUI = nil }
        let name = "Intel Probe \(UUID().uuidString.prefix(6))"

        let results = await ConfigApplier.apply(document: Self.anthropicDocument(named: name), prune: false)
        let result = try #require(results.first { $0.target == name })
        #expect(result.status == .done)
        #expect(requestedPreset == .anthropic)
        #expect(!(result.message ?? "").contains(secret))
        let created = RemoteProviderManager.shared.configuration.providers.first { $0.name == name }
        #expect(created != nil)
        if let created { RemoteProviderManager.shared.removeProvider(id: created.id) }
    }

    @Test("a paired-phone run never opens the Mac sheet and creates nothing")
    func keyedProvider_phoneRun_needsTheMac() async throws {
        var opened = false
        ProviderCredentialPromptService.bypassUI = { _ in
            opened = true
            return .cancelled
        }
        defer { ProviderCredentialPromptService.bypassUI = nil }
        let name = "Intel Probe \(UUID().uuidString.prefix(6))"
        let document = Self.anthropicDocument(named: name)

        let results = await ChatExecutionContext.$hasRemoteReviewer.withValue(true) {
            await ConfigApplier.apply(document: document, prune: false)
        }
        let result = try #require(results.first { $0.target == name })
        #expect(result.status == .needsUserAction)
        #expect(result.message?.contains("Settings") == true)
        #expect(!opened)
        #expect(!RemoteProviderManager.shared.configuration.providers.contains { $0.name == name })
    }

    @Test("an unresolvable api_key_ref fails and creates nothing")
    func apiKeyRef_unresolved_failsWithoutCreating() async throws {
        let name = "Intel Probe \(UUID().uuidString.prefix(6))"
        var entry = ProviderEntry(name: name)
        entry.provider = "openai"
        entry.apiKeyRef = "env:OSAURUS_TEST_DEFINITELY_UNSET_\(UUID().uuidString.prefix(8))"
        var document = OsaurusConfigDocument()
        document.providers = [entry]

        let results = await ConfigApplier.apply(document: document, prune: false)
        let result = try #require(results.first { $0.target == name })
        #expect(result.status == .failed)
        #expect(!RemoteProviderManager.shared.configuration.providers.contains { $0.name == name })
    }

    @Test("a watcher cannot target a shared workspace agent on Intel")
    func watcher_workspaceAgent_isRefusedByPlanner() {
        var entry = WatcherEntry(name: "Intel Probe Watcher")
        entry.agent = "ws-1:0x" + String(repeating: "a", count: 40)
        entry.instructions = "x"
        entry.path = NSTemporaryDirectory()
        var document = OsaurusConfigDocument()
        document.watchers = [entry]
        do {
            _ = try ConfigPlanner.plan(document: document, prune: false)
            Issue.record("expected a validation failure")
        } catch let issues as ConfigPlanIssues {
            #expect(issues.issues.contains { $0.contains("workspace agents are not available") }, "\(issues.issues)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("sections Intel's schema omits are rejected before they can reach the applier")
    func omittedSections_failAtDecode() {
        for yaml in [
            "channels:\n  telegram:\n    write_enabled: true\n",
            "models:\n  - mlx-community/Some-Model-4bit\n",
        ] {
            #expect(throws: (any Error).self) { try ConfigYAML.decode(yaml) }
        }
    }

    @Test("ToolRegistry reports unknown tool names as unregistered")
    func toolRegistry_isRegistered() {
        #expect(!ToolRegistry.shared.isRegistered("definitely_not_a_tool_\(UUID().uuidString)"))
    }
}
