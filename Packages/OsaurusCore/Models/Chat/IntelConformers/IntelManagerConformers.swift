//
//  IntelManagerConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel-lite manager conformers — concretized.
//  All types use concrete types, no protocol existentials.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import Foundation

// MARK: - AgentManager

final class AgentManager: ObservableObject, @unchecked Sendable {
    static let shared = AgentManager()

    private var defaultModel = "deepseek-v4-pro"

    struct AgentInfo: Identifiable, Sendable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool = true
        let autoSpeak: Bool? = false
        var ttsVoice: String? { nil }
    }

    @Published var activeAgentId: UUID = Agent.defaultId
    // Real agent list: the built-in Default first, then any custom
    // agents persisted as JSON under `OsaurusPaths.agents()`. M11 Phase
    // 11.A.4 click-through (Renée 2026-06-02) found that creating an
    // agent didn't surface a card because `add` was a no-op and this
    // array was a single throwaway. Now backed by real on-disk
    // persistence (same pattern as SlashCommandStore / SkillStore).
    @Published var agents: [Agent] = [Agent.default]

    private static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        reload()
    }

    /// Re-read custom agents from disk and rebuild `agents` (Default
    /// always pinned first). Triggers the `@Published` so the grid +
    /// pickers refresh.
    func reload() {
        let dir = OsaurusPaths.agents()
        OsaurusPaths.ensureExistsSilent(dir)
        var custom: [Agent] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) {
            for url in files where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                    let agent = try? Self.isoDecoder.decode(Agent.self, from: data)
                {
                    custom.append(agent)
                }
            }
        }
        custom.sort { $0.createdAt < $1.createdAt }
        agents = [Agent.default] + custom
    }

    private func persist(_ agent: Agent) {
        guard agent.id != Agent.defaultId else { return }  // Default is built-in, never written
        let dir = OsaurusPaths.agents()
        OsaurusPaths.ensureExistsSilent(dir)
        let url = dir.appendingPathComponent("\(agent.id.uuidString).json")
        if let data = try? Self.iso.encode(agent) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func agent(for id: UUID) -> Agent? {
        agents.first { $0.id == id }
    }

    func agent(byAddress address: String) -> Agent? {
        agents.first { $0.agentAddress == address }
    }

    func resolveAgentId(_ identifier: String) -> UUID? {
        if let uuid = UUID(uuidString: identifier) { return uuid }
        return agents.first { $0.name == identifier }?.id
    }

    func agentsList() -> [Agent] { agents }

    func refresh() { reload() }

    func setActiveAgent(_ id: UUID) { activeAgentId = id }

    func add(_ agent: Agent) {
        persist(agent)
        reload()
    }

    func update(_ agent: Agent) {
        if agent.id == Agent.defaultId {
            // The Default agent is built-in and not persisted; reflect
            // the edit in-memory so the editor's bindings stay live for
            // the session.
            if let idx = agents.firstIndex(where: { $0.id == Agent.defaultId }) {
                agents[idx] = agent
            }
            return
        }
        persist(agent)
        reload()
    }

    func delete(id: UUID) async -> AgentDeleteResult {
        // The Default agent is mandatory and cannot be deleted (matches
        // upstream). Return `deleted: false` so the UI keeps the card.
        guard id != Agent.defaultId else {
            return AgentDeleteResult(deleted: false)
        }
        let url = OsaurusPaths.agents().appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        if activeAgentId == id { activeAgentId = Agent.defaultId }
        reload()
        return AgentDeleteResult(deleted: true)
    }

    // Per-agent custom avatar. Avatars are amputated on Intel (no
    // sandbox-side image processing pipeline), so these are no-ops; the
    // view's `customAvatarURL` reads stay nil. Surface kept so the
    // AgentDetailView avatar section (un-body-swapped in M11 Phase
    // 11.A.4) type-checks.
    func setCustomAvatar(_ data: Data, ext: String, for agentId: UUID) {}
    func clearCustomAvatar(for agentId: UUID) {}

    func updateDefaultModel(for agentId: UUID, model: String?) {
        if agentId == activeAgentId, let model { defaultModel = model }
    }

    func effectiveModel(for agentId: UUID) -> String? { defaultModel }
    func effectiveTemperature(for agentId: UUID) -> Double? { nil }
    func effectiveMaxTokens(for agentId: UUID) -> Int? { nil }
    func effectiveSystemPrompt(for agentId: UUID) -> String { "" }
    func effectiveToolsDisabled(for agentId: UUID) -> Bool { false }
    func effectiveDBEnabled(for agentId: UUID) -> Bool { false }
    func effectiveMemoryDisabled(for agentId: UUID) -> Bool { true }
    func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode? { nil }
    func effectiveEnabledToolNames(for agentId: UUID) -> [String]? { nil }
    func effectiveEnabledSkillNames(for agentId: UUID) -> [String]? { nil }
    // AgentDetailView's sandbox section reads/writes
    // `AutonomousExecConfig` (the real type from Models/Agent/Agent.swift,
    // NOT excluded on Intel) — not the lightweight protocol
    // `AgentAutoExecInfo`. The protocol overloads below are kept for the
    // chat-side callers that use them; the view-facing overloads use
    // `AutonomousExecConfig`. Sandbox is amputated on Intel so both are
    // effectively inert (return `.default`, write no-ops).
    /// AgentDetailView's sandbox section reads/writes the real
    /// `AutonomousExecConfig` (Models/Agent/Agent.swift, NOT excluded),
    /// so `effectiveAutonomousExec` returns that type here. Sandbox is
    /// amputated on Intel → always `.default` (disabled), write no-ops.
    func effectiveAutonomousExec(for agentId: UUID) -> AutonomousExecConfig? { .default }
    func updateAutonomousExec(_ config: AutonomousExecConfig, for agentId: UUID) async throws {}
    func ttsVoice(for agentId: UUID) -> Any? { nil }
    func themeId(for agentId: UUID) -> UUID? { nil }
}

// MARK: - ModelPickerItemCache

// `ConfigurationView`'s CoreModel picker (un-body-swapped in M11
// Phase 11.A.3.1, gated visually to AppleSiliconOnlyOverlay)
// observes `$items`, which requires `ObservableObject` + `@Published`
// surface. Mirrored here. The cache stays Intel-functional for
// `FloatingInputCard`'s model selector — that's where the DeepSeek
// rows actually surface, and the Configuration picker is gated.
final class ModelPickerItemCache: ObservableObject, @unchecked Sendable {
    static let shared = ModelPickerItemCache()

    /// Stable synthetic UUID for the built-in DeepSeek provider. The Intel
    /// build's `RemoteProviderManager` doesn't configure user-facing
    /// providers (the API key is read from `DEEPSEEK_API_KEY` and the URL
    /// is hard-coded in `CloudChatEngine`), but `ModelPickerItem.Source`
    /// still wants a UUID and `ChatView`'s `source.remoteProviderId`
    /// filter still compares against it — so we pin a stable value here.
    static let deepSeekProviderId = UUID(uuidString: "00000000-0000-0000-0000-DEEDEEDEEDEE")!

    var isLoaded: Bool = false
    @Published private(set) var items: [ModelPickerItem] = []

    func buildModelPickerItems() async -> [ModelPickerItem] {
        let provider: ModelPickerItem.Source = .remote(
            providerName: "DeepSeek",
            providerId: Self.deepSeekProviderId
        )
        let built: [ModelPickerItem] = [
            ModelPickerItem(
                id: "deepseek-v4-pro",
                displayName: "DeepSeek V4 Pro",
                source: provider,
                isVLM: false,
                description: "DeepSeek's flagship chat model"
            ),
            ModelPickerItem(
                id: "deepseek-v4-flash",
                displayName: "DeepSeek V4 Flash",
                source: provider,
                isVLM: false,
                description: "DeepSeek's fast tier"
            ),
        ]
        items = built
        isLoaded = true
        return built
    }

    func prewarm() { Task { await buildModelPickerItems() } }
    func prewarmModelCache() async { _ = await buildModelPickerItems() }
    func invalidateCache() { isLoaded = false }
}

// MARK: - ChatSessionData

struct ChatSessionData: Identifiable, @unchecked Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    let agentId: UUID
    var source: SessionSource
    var sourcePluginId: String?
    var externalSessionKey: String?
    var dispatchTaskId: UUID?
    var archived: Bool
    var selectedModel: String?
    var turns: [ChatTurnData]
    var capabilities: Set<SessionCapability> = []

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModel: String? = nil,
        turns: [ChatTurnData] = [],
        agentId: UUID? = nil,
        source: SessionSource = .chat,
        sourcePluginId: String? = nil,
        externalSessionKey: String? = nil,
        dispatchTaskId: UUID? = nil,
        archived: Bool = false,
        capabilities: Set<SessionCapability> = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.agentId = agentId ?? UUID()
        self.archived = archived
        self.selectedModel = selectedModel
        self.turns = turns
        self.source = source
        self.sourcePluginId = sourcePluginId
        self.externalSessionKey = externalSessionKey
        self.dispatchTaskId = dispatchTaskId
        self.capabilities = capabilities
    }

    static func generateTitle(from turnData: [ChatTurnData]) -> String { "Chat" }
}

// MARK: - ChatSessionsManager

final class ChatSessionsManager: ObservableObject, @unchecked Sendable {
    static let shared = ChatSessionsManager()
    /// `@Published` so `ChatWindowState.observeSessionsManager()` can subscribe
    /// via `$sessions` and refresh the sidebar when a turn lands during an
    /// active stream — without this, the sidebar only updates on explicit
    /// user actions (e.g., clicking "New Chat"). Renamed-from-private to
    /// `internal` so observers can read it.
    @Published var sessions: [UUID: ChatSessionData] = [:]

    func save(_ data: ChatSessionData) { sessions[data.id] = data }
    func delete(id: UUID) { sessions.removeValue(forKey: id) }
    func rename(id: UUID, title: String) {
        if var s = sessions[id] {
            s.title = title
            sessions[id] = s
        }
    }
    func setArchived(id: UUID, archived: Bool) {
        if var s = sessions[id] {
            s.archived = archived
            sessions[id] = s
        }
    }
    func refresh() {}

    func createNew(selectedModel: String? = nil, agentId: UUID? = nil) -> UUID {
        let id = UUID()
        sessions[id] = ChatSessionData(id: id, agentId: agentId ?? UUID())
        return id
    }

    func sessions(for agentId: UUID?) -> [ChatSessionData] {
        Array(sessions.values).sorted { $0.updatedAt > $1.updatedAt }
    }
    func session(for id: UUID) -> ChatSessionData? { sessions[id] }
}

// MARK: - Hotkey (Intel stub)
//
// Upstream `Hotkey` is defined inside the excluded
// `Models/Chat/ChatConfiguration.swift`. Mirror the public surface
// byte-for-byte so `ConfigurationView`'s chat-hotkey picker row
// (un-body-swapped in M11 Phase 11.A.3.1) type-checks. The Intel
// build doesn't currently register a global hotkey through
// `HotKeyManager` (excluded), but the field is still wired through
// the config so persistence survives the round-trip.
public struct Hotkey: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let displayString: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString
    }
}

// MARK: - PreflightSearchMode (Intel stub)
//
// Upstream `PreflightSearchMode` lives in the excluded
// `Services/Context/PreflightCapabilitySearch.swift`. The view binds
// the `.balanced` case and presents the four-way picker; persistence
// goes through the conformer's `preflightSearchMode` field. Search
// is amputated on Intel so the field's value never drives real
// behavior — it just keeps the picker's binding alive.
public enum PreflightSearchMode: String, Codable, CaseIterable, Sendable {
    case off, narrow, balanced, wide

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .narrow: return "Narrow"
        case .balanced: return "Balanced"
        case .wide: return "Wide"
        }
    }

    /// Help text shown beneath the segmented picker in
    /// `ConfigurationView`. Mirrors upstream verbatim — even though
    /// preflight search is amputated on Intel, the picker still
    /// renders + binds, and the explainer keeps the UI honest about
    /// what each mode would do.
    public var helpText: String {
        switch self {
        case .off: return "Disable pre-flight search. Only explicit tool calls are used."
        case .narrow: return "Minimal tool injection. Up to 2 tools loaded."
        case .balanced: return "Default. Up to 5 relevant tools loaded."
        case .wide: return "Aggressive search. Up to 15 tools loaded, may increase prompt size."
        }
    }
}

// MARK: - ChatConfiguration
//
// Extended in M11 Phase 11.A.3.0 to mirror more of the upstream
// public surface so `ConfigurationView` (un-body-swapped in 11.A.3.1)
// can bind to its rows. Fields whose backing subsystem is amputated
// on Intel (CoreModel picker, workMax* runtime, preflightSearchMode)
// still persist via the shared singleton so the view's two-way
// bindings work — they just don't drive real behavior. Persistence
// is in-memory per process; `ChatConfigurationStore.save` is a no-op
// (config doesn't survive Intel app restarts yet).

final class ChatConfiguration: @unchecked Sendable {
    static let shared = ChatConfiguration()

    // Tool / generation behaviour
    var disableTools: Bool = false
    var maxToolAttempts: Int? = nil
    // Kept as `Double?` to match the consumer at `ChatView.swift:2148`
    // (which forwards it to a `Double?` API). Upstream uses `Float?`
    // here; the Intel divergence is intentional and bridged at the
    // call-site Bool / numeric conversion if needed.
    var topPOverride: Double? = nil

    // Chat-side defaults
    var hotkey: Hotkey? = nil
    var systemPrompt: String = ""
    var temperature: Float? = nil
    var maxTokens: Int? = nil
    var contextLength: Int? = 128000
    var defaultModel: String? = nil
    var generativeGreetingsEnabled: Bool = false
    var greetingPersona: String = ""
    var enableClipboardMonitoring: Bool = true
    var defaultToolSelectionMode: Any? = nil
    var defaultManualToolNames: [String]? = nil
    var defaultManualSkillNames: [String]? = nil

    // Core (local) model picker — amputated on Intel.
    var coreModelProvider: String? = nil
    var coreModelName: String? = nil
    var coreModelIdentifier: String? {
        guard let provider = coreModelProvider, let name = coreModelName else { return nil }
        return "\(provider)/\(name)"
    }

    // Work-agent runtime — used by upstream's local agent loop.
    var workTemperature: Float? = nil
    var workMaxTokens: Int? = nil
    var workTopPOverride: Float? = nil
    var workMaxIterations: Int? = nil

    // Preflight search mode — picker binds even though search is
    // amputated. Stored for round-trip integrity.
    var preflightSearchMode: PreflightSearchMode? = nil

    init() {}

    /// Designated init mirroring upstream's struct init. Upstream is a
    /// value type; on Intel `ChatConfiguration` is a class with a
    /// shared singleton, so this convenience init creates a NEW
    /// instance carrying the parameters. `ChatConfigurationStore.save(_:)`
    /// copies the fields from the passed instance into the shared
    /// singleton, keeping the call sites that do
    /// `let cfg = ChatConfiguration(...); save(cfg)` working
    /// byte-for-byte without view-side changes.
    convenience init(
        hotkey: Hotkey?,
        systemPrompt: String,
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        contextLength: Int? = nil,
        // Accepts `Float?` to match the view's `parsedTopP: Float?`
        // call site; stored internally as `Double?` (the type
        // `ChatView.swift:2148` consumes). Bridged in the body.
        topPOverride: Float? = nil,
        maxToolAttempts: Int? = nil,
        defaultModel: String? = nil,
        coreModelProvider: String? = nil,
        coreModelName: String? = nil,
        workTemperature: Float? = nil,
        workMaxTokens: Int? = nil,
        workTopPOverride: Float? = nil,
        workMaxIterations: Int? = nil,
        preflightSearchMode: PreflightSearchMode? = nil,
        disableTools: Bool = false,
        defaultToolSelectionMode: Any? = nil,
        defaultManualToolNames: [String]? = nil,
        defaultManualSkillNames: [String]? = nil,
        enableClipboardMonitoring: Bool = true,
        generativeGreetingsEnabled: Bool = false,
        greetingPersona: String = ""
    ) {
        self.init()
        self.hotkey = hotkey
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.topPOverride = topPOverride.map(Double.init)
        self.maxToolAttempts = maxToolAttempts
        self.defaultModel = defaultModel
        self.coreModelProvider = coreModelProvider
        self.coreModelName = coreModelName
        self.workTemperature = workTemperature
        self.workMaxTokens = workMaxTokens
        self.workTopPOverride = workTopPOverride
        self.workMaxIterations = workMaxIterations
        self.preflightSearchMode = preflightSearchMode
        self.disableTools = disableTools
        self.defaultToolSelectionMode = defaultToolSelectionMode
        self.defaultManualToolNames = defaultManualToolNames
        self.defaultManualSkillNames = defaultManualSkillNames
        self.enableClipboardMonitoring = enableClipboardMonitoring
        self.generativeGreetingsEnabled = generativeGreetingsEnabled
        self.greetingPersona = greetingPersona
    }

    /// Copy every editable field from another instance into self.
    /// Used by `ChatConfigurationStore.save(_:)` to fold a freshly-
    /// constructed `ChatConfiguration` into the shared singleton.
    func adopt(_ other: ChatConfiguration) {
        self.hotkey = other.hotkey
        self.systemPrompt = other.systemPrompt
        self.temperature = other.temperature
        self.maxTokens = other.maxTokens
        self.contextLength = other.contextLength
        self.topPOverride = other.topPOverride
        self.maxToolAttempts = other.maxToolAttempts
        self.defaultModel = other.defaultModel
        self.coreModelProvider = other.coreModelProvider
        self.coreModelName = other.coreModelName
        self.workTemperature = other.workTemperature
        self.workMaxTokens = other.workMaxTokens
        self.workTopPOverride = other.workTopPOverride
        self.workMaxIterations = other.workMaxIterations
        self.preflightSearchMode = other.preflightSearchMode
        self.disableTools = other.disableTools
        self.defaultToolSelectionMode = other.defaultToolSelectionMode
        self.defaultManualToolNames = other.defaultManualToolNames
        self.defaultManualSkillNames = other.defaultManualSkillNames
        self.enableClipboardMonitoring = other.enableClipboardMonitoring
        self.generativeGreetingsEnabled = other.generativeGreetingsEnabled
        self.greetingPersona = other.greetingPersona
    }

    static func load() -> ChatConfiguration { shared }

    /// Mirrors `ChatConfiguration.default` from upstream. Upstream
    /// is a value-type static factory; the Intel class equivalent
    /// returns the shared singleton so call-site identity checks
    /// (`config == .default`) hold for the duration of a process.
    static var `default`: ChatConfiguration { shared }
}

// MARK: - ManagementBadgeStore (Intel stub — M11)
//
// Upstream coalesces every sidebar-badge data source (ModelManager,
// RemoteProviderManager, AgentManager, PluginRepositoryService,
// SandboxPluginLibrary, SpeechModelManager) into a single throttled
// snapshot so the Management view's body doesn't re-render on every
// model-download progress chunk. On Intel none of those sources have
// badge content to publish (local-model installs amputated, sandbox
// amputated, speech amputated), so the snapshot stays empty and the
// store is a no-op ObservableObject.

struct ManagementBadgeSnapshot: Sendable {
    var counts: [ManagementTab: Int] = [:]
    var highlights: Set<ManagementTab> = []
}

@MainActor
final class ManagementBadgeStore: ObservableObject {
    static let shared = ManagementBadgeStore()
    @Published var snapshot = ManagementBadgeSnapshot()
}

// MARK: - IncomingPairCoordinator (Intel stub — M11)
//
// Upstream surfaces `osaurus://...?pair=...` deeplinks here. The
// pairing services + Bonjour discovery are excluded on Intel, so no
// invite ever lands; ManagementView's `.sheet(...)` binding reads
// `pendingInvite` and stays nil.

@MainActor
final class IncomingPairCoordinator: ObservableObject {
    static let shared = IncomingPairCoordinator()
    @Published var pendingInvite: AgentInvite? = nil
}

// MARK: - AgentInvite (Intel stub — M11)
//
// Upstream `AgentInvite` lives in the excluded
// `Models/Agent/AgentInvite.swift`. We only need an empty Identifiable
// struct here so the `.sheet(item:)` binding type-checks; the sheet
// itself is body-swapped to `AppleSiliconOnlyTab` upstream.

struct AgentInvite: Identifiable, Sendable, Equatable {
    let id = UUID()
}

#endif
