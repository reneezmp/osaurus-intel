//
//  PeerCallNotifierTests.swift
//  osaurusTests
//
//  The host toast for a peer driving one of this Mac's agents (#1676) is
//  debounced per peer so a burst of calls shows one toast.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct PeerCallNotifierTests {
    @Test func debouncesPerPeer() {
        let notifier = PeerCallNotifier.shared
        let start = Date(timeIntervalSince1970: 1_000_000)
        let peerA = "test-peer-a-\(UUID().uuidString)"
        let peerB = "test-peer-b-\(UUID().uuidString)"

        #expect(notifier.shouldNotify(peerA, now: start))
        // Same peer inside the cooldown is silent; another peer is not.
        #expect(!notifier.shouldNotify(peerA, now: start.addingTimeInterval(30)))
        #expect(notifier.shouldNotify(peerB, now: start.addingTimeInterval(30)))
        // After the cooldown the first peer surfaces again.
        #expect(notifier.shouldNotify(peerA, now: start.addingTimeInterval(61)))
    }
}
