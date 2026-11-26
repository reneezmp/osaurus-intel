//
//  SettingsSearchIndexTests.swift
//  OsaurusCoreTests
//
//  Intel settings search (upstream #49). The index is hand-written from the
//  Intel UI, so these tests keep it honest: every title must be a string the
//  Intel views really show, every tab must be one Intel exposes, and General
//  page entries must resolve to an anchor on their control.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Settings search index (Intel)")
struct SettingsSearchIndexTests {
    private static let viewsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Configuration
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // OsaurusCore
        .appendingPathComponent("Views")

    /// Every string literal in the compiled view sources.
    private static let viewLiterals: Set<String> = {
        var literals = Set<String>()
        let regex = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let enumerator = FileManager.default.enumerator(at: viewsRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range(at: 1), in: text) { literals.insert(String(text[r])) }
            }
        }
        return literals
    }()

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: viewsRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Entry ids are unique")
    func uniqueIDs() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every entry targets a tab Intel shows")
    func tabsExistOnIntel() {
        let unavailable = Set(ManagementSection.unavailable.tabs)
        let shown = Set(ManagementSection.allCases.filter { $0 != .unavailable }.flatMap(\.tabs))
        for entry in SettingsSearchIndex.entries {
            #expect(!unavailable.contains(entry.tab), "\(entry.id) points at an unavailable tab")
            #expect(shown.contains(entry.tab), "\(entry.id) points at a tab missing from the sidebar")
        }
    }

    @Test("Every title (and host label) is a string the Intel views show")
    func titlesAreGrounded() {
        for entry in SettingsSearchIndex.entries {
            let grounded = entry.title == entry.tab.label || Self.viewLiterals.contains(entry.title)
            #expect(grounded, "\(entry.id): \"\(entry.title)\" is not in any Intel view")
            if let label = entry.anchorLabel {
                #expect(Self.viewLiterals.contains(label), "\(entry.id): host \"\(label)\" not found")
            }
        }
    }

    /// General and Conversation (upstream #2950 layout): every entry lands on
    /// a control, either through an explicit `anchorId` or through its
    /// (section, label) pair; entries in Advanced must also open the
    /// disclosure.
    @Test("General and Conversation entries resolve to an anchor on their control")
    func generalAndConversationEntriesAnchor() throws {
        let pages: [(ManagementTab, String, Set<String>)] = [
            (.settings, try Self.source("Settings/ConfigurationView.swift") + (try Self.source("Settings/StorageSettingsView.swift"))
                + (try Self.source("Settings/FileHistoryRetentionSection.swift"))
                + (try Self.source("Settings/ActivityLogSettingsSection.swift")),
             ConfigurationView.advancedAnchorIds),
            (.chat, try Self.source("Settings/ChatSettingsView.swift"), ChatSettingsView.advancedAnchorIds),
        ]
        for (tab, source, advancedIDs) in pages {
            for entry in SettingsSearchIndex.entries where entry.tab == tab {
                #expect(!entry.isTabLevel)
                let explicit =
                    source.contains("anchorId: \"\(entry.id)\"")
                    || source.contains("settingsLandingAnchor(\"\(entry.id)\")")
                    || source.contains("? \"\(entry.id)\" :")
                if !explicit {
                    #expect(source.contains("title: \"\(entry.section)\""), "\(entry.id): section missing")
                    let label = entry.anchorLabel ?? entry.title
                    #expect(source.contains("\"\(label)\""), "\(entry.id): control \"\(label)\" missing")
                    #expect(SettingsSearchIndex.anchorID(section: entry.section, label: label) == entry.id)
                }
                if entry.section == "Advanced" {
                    #expect(advancedIDs.contains(entry.id), "\(entry.id) sits in Advanced but cannot open it")
                }
            }
        }
        // Same label in another section must not steal the anchor.
        #expect(SettingsSearchIndex.anchorID(section: "Advanced", label: "Temperature") == "settings.chat.temperature")
        #expect(SettingsSearchIndex.anchorID(section: "Work", label: "Temperature") == nil)
        // The chat-wide Disable Tools switch is gone (upstream #2505).
        #expect(SettingsSearchIndex.anchorID(section: "Behavior", label: "Disable Tools") == nil)
    }

    @Test("Search ranks title hits first and needs every word")
    func searchRanking() {
        #expect(SettingsSearchIndex.search("spelling").first?.id == "settings.chat.spellCheck")
        #expect(SettingsSearchIndex.search("collapse long pastes").first?.id == "settings.chat.collapseLongPastes")
        #expect(SettingsSearchIndex.search("hotkey").first?.id == "settings.general.hotkey")
        #expect(SettingsSearchIndex.search("clipboard monitoring").first?.id == "settings.chat.clipboard")
        #expect(SettingsSearchIndex.search("recovery phrase").contains { $0.id == "identity.recovery" })
        #expect(SettingsSearchIndex.search("api key").contains { $0.id == "providers.overview" })
        #expect(SettingsSearchIndex.search("   ").isEmpty)
        #expect(SettingsSearchIndex.search("zzqxv").isEmpty)
        // Title matches outrank keyword-only matches.
        let temperature = SettingsSearchIndex.search("temperature")
        #expect(temperature.first?.id == "settings.chat.temperature")
    }

    @Test("Breadcrumbs collapse a section that repeats the tab")
    func breadcrumbs() throws {
        let hotkey = try #require(SettingsSearchIndex.entries.first { $0.id == "settings.general.hotkey" })
        #expect(hotkey.breadcrumbPath == "General › Global Hotkey")
        let temp = try #require(SettingsSearchIndex.entries.first { $0.id == "settings.chat.temperature" })
        #expect(temp.breadcrumbPath == "Conversation › Advanced › Temperature")
    }

    /// Views carry landing anchors from upstream; an anchor without an index
    /// entry is a control that search cannot find (W-settings-ux-2950, stage 1:
    /// Mobile, Browser Use, Identity, Web Search and Voice had several).
    @Test("Every landing anchor in the views has a search entry")
    func everyAnchorHasEntry() throws {
        // Page-level anchors that the tab-level entries already cover.
        let coveredByTab: Set<String> = ["themes.appearance", "voice.models"]
        let regex = try NSRegularExpression(
            pattern: #"(?:settingsLandingAnchor\(|anchorId: )"([^"]+)""#)
        let ids = Set(SettingsSearchIndex.entries.map(\.id))
        let enumerator = FileManager.default.enumerator(at: Self.viewsRoot, includingPropertiesForKeys: nil)
        var missing: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let id = String(text[r])
                if !ids.contains(id), !coveredByTab.contains(id) { missing.append(id) }
            }
        }
        #expect(missing.isEmpty, "anchors without a search entry: \(Set(missing).sorted())")
    }

    @Test("Mobile, Browser Use and Web Search controls are findable")
    func previouslyMissingTabsAreSearchable() {
        #expect(SettingsSearchIndex.search("pairing code").first?.tab == .connect)
        #expect(SettingsSearchIndex.search("reach from anywhere").first?.id == "settings.connect.reachAnywhere")
        #expect(SettingsSearchIndex.search("browser sessions").contains { $0.id == "browser.sessions" })
        #expect(SettingsSearchIndex.search("codex").contains { $0.id == "server.codexCLI" })
        #expect(SettingsSearchIndex.search("speaking rate").contains { $0.id == "voice.tts.rate" })
    }
}
