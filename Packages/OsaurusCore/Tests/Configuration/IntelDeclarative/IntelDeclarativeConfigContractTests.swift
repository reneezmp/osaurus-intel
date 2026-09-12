//
//  IntelDeclarativeConfigContractTests.swift
//  OsaurusCoreTests
//
//  Gate 5 tests for the bounded Intel declarative configuration plane.
//
//  These tests deliberately exercise the Intel slice only:
//  default_agent and delegation are supported; other upstream domains must
//  fail closed. The fixture uses OSAURUS_TEST_ROOT and a disposable file
//  store, serialized with StoragePathsTestLock, so no real user settings are
//  touched.
//
//  The current core exposes approval creation rather than public denied or
//  cancelled approval values. Invalid approval covers the same fail-closed
//  boundary; a public denial/cancellation seam should add cases beside it.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel declarative configuration contract", .serialized)
struct IntelDeclarativeConfigContractTests {
    @Test("strict decoding accepts the bounded Gate 5 shape")
    func strictDecodeAcceptsSupportedShape() throws {
        let document = try IntelDeclarativeConfigurationDocument.decode(
            json: Data(
                """
                {
                  "version": 1,
                  "default_agent": {
                    "name": "Sunny",
                    "system_prompt": "Be precise.",
                    "model": "cloud/example",
                    "temperature": 0.25,
                    "max_tokens": 2048
                  },
                  "delegation": {
                    "allowed_agent_ids": [],
                    "admitted_cloud_model_ids": ["cloud/child"],
                    "permissions": {},
                    "max_child_tokens": 256,
                    "max_input_characters": 12000,
                    "max_output_characters": 8192,
                    "timeout_seconds": 30
                  }
                }
                """.utf8
            )
        )

        #expect(document.defaultAgent?.displayName == .set("Sunny"))
        #expect(document.defaultAgent?.systemPrompt == .set("Be precise."))
        #expect(document.defaultAgent?.defaultModel == .set("cloud/example"))
        #expect(document.defaultAgent?.temperature == .set(0.25))
        #expect(document.defaultAgent?.maxTokens == .set(2048))
        #expect(document.delegation?.admittedCloudModelIDs == .set(["cloud/child"]))
    }

    @Test("unknown nested keys are rejected without mutation")
    func unknownNestedKeysAreRejectedWithoutMutation() async throws {
        try await withFixture { fixture in
            let malformed = Data(
                #"{"version":1,"default_agent":{"temprature":0.7}}"#.utf8
            )
            let before = fixture.store.load()

            #expect(throws: IntelDeclarativeConfigurationError.self) {
                try IntelDeclarativeConfigurationDocument.decode(json: malformed)
            }
            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.plan(json: malformed)
            }
            #expect(fixture.store.load() == before)
            #expect(fixture.store.saveCount == 0)
        }
    }

    @Test("unknown top-level domains are rejected with a dependency-aware error")
    func unknownDomainIsRejected() throws {
        do {
            _ = try IntelDeclarativeConfigurationDocument.decode(
                json: Data(#"{"version":1,"agents":[]}"#.utf8)
            )
            Issue.record("expected unsupported-domain rejection")
        } catch let error as IntelDeclarativeConfigurationError {
            #expect(error == .unsupportedDomain("agents"))
            #expect(error.errorDescription?.contains("Intel") == true)
        }
    }

    @Test("secret-shaped input is rejected without echoing its value")
    func secretShapedInputDoesNotLeakValue() {
        let secret = "super-secret-\(UUID().uuidString)"
        let input = Data(
            #"{"version":1,"default_agent":{"api_key":""#.utf8
        ) + Data(secret.utf8) + Data(#""}}"#.utf8)

        do {
            _ = try IntelDeclarativeConfigurationDocument.decode(json: input)
            Issue.record("expected secret-shaped key rejection")
        } catch let error as IntelDeclarativeConfigurationError {
            #expect(error == .secretReference(path: "$.default_agent.api_key"))
            #expect(!String(describing: error).contains(secret))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ordinary token limits are accepted while booleans and out-of-range numbers are rejected")
    func numericFieldsAreStrict() throws {
        _ = try IntelDeclarativeConfigurationDocument.decode(json: Data(
            #"{"version":1,"default_agent":{"max_tokens":2048,"temperature":0.5}}"#.utf8
        ))
        #expect(throws: IntelDeclarativeConfigurationError.self) {
            try IntelDeclarativeConfigurationDocument.decode(json: Data(
                #"{"version":1,"default_agent":{"temperature":true}}"#.utf8
            ))
        }
        #expect(throws: IntelDeclarativeConfigurationError.self) {
            try IntelDeclarativeConfigurationDocument.decode(json: Data(
                #"{"version":1,"default_agent":{"max_tokens":65537}}"#.utf8
            ))
        }
    }

    @Test("malformed input never mutates the disposable store")
    func malformedInputNeverMutatesTheDisposableStore() async throws {
        try await withFixture { fixture in
            let before = fixture.store.load()
            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.plan(json: Data(#"{"version":1,"#.utf8))
            }
            #expect(fixture.store.load() == before)
            #expect(fixture.store.saveCount == 0)
        }
    }

    @Test("plans are deterministic, idempotent, and read-only")
    func plansAreDeterministicIdempotentAndReadOnly() async throws {
        try await withFixture { fixture in
            let json = Data(
                #"{"version":1,"default_agent":{"name":"Sunny","max_tokens":2048}}"#.utf8
            )
            let first = try await fixture.service.plan(json: json)
            let second = try await fixture.service.plan(json: json)

            #expect(first == second)
            #expect(first.changes.count == 2)
            #expect(first.isNoOp == false)
            #expect(fixture.store.saveCount == 0)

            let noOp = try await fixture.service.plan(json: Data(
                #"{"version":1}"#.utf8
            ))
            #expect(noOp.isNoOp)
            #expect(noOp.changes.isEmpty)
            #expect(fixture.store.saveCount == 0)
        }
    }

    @Test("successful apply mutates only the isolated store after exact approval")
    func successfulApplyMutatesOnlyTheIsolatedStoreAfterExactApproval() async throws {
        try await withFixture { fixture in
            let plan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Gate 5","max_tokens":1024}}"#.utf8
            ))
            let approval = await fixture.service.approve(plan)
            let result = try await fixture.service.apply(plan, approval: approval)

            #expect(result.displayName == "Gate 5")
            #expect(result.maxTokens == 1024)
            #expect(fixture.store.saveCount == 1)
            let noOp = try await fixture.service.plan(json: Data(#"{"version":1}"#.utf8))
            #expect(noOp.isNoOp)
        }
    }

    @Test("approval for a different plan is rejected and cannot mutate")
    func approvalForADifferentPlanIsRejectedAndCannotMutate() async throws {
        try await withFixture { fixture in
            let first = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"One"}}"#.utf8
            ))
            let second = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Two"}}"#.utf8
            ))
            let approvalForFirst = await fixture.service.approve(first)

            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.apply(second, approval: approvalForFirst)
            }
            #expect(fixture.store.saveCount == 0)
            #expect(fixture.store.load().displayName == "Original")
        }
    }

    @Test("invalid approval is fail-closed")
    func invalidApprovalIsFailClosed() async throws {
        try await withFixture { fixture in
            let plan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Denied"}}"#.utf8
            ))
            let otherPlan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Other"}}"#.utf8
            ))
            let invalidApproval = await fixture.service.approve(otherPlan)

            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.apply(plan, approval: invalidApproval)
            }
            #expect(fixture.store.saveCount == 0)
        }
    }

    @Test("approval replay is rejected after the first successful apply")
    func approvalReplayIsRejectedAfterTheFirstSuccessfulApply() async throws {
        try await withFixture { fixture in
            let plan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Applied"}}"#.utf8
            ))
            let approval = await fixture.service.approve(plan)
            _ = try await fixture.service.apply(plan, approval: approval)
            #expect(fixture.store.saveCount == 1)

            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.apply(plan, approval: approval)
            }
            #expect(fixture.store.saveCount == 1)
        }
    }

    @Test("a stale plan is rejected after external state changes")
    func stalePlanIsRejectedAfterExternalStateChanges() async throws {
        try await withFixture { fixture in
            let plan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Planned"}}"#.utf8
            ))
            let approval = await fixture.service.approve(plan)
            fixture.store.externalSave(DefaultAgentConfiguration(displayName: "Changed elsewhere"))

            await #expect(throws: IntelDeclarativeConfigurationError.self) {
                try await fixture.service.apply(plan, approval: approval)
            }
            #expect(fixture.store.load().displayName == "Changed elsewhere")
            #expect(fixture.store.saveCount == 1)
        }
    }

    @Test("an unreadable persisted result never passes verification through memory")
    func unreadablePersistenceFailsVerification() async throws {
        try await withFixture { fixture in
            let plan = try await fixture.service.plan(json: Data(
                #"{"version":1,"default_agent":{"name":"Must persist"}}"#.utf8
            ))
            let approval = await fixture.service.approve(plan)
            fixture.store.failNextFreshLoad()

            do {
                _ = try await fixture.service.apply(plan, approval: approval)
                Issue.record("expected fresh-disk verification failure")
            } catch let error as IntelDeclarativeConfigurationError {
                #expect(error == .persistenceVerificationFailed)
            }
            #expect(fixture.store.saveCount == 1)
        }
    }
}

// MARK: - Disposable store fixture

private func withFixture(
    _ body: @Sendable (IntelDeclarativeTestFixture) async throws -> Void
) async throws {
    try await StoragePathsTestLock.shared.run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-intel-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let previousRoot = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]
        setenv("OSAURUS_TEST_ROOT", root.path, 1)
        defer {
            if let previousRoot {
                setenv("OSAURUS_TEST_ROOT", previousRoot, 1)
            } else {
                unsetenv("OSAURUS_TEST_ROOT")
            }
        }

        try await body(IntelDeclarativeTestFixture(directory: root))
    }
}

private struct IntelDeclarativeTestFixture: Sendable {
    let store: IntelDeclarativeTestStore
    let service: IntelDeclarativeConfigurationService

    init(directory: URL) {
        store = IntelDeclarativeTestStore(directory: directory)
        service = IntelDeclarativeConfigurationService(store: store)
    }
}

private final class IntelDeclarativeTestStore: IntelDeclarativeDefaultAgentStore, @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var value: DefaultAgentConfiguration
    private var shouldFailFreshLoad = false
    private(set) var saveCount = 0

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("default-agent.json")
        value = DefaultAgentConfiguration(displayName: "Original", maxTokens: 512)
    }

    func load() -> DefaultAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func loadFresh() throws -> DefaultAgentConfiguration {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailFreshLoad {
            shouldFailFreshLoad = false
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func failNextFreshLoad() {
        lock.lock()
        shouldFailFreshLoad = true
        lock.unlock()
    }

    func save(_ configuration: DefaultAgentConfiguration) throws {
        lock.lock()
        value = configuration
        saveCount += 1
        let data = try? JSONEncoder().encode(configuration)
        lock.unlock()
        if let data {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    func externalSave(_ configuration: DefaultAgentConfiguration) {
        try! save(configuration)
    }
}
