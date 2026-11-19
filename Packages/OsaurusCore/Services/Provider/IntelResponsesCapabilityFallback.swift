//
//  IntelResponsesCapabilityFallback.swift
//  OsaurusCore
//
//  Upstream's `RemoteResponsesCapabilityFallback.isUnsupportedEndpoint`
//  (Classic 0.25.x), kept verbatim. Intel does not compile upstream's file (it
//  also carries `ResponsesProviderOptions` validation Intel has no use for).
//

#if OSAURUS_INTEL

import Foundation

/// Protocol negotiation is allowed only for an unmistakably missing endpoint,
/// before a successful stream is accepted. Model/auth/rate and midstream
/// failures are never evidence that a different protocol should be replayed.
enum IntelResponsesCapabilityFallback {
    static func isUnsupportedEndpoint(status: Int, body: Data, endpoint: URL?) -> Bool {
        guard [400, 404, 405, 501].contains(status), endpoint?.path.hasSuffix("/responses") == true else { return false }
        let text = String(decoding: body, as: UTF8.self).lowercased()
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let code = (error?["code"] as? String ?? root?["code"] as? String ?? "").lowercased()
        let parameter = (error?["param"] as? String ?? "").lowercased()
        if parameter == "model" || text.contains("model_not_found") || text.contains("invalid_api_key") { return false }
        if ["unsupported_endpoint", "endpoint_not_found", "route_not_found"].contains(code) { return true }
        return ["cannot post /responses", "cannot post /v1/responses", "unknown endpoint /responses",
            "unknown endpoint: /responses", "unsupported endpoint /responses", "unsupported endpoint: /responses",
            "/responses is not supported", "responses endpoint is not supported", "route /v1/responses not found"]
            .contains { text.contains($0) }
    }
}

#endif
