//
//  IntelRelayTests.swift
//  OsaurusCoreTests
//
//  `W-identity-mobile` stage 4 (docs/IDENTITY_MOBILE_INTEL.md): Intel's
//  rules around the real relay. Reach From Anywhere starts off (Renée,
//  2026-11-03), and tunnel switches saved by another build, never in effect
//  while Intel's relay was a stub, are turned off once. (The off default is
//  checked in `MobilePairingTests`.) Nothing here opens a
//  tunnel: the paths and stores are under the test root, and the relay only
//  connects for an enabled agent with a readable master key.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct IntelRelayTests {

    private func relayMarker() -> URL {
        OsaurusPaths.config().appendingPathComponent(IntelNetworkExposure.relayResetMarkerName)
    }

    @Test func savedTunnels_areTurnedOffOnce() {
        let fm = FileManager.default
        let marker = relayMarker()
        let previous = RelayConfigurationStore.load()
        try? fm.removeItem(at: marker)
        defer {
            RelayConfigurationStore.save(previous)
            try? fm.removeItem(at: marker)
        }

        var saved = RelayConfiguration.default
        let agentId = UUID()
        saved.setEnabled(true, for: agentId)
        RelayConfigurationStore.save(saved)

        #expect(IntelNetworkExposure.resetSavedRelaysOnce())
        #expect(RelayConfigurationStore.load().enabledAgentIds.isEmpty)
        #expect(fm.fileExists(atPath: marker.path))

        // The user turns a tunnel on again: it stays on.
        RelayConfigurationStore.save(saved)
        #expect(!IntelNetworkExposure.resetSavedRelaysOnce())
        #expect(RelayConfigurationStore.load().isEnabled(for: agentId))
    }

    @Test func freshInstall_justWritesTheRelayMarker() {
        let fm = FileManager.default
        let marker = relayMarker()
        let previous = RelayConfigurationStore.load()
        try? fm.removeItem(at: marker)
        RelayConfigurationStore.save(.default)
        defer {
            RelayConfigurationStore.save(previous)
            try? fm.removeItem(at: marker)
        }
        #expect(!IntelNetworkExposure.resetSavedRelaysOnce())
        #expect(fm.fileExists(atPath: marker.path))
    }

    /// A disabled tunnel stays off and reports nothing to connect to.
    @Test func aDisabledTunnelNeverConnects() {
        let agentId = UUID()
        let relay = RelayTunnelManager.shared
        #expect(!relay.isTunnelEnabled(for: agentId))
        relay.setTunnelEnabled(false, for: agentId)
        #expect(relay.agentStatuses[agentId] == .disconnected)
        #expect(!relay.isConnected)
    }
}
