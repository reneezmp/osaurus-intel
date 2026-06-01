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
