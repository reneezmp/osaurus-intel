# Intel Fork — Archeology Report

**Date:** 2026-05-23  
**Build:** `swift build --arch x86_64` — **succeeds** with 293 surviving files, 321 excluded.  
**Method:** Iterative `exclude:`-driven dependency-cone mapping in `Packages/OsaurusCore/Package.swift`.

## Findings

The four amputated subsystems — MLX (vmlx-swift), FluidAudio, Containerization, and VecturaKit — form a dependency cone that pulls **55.8% of OsaurusCore** (321 of 575 source files) into exclusion. This is roughly 7× the original plan's estimate of 3–5 rebase-conflict files. The cone reaches into virtually every subsystem: `AppDelegate`, `HTTPHandler`, `ChatEngine`, `Router`, `AgentLoopTools`, the entire memory/search stack, all sandbox infrastructure, all voice, and all server-settings UI. Even cloud-only API paths (Anthropic, OpenAI, Gemini) cannot survive without the excluded files because the chat engine and HTTP handler reference MLX runtime types, embedding services, and search indexes backed by VecturaKit.

## What Survived (293 files)

- **Identity** (18 files): MasterKey, DeviceKey, AgentKey, RecoveryManager, PairingKey, iCloud Keychain integration — fully intact.
- **Networking core** (5 files): `OsaurusServer`, `RelayTunnelManager`, HTTP protocol helpers — the NIO lifecycle survives.
- **Generic UI** (`Views/Common/`, `Views/Settings/ServerSettings/` non-MLX sections) — shared components, theme infrastructure, proxy/advanced-HTTP config.
- **Model-agnostic runtime** (14 `Services/ModelRuntime/` files): MetalGate, format adapters, capability detection — pieces decoupled from MLX's batch engine.
- **Documents** (15 files): The document pipeline and format registry are untouched.

## The Rewrite Surface

To make the Intel fork runnable, each excluded file needs one of:
- **Inline `#if OSAURUS_INTEL` stubs** (Pattern B from the plan) — keeping type declarations, providing no-op implementations for Intel.
- **Architecture refactors** to decouple core types (e.g., `ServerController`, `ModelRuntime`, search services) from their MLX/VecturaKit dependencies.
- **Acceptance of graceful degradation**: chat without local models, embeddings via renee-rag plugin, no sandbox, no voice.

The 321-file exclude list in `Package.swift` serves as the authoritative map of the dependency cone. Incremental rewrites should target files in order of criticality: `AppDelegate` → `HTTPHandler` → `ChatEngine` → `Router` → `AgentLoopTools` → search services → UI.

## Conclusion

The amputation is architecturally correct — the four subsystems ARE the only Apple-Silicon-only dependencies — but OsaurusCore's monorepo structure creates a shallow, wide type graph where core infrastructure transitively references subsystem-specific types through internal visibility (no `public` needed — every type is visible module-wide). The plan's surgical approach underestimated this graph depth by an order of magnitude. Future ports should either (a) adopt in-module stub packages (proven viable — `Packages/IntelStubs/` resolves all `import`-level errors) paired with selective body-wrapping, or (b) isolate the four subsystems into true SwiftPM library targets so the dependency edges are explicit and amputation becomes library-level removal rather than file-level exclude cascading.

## M9 Plugin Capability Testing (2026-05-23)

**Status:** Phase 1–3 committed, Phase 4 test manifests created, Phase 5 (docs) pending.

### Test Setup

Two test plugin manifests installed in `~/.osaurus/Tools/`:

- `com.test.hello` — requires `["http"]` (Intel-compatible) → expected: **compatible**
- `com.test.needs-mlx` — requires `["mlx_inference", "vector_storage"]` → expected: **incompatible** (Apple Silicon required)

### Intel Host Capabilities

```
http, sqlite, config, logging, dispatch, file_io
```

### Expected PluginManager Behavior (Phase 2 implementation)

| Plugin | host_capabilities_required | Intel Compatibility | Bucket |
|---|---|---|---|
| `com.test.hello` | `["http"]` | `http` is supported | Compatible |
| `com.test.needs-mlx` | `["mlx_inference", "vector_storage"]` | Both missing | Apple Silicon Required |

### Verification

- `swift build --arch x86_64` — passes
- `xcodebuild` — BUILD SUCCEEDED
- `PluginCompatibilityChecker.check(required: ["http"])` → `.compatible`
- `PluginCompatibilityChecker.check(required: ["mlx_inference", "vector_storage"])` → `.incompatible`
- `PluginCompatibilityChecker.check(required: nil, optional: ["mlx_inference"])` → `.degraded`
- Empty requirements (nil) → `.compatible` (backwards compat)

Full end-to-end dylib loading + tool invocation testing is deferred until the full PluginManager C ABI is restored on Intel (requires `ExternalTool`, `PluginHostContext`, etc. — Wave D-level work).

---

## Marathon Session 2026-05-23 → 2026-05-24

**Agent:** Sunny (DeepSeek-V4-Pro via OpenCode)  
**Branch:** `intel-fork`  
**Remote:** `origin https://github.com/reneezmp/osaurus.git`

### What was built (M2 through M10 partial)

This session transformed the Intel fork from a 293-file "compiles but doesn't run" substrate into a native Intel .app with: HTTP+MCP+agent loop (M2-M6), 126 view files restored with Apple Silicon Only placeholders (M6.5+M8a Waves A-D), capability-aware plugin loading as a real upstream-worthy feature (M9), and a protocol+conformer architecture for ChatView (M10 Phases 1-4d, Waves 2-7, Auto-Sync Waves 1-2). The .app launches, streams from DeepSeek via cloud proxy, serves MCP tools, and has functional PluginManager + PluginsView. ChatView is un-body-swapped and compiling to 289 errors (down from 32,157 at start) but stuck at a Nash equilibrium where each stub API fix trades errors rather than reducing them.

**Strategic docs in the vault** (read these in order if you're the M10.5 agent):
1. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_M10_AutoSync.md` — **the M10.5 execution plan**, written after this session ended. Read FIRST. Contains the source-of-truth-reading strategy, phase-by-phase paste-prompts, forbidden/required patterns, and the Agent Logging Protocol (you append your work history to dedicated sections in that doc as you execute).
2. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_Fork_PathB.md` — the broader project map across M1-M10.5. Has the progress update section that summarizes this entire marathon.
3. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_Plugin_Capability_Loading.md` — M9's design doc (capability-aware plugin loading). Useful background; not strictly required for M10.5.

### File organization map

**M10 Core files:**

| File | Lines | Description |
|---|---|---|
| `Services/Chat/CloudChatEngine.swift` | 147 | Cloud-backed `ChatEngine` actor conforming to `ChatEngineProtocol`. Uses `DEEPSEEK_API_KEY` env var. Streaming via `URLSession.shared.bytes(for:)`, non-streaming via `data(for:)`. Wrapped in `#if OSAURUS_INTEL`. |
| `Managers/Chat/ChatWindowManager.swift` | 975 | Body-swapped. Original Apple Silicon code in `#if !OSAURUS_INTEL`. Intel `#else` block provides minimal `ChatWindowManager` that creates real `NSWindow` instances, manages window lifecycle (create, close, focus, stopAll). |
| `Managers/Chat/ChatWindowState.swift` | 546 | Body-swapped. Intel `#else` block provides `@Published` ObservableObject matching the original's properties (agentId, theme, filteredSessions, discoveredAgents, selectedDiscoveredAgent, etc.). |
| `Models/Chat/Protocols/` | 476 total across 19 files | See protocol list below. |
| `Models/Chat/IntelConformers/` | 626 total across 3 files | See conformer list below. |

**M10 Protocols** (`Models/Chat/Protocols/`):

| File | What it covers |
|---|---|
| `ChatTurnProtocol.swift` | `ChatTurn` — role, content, tool calls, timing, attachments, thinking. ~42 lines. |
| `AttachmentProtocol.swift` | `Attachment` — file metadata, audio/video loading. |
| `ModelPickerItemProtocol.swift` | `ModelPickerItem` + `ModelPickerSource` enum. Source is `enum ModelPickerSource: Sendable { case builtIn; case remote(String, String); case foundation }`. |
| `AgentManagerProtocol.swift` | `AgentManager` + `AgentInfoProtocol` — agent lookup, model selection, temperature, tokens. |
| `SpeechServiceProtocol.swift` | `SpeechService` — isRecording, stop/cancel. |
| `ChatWindowManagerProtocol.swift` | `ChatWindowManager` — window lifecycle, model names. |
| `ModelPickerItemCacheProtocol.swift` | `ModelPickerItemCache` — isLoaded, items, buildModelPickerItems. |
| `RemoteProviderManagerProtocol.swift` | `RemoteProviderManager` + `RemoteProviderConfigInfoProtocol` + `RemoteProviderInfoProtocol`. |
| `ToolRegistryProtocol.swift` | `ToolRegistry` — resolveExecutionMode, execute. |
| `ChatSessionDataProtocol.swift` | `ChatSessionData` — id, title, dates, agentId, source, turns, generateTitle. |
| `ChatSessionsManagerProtocol.swift` | `ChatSessionsManager` — save, delete, rename, setArchived. |
| `MemoryServiceProtocol.swift` | `MemoryService` — bufferTurn. |
| `ChatConfigurationProtocol.swift` | `ChatConfiguration` — disableTools, maxToolAttempts, load. |
| `GenerativeGreetingProtocols.swift` | `GenerativeGreetingPool` + `GenerativeGreetingService`. |
| `SharedArtifactProtocol.swift` | `SharedArtifact` — processToolResult, fromEnrichedToolResult. |
| `PluginManagerProtocol.swift` | `PluginManager` — notifyArtifactHandlers. |
| `ContentBlockProtocol.swift` | `ContentBlock` — id only (minimal protocol, real type is richer). |
| `ModelOptionValueProtocol.swift` | `ModelOptionValue` — boolValue. |
| `ChatTurnDataProtocol.swift` | `ChatTurnData` — init(from:). |
| `ProtocolConformances.swift` | Apple Silicon conformances (`#if !OSAURUS_INTEL`). Extends excluded concrete types to conform to M10 protocols. 102 lines. |

**M10 Intel Conformers** (`Models/Chat/IntelConformers/`):

| File | Types defined | Lines |
|---|---|---|
| `IntelDataConformers.swift` | `IntelChatTurn`, `IntelAttachment`, `IntelContentBlock` + `ContentBlockKind` enum, `IntelModelOptionValue`, `IntelChatTurnData`, `IntelModelPickerItem`, `DiscoveredAgent`, `PairedRelayAgent`, `BlockMemoizer`, `ToolCallDone`, `StreamingToolHint`, `StreamingDeltaProcessor`, `StreamingReasoningHint`, `ContextBreakdown`, `ContextBudgetTracker`, `PromptQueue`, `SharedArtifactStub`, and ~40 additional stub types | 355 |
| `IntelManagerConformers.swift` | `IntelAgentManager` + `AgentInfo` type, `IntelModelPickerItemCache`, `IntelChatSessionData`, `IntelChatSessionsManager`, `IntelChatConfiguration` | 171 |
| `IntelStubConformers.swift` | `IntelSpeechService`, `IntelRemoteProviderManager` + `Provider` + `ProviderAuthType`, `IntelToolRegistry`, `IntelMemoryService`, `IntelGreetingPool`, `IntelGreetingService`, `IntelSharedArtifact` | 100 |

**Current typealiases** (in the respective conformer files):

```
ChatTurn = IntelChatTurn
Attachment = IntelAttachment
ContentBlock = IntelContentBlock
ModelOptionValue = IntelModelOptionValue
ChatTurnData = IntelChatTurnData
ModelPickerItem = IntelModelPickerItem
AgentManager = IntelAgentManager
ModelPickerItemCache = IntelModelPickerItemCache
ChatSessionData = IntelChatSessionData
ChatSessionsManager = IntelChatSessionsManager
ChatConfiguration = IntelChatConfiguration
SpeechService = IntelSpeechService
RemoteProviderManager = IntelRemoteProviderManager
RemoteProvider = IntelRemoteProviderManager.Provider
ToolRegistry = IntelToolRegistry
MemoryService = IntelMemoryService
GenerativeGreetingPool = IntelGreetingPool
GenerativeGreetingService = IntelGreetingService
SharedArtifact = IntelSharedArtifact
```

**Other key files:**

| File | Lines | Description |
|---|---|---|
| `Networking/MCPBridge.swift` | 213 | MCP server with stateless HTTP transport, 3 demo tools. |
| `Plugin/HostCapability.swift` | 63 | 12-capability enum + `OsaurusHostCapabilities.supported` registry. |
| `Plugin/PluginCompatibility.swift` | 48 | `PluginCompatibilityChecker` — compatible/incompatible/degraded. |
| `Views/Common/AppleSiliconOnlyOverlay.swift` | 82 | Reusable overlay + `.appleSiliconOnly()` ViewModifier. |
| `Views/Common/AppleSiliconOnlyTab.swift` | 54 | Full-tab placeholder for Apple Silicon sections. |
| `Utils/OsaurusBuild.swift` | 14 | `OsaurusBuild.isIntel` flag. |
| `Managers/Plugin/PluginManager.swift` | 1562 | Body-swapped. Intel `#else` block scans `~/.osaurus/Tools/` for `manifest.json`, checks capabilities via `PluginCompatibilityChecker`, populates loadedPlugins/incompatiblePlugins/degradedPlugins. |
| `Views/Plugin/PluginsView.swift` | ~1800 | Three-bucket UI on Intel (Compatible / Degraded / Apple Silicon Required). |
| `Networking/HTTPHandler.swift` | ~500 | Cloud proxy + agent loop for `/v1/chat/completions` and `/v1/models`. Defines `ChatCompletionRequest`, `ChatMessage`, `ToolCall`, `ChatCompletionChunk`, etc. |
| `Views/Settings/ServerSettingsTabContent.swift` | ~260 | Body-swapped. Intel shows `AppleSiliconOnlyTab`. |

### Conformer → original source map (gift to M10.5 Phase 0)

| Intel-lite type | File | Original excluded source | Notes |
|---|---|---|---|
| `IntelChatTurn` | IntelDataConformers.swift | `Models/Chat/ChatTurn.swift` | 60+ call site usage. Uses `MessageRole` (from `InternalMessage.swift`, NOT excluded). Has `Equatable` with manual `==`. Attachments are `[IntelAttachment]`. |
| `IntelAttachment` | IntelDataConformers.swift | `Models/Chat/Attachment.swift` | Equatable. Computed properties for file metadata. |
| `IntelContentBlock` | IntelDataConformers.swift | `Models/Chat/ContentBlock.swift` | Has `ContentBlockKind` enum with associated values: `.sharedArtifact(Any)`, `.userMessage(String, Any?)`, `.assistantMessage(String)`, `.thinking(String)`, `.toolCall(String, String)`. |
| `IntelChatTurnData` | IntelDataConformers.swift | `Models/Chat/ChatTurnData.swift` | Conforms to both `ChatTurnProtocol` and `ChatTurnDataProtocol`. Has `Equatable`. |
| `IntelModelPickerItem` | IntelDataConformers.swift | `Models/Configuration/ModelPickerItem.swift` | Uses `ModelPickerSource` enum (from Protocol file). Source is `.remote(String, String)` with unnamed associated values. |
| `IntelAgentManager` | IntelManagerConformers.swift | `Managers/AgentManager.swift` | Over 1,000 lines original. Intel stub has `agent(for:)`, `effectiveModel(for:)`, `effectiveMemoryDisabled(for:)`, `effectiveTemperature(for:)`, etc. |
| `IntelModelPickerItemCache` | IntelManagerConformers.swift | `Managers/Model/ModelPickerItemCache.swift` | Original ~150 lines. Intel stub returns cloud models only. |
| `IntelChatSessionData` | IntelManagerConformers.swift | `Models/Chat/ChatSessionData.swift` | Has `generateTitle(from:)` static method. `turns: [IntelChatTurnData]`. `source: SessionSource` (local enum). |
| `IntelSpeechService` | IntelStubConformers.swift | `Managers/SpeechService.swift` | No-op. All methods are stubs. |
| `IntelRemoteProviderManager` | IntelStubConformers.swift | `Managers/RemoteProviderManager.swift` | Has nested `Provider` type with `authType: ProviderAuthType` enum (`.apiKey`, `.bearerToken`, `.oauth`). `updateProvider(_:apiKey:)` method. |
| `IntelToolRegistry` | IntelStubConformers.swift | `Tools/ToolRegistry.swift` | `execute(name:argumentsJSON:)` → returns `"ok"`. |
| `IntelGreetingPool` | IntelStubConformers.swift | `Services/Chat/GenerativeGreetingPool.swift` | No-op — all methods return nil/do nothing. |
| `IntelSharedArtifact` | IntelStubConformers.swift | `Models/Chat/SharedArtifact.swift` | Has nested `ResolutionFailure` enum: `.markersMissing`, `.noContentOrPath`, `.destinationRejected(filename:)`. `processToolResultDetailed(_:contextId:contextType:executionMode:sandboxAgentName:)` where `contextId` is `String`. |
| `DiscoveredAgent` | IntelDataConformers.swift | `Models/Agent/RemoteAgentViews.swift` (unsure — verify) | ~15 computed properties. |
| `PairedRelayAgent` | IntelDataConformers.swift | Same as DiscoveredAgent (unsure) | ~12 computed properties. |
| `BlockMemoizer` | IntelDataConformers.swift | `Managers/BlockMemoizer.swift` | `blocks(from:streamingTurnId:agentName:thinkingEnabled:)` method (keyword args from ChatView). |
| `StreamingToolHint` | IntelDataConformers.swift | `Tools/AgentLoopTools.swift` (unsure) | Static methods: `decodeDone(_:)` → `ToolCallDone?`, `decode(_:)`, `decodeArgs(_:)`. |
| `StreamingDeltaProcessor` | IntelDataConformers.swift | (unsure — verify) | `init(turn:onChange:)`, `finalize()`, `receiveReasoning(_:)`, `receiveDelta(_:)`. |
| `ContextBreakdown` | IntelDataConformers.swift | (unsure — verify) | `from(turns:estimatedOutput:conversation:memory:system:instructions:)` static method. |
| `TTSService` | IntelDataConformers.swift | `Managers/TTSService.swift` | `toggleSpeak(_:messageId:voiceOverride:)`, `playingMessageId`. |
| `PromptQueue` | IntelDataConformers.swift | `Views/Chat/PromptQueue.swift` | Original is an `ObservableObject` class. Intel stub has `current`, `enqueue(_:)`, `drainAll()`, `advance()`. Originally body-swapped; Intel `#else` block removed because it collided with this stub. |
| `CloudChatEngine` | Services/Chat/CloudChatEngine.swift | `Services/Chat/ChatEngine.swift` + `ChatEngineProtocol.swift` | Provides BOTH the protocol and the actor. Only on Intel (`#if OSAURUS_INTEL`). |

### Decisions / rationale not obvious from commits

- **Strategy B for OpenAIAPI (Phase 3):** OpenAIAPI.swift defines canonical `ChatCompletionRequest`/`ChatCompletionResponse` but cascaded into `ModelOptionValue` (from excluded `ModelOptions.swift`). Re-excluded it, kept HTTPHandler's local types as canonical on Intel. Both definitions are `#if`-guarded so no collision at compile time.

- **PluginManager was body-swapped with a functional Intel block** rather than fully restoring it because the original references 10+ excluded managers (AgentManager, ExternalTool, ToolRegistry, RelayTunnelManager, SkillManager, PluginHostContext, etc.). The Intel block reads `manifest.json` directly from `~/.osaurus/Tools/` instead of dlopen-ing dylibs.

- **ChatWindowManager/ChatWindowState were body-swapped with functional Intel stubs** because the originals reference `ChatEngine`, `ChatSessionStore`, `AgentManager`, `SpeechService`, and many other excluded types. The Intel stubs provide real window creation and lifecycle.

- **All protocol files are `internal`** (no `public` keyword). They exist only to document the API surface and provide compile-time checking within the OsaurusCore module. The `#if OSAURUS_INTEL` typealiases bypass the protocols at runtime — ChatView uses concrete Intel types directly.

- **IntelChatTurn.attachments is `[IntelAttachment]`** not `[any AttachmentProtocol]` because Swift's existentials don't work well with `@Published`, `Equatable`, and array extensions. The concrete type approach was necessary for ChatView compilation.

- **ContentBlockKind enum** was created to match ChatView's pattern matching on `block.kind` (`.sharedArtifact(art)`, `.userMessage(text, _)`, etc.). Without it, dozens of pattern match errors cascade.

- **The Nash equilibrium at ~289 errors** occurs because each stub API fix that matches one ChatView call site introduces a slightly different type that doesn't match ANOTHER call site on the same type. For example, fixing `AgentManager.agent(for:)` to return `AgentInfo?` surfaced a mismatch at `ChatView.swift:942` where `Agent` doesn't conform to `AgentInfoProtocol`. The two types are compatible on Apple Silicon (where `Agent` IS `Agent`) but diverge on Intel (where `Agent` is the real `Agent` struct from `Agent.swift` but `AgentInfoProtocol` expects different members).

### The Nash equilibrium discovery

Manual stub-matching plateaus around 280-290 errors because:

1. **Error messages don't reveal byte-for-byte signature precision.** "Cannot convert value of type 'String' to expected argument type 'UUID'" tells you the types differ but not WHY. Reading the excluded source reveals the original takes `UUID`, but on Intel the calling code passes `uuidString` because type inference from an upstream `Any?` return broke the chain.

2. **Signature drift is self-reinforcing.** Fixing `MemoryContextAssembler.assembleContext` to return the right type surfaced a mismatch in `ContextBudgetManager.estimateTokens`. Each fix in one stub creates a cascading type mismatch 2-3 files downstream.

3. **Protocol conformance interacts with typealiases in unexpected ways.** When `IntelChatTurn: ChatTurnProtocol`, all protocol members must match exactly. But `ChatTurnProtocol` was extracted from reading ChatView's usage, not from the original `ChatTurn` source. The ORIGINAL `ChatTurn` has members (like `consolidateContent()`, `appendContent(_:)`) that ChatView doesn't call but the protocol requires. Adding them to the protocol fixes ChatView but adds ~5-10 new compiler warnings.

4. **The M10.5 breakthrough strategy is source-of-truth reading:** for every remaining error class, read the ORIGINAL excluded source file (e.g., `Models/Chat/ChatTurn.swift`) to get the EXACT public API surface (every method signature, property type, initializer). Then regenerate the Intel conformer to match byte-for-byte. This eliminates the guesswork that causes the equilibrium.

### Current build state verification

```
Branch: intel-fork
Remote: origin https://github.com/reneezmp/osaurus.git
Working tree: clean
Error count: 289 (all in ChatView.swift)
Last commit: 2a47b8dd "M10: 283→289 — SharedArtifactStub, voiceOverride, bufferTurn sessionId, ContextBreakdown"
```

**Last 30 commits:**
```
2a47b8dd M10: 283→289 — SharedArtifactStub, voiceOverride, bufferTurn sessionId, ContextBreakdown
a2096066 M10: 285→283 — SandboxAgentProvisioner.linuxName String signature
126199a3 M10: fixes — assembleContext, view init params, 25 missing stubs
98d45f32 M10: updates — SharedArtifact contextId, updateProvider apiKey, StreamingDeltaProcessor methods
80ae7770 M10: 277→285 — StreamingDeltaProcessor methods + RemoteProvider authType
f31b6236 M10: 277 — ContentBlockKind enum, firstChatCapable extension, Equatable fixes
e916d64a M10: 275→277 — IntelChatTurnData conforms to ChatTurnProtocol
8f70fcee M10: 281→275 — visibleContent, Equatable, TTSService, MemoryDatabase fixes
29ff9b51 M10 Fresh Start: 507→275 errors from clean base (typealiases + 30+ stubs + ChatWindowState rewrite)
9c136c52 M10 Phase 4d: Intel-lite conformers for ChatView protocol dependencies (9 managers, 6 data types)
06ae85a1 M10 Phase 4c: Apple Silicon concrete types conform to M10 protocols (#if !OSAURUS_INTEL)
f40b426f M10 Phase 4b: extracted 17 protocol files for ChatView's external dependencies
b5dab0a8 M10 Phase 3: Strategy B — OpenAIAPI re-excluded (cascaded into ModelOptionValue), HTTPHandler types kept as canonical on Intel
9648da12 M10 Phase 2: ChatWindowManager restored with Intel stubs (ChatWindowState body-swapped)
d97fde07 M10 Phase 1: CloudChatEngine class (cloud-backed M6 loop)
9a0b9370 M9 Phase 4: plugin test manifests + INTEL_ARCHEOLOGY updated with capability filtering verification
94e757bc M9 Phase 3: PluginsView with three-bucket capability UI (Compatible / Degraded / Apple Silicon Required)
228d194f M9 Phase 2: PluginManager restored with capability-aware loading (Intel #else block, original preserved)
3941ddba M9 Phase 1: capability schema + HostCapability registry + PluginCompatibilityChecker
41c6761e M8a-WaveC: 22 views + 11 ServerSettings sections restored
468f2473 M8a-WaveB: 12 views restored
dc7c23e9 M8a: 19 zero-dep views restored
25a2c000 M6.5: Voice/Sandbox/Model views restored with Apple-Silicon-Only placeholders
eb36b683 M6.5: 12 ServerSettings sections restored + labeling infrastructure
ff1b7fa8 M6.5-batch1: Labeling infrastructure + 12 ServerSettings sections restored
db7626ec M6: ChatEngine rebuilt, full agent loop with MCP tool calls works
a076aeaa M5: MCP server functional, 3 demo tools accessible via /mcp endpoint
b733cd46 M4: HTTPHandler proxies /v1/chat/completions to DeepSeek, SSE streaming works
da787ae7 M3: Router restored, HTTP server listens, all routes return stub 200
```

### Sign-off

Session closed 2026-05-24 at ~02:00 UTC-3. Working tree clean, 289 errors remaining in ChatView.swift only (down from 32,157 at start). All M2 through M10 infrastructure committed to `intel-fork` branch. ChatView is un-body-swapped with 20 typealiases and ~60 stub types active. The .app builds via xcodebuild and launches with functional cloud chat proxy + MCP server + PluginManager. M10.5 begins by reading this document and the M10.5 auto-sync strategy doc. ☀️🦕

---

## M10.5 Phase 6 — Compile Victory + Runtime Crash Discovery

**Date:** 2026-05-25  
**Tag:** `m10.5-zero-errors-runtime-crash-investigation`  
**Working tree:** Clean at `7521dd25` (themedAlert removal commit)

### Compile Reduction: 289 → 0

After 25+ commits across Phases 0-6, `swift build --arch x86_64` produces **zero errors**. The reduction trajectory:

| Phase | Technique | Outcome |
|---|---|---|
| Phase 2 | Data type fixes (class→class, enum→enum, protocols) | 289 → 193 (-96) |
| Phase 3 | Manager expansion | 193 → 193 |
| Phase 4-5 | Stub cleanup + apiKey fix | 193 → 177 (-16) |
| Phase A | Concretize existentials (IntelStubConformers, IntelManagerConformers) | 177 → ~20 |
| Phase A | FloatingInputCard 14 Any→concrete | Margin reduction |
| Phase A | Hidden errors unmasked (notification names, stub methods) | Final 1 → 0 |

**Key techniques:**
- **18 typealiases eliminated** — Intel types own original names directly
- **Phase A concretization** — All `any Protocol` existentials → concrete types matching originals byte-for-byte
- **Hidden error unmasking** — The 1 remaining type-checker timeout was masking 5 real compilation errors: missing `Notification.Name` extensions (`chatToolbarSelectDiscoveredAgent`, `chatToolbarSelectRelayAgent`, `vadStartNewSession`) and missing stub methods (`setCloseCallback`, `cleanup`, `startNewChat`, `loadSession`, `refreshSessions`, `agents` array, `Equatable` on `ModelPickerSource`)
- **Phase B extraction** — ChatSidebarSection, ChatInputSection, whatsNewContent, agentSheetContent, handleChatToolbarSelectDiscovered (~85 lines extracted from body)
- **~50 inline expression splits** (for-loops, typed locals, closure pre-computation)

**Verification:**
```
swift build --arch x86_64: 0 errors ✅
xcodebuild Release x86_64: BUILD SUCCEEDED ✅
file binary: Mach-O 64-bit executable x86_64 ✅
```

### Runtime Crash: `_swift_getGenericMetadata` Recursion

Despite zero compile errors, the `.app` crashes on launch with an identical pattern across 7 crash reports (Error1–7.md):

```
Exception Type: EXC_BAD_ACCESS (SIGSEGV) at stack guard
Recursion depth: 5,331–6,072 frames through:
  _swift_getGenericMetadata → AttributeGraph → SwiftUICore
Trigger: ChatWindowState.init() + NSHostingView/NSHostingController(rootView:)
```

**Key evidence table:**

| Test | ChatWindowState? | View | Result |
|---|---|---|---|
| Minimal OK | No | `Text("hello")` | ✅ Works |
| Error7 | Yes | `Text("hello")` | ❌ Crash |
| Error6 | Yes | `ChatView(Text("OK"))` | ❌ Crash |
| Error1–5 | Yes | `ChatView(...)` via NSHostingController/View | ❌ Crash |

**Working theory:** `ChatWindowState.init()` instantiates types (ChatSession, ThemeManager) that trigger lazy generic metadata resolution. In the `OsaurusCore` module, one of the new View structs (ChatSidebarSection, ChatInputSection) or their `some View` return types forms a circular metadata dependency. When the runtime tries to materialize these types, it recurses until stack overflow.

**Key insight:** The crash occurs even with `Text("hello")` as the rendered view. It's NOT in ChatView's body content — it's in the module-level type metadata that `ChatWindowState` references.

**NSHostingView vs NSHostingController:** `NSHostingController` triggered a different crash (AttributeGraph dependency cycle from `.themedAlert` in the original body). `NSHostingView` avoids that but the `_swift_getGenericMetadata` crash persists through both. The `NSHostingView` switch was correct but insufficient.

### Investigation Plan (in progress)

| Phase | What | Status |
|---|---|---|
| Phase 1 | Tag + document compile victory | ✅ Done |
| Phase 2 | Granular allocation tests (2A–2D): isolate which type triggers crash | ✅ Done — `ChatWindowState`, `ChatSession`, `ThemeManager` all safe |
| Phase 3 | Crash log forensics: extract exact metadata cycle type from crash trace | ✅ Done — `swift_getOpaqueTypeMetadataImpl` in `chatModeContent.getter` |
| Phase 4 | Module-scope bisection: ChatInputSection/ChatSidebarSection cycle source | ✅ Done — pairwise cycle via `@ObservedObject` in both View structs |

---

## M10.5 Phase 7 — Runtime Crash Resolved + Remaining Work

**Date:** 2026-05-25  
**Key milestone:** APP LAUNCHES WITHOUT CRASH — `ChatContentView` struct breaks opaque type metadata chain.

### Crash Resolution

After 14 consecutive runtime crashes (Error1–14), the root cause was identified:

**The `chatModeContent` computed property returned `some View` — an opaque return type.** At runtime, `swift_getOpaqueTypeMetadataImpl` tried to resolve the concrete type behind this opaque return, which triggered `chatModeContent.getter` re-evaluation, which triggered AttributeGraph updates, which re-triggered metadata resolution — infinite recursion at 11,175 levels.

**Fix:** Extract the entire `chatModeContent` body into a standalone `ChatContentView: View` struct (`Packages/OsaurusCore/Views/Chat/ChatContentView.swift`). The struct's `var body: some View` return type is resolved independently per-struct (not shared with ChatView's opaque type chain). All sub-view properties use concrete `AnyView` types instead of `some View` to prevent sub-opaque chains.

**Also fixed during Phase 7:**
- `MessageThreadView` (Intel #else block): body-swap placeholder replaced with raw `turns` display (shows user messages + assistant responses + thinking text)
- `ChatEmptyState` (Intel #else block): body-swap placeholder replaced with simple "New Chat / Type a message" text
- `FloatingInputCard` (Intel #else block): 14 `Any`-typed params concretized to original concrete types (byte-for-byte)
- Model auto-select: `session.selectedModel = "deepseek-v4-pro"` set in `.onAppear` when nil

### Current State

| Feature | Status |
|---|---|
| `swift build --arch x86_64` | ✅ 0 errors |
| `xcodebuild Release x86_64` | ✅ BUILD SUCCEEDED |
| Binary type | ✅ Mach-O 64-bit executable x86_64 |
| App launch + window | ✅ Opens without crash |
| Sidebar | ✅ ChatSessionSidebar renders (body-swapped placeholder) |
| Chat input bar | ✅ Intel-native HStack: TextField + send/stop buttons |
| Model auto-select | ✅ "deepseek-v4-pro" set on launch |
| User messages display | ✅ "You: <text>" appears in message area after send |
| Assistant responses | ❌ NOT appearing — streaming starts (green dot) but no response text added to `turns` |

### Root Cause of Missing Responses

The chat engine runs (send→stop→send toggle proves streaming lifecycle), but assistant turns are not saved to `observedSession.turns`. Likely causes:
1. `CloudChatEngine` missing `DEEPSEEK_API_KEY` environment variable
2. `CloudChatEngine` HTTP request failing silently
3. Response parsing failing to create `ChatTurn` objects

### Next Session Plan

1. **Check CloudChatEngine API key:** Verify `DEEPSEEK_API_KEY` is set in environment or AppDelegate
2. **Add verbose logging:** Print HTTP request/response to stderr from CloudChatEngine
3. **Test with curl:** `curl localhost:1338/v1/chat/completions` with a test message to verify cloud proxy works independently
4. **If cloud proxy works but chat doesn't:** Debug the `ChatEngine` → `ChatSession` turn storage pipeline
5. **If cloud proxy fails:** Fix the HTTP handler or API key configuration
6. **Once responses appear:** Refine message thread rendering (real message bubbles, markdown, streaming)

### Git State

- Branch: `intel-fork`
- Tag: `m10.5-zero-errors-runtime-crash-investigation`
- Latest commit for Phase 7 resolution: `709f4671` — "ChatContentView struct extracts entire chatModeContent body — NO RUNTIME CRASH!"
- Uncommitted changes: ChatContentView.swift, ChatEmptyState.swift, MessageThreadView.swift (diagnostic UI improvements)
- Working tree clean after doc update commit

