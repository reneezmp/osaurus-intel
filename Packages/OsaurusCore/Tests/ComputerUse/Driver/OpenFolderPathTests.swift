//
//  OpenFolderPathTests.swift
//  OsaurusCoreTests — Computer Use
//
//  `open` accepts a folder path and opens it in a new front Finder window,
//  replacing sidebar/icon navigation that failed with several Finder windows
//  open. Only real, non-package directories resolve: a file would launch its
//  default app (and a script would run), and app names keep their old path.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
final class OpenFolderPathTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func absoluteDirectoryResolves() {
        let url = openableFolderURL(forOpenIdentifier: tempDir.path)
        #expect(url?.standardizedFileURL.path == tempDir.standardizedFileURL.path)
    }

    @Test func fileURLDirectoryResolves() {
        #expect(openableFolderURL(forOpenIdentifier: tempDir.absoluteString) != nil)
    }

    @Test func tildePathResolvesToHome() {
        let url = openableFolderURL(forOpenIdentifier: "~")
        #expect(url?.standardizedFileURL.path == (NSHomeDirectory() as NSString).standardizingPath)
    }

    @Test func fileIsNotOpenedAsFolder() throws {
        let script = tempDir.appendingPathComponent("run.command")
        try "echo hi".write(to: script, atomically: true, encoding: .utf8)
        #expect(openableFolderURL(forOpenIdentifier: script.path) == nil)
    }

    @Test func appNamesAndMissingPathsDoNotResolve() {
        #expect(openableFolderURL(forOpenIdentifier: "Finder") == nil)
        #expect(openableFolderURL(forOpenIdentifier: "com.apple.finder") == nil)
        #expect(openableFolderURL(forOpenIdentifier: tempDir.appendingPathComponent("missing").path) == nil)
    }
}
