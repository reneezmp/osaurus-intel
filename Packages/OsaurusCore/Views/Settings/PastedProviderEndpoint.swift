//
//  PastedProviderEndpoint.swift
//  osaurus
//
//  Intel (2026-10-27): upstream keeps these helpers at the top of
//  `RemoteProviderEditSheet.swift`; Intel's sheet is older and lacks them,
//  and onboarding's custom-provider dialog needs the parser
//  (`CustomProviderForm.parse`). Move them back into the sheet when it is
//  ported (`W-providers-ux`).
//

import Foundation

// MARK: - Pasted URL Detection

/// Endpoint components recovered from a full URL pasted into a host field,
/// so users can paste e.g. "https://api.example.com:8443/v1" and have the
/// protocol, host, port, and base path fields filled in automatically.
struct PastedEndpointComponents {
    var providerProtocol: RemoteProviderProtocol?
    var host: String
    var port: Int?
    var basePath: String?
}

/// Only restructure input that was pasted (multi-character change) or that
/// carries an explicit scheme; never mangle text the user is typing out
/// character by character.
func shouldSplitHostInput(previous: String, value: String) -> Bool {
    value.contains("://") || (value.count - previous.count > 1 && (value.contains("/") || value.contains(":")))
}

/// Parses host-field input that looks like a full URL. Returns nil when the
/// text is already a bare host so callers leave their state untouched.
func parsePastedEndpoint(_ text: String) -> PastedEndpointComponents? {
    var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !remainder.isEmpty else { return nil }

    var providerProtocol: RemoteProviderProtocol?
    if let schemeRange = remainder.range(of: "://") {
        switch remainder[..<schemeRange.lowerBound].lowercased() {
        case "https": providerProtocol = .https
        case "http": providerProtocol = .http
        default: break  // Unknown scheme: still salvage host/port/path below.
        }
        remainder = String(remainder[schemeRange.upperBound...])
    }

    // Plain host input has nothing to split apart.
    guard providerProtocol != nil || remainder.contains("/") || remainder.contains(":") else { return nil }

    // Drop query string and fragment.
    if let cutoff = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) {
        remainder = String(remainder[..<cutoff])
    }

    var basePath: String?
    if let slash = remainder.firstIndex(of: "/") {
        var path = String(remainder[slash...])
        remainder = String(remainder[..<slash])
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        basePath = normalizedPastedProviderBasePath(from: path)
    }

    var port: Int?
    if let colon = remainder.lastIndex(of: ":"),
        // Don't treat colons inside an IPv6 literal ("[::1]") as a port separator.
        remainder.lastIndex(of: "]").map({ colon > $0 }) ?? true
    {
        port = Int(remainder[remainder.index(after: colon)...])
        remainder = String(remainder[..<colon])
    }

    let host = remainder.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { return nil }
    return PastedEndpointComponents(providerProtocol: providerProtocol, host: host, port: port, basePath: basePath)
}

private func normalizedPastedProviderBasePath(from path: String) -> String? {
    guard path != "/" else { return nil }

    let operationSuffixes = [
        "/chat/completions",
        "/responses",
        "/messages",
        "/models",
    ]
    for suffix in operationSuffixes where path == suffix || path.hasSuffix(suffix) {
        let base = String(path.dropLast(suffix.count))
        return base.isEmpty ? "" : base
    }

    return path
}
