// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OsaurusCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OsaurusCore", targets: ["OsaurusCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.88.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        // MCP pulls EventSource transitively. Enable its AsyncHTTPClient trait.
        .package(
            url: "https://github.com/mattt/eventsource.git",
            from: "1.4.1",
            traits: [.trait(name: "AsyncHTTPClient")]
        ),
        .package(url: "https://github.com/orlandos-nl/IkigaJSON", from: "2.3.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1"),
        .package(path: "../OsaurusRepository"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/AAChartModel/AAChartKit-Swift.git", from: "9.5.0"),
        .package(path: "../IntelStubs"),
    ],
    targets: [
        // Vendored SQLCipher 4.6.1 amalgamation (CommonCrypto
        // provider, FTS5 enabled). See `SQLCipher/README.md` for
        // re-build instructions and the FTS5 header-guard maintenance
        // contract. OsaurusCore links this *instead of* Apple's
        // system `import SQLite3` so every SQLite call goes through
        // the SQLCipher-extended build (giving us `sqlite3_key_v2`
        // for at-rest encryption).
        //
        // ⚠️  FTS5 typedef collision. `sqlite3.h` declares
        //     `Fts5ExtensionApi`, `fts5_api`, `Fts5Context`,
        //     `Fts5PhraseIter` and `fts5_extension_function`
        //     UNCONDITIONALLY (they are NOT gated by
        //     `SQLITE_ENABLE_FTS5`). When another module in the
        //     same Swift compilation unit imports Apple's system
        //     `SQLite3` (notably vmlx-swift's `DiskCache`),
        //     Swift's Clang importer sees two different definitions
        //     of those typedefs and rejects the build with
        //         'Fts5ExtensionApi' has different definitions in different modules
        //     The fix is three-part:
        //       1. `include/sqlite3.h` wraps the `_FTS5_H` block in
        //          `#ifndef OSAURUS_OMIT_FTS5_HEADERS` (search for
        //          OSAURUS LOCAL MODIFICATION inside that file).
        //       2. `include/OsaurusSQLCipher.h` defines
        //          `OSAURUS_OMIT_FTS5_HEADERS` before including
        //          sqlite3.h so Swift's Clang module import sees the
        //          hidden extension API.
        //       3. The `cSettings` `.define("OSAURUS_OMIT_FTS5_HEADERS")`
        //          below keeps the C compilation path aligned.
        //     `sqlite3.c` itself inlines its own copy of the header
        //     text, so FTS5's SQL-level functionality keeps working;
        //     we only hide the C-extension API, which Osaurus
        //     doesn't use.
        //     `Tests/Storage/SQLCipherVendorGuardTests.swift` asserts
        //     the header guard, umbrella define, and cSettings flag
        //     are in place — CI fails if a SQLCipher bump strips them.
        //
        // ⚠️  sqlite3ext.h collision. Newer macOS SDKs append fields
        //     to `sqlite3_api_routines` before our pinned SQLCipher
        //     adopts that SQLite version. Osaurus does not compile
        //     SQLite loadable extensions, so the umbrella header hides
        //     sqlite3ext.h's loadable-extension API from the Swift
        //     Clang importer while still including the header to keep
        //     module import warnings quiet.
        .target(
            name: "OsaurusSQLCipher",
            path: "SQLCipher",
            sources: ["sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_ENABLE_JSON1"),
                .define("SQLITE_ENABLE_COLUMN_METADATA"),
                .define("SQLITE_ENABLE_LOAD_EXTENSION"),
                .define("SQLITE_ENABLE_DBSTAT_VTAB"),
                .define("HAVE_USLEEP", to: "1"),
                // Strip assert()s. Several SQLite asserts reference
                // identifiers only declared inside debug-only build
                // configs (e.g. `bCorrupt`, `startedWithOom`); the
                // shipped library normally compiles with NDEBUG, so
                // do the same here. NDEBUG must be a compile flag,
                // not a late `#define` in source — Apple's
                // `<assert.h>` is a precompiled Clang module whose
                // expansion is fixed at module-compilation time.
                .define("NDEBUG"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // Hide the FTS5 C-extension typedefs from
                // `include/sqlite3.h` so the Swift Clang importer
                // doesn't conflict with the system SQLite3 module —
                // see the long comment above. `sqlite3.c`'s inlined
                // copy of sqlite3.h text is unaffected, so the C
                // compilation of FTS5 keeps working.
                .define("OSAURUS_OMIT_FTS5_HEADERS"),
                // The SQLite amalgamation calls a few self-references
                // before their forward declarations show up; modern
                // Apple clang upgrades this from a warning to an
                // error. Allow the implicit decls only inside this
                // vendored target so we keep strict diagnostics on
                // the rest of the codebase.
                .unsafeFlags([
                    "-Wno-shorten-64-to-32",
                    "-Wno-ambiguous-macro",
                    "-Wno-implicit-function-declaration",
                    "-Wno-unused-but-set-variable",
                    "-Wno-deprecated-non-prototype",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .target(
            name: "OsaurusCore",
            dependencies: [
                "OsaurusSQLCipher",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "IkigaJSON", package: "IkigaJSON"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "OsaurusRepository", package: "OsaurusRepository"),
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "AAInfographics", package: "AAChartKit-Swift"),
                .product(name: "MLX", package: "IntelStubs"),
                .product(name: "MLXRandom", package: "IntelStubs"),
                .product(name: "MLXLLM", package: "IntelStubs"),
                .product(name: "MLXVLM", package: "IntelStubs"),
                .product(name: "MLXLMCommon", package: "IntelStubs"),
                .product(name: "VMLXTokenizers", package: "IntelStubs"),
                .product(name: "FluidAudio", package: "IntelStubs"),
                .product(name: "Containerization", package: "IntelStubs"),
                .product(name: "ContainerizationExtras", package: "IntelStubs"),
                .product(name: "VecturaKit", package: "IntelStubs"),
            ],
            path: ".",
            exclude: [
                "Tests",
                "SQLCipher",
                "Managers/Model/ModelManager.swift",
                "Managers/Model/SpeechModelManager.swift",
                "Managers/SpeechService.swift",
                "Managers/TTSService.swift",
                "Models/Chat/LiveVoiceAudioInputRegistry.swift",
                "Models/Configuration/ServerRuntimeSettingsStore.swift",
                "Models/Configuration/VLMDetection.swift",
                "Networking/ServerController.swift",
                "Services/Inference/MLXService.swift",
                "Services/MCP/Stdio/SandboxStdioRunner.swift",
                "Services/Memory/EmbeddingService.swift",
                "Services/Memory/MemorySearchService.swift",
                "Services/Memory/MetalSafeEmbedder.swift",
                "Services/Method/MethodSearchService.swift",
                "Services/ModelRuntime.swift",
                "Services/ModelRuntime/GenerationEventMapper.swift",
                "Services/ModelRuntime/InferenceFeatureFlags.swift",
                "Services/ModelRuntime/MLXBatchAdapter.swift",
                "Services/ModelRuntime/MLXErrorRecovery.swift",
                "Services/ModelRuntime/RuntimeConfig.swift",
                "Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift",
                "Services/Sandbox/LiveExecSink.swift",
                "Services/Sandbox/SandboxManager.swift",
                "Services/Sandbox/TeeWriter.swift",
                "Services/Skill/SkillSearchService.swift",
                "Services/Tool/ToolSearchService.swift",
                "Tools/BuiltinSandboxTools.swift",
                "Views/Chat/ChatView.swift",
                "Folder/FolderTools.swift",                 "Managers/BackgroundTaskManager.swift",                 "Managers/Chat/ChatWindowManager.swift",                 "Managers/Chat/ChatWindowState.swift",                 "Managers/ExecutionContext.swift",                 "Managers/MCPProviderManager.swift",                 "Managers/ManagementBadgeStore.swift",                 "Managers/Model/ModelPickerItemCache.swift",                 "Managers/Plugin/SandboxPluginManager.swift",                 "Managers/SkillManager.swift",                 "Models/BackgroundTaskModels.swift",                 "Models/Configuration/MLXModel.swift",                 "Models/Configuration/ModelInfo.swift",                 "Networking/HostAPIBridgeServer.swift",                 "Services/Chat/ChatEngine.swift",                 "Services/Chat/SystemPromptComposer.swift",                 "Services/Context/CapabilitySearchEvaluator.swift",                 "Services/Context/PreflightCapabilitySearch.swift",                 "Services/Context/PreflightCompanions.swift",                 "Services/Context/PreflightEvaluator.swift",                 "Services/DirectoryPickerService.swift",                 "Services/HuggingFaceService.swift",                 "Services/Inference/CoreModelService.swift",                 "Services/LocalGenerationDefaults.swift",                 "Services/LocalReasoningCapability.swift",                 "Services/Memory/MemoryConsolidator.swift",                 "Services/Memory/MemoryPlanner.swift",                 "Services/Memory/MemoryService.swift",                 "Services/Method/MethodService.swift",                 "Services/ModelDownloadService.swift",                 "Services/Plugin/PluginHostAPI.swift",                 "Services/Sandbox/SandboxAgentProvisioner.swift",                 "Services/Sandbox/SandboxPluginRegistration.swift",                 "Services/Sandbox/SandboxToolRegistrar.swift",                 "Services/Skill/ClaudePluginInstaller.swift",                 "Services/SystemPermissionService.swift",                 "Services/Tool/ToolIndexService.swift",                 "Services/Voice/TranscriptionCleanupService.swift",                 "Services/Voice/TranscriptionModeService.swift",                 "Services/Voice/VADService.swift",                 "Storage/StorageMigrator.swift",                 "Tools/AgentLoopTools.swift",                 "Tools/CapabilityTools.swift",                 "Tools/SandboxPluginTool.swift",                 "Tools/SearchMemoryTool.swift",                 "Views/Agent/AgentsView.swift",                 "Views/Chat/ChatEmptyState.swift",                 "Views/Chat/FloatingInputCard.swift",                 "Views/Chat/NativeBlockViews.swift",                 "Views/Chat/NativeMessageCellView.swift",                 "Views/Chat/NativeToolCallGroupView.swift",                 "Folder/FolderContextService.swift",                 "Identity/OsaurusIdentity.swift",                 "Managers/AgentManager.swift",                 "Managers/Plugin/PluginManager.swift",                 "Managers/SlashCommandRegistry.swift",                 "Managers/TaskDispatcher.swift",                 "Managers/ToastManager.swift",                 "Models/Agent/AgentInvite.swift",                 "Models/Chat/ChatConfiguration.swift",                 "Models/Chat/ChatTurn.swift",                 "Models/Chat/ContentBlock.swift",                 "Models/Configuration/ModelOptions.swift",                 "Models/Configuration/ModelPickerItem.swift",                 "Models/Plugin/ExternalPlugin.swift",                 "Networking/HTTPLoopHelpers.swift",                 "Networking/HTTPProtocolErrors.swift",                 "Networking/HTTPRequestParse.swift",                 "Networking/RelayTunnelManager.swift",                 "Services/Chat/AgentNameDetector.swift",                 "Services/Chat/ComposeRequest.swift",                 "Services/Chat/ContextSizeClass.swift",                 "Services/Chat/GenerativeGreetingPool.swift",                 "Services/Chat/GenerativeGreetingService.swift",                 "Services/Chat/PromptManifest.swift",                 "Services/Chat/ResolvedToolset.swift",                 "Services/Context/SessionToolStateStore.swift",                 "Services/GitHubSkillService.swift",                 "Services/Memory/DistillationCoordinator.swift",                 "Services/Memory/MemoryContextAssembler.swift",                 "Services/Memory/MemoryDiagnostics.swift",                 "Services/NotificationService.swift",                 "Services/Plugin/PluginHostAPI+SessionPersistence.swift",                 "Services/Plugin/PluginRepositoryService.swift",                 "Services/SearchService.swift",                 "Services/Themes/ThemeShareService.swift",                 "Storage/StorageExportService.swift",                 "Tools/FolderToolManager.swift",                 "Tools/MCPProviderTool.swift",                 "Tools/SandboxPluginRegisterTool.swift",                 "Tools/ToolEnvelope.swift",                 "Tools/ToolRegistry.swift",                 "Utils/MockChatData.swift",                 "Views/Agent/AgentCapabilityManagerView.swift",                 "Views/Agent/RemoteAgentViews.swift",                 "Views/Chat/MarkdownMessageView.swift",                 "Views/Chat/MessageTableRepresentable.swift",                 "Views/Chat/NativeMarkdownView.swift",                 "Views/Chat/SlashCommandPopup.swift",                 "Views/Storage/StorageMigrationOverlay.swift",                 "Folder/FolderPluginHints.swift",                 "Managers/BlockMemoizer.swift",                 "Managers/Chat/ChatSessionExportCoordinator.swift",                 "Managers/Chat/ChatSessionExporter.swift",                 "Managers/HotKeyManager.swift",                 "Managers/InsightsService.swift",                 "Managers/NextRunScheduler.swift",                 "Managers/RemoteAgentManager.swift",                 "Managers/ScheduleManager.swift",                 "Managers/ThreadCache.swift",                 "Managers/ToastManager+Localized.swift",                 "Managers/TranscriptionHotKeyManager.swift",                 "Managers/WatcherManager.swift",                 "Models/API/OpenAIAPI.swift",                 "Models/Agent/AgentInviteStore.swift",                 "Models/Chat/ChatConfigurationStore.swift",                 "Models/Chat/ChatSessionStore.swift",                 "Models/Chat/ChatTurnData.swift",                 "Models/Chat/SessionSource.swift",                 "Models/Chat/SharedArtifact.swift",                 "Models/Configuration/AppConfiguration.swift",                 "Models/Voice/TranscriptionConfiguration.swift",                 "Networking/BonjourAdvertiser.swift",                 "Networking/BonjourBrowser.swift",                 "Services/AgentBridge/LocalAgentBridge.swift",                 "Services/Chat/AgentConfigSnapshot.swift",                 "Services/Chat/ContextBudgetManager.swift",                 "Services/Context/CapabilitySearchHealth.swift",                 "Services/Inference/ModelService.swift",                 "Services/Keychain/ToolSecretsKeychain.swift",                 "Services/MCP/MCPServerManager.swift",                 "Services/ModelOptionsStore.swift",                 "Services/Pairing/IncomingPairCoordinator.swift",                 "Services/Pairing/PairingDeepLinkRouter.swift",                 "Services/Plugin/PluginInstructionsResolver.swift",                 "Services/Provider/RemoteProviderService.swift",                 "Services/Themes/ThemesDeepLinkRouter.swift",                 "Services/ToolPermissionPromptService.swift",                 "Storage/AgentDatabase.swift",                 "Storage/ChatHistoryDatabase.swift",                 "Storage/ChatHistoryWriter.swift",                 "Storage/MemoryDatabase.swift",                 "Storage/MethodDatabase.swift",                 "Storage/PluginDatabase.swift",                 "Storage/SchedulerDatabase.swift",                 "Storage/ToolDatabase.swift",                 "Tools/Database/DatabaseTools.swift",                 "Tools/Database/SchedulerTools.swift",                 "Tools/ExternalTool.swift",                 "Tools/OsaurusTool.swift",                 "Tools/RenderChartTool.swift",                 "Tools/SandboxSecretTools.swift",                 "Tools/ShareArtifactTool.swift",                 "Tools/ToolErrorEnvelope.swift",                 "Utils/StreamingDeltaProcessor.swift",                 "Views/Agent/AgentDBTabViews.swift",                 "Views/Agent/AgentReorderSheet.swift",                 "Views/Agent/NextRunPanelView.swift",                 "Views/Agent/ShareAgentSheet.swift",                 "Views/Chat/ChatSessionSidebar.swift",                 "Views/Chat/MessageThreadView.swift",                 "Views/Chat/NativeThinkingView.swift",                 "Views/Chat/TerminalSnapshot.swift",                 "Managers/Chat/ChatSessionsManager.swift",                 "Managers/RemoteProviderManager.swift",                 "Models/API/AnthropicAPI.swift",                 "Models/API/GeminiAPI.swift",                 "Models/API/OpenResponsesAPI.swift",                 "Models/Agent/AgentStore.swift",                 "Models/Chat/ChatSessionData.swift",                 "Models/Chat/DispatchRequest.swift",                 "Models/Chat/LegacySessionImporter.swift",                 "Models/Chat/ResponseWriters.swift",                 "Models/Chat/SessionCapability.swift",                 "Models/Plugin/SandboxPlugin.swift",                 "Services/AgentBridge/AgentRuntimeBridge.swift",                 "Services/AgentBridge/SchemaDumper.swift",                 "Services/AgentBridge/SchemaSnapshot.swift",                 "Services/Chat/ChatEngineProtocol.swift",                 "Services/Chat/PromptBuilder.swift",                 "Services/Inference/FoundationModelService.swift",                 "Services/Keychain/AgentSecretsKeychain.swift",                 "Services/Provider/RemoteToolDetection.swift",                 "Storage/AgentDatabaseStore.swift",                 "Storage/AttachmentBlobStore.swift",                 "Tools/SchemaValidator.swift",                 "Utils/ActivityTracker.swift",                 "Views/Chat/ExportChooserSheet.swift",                 "Views/Chat/MarkdownImageView.swift",                 "Views/Chat/NativeArtifactCardView.swift",                 "Views/Chat/SelectableTextView.swift",                 "Views/Chat/TerminalDisplayView.swift",                 "Models/Configuration/MLXModelDownloadCache.swift", "Managers/WindowManager.swift",                 "Models/Voice/VADConfiguration.swift",                 "Services/Context/ClipboardService.swift",                 "Utils/DocumentParser.swift",                 "Views/Chat/DocumentChip.swift",                 "Views/Chat/PastedContentSheet.swift",                 "Views/Chat/PromptQueue.swift", "Views/Chat/ClarifyPromptOverlay.swift",                  "Managers/Chat/ChatSessionsManager.swift",                 "Managers/RemoteProviderManager.swift",                 "Models/API/AnthropicAPI.swift",                 "Models/API/GeminiAPI.swift",                 "Models/API/OpenResponsesAPI.swift",                 "Models/Agent/AgentStore.swift",                 "Models/Chat/ChatSessionData.swift",                 "Models/Chat/DispatchRequest.swift",                 "Models/Chat/LegacySessionImporter.swift",                 "Models/Chat/ResponseWriters.swift",                 "Models/Chat/SessionCapability.swift",                 "Models/Plugin/SandboxPlugin.swift",                 "Services/AgentBridge/AgentRuntimeBridge.swift",                 "Services/AgentBridge/SchemaDumper.swift",                 "Services/AgentBridge/SchemaSnapshot.swift",                 "Services/Chat/ChatEngineProtocol.swift",                 "Services/Chat/PromptBuilder.swift",                 "Services/Inference/FoundationModelService.swift",                 "Services/Keychain/AgentSecretsKeychain.swift",                 "Services/Provider/RemoteToolDetection.swift",                 "Storage/AgentDatabaseStore.swift",                 "Storage/AttachmentBlobStore.swift",                 "Tools/SchemaValidator.swift",                 "Utils/ActivityTracker.swift",                 "Views/Chat/ExportChooserSheet.swift",                 "Views/Chat/MarkdownImageView.swift",                 "Views/Chat/NativeArtifactCardView.swift",                 "Views/Chat/SelectableTextView.swift",                 "Views/Chat/TerminalDisplayView.swift",                 "Managers/Plugin/SandboxPluginLibrary.swift",                 "Models/Chat/Attachment.swift",                 "Models/Chat/ChatExportOptions.swift",                 "Services/AgentBridge/AgentBundleService.swift",                 "Services/Sandbox/SandboxSecurity.swift",                 "Views/Chat/SecretPromptOverlay.swift",                 "Views/Sandbox/SandboxView.swift",  
            ],
            resources: [.process("Resources")],
            swiftSettings: [
                .define("OSAURUS_INTEL")
            ]
        ),
        .testTarget(
            name: "OsaurusCoreTests",
            dependencies: [
                "OsaurusCore",
                "OsaurusSQLCipher",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "VMLXJinja", package: "IntelStubs"),
                .product(name: "VecturaKit", package: "IntelStubs"),
            ],
            path: "Tests",
            exclude: [
                "Voice/LiveVoiceResidentPreencodeIntegrationTests.swift",
                "Sandbox/BuiltinSandboxToolsTests.swift",
                "Sandbox/TeeWriterTests.swift",
                "Model/FoundationMLXParityTests.swift",
                "Model/MaterializeMediaDataUrlMCDCTests.swift",
                "Model/MultimodalContentPartTests.swift",
                "Model/ModelRuntimeMappingTests.swift",
                "Service/MLXErrorRecoveryTests.swift",
                "Service/VecturaRecoveryTests.swift",
                "Service/DSV4ParserPipelineTests.swift",
                "Service/SwiftTransformersTokenizerLoaderTests.swift",
                "Service/VecturaTopKGuardTests.swift",
                "Service/JinjaTemplateCompatibilityTests.swift",
                "Service/GenerationEventMapperTests.swift",
                "Service/MLXBatchAdapterTests.swift",
                "Helpers/FakeEmbedder.swift",
            ]
        ),
    ]
)
