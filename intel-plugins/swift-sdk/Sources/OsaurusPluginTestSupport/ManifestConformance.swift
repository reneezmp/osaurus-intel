//
//  ManifestConformance.swift
//  OsaurusPluginTestSupport
//
//  Registry-conformance checks a plugin's test suite runs against its own
//  manifest JSON (the string `get_manifest` returns).
//

import Foundation

public enum ManifestConformance {

    /// Returns every conformance violation found in `manifestJSON`; an
    /// empty array means the manifest is conformant. Checks:
    ///
    /// - parses as a JSON object
    /// - `plugin_id` present, lowercase, dot-separated (>= 2 components)
    /// - `version` present and semver
    /// - tool ids unique and non-empty
    /// - every tool has a non-empty `description` and a `parameters` object
    public static func violations(inManifest manifestJSON: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(manifestJSON.utf8)),
            let manifest = object as? [String: Any]
        else {
            return ["manifest does not parse as a JSON object"]
        }

        var violations: [String] = []
        violations.append(contentsOf: pluginIdViolations(manifest))
        violations.append(contentsOf: versionViolations(manifest))
        violations.append(contentsOf: toolViolations(manifest))
        return violations
    }

    /// Throws a `ConformanceError` listing every violation. Call from a
    /// plugin's tests: `try ManifestConformance.assertConformant(json)`.
    public static func assertConformant(_ manifestJSON: String) throws {
        let found = violations(inManifest: manifestJSON)
        guard found.isEmpty else {
            throw ConformanceError(
                "manifest is not conformant:\n- " + found.joined(separator: "\n- "))
        }
    }

    // MARK: - plugin_id

    private static func pluginIdViolations(_ manifest: [String: Any]) -> [String] {
        guard let pluginId = manifest["plugin_id"] as? String, !pluginId.isEmpty else {
            return ["plugin_id is missing or not a non-empty string"]
        }
        let components = pluginId.components(separatedBy: ".")
        let componentPattern = "^[a-z0-9][a-z0-9_-]*$"
        let allValid = components.allSatisfy {
            $0.range(of: componentPattern, options: .regularExpression) != nil
        }
        if components.count < 2 || !allValid {
            return [
                "plugin_id '\(pluginId)' must be lowercase dot-separated (e.g. 'osaurus.maps')"
            ]
        }
        return []
    }

    // MARK: - version

    private static func versionViolations(_ manifest: [String: Any]) -> [String] {
        guard let version = manifest["version"] as? String, !version.isEmpty else {
            return ["version is missing or not a non-empty string"]
        }
        let semver =
            #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#
        if version.range(of: semver, options: .regularExpression) == nil {
            return ["version '\(version)' is not semver (expected MAJOR.MINOR.PATCH)"]
        }
        return []
    }

    // MARK: - tools

    /// Tools may live under `capabilities.tools` (current convention) or
    /// top-level `tools` (older manifests). A manifest with no tools array
    /// is fine — route-only plugins exist.
    static func toolsArray(_ manifest: [String: Any]) -> [Any]? {
        if let capabilities = manifest["capabilities"] as? [String: Any],
            let tools = capabilities["tools"] as? [Any]
        {
            return tools
        }
        return manifest["tools"] as? [Any]
    }

    private static func toolViolations(_ manifest: [String: Any]) -> [String] {
        guard let tools = toolsArray(manifest) else { return [] }

        var violations: [String] = []
        var seenIds = Set<String>()
        for (index, entry) in tools.enumerated() {
            guard let tool = entry as? [String: Any] else {
                violations.append("tool at index \(index) is not a JSON object")
                continue
            }

            let label: String
            if let id = tool["id"] as? String,
                !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                label = "tool '\(id)'"
                if !seenIds.insert(id).inserted {
                    violations.append("duplicate tool id '\(id)'")
                }
            } else {
                label = "tool at index \(index)"
                violations.append("\(label) is missing a non-empty id")
            }

            if (tool["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            {
                violations.append("\(label) is missing a non-empty description")
            }
            if !(tool["parameters"] is [String: Any]) {
                violations.append("\(label) is missing a parameters object")
            }
        }
        return violations
    }
}
