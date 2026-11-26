//
//  HarnessTestSupport.swift
//  osaurusTests
//
//  Fixtures for the harness suites. Tests here never launch a real external
//  process (Claude Code, Pi): they use temporary folders and in-memory fakes.
//

import Foundation

@testable import OsaurusCore

enum HarnessFixtures {
    static func temporaryDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: realPath(dir.path), isDirectory: true)
    }

    /// `/var/…` → `/private/var/…`.
    static func realPath(_ path: String) -> String {
        path.withCString { pointer -> String? in
            guard let real = realpath(pointer, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
        } ?? path
    }
}
