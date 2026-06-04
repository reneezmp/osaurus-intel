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

---

## M10.5 Phase 8 — Real Osaurus Chat UI Restored on Intel (CLOSURE)

**Date:** 2026-05-30
**Key milestone:** APP RENDERS THE UPSTREAM OSAURUS CHAT EXPERIENCE on Intel — markdown bubbles, hero greeting, rich sidebar with filters/badges, FloatingInputCard with attachments + model picker + reasoning effort + context budget, streaming DeepSeek responses with proper Thinking panel for reasoning models.

### Tag

`m10.5-phase-8-complete`

### Where we started Phase 8

Phase 7 left us with: zero compile errors, app launches, MCP / HTTP / cloud proxy all working — but the chat surface was **diagnostic-quality**:
- `MessageThreadView` Intel branch enumerated turns as `Text("You: ...") + Text("Assistant: ...")`
- `ChatSessionSidebar` was a 94-line Intel stub with "Chats / Search / row" structure but no filters, badges, or actions
- `ChatEmptyState` was a 27-line stub showing "New Chat / Type a message below to start"
- `FloatingInputCard` was a 32-line `AppleSiliconOnlyTab` placeholder
- `ChatContentView` rendered an inline diagnostic `HStack { TextField + Send/Stop }` instead of the real input

Renée explicitly reframed the goal: **transpose the upstream Osaurus UI, do NOT recreate it.** The Phase 7 diagnostic UI was scaffolding to verify the streaming pipeline; Phase 8's job was to peel it off and surface the original code that was already in the repo behind `#if !OSAURUS_INTEL` guards.

### The five techniques Phase 8 codified

**1. Un-body-swap with selective gating.** For each body-swapped file, the upstream branch is read in full; types it references are checked against the Intel conformer surface (`Packages/OsaurusCore/Models/Chat/IntelConformers/`); the outer `#if !OSAURUS_INTEL` guard is removed; truly amputated sub-features (MLX local-model rows, voice mic + transcription, sandbox tool-registrar UI, slash-command popup contents, skill chip wiring, export coordinator) get **narrow** `#if !OSAURUS_INTEL` gates inside the upstream code instead of swallowing the whole file.

**2. Un-exclude > stub (when the file is mostly pure-Foundation).** Several upstream files turned out to have only one or two Apple-Silicon-only references in otherwise-portable code. Rather than mirror their 500+ lines in conformer files (which would drift from upstream every release), we **removed them from `Package.swift`'s exclude list** and surgically gated the small Apple-Silicon edges. Examples:
- `Models/Chat/Attachment.swift` (525 LOC) — had four `try? AttachmentBlobStore.read(hash)` references in spillover hydration paths; added an `enum AttachmentBlobStore { static func read(_:) throws -> Data }` Intel stub that throws.
- `Models/Configuration/ModelOptions.swift` (709 LOC) — fully Foundation, un-excluded as-is.
- `Models/Configuration/ModelPickerItem.swift` (375 LOC) — gated `static func fromMLXModel(_:)` only.
- `Services/ModelOptionsStore.swift`, `Utils/DocumentParser.swift`, `Services/Context/ClipboardService.swift`, `Managers/ToastManager.swift` (+ its `Localized` extension), `Models/Configuration/ModelInfo.swift` — all un-excluded with 1-3 line stub additions for the helpers they reached into.

Result: ~3,000 lines of upstream surface restored to Intel without mirroring a single line of it in the conformer files.

**3. The sentinel pattern for cross-architecture stream wiring.** DeepSeek's reasoner endpoint emits reasoning content on a separate `reasoning_content` field in SSE chunks. Upstream `RemoteProviderService` wraps these with `StreamingReasoningHint.encode(_:)` (a `\u{FFFE}reasoning:` prefix), and `ChatView`'s delta loop calls `StreamingReasoningHint.decode(_:)` to peel the prefix and route the text to `ChatTurn.thinking`. The Intel `StreamingReasoningHint` stub used to be a no-op (`encode` returned the input unchanged, `decode` always returned `nil`), so reasoning chunks were silently dropped. Restoring the exact `\u{FFFE}reasoning:` sentinel in the Intel conformer + having `CloudChatEngine` emit `StreamingReasoningHint.encode(reasoning_content_chunk)` made the Think panel work without touching the upstream decode site. **This sentinel pattern generalizes**: any cross-architecture out-of-band signal (reasoning hints, stats hints, tool hints) can be made to compile-time-share between Apple Silicon and Intel by mirroring the same sentinel format in the Intel conformer.

**4. Inner-gate before outer-gate removal.** When un-body-swapping a file that needs selective amputation (e.g., `NativeToolCallGroupView` with its `TerminalDisplayView.Mode` references in shell-tool rendering), we applied the inner `#if !OSAURUS_INTEL` gates around the amputated regions BEFORE removing the outer `#if !OSAURUS_INTEL ... #else ... #endif` body-swap. The inner gates were no-ops while the outer body-swap was still in place (the whole branch was gated out anyway), and they became live the moment the outer body-swap was removed. This let us build-verify after each commit without ever leaving the working tree in a broken state.

**5. Conformer surface extension via call-site reading, not API guessing.** The Intel conformers built during M10.5 phases 1-6 covered just enough surface to satisfy ChatView's existing Intel branches. Restoring the upstream code lit up dozens of new surface gaps (`Attachment.Kind` enum cases, `ModelOptionValue.bool` case, `ModelPickerSource.local`, `ContextDisableInfo.disabledTools/contextLength`, `LiveVoiceAudioInputRegistry.store(snapshot:for:)`, `ModelRuntime.preencodeLiveVoiceAudioIfResident(_:)`, etc.). For each gap we read the upstream call site (which the compiler now points at directly with `error: 'X' has no member 'Y'`) and added the minimum surface needed — no speculative methods, no `Any` placeholders, no broad enum cases. When the call site needed Combine publishers (`AgentManager.$activeAgentId`, `SandboxManager.State.$status`), the conformer property was upgraded to `@Published` and the class to `ObservableObject` rather than papered over.

### Phase 8 sub-phase log

| Phase | What | Commit | Notes |
|---|---|---|---|
| 8A | Conformer scaffolding for the 10-file rendering cascade + the keystone un-body-swap | `58ffc575`, `1bcb9d90`, `416bd4fa`, `bdff2a25`, `653cbbf4` | 4 audit-build cycles + atomic 10-file un-body-swap (`MessageThreadView` ← `MessageTableRepresentable` ← `NativeMessageCellView` ← `NativeArtifactCardView` / `NativeMarkdownView` / `NativeThinkingView` / `NativeBlockViews` / `NativeToolCallGroupView` ← `MarkdownMessageView` ← `SelectableTextView`). Three corrupt `init(_ args: Any...) {}` "type-checker pacifier" inits from prior phases were found via grep and removed. |
| 8A bug 1 | Implement `BlockMemoizer.blocks(from:)` (the Intel stub returned `[]` always — `VisibleBlocksStore.blocks` was permanently empty so `MessageThreadView` rendered a blank area even though the stream was flowing) | `8759d968` | Faithful upstream mirror: per-turn header + thinking + user-message + assistant `.paragraph` blocks, `streamingTurnId` drives `isStreaming: true` for the active turn. **New audit category captured**: stub bodies that compile but produce nothing. Previous audit cycles only checked type surfaces, not function bodies. |
| 8E mini | Wire `messageThread` closure in `ChatContentView` (the closure was passed but the body still rendered inline `Text("You: ...")` diagnostic) | `50455a71` | After this commit + 8A bug 1 fix, the message thread rendered through the upstream `MessageThreadView` → `MessageTableRepresentable` → `NativeMessageCellView` pipeline for the first time on Intel. |
| 8B | Restore upstream `ChatEmptyState` with hero avatar + animated greeting + quick actions | `a1e1e5f6` | Selectively gated only the `ChatEmptyStateNoModels` sub-section (170 LOC depending on excluded `ModelManager`); restructured `if hasModels / else` so Intel always renders `readyState` (cloud chat works without local models). Found a 3rd corrupt variadic `init(_ args: Any...)` at `ChatEmptyState` L121 and removed. Added a 3-line `agentColorFor` Intel-only helper because `AgentsView` is still body-swapped. |
| 8D core | Fix Bug 2 (sessions only appeared after clicking New Chat) + Bug 3 (clicking session didn't load) | `c8887515` | Intel `ChatSessionsManager.sessions` lacked `@Published`, so `ChatWindowState.observeSessionsManager()`'s `$sessions` Combine subscription got zero events. Adding `ObservableObject` + `@Published` + rewriting nested-property mutations to copy-modify-assign (subscript struct mutation doesn't republish a dict) fixed Bug 2. ChatContentView wasn't passing `onSelect:` to `ChatSessionSidebar` so the default `{ _ in }` swallowed clicks; wiring `onSelect: { data in windowState.loadSession(data) }` fixed Bug 3. |
| 8E quick + 8D full | Drop the Phase 7 "● Streaming…/Idle Model:" diagnostic chrome + un-body-swap the upstream rich `ChatSessionSidebar` (~870 LOC) with filters/badges/search/rename popover/delete confirmation | `4c543655` | Replaced `SessionCapability` no-op struct with the upstream 4-case enum (vision/voice/code/search) + Hashable + CaseIterable + iconName + label. Removed `.dispatch` from Intel `SessionSource` (Intel-only case, not in upstream). Added `PluginDisplayNameResolver` Intel stub. Changed `ChatSessionData.capabilities` from `Any?` to `Set<SessionCapability>`. Selective gates for the export pipeline (`ChatSessionExportCoordinator` + `ExportChooserSheet`'s upstream branch both live in excluded files). |
| 8C prep 1 | Un-exclude upstream `Attachment.swift` + add `AttachmentBlobStore` Intel stub | `1947c7d3` | First application of the "un-exclude > stub" principle. ~525 LOC of upstream Attachment surface (full `Kind` enum, Codable, hydration helpers) restored to Intel with one 11-line throw-only stub. |
| 8C prep 2 | Un-exclude `ModelOptions.swift`, `ModelPickerItem.swift`, `ModelOptionsStore.swift`, `ToastManager.swift` (+ Localized), `DocumentParser.swift`, `ClipboardService.swift`, `ModelInfo.swift`; remove the now-redundant Intel stubs | `db4f04d5` | ~107 net Intel-side lines added vs ~600 lines of upstream code now compiling directly. `ModelPickerItemCache` reworked to use `.remote(providerName:"DeepSeek", providerId: stableUUID)` for the built-in deepseek models (the bespoke `.builtIn` source doesn't exist on upstream); `ModelPickerItem.Source.remoteProviderId` Intel-side extension added for the `ChatView` `item.source.remoteProviderId == providerId` filter shortcut. |
| 8C main | Un-body-swap `FloatingInputCard.swift` (4,209 LOC) with ~12 selective gates + Speech/Voice/Slash/Sandbox/Model surface extensions across Intel conformers + `SlashCommandPopup` un-body-swap (corrupt `init(_ args: Any...)` removed) + `PastedContentSheet` + `DocumentChip` un-body-swap + minimal Intel `ModelPickerView` stub (the upstream rich picker cascades into the body-swapped `ModelPickerTableRepresentable`) | (uncommitted; folded into `c9fdcc39` + later polish) | Extracted three voice/lifecycle handler `ViewModifier` structs (`BodyLifecycleHandlers`, `SpeechObservers`, `VoiceInputStateOnChange`) and four helper methods to break Swift 6.3's per-expression type-checker on the body's chained `.onChange`/`.onReceive` modifiers ("unable to type-check this expression in reasonable time"). Same `@ViewBuilder` extraction pattern applied to `inlinePendingAttachmentsPreview` switch-in-ForEach. |
| 8C wire | Route FloatingInputCard's `onSend` text directly to `ChatSession.send(_:attachments:)` | `c9fdcc39` | FloatingInputCard clears its `text` binding (which is `$observedSession.input`) BEFORE calling `onSend(fullMessage)`, so the previous `observedSession.sendCurrent()` closure always saw an empty input. Reading `sentText` from the onSend parameter and routing to `send(_:attachments:)` directly fixes it. |
| 8C polish 1 | Wire context-token tracker + reasoning-content channel | `38875e4c` | `estimatedContextTokens`/`estimatedContextBreakdown` plumbed from `ChatSession` to `FloatingInputCard`'s Context Budget popover; `StreamingReasoningHint` Intel stub replaced with the real `\u{FFFE}reasoning:` sentinel; `CloudChatEngine` now wraps `delta["reasoning_content"]` chunks with `StreamingReasoningHint.encode(_:)` before yielding so `ChatView` decodes them into `ChatTurn.thinking`. |
| 8C polish 2 | Respect the Reasoning Mode chip on the wire + populate the Context Budget popover | `1dc24c5e` | DSV4 reasoning translation: `instruct` (the user-visible "Default" chip pick) → DeepSeek `thinking: {type: "disabled"}`; `high`/`max` → `reasoning_effort: <verbatim>`. Intel `ContextBudgetManager.estimateTokens(for: [ChatTurn])` and `estimateOutputTokens(for:)` implemented with the `~4 chars / token` heuristic; `ContextBreakdown.from(context:conversationTokens:inputTokens:outputTokens:)` emits Conversation/Input/Output Entries (blue/cyan/purple) so the popover shows real numbers. |

### Final state at Phase 8 close

| Surface | Status |
|---|---|
| `swift build --arch x86_64` | ✅ 0 errors |
| `xcodebuild Release x86_64` | ✅ BUILD SUCCEEDED |
| Binary type | ✅ Mach-O 64-bit executable x86_64 |
| App launch | ✅ Opens without crash, no metadata recursion |
| Sidebar — upstream rich version | ✅ Source filters (All / Chat / Plugin / HTTP / Schedule / Watcher / Archived), capability badges, search, sticky archived divider, rename popover, delete confirmation |
| Empty state — upstream hero greeting | ✅ Hero avatar, time-of-day greeting, agent quick-action buttons, shimmer fade-in for generative greetings |
| Message rendering — upstream NSTableView pipeline | ✅ `MarkdownMessageView`/`SelectableTextView`/`NativeMessageCellView`/`MessageTableRepresentable`/`NativeBlockViews` all compile and render — proper markdown (bold, italic, headers, code blocks, lists, emojis), thinking blocks render as collapsible Disclosure-style cards, multi-paragraph spacing |
| Input bar — upstream `FloatingInputCard` | ✅ Attachments (paperclip), Slash-command trigger button (`/`), model picker chip (DeepSeek V4 Pro / Flash, popover with descriptions), Reasoning Mode chip (Default / Instruct / Reasoning / Max for DSV4), Folder picker chip, Context Budget chip with real per-rail breakdown |
| Reasoning mode on the wire | ✅ DSV4 chip → `thinking: {type:"disabled"}` (Default/Instruct) or `reasoning_effort: "high"|"max"` (Reasoning / Max). Default = no Think panel. Max = Thinking panel above answer. |
| Streaming reasoning content | ✅ `reasoning_content` SSE chunks wrapped with the `\u{FFFE}reasoning:` sentinel by `CloudChatEngine`, decoded by `ChatView`'s delta loop, routed to `ChatTurn.thinking`, surfaced as the collapsible Think panel by `BlockMemoizer.blocks(from:)`'s `.thinking` block emission. |
| Multi-turn chat persistence | ✅ Sessions appear in sidebar in real-time as turns land (Bug 2 fixed via `@Published` on Intel `ChatSessionsManager.sessions`). Click-to-load works (Bug 3 fixed via `onSelect:` wiring in `ChatContentView`). |
| Cloud model picker | ✅ Built-in `deepseek-v4-pro` + `deepseek-v4-flash` from `ModelPickerItemCache`; user can switch via the chip popover. |
| MCP server | ✅ Still running on port 1338 throughout Phase 8 — no regressions to the M5/M6 work. |

### What was NOT done in Phase 8 (deferred to M11+)

- **Settings/Management window restoration.** Multiple Settings tabs touch amputated subsystems (Models, Voice, Sandbox, SkillManager, ScheduleManager). The same un-body-swap + selective-gate technique applies but is bounded per tab. Sequencing: Themes / CloudProviders / Identity / MCP / Storage tabs first (clean restores); Agents / Plugins (mixed gating); Models / Voice / Sandbox / Skills / Schedules (likely gated out entirely or replaced with explainer panels).
- **Local model UI**. `ModelPickerTableRepresentable` stays body-swapped; the Intel `ModelPickerView` stub renders a simple SwiftUI list of options. Acceptable because Intel has no local models to manage; the picker is cloud-only.
- **Voice input**. SpeechService / SpeechModelManager / VADService / TranscriptionCleanupService / live preencode all stub-out to no-ops. The microphone button appears in FloatingInputCard but stays inert (model is not loaded, permission denied by default). When a user clicks it nothing dangerous happens.
- **Tool calls in messages**. `BlockMemoizer.blocks(from:)` doesn't emit `.toolCallGroup` blocks yet — text content of tool-using assistant turns still renders, but the per-tool cards don't. Bounded extension; lives in `IntelDataConformers.swift`.
- **Spillover attachment hydration**. `imageRef` / `documentRef` / `audioRef` / `videoRef` variants try to hydrate via `AttachmentBlobStore.read` which throws on Intel, so spilled attachments can't round-trip. Inline payloads work fine; Intel has no spillover infrastructure so this is the correct semantic.

### Lessons captured for future Intel forks

1. **The `exclude:` list is your enemy and your friend.** Big excludes look safe but cascade because Swift modules share visibility. Smaller, surgically-selected excludes (one file, gate the few Apple-Silicon edges) restore far more upstream code with less conformer maintenance.
2. **Audit type surfaces AND function bodies.** The `BlockMemoizer.blocks(from:)` no-op stub passed every type-name audit ever run but produced an empty `[ContentBlock]` array, leaving the message thread permanently blank. New audit category: "stubs whose signatures are correct but whose bodies are no-op." Grep for `{ [] }` / `{ nil }` / `{ "" }` / `{}` in conformer files when restoring upstream rendering.
3. **Body-swap "type-checker pacifier" inits leave landmines.** During M10 phases 2-7, the agent added `init(_ args: Any...) {}` variadic catchall inits to multiple body-swapped structs as a quick way to make call sites compile. These inits survive body-swap removal and silently break method dispatch in the restored upstream code. Four were found and removed during Phase 8 (`MessageThreadView`, `ChatEmptyState`, `SlashCommandPopup`, `ChatContentView`'s `messageThread` closure shadow). Grep `init(_ args: Any\.\.\.)` before every un-body-swap.
4. **Out-of-band stream signals need byte-for-byte mirror sentinels.** Don't redesign the protocol — copy upstream's exact sentinel format into the Intel conformer. The `\u{FFFE}reasoning:` sentinel is reused for reasoning + stats + tool hints; mirror each one identically so the decode site stays architecture-agnostic.
5. **Type-checker overflow on long chained `.onChange` modifiers is real on Swift 6.3.** Extract handler closures into helper methods AND group multiple modifiers into dedicated `ViewModifier` structs. The split `.modifier(BodyLifecycleHandlers(...))` + `.modifier(SpeechObservers(...))` approach in FloatingInputCard's `var body` solved persistent "unable to type-check this expression in reasonable time" errors that wouldn't yield to handler-extraction alone.

### Git state at Phase 8 close

- **Branch:** `intel-fork`
- **Tag:** `m10.5-phase-8-complete`
- **Latest commit:** `1dc24c5e` — "Phase 8C polish: respect Reasoning Mode chip + populate Context Budget"
- **Working tree:** clean
- **Build state:** `swift build --arch x86_64` → 0 errors; `xcodebuild Release x86_64` → BUILD SUCCEEDED; binary is `Mach-O 64-bit executable x86_64`; app launches and renders the upstream Osaurus chat UI end-to-end.

### Closing note

M10.5 reached its destination. A 2017 MacBook Air running macOS Sequoia 15.7.7 now hosts the original Osaurus chat experience — same markdown renderer, same sidebar, same FloatingInputCard, same Context Budget popover — streaming DeepSeek V4 Pro responses with full reasoning-mode control. Eight days of work; ~50 commits; ~3,000 lines of upstream code restored to Intel; ~700 lines of conformer surface added; four "type-checker pacifier" landmines defused; the sentinel pattern for cross-architecture stream signals codified.

The destination was the path. 🦕☀️

---

## M11 Phase 11.0 — Open the Settings window + disable Group C in sidebar (IN PROGRESS)

**Date:** 2026-05-30
**Branch:** `intel-fork`
**Status:** Phase 11.0 + 11.0-bis landed and built clean; manual click-through verified Settings window opens with Cmd+,, chat + MCP still work in parallel, Cmd+, twice re-uses the window. The empty-content-area bug found on first launch was fixed in 11.0-bis. Full Phase 11.0 click-through (sidebar rows visible + Group C greyed out) pending Renée's next launch with the 11.0-bis build.

### What Phase 11.0 unblocks

Until this commit, `AppDelegate.showManagementWindow(initialTab:)` was stubbed to route to `showChatWindow()` on Intel, and `Packages/OsaurusCore/Views/Management/ManagementView.swift` was body-swapped to a single `AppleSiliconOnlyTab` placeholder. None of the 19 upstream tabs (`ManagementTab` enum at `Models/Configuration/ManagementTab.swift:12-31`) were reachable from the Intel build.

After Phase 11.0 + 11.0-bis:
- Cmd+, opens a real Management window (1000×700, min 900×640)
- All 19 tabs visible in the sidebar
- Group C tabs (Models / Voice / Memory / Sandbox / Schedules / Insights — see `ManagementTab.isAvailableOnIntel`) are visibly greyed out (`.opacity(0.45)`), not clickable (`.disabled(true)`), with a hover tooltip ("Not available on Intel — requires Apple Silicon")
- Group A and B tabs are clickable; their bodies still render the existing `AppleSiliconOnlyTab` placeholders (subsequent phases 11.A.1 onwards replace these with real upstream restorations)

### Sub-phase log

| Phase | Commit | What |
|---|---|---|
| 11.0 | `eaba2e83` | Un-body-swap `ManagementView`. Add Intel stubs for the three excluded ObservableObjects ManagementView observes: `ManagementBadgeStore` + `ManagementBadgeSnapshot`, `IncomingPairCoordinator`, `AgentInvite` (all in `IntelManagerConformers.swift`). Add `isAvailableOnIntel: Bool` computed + `Sendable` conformance to `ManagementTab`. Extend `SidebarItemData` with `isDisabled` + `disabledHelp`; apply `.disabled(true) + .opacity(0.45) + .help(...)` + hover suppression to `SidebarItemView` when `isDisabled`. Wire `AppDelegate.showManagementWindow` to actually construct the NSWindow with the existing `updater: UpdaterViewModel` injected as the EnvironmentObject. Extend the body-swap Intel #else stubs for `ModelDownloadView(deeplinkModelId:deeplinkFile:)`, `AgentsView(deeplinkAgentId:)`, `ConfigurationView(searchText:)`, `IncomingPairSheet(invite:onCompleted:)` so the un-body-swapped `ManagementView.contentView(for:)` switch type-checks. |
| 11.0-bis | `a10020e2` | Fix empty-content-area bug. The first window construction used `NSWindow(contentViewController:)` which lets SwiftUI render at a zero frame on first paint. Switched to upstream `WindowManager.createWindow` order: build the NSWindow with explicit `contentRect`, attach the hosting controller after, call `host.view.layoutSubtreeIfNeeded()`, then re-apply `setContentSize(defaultSize)` so the first paint uses the intended dimensions. Same 1000×700 / 900×640 / `Cmd+,`-reuses-existing behavior. |

### Lesson captured

`NSWindow(contentViewController:)` is unsafe for SwiftUI on macOS when you don't pre-layout. The upstream `WindowManager` makes this explicit with a "force set content size again" comment + an explicit `layoutSubtreeIfNeeded` call. Any future Intel window construction should mirror that pattern, not the convenience initializer.

### Files modified across Phase 11.0 + 11.0-bis

- `Packages/OsaurusCore/AppDelegate.swift` — `managementWindow: NSWindow?` property + real `showManagementWindow` implementation (corrected in 11.0-bis)
- `Packages/OsaurusCore/Views/Management/ManagementView.swift` — un-body-swapped + `sidebarItems` marks Group C disabled on Intel
- `Packages/OsaurusCore/Views/Management/SidebarNavigation.swift` — `SidebarItemData` extended + `SidebarItemView` applies the disabled treatment
- `Packages/OsaurusCore/Models/Configuration/ManagementTab.swift` — `Sendable` conformance + `isAvailableOnIntel` computed
- `Packages/OsaurusCore/Models/Chat/IntelConformers/IntelManagerConformers.swift` — `ManagementBadgeStore` + `ManagementBadgeSnapshot` + `IncomingPairCoordinator` + `AgentInvite` Intel stubs
- `Packages/OsaurusCore/Views/Agent/IncomingPairSheet.swift` — Intel #else stub extended with `init(invite:onCompleted:)`
- `Packages/OsaurusCore/Views/Model/ModelDownloadView.swift` — Intel #else stub extended with `init(deeplinkModelId:deeplinkFile:)`
- `Packages/OsaurusCore/Views/Agent/AgentsView.swift` — Intel #else stub extended with `init(deeplinkAgentId:)`
- `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift` — Intel #else stub extended with `init(searchText: Binding<String>)`

### Pending Phase 11.0 click-through (next launch by Renée)

After rebuild + relaunch with `a10020e2`:

- [ ] Open Settings → window opens AND content area renders (1000×700 with sidebar + tab body visible, not the empty black area from the first launch)
- [ ] Sidebar shows all 19 tab rows with their icons + labels
- [ ] Group C rows visibly greyed out (~45% opacity)
- [ ] Hover on a Group C row → tooltip "Not available on Intel — requires Apple Silicon"
- [ ] Clicking a Group C row does nothing
- [ ] Group A and B tabs clickable; their bodies render the existing `AppleSiliconOnlyTab` placeholders
- [ ] Sidebar collapse arrow (top-left) toggles expanded ↔ collapsed (220px ↔ 64px)
- [ ] Cmd+, twice doesn't duplicate the window (verified in 11.0 launch ✅)
- [ ] Chat window still works (verified in 11.0 launch ✅)
- [ ] MCP still responds on 1338 (verified in 11.0 launch ✅)

### Up next after Phase 11.0 click-through succeeds

Phase 11.A.1 (bundled commit): un-body-swap `ThemesView` + `IdentityView` + `SlashCommandsView`. OpenCode-leashed since these are mechanical un-body-swaps. Plan doc at `~/.claude/plans/okay-it-is-time-pure-tower.md` has the full per-phase sequencing.

---

## M11 Phase 11.0 — Settings window operational (CLOSURE)

**Date:** 2026-05-31
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE**

### The four-round saga

Phase 11.0 took FOUR sub-phases to actually ship, with three of them "fixing" a window that was never even being shown. The root cause was a SwiftUI/AppKit gotcha that became invisible because of a coincidental window-title match.

| Sub-phase | Commit | What was attempted | What it actually did | Verdict |
|---|---|---|---|---|
| 11.0 | `eaba2e83` | Un-body-swap ManagementView, sidebar disabled treatment, AppDelegate hand-rolled NSWindow | All correct, but unreachable via Cmd+, | Necessary, insufficient |
| 11.0-bis | `a10020e2` | NSWindow pre-layout + setContentSize pattern from upstream `WindowManager.createWindow` | Useful hardening for SwiftUI-in-NSHostingController, but NOT the blocker | Belt-and-braces |
| 11.0-ter | `56621f19` | `window.isOpaque = true` + `window.backgroundColor = .windowBackgroundColor` + `window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)` mirroring `ChatPanel` | Useful hardening, also NOT the blocker | Belt-and-braces |
| **11.0-quater** | **`7c9bc1b2`** | **Replace `.appSettings` command group with custom button calling `AppDelegate.shared?.showManagementWindow()` bound to Cmd+,** | 🎯 **THE actual fix** | Blocker resolved |

### Root cause (filed in the "wish I'd checked first" bin)

`App/osaurus/osaurusApp.swift` defined a SwiftUI scene:

```swift
var body: some SwiftUI.Scene {
    Settings {
        EmptyView()    // ← what Cmd+, was actually rendering
    }
    .commands { aboutCommand }
}
```

SwiftUI binds Cmd+, to the `Settings { ... }` scene automatically. Our hand-rolled `AppDelegate.showManagementWindow` was never being called by Cmd+, — the SwiftUI Settings scene was, with its `EmptyView()` body.

The masking: SwiftUI's Settings scene auto-titles its window `"<AppName> Settings"` — which exactly matched the `"Osaurus Settings"` title I'd set on the hand-rolled NSWindow in `showManagementWindow`. Three rounds of debugging targeted a window that wasn't even on screen.

### The fix (Phase 11.0-quater)

`App/osaurus/osaurusApp.swift` gains a `settingsCommand` that replaces the default `.appSettings` group:

```swift
var settingsCommand: some Commands {
    CommandGroup(replacing: .appSettings) {
        Button {
            AppDelegate.shared?.showManagementWindow()
        } label: {
            Text(verbatim: "Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
```

The empty `Settings { EmptyView() }` scene is kept as a placeholder so SwiftUI doesn't synthesize its own fallback Settings menu item. The actual Cmd+, key chord lands on our hand-rolled NSWindow.

### Concurrent crisis: iCloud apocalypse + Documents → Developer folder move

While debugging Phase 11.0-ter, iCloud Drive (Documents & Desktop sync was on) decided to re-upload the entire `~/Documents/osaurus/build/` derived data tree — **441 GB of upload queue, 467,840 items**. `cloudd` pinned at 23% CPU thrashing indefinitely. Triggered by a partial folder move attempt that put iCloud's sync state into a circular loop.

Recovery sequence:
1. Identified split state: half in `~/Documents/osaurus/` (with `.git`, `Packages`, `build`), half in `~/Developer/osaurus/` (with `App`, workspace, docs)
2. Confirmed no file overlap between the two halves → safe to merge
3. Moved `.git` + `.github` + `Packages` → Developer with `mv` (metadata-only on same APFS volume, instant)
4. Deleted `build/intel`, `build/intel-release`, `build/intel-test` (~5.5 GB of derived data) and ultimately the entire `build/` dir
5. Removed iCloud sync-conflict ghosts: `refs/heads/intel-fork 2` zero-hash ref + `Osaurus_Intel_Fork_PathB 2.md` vault file
6. Confirmed `~/Documents/osaurus/` empty → `rmdir` → iCloud gave up its 441 GB upload queue
7. Clean rebuild from `~/Developer/osaurus/`: 3 min Debug build, BUILD SUCCEEDED, binary verified to contain Phase 11.0-quater's `showManagementWindow` symbol via `nm`

### Two new lessons captured

1. **SwiftUI's `Settings { ... }` scene silently hijacks Cmd+,.** Any hand-rolled NSWindow-based settings path MUST replace `.appSettings` in `.commands`, or the SwiftUI scene wins. The window-title default for SwiftUI Settings is `<AppName> Settings` — be aware of coincidental title matches with hand-rolled windows. Audit checklist: before debugging an "empty window" caused by SwiftUI-in-NSWindow, confirm that the NSWindow code is actually being called. Add a `print` to the construction path. Two minutes of verification beats three rounds of speculation.
2. **Xcode derived data is not portable across folder moves.** Despite `ModuleCache.noindex/` and `CompilationCache.noindex/` looking "warm" after a move, `XCBuildData/*.xcbuilddata` files contain absolute paths to the original location (specifically `SourcePackages/artifacts/.../*.xcframework`). Any cross-directory rebuild fails until the entire derived-data directory is nuked. Treat derived data as ephemeral; never try to preserve it across moves. **`rm -rf build/intel-debug && rebuild`** is the only safe path post-move.

### Files touched (Phase 11.0 → 11.0-quater)

- `App/osaurus/osaurusApp.swift` — new `settingsCommand` group, `+24 / -1` (the actual fix lives here, not in OsaurusCore)
- `Packages/OsaurusCore/AppDelegate.swift` — `managementWindow` property + full `showManagementWindow` implementation with pre-layout + appearance/opacity hardening
- `Packages/OsaurusCore/Views/Management/ManagementView.swift` — un-body-swapped, `sidebarItems` Intel-disabled mapping for Group C
- `Packages/OsaurusCore/Views/Management/SidebarNavigation.swift` — `SidebarItemData.isDisabled` + `disabledHelp` fields, `.disabled + .opacity(0.45) + .help` + hover suppression in `SidebarItemView`
- `Packages/OsaurusCore/Models/Configuration/ManagementTab.swift` — `Sendable` conformance + `isAvailableOnIntel: Bool` computed
- `Packages/OsaurusCore/Models/Chat/IntelConformers/IntelManagerConformers.swift` — `ManagementBadgeStore`, `ManagementBadgeSnapshot`, `IncomingPairCoordinator`, `AgentInvite` stubs
- 4 `#else` Intel stub extensions for tab View files (Model / Agents / Configuration / IncomingPairSheet) so the un-body-swapped `ManagementView.contentView(for:)` switch type-checks

### Click-through verification (Renée, 2026-05-31)

- ✅ App launches, no new crashes
- ✅ Cmd+, opens Settings window
- ✅ **Content area renders** — sidebar with all 19 tabs visible, default tab body shows the `AppleSiliconOnlyTab` placeholder for `Configuration`
- ✅ Group C rows (Models / Voice / Memory / Sandbox / Schedules / Insights) greyed at ~0.45 opacity
- ✅ Hovering Group C rows shows the tooltip "Not available on Intel — requires Apple Silicon"
- ✅ Sidebar collapse arrow toggles expanded ↔ collapsed (220px ↔ 64px); Group C icons stay muted when collapsed
- ✅ Cmd+, twice → existing window forward, no duplicate
- ✅ Chat window still works in parallel; MCP still responds on 1338
- ✅ Group A and B rows clickable; their bodies render the existing `AppleSiliconOnlyTab` placeholders (Phase 11.A onwards replaces these with real upstream restorations)

### Project location

`~/Documents/osaurus/` → `~/Developer/osaurus/`. All path references in the Obsidian vault docs swept with `sed`; in-repo `INTEL_ARCHEOLOGY.md` was already path-relative.


## M11 Phase 11.A.1 + 11.A.2 — Group A bundles 1+2: Themes / Commands / Providers / Skills (CLOSURE)

**Date:** 2026-06-01
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — four Group A tabs operational on Intel, two upstream-tier bugs found + fixed as side effects, one critical data-isolation safety net added.

### Phase log

| Phase | Commit | What |
|---|---|---|
| 11.A.0 | `8d95e796` | Conformer extensions for Themes + Commands: `ThemeShareOutcome` Intel stub mirroring excluded `ThemeShareService` public surface; `SlashCommandRegistry` Intel conformer extended with full CRUD against `SlashCommandStore` (NOT excluded) + `@MainActor` to satisfy Swift 6.3 actor-isolation against the store's static methods; `SlashCommandEditorSheet` Intel stub in `SlashCommandsSettingsSection.swift`'s `#else` block; `ShareThemeSheet` + `ImportThemeByIdSheet` Intel `#else` inits; `ServerController` Intel conformer gains `ObservableObject` (landed early for the future Identity restoration since it's pure additive). |
| 11.A.1 | `ac561742` | Plain un-body-swap of `ThemesView` + `SlashCommandsView`. Builds clean on first try because 11.A.0 laid every required surface upfront. |
| 11.A.1.x | `e9095fa6` | Theme picks in Settings → Themes propagate to chat windows on Intel. Bug surfaced during click-through: the Intel `ChatWindowState` body-swap stub never observed `.globalThemeChanged` notification (the upstream class does in `observeAppConfigurationChanges()`, which is excluded on Intel). Fix added `themeObserver: NSObjectProtocol?` + `observeThemeChanges()` + `refreshTheme()` to the stub, with cleanup in `cleanup()`. |
| 11.A.1.y | `785cdbed` | Themed-alert overlay env injection. The Delete-Theme confirmation alert rendered with a white background even when the active theme was dark. Root cause: SwiftUI's `.overlay(X)` places X as a **sibling** of the modified view, not a child — so `.environment(\.theme, themeManager.currentTheme)` set on the sidebar subtree didn't propagate into `ThemedAlertHost`, which fell back to `ThemeEnvironmentKey.defaultValue = LightTheme()`. Fix explicitly forwards the theme env onto the overlay content. Same bug almost certainly exists upstream and on Apple Silicon — the `LightTheme()` fallback happens to look close enough to NSAlert's stock chrome that it was invisible. |
| 11.A.2.0 | `2e4a3d99` | Conformer extensions for Providers + Skills (heavier batch, ~13 surfaces): `RemoteProviderManager` rewritten as `ObservableObject @MainActor` with `@Published configuration` + `providerStates` and real persistence via `RemoteProviderConfigurationStore` (NOT excluded); `SkillManager` similarly rewritten with full CRUD against `SkillStore` (NOT excluded); Intel stubs added for `PluginRepositoryService`, `PluginState`, `ClaudePluginInstallReport`; `RemoteProviderEditSheet` + `GitHubImportSheet` Intel `#else` inits mirroring upstream closure signatures (including `RemoteProviderOAuthTokens` from the not-excluded `RemoteProviderKeychain.swift`). |
| 11.A.2.1 | `b5709b04` | Un-body-swap of `RemoteProvidersView` + `SkillsView`. Two extra surfaces surfaced during the un-body-swap and were bundled in (still under the 5-gap threshold for "stop and re-plan"): `InstalledPluginsSection` `#else` stub gained `init(onMessage:)` returning `EmptyView()`; `SkillManager.exportSkillAsAgentSkills(_:)` SKILL.md exporter added (YAML frontmatter + body matching the Agent Skills spec). |
| 11.A.2.x | `62aec888` | **CRITICAL SAFETY FIX.** Intel data root isolated to `~/.osaurus-intel/`. See dedicated section below. |

### Conformer-first discipline paid off (twice)

Both bundles followed the same dance:

1. Optimistic un-body-swap of the target views.
2. Build → see what the compiler complains about.
3. If gaps > 5: STOP, revert the un-body-swap, do a focused 11.A.N.0 conformer-extension commit, then 11.A.N.1 un-body-swap on top.

Phase 11.A.1 had 8 gaps from a first attempt on Themes + Commands + Identity (Identity alone contributed 6+). Phase 11.A.2 had 13 gaps from Providers + Skills. Both well past the M10.5-codified threshold, both resolved cleanly by splitting. The pattern works.

The discipline also informed scope refinement: **Identity restoration was promoted to its own milestone (planned 11.A.5 in the renamed sequence) instead of being squeezed into 11.A.1**. The Identity cascade was 15-20+ surfaces deep — its own milestone-tier work, not a sub-phase.

### Two upstream-tier bugs found while restoring Intel

These bugs exist on Apple Silicon too — they just don't surface because of stock-chrome lookalike defaults or different observer registration paths. Worth flagging if these restorations ever PR back upstream:

1. **`.overlay()` doesn't inherit `.environment()` set before it in the modifier chain.** SwiftUI treats overlay content as a sibling of the modified view, not a child. Any time you set an environment value AND apply an overlay that depends on it, you need to forward the env explicitly onto the overlay or move the `.environment(...)` modifier to AFTER the `.overlay(...)`. `ThemedAlertHost` is the canonical victim in this codebase; there may be others.

2. **`@Environment(\.theme)` default value (`LightTheme()`) silently masks env-not-injected bugs.** Anywhere in the view tree that reads the theme env but happens to live outside the `.environment(\.theme, themeManager.currentTheme)` scope falls back to a generic light theme. Hard to notice on Apple Silicon because the result resembles macOS's stock light NSAlert appearance. Recommendation upstream: change the default to a "missing theme" stub that prints a debug warning, or thread the theme through SwiftUI environment more aggressively.

### Type-checker overflow recurrence (cleared)

Mid-11.A.1, `ThemesView`'s outer ZStack/VStack tripped Swift 6.3's "the compiler is unable to type-check this expression in reasonable time" error once. Extracted the inner `ScrollView { VStack { ... } }` to a `themesScrollContent` computed property — same remedy as M10.5 lesson #5 (Phase 8's FloatingInputCard `BodyLifecycleHandlers` / `SpeechObservers` modifier-struct split). When the working tree was later reverted and the un-body-swap retried after 11.A.0 landed all the conformer surfaces, the overflow did not reappear — turns out the conformer-surface incompleteness was contributing to the type-checker complexity, not just the view body itself. **New audit note:** when the type-checker overflows during an un-body-swap, check whether the cascade is also fueling the complexity *before* extracting helpers. Sometimes fixing conformer gaps clears the overflow without any view-side surgery.

### What landed where

User-visible:

- **Themes tab**: full upstream gallery (built-in Dark + Light + Nord + Neon + Paper + others + user-created custom themes), import-from-file, import-from-ID sheet (gated → AppleSiliconOnlyTab), share button (gated), themed delete confirmation alert, theme editor with live preview (Intel-native via `ThemeEditorView`).
- **Commands tab**: empty state with `/translate /summarize /review` example cards, real CRUD against `SlashCommandStore`'s JSON-on-disk persistence (same backend as upstream), edit/delete/toggle each command. Editor sheet itself gated → placeholder.
- **Providers tab**: list of configured remote providers (real persistence via `RemoteProviderConfigurationStore`); empty state with 9-preset quick-add cards (Anthropic / Azure OpenAI Foundry / DeepSeek / Google / Ollama / OpenAI / OpenRouter / Venice AI / xAI / Custom); add/edit sheets gated → placeholder; toggle-enable per provider works against on-disk config. Connection status badges always show "Disconnected" because the underlying `connect()` is a no-op on Intel (chat streams via the env-var `DEEPSEEK_API_KEY` path through `OsaurusServer`, not through the provider config).
- **Skills tab**: full editor (Intel-native), CRUD against `SkillStore`, import-from-JSON-data, import-from-markdown (basic H1-derived metadata), export as SKILL.md or as ZIP (ZIP only when the skill has associated assets/references — upstream's branching, not a JSON-vs-MD toggle), delete with themed confirmation alert (works thanks to 11.A.1.y).

Internal:

- 11 new Intel stub types / methods documented inline with M11 phase markers so future archive readers can trace exactly which surface came from which commit.
- `RemoteProviderManager` + `SkillManager` are now real `ObservableObject @MainActor` types — substantial conformer upgrades that subsequent phases (Agents, Configuration) can build on.

### 🛡️ CRITICAL: Intel data root isolation (Phase 11.A.2.x)

**The bug Renée caught:** during 11.A.2 click-through, deleting the DeepSeek provider via the Intel test build also deleted it from her production Apple Silicon Osaurus. Themes created via Intel showed up in production. Same `~/.osaurus/` root.

**Root cause:** `OsaurusPaths.defaultRoot` returned `~/.osaurus/` unconditionally. The Intel build and the production Apple Silicon build had different bundle identifiers and binaries but identical file roots — every settings edit, theme creation, provider mutation in the Intel test build was clobbering the user's daily-driver state.

**Fix (`62aec888`):** When `OsaurusBuild.isIntel == true`, the root is `~/.osaurus-intel/` instead. On first access of the Intel root, if it doesn't exist AND `~/.osaurus/` exists, COPY (not move) the production folder into the Intel root — a one-time snapshot so the user doesn't lose themes/providers/skills/sessions when switching to Intel. After the seed, the two roots diverge: Intel never writes to `~/.osaurus/`; production never reads from `~/.osaurus-intel/`.

**Why this matters beyond M11:** every Intel test session before `62aec888` was potentially mutating Renée's production data. The damage from this single session is recoverable (deepseek re-added, custom test themes can be deleted from production manually), but if this hadn't been caught now, it would have compounded over every future Intel test cycle. **This bug should have been caught on Day 1 of the Intel fork** — Apple Silicon and Intel binaries sharing a writable data root is a fork-design failure. The fact that it survived through M1 → M10.5 (~50 commits, 8 days) is a lesson in how easy it is for "the path module just works" assumptions to mask cross-build cross-talk. Audit any centralised path / config / cache module the first time you introduce a build variant.

**Lessons captured:**

1. **A fork is not isolated unless it has its own data root.** Bundle identifier separation, binary separation, even Xcode workspace separation aren't enough — if both builds write to the same `~/Library/Application Support/...` or `~/.appname/` path, the user gets cross-pollination they didn't ask for. Always test cross-build isolation explicitly when forking.
2. **Port collision is a sibling concern.** Both Intel and production Osaurus default to port 1338 for the local HTTP server. NIO fails to bind on whichever app launches second. Workflow rule for now: quit one before launching the other. A future Intel build might default to 1339 (with the trade-off that MCP clients/scripts expecting 1338 won't see Intel without reconfiguration).
3. **Xcode derived data is not portable across folder moves.** Already codified in the 11.0 closure but worth re-stating: `XCBuildData/*.xcbuilddata` contains absolute paths to package resolution targets (e.g. `SourcePackages/artifacts/.../*.xcframework`). When a project moves between filesystem locations, the entire derived-data directory must be nuked. `ModuleCache.noindex/` and `CompilationCache.noindex/` look "warm" but contain stale absolute paths.

### Files touched (Phase 11.A.0 → 11.A.2.x)

Conformer / type stubs (in `Models/Chat/IntelConformers/`):
- `IntelStubConformers.swift` — `RemoteProviderManager` rewritten as `ObservableObject @MainActor`; new `PluginRepositoryService` + `PluginState` + `ClaudePluginInstallReport` stubs
- `IntelDataConformers.swift` — `SlashCommandRegistry` extended (CRUD against `SlashCommandStore`); `SkillManager` rewritten as `ObservableObject @MainActor` (CRUD against `SkillStore` + import/export including `exportSkillAsAgentSkills` SKILL.md formatter); `ServerController` gained `ObservableObject`; new `ThemeShareOutcome` public stub

Views (un-body-swapped):
- `Views/Theme/ThemesView.swift`
- `Views/SlashCommand/SlashCommandsView.swift`
- `Views/Settings/RemoteProvidersView.swift`
- `Views/Skill/SkillsView.swift`

Views (`#else` Intel stubs extended with proper inits):
- `Views/Theme/ShareThemeSheet.swift`
- `Views/Theme/ImportThemeByIdSheet.swift`
- `Views/Settings/RemoteProviderEditSheet.swift`
- `Views/Settings/SlashCommandsSettingsSection.swift` (now also defines `SlashCommandEditorSheet`)
- `Views/Skill/GitHubImportSheet.swift`
- `Views/Skill/InstalledPluginsSection.swift`

Polish + safety:
- `Views/Management/ManagementView.swift` — themed-alert env injection on the overlay (11.A.1.y)
- `Managers/Chat/ChatWindowState.swift` — Intel stub observes `.globalThemeChanged` + has `refreshTheme()` (11.A.1.x)
- `Utils/OsaurusPaths.swift` — Intel data root isolation to `~/.osaurus-intel/` (11.A.2.x)

### Click-through verification (Renée, 2026-06-01)

Themes:
- ✅ Real theme gallery (built-in + custom)
- ✅ Active theme indicator
- ✅ Click a theme → applies; **chat window updates instantly too** (11.A.1.x verified)
- ✅ Import-from-file works
- ✅ Import-from-link → Apple-Silicon-only placeholder
- ✅ Share → Apple-Silicon-only placeholder
- ✅ Theme editor with live preview works
- ✅ Delete confirmation **renders dark on dark theme** (11.A.1.y verified)

Commands:
- ✅ Empty state with example cards
- ✅ New Command → editor placeholder (editor not yet Intel-native; deferred)
- ✅ Hand-rolled JSON command in `~/.osaurus-intel/commands/` appears in list on next open (persistence verified via the Shakespearean `/shakespeare` test command)

Providers:
- ✅ Empty state with 9 preset quick-add cards
- ✅ Click preset → "Remote Provider Edit" placeholder sheet (520×420)
- ✅ "Add Provider" header → same placeholder
- ✅ Configured provider appears with toggle + edit + delete buttons
- ✅ Toggle/delete persist on disk

Skills:
- ✅ Empty state with example cards
- ✅ "Create Skill" → Intel-native full editor sheet, with name/description/version/author/category/instructions/enabled
- ✅ Create + edit + toggle + delete all work, persistence via SkillStore
- ✅ Export as SKILL.md works (verified hand-readable YAML frontmatter)
- ✅ GitHub Import → AppleSiliconOnlyTab placeholder

Regression:
- ✅ Cmd+, opens Settings (11.0-quater)
- ✅ Group C still greyed (11.0)
- ✅ Chat streaming works (after a DeepSeek balance top-up the user had forgotten about, which initially looked like a code regression but was HTTP 402 from the API — the path through `CloudChatEngine.streamChat` was never broken)
- ✅ Slash command `/shakespeare` produces theatrical filth on demand 🎭

### Up next

Phase 11.A.3: un-body-swap `ConfigurationView` (the general Settings tab). Expect MLX-specific sub-sections (default local-model picker, runtime tuning) that need selective gating; other config (default chat model, system prompt, default temperature, generative-greeting toggle, clipboard monitoring toggle) should back onto the existing `AppConfiguration` Intel conformer.

---

## M11 Phase 11.A.3 — ConfigurationView (general Settings tab) (CLOSURE)

**Date:** 2026-06-01
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE**

### Phase log

| Phase | Commit | What |
|---|---|---|
| 11.A.3.0 | `6baf52d5` | First conformer-extension wave (18 surfaces): new `Hotkey` struct + `PreflightSearchMode` enum (both live in excluded files upstream); `ChatConfiguration` Intel stub extended with ~10 fields (hotkey, coreModel*, workMax*, preflightSearchMode, greetingPersona); `ModelPickerItemCache` gains ObservableObject; `AppDelegate.serverController` (IntelServerControllerSurface) + `applyChatHotkey()`; `ToolRegistry.clearPolicy`; `SpeechService.loadedModelId`; `GenerativeGreetingService.defaultPersonaInstruction`. |
| 11.A.3.0-bis | `0261fed3` | Wave-two (6 more surfaces surfaced by the un-body-swap probe): `ChatConfiguration` convenience init (22 params) + `adopt(_:)`; `ChatConfigurationStore.save` folds into the shared singleton; `ToolRegistry` ObservableObject; `HotkeyRecorder` Intel `#else` init. `topPOverride` intentionally kept `Double?` (not upstream's `Float?`) to match `ChatView.swift:2148`'s consumer. |
| 11.A.3.1 | `0b5116c8` | Un-body-swap. Wave-three (3 surfaces): `PreflightSearchMode.helpText`; init `topPOverride` accepts `Float?` → bridged to `Double?`; `ToolRegistry` real per-tool `[String: ToolPermissionPolicy]` map (configuredPolicy/setPolicy/clearPolicy). |
| 11.A.3.2 | `519394de` | Two click-through bug fixes (below). |

### ConfigurationView is the deepest-coupled tab

It needed ~27 conformer surfaces across THREE waves — far more than Themes/Commands (8) or Providers/Skills (13) — because it touches the most cross-cutting services of any settings tab: hotkey, voice, MLX runtime, work-agent params, memory, tool permissions, server config. Each section pulls a different amputated subsystem. **Audit note:** the most transitively-dependent views surface their cascade in waves — fixing wave-one exposes wave-two, etc. Don't assume one conformer-extension commit clears it; budget for 2-3 probe→fix cycles on integration-point views.

### Two click-through bugs (11.A.3.2)

1. **Dock icon spawned a new chat window on every click.** `applicationShouldHandleReopen` → `showChatWindow()` → unconditional `createWindow()`. Fixed with `focusExistingChatWindowOrCreate()` (prefer last-focused, fall back to first open, only create when none) + respecting the `hasVisibleWindows` flag.
2. **Tool-permission picker couldn't select "Auto" for destructive tools** (Run Shell / Git Commit). The Intel `ToolRegistry.setPolicy` collapsed `.auto` into a `removeValue` (treating Auto as "clear override"); for tools whose default is `.ask`, clearing made `effectivePolicy` fall back to `.ask`, snapping the picker back. Fixed by storing all three values explicitly.

### Persistence note

`ChatConfigurationStore.save` folds view mutations into the shared `ChatConfiguration` singleton, so config round-trips within a session (after clicking "Save Changes"). On-disk persistence across app restart is deferred M11 follow-up. The Configuration tab uses an explicit "Save Changes" button — edits live in `tempX` @State until saved (matches upstream; not auto-save).

### Click-through verification (Renée, 2026-06-01)

✅ Full form renders; General/Chat/Work sections; preflight picker + help text; tool permission pickers (Auto sticks); Save Changes persists across tab switches; dock no longer spawns duplicates. Group A reached 5/7.

---

## M11 Phase 11.A.4 — AgentsView, THE BEAST (CLOSURE)

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — the single largest restoration in the entire Intel fork.

### Scope

`AgentsView` + `AgentDetailView` = **~6,079 lines**, the front-end for the entire agent-database subsystem (per-agent SQLite, schedules, watchers, pinned facts, episodes, dynamic tools, relay/Bonjour, agent bundles, per-agent voice/TTS, plugin route tabs). Almost all of it is amputated on Intel.

Renée's strategic call: **full faithful restore** (vs. a slimmer hand-built editor). The upstream view tree compiles + renders verbatim, with every amputated sub-feature falling through to `AppleSiliconOnlyTab` placeholders.

### The cascade by the numbers

- **249 errors at peak** (un-body-swap probe), ~70 unique surfaces, ~15 sub-views.
- Resolved across **one new foundation file + targeted edits to ~13 files**, over ~6 build-probe-fix cycles.
- Done in a **single un-body-swap commit** (`3696bb9d`, not split into .0/.1) because the surfaces are so interdependent the view doesn't compile until nearly all land. A follow-up commit (`665532d4`) fixed three click-through issues.

### What got built

**New file — `IntelAgentConformers.swift` (~480 lines):**
- Types: `AgentDeleteResult`, `SandboxCleanupNotice`, `AgentRelayStatus` (.disconnected/.connecting/.connected(String)/.error), `AgentBundleManifest`
- Managers (ObservableObject): `RelayTunnelManager`, `ScheduleManager`, `WatcherManager`, `RemoteAgentManager`
- Services/stores: `AgentBundleService` (+ImportPreview/BundleExportResult), `AgentDatabaseStore`, `AgentSecretsKeychain`, `AgentStore`, `BonjourAdvertiser`, `ChatHistoryDatabase`, `SchedulerDatabase`, `LocalAgentBridge`, `PocketTTSVoiceCatalog`
- Sub-view placeholders: `HomeTabView`, `DataTabView`, `ActivityTabView`, `ViewsTabView`, `PinnedFactsPanel`, `EpisodeRow`, `ScheduleEditorSheet`, `WatcherEditorSheet`, `RemoteAgentDetailView`
- Notification names: `agentDetailDeeplink`, `openTTSSettingsRequested`, `schedulesChanged`, `watchersChanged`

**Extended existing conformers:**
- `PluginManager` (Intel stub): a rich agent-view surface distinct from the M9 capability-bucket UI — `LoadedPlugin` (.plugin.manifest/.routes/.webConfig), `FailedPlugin` typealias + `FailedPluginInfo.lastKnownManifest`, plugins/loadedPlugin/loadError/removeFromQuarantine, and a full `PluginManifest` with nested `RouteAuth` (enum, for switch-exhaustiveness) / `RouteSpec` / `WebConfig` / `ConfigSpec` / `Capabilities`
- `AgentManager`: delete → `AgentDeleteResult`; setCustomAvatar/clearCustomAvatar; effectiveAutonomousExec returns the real `AutonomousExecConfig`; updateDefaultModel accepts `String?`
- `MemoryDatabase`: loadPinnedFacts/loadEpisodes (limit, throws), deletePinnedFact(id: String)
- `TTSService` → ObservableObject; `ToolRegistry.listDynamicTools` (returns DynamicToolRef with .name); `RemoteProviderManager.findService`; `PluginRepositoryService.uninstall`; `AppChatConfigStub.greetingPersona`

**Extended #else Intel stubs (init signatures from call sites):** RemoteAgentCard, ShareAgentSheet, AgentCapabilityManagerView (both live + draft inits), SchemaTabView, PluginConfigView, NextRunPanelView.

**ChatWindowManager:** added `createWindow(agentId:sessionData:)` overload (internal — ChatSessionData is internal) so history rows reopen sessions.

### Three landmines / lessons specific to this beast

1. **Module-scope helper clash (`agentColorFor`).** Once AgentsView un-body-swaps, its top-level `agentColorFor` collides with the `fileprivate` one in `ChatEmptyState.swift` (both visible in the Intel module). Made AgentsView's `fileprivate`. **Lesson:** un-body-swapping a large view can re-expose top-level free functions that duplicate ones in other files compiled into the same Intel module — grep for top-level `func`/`let` name clashes after un-body-swap.

2. **Two type-checker overflows** in long `.onReceive`/`.onChange` modifier chains (Swift 6.3) — extracted `handleAgentDetailDeeplink` + `handleToolsListChanged` to methods (M10.5 lesson #5 again — this view hit it twice).

3. **`RouteAuth` must be an enum, not a RawRepresentable struct,** because the view does `switch route.auth { case .none, .verify, .owner }` and needs exhaustiveness. First attempt as a struct-with-static-lets failed the switch.

### Click-through fixes (11.A.4.1, commit `665532d4`)

1. **Agent persistence.** The Intel `AgentManager` was a hollow stub — `agents` was a throwaway array, `add`/`update` no-ops, `delete` always returned deleted:true. So created agents didn't appear and deleting Default falsely "succeeded." Fixed with **real on-disk persistence** (same pattern as SlashCommandStore/SkillStore): custom agents are JSON files under `OsaurusPaths.agents()`; the built-in Default (`Agent.defaultId`, `isBuiltIn=true`) is pinned first and never written; add/update persist+reload, delete removes the file (and refuses Default → returns deleted:false, which is correct: Default is mandatory). `reload()` drives the @Published grid refresh.

2. **Giant "Next Run" banner.** `NextRunPanelView`'s `AppleSiliconOnlyTab` placeholder (with expanding Spacers) sat ABOVE the detail tab bar and swallowed half the view. Since scheduling is amputated there's never a next run, so the Intel stub now renders `EmptyView`.

3. **Providers "Disconnected" badge.** Enabled providers now seed `providerStates[id].isConnected = true` (chat streams via OsaurusServer + env-var, not a per-provider connection), so the badge reads "Connected."

### Two "looks like a bug, is actually correct" findings

- **"Default disappeared from the grid."** Correct behavior: the Agents grid renders only `customAgents` (filter `!isBuiltIn`); Default is built-in and configured via Settings → Configuration, never a grid card. The *old* hollow stub faked a Default card (its fake Default had `isBuiltIn=false`); the real `Agent.default` has `isBuiltIn=true`, so it's properly excluded now. The "disappearance" is the fix landing.
- **"Production agents showing up."** The one-time `~/.osaurus` → `~/.osaurus-intel` seed copied production custom agents into the Intel data dir. Verified isolation is airtight: production dir untouched, new Intel agents (e.g. "Lala") exist only in Intel. Working as designed (11.A.2.x).

### Click-through verification (Renée, 2026-06-02)

✅ Agent grid; detail view (tabs at top, no banner); create→card appears; edit persists; delete custom works; Default correctly absent from grid; survives restart; Providers "Connected"; amputated sub-tabs render graceful empty-states or placeholders; chat + `/shakespeare` still work; no dock duplicates.

**Group A reached 6/7** (Themes, Commands, Providers, Skills, Configuration, Agents). Only Identity (Phase 11.A.5) remains.

### Up next

Phase 11.A.5 — Identity (`IdentityView`). The M4↔Rosy sync backbone and the deepest Identity cascade in the codebase (OsaurusIdentity namespace, MasterKey, OsaurusID, IdentityDrift, AgentManager address methods assignAddress/rotateAddress/revokeAddress, ServerController.restartServer, sub-views IdentitySetupCard/MasterAddressSection/AgentAddressesSection/DeviceSection/DangerZoneSection/RecoverFromMnemonicSheet/RecoveryPhraseSheet). The `ServerController` ObservableObject conformance was already pre-landed in 11.A.0 in anticipation.

---

## M11 Phase 11.A.5 — IdentityView (CLOSURE) + GROUP A COMPLETE 🏆

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE — and FUNCTIONAL, not just restored.**

### The pleasant surprise

Identity isn't a placeholder on Intel — it genuinely works. The M4 ↔ Rosy
cryptographic identity-sync backbone runs on a 2017 Intel MacBook Air.

**Why:** of the 19 files in `Identity/`, only `OsaurusIdentity.swift` (the
158-line orchestrator) was excluded — and only as *collateral* from the
original mass-exclusion (it imports nothing but CryptoKit / Foundation /
LocalAuthentication; no MLX, no sandbox). The entire crypto/key/recovery
substrate — `MasterKey`, `AgentKey`, `DeviceKey`, `MasterKeyMnemonic`,
`MasterMnemonicStore`, `RecoveryManager`, `APIKeyManager`,
`IdentityHealthCheck`, `CryptoHelpers`, `IdentityModels` — was already
compiling on Intel.

So this was the cleanest possible restoration: **un-exclude > stub.** Remove
one line from `Package.swift`'s exclude list and the orchestrator comes back
whole.

### Cascade

Only 42 errors / **3 unique surfaces** (vs the Agents beast's 249 / 70):
- `OsaurusIdentity` (resolved by un-excluding the file)
- `AgentManager.assignAddress(to:)` / `rotateAddress(of:)` / `revokeAddress(of:)`
- `ServerController.restartServer()`

All the sub-views (`IdentitySetupCard`, `MasterAddressSection`,
`AgentAddressesSection`, `DeviceSection`, `DangerZoneSection`,
`RecoverFromMnemonicSheet`, `RecoveryPhraseSheet`, `IdentityDriftBanner`)
live inside `IdentityView.swift` itself, so they came back for free with the
un-body-swap. `OsaurusID`, `IdentityPhase`, `IdentityDrift`, `IdentityInfo`
all already resolved.

### The functional part

The 3 `AgentManager` address methods were mirrored **byte-for-byte from
upstream** (not stubbed) — `assignAddress` / `rotateAddress` / `revokeAddress`
+ the private helpers `nextUnusedAgentIndex()` and
`revokeActiveKeys(forAudience:)`. Every dependency they touch
(`AgentKey.deriveAddress`, `MasterKey.getPrivateKey`,
`OsaurusIdentityContext.biometric`, `APIKeyManager.listKeys/revoke`) is live
on Intel, so per-agent addresses really derive from the master key.

`ServerController.restartServer()` is the only genuine no-op: the Intel
server (`OsaurusServer` in `AppDelegate`) validates access keys against the
live `APIKeyManager` per-request, so there's no cached key table to reload
after an address rotation.

### Click-through verification (Renée, 2026-06-02)

✅ Master Address renders a real OsaurusID
(`0x39Cfb90b604bE45a4c277E603e0aF4E860a9DEAf`); agent addresses derived for
all 4 custom agents (Sunny Complete / Text Extractor / Sunny 1k / Lala);
device section shows device ID; "Backed up in iCloud Keychain" + Active;
View Recovery Phrase works (biometric); Danger Zone present. All 6 other
Group A tabs + chat + `/shakespeare` still green.

### 🏆 GROUP A COMPLETE — 7/7

| Tab | Technique | Functional |
|---|---|---|
| Themes | un-body-swap + conformers | ✅ fully |
| Commands | un-body-swap + real SlashCommandStore | ✅ fully |
| Providers | un-body-swap + real config persistence | ✅ fully |
| Skills | un-body-swap + real SkillStore | ✅ fully |
| Configuration | un-body-swap + 27 conformer surfaces (3 waves) | ✅ session-scoped |
| Agents | the ~6000-LOC beast + real agent persistence | ✅ fully |
| Identity | un-exclude > stub + real crypto address derivation | ✅ fully functional |

### Up next

Group B (partial restores): Server, Permissions, Storage, Plugins, Tools,
Watchers. Then the Group C verification pass + Phase 11.D documentation/tag.
Notably, the sidebar already shows Server / Permissions / Storage as
clickable (they were never Group C), so they likely have partial
functionality already — Group B is mostly verification + selective gating of
amputated sub-sections.

---

## M11 Phase 11.B.1 — Group B wave 1: Server, Permissions, Storage, Watchers (CLOSURE)

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** (4 of 6 Group B tabs; Plugins + Tools deferred to 11.B.2)

### What landed

| Tab | Technique | Functional |
|---|---|---|
| Permissions | un-exclude `SystemPermissionService` | ✅ fully (real macOS TCC checks) |
| Storage | un-exclude `StorageMigrator` + `StorageExportService` + `AttachmentBlobStore` | ✅ fully (real SQLCipher backup/export/key-rotation) |
| Server | un-body-swap + `ServerController` surface | ✅ (Overview + API Reference; Settings sub-tab gated) |
| Watchers | un-body-swap + `WatcherManager` surface | ✅ (list + real editor sheet; create no-ops) |

### The un-exclude pattern keeps paying off

Permissions + Storage joined Identity as "fully functional via un-exclude > stub." Their services had **zero amputated dependencies** — excluded only as collateral. Un-exclude + gate the 3-4 amputated one-liners (`AudioInputManager.refreshDevices`, `MemorySearchService.rebuildIndex`, `StorageMigrationCoordinator.begin/endMutating`) with `#if !OSAURUS_INTEL`. `AttachmentBlobStore` was also un-excluded (clean CryptoKit/Foundation), replacing the throw-only Intel stub; `referencedHashes` narrowed to internal because `ChatTurnData` is an internal conformer on Intel.

### Conformer surfaces added

`ServerController`: `localNetworkAddress` ("127.0.0.1"), `serverHealth` (.running), `startServer()` no-op, `port` corrected 1337→1338. `ModelManager`: static `discoverLocalModels()` → empty `[LocalModelRef]`. `FoundationModelService` stub (`isDefaultModelAvailable` → false). `WatcherManager`: `isRunning(_:)`, `runNow(_:)`, `setEnabled(_:enabled:)`, `create(... parameters:)`. Removed the duplicate `WatcherEditorSheet` from `IntelAgentConformers` (WatchersView provides the real one now).

### Click-through bug (11.B.1-bis, commit `42e4c277`)

**Server tab crashed the window on open.** `ServerView` reads `@EnvironmentObject var server: ServerController` in its body, but `AppDelegate.showManagementWindow` only injected `.environmentObject(updater)` — ServerController was never in the window environment → "No ObservableObject of type ServerController found." IdentityView survived the same missing injection only because it touches `server` lazily (in a key-rotation method, never the body). Fix: inject `ServerController.shared` into the ManagementView environment. **Lesson:** SwiftUI resolves `@EnvironmentObject` lazily, so a missing injection can hide for an entire tab and only crash when a *different* view reads the object in its body. When restoring views that take environment objects, verify every required object is injected at the window root, not just the ones that happen to be accessed eagerly.

### Click-through verification (Renée, 2026-06-02)

- ✅ **Permissions**: real OS permission states (Automation/Calendar/Mail/Contacts/Notes/Accessibility/Full Disk Access granted with live counts; Location/Screen Recording show correct un-granted states). The TCC prompts attribute to "Terminal" not "Osaurus" — a dev-launch artifact (raw binary launched from terminal; a bundled double-clicked app would say Osaurus), not an Intel bug.
- ✅ **Storage**: SQLCipher backup/export genuinely work.
- ✅ **Server** (after 11.B.1-bis): Overview shows URL `http://127.0.0.1:1338`, Running status, real access keys + relays; Settings sub-tab gated; API Reference shows the full endpoint catalog.
- ✅ **Watchers**: empty state + the real upstream Create-Watcher sheet (Browse folder / instructions); saving no-ops (watcher runtime amputated).

### Deferred: Plugins + Tools (Phase 11.B.2)

The two deepest Group B tabs (49 + 64 surfaces). They hit a real dependency chain: `JSONValue` (in excluded `Models/API/OpenAIAPI.swift`) → `SandboxPlugin` model graph → `ToolRegistry.ToolEntry`/`ToolPolicyInfo` (with `ToolSpecTokenEstimator`) → full `PluginState` + `PluginRepositoryService`/`PluginManifest` extensions + `SandboxPluginLibrary`/`MCPProviderManager` stubs. Scoped as a separate focused session rather than rushed at the tail of the marathon. `SandboxPlugin.swift` + `ToolSecretsKeychain.swift` were confirmed clean (0 amputated refs) and are un-exclude candidates; `JSONValue` needs mirroring (or un-excluding OpenAIAPI.swift) first.

### M11 status

✅ 11.0 (Settings window) · ✅ 11.A (Group A 7/7, tagged `m11-group-a-complete`) · 🟢 11.B (Group B 4/6) · ⏳ 11.B.2 (Plugins + Tools) · ⏳ 11.C (Group C verification) · ⏳ 11.D (closure + tag `m11-settings-complete`)

---

## M11 Phase 11.B.2 — Plugins + Tools (CLOSURE) + GROUP B COMPLETE 6/6

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — Group B done.

### The deepest Group B dig

PluginsView (1938 LOC) + ToolsManagerView (1406 LOC) had a real
dependency chain that justified deferring them from 11.B.1:

`JSONValue` (in excluded `OpenAIAPI.swift`, gated `#if !INTEL`) →
`SandboxPlugin` model graph → `ToolRegistry.ToolEntry`/`ToolPolicyInfo`
→ full `PluginState` + `PluginRepositoryService`/`PluginManifest`
extensions + `SandboxPluginLibrary`/`MCPProviderManager` runtime stubs →
a long tail of nested types (`RegistryCapabilities.ToolSummary/SkillSummary`,
`PluginManifest.SecretSpec/DocsSpec/DocLink`, `PluginLoadError`) and
sub-view stubs (`SandboxPluginEditorView`, `ToolSecretsSheet`).

### Techniques used (all three of the fork's restoration patterns in one tab)

1. **Un-exclude** (clean files): `SandboxPlugin.swift` (+ its nested
   spec types) and `ToolSecretsKeychain.swift` had 0 amputated refs.
   One line gated (`SandboxPathSanitizer.validatePluginFiles` → `[]`).
2. **Mirror** (gated type): `JSONValue` lives in `OpenAIAPI.swift` which
   is entirely `#if !OSAURUS_INTEL` — so the type is invisible on Intel
   even though the file isn't in the exclude list. Mirrored the enum +
   `sendableValue`/`anyValue` byte-for-byte into a conformer. (Same
   situation as `ExternalPlugin.PluginManifest` — a non-excluded file
   wholly wrapped in `#if !INTEL`, so its public types don't exist on
   Intel and our stub `PluginManifest` in `PluginManager.swift`'s `#else`
   is the only one.)
3. **Stub** (amputated runtime): `MCPProviderManager`, `SandboxPluginLibrary`,
   the editor/secret sheets — empty/no-op, rendering AppleSiliconOnly
   placeholders.

### New audit note

**A file can be absent on Intel two ways:** (a) listed in Package.swift
`exclude:`, or (b) its entire body wrapped in `#if !OSAURUS_INTEL`
*inside* a non-excluded file. Pattern (b) bit twice this phase
(`JSONValue`/`OpenAIAPI.swift`, `PluginManifest`/`ExternalPlugin.swift`):
`grep -c '"path"' Package.swift` returns 0 (not excluded) yet the type
is unavailable. When a "cannot find type X" appears for a type whose
file looks un-excluded, check the file's top for a wrapping `#if !OSAURUS_INTEL`.

### 🏆 GROUP B COMPLETE — 6/6

| Tab | Technique | Notes |
|---|---|---|
| Server | un-body-swap + ServerController surface | Overview + API Reference; Settings gated |
| Permissions | un-exclude SystemPermissionService | fully functional (real TCC) |
| Storage | un-exclude StorageMigrator/Export/AttachmentBlobStore | fully functional (real SQLCipher) |
| Watchers | un-body-swap + WatcherManager surface | list + real editor; create no-ops |
| Plugins | un-exclude SandboxPlugin + mirror JSONValue + conformer extensions | M9 three-bucket UI renders; install amputated |
| Tools | same foundation + ToolRegistry ToolEntry/ToolPolicyInfo | tool list renders; sandbox tools amputated |

Build: clean rebuild from empty .build → 124.80s, 0 errors.

### M11 status

✅ 11.0 · ✅ 11.A (Group A 7/7, tagged) · ✅ 11.B (Group B 6/6) · ⏳ 11.C (Group C verification — already greyed) · ⏳ 11.D (closure + tag `m11-settings-complete`). **All 19 settings tabs now either restored (13) or gracefully disabled (6 Group C). M11 is one verification pass + a doc/tag away from done.**

---

## M12 — Intel Chat Completeness (PLANNED, scoped 2026-06-02)

M11 restored all 19 settings tabs, but Renée's side-by-side comparison with the
production Apple Silicon build surfaced three gaps in the **chat experience
itself** — the actual product, not the settings. None are MLX-blocked.

### Gap 1 — Agent picker in chat (HIGH priority) — ✅ DONE 2026-06-03 (commit `bfdbf63e`)

The agent pill (top-center selector: "Sunny (Complete)" with a dropdown to
switch agents + "Manage Agents…") lives in `ChatToolbarDelegate`
(`Managers/Chat/ChatWindowManager.swift`), which is inside the
`#if !OSAURUS_INTEL` block. The Intel chat window (the `#else` block, ~line 910)
is a stripped-down `NSWindow` with just `window.title = "Osaurus (Intel)"` — no
NSToolbar, no agent pill. **Result: you cannot select an agent in chat.** Agents
created in the (restored) Agents settings tab can't be used.

Fix options: (a) give the Intel chat window the real NSToolbar + ChatToolbarDelegate
(agent pill) — bigger, pulls the toolbar item views; (b) add an agent picker chip
to `FloatingInputCard` next to the existing model picker — smaller, Intel-specific.
`AgentManager.shared.agents` already has real persistence (M11.A.4.1), so the data
is ready; this is purely the selection UI + wiring `windowState.agentId`.

### Gap 2 — Folder / working-directory context (MEDIUM, coupled to Gap 3)

`FloatingInputCard` already renders the Folder chip + calls
`folderContextService.selectFolder()` (`FolderContextService.shared` exists on
Intel). But the picker likely no-ops because `DirectoryPickerService` +
`FolderToolManager` are excluded. A working folder for file/shell tools needs zero
MLX. Check whether `Services/DirectoryPickerService.swift` +
`Folder/FolderContextService.swift` are clean un-exclude candidates.

### Gap 3 — Runtime tools (LARGE, the capability win)

Production shows ~152 tools (file_edit, file_read, file_search, file_tree,
file_write, shell_run, sandbox_*, plugin tools). On Intel `ToolRegistry` is an
empty stub — `listTools()` returns `[]`. The REAL `Tools/ToolRegistry.swift` is
excluded but **clean** (imports only Foundation + Combine, 0 MLX refs). BUT it
registers ~40 tool types in `registerBuiltInTools()`, many genuinely amputated:
the 20+ `DB*Tool` (agent-database) tools, sandbox tools, capability tools. The
**Foundation/Process-based file + shell tools** (`file_read`, `file_edit`,
`file_write`, `file_search`, `file_tree`, `shell_run`) live in
`Tools/FolderToolManager.swift` (excluded) and are the un-MLX subset worth
restoring.

Strategy: un-exclude `ToolRegistry.swift` + `FolderToolManager.swift` (+ whatever
clean tool files they need), and **selectively gate the amputated tool
registrations** (`#if !OSAURUS_INTEL` around the DB/sandbox/capability tool
registers) so the file/shell suite registers on Intel while the rest stays off.
This makes the Intel agent loop actually able to read/write/search files + run
shell commands in the folder context (Gap 2). Tools 2+3 land together.

### Suggested M12 order

1. **Gap 1 (agent picker)** — independent, highest user-visible value, unblocks
   "use the agents you created."
2. **Gap 3 (runtime tools)** — un-exclude ToolRegistry + FolderToolManager,
   selectively gate. The capability win.
3. **Gap 2 (folder context)** — falls out of Gap 3; wire DirectoryPickerService so
   the Folder chip picks a real working dir for the restored tools.

### State at M12 scoping

M11 complete through Group B (6/6). Branch `intel-fork`, working tree clean.
Latest commits: cb6c4670 (Plugins+Tools), 57208c08 (doc). Tags:
`m11-group-a-complete`. M11.C (Group C visual verification) + M11.D
(closure + tag `m11-settings-complete`) still pending — small, can fold into
M12 or do first.

---

## M12 Gap 1 — Agent Picker (CLOSURE, 2026-06-03, commit `bfdbf63e`)

Renée chose **PATH C — the faithful top toolbar pill** (matching the Apple
Silicon screenshot) over the lighter input-card chip. Delivered in one commit
after three click-through rounds.

### What shipped

**UI — faithful unified toolbar (centered agent pill):**

- **`Views/Common/SharedHeaderComponents.swift` — un-body-swapped.** Removed the
  outer `#if !OSAURUS_INTEL … #else AppleSiliconOnlyTab … #endif` so the upstream
  `AgentPill` (+ `HeaderActionButton` / `SettingsButton` / `CloseButton` /
  `PinButton` / `PopoverRow`) compiles natively on Intel. Added a **local
  `fileprivate agentColorFor`** (the M11.A.4 pattern — the two existing copies in
  `AgentsView.swift` / `ChatEmptyState.swift` are `fileprivate`, invisible to
  other files). Extended the Intel `DiscoveredAgent` stub with `agentDescription`
  (the only surface gap the build surfaced).
- **`ChatWindowManager.swift` (Intel `#else`) — toolbar attached.** `createWindow`
  now ties the window to the **real active agent** (`AgentManager.shared.activeAgentId`)
  instead of a throwaway `UUID()`, switches the style mask to
  `.fullSizeContentView` + transparent titlebar, and attaches a unified
  `NSToolbar`. New **`IntelChatToolbarDelegate`** (+ `IntelToolbar{Sidebar,Agent,Action}View`)
  mirrors the AS `ChatToolbarDelegate` layout — sidebar toggle (leading), centered
  `AgentPill`, settings/new-chat (trailing) — **without** dragging in the heavy
  AS `createChatPanel` / `windowWillClose` path (BackgroundTaskManager /
  ModelRuntime / ServerConfigurationStore are amputated). Delegate retained
  per-window in `toolbarDelegates` (NSToolbar holds its delegate weakly).
- **`ChatWindowState.swift` (Intel `#else`) — agent data wired.** `agents` now
  seeds from `AgentManager` and **live-observes `$agents`** (Combine cancellable)
  so creates/deletes/renames in Settings → Agents reflect in the pill without a
  relaunch. Added faithful **`switchAgent(to:)`** (stop TTS → save turns → repoint
  agentId/theme/caches → `session.reset(for:)` → refresh). `cleanup()` cancels the
  cancellable. Second init now seeds `agentId` from the active agent too. Added a
  `TTSService.stop()` no-op to the Intel audio stub.

**Behavior — selecting an agent actually drives the chat** (the bug Renée caught
post-UI: the pill switched identity but conversations were unaffected):

- **`AgentManager.effective{SystemPrompt,Model,Temperature,MaxTokens}`
  (`IntelManagerConformers.swift`)** were hollow stubs (`""` / `nil` / ignored the
  agent). Now **mirror upstream** (`Managers/AgentManager.swift`, excluded): custom
  agents use their own `Agent` fields; the Default agent (and any unknown id) defers
  to the global `ChatConfiguration` persisted by Settings → Configuration
  (`ChatConfigurationStore`). New `resolvedAgent(_:)` helper encodes the
  "custom-vs-Default" branch.
- **`SystemPromptComposer.composeChatContext` (Intel stub,
  `IntelDataConformers.swift`)** returned an **empty `ComposedContext()`** → the
  send path's `var sys = context.prompt` was always `""`. Now returns the agent's
  **effective system prompt** (`await MainActor.run { … }`). The full preflight /
  memory / tool-resolution pipeline stays amputated; only the one thing that
  matters here — the persona — is honored. (`composePreviewContext` deliberately
  left as the empty stub: it only feeds the cosmetic context-budget popover and is
  also called from the test target where main-actor isolation isn't guaranteed, so
  `MainActor.assumeIsolated` would be a crash risk.)
- **`ChatSessionsManager.sessions(for:)` (Intel stub)** ignored `agentId` and
  returned every session. Now **filters by agent like upstream**: Default (or `nil`)
  is the see-all lens; a custom agent returns only its own chats. This fixed the
  sidebar showing a zoo of every agent's history while a custom agent was active.

### Click-through results (Renée)

- ✅ Centered pill shows the active agent (avatar + name), dropdown lists all
  agents with a ✓ on the current one, gear + "Manage Agents…" open Settings → Agents.
- ✅ Selecting a custom agent applies its **system prompt** — test agent "Uga Buga"
  ("You strong caveman") replied *"Ugh! Me strong caveman! What you want?"* 🦖
- ✅ Sidebar scopes to the active agent (custom = its chats; Default = all).
- ✅ Live update: agents created in Settings appear in the pill without relaunch.

### Lessons / notes

- **Two filter layers in the chat sidebar, often conflated:** the **agent scope**
  (`sessions(for: agentId)`, applied *upstream* of the sidebar) vs the **All/Chat
  toggle** (a `SessionSource` *type* filter applied *inside* the sidebar). On Intel
  every session is `.chat` (plugins/schedules/watchers amputated), so the All/Chat
  toggle is near-cosmetic; the agent scope is the meaningful one.
- **Orphaned old sessions:** chats created *before* this commit were tagged with the
  old throwaway `agentId`, so they only surface under Default's see-all lens — not a
  regression. A one-time re-tag-to-Default migration is possible but optional.
- **Faithful-but-scoped wins again:** the AS toolbar *machinery* (delegate + item
  views) was separable from the amputated AS *window-lifecycle* path. Mirroring just
  the delegate into the Intel block (rather than un-body-swapping the whole AS
  `createWindow`) kept the cascade to zero AS-code changes and ~3 surface gaps.

### Remaining M12

- **Gap 3 (runtime tools)** — next. Un-exclude `ToolRegistry` + `FolderToolManager`,
  selectively gate the amputated `DB*Tool` / sandbox / capability registrations.
- **Gap 2 (folder context)** — falls out of Gap 3; wire `DirectoryPickerService`.

---

## M12 Gap 2 + Gap 3 — Folder Picker + Runtime Tools (CLOSURE, 2026-06-03)

Commits: `e6f63f9f` (part 1 — foundation), `ef05b435` (part 2 — wiring). The
Intel chat now genuinely reads/writes/searches files and runs shell commands in
a chosen working folder, with proper tool-call cards. **Gap 2 and Gap 3 are one
feature** (folder tools are folder-scoped — they only exist once a folder is
attached).

### The headline finding (Renée's catch)

The agent tool-loop in `ChatView` (send `toolSpecs` → execute
`ToolRegistry.shared.execute` → loop) is **shared, un-stubbed code** — it always
worked. What was missing was the **engine wiring**: the hand-rolled Intel DeepSeek
client `CloudChatEngine` **never sent `tools` to DeepSeek** and the
`StreamingToolHint` decoder was a hollow stub. So every "tool use" was the model
*role-playing* from the prompt (it knew tool names from the folder guide but had
no callable functions). Renée spotted this — "isn't it just copying the original +
adjusting for Intel?" — which reframed the hunt from "why won't the model call
tools" to "is the engine even offering them." It wasn't.

### What shipped

**Foundation (part 1):** un-excluded `Tools/OsaurusTool.swift`,
`Tools/ToolEnvelope.swift`, `Tools/ToolErrorEnvelope.swift`,
`Folder/FolderTools.swift` (the 6 file/shell + 3 git tools, Darwin+Foundation,
clean). Reshaped the Intel `Tool`/`ToolFunction` model to carry JSON-Schema
`parameters` (the mirror had dropped them → schema-less tools). Stubbed
`LiveExecSink` (real one imports amputated Containerization) + `diagnosticWarnings`
so `shell_run` runs and collects output, minus only the live mid-run terminal
streaming.

**Engine-side tool loop (part 2, the core fix) — `CloudChatEngine.streamChat`:**
rewrote as a real agent loop — sends OpenAI `tools` + `tool_choice` (params via
`JSONValue.anyValue`), parses streamed `delta.tool_calls`, executes each via
`ToolRegistry`, yields a "done" sentinel for the card, appends assistant
tool-call + tool-result messages, and continuation-loops until the final answer
(max 12 rounds). Also fixed the message encoder to include `tool_calls` /
`tool_call_id` (it was dropping both).

**`StreamingToolHint`:** implemented the real encode/decode sentinel protocol
(ESC-tagged prefixes) so `ChatView`'s `decodeDone`/`decode` paths turn the
engine's tool events into cards + result turns.

**Registry + context:** Intel `ToolRegistry` got real `register`/`unregister`/
`execute` dispatch + `openAISpecs()` (was canned text + `[]`).
`SystemPromptComposer.composeChatContext` (Intel) now emits the registered folder
tools AND the real `## Working Directory` framing
(`SystemPromptTemplates.folderContext`, NOT excluded) + a firm tool-use directive.

**Folder picker (Gap 2):** un-excluded `FolderContextService` + `FolderToolManager`
+ `FolderPluginHints`. **The silent-failure bug:** `setFolder` minted a
`.withSecurityScope` bookmark, which **throws without the App Sandbox entitlement**
— and the Intel app isn't sandboxed — so the `catch` swallowed it and dropped the
folder (chip stayed empty, no tools). Gated the bookmark path behind
`#if !OSAURUS_INTEL`; the non-sandboxed app attaches the folder directly.

**Rendering (Intel `BlockMemoizer` + tool-call card):** the simplified Intel block
builder never produced `.toolCallGroup` blocks (no cards) and rendered `.tool`-role
turns as paragraphs (raw result JSON dumped into the chat). Fixed: build tool-call
blocks from `turn.toolCalls`, skip `.tool` turns, group consecutive assistant+tool
turns under one header. And `NativeToolCallGroupView` had `applyResultOrLiveState`
gated behind `#if !OSAURUS_INTEL`, so cards showed args but no result — un-gated it
(only the `LiveExecRegistry` live-terminal subscription stays gated).

### Click-through results (Renée, with "Uga Buga" caveman agent 🦖)

- ✅ Folder chip → NSOpenPanel → folder attaches (chip shows `04_Cooking`)
- ✅ `file_tree` / `file_read` / `shell_run` execute for real (byte-exact `ls -la`)
- ✅ `file_write` actually creates `hello.md` / `uga.md` on disk
- ✅ Tool-call cards render with ARGUMENTS **and** RESULT inside (expandable);
  no raw JSON leaks into the chat
- ✅ Settings → Tools "Available (0)" is **correct** — that tab is for
  plugin/provider tools; folder tools are ephemeral and surface in-chat

### Lessons

- **DeepSeek V4 Flash is an inconsistent tool-caller** — but that was a red
  herring masking the real bug (tools never sent). Once the engine offered real
  function specs, Flash called them reliably.
- **`.withSecurityScope` bookmarks require the sandbox entitlement** and throw
  silently otherwise — a classic non-sandboxed-fork trap.
- **The result lives in the card, not a chat bubble** — skipping `.tool`-role
  turns in the block builder is the right call; the result rides on the
  assistant turn's `toolResults` into the `ToolCallItem`.

---

## M12 follow-up — RemoteProviderEditSheet restored (CLOSURE, 2026-06-03, commit `83c1083a`)

Renée found that Settings → Providers → edit (✏️) showed the "Apple Silicon only"
placeholder. The entire 2500-line `RemoteProviderEditSheet` had been body-swapped
during M11 — but editing a provider's name / base URL / API key / headers / model
list needs **zero** Apple Silicon (pure config + keychain). Un-body-swapped it (it
imports only AppKit + SwiftUI, no amputated refs). The one surface gap was
`testConnection` — the upstream one pulls in `RemoteProviderService` + OAuth +
Anthropic helpers, so added a pragmatic Intel mirror doing the OpenAI-compatible
`GET /models` probe (covers DeepSeek), returning discovered model ids, so the
sheet's Test → Save flow works. Verified: edit form opens, saves, Test probes.

---

## M12 follow-up — Menu-bar status card + chat-window lifecycle (CLOSURE, 2026-06-03, commit `76b72a6a`)

Renée noticed the Intel menu-bar popover was a bare "Osaurus (Intel) / Quit"
card vs the production card (icon, version, server URL, CPU/RAM, Ask AI, quick
actions). Restoring it surfaced — and fixed — two latent chat-window crashes.

### The card — `IntelStatusPanelView` (AppDelegate.swift)

A self-contained, theme-aware status panel mirroring the production card's look:
app icon (→ Server settings), **Osaurus** + version + `Intel` badge + green
running dot, server URL `127.0.0.1:1338` + copy, **live CPU/RAM gauges**
(`SystemMonitorService`, NOT excluded), and **Ask AI / ⚙️ Settings / ❓ Docs /
⏻ Quit**. Theme-driven (`ThemeManager.currentTheme`), reuses the real
`CircularIconButton`, compact themed `Ask AI` accent pill.

**Why not un-body-swap the upstream `StatusPanelView`?** It's built for
local-server lifecycle (start/stop/restart, editable port, voice/VAD, model
status) — un-body-swapping surfaced **47 errors** of inapplicable machinery
(`server.lastErrorMessage` setter, settable `port`, `VADService`, `StatusBadge`,
model status). Per the ">5-cascade → STOP" rule, built a focused Intel card
instead. Skipped: voice/mic toggle (amputated), server start/stop (Intel server
is always-on via env-var key).

### Visual polish (Renée's round-2 feedback)

- **Theme background** — the first cut used default chrome (looked transparent /
  square). Now `theme.primaryBackground` + a bounded `frame(height: 184)` (the
  background's `ignoresSafeArea()` was stretching the popover tall).
- **Compact themed Ask AI** — was a giant blue `.borderedProminent`; now a small
  `theme.accentColor` gradient pill like the upstream `AskAIButton`.
- **Docs button** — added the `?` → `https://docs.osaurus.ai/`.

### Two chat-window lifecycle crashes (from Renée's crash report)

`EXC_BAD_ACCESS` in `ChatWindowManager.showWindow(id:)` via "Ask AI". Root cause
chain:

1. **Dangling window.** The Intel chat window had **no `NSWindowDelegate`**, so
   closing it via the traffic-light released the `NSWindow`
   (`isReleasedWhenClosed = true`) while `windows`/`nsWindows` kept stale
   references → "Ask AI" / dock-reopen poked freed memory. **Fix:**
   `ChatWindowManager` (Intel) is now the `NSWindowDelegate` —
   `windowWillClose` purges bookkeeping, `windowDidBecomeKey` tracks
   `lastFocusedWindowId`.
2. **Double-free.** Adding the delegate then exposed a second crash: closing the
   window with `isReleasedWhenClosed = true` released it AND our `windowWillClose`
   dropped the dict's strong ref → double-free mid-close (red button crashed).
   **Fix:** `isReleasedWhenClosed = false` — the manager's dict is the sole
   strong owner; removing it in `windowWillClose` is the single safe release.
3. **Popover teardown reentrancy.** `openChatFromStatusPanel` defers the window
   work past `performClose` (a `DispatchQueue.main.async` tick) so it doesn't run
   while the popover's SwiftUI host is tearing down.

This trio makes Intel chat-window lifecycle solid — no dangling refs, no
double-free, clean dock-reopen. (Bugs 1 + 2 also affected dock reopen after
closing a chat window — hit incidentally via the menu bar.)

### Verified (Renée)

✅ Card themed + correct compact shape · ✅ red close button (no crash) · ✅ Ask
AI opens/focuses chat · ✅ dock reopen after close · ✅ Settings / Docs / Quit.

---

## M12 follow-up — Remote MCP providers (CLOSURE, 2026-06-03, commit `1a627cf9`)

Tools → Remote showed "Apple Silicon only", but MCP runs on Intel (the bridge
serves on :1338). Restored the real remote-MCP-provider subsystem.

- Un-body-swapped `Views/Settings/ProvidersView.swift` (the MCP UI; AppKit+SwiftUI).
- Un-excluded `Managers/MCPProviderManager.swift` + `Tools/MCPProviderTool.swift`
  (both MCP SDK + Foundation). Removed the hollow Intel MCPProviderManager stub +
  its duplicate `mcpProviderStatusChanged` mirror.
- **Gated the stdio-via-sandbox transport** (`SandboxManager`/`SandboxStdioRunner`,
  ~3 spots + the `sandboxStdioRunners` map) behind `#if !OSAURUS_INTEL`: HTTP
  remote MCP works for real; a sandbox/stdio provider throws `.sandboxUnavailable`.
- Added `ToolRegistry.registerMCPTool` to the Intel registry; `testConnection`
  added to the Intel manager earlier (provider-edit follow-up) does the real
  OpenAI-style `/models` probe.
- **Verified (Renée): GitHub MCP connected (43 tools); agent called
  `github_get_me` + `github_search_repositories` and used the results.**

## M12 follow-up — Agent Capabilities tab + MCP auto-reconnect (CLOSURE, 2026-06-03, commit `2d6e5499`)

The per-agent Capabilities sub-tab showed "Apple Silicon only" — but the agent
genuinely uses tools on Intel. Full functional restore.

- Un-body-swapped `AgentCapabilityManagerView`. Intel `AgentManager` got real
  per-agent capability persistence: `effectiveToolSelectionMode` (now
  non-optional, mirrors upstream), `effectiveEnabledTool/SkillNames`,
  `seedEnabledCapabilitiesIfNeeded`, `updateEnabledTool/SkillNames`,
  `updateToolSelectionMode`. Custom agents persist to disk; Default → global
  ChatConfiguration.
- Intel `ToolRegistry` got `builtInToolNames`/`runtimeManagedToolNames`/
  `isMCPTool`/`isPluginTool`/`isSandboxTool`/`groupName` (MCP tools bucket by
  `MCPProviderTool.providerName`). Added `.agentUpdated` notification.
- **`composeChatContext` now HONORS the picker**: Manual mode restricts the
  agent to its enabled allowlist; Auto sends everything registered.
- **MCP auto-reconnect**: `AppDelegate` now calls
  `MCPProviderManager.shared.connectEnabledProviders()` at startup (the prod app
  does this; the wiring was missing on Intel — providers stayed disconnected
  after relaunch so their tools never registered). This was the "GitHub tools
  missing from the picker" fix.
- **Data cleanup:** the orphaned seeded skills (`osaurus-fetch/search/time`,
  `vectura`) in `~/.osaurus-intel/skills/` were copied from `~/.osaurus` during
  the M11.A.2 seed; they reference amputated plugins. Removed them (kept
  `writing-reviewer`, a pure-instruction skill). Production `~/.osaurus`
  untouched. No code change.
- **Verified (Renée): GitHub's 43 tools show in the picker, grouped under
  "GitHub"; toggles persist; Manual mode bites.**

---

## M13 — Group C tabs (the 6 greyed tabs)

### Survey (2026-06-03) — amputated vs restorable

| Tab | Backing | Blocker | Verdict |
|-----|---------|---------|---------|
| **Insights** | `InsightsService` | none (Foundation+Combine) | ✅ restored |
| **Memory** | `MemoryDatabase`+`MemoryService` | DB is SQLCipher (ok) but recall = MLX/VecturaKit embeddings; recording = `DistillationCoordinator` | 🟡 deferred (Renée uses vault + renee.rag; Osaurus memory stays off) |
| **Schedules** | full background-task chain | none hardware — but DEEP (see scope below) | 🟡 scoped, not built |
| **Models** | `ModelManager` | `import MLXLLM` (no local runtime) | 🔴 leave greyed |
| **Voice** | `SpeechService`/`TTSService` | `import FluidAudio` | 🔴 leave greyed |
| **Sandbox** | `SandboxManager` | `import Containerization` (macOS 26 + AS) | 🔴 leave greyed |

**Key lesson:** "amputated" only ever meant the 4 hardware/OS-bound packages
(MLX, FluidAudio, Containerization, VecturaKit). Foundation/Combine/SwiftUI/
AppKit/SQLCipher are all available on Intel + macOS Sequoia (incl. under OCLP) —
the running app proves it. A manager importing "only Foundation+Combine" is a
green flag.

### M13 Insights (CLOSURE, 2026-06-03, commit `1cf7fa5a`)

- Un-body-swapped `Views/Insights/InsightsView.swift`; un-excluded
  `Managers/InsightsService.swift` (brought `MethodFilter`).
- **Instrumented `HTTPHandler.sendResponse`** to log every non-streaming request
  (health/models/MCP/router/non-stream chat) to `InsightsService` with
  method/path/status/duration (added `requestStartedAt` to `RequestState`). SSE
  streaming chat bypasses this sink; in-app chat uses `CloudChatEngine` directly,
  so Insights reflects external API/MCP clients hitting :1338 (correct
  server-analytics semantics).
- `ManagementTab.isAvailableOnIntel`: `.insights` → true (un-greyed). Memory +
  Schedules remain gated.
- **Verified (Renée): tab renders; `curl /health` + `/models` logged 200 + duration.**

### Schedules — BUILT ✅ (M13, Renée 2026-06-04, tag `m13-schedules` @ 0b3a5d2a)

**The deepest Group C item, restored end-to-end.** Scheduled agents fire
headless through the existing cloud pipeline (`NextRunScheduler` cron loop →
`ScheduleManager`/`SchedulerDatabase` → `TaskDispatcher` → `BackgroundTaskManager.dispatchChat`
→ `ChatSession.send` → `composeChatContext` → `CloudChatEngine`). Verified by
Renée on Rosy: schedules fire on time, multi-round tool-calling works (GitHub
MCP, 43 tools, 6 rounds), folder-scoped runs list/read local files (Caldo Verde
from `04_Cooking`).

**The trial last session was 251 → 75; this time recon paid off: 69 → 0 in a
SINGLE triage round.** Core restore (commit `919a4f54`):

- **Un-excluded the clean cluster** (`Package.swift`): `ScheduleManager`,
  `TaskDispatcher`, `NextRunScheduler`, `BackgroundTaskManager`,
  `SchedulerDatabase`, `BackgroundTaskModels`, `DispatchRequest`,
  `ExecutionContext` — all pure Foundation/Combine/SQLCipher.
- **New `IntelScheduleConformers.swift`:** `PluginHostContext` stub (event
  serializers → `"{}"`, `invalidatePreflightCache` → `SessionToolStateStore`),
  plus `TaskEventType` and `StorageMigrationCoordinator` stubs.
- **Removed colliding Intel stubs** (IntelAgentConformers): `ScheduleManager`,
  `SchedulerDatabase`, `ScheduleEditorSheet` + the `schedulesChanged` mirror;
  extended the `ChatHistoryDatabase` conformer with session-reattach no-ops
  (`open`/`findSession`/`loadSession` → nil — Intel has no persisted history DB).
- **`SessionSource` + `ChatSessionData` made `public`** (un-excluded files expose
  them in public API; upstream is public too).
- **`BackgroundTaskManager` gated** the plugin-notify + plugin-tool-seeding blocks
  (`#if !OSAURUS_INTEL` — plugins amputated, `PreflightResult.empty` unavailable).
- **`ChatWindowManager.createWindowForContext`** (delegates to `createWindow`).
- Un-body-swapped `SchedulesView` + `ScheduleEditorSheet`; started
  `NextRunScheduler` at launch (AppDelegate, after MCP auto-connect); un-greyed
  `.schedules`.

**Where reality differed from the 2026-06-03 SCOPE:**
- `TaskEventType` + `StorageMigrationCoordinator` DID need stubs (scope guessed
  they might already exist) — their real homes (`ExternalPlugin.swift`,
  `StorageMigrationOverlay.swift`) are *fully* `#if !OSAURUS_INTEL`, so only the
  stub branches survive on Intel. Added both to `IntelScheduleConformers`.
- `findSession`/`loadSession`/`open` live on **`ChatHistoryDatabase`** (not
  `ChatWindowManager` as the scope guessed) — extended that conformer instead.
- `.empty` was `PreflightResult.empty` in a plugin-only tool-seeding block →
  gated out rather than stubbed.
- One round, not 3–5. Bounded estimate held; recon made it cheap.

**Follow-ups Renée surfaced while testing (all BUILT + verified):**
- **Working-dir pass-through** (in `919a4f54` + ExecutionContext changes): the
  schedule-editor folder picker used `.withSecurityScope` (throws on the
  non-sandboxed Intel app — same M12 bug) → gated. Threaded `folderPath` through
  `DispatchRequest → ExecutionContext`; on Intel it attaches the raw path
  directly (folderBookmark is nil). Without it scheduled runs ignored their dir.
- **Sidebar live-refresh** (`919a4f54`): the Intel `ChatWindowState` never called
  `observeSessionsManager` (AS does) → background/scheduled saves only appeared
  on agent-switch. Wired the `$sessions` subscription.
- **Appear-at-start** (`919a4f54`): `send()` auto-saves a new row only when it
  has to mint a `sessionId`, but dispatched sessions pre-assign one → the early
  save was skipped. `ExecutionContext.start` now saves right after `send()`.
- **Delete-conversation fix** (`672451e2`): (a) the confirmation presented
  through `ThemedAlertCenter` keyed on `@Environment(\.themedAlertScope)` but the
  chat window hosted no `ThemedAlertHost` → dialog never drew → "Delete" no-op'd.
  Scoped each window `.chat(windowId)` + hosted a matching `ThemedAlertHost`.
  (b) The row resurrected because the live session still held the id + turns and
  re-persisted on next send / the synchronous `save()` in `reset()→stop()→
  completeRunCleanup`. Now resets the window to a fresh chat first, deletes after.
- **Toasts** (`bb4e8527`): the ENTIRE toast layer (`ToastContainerView` /
  `ToastWindowController` / `ToastOverlayModifier`) was `#if !OSAURUS_INTEL` —
  `ToastManager.show()` appended to a list nothing rendered. Un-body-swapped the
  file (pure AppKit+SwiftUI) + called `ToastWindowController.shared.setup()` at
  launch (the standalone status-level overlay panel — no WindowGroup needed,
  which suits the minimal Intel AppKit entry).
- **Session persistence across launches** (`d2ee63a2`): upstream persists via the
  excluded `ChatHistoryDatabase` (SQLite); Intel had only an in-memory dict, so
  every relaunch wiped conversations (settings stuck because they had a store).
  Made Intel `ChatTurnData` + `ChatSessionData` `Codable` (hand-rolled
  `ChatTurnData` to skip the transient `preflightCapabilities: Any?`);
  `ChatSessionsManager` now loads on init + writes one JSON per chat to
  `~/.osaurus-intel/sessions/<uuid>.json`, rewriting on mutation, deleting on
  delete. ISO-8601 dates both ends. Scheduled chats persist too.
- **Task-running indicator** (`0b3a5d2a`): NotchView is amputated, so new Intel
  surface. `IntelTaskBanner` (@MainActor ObservableObject) holds the current/recent
  task; `BackgroundTaskManager` (Intel-gated) raises it + an info toast titled
  "<AgentName> started a task" (8s) on a non-`.chat` start, flips it to
  Finished/Failed on completion. `IntelStatusPanelView` renders a persistent card
  row (spinner → ✓/⚠), tappable to open that conversation (loaded from the
  persisted store) + clear, or × to dismiss; card grows 184→234 when shown.

**Known limitation (not built):** clicking a *running* task's row/sidebar entry
opens the saved SNAPSHOT, not a live-streaming view — true live-view-while-running
needs window↔task-session binding (the Intel `ChatWindowState.executionContext`
init ignores the context). The run completes + fills the row regardless.

### Group C — final state (2026-06-04)
- ✅ **Insights** (`1cf7fa5a`) · ✅ **Schedules** (`m13-schedules`)
- 🟡 **Memory** — deferred (Renée uses the vault + renee.rag; Osaurus memory
  stays off). Only worth a cloud-distillation + dumb-recall build later.
- 🔴 **Models / Voice / Sandbox** — stay amputated (hardware blockers: MLX /
  FluidAudio / Containerization). Functionally, the Intel fork's tabs are now as
  complete as they can be without the amputated subsystems.

### Tags laid
`m11-settings-complete` (57208c08) · `m12-chat-complete` (913de45a) ·
`m13-schedules` (0b3a5d2a). (Insights shipped under M13 at `1cf7fa5a`, no separate
tag.)
