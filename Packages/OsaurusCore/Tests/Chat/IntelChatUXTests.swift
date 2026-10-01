//
//  IntelChatUXTests.swift
//  OsaurusCoreTests
//
//  Intel checks for the `W-chat-ux` ports (docs/CHAT_UX_INTEL.md): the "@"
//  file menu's resolver and lister (upstream ships no test for them) and the
//  composer wiring that Intel's own views add.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Intel chat UX")
struct IntelChatUXTests {

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmenu-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("src/main.swift"))
        try Data("c".utf8).write(to: root.appendingPathComponent(".hidden"))
        return root
    }

    @Test("@ lists the work folder: folders first, dotfiles hidden until typed")
    func atMenuListsWorkFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = AtFileMenu.list(query: "", rootPath: root)
        #expect(all.status == .ok)
        #expect(all.items.map(\.name) == ["docs", "src", "README.md"])
        #expect(all.items.first?.isDirectory == true)

        let filtered = AtFileMenu.list(query: "sr", rootPath: root)
        #expect(filtered.items.map(\.name) == ["src"])

        let nested = AtFileMenu.list(query: "src/", rootPath: root)
        #expect(nested.items.map(\.name) == ["main.swift"])
        // Temp paths may resolve through /private; compare the tail.
        #expect(nested.items.first?.path.hasSuffix("/src/main.swift") == true)

        let dot = AtFileMenu.list(query: ".h", rootPath: root)
        #expect(dot.items.map(\.name) == [".hidden"])

        let missing = AtFileMenu.list(query: "nope/", rootPath: root)
        #expect(missing.status == .notFound)
    }

    @Test("@ resolves absolute and tilde queries directly")
    func atMenuResolve() {
        let abs = AtFileMenu.resolve(query: "/etc/ho", rootPath: nil)
        #expect(abs.dir.path == "/etc")
        #expect(abs.filter == "ho")
        let tilde = AtFileMenu.resolve(query: "~/", rootPath: URL(fileURLWithPath: "/tmp"))
        #expect(tilde.dir.path == NSHomeDirectory())
        #expect(tilde.filter.isEmpty)
    }
}
