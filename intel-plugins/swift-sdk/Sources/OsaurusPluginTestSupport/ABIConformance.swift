//
//  ABIConformance.swift
//  OsaurusPluginTestSupport
//
//  Checks a plugin's entry-point result against the ABI contract: the
//  five required v1 callbacks must all be populated, and (for v2+
//  plugins) capabilities declared in the manifest must have their
//  callbacks wired.
//

import Foundation
import OsaurusPluginABI

public enum ABIConformance {

    /// Asserts against the raw pointer returned by
    /// `osaurus_plugin_entry` / `osaurus_plugin_entry_v2`.
    ///
    /// Pass the plugin's manifest JSON to additionally verify that
    /// declared capabilities (currently: routes) have their optional
    /// callbacks populated.
    public static func assertEntryConformance(
        _ entryResult: UnsafeRawPointer?,
        manifestJSON: String? = nil
    ) throws {
        guard let entryResult else {
            throw ConformanceError("entry point returned NULL instead of an osr_plugin_api*")
        }
        let api = entryResult.assumingMemoryBound(to: OsrPluginAPI.self).pointee
        try assertPluginAPIConformance(api, manifestJSON: manifestJSON)
    }

    /// Same checks against an already-typed `OsrPluginAPI` value.
    public static func assertPluginAPIConformance(
        _ api: OsrPluginAPI,
        manifestJSON: String? = nil
    ) throws {
        var missing: [String] = []
        if api.free_string == nil { missing.append("free_string") }
        if api.`init` == nil { missing.append("init") }
        if api.destroy == nil { missing.append("destroy") }
        if api.get_manifest == nil { missing.append("get_manifest") }
        if api.invoke == nil { missing.append("invoke") }
        guard missing.isEmpty else {
            throw ConformanceError(
                "required v1 callbacks are NULL: \(missing.joined(separator: ", "))")
        }

        guard api.version >= OsrABIVersion.v2, let manifestJSON else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(manifestJSON.utf8)),
            let manifest = object as? [String: Any]
        else {
            throw ConformanceError("manifest does not parse as a JSON object")
        }

        if let capabilities = manifest["capabilities"] as? [String: Any],
            let routes = capabilities["routes"] as? [Any],
            !routes.isEmpty,
            api.handle_route == nil
        {
            throw ConformanceError(
                "manifest declares \(routes.count) route(s) but handle_route is NULL")
        }
    }
}
