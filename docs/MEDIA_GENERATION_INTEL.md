# Media generation on Intel (`W-media-generation`)

Cloud image and video generation, ported from upstream through `bce907045`
starting 2026-10-28. Local generation (vMLXFlux / mflux image bundles, Wan
video) is MLX and stays out (`INC-mlx`); everything here runs on a cloud
service, so it works on an Intel Mac.

## Backends

| Backend | What it is | Where it comes from |
|---|---|---|
| Osaurus Cloud | The Router's media catalog (`GET /v1/media/models`), billed in credits | Signed Router calls in `OsaurusRouterAPIClient` (the "Cloud media" section, no longer gated) through `OsaurusCloudMediaClient` |
| Venice | Image and video models of a Venice provider (`api.venice.ai`) added under Cloud Models with an API key | `VeniceMediaClient`; the catalog comes from Venice's `/models?type=all` during discovery |
| Local | MLX bundles | Not on Intel: every `.local` branch of `MediaGenerationCoordinator` throws `intelLocalUnsupported` ("needs an Apple Silicon Mac") |

## Core (part A, 2026-10-28)

Taken from upstream as they are: `Services/MediaGeneration/`
(`MediaGenerationTypes`, `MediaGenerationCoordinator`, `MediaJobStore`,
`MediaQuoteStore`, `MediaFileValidation`, `OsaurusCloudMediaClient`,
`VeniceMediaCatalog`, `VeniceMediaClient`), `Services/ModelRuntime/ImageGenerationTypes.swift`
and `ImageEffectiveParameters.swift` (Foundation-only request types:
`ImageOutputFormat`, `ImageComposerSettings`, …; no engine), `ComputerUse/Loop/InterruptToken.swift`
and `Tools/SubagentApprovalArguments.swift` (small helpers the media paths use).

Intel edits:

- **Coordinator:** the local (MLX) branches are `#if OSAURUS_INTEL`
  throws; the Cloud and Venice paths are upstream's.
- **Venice client:** `RemoteProviderService` is excluded, so the host check
  and header filter come from `IntelProviderDiscoveryExtras`
  (`isVeniceProvider`, `isSafeHeader`).
- **Discovery:** Intel's `RemoteProviderManager.probeModelsDiscovery` asks a
  Venice provider for `/models?type=all`
  (`IntelProviderDiscoveryExtras.fetchVeniceModelsDiscovery`). Text ids are
  the chat list as before; image and video entries go to
  `mediaModelCatalogs[providerId]`, never into `discoveredModels`. Any
  failure falls back to the plain `/models` probe. Upstream's lookups are
  there too: `cachedMediaModels()`, `mediaModel(for:)`,
  `configuredProvider(id:)`.
- **Launch:** after the Router connects, `AppDelegate` refreshes the Cloud
  media catalog (signed; without an identity it fails closed and Cloud media
  stays hidden) and resumes paid video jobs left running at quit.

Files on disk: generated images in `~/.osaurus/generated-images/`, videos in
`~/.osaurus/generated-videos/`, durable video jobs in
`~/.osaurus/runtime/media-jobs.json` (pruned after 30 days; a job is
recovered for up to 26 h because providers offer no upstream cancel).

## Chat composer (part B, 2026-10-28)

Media models appear in the chat model picker: Venice's under the Venice
provider, Osaurus Cloud's under Osaurus (`ModelPickerItem.fromMediaModel`:
catalog name, privacy, "From N credits"). They are never chat models
(`isLikelyChatCapable` is false), so the default pick and discovery
fallbacks skip them, and the Cloud browser's Image / Text-to-video /
Image-to-video categories now fill (`CloudModelCategory` is upstream's
again).

Picking one swaps the selector row's chips for the model's options
(`Views/Chat/MediaComposerChips.swift`, upstream's catalog branch of
`catalogMediaComposerChips`): aspect ratio, resolution, quality, duration,
audio, and for images size, steps, CFG, seed, format and count, plus the
starting price and a negative prompt (a popover on Intel; upstream uses an
alert accessory). `ImageComposerSettings` resets to the model's defaults on
every selection (`applyImageModelDefaults`). The placeholder changes to
"Describe the image..." / "Describe the video..."; an image-to-video model
accepts one image attachment.

Sending runs upstream's `runRemoteImageGeneration` / `runVideoGeneration`
(Intel `ChatSession` extension at the end of `ChatView.swift`) instead of
the chat engine: approval card, the coordinator, then the file attached to
the assistant turn as an artifact ("Generated image · N credits").
Regenerate re-sends the last user prompt. Upstream's local image branch is
not there.

Intel-only guard: `ChatSession.auxiliaryChatModel` is nil while a media
model is selected, so title generation, follow-up suggestions and the empty
chat greeting never send a media id to the chat engine (they use the core
model or skip).

**Picker cache race (found here):** Intel's `ModelPickerItemCache` wrote
`items` off the main actor; the extra `await` for the Cloud list made
`ModelPickerItemCacheTests.concurrentCallers_returnIdenticalResults` crash
(signal 11, only when the suite runs alone). The list is now built and
published inside one main-actor block.

## Agent tools (part C, 2026-10-28)

Upstream's `image` and `video` tools run through its subagent framework
(`ImageSubagentKind`, `VideoSubagentKind`, `SubagentSession`), which Intel
does not have (`W-subagents`). Intel's tools carry the cloud parts of those
kinds directly:

- `Tools/IntelImageTool.swift` (`ImageTool`, name `image`): generation only
  (cloud editing isn't supported upstream either), upstream's
  generation-only schema minus the local controls (sampler, adapters,
  batches, previews), one image per call. Always asks (billable) unless the
  agent's policy is Deny.
- `Tools/VideoTool.swift` (`VideoTool`, name `video`): upstream's schema
  minus the local controls; catalog checks (`VideoTool.validate`), a quote,
  then the policy (Ask shows the quote, Always Allow skips the card, Deny
  refuses). `source_path` must be inside the Osaurus root, PNG/JPEG/WebP,
  ≤ 25 MB, with matching magic bytes (upstream decodes through
  `HTTPHandler`, which Intel lacks).
- `Tools/IntelMediaToolSupport.swift`: the agent's switch, target and
  policy; model resolution (explicit `model` matched uniquely, else the
  configured target, else the first candidate; an unknown request or a
  configured model that is gone never falls back to another billable
  model); the artifact; error envelopes.
- **Settings:** `AgentSettings` gained upstream's `imageEnabled`,
  `videoEnabled`, `imageGenerationTarget`, `textToVideoTarget`,
  `imageToVideoTarget`, plus Intel's `imagePermission` / `videoPermission`
  (`MediaToolPermission`: upstream's `SubagentPermissionPolicy` values).
  Custom agents only (`AgentManager.effectiveImageEnabled` /
  `effectiveVideoEnabled`), as upstream; the Orchestrator never has them.
  UI: Agents → (agent) → Abilities → Overview → **Images & Video**
  (`IntelMediaAbilitySection` in `AgentsView.swift`).
- **Gates:** the switches are the grants (like `speak`): the tool
  resolution in `IntelDataConformers` strips the specs unless the switch is
  on, `runtimeCapabilityDenial` refuses a call otherwise, and each tool
  re-checks.
- **Display:** the tool promotes the file into the chat's artifact store and
  puts the enriched artifact text in its result (`payload["text"]`), so
  `ContentBlock` renders a file card for `image` / `video` like
  `share_artifact` (upstream: `GeneratedMediaToolArtifactBridge` in the
  chat loop, which Intel's engine does not run). The rest of the payload is
  upstream's `generated_media_job`.
- **Grounded-write check (#3104):** a completed `image` / `video` result
  counts as the file write. Upstream accepts only the local
  `native_image_generation_job` kind for images; Intel also accepts the
  cloud `generated_media_job`.
- **Not ported:** upstream's Images settings panel (`ImageGenerationView`).
  Its default models and permissions apply only to the Orchestrator, which
  never gets the tools, and the rest is local model management (MLX). Its
  recent video jobs list is not shown anywhere on Intel yet.

## Cost and approval rules (upstream, kept)

- Images: Cloud and Venice are billable. Upstream asks before every remote
  image (provider, privacy, estimated minimum price) whatever the agent's
  permission setting, unless that setting is Deny. So the agent's image
  permission offers only Ask and Deny on Intel.
- Videos: a quote is fetched first and shown in the approval; queueing
  re-quotes and refuses if the price rose (`requireApprovedQuote`). Once
  queued, a paid job cannot be cancelled upstream; Stop detaches the UI and
  the job keeps being recovered.

## Tests

`Tests/MediaGeneration/MediaGenerationContractTests.swift` (upstream, minus
the `SubagentConfiguration` migration case and the two HTTP cases that come
with the server routes) and `IntelMediaGenerationTests.swift` (Venice host
check and discovery split, local targets refused, Cloud fails closed without
its catalog). Stub transports only; nothing reaches the network. Part B:
upstream's `CloudModelCategoryTests` (media cases back) and
`IntelMediaChatTests` (media rows never chat models, candidates, defaults on
selection, `auxiliaryChatModel`). Part C: `IntelMediaToolsTests` (settings round
trip, resolution order, switch gate, registration, video checks, source
image rule), upstream's media case in `GroundedFileSideEffectCheckTests`
(plus Intel's cloud image kind), `OsaurusHelpToolTests` (the Images and
Video topic).

## Status

Complete 2026-10-28: parts A (core), B (chat composer) and C (agent
tools). The `/v1/images` and `/v1/videos` server routes moved to
`W-server-api`: they spend credits or Venice money, and Intel's server holds
an `APIKeyValidator` but never checks it, so they wait for that check
(`Models/API/ImageAPI.swift` is classified there). Follow-ups: a place to
see recent video jobs (upstream shows them in its Images panel).
