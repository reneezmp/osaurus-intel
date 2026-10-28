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

## Cost and approval rules (upstream, kept)

- Images: Cloud and Venice are billable. Upstream asks before every remote
  image (provider, privacy, estimated minimum price) whatever the agent's
  permission setting, unless that setting is Deny.
- Videos: a quote is fetched first and shown in the approval; queueing
  re-quotes and refuses if the price rose (`requireApprovedQuote`). Once
  queued, a paid job cannot be cancelled upstream; Stop detaches the UI and
  the job keeps being recovered.

## Tests

`Tests/MediaGeneration/MediaGenerationContractTests.swift` (upstream, minus
the `SubagentConfiguration` migration case and the two HTTP cases that come
with the server routes) and `IntelMediaGenerationTests.swift` (Venice host
check and discovery split, local targets refused, Cloud fails closed without
its catalog). Stub transports only; nothing reaches the network.

## Status

Part A (core) shipped 2026-10-28. Still to come in this item: the chat
composer path (media models in the picker), the `image` / `video` agent
tools with an Images settings panel, and the `/v1/images` and `/v1/videos`
server routes.
