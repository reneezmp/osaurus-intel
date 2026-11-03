//
//  IntelNetworkExposure.swift
//  osaurus
//
//  Settings › Server › "Expose to Network" on Intel (`W-server-api`
//  stage 7, docs/SERVER_API_INTEL.md). Upstream's `ServerController`
//  (excluded) binds `0.0.0.0` with loopback trust off while the switch is
//  on, advertises Bonjour agents, and turns the switch on when an agent
//  enables Bonjour. Intel's `AppDelegate` runs the server, so the same
//  rules live here.
//
//  Until 2026-11-02 Intel bound `127.0.0.1` whatever the switch said, so a
//  saved "on" (from an upstream build, or an agent's Bonjour switch) was
//  never in effect. The first launch that honours it turns a saved "on"
//  off once (`resetSavedExposureOnce`), so no Mac starts listening on the
//  network by surprise after updating (Renée's call, 2026-11-02).
//
//  The relay (`W-identity-mobile` stage 4) gets the same treatment: Intel's
//  relay was a stub until 2026-11-03, so per-agent tunnel switches saved by
//  another build were never in effect. `resetSavedRelaysOnce` turns them off
//  once, and Reach From Anywhere starts off on Intel (Renée's call,
//  2026-11-03): nothing connects to the relay until the user turns it on.
//

import Foundation

@MainActor
enum IntelNetworkExposure {
    /// Written once the saved switch has been checked; never removed.
    static let resetMarkerName = "intel-network-exposure-reset.marker"

    static func resetMarkerURL() -> URL {
        OsaurusPaths.config().appendingPathComponent(resetMarkerName)
    }

    /// Turns a saved "Expose to Network" off, once per install. Returns true
    /// when it changed the saved setting.
    @discardableResult
    static func resetSavedExposureOnce(fileManager fm: FileManager = .default) -> Bool {
        let marker = resetMarkerURL()
        guard !fm.fileExists(atPath: marker.path) else { return false }
        var changed = false
        if var config = ServerConfigurationStore.load(), config.exposeToNetwork {
            config.exposeToNetwork = false
            ServerConfigurationStore.save(config, synchronous: true)
            changed = true
            NSLog("[Osaurus Intel] Expose to Network was saved on but never in effect; turned off once")
        }
        OsaurusPaths.ensureExistsSilent(marker.deletingLastPathComponent())
        let note = "network_exposure_reset=1\nchanged=\(changed ? 1 : 0)\n"
        try? Data(note.utf8).write(to: marker, options: .atomic)
        return changed
    }

    static let relayResetMarkerName = "intel-relay-reset.marker"

    /// Turns every saved per-agent relay tunnel off, once per install.
    /// Returns true when it changed the saved setting.
    @discardableResult
    static func resetSavedRelaysOnce(fileManager fm: FileManager = .default) -> Bool {
        let marker = OsaurusPaths.config().appendingPathComponent(relayResetMarkerName)
        guard !fm.fileExists(atPath: marker.path) else { return false }
        let saved = RelayConfigurationStore.load()
        let changed = !saved.enabledAgentIds.isEmpty
        if changed {
            RelayConfigurationStore.save(.default)
            NSLog("[Osaurus Intel] Relay tunnels were saved on but never in effect; turned off once")
        }
        OsaurusPaths.ensureExistsSilent(marker.deletingLastPathComponent())
        let note = "relay_reset=1\nchanged=\(changed ? 1 : 0)\n"
        try? Data(note.utf8).write(to: marker, options: .atomic)
        return changed
    }

    /// Upstream's bind rule: all interfaces and no loopback trust while
    /// exposed (local callers then need a key or the app's own token), else
    /// this Mac only.
    static func serverConfig(for config: ServerConfiguration) -> OsaurusServer.Config {
        OsaurusServer.Config(
            host: config.exposeToNetwork ? "0.0.0.0" : "127.0.0.1",
            port: config.port,
            trustLoopback: !config.exposeToNetwork
        )
    }

    /// Bonjour agents, and this Mac itself for the phone's pairing
    /// (`_osaurus-mobile._tcp`, `W-identity-mobile`), are advertised only
    /// while the server is reachable from the network (upstream).
    static func syncBonjour(for config: ServerConfiguration) {
        if config.exposeToNetwork {
            BonjourAdvertiser.shared.startAdvertising(port: config.port)
            MobileConnectAdvertiser.shared.startAdvertising(port: config.port)
        } else {
            BonjourAdvertiser.shared.stopAdvertising()
            MobileConnectAdvertiser.shared.stopAdvertising()
        }
    }

    /// Upstream: an agent with Bonjour discovery on needs the network, so it
    /// turns the switch on; nothing ever turns it off but the user.
    static func exposureRequired(by agents: [Agent], current config: ServerConfiguration) -> Bool {
        !config.exposeToNetwork && agents.contains { $0.bonjourEnabled }
    }
}
