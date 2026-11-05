//
//  IntelPluginHostSafetyTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2a (docs/UPSTREAM_SYNC.md, "Plugin host
//  safety"): Intel's plugin host now answers `http_request` and `file_read`
//  with upstream's `PluginHostContext`. Upstream's `SSRFTighteningTests`
//  and `PluginHttpRateLimitTests` pin the checks themselves; these pin what
//  changed for Intel plugins:
//
//    * `file_read` takes upstream's `{"path"}` request (Intel's took a bare
//      path) and only reads inside the artifacts folder;
//    * `http_request` refuses private addresses and spent quotas before any
//      network traffic;
//    * Intel's own callbacks read the same thread-local scope as upstream's.
//
//  No test touches the network. Files live under a temporary root set
//  through `OsaurusPaths.overrideRoot` inside `StoragePathsTestLock`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct IntelPluginHostSafetyTests {

    private func makeContext() throws -> PluginHostContext {
        try PluginHostContext(pluginId: "com.test.intel.hostsafety.\(UUID().uuidString)")
    }

    private func object(_ json: String) -> [String: Any] {
        PluginHostContext.parseJSON(json) ?? [:]
    }

    private static func withTempRoot(_ body: @escaping @Sendable (URL) throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-plugin-host-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = nil
                try? FileManager.default.removeItem(at: root)
            }
            #expect(OsaurusPaths.artifactsDir().path.hasPrefix(root.path))
            try body(root)
        }
    }

    // MARK: - file_read

    @Test func fileRead_readsArtifacts_withUpstreamsReply() async throws {
        try await Self.withTempRoot { _ in
            let ctx = try makeContext()
            defer { ctx.teardown() }
            let folder = OsaurusPaths.contextArtifactsDir(contextId: "ctx-1")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: file)

            let reply = object(ctx.fileRead(requestJSON: PluginHostContext.jsonString(["path": file.path])))
            #expect(reply["data"] as? String == Data("hello".utf8).base64EncodedString())
            #expect(reply["size"] as? Int == 5)
            #expect(reply["mime_type"] as? String == "text/plain")
            #expect(reply["error"] == nil)
        }
    }

    @Test func fileRead_refusesPathsOutsideArtifacts() async throws {
        try await Self.withTempRoot { root in
            let ctx = try makeContext()
            defer { ctx.teardown() }
            let secret = root.appendingPathComponent("secret.txt")
            try Data("no".utf8).write(to: secret)
            let escaping = OsaurusPaths.artifactsDir().path + "/../secret.txt"

            for path in [secret.path, escaping, "/etc/hosts"] {
                let reply = object(ctx.fileRead(requestJSON: PluginHostContext.jsonString(["path": path])))
                #expect(reply["error"] as? String == "access_denied", "\(path)")
                #expect(reply["data"] == nil)
            }
        }
    }

    /// Intel's old callback took a bare path. Upstream's contract is JSON, so
    /// a bare path is now an invalid request rather than a read.
    @Test func fileRead_barePathIsAnInvalidRequest() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        let reply = object(ctx.fileRead(requestJSON: "/etc/hosts"))
        #expect(reply["error"] as? String == "invalid_request")
    }

    // MARK: - http_request

    @Test func httpRequest_blocksPrivateAddressesBeforeConnecting() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for url in ["http://127.0.0.1:1/", "http://localhost/", "http://192.168.1.1/", "http://[::1]/"] {
            let reply = object(ctx.httpRequest(requestJSON: PluginHostContext.jsonString(["method": "GET", "url": url])))
            #expect(reply["error"] as? String == "ssrf_blocked", "\(url)")
        }
    }

    /// Plugin calls without a chat agent share one anonymous bucket (never the
    /// Default agent's). A spent bucket answers before any request is made.
    @Test func httpRequest_spentQuotaAnswersRateLimitExceeded() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        for _ in 0 ..< PluginHostContext.httpRateLimit {
            _ = ctx.checkHttpRateLimit(agentId: PluginHostContext.anonymousPluginRateBucketId)
        }
        let request = PluginHostContext.jsonString(["method": "GET", "url": "https://example.invalid/"])
        let reply = object(ctx.httpRequest(requestJSON: request))
        #expect(reply["error"] as? String == "rate_limit_exceeded")
        #expect(reply["retry_after_ms"] as? Int == 60_000)
    }

    @Test func httpRequest_missingFieldsIsAnInvalidRequest() throws {
        let ctx = try makeContext()
        defer { ctx.teardown() }
        let reply = object(ctx.httpRequest(requestJSON: #"{"url":"https://example.com"}"#))
        #expect(reply["error"] as? String == "invalid_request")
    }

    // MARK: - Trampolines and scope

    /// The C trampoline resolves the plugin from the thread-local scope that
    /// `ExternalPlugin.invoke` sets.
    @Test func trampoline_resolvesTheScopedPlugin() throws {
        let ctx = try makeContext()
        PluginHostContext.setContext(ctx, for: ctx.pluginId)
        defer { ctx.teardown() }
        #expect(PluginHostContext.getContext(for: ctx.pluginId) === ctx)

        let reply: String? = PluginHostContext.withTLSScope(pluginId: ctx.pluginId, agentId: nil) {
            let request = PluginHostContext.jsonString(["method": "GET", "url": "http://10.0.0.1/"])
            return request.withCString { pointer -> String? in
                guard let result = PluginHostContext.trampolineHttpRequest(pointer) else { return nil }
                defer { free(UnsafeMutableRawPointer(mutating: result)) }
                return String(cString: result)
            }
        }
        #expect(object(reply ?? "")["error"] as? String == "ssrf_blocked")

        ctx.teardown()
        #expect(PluginHostContext.getContext(for: ctx.pluginId) == nil)
    }

    /// Since stage 2e every slot of the host table is upstream's, config
    /// included: `config_set` / `config_get` through the table land in the
    /// scoped agent's namespace, and an anonymous call reads nothing.
    @Test func configThroughTheTable_usesTheScopedAgent() throws {
        let ctx = try makeContext()
        PluginHostContext.setContext(ctx, for: ctx.pluginId)
        defer {
            ctx.teardown()
            ToolSecretsKeychain.deleteAllSecretsAllAgents(for: ctx.pluginId)
        }
        let api = ctx.buildHostAPI().pointee
        let agent = UUID()

        func get(_ agentId: UUID?) -> String? {
            PluginHostContext.withTLSScope(pluginId: ctx.pluginId, agentId: agentId) {
                "token".withCString { key -> String? in
                    guard let result = api.config_get?(key) else { return nil }
                    defer { api.free_string?(result) }
                    return String(cString: result)
                }
            }
        }
        PluginHostContext.withTLSScope(pluginId: ctx.pluginId, agentId: agent) {
            "token".withCString { key in "abc".withCString { value in api.config_set?(key, value) } }
        }
        #expect(get(agent) == "abc")
        #expect(get(nil) == nil)
        #expect(ToolSecretsKeychain.getSecret(id: "token", for: ctx.pluginId, agentId: agent) == "abc")
    }
}
