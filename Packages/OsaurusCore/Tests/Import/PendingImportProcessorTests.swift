//
//  PendingImportProcessorTests.swift
//  OsaurusCoreTests
//
//  End-to-end over the real queue, SkillManager, ConfigApplier and
//  AgentManager, with Intel's owner policy (W-osaurus-bundles, upstream
//  Classic #3174): a queued bundle request changes NOTHING until the user
//  approves its plan in the app. Approved: installs its skill and agent,
//  re-running it is a no-op, items the bundle does not own are never
//  touched, removing an agent takes its unused dependencies with it.
//  Declined: nothing changes and the request completes as failed.
//  No window / timed out: nothing changes and the request stays queued.
//  Names and bundle ids are unique per test because the stores are shared
//  with the rest of the suite. No MCP server is applied here (it would try
//  to connect), no network, no keychain.
//

import Foundation
import OsaurusRepository
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PendingImportProcessorTests {

    private struct Fixture {
        var root: URL
        var bundleId: String
        var skill: String
        var agent: String
        var server: String
        var runtime: String
    }

    private func makeFixture(
        withServer: Bool = false, withRuntime: Bool = false, settings: [String: Any]? = nil,
        runtimeEnvironment: [String: String] = ["PI_LOG_LEVEL": "info"]
    ) throws -> Fixture {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let fixture = Fixture(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-import-\(suffix)", isDirectory: true),
            bundleId: "com.example.import\(suffix)",
            skill: "triage-\(suffix)",
            agent: "Support \(suffix)",
            server: "Tickets \(suffix)",
            runtime: "Pi \(suffix)")
        func write(_ text: String, _ relative: String) throws {
            let url = fixture.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        var manifest: [String: Any] = [
            "format": "osaurus.bundle", "format_version": 1, "id": fixture.bundleId,
            "name": "Import Probe", "version": "1.0.0",
            "skills": [["name": fixture.skill, "path": "skills/\(fixture.skill)"]],
            "agents": [["path": "agents/support.json"]],
        ]
        var agent: [String: Any] = [
            "name": fixture.agent, "system_prompt": "Triage tickets.",
            "tools": ["mode": "manual", "enabled": ["tickets_\(suffix)_search"]],
        ]
        if withServer {
            manifest["mcp_servers"] = [
                [
                    "name": fixture.server, "transport": "stdio", "command": "/usr/bin/true",
                ]
            ]
            agent["mcp_servers"] = ["enabled": [fixture.server]]
        }
        if withRuntime {
            manifest["harness_runtimes"] = [
                [
                    "name": fixture.runtime, "kind": "pi_rpc", "executable": "/bin/cat",
                    "arguments": ["--mode", "rpc", "--session-id", "{chat_id}"],
                    "environment": runtimeEnvironment,
                ]
            ]
            agent["runtime"] = fixture.runtime
        }
        if let settings { manifest["settings"] = settings }
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try write(String(decoding: manifestData, as: UTF8.self), "osaurus-bundle.json")
        try write(
            "---\nname: \(fixture.skill)\ndescription: Triage a ticket.\n---\n\n# Triage\n\nRead the ticket.\n",
            "skills/\(fixture.skill)/SKILL.md")
        try write("Escalation matrix.\n", "skills/\(fixture.skill)/references/escalation.md")
        let envelope: [String: Any] = [
            "format": "osaurus.template", "format_version": 1, "name": fixture.agent, "agent": agent,
        ]
        let agentData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try write(String(decoding: agentData, as: UTF8.self), "agents/support.json")
        return fixture
    }

    /// Other suites swap `OsaurusPaths.overrideRoot` and reload the shared
    /// agent and skill stores under the storage lock, and creating an agent
    /// writes the Orchestrator's spawn pool that spawn suites sandbox under
    /// the subagent store lock. The import queue gets its own temp root so
    /// a test never touches a real `~/.osaurus/import`.
    private func exclusive(_ body: @Sendable @MainActor () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let lease = await acquireSubagentStoreSandbox("bundle-import")
            defer { lease.release() }
            let queueRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("osaurus-import-queue-\(UUID().uuidString)", isDirectory: true)
            let previous = ToolsPaths.overrideRoot
            ToolsPaths.overrideRoot = queueRoot
            defer {
                ToolsPaths.overrideRoot = previous
                try? FileManager.default.removeItem(at: queueRoot)
            }
            try await body()
        }
    }

    /// A recorder for what the review showed.
    private final class Reviews: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [ConfigPlan] = []
        func add(_ plan: ConfigPlan) { lock.lock(); plans.append(plan); lock.unlock() }
        var all: [ConfigPlan] { lock.lock(); defer { lock.unlock() }; return plans }
    }

    private func processor(
        answer: ConfigApprovalOutcome = .approved, reviews: Reviews = Reviews()
    ) -> PendingImportProcessor {
        let processor = PendingImportProcessor()
        processor.connectTimeout = 1
        processor.approver = { plan in
            reviews.add(plan)
            return answer
        }
        return processor
    }

    private func enqueue(_ action: ImportAction, _ fixture: Fixture, kinds: [BundleItemKind]? = nil) throws
        -> ImportRequest
    {
        let bundle = try OsaurusBundle.load(from: fixture.root)
        var operations: [ImportOperation] = []
        if action == .remove {
            operations = ImportQueue.loadReceipts()
                .filter { $0.bundleId == fixture.bundleId && (kinds?.contains($0.kind) ?? true) }
                .map { ImportOperation(action: .remove, kind: $0.kind, name: $0.name, explicit: true) }
        } else {
            let refs = try bundle.select(kind: nil, names: [])
            operations = refs.map {
                ImportOperation(action: action, kind: $0.kind, name: $0.name, explicit: $0.explicit)
            }
        }
        let request = ImportRequest(
            bundleId: bundle.id, bundleName: bundle.manifest.name, bundleVersion: bundle.manifest.version,
            operations: operations, confirmHighRisk: true)
        try ImportQueue.enqueue(request, bundle: action == .remove ? nil : bundle)
        return request
    }

    /// Queues a request the way `osaurus import` does and applies it with the user's approval.
    private func run(
        _ action: ImportAction, _ fixture: Fixture, kinds: [BundleItemKind]? = nil,
        processor: PendingImportProcessor? = nil
    ) async throws -> ImportResult {
        let request = try enqueue(action, fixture, kinds: kinds)
        let outcome = try #require(await (processor ?? self.processor()).process(requestId: request.id))
        guard case .completed(let result) = outcome else {
            Issue.record("expected the request to complete, got \(outcome)")
            throw CancellationError()
        }
        return result
    }

    private func receipts(_ fixture: Fixture) -> [ImportReceipt] {
        ImportQueue.loadReceipts().filter { $0.bundleId == fixture.bundleId }
    }

    private func agent(named name: String) -> Agent? {
        AgentManager.shared.agents.first { $0.name == name }
    }

    @Test
    func installsSkillAndAgent_thenReinstallIsUnchanged_thenRemoveCleansUp() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let first = try await run(.install, fixture)
            #expect(first.status == .applied, "\(first.items)")
            #expect(first.items.map(\.kind) == [.skill, .agent])
            #expect(ImportQueue.result(id: first.requestId)?.items == first.items)
            #expect(!ImportQueue.pending().contains { $0.request.id == first.requestId })

            let installed = try #require(agent(named: fixture.agent))
            #expect(installed.toolSelectionMode == .manual)
            // Kept although no server provides it yet.
            #expect(installed.manualToolNames?.contains { $0.hasSuffix("_search") } == true)
            let skill = try #require(SkillManager.shared.skill(named: fixture.skill))
            #expect(skill.directoryName == fixture.skill)
            #expect(
                FileManager.default.fileExists(
                    atPath: SkillStore.skillDirectory(for: skill).appendingPathComponent("references/escalation.md").path))
            #expect(Set(receipts(fixture).map(\.kind)) == [.skill, .agent])
            #expect(receipts(fixture).first { $0.kind == .agent }?.agentId == installed.id.uuidString)
            #expect(receipts(fixture).first { $0.kind == .skill }?.explicit == true)

            let second = try await run(.install, fixture)
            #expect(second.items.allSatisfy { $0.status == .unchanged }, "\(second.items)")

            let removed = try await run(.remove, fixture, kinds: [.agent])
            #expect(removed.items.first?.kind == .agent)
            #expect(removed.items.first?.status == .done)
            #expect(agent(named: fixture.agent) == nil)
            // The skill was named on its own (select-all), so it stays.
            #expect(SkillManager.shared.skill(named: fixture.skill) != nil)

            let rest = try await run(.remove, fixture)
            #expect(rest.items.allSatisfy { $0.status == .done }, "\(rest.items)")
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
            #expect(receipts(fixture).isEmpty)
        }
    }

    /// Runs `body` with an empty harness runtime store.
    private func withRuntimeStore(_ body: @MainActor () async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-import-runtimes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = HarnessRuntimeStore.overrideDirectory
        HarnessRuntimeStore.overrideDirectory = directory
        HarnessRuntimeStore.shared.resetForTests()
        defer {
            HarnessRuntimeStore.overrideDirectory = previous
            HarnessRuntimeStore.shared.resetForTests()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body()
    }

    /// Owner policy: the review lists the runtime's command line and
    /// environment and a HIGH RISK line, and a declined review registers
    /// nothing (importing never starts the program either way).
    @Test
    func harnessRuntimeIsReviewedAsHighRisk_andDeclinedRegistersNothing() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(withRuntime: true)
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let reviews = Reviews()
                let request = try enqueue(.install, fixture)
                _ = await processor(answer: .denied, reviews: reviews).process(requestId: request.id)

                let plan = try #require(reviews.all.first)
                #expect(plan.hasHighRiskChanges)
                #expect(plan.risks.contains { $0.contains("launches a local program") })
                let row = try #require(
                    plan.actions.first { $0.section == "harness_runtimes" && $0.target == fixture.runtime })
                #expect(row.changes.contains { $0.contains("/bin/cat --mode rpc --session-id {chat_id}") })
                #expect(row.changes.contains { $0.contains("environment[PI_LOG_LEVEL]: info") })
                #expect(plan.actions.contains { $0.section == "agents" && $0.target == fixture.agent })
                #expect(plan.risks.contains { $0.contains("runs on harness") })
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(agent(named: fixture.agent) == nil)
                #expect(receipts(fixture).isEmpty)
            }
        }
    }

    @Test
    func harnessRuntimeInstallsWithItsAgent_afterReview_andIsRemovedOnlyWhenUnused() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(withRuntime: true)
                defer { try? FileManager.default.removeItem(at: fixture.root) }

                let installed = try await run(.install, fixture)
                #expect(installed.status == .applied, "\(installed.items)")
                #expect(installed.items.map(\.kind) == [.skill, .harnessRuntime, .agent])
                let runtime = try #require(ConfigHarness.runtime(named: fixture.runtime))
                #expect(runtime.kind == .piRPC)
                #expect(runtime.executable == "/bin/cat")
                #expect(runtime.arguments == ["--mode", "rpc", "--session-id", "{chat_id}"])
                #expect(runtime.environment == ["PI_LOG_LEVEL": "info"])
                let created = try #require(agent(named: fixture.agent))
                #expect(created.runtime == .harness(runtime.id))
                #expect(receipts(fixture).first { $0.kind == .harnessRuntime }?.harnessRuntimeId == runtime.id.uuidString)
                #expect(receipts(fixture).first { $0.kind == .agent }?.harnessRuntime == fixture.runtime)

                let again = try await run(.install, fixture)
                #expect(again.items.allSatisfy { $0.status == .unchanged }, "\(again.items)")

                let blocked = try await run(.remove, fixture, kinds: [.harnessRuntime])
                #expect(blocked.items.first?.status == .failed)
                #expect(blocked.items.first?.message?.contains(fixture.agent) == true)
                #expect(ConfigHarness.runtime(named: fixture.runtime) != nil)

                let removed = try await run(.remove, fixture)
                #expect(removed.items.allSatisfy { $0.status == .done }, "\(removed.items)")
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(agent(named: fixture.agent) == nil)
                #expect(receipts(fixture).isEmpty)
            }
        }
    }

    @Test
    func agentPullsInItsRuntime_andRemovingTheAgentRemovesIt() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(withRuntime: true)
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let bundle = try OsaurusBundle.load(from: fixture.root)
                let refs = try bundle.select(kind: .agent, names: [fixture.agent])
                #expect(refs.contains { $0.kind == .harnessRuntime && !$0.explicit })
                let request = ImportRequest(
                    bundleId: bundle.id, bundleName: nil, bundleVersion: bundle.manifest.version,
                    operations: refs.map {
                        ImportOperation(action: .install, kind: $0.kind, name: $0.name, explicit: $0.explicit)
                    },
                    confirmHighRisk: true)
                try ImportQueue.enqueue(request, bundle: bundle)
                let installed = try #require(await processor().process(requestId: request.id))
                guard case .completed(let result) = installed else {
                    Issue.record("expected the request to complete, got \(installed)")
                    return
                }
                #expect(result.status == .applied, "\(result.items)")

                let removed = try await run(.remove, fixture, kinds: [.agent])
                #expect(removed.items.map(\.kind) == [.agent, .harnessRuntime], "\(removed.items)")
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                #expect(receipts(fixture).isEmpty)
            }
        }
    }

    /// Intel: `OSAURUS_*` is refused in an imported runtime, as the Runtimes
    /// editor refuses it; the runtime and its agent are not installed.
    @Test
    func harnessRuntimeWithAnOsaurusEnvironmentKeyIsRefused() async throws {
        try await exclusive {
            try await withRuntimeStore {
                let fixture = try makeFixture(
                    withRuntime: true, runtimeEnvironment: ["OSAURUS_AGENT_TOKEN": "x", "PI_LOG_LEVEL": "info"])
                defer { try? FileManager.default.removeItem(at: fixture.root) }

                let result = try await run(.install, fixture)
                let runtime = try #require(result.items.first { $0.kind == .harnessRuntime })
                #expect(runtime.status == .failed)
                #expect(runtime.message?.contains("OSAURUS_AGENT_TOKEN") == true, "\(runtime.message ?? "")")
                #expect(ConfigHarness.runtime(named: fixture.runtime) == nil)
                let agentRow = try #require(result.items.first { $0.kind == .agent })
                #expect(agentRow.status == .failed)
                #expect(agent(named: fixture.agent) == nil)
                #expect(HarnessRuntimeStore.shared.all().allSatisfy { $0.displayName != fixture.runtime })
            }
        }
    }

    /// Owner policy: the review lists every change before anything lands.
    @Test
    func reviewListsSkillAndAgentRows_beforeAnythingIsApplied() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let reviews = Reviews()
            let seen = processor(answer: .denied, reviews: reviews)
            let request = try enqueue(.install, fixture)
            _ = await seen.process(requestId: request.id)

            let plan = try #require(reviews.all.first)
            #expect(plan.actions.contains { $0.section == "skills" && $0.target == fixture.skill })
            #expect(plan.actions.contains { $0.section == "agents" && $0.target == fixture.agent })
            #expect(plan.notes.first?.contains("Import Probe") == true)
        }
    }

    @Test
    func declinedReview_changesNothing_andCompletesTheRequestAsFailed() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let request = try enqueue(.install, fixture)
            let outcome = try #require(await processor(answer: .denied).process(requestId: request.id))
            guard case .completed(let result) = outcome else {
                Issue.record("a denial completes the request")
                return
            }
            #expect(result.items.allSatisfy { $0.status == .failed }, "\(result.items)")
            #expect(result.items.allSatisfy { $0.message?.contains("Declined") == true })
            #expect(agent(named: fixture.agent) == nil)
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
            #expect(receipts(fixture).isEmpty)
            #expect(!ImportQueue.pending().contains { $0.request.id == request.id })
        }
    }

    /// No chat window to show the review (`ConfigApprovalService` answers
    /// `.cancelled`) or a timeout: nothing applies and the request stays queued.
    @Test(arguments: [ConfigApprovalOutcome.cancelled, .timedOut])
    func unansweredReview_changesNothing_andKeepsTheRequestQueued(answer: ConfigApprovalOutcome) async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let request = try enqueue(.install, fixture)
            let outcome = try #require(await processor(answer: answer).process(requestId: request.id))
            guard case .awaitingApproval(let reason) = outcome else {
                Issue.record("expected awaitingApproval, got \(outcome)")
                return
            }
            #expect(reason == answer)
            #expect(agent(named: fixture.agent) == nil)
            #expect(SkillManager.shared.skill(named: fixture.skill) == nil)
            #expect(receipts(fixture).isEmpty)
            #expect(ImportQueue.pending().contains { $0.request.id == request.id })
            #expect(ImportQueue.result(id: request.id) == nil)

            // processAll stops at the first unanswered request.
            let all = await processor(answer: answer).processAll()
            #expect(all.count == 1)
            #expect(ImportQueue.pending().contains { $0.request.id == request.id })
        }
    }

    @Test
    func theCallersYesDoesNotApproveAnything() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            // `confirmHighRisk: true` is what `osaurus import install --yes` queues.
            let request = try enqueue(.install, fixture)
            #expect(request.confirmHighRisk)
            let outcome = try #require(await processor(answer: .cancelled).process(requestId: request.id))
            guard case .awaitingApproval = outcome else {
                Issue.record("--yes must not skip the review")
                return
            }
            #expect(agent(named: fixture.agent) == nil)
        }
    }

    @Test
    func mcpServerRowCarriesTheHighRiskLine() async throws {
        try await exclusive {
            let fixture = try makeFixture(withServer: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let reviews = Reviews()
            let request = try enqueue(.install, fixture)
            // Denied, so the server is never registered or started.
            _ = await processor(answer: .denied, reviews: reviews).process(requestId: request.id)

            let plan = try #require(reviews.all.first)
            #expect(plan.hasHighRiskChanges)
            #expect(plan.risks.contains { $0.contains("launches a local process") })
            #expect(plan.actions.contains { $0.section == "mcp_servers" })
            #expect(MCPProviderManager.shared.configuration.providers.allSatisfy { $0.name != fixture.server })
        }
    }

    @Test
    func neverTouchesItemsTheBundleDoesNotOwn() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let mine = AgentManager.newCustomAgentRecord(name: fixture.agent)
            AgentManager.shared.add(mine)
            defer { Task { _ = await AgentManager.shared.delete(id: mine.id) } }

            let result = try await run(.install, fixture)
            let row = try #require(result.items.first { $0.kind == .agent })
            #expect(row.status == .failed)
            #expect(row.message?.contains("was not installed by") == true)
            #expect(agent(named: fixture.agent)?.systemPrompt == mine.systemPrompt)
            #expect(result.exitCode == 1)

            _ = try await run(.remove, fixture)
        }
    }

    @Test
    func updateDoesNotBringBackWhatTheUserDeleted() async throws {
        try await exclusive {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try await run(.install, fixture)
            let installed = try #require(agent(named: fixture.agent))
            _ = await AgentManager.shared.delete(id: installed.id)

            let updated = try await run(.update, fixture)
            let row = try #require(updated.items.first { $0.kind == .agent })
            #expect(row.status == .skipped)
            #expect(agent(named: fixture.agent) == nil)

            _ = try await run(.remove, fixture)
        }
    }

    // MARK: - Settings

    @MainActor
    private final class FakeSettings: ImportSettingsAccess {
        var toggle = false
        var origins: [String] = []
        var keys = false
        var restarts = 0
        var sets: [String] = []
        func value(of setting: BundleSetting) -> BundleSettingValue {
            setting.id == .requireLocalAccessKey ? .bool(toggle) : .strings(origins)
        }
        func set(_ value: BundleSettingValue, for setting: BundleSetting) {
            sets.append(setting.key)
            switch value {
            case .bool(let flag): toggle = flag
            case .strings(let list): origins = list
            }
        }
        func hasAccessKeys() -> Bool { keys }
        func applyDeferredChanges() async { restarts += 1 }
    }

    @Test
    func settingsOnlyChangeAfterApproval_andLooseningOnesAreListedAsRisks() async throws {
        try await exclusive {
            let fixture = try makeFixture(
                settings: ["require_local_access_key": true, "allowed_origins": ["https://app.example.com"]])
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let fake = FakeSettings()
            let reviews = Reviews()
            let declined = processor(answer: .denied, reviews: reviews)
            declined.settings = fake
            let request = try enqueue(.install, fixture)
            _ = await declined.process(requestId: request.id)
            #expect(fake.sets.isEmpty, "a denied review must not touch settings")
            let plan = try #require(reviews.all.first)
            #expect(plan.actions.contains { $0.section == "settings" })
            #expect(plan.risks.contains { $0.contains("https://app.example.com") })

            let approved = processor()
            approved.settings = fake
            let again = try enqueue(.install, fixture)
            let outcome = try #require(await approved.process(requestId: again.id))
            guard case .completed(let result) = outcome else {
                Issue.record("expected completion")
                return
            }
            #expect(fake.toggle)
            #expect(fake.origins == ["https://app.example.com"])
            #expect(result.items.contains { $0.kind == .setting && $0.name == "allowed_origins" })

            _ = try await run(.remove, fixture)
        }
    }
}
