//
//  IntelPluginTaskEventTests.swift
//  OsaurusCoreTests
//
//  `W-plugin-reliability` stage 2c (docs/UPSTREAM_SYNC.md, "Plugin
//  dispatch and task events"). Upstream's `PluginHostAPITests` and
//  `PluginDispatchToolSelectionTests` pin dispatch planning, the
//  serializers and the trampolines. These pin the Intel half:
//
//    * a loaded plugin's `notifyTaskEvent` reaches its `on_task_event`, in
//      order, with the task's agent in scope, and stops after shutdown
//      (since stage 2e the loaded plugin is upstream's `ExternalPlugin`);
//    * the host table hands plugins upstream's task-control callbacks
//      instead of Intel's old no-ops and empty lists;
//    * dispatch without a chat agent is refused; a plugin's dispatch
//      allowed set holds its own tools, and an unloaded plugin's is
//      built-ins only.
//
//  No dylib is loaded: the plugin table is built in the test, the way
//  `PluginLoaderAbiValidationTests` does.
//

import Darwin
import Foundation
import Testing

@testable import OsaurusCore

/// What the fake plugin's `on_task_event` saw. `@convention(c)` callbacks
/// can't capture, so they write here.
private final class TaskEventRecorder: @unchecked Sendable {
    static let shared = TaskEventRecorder()
    private let lock = NSLock()
    private var _events: [(taskId: String, type: Int32, json: String, agent: UUID?)] = []

    func record(taskId: String, type: Int32, json: String) {
        lock.withLock {
            _events.append((taskId, type, json, PluginHostContext.activeAgentId()))
        }
    }

    func events(for taskId: String) -> [(type: Int32, json: String, agent: UUID?)] {
        lock.withLock { _events.filter { $0.taskId == taskId }.map { ($0.type, $0.json, $0.agent) } }
    }
}

@Suite(.serialized)
struct IntelPluginTaskEventTests {

    private func manifest(pluginId: String, tools: [PluginManifest.ToolSpec]? = nil) -> PluginManifest {
        PluginManifest(
            plugin_id: pluginId,
            description: nil,
            capabilities: .init(tools: tools, routes: nil, config: nil, web: nil, artifact_handler: nil),
            instructions: nil,
            name: "Events",
            version: nil,
            license: nil,
            authors: nil,
            min_macos: nil,
            min_osaurus: nil,
            secrets: nil,
            docs: nil
        )
    }

    private func makePlugin(pluginId: String, tools: [PluginManifest.ToolSpec]? = nil) throws -> ExternalPlugin {
        let api = osr_plugin_api(
            free_string: { _ in },
            init: { nil },
            destroy: { _ in },
            get_manifest: { _ in nil },
            invoke: { _, _, _, _ in nil },
            version: 2,
            handle_route: nil,
            on_config_changed: nil,
            on_task_event: { _, taskId, type, json in
                TaskEventRecorder.shared.record(
                    taskId: taskId.map { String(cString: $0) } ?? "",
                    type: type,
                    json: json.map { String(cString: $0) } ?? "")
            }
        )
        let handle = try #require(dlopen(nil, RTLD_NOW))
        return ExternalPlugin(
            handle: handle,
            api: api,
            ctx: UnsafeMutableRawPointer(bitPattern: 0x1)!,
            manifest: manifest(pluginId: pluginId, tools: tools),
            path: "/tmp/\(pluginId).dylib",
            abiVersion: 2
        )
    }

    @Test func eventsReachOnTaskEvent_inOrder_withTheTaskAgent() async throws {
        let plugin = try makePlugin(pluginId: "com.test.events.\(UUID().uuidString)")
        #expect(plugin.hasTaskEventHandler)

        let taskId = UUID().uuidString
        let agent = UUID()
        plugin.notifyTaskEvent(
            taskId: taskId, eventType: .started, eventJSON: #"{"status":"running"}"#, agentId: agent)
        plugin.notifyTaskEvent(
            taskId: taskId, eventType: .activity, eventJSON: #"{"kind":"tool"}"#, agentId: agent)
        plugin.notifyTaskEvent(
            taskId: taskId, eventType: .completed, eventJSON: #"{"success":true}"#, agentId: agent)
        plugin.drainEventQueuesForTesting()

        let events = TaskEventRecorder.shared.events(for: taskId)
        #expect(events.map(\.type) == [0, 1, 4])
        #expect(events.first?.json == #"{"status":"running"}"#)
        #expect(events.allSatisfy { $0.agent == agent }, "the task's agent is in scope inside on_task_event")
        #expect(PluginHostContext.activeAgentId() == nil, "and cleared afterwards")
        await plugin.shutdown()
    }

    @Test func noEventsAfterShutdown() async throws {
        let plugin = try makePlugin(pluginId: "com.test.events.down.\(UUID().uuidString)")
        await plugin.shutdown()
        let taskId = UUID().uuidString
        plugin.notifyTaskEvent(taskId: taskId, eventType: .cancelled, eventJSON: "{}", agentId: nil)
        plugin.drainEventQueuesForTesting()
        #expect(TaskEventRecorder.shared.events(for: taskId).isEmpty)
    }

    /// Intel's table used to hand plugins no-ops and empty lists for these.
    @Test func hostTableCarriesUpstreamsTaskControl() throws {
        let ctx = try PluginHostContext(pluginId: "com.test.table.\(UUID().uuidString)")
        defer { ctx.teardown() }
        let api = ctx.buildHostAPI().pointee
        #expect(api.version == 6)
        #expect(api.dispatch != nil && api.task_status != nil && api.list_active_tasks != nil)
        #expect(api.dispatch_cancel != nil && api.dispatch_interrupt != nil && api.send_draft != nil)
        #expect(api.get_active_agent_id != nil && api.dispatch_add_issue != nil)
        #expect(api.db_exec != nil && api.http_request != nil && api.file_read != nil)

        // Through the table, as a plugin calls it.
        PluginHostContext.setContext(ctx, for: ctx.pluginId)
        let reply: String? = PluginHostContext.withTLSScope(pluginId: ctx.pluginId, agentId: nil) {
            guard let result = api.list_active_tasks?() else { return nil }
            defer { free(UnsafeMutableRawPointer(mutating: result)) }
            return String(cString: result)
        }
        #expect(reply == #"{"tasks":[]}"#)
    }

    /// Plugin dispatch from a chat runs as that chat's agent; without one it
    /// is refused, as upstream does.
    @Test func dispatchWithoutAnAgentIsRefused() throws {
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi"}"#, pluginId: "com.test.plan", activeAgent: nil)
        guard case .error(let envelope) = plan else {
            Issue.record("expected a refusal")
            return
        }
        #expect(envelope.contains("error"))
    }

    @MainActor
    @Test func dispatchAllowedSetIncludesThePluginsOwnTools() async throws {
        let pluginId = "com.test.allowed.\(UUID().uuidString)"
        #expect(
            !PluginHostContext.dispatchToolAllowedSet(pluginId: pluginId).contains("\(pluginId).tool"),
            "an unknown plugin gets built-ins only")

        let spec = PluginManifest.ToolSpec(
            id: "\(pluginId).tool", description: "t", parameters: nil, requirements: nil, permission_policy: nil)
        let plugin = try makePlugin(pluginId: pluginId, tools: [spec])
        let handle = try #require(dlopen(nil, RTLD_NOW))
        PluginManager.shared.injectLoadedPluginForTesting(
            PluginManager.LoadedPlugin(
                plugin: plugin,
                handle: handle,
                tools: [ExternalTool(plugin: plugin, spec: spec)],
                skills: [],
                routes: [],
                webConfig: nil,
                readmePath: nil,
                changelogPath: nil
            ))
        defer { PluginManager.shared.removeLoadedPluginForTesting(pluginId: pluginId) }
        #expect(PluginHostContext.dispatchToolAllowedSet(pluginId: pluginId).contains("\(pluginId).tool"))
    }
}
