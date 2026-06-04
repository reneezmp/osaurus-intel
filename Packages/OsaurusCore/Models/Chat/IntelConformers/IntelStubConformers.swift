//
//  IntelStubConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel stub conformers — concretized (no existential protocol types).
//  All types use concrete types matching the Apple Silicon originals byte-for-byte.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import Foundation
import OsaurusRepository

// MARK: - SpeechService (no-op on Intel)

// MARK: - Voice notification names (Intel stubs)
//
// Upstream declares these in `Services/Voice/VADService.swift` (excluded).
// FloatingInputCard subscribes to both via `NotificationCenter.default`;
// on Intel nothing posts them (no VAD pipeline, no Settings panel) but
// the names still need to resolve at compile time.
extension Notification.Name {
    public static let startVoiceInputInChat = Notification.Name("startVoiceInputInChat")
    public static let voiceConfigurationChanged = Notification.Name("voiceConfigurationChanged")
}

// MARK: - Voice subsystem stubs (Phase 8C)
//
// The entire voice pipeline (SpeechService, SpeechModelManager,
// SpeechConfiguration, LiveVoiceAudioSnapshot, SpeechError,
// TranscriptionCleanupService) lives behind the excluded
// `Services/Voice/*.swift` + `Managers/SpeechService.swift` +
// `Managers/Model/SpeechModelManager.swift` files. FloatingInputCard's
// microphone button + transcription overlay reach deeply into this
// surface, so rather than gate every line in the upstream view, we
// expose no-op stubs here. The buttons render but stay inert; users
// see "microphone permission denied" semantics by default.

struct LiveVoiceAudioSnapshot: Sendable {
    var samples: [Float] = []
    /// Sample rate as `Int` so the Int↔Double comparisons in
    /// FloatingInputCard's `scheduleLiveVoicePreencodeIfNeeded` type-check
    /// without explicit conversion. 16_000 is the standard wav rate the
    /// upstream pipeline uses.
    var sampleRate: Int = 16_000
    /// Seconds-of-audio derived from `samples.count / sampleRate`.
    /// FloatingInputCard logs this on every send; with empty samples
    /// the value is zero.
    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
    /// Best-effort WAV-encoded bytes. Returns nil on Intel because the
    /// stub never carries actual samples; FloatingInputCard handles the
    /// nil case (treats it as "no voice attachment").
    func wavData() -> Data? { nil }
}

enum SpeechError: Error, LocalizedError {
    case unavailable
    case modelNotLoaded
    case permissionDenied
    case microphonePermissionDenied
    case transcriptionFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech input is not available on Intel."
        case .modelNotLoaded: return "Speech model not loaded."
        case .permissionDenied, .microphonePermissionDenied:
            return "Microphone permission denied."
        case .transcriptionFailed(let detail): return "Transcription failed: \(detail)"
        }
    }
}

/// Return type for `ModelRuntime.preencodeLiveVoiceAudioIfResident` —
/// FloatingInputCard logs every field on completion. Intel never
/// actually produces one (the method returns nil), but the type has
/// to exist for the closure body's `result.status.rawValue` access
/// path to type-check.
struct LiveVoicePreencodeResult: Sendable {
    enum Status: String, Sendable {
        case ok
        case skipped
        case failed
    }
    let status: Status
    let sampleCount: Int
    let sampleRate: Int
    let encodeMs: Int
    let message: String?
}

// `SpeechConfiguration` (with its `.default` static, `confirmationDelay`,
// `pauseDuration`, etc.) is provided by upstream
// `Models/Voice/SpeechConfiguration.swift` (un-excluded — it's pure
// Foundation enums + struct). The stub that used to live here has been
// removed to avoid a redeclaration collision.

final class SpeechService: ObservableObject, @unchecked Sendable {
    static let shared = SpeechService()

    // Recording lifecycle
    @Published var isRecording: Bool = false
    @Published var isSpeechDetected: Bool = false
    @Published var audioLevel: Float = 0

    // Transcription state
    @Published var currentTranscription: String = ""
    @Published var confirmedTranscription: String = ""

    // Model state
    @Published var isLoadingModel: Bool = false
    @Published var isModelLoaded: Bool = false

    // Permission state
    @Published var microphonePermissionGranted: Bool = false

    /// Identifier of the currently-loaded speech model. Always nil on
    /// Intel because the speech subsystem is amputated; surface kept
    /// so `ConfigurationView`'s Voice section (un-body-swapped in M11
    /// Phase 11.A.3.1, gated visually to AppleSiliconOnlyOverlay)
    /// type-checks.
    @Published var loadedModelId: String? = nil

    // Methods — all no-op on Intel
    func stopStreamingTranscription(force: Bool = false) async {}
    func clearTranscription() {}
    func startStreamingTranscription(config: SpeechConfiguration = .default) async throws {
        throw SpeechError.unavailable
    }
    func loadModel(_ modelId: String? = nil) async throws {
        throw SpeechError.modelNotLoaded
    }
    func requestMicrophonePermission() async -> Bool { false }
    /// Live snapshot accessor used by `FloatingInputCard.scheduleLiveVoicePreencodeIfNeeded`.
    /// Upstream is a `currentLiveAudioSnapshot()` method that returns
    /// the latest live VAD frame; Intel has no recording session so
    /// the answer is always nil.
    func currentLiveAudioSnapshot() -> LiveVoiceAudioSnapshot? { nil }
}

final class SpeechModelManager: ObservableObject, @unchecked Sendable {
    static let shared = SpeechModelManager()
    @Published var selectedModel: SpeechModelInfo? = nil
    @Published var availableModels: [SpeechModelInfo] = []
    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    /// Used by FloatingInputCard's "Speech models" sub-popover header.
    /// Always zero on Intel.
    @Published var downloadedModelsCount: Int = 0

    func selectModel(_ model: SpeechModelInfo) {}
    func downloadModel(_ model: SpeechModelInfo) async {}
    func deleteModel(_ model: SpeechModelInfo) {}
}

struct SpeechModelInfo: Identifiable, Sendable, Equatable {
    let id: String
    var name: String = ""
    var isInstalled: Bool = false
    var sizeBytes: Int64 = 0
}

final class TranscriptionCleanupService: @unchecked Sendable {
    static let shared = TranscriptionCleanupService()
    func cleanup(_ text: String) -> String { text }
    func cleanupForSend(_ text: String) -> String { text }
    func clean(_ text: String) -> String { text }
    static func cleanup(_ text: String) -> String { text }
    static func cleanupForSend(_ text: String) -> String { text }
}

// MARK: - ModelManager (Intel stub)
//
// Upstream `Managers/Model/ModelManager.swift` orchestrates the MLX
// local-model lifecycle (download / load / unload / list). Intel has
// zero local models, so the stub exposes only the surface
// FloatingInputCard reads — empty everywhere.

final class ModelManager: ObservableObject, @unchecked Sendable {
    static let shared = ModelManager()
    @Published var availableModels: [ModelInfo] = []
    @Published var suggestedModels: [ModelInfo] = []
    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var downloadMetrics: [String: DownloadMetrics] = [:]

    /// A locally-discovered model reference. ServerView reads `.id`.
    struct LocalModelRef: Sendable { let id: String }

    /// ServerView's API-reference example list calls this to enumerate
    /// locally-downloaded MLX models. Always empty on Intel (local
    /// model execution is amputated). Static to match the upstream
    /// call site `ModelManager.discoverLocalModels()`.
    static func discoverLocalModels() -> [LocalModelRef] { [] }

    enum DownloadState: Sendable, Equatable {
        case idle
        case downloading(Double)
        case completed
        case failed(String)
    }

    struct DownloadMetrics: Sendable {
        var bytesReceived: Int64? = nil
        var totalBytes: Int64? = nil
        var bytesPerSecond: Double? = nil
        var etaSeconds: Double? = nil
    }

    /// Upstream returns a newer model id when a known-deprecated MLX
    /// model gets selected (e.g., Qwen 3 → Qwen 3.5). Intel has no
    /// local-model catalogue, so deprecation never applies.
    static func replacementForDeprecatedModel(_ modelId: String) -> String? { nil }
}

// `ModelFamilyNames` is provided by upstream
// `Models/Configuration/ModelFamilyNames.swift` (not excluded). The
// Intel stub that used to live here was removed to avoid a
// redeclaration collision.

// MARK: - RemoteProviderManager (cloud-only, concretized)
//
// `RemoteProvidersView` (un-body-swapped in M11 Phase 11.A.2) reads
// `manager.configuration.providers` + `manager.providerStates` via
// `@ObservedObject`, and mutates the set via `addProvider`,
// `updateProvider`, `removeProvider`, `setEnabled`. Extended in M11
// Phase 11.A.2.0 to mirror the upstream public surface used by the
// view, with real on-disk persistence via
// `RemoteProviderConfigurationStore` (NOT excluded on Intel — see
// `Models/Configuration/RemoteProviderConfiguration.swift:500`).
// `@MainActor` matches upstream so the view's bindings stay on the
// main actor and Swift 6.3 actor-isolation diagnostics are quiet.
//
// What's deliberately NOT modeled: `connect` / `reconnect` /
// `testConnection` / `service(for:)` / `connectedServices()` — those
// route through `RemoteProviderService` which is excluded on Intel
// (cloud streaming happens via `OsaurusServer` + env-var
// `DEEPSEEK_API_KEY`, not through the configured provider list).
// The Intel stubs for those methods stay as no-ops so any chat-side
// caller doesn't crash.
@MainActor
final class RemoteProviderManager: ObservableObject, @unchecked Sendable {
    static let shared = RemoteProviderManager()

    @Published private(set) var configuration: RemoteProviderConfiguration
    @Published private(set) var providerStates: [UUID: RemoteProviderState] = [:]

    private init() {
        self.configuration = RemoteProviderConfigurationStore.load()
        seedConnectedStates()
    }

    /// Mark every enabled provider as "connected" so the Providers tab
    /// doesn't show a misleading "Disconnected" badge. On Intel,
    /// streaming goes through `OsaurusServer` + the env-var
    /// `DEEPSEEK_API_KEY` rather than a per-provider connection — so a
    /// configured + enabled provider IS effectively usable, and the
    /// stock "Disconnected" state confused users during the 11.A.2
    /// click-through. (Renée 2026-06-01/02.)
    private func seedConnectedStates() {
        for provider in configuration.providers where provider.enabled {
            var state = RemoteProviderState(providerId: provider.id)
            state.isConnected = true
            providerStates[provider.id] = state
        }
    }

    func isEphemeral(id: UUID) -> Bool { false }

    func addProvider(
        _ provider: RemoteProvider,
        apiKey: String? = nil,
        oauthTokens: RemoteProviderOAuthTokens? = nil,
        isEphemeral: Bool = false
    ) {
        configuration.add(provider)
        RemoteProviderConfigurationStore.save(configuration)
        if provider.enabled {
            var state = RemoteProviderState(providerId: provider.id)
            state.isConnected = true
            providerStates[provider.id] = state
        }
    }

    func updateProvider(
        _ provider: RemoteProvider,
        apiKey: String? = nil,
        oauthTokens: RemoteProviderOAuthTokens? = nil
    ) {
        configuration.update(provider)
        RemoteProviderConfigurationStore.save(configuration)
    }

    func removeProvider(id: UUID) {
        configuration.remove(id: id)
        providerStates.removeValue(forKey: id)
        RemoteProviderConfigurationStore.save(configuration)
    }

    func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        RemoteProviderConfigurationStore.save(configuration)
        if enabled {
            var state = RemoteProviderState(providerId: providerId)
            state.isConnected = true
            providerStates[providerId] = state
        } else {
            providerStates.removeValue(forKey: providerId)
        }
    }

    // Cloud-routing no-ops kept for compatibility with chat-side callers.
    func connect(providerId: UUID) async throws {}
    func disconnect(providerId: UUID) {}
    func reconnect(providerId: UUID) async throws {}

    /// AgentDetailView's per-agent model picker calls `findService` to
    /// resolve a provider's live connection. Cloud streaming on Intel
    /// goes through `OsaurusServer` + the env-var key, not through a
    /// per-provider service object, so this returns nil.
    func findService(forModel model: String) -> Any? { nil }

    /// M12 follow-up (Renée 2026-06-03): the RemoteProviderEditSheet "Test"
    /// step probes the provider's `/models` endpoint. The upstream
    /// `RemoteProviderManager.testConnection` (excluded) pulls in
    /// `RemoteProviderService` + OAuth + Anthropic-specific helpers; this is a
    /// pragmatic Intel mirror that does the OpenAI-compatible GET /models probe
    /// (which covers DeepSeek and friends) so add/edit actually works. Returns
    /// the discovered model ids.
    func testConnection(
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType = .openaiLegacy,
        apiKey: String?,
        headers: [String: String]
    ) async throws -> [String] {
        let tempProvider = RemoteProvider(
            name: "Test",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: authType,
            providerType: providerType,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )

        var testHeaders = headers
        if authType == .apiKey, let apiKey, !apiKey.isEmpty {
            switch providerType {
            case .anthropic:
                if testHeaders["x-api-key"] == nil { testHeaders["x-api-key"] = apiKey }
                if testHeaders["anthropic-version"] == nil {
                    testHeaders["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                if testHeaders["x-goog-api-key"] == nil { testHeaders["x-goog-api-key"] = apiKey }
            case .azureOpenAI:
                if testHeaders["api-key"] == nil { testHeaders["api-key"] = apiKey }
            default:
                if testHeaders["Authorization"] == nil {
                    testHeaders["Authorization"] = "Bearer \(apiKey)"
                }
            }
        }

        guard let url = tempProvider.url(for: "/models") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (k, v) in testHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "RemoteProvider",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Test failed — HTTP \(http.statusCode)"]
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let arr = json["data"] as? [[String: Any]] {
            return arr.compactMap { $0["id"] as? String }.sorted()
        }
        if let arr = json["models"] as? [[String: Any]] {
            return arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
        }
        return []
    }
}

// MARK: - PluginRepositoryService (Intel stub)
//
// Upstream `PluginRepositoryService` (excluded on Intel — see
// `Services/Plugin/PluginRepositoryService.swift`) tracks installed
// + repository-known plugins and is referenced by `SkillsView` (un-
// body-swapped in M11 Phase 11.A.2) when rendering "From: <plugin>"
// breadcrumbs on plugin-attached skills. The Intel stub returns an
// empty plugin list because plugin installation is amputated; the
// `Skill.pluginId` field can still be populated by manually-
// installed skills, but the breadcrumb just falls through to the
// generic "Plugin" label.
@MainActor
final class PluginRepositoryService: ObservableObject, @unchecked Sendable {
    static let shared = PluginRepositoryService()

    @Published private(set) var plugins: [PluginState] = []
    @Published private(set) var isRefreshing: Bool = false
    // PluginsView observes these (M11 Phase 11.B.2). All inert on Intel:
    // no plugins install, so nothing updates / errors / needs secrets.
    @Published var updatesAvailableCount: Int = 0
    @Published var lastError: String? = nil
    @Published var pendingSecretsPlugin: String? = nil

    private init() {}

    /// AgentDetailView offers an "uninstall plugin" affordance. Plugin
    /// installation is amputated on Intel (the three-bucket M9 UI shows
    /// compatibility but doesn't install), so uninstall is a no-op.
    func uninstall(pluginId: String) async {}

    // PluginsView install/update affordances. Still no-ops on Intel until
    // the execution host is restored (M9 Phase C) — Browse shows the registry
    // + compatibility, but nothing installs yet.
    func install(pluginId: String) async throws {}
    func upgrade(pluginId: String) async throws {}

    /// M9 Phase A (Renée 2026-06-04): real registry browse on Intel. The git
    /// registry fetcher (`CentralRepositoryManager`) lives in the
    /// `OsaurusRepository` package, which is plain Foundation and already
    /// linked — so Browse works on Intel even though the plugin EXECUTION host
    /// is still amputated. Maps each `PluginSpec` to the Intel `PluginState`
    /// shape (versions converted; capabilities skipped — display only). Nothing
    /// is ever `installedVersion`, so every plugin lands in the Browse tab.
    func refresh() async {
        if isRefreshing { return }
        await MainActor.run {
            isRefreshing = true
            lastError = nil
        }
        let reachable = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.refresh()
        }.value
        let specs = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.listAllSpecs()
        }.value
        let mapped: [PluginState] = specs.map { spec in
            let latest = spec.versions.map(\.version).max()
            return PluginState(
                pluginId: spec.plugin_id,
                name: spec.name,
                pluginDescription: spec.description,
                authors: spec.authors,
                license: spec.license,
                capabilities: nil,
                installedVersion: nil,
                latestVersion: latest.map {
                    SemanticVersion(major: $0.major, minor: $0.minor, patch: $0.patch)
                },
                isInstalling: false,
                loadError: nil
            )
        }
        await MainActor.run {
            if !reachable && mapped.isEmpty {
                lastError = "Unable to reach the plugin repository"
            }
            plugins = mapped.sorted { ($0.name ?? $0.pluginId) < ($1.name ?? $1.pluginId) }
            isRefreshing = false
        }
    }
}

/// Intel stub mirroring just the surface `SkillsView` reads off
/// `PluginRepositoryService.shared.plugins.first(where:)`. Upstream
/// definition at `Services/Plugin/PluginRepositoryService.swift:14`
/// has the full plugin metadata; Intel keeps only `pluginId` +
/// `displayName` since the only caller is the breadcrumb in SkillRow.
// Full PluginState shape (M11 Phase 11.B.2) mirroring upstream
// `Services/Plugin/PluginRepositoryService.swift`. The PluginsView
// three-bucket UI reads display metadata + install/update state. Empty
// on Intel (no plugin runtime), but the full shape must compile.
struct PluginState: Identifiable, Equatable {
    let pluginId: String
    var id: String { pluginId }
    let name: String?
    let pluginDescription: String?
    let authors: [String]?
    let license: String?
    let capabilities: RegistryCapabilities?
    var installedVersion: SemanticVersion?
    var latestVersion: SemanticVersion?
    var isInstalling: Bool
    var loadError: String?

    var displayName: String { name ?? pluginId }
    var hasUpdate: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return latest > installed
    }
    var isInstalled: Bool { installedVersion != nil }
    var hasLoadError: Bool { isInstalled && loadError != nil }

    init(
        pluginId: String,
        name: String? = nil,
        pluginDescription: String? = nil,
        authors: [String]? = nil,
        license: String? = nil,
        capabilities: RegistryCapabilities? = nil,
        installedVersion: SemanticVersion? = nil,
        latestVersion: SemanticVersion? = nil,
        isInstalling: Bool = false,
        loadError: String? = nil
    ) {
        self.pluginId = pluginId
        self.name = name
        self.pluginDescription = pluginDescription
        self.authors = authors
        self.license = license
        self.capabilities = capabilities
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isInstalling = isInstalling
        self.loadError = loadError
    }
}

// MARK: - ClaudePluginInstallReport (Intel stub)
//
// Upstream `ClaudePluginInstallReport` lives in the excluded
// `Services/Skill/ClaudePluginInstaller.swift`. The type only
// surfaces through `GitHubImportSheet.onPluginInstallComplete:
// ((ClaudePluginInstallReport) -> Void)?` and the closure body at
// `SkillsView:190` reads four computed totals. The Intel stub
// returns zeros because the GitHub-installer path itself is Apple-
// Silicon only (its sheet renders the `AppleSiliconOnlyTab`
// placeholder), so the callback will never fire with non-zero
// counts on Intel.
public struct ClaudePluginInstallReport: Sendable {
    public init() {}
    public var totalImportedSkills: Int { 0 }
    public var totalImportedAgents: Int { 0 }
    public var totalImportedCommands: Int { 0 }
    public var totalImportedMCPProviders: Int { 0 }
}

// MARK: - ToolRegistry (stub)

final class ToolRegistry: ObservableObject, @unchecked Sendable {
    static let shared = ToolRegistry()

    func resolveExecutionMode(folderContext: FolderContext?, autonomousEnabled: Bool) -> ExecutionMode { .none }

    // M12 Gap 3: real tool storage + dispatch. The Intel chat already runs the
    // full agent tool-loop (ChatView sends `toolSpecs` and calls
    // `ToolRegistry.shared.execute`); it was inert only because this registry
    // held nothing and `execute` returned canned text. Folder tools
    // (file_read/write/edit/search/tree, shell_run, git_*) register here via
    // FolderToolManager when a working folder is selected, and unregister when
    // it's cleared. No sandbox/DB/capability built-ins (those are amputated) —
    // the folder tool suite is the Intel-supported set.
    private var toolsByName: [String: OsaurusTool] = [:]

    /// Register (or overwrite) a tool by name. Used by FolderToolManager.
    func register(_ tool: OsaurusTool) {
        toolsByName[tool.name] = tool
        objectWillChange.send()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Names of remote MCP-provider tools (tracked so the capability picker can
    /// bucket them under their provider). M12 follow-up.
    private var mcpToolNames: Set<String> = []

    /// Register a remote MCP provider's tool. The real MCPProviderManager
    /// (un-excluded) registers each connected remote tool here so the chat
    /// tool-loop + ToolsManagerView + capability picker see them.
    func registerMCPTool(_ tool: OsaurusTool) {
        mcpToolNames.insert(tool.name)
        register(tool)
    }

    // MARK: Tool source predicates (for AgentCapabilityManagerView grouping)

    /// Always-loaded built-in tools. Intel has none (folder tools are
    /// folder-scoped, not always-loaded built-ins), so this stays empty.
    private(set) var builtInToolNames: Set<String> = []

    /// Runtime-managed (dynamically loaded) tool names — none on Intel.
    var runtimeManagedToolNames: Set<String> { [] }

    func isMCPTool(_ name: String) -> Bool { mcpToolNames.contains(name) }

    /// Native dylib plugins are amputated on Intel.
    func isPluginTool(_ name: String) -> Bool { false }

    /// Sandbox tools are amputated on Intel.
    func isSandboxTool(_ name: String) -> Bool { false }

    /// The provider/plugin group a tool belongs to. On Intel only MCP-provider
    /// tools carry a group (their `providerName`); ExternalTool/SandboxPluginTool
    /// are amputated. Mirrors the real ToolRegistry.groupName.
    func groupName(for toolName: String) -> String? {
        guard let tool = toolsByName[toolName] else { return nil }
        if let mcp = tool as? MCPProviderTool { return mcp.providerName }
        return nil
    }

    /// Remove tools by name. Used by FolderToolManager when the folder clears
    /// and by MCPProviderManager on disconnect.
    func unregister(names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            toolsByName.removeValue(forKey: name)
            mcpToolNames.remove(name)
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// OpenAI-compatible specs for the currently registered tools, fed into
    /// `ComposedContext.tools` so the model sees them on the next send.
    func openAISpecs() -> [Tool] {
        toolsByName.values
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
    }

    func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = toolsByName[name] else {
            return ToolEnvelope.failure(
                kind: .toolNotFound,
                message:
                    "Tool '\(name)' is not registered. Pick a working folder to enable file/shell tools.",
                tool: name
            )
        }
        return try await tool.execute(argumentsJSON: argumentsJSON)
    }

    /// Per-tool allow/deny policy state for `ConfigurationView`'s tool
    /// permission rows (un-body-swapped in M11 Phase 11.A.3.1). Intel
    /// keeps an in-memory map keyed by tool name. Unlike upstream —
    /// which persists policies to `tools.json` and enforces them in
    /// the sandbox executor — Intel's policy state is advisory only
    /// (sandbox tools are amputated; cloud tools run unconditionally).
    /// The map exists so the per-tool segmented picker round-trips and
    /// the `@Published`-style republish via `objectWillChange` keeps
    /// other rows in sync. Stored on the registry; reads/writes are
    /// main-thread (the view drives them).
    private var _policies: [String: ToolPermissionPolicy] = [:]

    /// Returns the configured policy for `toolName`, or nil if the
    /// user hasn't set one (meaning "Auto" / inherit-default).
    func configuredPolicy(for toolName: String) -> ToolPermissionPolicy? {
        _policies[toolName]
    }

    /// Sets the policy for `toolName` and republishes so observing rows
    /// refresh. Stores ALL three values explicitly — including `.auto`.
    ///
    /// Earlier this collapsed `.auto` into a `removeValue` (treating
    /// Auto as "clear the override"). That broke the picker for
    /// destructive tools: `shell_run` and `git_commit` default to
    /// `.ask`, so selecting "Auto" cleared the override, the
    /// `effectivePolicy` fell back to the `.ask` default, and the
    /// segmented control immediately snapped back to Ask — making
    /// Auto un-selectable. Storing the value explicitly lets the
    /// picker's `get: { configuredPolicy ?? defaultPolicy }` read
    /// back the user's actual choice. (M11 Phase 11.A.3 click-through
    /// fix, Renée 2026-06-01.)
    func setPolicy(_ policy: ToolPermissionPolicy, for toolName: String) {
        objectWillChange.send()
        _policies[toolName] = policy
    }

    /// Used by `ConfigurationView`'s per-tool permission rows to clear
    /// a custom allow/deny policy back to the inherited default.
    func clearPolicy(for toolName: String) {
        objectWillChange.send()
        _policies.removeValue(forKey: toolName)
    }

    /// AgentDetailView lists per-agent dynamic (plugin-registered) tools
    /// and reads each entry's `.name`. Dynamic tools come from the
    /// sandbox plugin runtime which is amputated on Intel, so the list
    /// is always empty.
    struct DynamicToolRef: Sendable { let name: String }
    func listDynamicTools() -> [DynamicToolRef] { [] }

    // MARK: - ToolsManagerView surface (M11 Phase 11.B.2)

    /// A registered tool as ToolsManagerView lists it. Mirrors upstream
    /// `ToolRegistry.ToolEntry`.
    struct ToolEntry: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let description: String
        var enabled: Bool
        let parameters: JSONValue?
        /// Rough heuristic (~4 chars/token) — upstream uses
        /// ToolSpecTokenEstimator (excluded); the inline estimate is
        /// close enough for the tool-list token badge.
        var estimatedTokens: Int {
            (name.count + description.count) / 4
        }
    }

    /// Per-tool policy + permission detail, mirroring upstream
    /// `ToolRegistry.ToolPolicyInfo`.
    struct ToolPolicyInfo: Sendable {
        let isPermissioned: Bool
        let defaultPolicy: ToolPermissionPolicy
        let configuredPolicy: ToolPermissionPolicy?
        let effectivePolicy: ToolPermissionPolicy
        let requirements: [String]
        let grantsByRequirement: [String: Bool]
        let systemPermissions: [SystemPermission]
        let systemPermissionStates: [SystemPermission: Bool]
    }

    /// The tools registered on Intel — the folder tool suite once a working
    /// folder is selected (M12 Gap 3). ToolsManagerView renders the list.
    func listTools() -> [ToolEntry] {
        toolsByName.values
            .sorted { $0.name < $1.name }
            .map {
                ToolEntry(
                    name: $0.name,
                    description: $0.description,
                    enabled: true,
                    parameters: $0.parameters
                )
            }
    }

    /// Toggle a tool on/off. No-op stub on Intel (tool enablement state
    /// isn't persisted in this surface yet).
    func setEnabled(_ enabled: Bool, for name: String) {}

    /// Policy detail for a tool. Returns a default-`.auto` policy with
    /// no permission requirements on Intel (sandbox-gated tools are
    /// amputated).
    func policyInfo(for name: String) -> ToolPolicyInfo? {
        ToolPolicyInfo(
            isPermissioned: false,
            defaultPolicy: .auto,
            configuredPolicy: _policies[name],
            effectivePolicy: _policies[name] ?? .auto,
            requirements: [],
            grantsByRequirement: [:],
            systemPermissions: [],
            systemPermissionStates: [:]
        )
    }

    /// Register/unregister sandbox plugin tools. Sandbox runtime is
    /// amputated on Intel, so these are no-ops.
    func registerSandboxPluginTools(plugin: SandboxPlugin) {}
    func unregisterSandboxPluginTools(pluginId: String) {}
}

// MARK: - MemoryService (disabled on Intel)

final class MemoryService: @unchecked Sendable {
    static let shared = MemoryService()
    func bufferTurn(userMessage: String, assistantMessage: String?, agentId: String, conversationId: String, sessionDate: String? = nil) async {}
}

// MARK: - GenerativeGreeting (no-op on Intel)

final class GenerativeGreetingPool: @unchecked Sendable {
    static let shared = GenerativeGreetingPool()
    func setActive(agent: Agent, model: String) async {}
    func popFresh(for agent: Agent, model: String) async -> GenerativeGreeting? { nil }
    func seed(_ cached: GenerativeGreeting, for agent: Agent, model: String) async {}
    func warmUp(for agent: Agent, model: String) async {}
}

final class GenerativeGreetingService: @unchecked Sendable {
    static let shared = GenerativeGreetingService()
    func generate(agent: Agent, fallbackModel: String) async throws -> GenerativeGreeting { throw CancellationError() }

    /// Used by `ConfigurationView`'s greeting persona row
    /// (un-body-swapped in M11 Phase 11.A.3.1) as placeholder text
    /// when the user hasn't set a custom persona. The actual
    /// greeting generation is amputated on Intel; this string is
    /// purely for the UI's empty-state hint.
    static let defaultPersonaInstruction: String = "Be warm and playful. Keep it short."
}

// MARK: - SharedArtifact (stub)

enum ArtifactContextType: String, Sendable {
    case work
    case chat
}

struct ProcessingResult: Sendable {
    let enrichedToolResult: String
}

struct SharedArtifact: Identifiable, Sendable, Equatable {
    let id: String
    let contextId: String
    let contextType: ArtifactContextType
    let filename: String
    let mimeType: String
    let fileSize: Int
    let hostPath: String
    let isDirectory: Bool
    let content: String?
    let description: String?
    let isFinalResult: Bool
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        contextId: String,
        contextType: ArtifactContextType,
        filename: String,
        mimeType: String,
        fileSize: Int,
        hostPath: String,
        isDirectory: Bool = false,
        content: String? = nil,
        description: String? = nil,
        isFinalResult: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.contextId = contextId
        self.contextType = contextType
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.hostPath = hostPath
        self.isDirectory = isDirectory
        self.content = content
        self.description = description
        self.isFinalResult = isFinalResult
        self.createdAt = createdAt
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isText: Bool { mimeType.hasPrefix("text/") || mimeType == "application/json" }
    var isHTML: Bool { mimeType == "text/html" }
    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isPDF: Bool { mimeType == "application/pdf" }
    var categoryLabel: String {
        if isDirectory { return "Directory" }
        if isImage { return "Image" }
        if isPDF { return "PDF" }
        if isAudio { return "Audio" }
        if isVideo { return "Video" }
        if isHTML { return "Web Page" }
        if isText { return "Text" }
        return "File"
    }

    enum ResolutionFailure: Error {
        case markersMissing
        case noContentOrPath
        case destinationRejected(filename: String)
        case pathRejected(path: String)
        case fileNotFound(path: String, searchedLocations: [String])
        case copyFailed(source: String, detail: String)
    }

    static func fromEnrichedToolResult(_ resultText: String) -> Any? { nil }

    static func processToolResultDetailed(
        _ text: String,
        contextId: String,
        contextType: ArtifactContextType,
        executionMode: ExecutionMode,
        sandboxAgentName: String? = nil
    ) -> Result<ProcessingResult, ResolutionFailure> {
        .success(ProcessingResult(enrichedToolResult: text))
    }
}

#endif
