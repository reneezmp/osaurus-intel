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

    @Test("General-page entries resolve to an anchor inside their section")
    func generalEntriesAnchor() throws {
        let general = try Self.source("Settings/ConfigurationView.swift")
        for entry in SettingsSearchIndex.entries where entry.tab == .settings {
            #expect(!entry.isTabLevel)
            #expect(general.contains("title: \"\(entry.section)\""), "\(entry.id): section missing")
            let label = entry.anchorLabel ?? entry.title
            #expect(general.contains("\"\(label)\""), "\(entry.id): control \"\(label)\" missing")
            #expect(SettingsSearchIndex.anchorID(section: entry.section, label: label) == entry.id)
        }
        // Same label in another section must not steal the anchor.
        #expect(SettingsSearchIndex.anchorID(section: "Chat", label: "Temperature") == "settings.chat.temperature")
        #expect(SettingsSearchIndex.anchorID(section: "Work", label: "Temperature") == nil)
        #expect(SettingsSearchIndex.anchorID(section: "Chat", label: "Tools") == "settings.chat.disableTools")
    }

    @Test("Search ranks title hits first and needs every word")
    func searchRanking() {
        #expect(SettingsSearchIndex.search("spelling").first?.id == "settings.chat.spellCheck")
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
        #expect(temp.breadcrumbPath == "General › Chat › Temperature")
    }
}
