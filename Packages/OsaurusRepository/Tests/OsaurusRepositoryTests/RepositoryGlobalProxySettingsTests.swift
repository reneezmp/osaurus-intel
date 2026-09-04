//
//  RepositoryGlobalProxySettingsTests.swift
//  OsaurusRepository
//
//  Regression coverage for `RepositoryGlobalProxySettings.currentConfiguration()`:
//  it must apply the same validation as `OsaurusNetworking.GlobalProxyConfiguration`
//  (credentials-in-URL rejection, unsafe/local-host rejection, port range) rather
//  than the hand-rolled CFNetwork dictionary this reader used to build.
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class RepositoryGlobalProxySettingsTests: XCTestCase {
    private var tempRoot: URL!
    private var previousOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        previousOverride = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = tempRoot
    }

    override func tearDownWithError() throws {
        ToolsPaths.overrideRoot = previousOverride
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeServerConfig(globalProxyURL: String?) throws {
        let configDir = tempRoot.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let file = configDir.appendingPathComponent("server.json", isDirectory: false)
        var object: [String: Any] = [:]
        if let globalProxyURL {
            object["globalProxyURL"] = globalProxyURL
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: file)
    }

    // MARK: - Tests

    func testValidProxyURLProducesConfiguration() throws {
        try writeServerConfig(globalProxyURL: "http://proxy.example.com:8080")
        let configuration = RepositoryGlobalProxySettings.currentConfiguration()
        XCTAssertNotNil(configuration)
        XCTAssertEqual(configuration?.host, "proxy.example.com")
        XCTAssertEqual(configuration?.port, 8080)
    }

    func testMissingGlobalProxyURLReturnsNil() throws {
        try writeServerConfig(globalProxyURL: nil)
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }

    func testEmptyGlobalProxyURLReturnsNil() throws {
        try writeServerConfig(globalProxyURL: "   ")
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }

    func testNoServerConfigFileReturnsNil() {
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }

    func testLocalHostProxyIsRejected() throws {
        // This is the actual behavior change: the old hand-rolled dictionary
        // builder had no local/link-local host check and would have honored this.
        try writeServerConfig(globalProxyURL: "http://127.0.0.1:8080")
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }

    func testCredentialsInURLAreRejected() throws {
        // Also new: the old builder had no credentials-in-URL check.
        try writeServerConfig(globalProxyURL: "http://user:pass@proxy.example.com:8080")
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }

    func testOutOfRangePortIsRejected() throws {
        try writeServerConfig(globalProxyURL: "http://proxy.example.com:70000")
        XCTAssertNil(RepositoryGlobalProxySettings.currentConfiguration())
    }
}
