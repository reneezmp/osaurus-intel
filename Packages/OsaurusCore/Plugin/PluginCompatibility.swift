//
//  PluginCompatibility.swift
//  OsaurusCore
//
//  M9: Plugin compatibility checker — gates dlopen on capability satisfaction.
//

import Foundation

/// Result of checking a plugin's declared capabilities against the host.
public enum PluginCompatibility: Equatable, Sendable {
    /// All required capabilities are available. Load normally.
    case compatible
    /// One or more REQUIRED capabilities are missing. Do NOT load.
    case incompatible(missingRequired: [String])
    /// One or more OPTIONAL capabilities are missing. Load, but flag as degraded.
    case degraded(missingOptional: [String])
}

/// Stateless checker that compares a PluginManifest's capability declarations
/// against the host's supported set.
public enum PluginCompatibilityChecker {
    /// Evaluates whether the plugin represented by `manifest` can be loaded
    /// on the current host, and whether any optional capabilities are missing.
    ///
    /// Plugins that declare NO capabilities (nil or empty arrays for both
    /// required and optional) are treated as `.compatible` — the optimistic
    /// backwards-compatible default.
    public static func check(required: [String]?, optional: [String]?) -> PluginCompatibility {
        let supported = OsaurusHostCapabilities.supported

        let requiredSet = Set(required ?? [])
        let missingRequired = requiredSet.subtracting(supported)

        if !missingRequired.isEmpty {
            return .incompatible(missingRequired: Array(missingRequired).sorted())
        }

        let optionalSet = Set(optional ?? [])
        let missingOptional = optionalSet.subtracting(supported)

        if !missingOptional.isEmpty {
            return .degraded(missingOptional: Array(missingOptional).sorted())
        }

        return .compatible
    }
}
