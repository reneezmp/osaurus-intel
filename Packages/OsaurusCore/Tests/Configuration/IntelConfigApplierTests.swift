//
//  IntelConfigApplierTests.swift
//  osaurusTests
//
//  Intel-only behaviour of the declarative planner/applier port
//  (`W-declarative-config` stage 2): what the applier does where upstream
//  opens a native sheet or uses a feature Intel lacks. Nothing here touches the
//  keychain or the network: the provider paths exercised never read a secret.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct IntelConfigApplierTests {

    @Test("a keyed provider without api_key_ref is not created and asks the user to use Settings")
    func keyedProvider_withoutRef_needsUserAction() async throws {
        let name = "Intel Probe \(UUID().uuidString.prefix(6))"
        var entry = ProviderEntry(name: name)
        entry.provider = "anthropic"
        var document = OsaurusConfigDocument()
        document.providers = [entry]

        let results = await ConfigApplier.apply(document: document, prune: false)
        let result = try #require(results.first { $0.target == name })
        #expect(result.status == .needsUserAction)
        #expect(result.message?.contains("Settings") == true)
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
            "harness_runtimes:\n  - name: x\n    kind: claude_code\n",
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
