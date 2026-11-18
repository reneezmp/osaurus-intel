//
//  ConfigSecretRefTests.swift
//  OsaurusCoreTests
//
//  Phase 4 — secrets by reference. Pins the `*_ref` grammar, the planner
//  validation (format, env presence, placement rules, mutual exclusion),
//  the plan wording (ref display names only — never values), and the
//  channel apply path end-to-end via the in-memory test Keychain. The
//  MCP/provider Keychains have no in-memory store: under
//  OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS their apply paths are pinned to the
//  documented needs-user-action / failure shapes; with a live Keychain
//  (CI's xcodebuild lane) the store succeeds and the row completes.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Grammar

struct ConfigSecretRefGrammarTests {

    @Test
    func parsesEnvAndKeychainForms() {
        guard case .success(let env) = ConfigSecretRef.parse("env:MY_API_KEY") else {
            Issue.record("env ref failed to parse")
            return
        }
        #expect(env.source == .env("MY_API_KEY"))
        #expect(env.display == "env:MY_API_KEY")

        guard case .success(let kc) = ConfigSecretRef.parse("keychain:my-service/my-account")
        else {
            Issue.record("keychain ref failed to parse")
            return
        }
        #expect(kc.source == .keychain(service: "my-service", account: "my-account"))
        #expect(kc.display == "keychain:my-service/my-account")
    }

    @Test
    func rejectsMalformedRefs() {
        for raw in [
            "sk-live-actual-secret",  // a raw secret is never a ref
            "env:",
            "env:9BAD",
            "env:HAS SPACE",
            "keychain:no-slash",
            "keychain:/account",
            "keychain:service/",
        ] {
            if case .success = ConfigSecretRef.parse(raw) {
                Issue.record("`\(raw)` should not parse as a secret ref")
            }
        }
    }

    @Test
    func envResolutionUsesOverrideAndTrims() {
        let environment = ["SET_KEY": "  value-123  ", "EMPTY_KEY": "   "]

        guard case .success(let set) = ConfigSecretRef.parse("env:SET_KEY"),
            case .success(let empty) = ConfigSecretRef.parse("env:EMPTY_KEY"),
            case .success(let missing) = ConfigSecretRef.parse("env:MISSING_KEY")
        else {
            Issue.record("refs failed to parse")
            return
        }
        #expect(set.resolve(environment: environment) == "value-123")
        #expect(empty.resolve(environment: environment) == nil)
        #expect(missing.resolve(environment: environment) == nil)
        #expect(set.planTimeIssue(label: "x", environment: environment) == nil)
        #expect(empty.planTimeIssue(label: "x", environment: environment) != nil)
        #expect(missing.planTimeIssue(label: "x", environment: environment) != nil)
    }
}
