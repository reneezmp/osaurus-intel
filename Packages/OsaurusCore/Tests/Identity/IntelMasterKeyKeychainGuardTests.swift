//
//  IntelMasterKeyKeychainGuardTests.swift
//  osaurusTests
//
//  Under OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 (the documented test gate),
//  `MasterKey` must never touch the real `com.osaurus.account` identity slot
//  (upstream's hermetic contract, ported 2026-10-09 after Intel's identity
//  suite was found rewriting it on every full run). Also covers the
//  `existsCached()` memo (upstream #1523). Nothing here reaches the keychain.
//

import Foundation
import LocalAuthentication
import Testing

@testable import OsaurusCore

@Suite(.enabled(if: KeychainQueryHelpers.disablesKeychainForProcess))
struct IntelMasterKeyKeychainGuardTests {
    @Test func identityCallsAreNoOpsWhenTheKeychainIsDisabled() throws {
        #expect(!MasterKey.exists())
        #expect(!OsaurusIdentity.exists())
        #expect(throws: OsaurusIdentityError.self) {
            try MasterKey.install(seed: Data(repeating: 7, count: 32), allowReplace: true)
        }
        #expect(throws: OsaurusIdentityError.self) {
            try MasterKey.getPrivateKey(context: LAContext())
        }
        #expect(MasterKey.delete())
    }

    @Test func cachedExistenceNeverReportsAnIdentityHere() {
        // `delete()` seeds the memo with false under the gate; the memo never
        // queries the keychain on the calling thread.
        _ = MasterKey.delete()
        #expect(!MasterKey.existsCached())
        #expect(!OsaurusIdentity.existsCached())
    }
}
