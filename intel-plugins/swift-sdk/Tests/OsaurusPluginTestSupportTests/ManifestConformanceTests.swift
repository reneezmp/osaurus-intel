//
//  ManifestConformanceTests.swift
//

import XCTest

@testable import OsaurusPluginTestSupport

final class ManifestConformanceTests: XCTestCase {

    private let validManifest = """
        {
          "plugin_id": "osaurus.example",
          "name": "Example",
          "version": "1.2.3",
          "capabilities": {
            "tools": [
              {
                "id": "example_do_thing",
                "description": "Does the thing",
                "parameters": {"type": "object", "properties": {}}
              },
              {
                "id": "example_other",
                "description": "Other thing",
                "parameters": {"type": "object", "properties": {}}
              }
            ]
          }
        }
        """

    func testValidManifestPasses() throws {
        XCTAssertEqual(ManifestConformance.violations(inManifest: validManifest), [])
        try ManifestConformance.assertConformant(validManifest)
    }

    func testMalformedJSONFails() {
        let violations = ManifestConformance.violations(inManifest: "{not json")
        XCTAssertEqual(violations, ["manifest does not parse as a JSON object"])
    }

    func testNonObjectRootFails() {
        XCTAssertFalse(ManifestConformance.violations(inManifest: "[1,2]").isEmpty)
    }

    func testMissingPluginIdFails() {
        let violations = ManifestConformance.violations(
            inManifest: #"{"version": "1.0.0"}"#)
        XCTAssertTrue(violations.contains { $0.contains("plugin_id") })
    }

    func testPluginIdShapeMatrix() {
        // (plugin_id, isValid)
        let cases: [(String, Bool)] = [
            ("osaurus.maps", true),
            ("osaurus.macos_use", true),
            ("com.dinoki.osaurus-tools", true),
            ("a.b.c", true),
            ("Osaurus.Maps", false),  // uppercase
            ("osaurus", false),  // no dot
            ("osaurus.", false),  // empty component
            (".maps", false),
            ("osaurus..maps", false),
            ("osaurus maps", false),  // space
        ]
        for (pluginId, isValid) in cases {
            let json = #"{"plugin_id": "\#(pluginId)", "version": "1.0.0"}"#
            let violations = ManifestConformance.violations(inManifest: json)
                .filter { $0.contains("plugin_id") }
            if isValid {
                XCTAssertTrue(violations.isEmpty, "'\(pluginId)' should be valid: \(violations)")
            } else {
                XCTAssertFalse(violations.isEmpty, "'\(pluginId)' should be rejected")
            }
        }
    }

    func testMissingVersionFails() {
        let violations = ManifestConformance.violations(
            inManifest: #"{"plugin_id": "osaurus.example"}"#)
        XCTAssertTrue(violations.contains { $0.contains("version") })
    }

    func testVersionSemverMatrix() {
        let cases: [(String, Bool)] = [
            ("1.0.0", true),
            ("0.5.12", true),
            ("2.0.0-beta.1", true),
            ("1.0.0+build.7", true),
            ("1.0", false),
            ("1", false),
            ("v1.0.0", false),
            ("1.0.0.0", false),
            ("01.0.0", false),
        ]
        for (version, isValid) in cases {
            let json = #"{"plugin_id": "osaurus.example", "version": "\#(version)"}"#
            let violations = ManifestConformance.violations(inManifest: json)
                .filter { $0.contains("version") }
            if isValid {
                XCTAssertTrue(violations.isEmpty, "'\(version)' should be valid: \(violations)")
            } else {
                XCTAssertFalse(violations.isEmpty, "'\(version)' should be rejected")
            }
        }
    }

    func testDuplicateToolIdsFail() {
        let json = """
            {
              "plugin_id": "osaurus.example", "version": "1.0.0",
              "capabilities": {"tools": [
                {"id": "dup", "description": "a", "parameters": {}},
                {"id": "dup", "description": "b", "parameters": {}}
              ]}
            }
            """
        let violations = ManifestConformance.violations(inManifest: json)
        XCTAssertTrue(violations.contains { $0.contains("duplicate tool id 'dup'") })
    }

    func testEmptyToolIdFails() {
        let json = """
            {
              "plugin_id": "osaurus.example", "version": "1.0.0",
              "capabilities": {"tools": [
                {"id": "  ", "description": "a", "parameters": {}}
              ]}
            }
            """
        let violations = ManifestConformance.violations(inManifest: json)
        XCTAssertTrue(violations.contains { $0.contains("missing a non-empty id") })
    }

    func testToolMissingDescriptionFails() {
        let json = """
            {
              "plugin_id": "osaurus.example", "version": "1.0.0",
              "capabilities": {"tools": [
                {"id": "t1", "parameters": {}}
              ]}
            }
            """
        let violations = ManifestConformance.violations(inManifest: json)
        XCTAssertTrue(violations.contains { $0.contains("missing a non-empty description") })
    }

    func testToolMissingParametersFails() {
        let json = """
            {
              "plugin_id": "osaurus.example", "version": "1.0.0",
              "capabilities": {"tools": [
                {"id": "t1", "description": "does stuff"}
              ]}
            }
            """
        let violations = ManifestConformance.violations(inManifest: json)
        XCTAssertTrue(violations.contains { $0.contains("missing a parameters object") })
    }

    func testTopLevelToolsArrayIsAlsoChecked() {
        let json = """
            {
              "plugin_id": "osaurus.example", "version": "1.0.0",
              "tools": [{"id": "t1", "description": "d"}]
            }
            """
        let violations = ManifestConformance.violations(inManifest: json)
        XCTAssertTrue(violations.contains { $0.contains("missing a parameters object") })
    }

    func testManifestWithoutToolsIsAllowed() {
        // Route-only plugins have no tools array.
        let json = #"{"plugin_id": "osaurus.webhooks", "version": "1.0.0"}"#
        XCTAssertEqual(ManifestConformance.violations(inManifest: json), [])
    }

    func testAssertConformantThrowsWithAllViolationsListed() {
        let json = #"{"plugin_id": "BAD", "version": "nope"}"#
        XCTAssertThrowsError(try ManifestConformance.assertConformant(json)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("plugin_id"))
            XCTAssertTrue(message.contains("version"))
        }
    }
}
