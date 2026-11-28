//
//  PathSafetyTests.swift
//
//  Containment escape matrix (including symlinks) and atomic write /
//  replace behavior.
//

import XCTest

@testable import OsaurusPluginKit

final class PathSafetyTests: XCTestCase {

    private var base = ""
    private var root = ""
    private var outside = ""

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "pathsafety_\(UUID().uuidString)"
        root = base + "/root"
        outside = base + "/outside"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: base)
        super.tearDown()
    }

    // MARK: - Containment escape matrix

    func testRootItselfIsContained() {
        XCTAssertTrue(PathSafety.isContained(root, in: root))
        XCTAssertTrue(PathSafety.isContained(root + "/", in: root))
    }

    func testDirectChildIsContained() {
        XCTAssertTrue(PathSafety.isContained(root + "/file.txt", in: root))
        XCTAssertTrue(PathSafety.isContained(root + "/a/b/c.txt", in: root))
    }

    func testNonexistentDescendantIsContained() {
        // Component-aware canonicalization must work for paths that do
        // not exist yet (write destinations).
        XCTAssertTrue(PathSafety.isContained(root + "/does/not/exist.bin", in: root))
    }

    func testDotDotEscapeRejected() {
        XCTAssertFalse(PathSafety.isContained(root + "/../outside/x.txt", in: root))
        XCTAssertFalse(PathSafety.isContained(root + "/a/../../outside/x.txt", in: root))
    }

    func testDotDotThatStaysInsideIsContained() {
        XCTAssertTrue(PathSafety.isContained(root + "/a/../b.txt", in: root))
    }

    func testAbsoluteOutsidePathRejected() {
        XCTAssertFalse(PathSafety.isContained("/etc/hosts", in: root))
        XCTAssertFalse(PathSafety.isContained(outside + "/x.txt", in: root))
    }

    func testPrefixSiblingRejected() throws {
        // "/tmp/root-extra" shares the string prefix of "/tmp/root" but is
        // NOT contained — the classic hasPrefix bug.
        let sibling = root + "-extra"
        try FileManager.default.createDirectory(
            atPath: sibling, withIntermediateDirectories: true)
        XCTAssertFalse(PathSafety.isContained(sibling + "/x.txt", in: root))
        XCTAssertFalse(PathSafety.isContained(sibling, in: root))
    }

    func testSymlinkInsideRootPointingOutsideRejected() throws {
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link", withDestinationPath: outside)
        XCTAssertFalse(PathSafety.isContained(root + "/link", in: root))
        // Nonexistent file under the escaping symlink also rejected —
        // symlinks resolve on the deepest existing ancestor.
        XCTAssertFalse(PathSafety.isContained(root + "/link/escape.txt", in: root))
    }

    func testSymlinkInsideRootPointingInsideAccepted() throws {
        try FileManager.default.createDirectory(
            atPath: root + "/real", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/alias", withDestinationPath: root + "/real")
        XCTAssertTrue(PathSafety.isContained(root + "/alias/file.txt", in: root))
    }

    func testSymlinkedRootStillContainsItsChildren() throws {
        // Root reached through a symlink canonicalizes the same as its
        // target, so children remain contained.
        let linkedRoot = base + "/rootlink"
        try FileManager.default.createSymbolicLink(
            atPath: linkedRoot, withDestinationPath: root)
        XCTAssertTrue(PathSafety.isContained(linkedRoot + "/child.txt", in: root))
        XCTAssertTrue(PathSafety.isContained(root + "/child.txt", in: linkedRoot))
    }

    func testTildeExpansion() {
        let home = NSHomeDirectory()
        XCTAssertEqual(PathSafety.canonicalize("~/x.txt"), PathSafety.canonicalize(home + "/x.txt"))
    }

    // MARK: - Atomic write

    func testAtomicWriteCreatesNewFile() throws {
        let path = root + "/new.txt"
        try PathSafety.atomicWrite(data: Data("fresh".utf8), to: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "fresh")
    }

    func testAtomicWriteReplacesExistingFile() throws {
        let path = root + "/existing.txt"
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        try PathSafety.atomicWrite(data: Data("new".utf8), to: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new")
    }

    func testAtomicWriteLeavesNoTempFilesBehind() throws {
        let path = root + "/clean.txt"
        try PathSafety.atomicWrite(data: Data("x".utf8), to: path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temp files left behind: \(leftovers)")
    }

    func testAtomicWriteToMissingDirectoryThrowsAndWritesNothing() {
        let path = root + "/missing-dir/file.txt"
        XCTAssertThrowsError(try PathSafety.atomicWrite(data: Data("x".utf8), to: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAtomicWriteOverDirectoryFailsAndPreservesDirectory() throws {
        let dir = root + "/precious"
        let inner = dir + "/keep.txt"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: inner))

        XCTAssertThrowsError(try PathSafety.atomicWrite(data: Data("clobber".utf8), to: dir))

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(try String(contentsOfFile: inner, encoding: .utf8), "keep me")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "failed write must clean up its temp file")
    }

    // MARK: - Atomic replace

    func testAtomicReplaceOverExistingFile() throws {
        let destination = root + "/dest.txt"
        let source = root + "/staged.txt"
        try Data("old".utf8).write(to: URL(fileURLWithPath: destination))
        try Data("new".utf8).write(to: URL(fileURLWithPath: source))

        try PathSafety.atomicReplace(at: destination, withItemAt: source)

        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "new")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: source), "source is consumed on success")
    }

    func testAtomicReplaceIntoNewDestination() throws {
        let destination = root + "/brand-new.txt"
        let source = root + "/staged2.txt"
        try Data("payload".utf8).write(to: URL(fileURLWithPath: source))

        try PathSafety.atomicReplace(at: destination, withItemAt: source)

        XCTAssertEqual(try String(contentsOfFile: destination, encoding: .utf8), "payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source))
    }
}
