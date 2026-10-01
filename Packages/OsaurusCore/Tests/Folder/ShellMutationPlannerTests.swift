//
//  ShellMutationPlannerTests.swift
//
//  Pins the conservative `shell_run` target planner used when the folder is
//  too large for a full scan: simple `mv`/`cp`/`rm`/`mkdir` forms name
//  exactly the paths they touch; anything the parser can't represent
//  faithfully (compound commands, globs, quoting, escapes from the root,
//  unknown programs) is nil so the call is treated as untrackable instead
//  of snapshotting the wrong paths; plain read-only commands are empty.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ShellMutationPlannerTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func readOnlyCommandsTouchNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in ["ls -la", "cat a.txt", "echo mv a b", "grep -n x f.txt"] {
            #expect(ShellMutationPlanner.targets(command: command, rootPath: root) == [], "\(command)")
        }
    }

    @Test func unknownProgramsAreUntrackable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // `find -delete`, `tree -o`, `env cmd` can all write: never "nothing".
        for command in ["swift test", "git checkout .", "python3 build.py", "ls > out.txt", "find . -name x -delete", "tree -o out.txt", "env rm -rf a"] {
            #expect(ShellMutationPlanner.targets(command: command, rootPath: root) == nil, "\(command)")
        }
    }

    @Test func simpleMoveNamesBothEnds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ShellMutationPlanner.targets(command: "mv a.txt b.txt", rootPath: root) == ["a.txt", "b.txt"])
    }

    @Test func moveIntoExistingDirectoryResolvesLandingPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dest"), withIntermediateDirectories: true)
        #expect(
            ShellMutationPlanner.targets(command: "mv a.txt dest", rootPath: root)
                == ["a.txt", "dest/a.txt"])
    }

    @Test func removeAndRecursiveRemoveNameTheirPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ShellMutationPlanner.targets(command: "rm a.txt b.txt", rootPath: root) == ["a.txt", "b.txt"])
        // Recursive removal is safe to plan: the journal snapshots the subtree.
        #expect(ShellMutationPlanner.targets(command: "rm -rf build", rootPath: root) == ["build"])
    }

    @Test func compoundGlobAndQuotedFormsAreUntrackable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in [
            "mv a b && rm c", "rm *.txt", "mv 'a b' c", "rm a; rm b", "cp a b | tee x", "rm -i a",
        ] {
            #expect(ShellMutationPlanner.targets(command: command, rootPath: root) == nil, "\(command)")
        }
    }

    @Test func pathEscapingRootIsUntrackable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ShellMutationPlanner.targets(command: "rm ../outside.txt", rootPath: root) == nil)
        #expect(ShellMutationPlanner.targets(command: "rm /etc/hosts", rootPath: root) == nil)
        #expect(ShellMutationPlanner.targets(command: "rm -rf .", rootPath: root) == nil)
    }

    @Test func mkdirNamesItsPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ShellMutationPlanner.targets(command: "mkdir -p a/b", rootPath: root) == ["a/b"])
    }
}

// Intel: upstream's `AgentTaskStateExecInvalidationTests` live in this file
// too; `AgentTaskState` (the agent loop's read-replay cache) is not on Intel.
