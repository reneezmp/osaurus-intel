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
    }

    // Cloud-routing no-ops kept for compatibility with chat-side callers.
    func connect(providerId: UUID) async throws {}
    func disconnect(providerId: UUID) {}
    func reconnect(providerId: UUID) async throws {}
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

    private init() {}
}

/// Intel stub mirroring just the surface `SkillsView` reads off
/// `PluginRepositoryService.shared.plugins.first(where:)`. Upstream
/// definition at `Services/Plugin/PluginRepositoryService.swift:14`
/// has the full plugin metadata; Intel keeps only `pluginId` +
/// `displayName` since the only caller is the breadcrumb in SkillRow.
struct PluginState: Identifiable, Equatable {
    let pluginId: String
    var id: String { pluginId }
    let displayName: String

    init(pluginId: String, displayName: String? = nil) {
        self.pluginId = pluginId
        self.displayName = displayName ?? pluginId
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
    func execute(name: String, argumentsJSON: String) async throws -> String {
        "Tool '\(name)' executed."
    }

    /// Used by `ConfigurationView`'s per-tool permission rows
    /// (un-body-swapped in M11 Phase 11.A.3.1) to clear a custom
    /// allow/deny policy. Intel keeps no per-tool policy state
    /// (sandbox tools are amputated and cloud tools are unconditional);
    /// the call is a no-op so the UI's "Reset to default" button
    /// works without crashing.
    func clearPolicy(for toolName: String) {}
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
