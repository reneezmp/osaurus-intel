//
//  FolderToolsSymlinkContainmentTests.swift
//  osaurusTests
//
//  Intel: a symlink inside the working folder must not carry a folder tool
//  read or write outside it. Fixtures live under the system temporary
//  directory (`/var/folders/...`, physically `/private/var/...`), which also
//  covers the `/var` -> `/private/var` spelling for legitimate paths. The
//  tools get a fixed root, so no chat session, operation log, or live
//  `~/.osaurus` store is involved.
//

import Foundation
import Testing

@testable import OsaurusCore

struct FolderToolsSymlinkContainmentTests {

    /// `root/` holds the working folder, `outside/` a secret next to it.
    ///
    ///     root/a.txt                 regular file
    ///     root/sub/b.txt             nested file
    ///     root/inner -> sub          link that stays inside (relative)
    ///     root/dirlink -> outside    linked folder (absolute)
    ///     root/hop -> ../outside     linked folder (relative, via ..)
    ///     root/secret-link.txt -> outside/secret.txt
    ///     root/dangling.txt -> outside/created-through-link.txt (missing)
    ///     root/loop -> loop
    private struct Fixture {
        let base: URL
        let root: URL
        let outside: URL
        let secret: URL
        static let secretText = "outside-secret-7f3a"

        init() throws {
            let fm = FileManager.default
            base = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-folder-symlinks-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("root", isDirectory: true)
            outside = base.appendingPathComponent("outside", isDirectory: true)
            secret = outside.appendingPathComponent("secret.txt")
            try fm.createDirectory(
                at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Self.secretText.write(to: secret, atomically: true, encoding: .utf8)
            try "alpha\n".write(
                to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "beta needle\n".write(
                to: root.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)

            try link("inner", to: "sub")
            try link("dirlink", to: outside.path)
            try link("hop", to: "../outside")
            try link("secret-link.txt", to: secret.path)
            try link(
                "dangling.txt", to: outside.appendingPathComponent("created-through-link.txt").path)
            try link("loop", to: "loop")
        }

        private func link(_ name: String, to destination: String) throws {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(name).path,
                withDestinationPath: destination)
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }

        /// The outside folder is byte-for-byte what `init` created.
        func expectOutsideUntouched(sourceLocation: SourceLocation = #_sourceLocation) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
            #expect(names == ["secret.txt"], sourceLocation: sourceLocation)
            let text = try? String(contentsOf: secret, encoding: .utf8)
            #expect(text == Self.secretText, sourceLocation: sourceLocation)
        }
    }

    private static let escapingPaths = [
        "dirlink",
        "dirlink/secret.txt",
        "dirlink/new.txt",
        "dirlink/newdir/new.txt",
        "hop/secret.txt",
        "inner/../dirlink/secret.txt",
        "secret-link.txt",
        "dangling.txt",
        "loop/x.txt",
    ]

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// `result.text` of a success envelope.
    private static func text(_ envelope: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(envelope.utf8))
        let result = (object as? [String: Any])?["result"] as? [String: Any]
        return result?["text"] as? String ?? envelope
    }

    private static func isOutsideRoot(_ error: Error) -> Bool {
        if case FolderToolError.pathOutsideRoot = error { return true }
        return false
    }

    private static func expectRefused(
        _ path: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> String
    ) async {
        do {
            let result = try await body()
            Issue.record("\(path) should be refused, got \(result)", sourceLocation: sourceLocation)
        } catch {
            #expect(isOutsideRoot(error), "\(path): \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Resolver

    @Test func resolverRefusesSymlinkEscapes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for path in Self.escapingPaths + [fixture.root.path + "/dirlink/secret.txt"] {
            await Self.expectRefused(path) {
                try FolderToolHelpers.resolvePath(path, rootPath: fixture.root).path
            }
        }
        // Lexical escapes keep their existing errors.
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.resolvePath("../outside/secret.txt", rootPath: fixture.root)
        }
        #expect(throws: FolderToolError.self) {
            try FolderToolHelpers.resolvePath(fixture.secret.path, rootPath: fixture.root)
        }
    }

    @Test func resolverKeepsLegitimatePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root

        #expect(try FolderToolHelpers.resolvePath(".", rootPath: root).path == root.standardized.path)
        #expect(
            try FolderToolHelpers.resolvePath("a.txt", rootPath: root).path
                == root.appendingPathComponent("a.txt").path)
        #expect(
            try FolderToolHelpers.resolvePath("sub/new/deep.txt", rootPath: root).path
                == root.appendingPathComponent("sub/new/deep.txt").path)
        // A link that stays inside the folder is fine, as a directory and
        // as the parent of a file that doesn't exist yet.
        _ = try FolderToolHelpers.resolvePath("inner", rootPath: root)
        _ = try FolderToolHelpers.resolvePath("inner/b.txt", rootPath: root)
        _ = try FolderToolHelpers.resolvePath("inner/new.txt", rootPath: root)
        _ = try FolderToolHelpers.resolvePath(root.path + "/sub/b.txt", rootPath: root)

        // The temporary directory lives under the `/var` link; the physical
        // `/private/var` spelling of the root is accepted as well.
        let physicalRoot = try #require(FolderToolHelpers.symlinkResolvedPath(root.path))
        if root.path.hasPrefix("/var/") {
            #expect(physicalRoot == "/private" + root.standardized.path)
        }
        _ = try FolderToolHelpers.resolvePath(physicalRoot + "/a.txt", rootPath: root)
        _ = try FolderToolHelpers.resolvePath(
            root.path + "/sub/b.txt", rootPath: URL(fileURLWithPath: physicalRoot))
        #expect(
            FolderToolHelpers.symlinkResolvedPath(root.appendingPathComponent("inner/b.txt").path)
                == physicalRoot + "/sub/b.txt")
    }

    // MARK: - Reads

    @Test func fileReadRefusesLinkedFolderAndFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = FileReadTool(rootPath: fixture.root)

        for path in Self.escapingPaths {
            await Self.expectRefused(path) {
                try await tool.execute(argumentsJSON: Self.json(["path": path]))
            }
        }
        let inside = try await tool.execute(argumentsJSON: Self.json(["path": "inner/b.txt"]))
        #expect(inside.contains("beta needle"))
    }

    @Test func fileSearchAndTreeStayInsideRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let search = FileSearchTool(rootPath: fixture.root)
        let tree = FileTreeTool(rootPath: fixture.root)

        let whole = try await search.execute(argumentsJSON: Self.json(["pattern": "outside-secret"]))
        #expect(whole.contains("No matches found"))

        // Relative display paths survive the `/var` -> `/private/var` walk.
        let nested = try await search.execute(argumentsJSON: Self.json(["pattern": "needle"]))
        #expect(Self.text(nested).contains("sub/b.txt:1: beta needle"))

        for path in ["dirlink", "hop", "secret-link.txt"] {
            await Self.expectRefused(path) {
                try await search.execute(
                    argumentsJSON: Self.json(["pattern": "secret", "path": path]))
            }
            await Self.expectRefused(path) {
                try await tree.execute(argumentsJSON: Self.json(["path": path]))
            }
        }

        let listing = try await tree.execute(argumentsJSON: Self.json(["max_depth": 5]))
        #expect(listing.contains("dirlink"))
        #expect(!listing.contains("secret.txt"))
    }

    // MARK: - Writes

    @Test func fileWriteRefusesLinkedTargetsAndParents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = FileWriteTool(rootPath: fixture.root)

        for path in Self.escapingPaths {
            await Self.expectRefused(path) {
                try await tool.execute(
                    argumentsJSON: Self.json(["path": path, "content": "overwritten"]))
            }
        }
        fixture.expectOutsideUntouched()

        _ = try await tool.execute(
            argumentsJSON: Self.json(["path": "sub/new/created.txt", "content": "made"]))
        _ = try await tool.execute(
            argumentsJSON: Self.json(["path": "inner/via-link.txt", "content": "made"]))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("sub/new/created.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("sub/via-link.txt").path))
        fixture.expectOutsideUntouched()
    }

    @Test func fileEditRefusesLinkedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = FileEditTool(rootPath: fixture.root)

        for path in ["secret-link.txt", "dirlink/secret.txt", "hop/secret.txt"] {
            await Self.expectRefused(path) {
                try await tool.execute(
                    argumentsJSON: Self.json([
                        "path": path, "old_string": Fixture.secretText, "new_string": "edited",
                    ]))
            }
        }
        fixture.expectOutsideUntouched()
    }

    // MARK: - Git and folder context

    @Test func gitToolsRefuseLinkedPathsAndOptionCommits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let diff = GitDiffTool(rootPath: fixture.root)
        let commit = GitCommitTool(rootPath: fixture.root)

        await Self.expectRefused("dirlink/secret.txt") {
            try await diff.execute(argumentsJSON: Self.json(["path": "dirlink/secret.txt"]))
        }
        await Self.expectRefused("secret-link.txt") {
            try await commit.execute(
                argumentsJSON: Self.json(["message": "m", "files": ["secret-link.txt"]]))
        }

        let written = fixture.outside.appendingPathComponent("diff-output.txt")
        do {
            _ = try await diff.execute(
                argumentsJSON: Self.json(["commit": "--output=\(written.path)"]))
            Issue.record("an option-shaped commit should be refused")
        } catch {
            guard case FolderToolError.invalidArguments = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        fixture.expectOutsideUntouched()
    }

    @Test func folderContextSkipsLinkedContextFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("AGENTS.md"), withDestinationURL: fixture.secret)
        #expect(FolderContextService.readContextFiles(root) == nil)

        try "Project rules".write(
            to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let context = try #require(FolderContextService.readContextFiles(root))
        #expect(context.contains("Project rules"))
        #expect(!context.contains(Fixture.secretText))

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("package.json"), withDestinationURL: fixture.secret)
        #expect(FolderContextService.readManifest(root, projectType: .node) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try "{}".write(
            to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        #expect(FolderContextService.readManifest(root, projectType: .node) == "{}")
    }
}
