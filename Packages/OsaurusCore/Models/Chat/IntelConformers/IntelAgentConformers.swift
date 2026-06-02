//
//  IntelAgentConformers.swift
//  OsaurusCore
//
//  Intel fork — conformer surfaces for the AgentsView restoration
//  (M11 Phase 11.A.4). AgentDetailView is the front-end for the entire
//  agent-database subsystem (per-agent SQLite, schedules, watchers,
//  pinned facts, episodes, dynamic tools, relay/Bonjour, agent bundles,
//  per-agent voice). Almost all of that is amputated on Intel, so these
//  stubs exist to let the upstream view tree compile + render, with the
//  amputated sub-features falling through to `AppleSiliconOnlyTab`
//  placeholders.
//
//  Created in M11 Phase 11.A.4.0. The companion un-body-swap of
//  AgentsView lands in 11.A.4.1.
//

#if OSAURUS_INTEL

import AppKit
import Foundation
import SwiftUI

// MARK: - Notification surface

extension Notification.Name {
    /// Posted by the deeplink router to focus a specific agent's detail
    /// view. Amputated on Intel (no deeplink routing for agents yet),
    /// but the name must exist for the observer in AgentsView.
    static let agentDetailDeeplink = Notification.Name("agentDetailDeeplink")
    /// Posted by TTSService when a voice model needs configuring. The
    /// AgentDetailView voice section observes it to route the user to
    /// TTS settings (amputated on Intel, but the name must resolve).
    static let openTTSSettingsRequested = Notification.Name("openTTSSettingsRequested")
    /// Posted by the (amputated) ScheduleManager when schedules change.
    static let schedulesChanged = Notification.Name("schedulesChanged")
    /// Posted by the (amputated) WatcherManager when watchers change.
    static let watchersChanged = Notification.Name("watchersChanged")
    /// Posted when an MCP provider connects/disconnects. ToolsManagerView
    /// observes it; amputated on Intel, but the name must resolve.
    static let mcpProviderStatusChanged = Notification.Name("mcpProviderStatusChanged")
}

// MARK: - SemanticVersion + RegistryCapabilities (Intel stubs — M11 11.B.2)
//
// Both live inside the excluded `PluginRepositoryService.swift` upstream.
// `PluginState` (the Plugins-tab row model) reads them. Plugin install/
// update is amputated on Intel, so versions are nil and capabilities
// empty — these exist only so the full `PluginState` shape compiles.
public struct SemanticVersion: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(major: Int = 0, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    public static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }

    /// Parse "X.Y.Z" (also tolerates a leading "v"). Used by the
    /// WhatsNew gate + plugin registry. Returns nil on malformed input.
    public static func parse(_ string: String) -> SemanticVersion? {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0) }
        guard parts.count >= 1, parts.allSatisfy({ $0 != nil }) else { return nil }
        let nums = parts.map { $0! }
        return SemanticVersion(
            major: nums.count > 0 ? nums[0] : 0,
            minor: nums.count > 1 ? nums[1] : 0,
            patch: nums.count > 2 ? nums[2] : 0
        )
    }
}

public struct RegistryCapabilities: Sendable, Equatable {
    public struct ToolSummary: Sendable, Equatable {
        public let name: String
        public let description: String
        public init(name: String, description: String = "") {
            self.name = name
            self.description = description
        }
    }
    public struct SkillSummary: Sendable, Equatable {
        public let name: String
        public let description: String
        public init(name: String, description: String = "") {
            self.name = name
            self.description = description
        }
    }
    public let tools: [ToolSummary]?
    public let skills: [SkillSummary]?
    public init(tools: [ToolSummary]? = nil, skills: [SkillSummary]? = nil) {
        self.tools = tools
        self.skills = skills
    }
}

// MARK: - MCP Provider Manager (Intel stub)
//
// `ToolsManagerView` reads `providerManager.configuration.providers`
// + `.providerStates` + `.disconnect(providerId:)`. MCP *providers*
// (the config model) are available on Intel
// (`Models/Configuration/MCPProviderConfiguration.swift`), but the
// manager runtime is amputated, so the configured list stays empty.
@MainActor
final class MCPProviderManager: ObservableObject, @unchecked Sendable {
    static let shared = MCPProviderManager()
    @Published private(set) var configuration = MCPProviderConfiguration()
    @Published private(set) var providerStates: [UUID: MCPProviderState] = [:]
    private init() {}
    func disconnect(providerId: UUID) {}
}

// MARK: - Sandbox Plugin Library (Intel stub)
//
// `ToolsManagerView` lists `pluginLibrary.plugins` + calls `.save(_:)`.
// Sandbox plugins (the model) are available (un-excluded), but the
// library runtime is amputated, so the list stays empty.
@MainActor
final class SandboxPluginLibrary: ObservableObject, @unchecked Sendable {
    static let shared = SandboxPluginLibrary()
    @Published private(set) var plugins: [SandboxPlugin] = []
    private init() {}
    func save(_ plugin: SandboxPlugin) {}
    func update(oldId: String, plugin: SandboxPlugin) {}
    func delete(id: String) {}
    @discardableResult
    func importFromFile(_ url: URL) throws -> SandboxPlugin {
        throw NSError(
            domain: "SandboxPluginLibrary",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Sandbox plugin import is unavailable on Intel."]
        )
    }
    func exportData(for pluginId: String) -> Data? { nil }
}

extension SandboxPlugin {
    /// An empty plugin for the "Create Plugin" editor. Upstream has
    /// this; Intel provides it so `SandboxPluginEditorView(plugin: .blank())`
    /// type-checks (the editor itself is the AppleSiliconOnly placeholder).
    static func blank() -> SandboxPlugin {
        SandboxPlugin(name: "", description: "")
    }
}

// MARK: - Agent delete result

/// Mirrors upstream `AgentDeleteResult` (Managers/AgentManager.swift).
/// The Intel `AgentManager.delete(id:)` returns this so the view's
/// `result.deleted` check type-checks.
public struct AgentDeleteResult: Sendable {
    public let deleted: Bool
    public let sandboxCleanupNotice: SandboxCleanupNotice?

    public init(deleted: Bool, sandboxCleanupNotice: SandboxCleanupNotice? = nil) {
        self.deleted = deleted
        self.sandboxCleanupNotice = sandboxCleanupNotice
    }
}

/// Sandbox cleanup is amputated on Intel; the notice type exists only
/// so the delete-result surface compiles.
public struct SandboxCleanupNotice: Sendable {
    public let title: String
    public let message: String
    public init(title: String = "Sandbox Cleanup", message: String = "") {
        self.title = title
        self.message = message
    }
}

// MARK: - Relay status

/// Per-agent relay tunnel status. Relay is amputated on Intel; the type
/// exists for the relay section's bindings.
public enum AgentRelayStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(String)
    case error(String)
}

// MARK: - Agent bundle

/// Agent bundle import/export is amputated on Intel. Minimal manifest
/// surface for the share/import flows (which render placeholders).
public struct AgentBundleManifest: Sendable {
    public let name: String
    public let agentName: String
    public let agentDescription: String
    public let schemaTables: Int
    public let savedViews: Int
    public let exportedAt: Date
    public init(
        name: String = "",
        agentName: String = "",
        agentDescription: String = "",
        schemaTables: Int = 0,
        savedViews: Int = 0,
        exportedAt: Date = Date()
    ) {
        self.name = name
        self.agentName = agentName
        self.agentDescription = agentDescription
        self.schemaTables = schemaTables
        self.savedViews = savedViews
        self.exportedAt = exportedAt
    }
}

// MARK: - Relay Tunnel Manager (Intel stub)

@MainActor
final class RelayTunnelManager: ObservableObject, @unchecked Sendable {
    static let shared = RelayTunnelManager()
    @Published var agentStatuses: [UUID: AgentRelayStatus] = [:]
    private init() {}
    func status(for agentId: UUID) -> AgentRelayStatus { .disconnected }
    func isTunnelEnabled(for agentId: UUID) -> Bool { false }
    func enable(for agentId: UUID) async throws {}
    func disable(for agentId: UUID) {}
    func baseURL(for agentId: UUID) -> URL? { nil }
    /// Sync no-op (relay is amputated). Upstream is async; the Intel
    /// call sites invoke it from non-async alert-button closures, so
    /// the Intel surface is synchronous + non-throwing.
    func setTunnelEnabled(_ enabled: Bool, for agentId: UUID) {}
}

// MARK: - Schedule Manager (Intel stub)

@MainActor
final class ScheduleManager: ObservableObject, @unchecked Sendable {
    static let shared = ScheduleManager()
    @Published private(set) var schedules: [Schedule] = []
    private init() {}
    func refresh() {}
    func schedules(for agentId: UUID) -> [Schedule] { [] }
    func scheduleCount(forAgentId agentId: UUID) -> Int { 0 }
    @discardableResult
    func create(
        name: String,
        instructions: String,
        agentId: UUID?,
        frequency: ScheduleFrequency,
        isEnabled: Bool
    ) -> Schedule? { nil }
    func update(_ schedule: Schedule) {}
    func delete(id: UUID) {}
    func setEnabled(_ enabled: Bool, for id: UUID) {}
}

// MARK: - Watcher Manager (Intel stub)

@MainActor
final class WatcherManager: ObservableObject, @unchecked Sendable {
    static let shared = WatcherManager()
    @Published private(set) var watchers: [Watcher] = []
    private init() {}
    func refresh() {}
    func watchers(for agentId: UUID) -> [Watcher] { [] }
    func watcherCount(forAgentId agentId: UUID) -> Int { 0 }
    /// Whether a watcher is actively firing. Always false on Intel
    /// (the file-watch runtime is amputated).
    func isRunning(_ id: UUID) -> Bool { false }
    /// Manually trigger a watcher run. No-op on Intel.
    func runNow(_ id: UUID) {}
    @discardableResult
    func create(
        name: String,
        instructions: String,
        agentId: UUID?,
        parameters: [String: String] = [:],
        watchPath: String?,
        watchBookmark: Data?,
        isEnabled: Bool,
        recursive: Bool,
        responsiveness: Responsiveness
    ) -> Watcher? { nil }
    func update(_ watcher: Watcher) {}
    func delete(id: UUID) {}
    func setEnabled(_ id: UUID, enabled: Bool) {}
}

// MARK: - Remote Agent Manager (Intel stub)

@MainActor
final class RemoteAgentManager: ObservableObject, @unchecked Sendable {
    static let shared = RemoteAgentManager()
    @Published private(set) var remoteAgents: [RemoteAgent] = []
    private init() {}
    func refresh() {}
    func remoteAgent(id: UUID) -> RemoteAgent? { nil }
    @discardableResult
    func remove(id: UUID) -> Bool { false }
}

// MARK: - Agent Bundle Service (Intel stub)

final class AgentBundleService: @unchecked Sendable {
    static let shared = AgentBundleService()
    private init() {}

    struct ImportPreview: Sendable {
        let name: String
        let displayName: String
        let manifest: AgentBundleManifest
        init(
            name: String = "",
            displayName: String = "",
            manifest: AgentBundleManifest = AgentBundleManifest()
        ) {
            self.name = name
            self.displayName = displayName
            self.manifest = manifest
        }
    }

    // Bundle import/export is amputated on Intel. These throw / no-op
    // so the share-agent flow's buttons compile; the share sheet
    // itself renders the AppleSiliconOnlyTab placeholder.
    struct BundleExportResult: Sendable {
        let bundleURL: URL
    }

    func exportBundle(
        agentId: UUID,
        passphrase: String,
        destinationDirectory: URL
    ) async throws -> BundleExportResult {
        throw NSError(
            domain: "AgentBundleService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Agent bundle export is unavailable on Intel."]
        )
    }
    func openBundleForReview(url: URL, passphrase: String) async throws -> ImportPreview {
        ImportPreview()
    }
    @discardableResult
    func activate(preview: ImportPreview) async throws -> ImportPreview { preview }
    func discard(preview: ImportPreview) {}
}

// MARK: - Agent Database Store (Intel stub)

final class AgentDatabaseStore: @unchecked Sendable {
    static let shared = AgentDatabaseStore()
    private init() {}
    func deleteOnDisk(for agentId: UUID) {}
}

// MARK: - Agent Secrets Keychain (Intel stub)

enum AgentSecretsKeychain {
    static func getAllSecrets(agentId: UUID) -> [String: String] { [:] }
    static func saveSecret(_ value: String, id: String, agentId: UUID) {}
    static func deleteSecret(id: String, agentId: UUID) {}
}

// MARK: - Agent Store (Intel stub)

enum AgentStore {
    static func save(_ agent: Agent) {}
    static func delete(id: UUID) -> Bool { false }
    static func loadAll() -> [Agent] { [] }
}

// MARK: - Bonjour Advertiser (Intel stub)

enum BonjourAdvertiser {
    static let serviceType = "_osaurus._tcp"
}

// MARK: - Chat History Database (Intel stub)

final class ChatHistoryDatabase: @unchecked Sendable {
    static let shared = ChatHistoryDatabase()
    private init() {}
    /// Per-session turn counts for an agent's history list. Empty on
    /// Intel (chat history persistence is session-scoped in-memory).
    func turnCounts(forAgent agentId: UUID?) -> [UUID: Int] { [:] }
}

// MARK: - Scheduler Database (Intel stub)

final class SchedulerDatabase: @unchecked Sendable {
    static let shared = SchedulerDatabase()
    private init() {}
    func deleteAllForAgent(_ agentId: UUID) {}
}

// MARK: - Local Agent Bridge (Intel stub)

final class LocalAgentBridge: @unchecked Sendable {
    static let shared = LocalAgentBridge()
    private init() {}
    func forget(agentId: UUID) {}
}

// MARK: - Pocket TTS Voice Catalog (Intel stub)

enum PocketTTSVoiceCatalog {
    static let availableVoices: [String] = []
    static func displayName(for voiceId: String) -> String { voiceId }
}

// MARK: - JSONValue (mirrored from excluded OpenAIAPI.swift)
//
// `JSONValue` is the recursive JSON value type the upstream tool-spec
// machinery uses. It lives in `Models/API/OpenAIAPI.swift` (excluded
// on Intel). `SandboxPlugin` + `ToolRegistry.ToolEntry` (un-excluded /
// extended in M11 Phase 11.B.2) need it. Mirrored byte-for-byte rather
// than un-excluding the whole OpenAI API model graph.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

extension JSONValue {
    var sendableValue: any Sendable {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.sendableValue }
        case .object(let obj):
            var dict: [String: any Sendable] = [:]
            for (k, v) in obj {
                if case .null = v { continue }
                dict[k] = v.sendableValue
            }
            return dict
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.anyValue }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = v.anyValue }
            return dict
        }
    }
}

// MARK: - Foundation Model Service (Intel stub)
//
// ServerView's API-reference example-model picker asks whether the
// Apple Foundation local model is available. It never is on Intel
// (local inference is amputated), so this returns false and the
// example falls back to a cloud model id.
enum FoundationModelService {
    static func isDefaultModelAvailable() -> Bool { false }
}

// MARK: - Agent sub-view placeholders
//
// Every agent-detail tab/sub-view below backs onto an amputated
// subsystem. They render the standard `AppleSiliconOnlyTab` placeholder
// but carry the exact init signatures the upstream AgentDetailView call
// sites use so the un-body-swapped view type-checks.

struct HomeTabView: View {
    let agentId: UUID
    init(agentId: UUID) { self.agentId = agentId }
    var body: some View { AppleSiliconOnlyTab(tabName: "Home", symbol: "house") }
}

struct DataTabView: View {
    let agentId: UUID
    let initialSelectedTable: String?
    init(agentId: UUID, initialSelectedTable: String? = nil) {
        self.agentId = agentId
        self.initialSelectedTable = initialSelectedTable
    }
    var body: some View { AppleSiliconOnlyTab(tabName: "Data", symbol: "cylinder") }
}

struct ActivityTabView: View {
    let agentId: UUID
    init(agentId: UUID) { self.agentId = agentId }
    var body: some View { AppleSiliconOnlyTab(tabName: "Activity", symbol: "waveform.path.ecg") }
}

struct ViewsTabView: View {
    let agentId: UUID
    let initialFocusedViewName: String?
    init(agentId: UUID, initialFocusedViewName: String? = nil) {
        self.agentId = agentId
        self.initialFocusedViewName = initialFocusedViewName
    }
    var body: some View { AppleSiliconOnlyTab(tabName: "Views", symbol: "tablecells") }
}

struct PinnedFactsPanel: View {
    let facts: [PinnedFact]
    let onDelete: (String) -> Void
    init(facts: [PinnedFact], onDelete: @escaping (String) -> Void) {
        self.facts = facts
        self.onDelete = onDelete
    }
    var body: some View { AppleSiliconOnlyTab(tabName: "Pinned Facts", symbol: "pin") }
}

struct EpisodeRow: View {
    let episode: Episode
    init(episode: Episode) { self.episode = episode }
    var body: some View { AppleSiliconOnlyTab(tabName: "Episode", symbol: "clock.arrow.circlepath") }
}

struct ScheduleEditorSheet: View {
    enum Mode { case create; case edit(Schedule) }
    let mode: Mode
    let onSave: (Schedule) -> Void
    let onCancel: () -> Void
    let initialAgentId: UUID?
    init(
        mode: Mode,
        onSave: @escaping (Schedule) -> Void,
        onCancel: @escaping () -> Void,
        initialAgentId: UUID? = nil
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        self.initialAgentId = initialAgentId
    }
    var body: some View {
        AppleSiliconOnlyTab(tabName: "Schedule Editor", symbol: "calendar.badge.clock")
            .frame(minWidth: 480, minHeight: 360)
    }
}

// NOTE: `WatcherEditorSheet` is defined by `WatchersView.swift` (Group B,
// un-body-swapped in M11 Phase 11.B.1) — its real upstream view, not a
// stub. Removed the duplicate that used to live here to avoid a
// redeclaration clash. `ScheduleEditorSheet` stays below because
// `SchedulesView` is Group C (still body-swapped), so nothing else
// provides it.

struct RemoteAgentDetailView: View {
    let remoteId: UUID
    let onBack: () -> Void
    let onRemoved: () -> Void
    let onChat: (RemoteAgent) -> Void
    init(
        remoteId: UUID,
        onBack: @escaping () -> Void,
        onRemoved: @escaping () -> Void,
        onChat: @escaping (RemoteAgent) -> Void
    ) {
        self.remoteId = remoteId
        self.onBack = onBack
        self.onRemoved = onRemoved
        self.onChat = onChat
    }
    var body: some View { AppleSiliconOnlyTab(tabName: "Remote Agent", symbol: "antenna.radiowaves.left.and.right") }
}

// NOTE: `RemoteAgentCard` (Views/Agent/RemoteAgentViews.swift) and
// `ShareAgentSheet` (Views/Agent/ShareAgentSheet.swift) already have
// their own Intel `#else` stubs — extended in place (in those files)
// with the init signatures AgentsView's call sites use — rather than
// duplicated here.

#endif
