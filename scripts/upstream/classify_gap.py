#!/usr/bin/env python3
"""Classify every upstream OsaurusCore source file that Intel does not compile.

Usage (from the repo root):  python3 scripts/upstream/classify_gap.py [upstream-ref]

Lists files that exist on the upstream ref but are absent from the Intel tree
or excluded in Packages/OsaurusCore/Package.swift, assigns each to a feature
(first matching pattern wins) and prints totals plus any UNASSIGNED files.
An unassigned file is a feature nobody has classified yet: add a pattern and a
row in docs/INTEL_MISSING_FEATURES_BACKLOG.md. Verdicts: I = incompatible
(Apple Silicon only / upstream-only artifact), C = covered by Intel's own
implementation, W = needs work, N = not a user feature (dev tooling).
See the verdict rule in docs/UPSTREAM_SYNC.md.
"""
import collections, os, re, subprocess, sys

REF = sys.argv[1] if len(sys.argv) > 1 else "upstream/main"
PRE = "Packages/OsaurusCore/"

pkg = open(PRE + "Package.swift").read()
excluded = set()
for block in re.findall(r"exclude:\s*\[(.*?)\]", pkg, re.S):
    excluded.update(re.findall(r'"([^"]+)"', block))

def is_excluded(f):
    return any(f == e or (not e.endswith(".swift") and f.startswith(e.rstrip("/") + "/")) for e in excluded)

listing = subprocess.run(["git", "ls-tree", "-r", "--name-only", REF, PRE], capture_output=True, text=True, check=True).stdout.split()
rows = []
for full in listing:
    f = full[len(PRE):]
    if not f.endswith(".swift") or f.startswith("Tests/"):
        continue
    if not os.path.exists(PRE + f):
        kind = "absent"
    elif is_excluded(f):
        kind = "excluded"
    else:
        continue
    text = subprocess.run(["git", "show", f"{REF}:{full}"], capture_output=True, text=True).stdout
    rows.append((kind, f, text.count("\n")))

F=[
("INC-mlx","I",r"ModelRuntime|MLX|Services/Inference/(MLXService|ModelService)|ModelDownloadService|Managers/Model/(ModelManager|ModelManifestUpdates|ModelUpdatePolling|ModelPickerItemCache)|HuggingFace|ModelManifest|ModelFileIntegrity|BundledModelSeeder|ChipProfile|GPUMemoryBudget|SwapPressureMonitor|MemoryPressureResponder|ModelWarmup|WarmupProgressHub|ChatWarmupController|ChatSessionWarmup|MTP|DiskCache|SafeDiskCachePurge|LocalVisionEvidence|EmbeddingDetection|VLMDetection|ModelFormatDetection|Safetensors|ModelSizeCache|ModelMemoryTelemetry|ModelCapabilityLedger|ModelPrefillTuning|ParentResidency|RuntimeProof|PrefillDebugLog|GenerationOutputRelay|DecodePerformanceSection|MemorySafetySection|LocalGenerationDefaults|LocalReasoningCapability|DeclaredReasoningEffort|AlignmentPreparationState|OnboardingModelsProxy|BrainSource|ModelListRow|SystemStatusBar|SwiftTransformersTokenizer|InferenceFeatureFlags|RuntimeConfig|GenerationEventMapper|MetalSafeEmbedder|ModelMetadataCache|ImageGenerationService|ImageGenerationTypes|ImageJobCancellation|ImageModelDownloadService|ImageModelsDownloadView|MLXErrorRecovery|ServerRuntimeSettingsStore|InstalledVisionEvaluation|AppleScriptModelCatalog|AppleScriptModelsView|ResidencyHandoff|SubagentResidency|AppleScriptWarmResidency|ChatResidencyHandoff|AuxiliaryModelHandoff|AdmissionPositionLimit|SubagentAdmission|SubagentBatchAdmissionPlanner|FoundationModelService|NativeImageJobCoordinator|NativeImageToolArtifactBridge|NativeImageTools|ImageGenerationView|ImageGenerationPanelView|ChunkedFileDownloader|LiveVoiceAudioInputRegistry"),
("INC-containers","I",r"Services/Sandbox/(SandboxManager|SandboxAgentProvisioner|SandboxEgressPolicy|SandboxPackage|SandboxPluginRegistration|SandboxProvisioningDiagnostics|SandboxResumableDownloader|SandboxRootfs|SandboxRuntimeAssets|SandboxSecurity|SandboxStartupMetrics|SandboxToolRegistrar|SandboxToolRequestContext|SandboxWorkspaceChange|LiveExecSink|TeeWriter)|SandboxEgressProxy|Plugin/SandboxPlugin|SandboxPlugin|SandboxSecretTools|BuiltinSandboxTools|SandboxStdioRunner|WorkspaceShareRoute|WorkspaceInspectPayload|ShellMutationPlanner"),
("INC-upstream-only","I",r"ProductHuntLaunchCampaign|MockAppleScriptWorld|MockMacDriver|MockChatData"),
("W-methods","W",r"Services/Method/|Storage/MethodDatabase"),
("COV-tool-discovery","C",r"Services/Tool/(ToolIndexService|ToolSearchService)|Services/Skill/SkillSearchService|Services/Context/(CapabilitySearchHealth|SessionToolStateStore|CapabilitySearchEvaluator)|Storage/ToolDatabase|CapabilityQueryIntent"),
("W-description-backfill","W",r"AgentDescriptionBackfill|AgentDescriptionGenerator"),
("N-dev-tooling","N",r"Services/Context/.*Evaluat|EvalHarness|EvalPairedRunIsolation|PromptComposerExperiment"),
("COV-intel-own","C",r"Managers/AgentManager\.swift|Models/Agent/AgentStore|Services/Chat/(ChatEngine|ChatEngineProtocol|SystemPromptComposer|AgentToolLoop|ContextBudgetManager|ComposeRequest|PromptBuilder|PromptManifest|ResolvedToolset|AgentConfigSnapshot|ContextSizeClass|AgentNameDetector|ContextCompactionService|CompactionWatermark|ChatTitleService|AgentReasoningPolicy)|Tools/ToolRegistry\.swift|Models/Chat/(ChatTurn|ChatTurnData|ContentBlock|ChatSessionData|ChatSessionStore|ChatConfiguration|SessionSource|ResponseWriters|SessionCapability)|Managers/BlockMemoizer|Managers/Chat/ChatSessionsManager|Managers/RemoteProviderManager|Services/Provider/(RemoteProviderService|RemoteReasoningPolicy|RemoteToolDetection)|Models/API/(OpenAIAPI|AnthropicAPI|GeminiAPI|OpenResponsesAPI)|Storage/(ChatHistoryDatabase|ChatHistoryWriter|OsaurusStorageOpener|StorageEncryptionPolicy|StorageFile|StorageFileFormat|StorageFormatConverter|StorageMigrationCoordinator|StorageMutationGate|StorageDatabaseCatalog)|Networking/(ServerController|BonjourAdvertiser)|Services/Memory/(MemoryService|MemorySearchService|MemoryConsolidator|DistillationCoordinator|MemoryContextAssembler|MemoryDiagnostics|MemoryPlanner|EmbeddingService|MemoryManagementConsoleService)|Models/Memory/MemoryManagementConsoleModels|Views/Memory/MemoryManagementConsoleView|Managers/SkillManager|Services/Inference/(ClaudeCodeService|ClaudeCodeBridgeGrantStore|CoreModelService)|Managers/WindowManager|Services/NotificationService|Services/DirectoryPickerService|Models/Configuration/AppConfiguration|Models/Chat/ChatConfigurationStore|Utils/ActivityTracker|Managers/ThreadCache|Utils/StreamingDeltaProcessor|Services/Keychain/AgentSecretsKeychain|Views/Settings/ChatSettingsView|Views/Router/RouterAccountUsageCenter|Services/Chat/AgentAbilityContextPreview|Views/Agent/AgentAbilitiesOverviewView|Services/Plugin/PluginHostAPI|Services/Plugin/PluginInstructionsResolver|Services/Plugin/PluginRepositoryService|Services/Themes/ThemeShareService|Services/Themes/ThemesDeepLinkRouter|Services/SearchService|Models/Chat/LegacySessionImporter|Services/MCP/MCPServerManager|Storage/PluginDatabase|Networking/HTTP(LoopHelpers|ProtocolErrors|RequestParse)|Managers/ManagementBadgeStore"),
("W-subagents","W",r"Subagent|AgentDelegation|SpawnAgentTool|SpawnConfigurationEditor|SubagentSettingsSection|SubagentFeedView|SubagentBackgroundTaskBridge|DelegationRecord|SpawnBatchConcurrency"),
("W-computer-use","W",r"ComputerUse|ScreenContextPreview|CloudVisionConsent"),
("W-browser-use","W",r"Browser"),
("W-applescript-agent","W",r"AppleScript/|MacQueryTool"),
("W-privacy-filter","W",r"PrivacyFilter|Redaction(Highlighter|HoverController)|SecretScrubber"),
("W-channels","W",r"AgentChannel|Services/(Slack|Telegram|Discord|WhatsApp|IMessage|Channels)/|Models/(Slack|Telegram|Discord|WhatsApp|IMessage|Channels)/|N8n|OsaurusRunningInstanceInspector|Storage/AgentChannelMessageStore|Views/Settings/(Slack|Telegram|Discord|WhatsApp|IMessage)SettingsView|ConfigChannelDetails"),
("W-workspaces-identity-mobile","W",r"ModelOptionsSnapshot|PeerInferenceSharing|Workspace|Router/|OsaurusID|Identity/|MobileConnect|Pairing|RelayTunnel|SecureChannel|OwnerDeviceAccessHost|RemoteAgentManager|AgentInvite|AgentSharedWithSection|PeerCallNotifier|BonjourBrowser|HostAPIBridgeServer|OsaurusConnectView|LocalNetworkAddress|SharedEventLoopGroups|HTTPCallerContext|AgentRunUsage|RemoteSessionContinuation|RemoteSecretPromptQueue|RemoteRunArtifacts|AgentCollaboration|HostedRunNotice|RemoteAgentRunLog"),
("W-declarative-config","W",r"Configuration/Declarative|Tools/Configuration|Tools/ConfigurationTools|ConfigApprovalModal|OrchestratorSupportSections"),
("W-file-history","W",r"FileHistory|FileChangesPanel|FileDiff|NativeFileDiffView|ChatHistoryPane|ChatInspectorPanel|ProjectInspectorPanel|ProjectDetailView|FileHistoryRetentionSection"),
("W-doc-editing","W",r"Services/Documents/|FileCopyTool"),
("W-chat-tabs","W",r"ChatTab|ThreadScrollPosition|LiveChatSessionRegistry|SessionActivityMonitor|NewAgentHighlightStore"),
("W-chat-export","W",r"ChatSessionExport|ChatExportOptions"),
("W-voice","W",r"Speech|TTSService|OpenAICompatibleTTSClient|Transcription|VAD|LiveVoiceAudio|Models/Voice|Services/Voice"),
("W-knowledge-write","W",r"Knowledge(Write|Curation|Diff|FolderWatcher|GitSync|LinkResolver|TypeInference)|KnowledgeWriteLogDatabase|Views/Knowledge/"),
("W-skills-plugins-import","W",r"Skill|ClaudeMarketplace|ClaudePlugin|GitHubImportSheet|GitHubTokenViews|GitHubAuth|PluginProcessHost|PluginHost/main|ExternalTool"),
("W-media-generation","W",r"MediaGeneration|VideoTool|ImageAPI"),
("W-agent-loop-tools","W",r"AgentLoopTools|AgentTaskState|RunProgress|StreamRepetitionDetector|ToolOutputCaps|ToolOutputCompressor|ToolExecutionScope|SchemaValidator|ToolWirePropertyOrder|CurrentTimeTool|SubagentApprovalArguments|Grounded.*Check|ToolResultMediaBridge|ChatErrorMessages|ChatTurnGenerationControls"),
("W-tool-catalog-ui","W",r"ToolDisplayName|Views/Tool/|Models/Tool/|ToolAvailabilityBadge|CapabilityTools|CapabilityQueryIntent|AgentCapabilityReadiness"),
("W-chat-ux","W",r"AtFile|ChatCrossSelection|ChatInputHistory|FollowUpSuggestion|CompactionDialogView|NativeCompactionMarkerView|NativeActivityGroupView|NativeDispatchBadgeRow|DispatchEnvelope|ShimmerLabel|RecentFoldersPanel|ImportGuideSheet|ImportHistoryPromptGate|ChatPersistenceNotice|MarkdownBlockParsing|MarkdownDocumentView|IMEAwareTextField|ScreenshotCaptureService|SlashCommandRegistry|WorkspaceFileReference|WorkspaceSessionContext|AgentDispatchTarget|BuiltInAgentGuard|Views/Agent/AgentDetailChrome|ContextAttribution"),
("W-server-api","W",r"ServerModelsTabContent|InferenceActivityRegistry|Networking/|MCPServerHub|ModelExposureStore|EvidenceReport|Services/Auth/"),
("W-mcp-providers","W",r"Services/MCP/"),
("W-providers-ux","W",r"Provider|FireworksAPI|CodexCLIConfiguration|FavoriteModelsStore|WireTransportProbe"),
("W-self-scheduling","W",r"SchedulerTools|Schedule"),
("W-tools-misc","W",r"RenderChartTool|SearchMemoryTool|ShareArtifactTool|SharedArtifact|RedactionTool|ShellSandboxProfile|Seatbelt"),
("W-storage-health","W",r"PersistenceHealth|StorageRecoveryService|FileVaultStatus|StorageLocationStandards|ConfigDiskWriter"),
("W-diagnostics-telemetry","W",r"ProcessCpuProbe|ProcessMemoryProbe|OnboardingTelemetry|CrashReporting|FeatureTelemetry|TelemetryService|SupportDiagnosticsBundle|TerminationForensics|ConsoleLogFile|MainThreadOperationLedger|AsyncDeadline"),
("W-ui-misc","W",r"Views/Common/|Views/Onboarding/|ThemeLibraryManagement|SystemAccentColor|OsaurusGuide|AgentRunPowerManager|Views/Tour/|WhatsNewHero|RedeemRetryCountdownHint|KeychainServices|SecretAvailability|SecretSaveOutcome|OsaurusKeychain|Search/SearchStructuredDataStore|Views/Settings/(BrowserSettingsView|ComputerUse)|Services/Keychain/"),
]

assign = collections.defaultdict(list)
unassigned = []
for kind, f, n in rows:
    for fid, verdict, pat in F:
        if re.search(pat, f):
            assign[fid].append((f, n, kind))
            break
    else:
        unassigned.append((f, n))

print(f"{len(rows)} upstream source files not compiled on Intel ({REF})")
for fid, verdict, _ in F:
    items = assign[fid]
    print(f"{fid:32s} {verdict} {len(items):4d} files {sum(n for _, n, _ in items):7d} lines")
print("UNASSIGNED", len(unassigned))
for f, n in unassigned:
    print("  ", n, f)
sys.exit(1 if unassigned else 0)
