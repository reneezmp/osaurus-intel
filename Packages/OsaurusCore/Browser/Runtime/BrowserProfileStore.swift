//
//  BrowserProfileStore.swift
//  osaurus
//
//  Intel (`W-browser-use`, decided by Renée 2026-10-11): upstream gives every
//  agent its own persistent WebKit profile through
//  `WKWebsiteDataStore(forIdentifier:)`, which needs macOS 14. On macOS 14+
//  this returns exactly that. On Ventura there is no way to create a separate
//  persistent store, so every agent shares the app's default persistent store:
//  cookies and sign-ins are visible to every agent's Browser Use, and
//  resetting one agent's browser data clears it for all of them. The settings
//  say so (`isolatesAgents`).
//

import WebKit

@MainActor
enum BrowserProfileStore {
    /// True when each agent gets its own browser profile (macOS 14+).
    nonisolated static var isolatesAgents: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    static func dataStore(for profileId: UUID) -> WKWebsiteDataStore {
        if #available(macOS 14, *) {
            return WKWebsiteDataStore(forIdentifier: profileId)
        }
        return WKWebsiteDataStore.default()
    }
}
