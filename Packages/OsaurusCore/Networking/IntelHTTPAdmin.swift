//
//  IntelHTTPAdmin.swift
//  osaurus
//
//  Upstream's runtime admin routes (`W-server-api` stage 7,
//  docs/SERVER_API_INTEL.md):
//
//  - `GET /admin/cache-stats` — upstream reports the on-device (vmlx)
//    engine's caches, memory plan and batch scheduler, plus the
//    storage-location audit. Intel answers upstream's shape in its cold
//    state (no loaded models, zero counters, no batch engine) with the
//    parts that apply here: the context policy and the storage audit.
//  - `GET /admin/generation-settings` — the last settings submitted to the
//    on-device engine; always empty here.
//  - `GET` / `PUT /admin/runtime-settings` — the vMLX runtime settings
//    (memory safety, caches, batch limits). MLX only
//    (`ServerRuntimeSettingsStore` is excluded), so 501.
//
//  Who may call: what the gate lets through. Loopback callers and master
//  keys; agent-scoped keys never reach `/admin/*` (the stage 1 gate).
//  `/admin/config/*` is `W-declarative-config`, `/admin/import/*`
//  `W-osaurus-bundles`.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {
    func routeAdminRequest(context: ChannelHandlerContext, head: HTTPRequestHead, path: String) -> Bool {
        switch (head.method, path) {
        case (.GET, "/admin/cache-stats"):
            sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: Self.cacheStatsBody())
        case (.GET, "/admin/generation-settings"):
            sendResponse(context: context, status: .ok, headers: jsonHeaders(), body: Self.generationSettingsBody())
        case (.GET, "/admin/runtime-settings"), (.PUT, "/admin/runtime-settings"):
            sendResponse(
                context: context, status: .notImplemented, headers: jsonHeaders(),
                body: Self.errorBody(
                    .openai(type: "invalid_request_error"),
                    message: "Runtime settings are for the on-device MLX engine, which needs an Apple Silicon Mac."))
        default:
            return false
        }
        return true
    }

    /// Upstream's aggregate counters, all zero: no on-device engine.
    static let coldCacheAggregate: [String: Int] = [
        "prefix_hits": 0,
        "prefix_misses": 0,
        "paged_hits": 0,
        "paged_misses": 0,
        "disk_l2_hits": 0,
        "disk_l2_misses": 0,
        "disk_l2_stores": 0,
        "companion_hits": 0,
        "companion_misses": 0,
        "companion_rederives": 0,
        "ssm_companion_hits": 0,
        "ssm_companion_misses": 0,
        "ssm_companion_rederives": 0,
        "zaya_cca_disk_payload_hits": 0,
        "zaya_cca_disk_payload_misses": 0,
        "zaya_cca_disk_payload_stores": 0,
    ]

    static func cacheStatsBody(storageReport: StorageLocationStandards.Report = StorageLocationStandards.currentReport())
        -> String
    {
        let metadataFallbackTokens = ChatConfigurationStore.load().contextLength
        let obj: [String: Any] = [
            "status": "ok",
            "timestamp": Date().ISO8601Format(),
            "models": [] as [Any],
            "aggregate": coldCacheAggregate,
            // The vmlx memory plan; no on-device engine here.
            "memory_safety": NSNull(),
            "context_policy": [
                "metadata_fallback_tokens": metadataFallbackTokens as Any? ?? NSNull(),
                "conversation_safety_margin": ContextBudgetManager.safetyMargin,
                "saved_kv_retention_override_tokens": NSNull(),
                "resolved_kv_retention_tokens": NSNull(),
            ] as [String: Any],
            "storage_locations": StorageLocationStandards.jsonObject(for: storageReport),
            // Upstream lists on-device generations in flight; cloud
            // requests show in Insights instead.
            "inference_activity": [] as [Any],
            "batch_diagnostics": NSNull(),
        ]
        let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
        return data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func generationSettingsBody() -> String {
        let obj: [String: Any] = [
            "status": "ok",
            "timestamp": Date().ISO8601Format(),
            "source":
                "last effective settings resolved by Osaurus; stage indicates whether they are pending preload or submitted to vmlx BatchEngine",
            "models": [] as [Any],
            "generation_defaults_by_model": [:] as [String: Any],
            "last_effective_generation_by_model": [:] as [String: Any],
        ]
        let data = try? JSONSerialization.data(withJSONObject: obj, options: .osaurusCanonical)
        return data.flatMap { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
