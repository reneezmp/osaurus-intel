# W-privacy-filter: plan and status

Backlog item `W-privacy-filter` (upstream Classic 0.25.x, about 12k lines in
`PrivacyFilter/`, plus plumbing in `RemoteProviderService`, `ChatView`,
`HTTPHandler`, `ChatEngine`, Insights and the folder redaction tools). Ported
from `upstream/classic` only; upstream's manual is `docs/PRIVACY_FILTER.md`
on that branch. Rows that depend on it: stage 5c row 16 (blocked-send error),
stage 5d row 40 (outbound/inbound scrub, Responses privacy stream), stage 6
rows `fa47416a8` #2979 and `437ca4257` #2793, the Bulk edits prompt section
(stage 5b row 17), the `detect_pii` / `redact_file` folder tools, spoken
numbers (#3135) and Computer Use's `FrameScrubber`.

## Owner policy (hard rules for every stage)

- The filter only ever removes or masks data before it leaves the Mac.
- It never sends the user's text anywhere new to decide what to mask: no
  cloud detector, ever.
- When it cannot decide, it masks (fail closed) wherever upstream does.
- It is on or off exactly as upstream's defaults say (upstream: master switch
  off for existing and fresh installs, built-in patterns on, presets seeded by
  locale), and turning it off is the user's action.
- Tests use synthetic data only: no network, keychain or `~/.osaurus`.

## Detector architecture finding (decided 2026-11-26)

Upstream has two optional "AI" detectors behind the rule layer:

| Detector | Files | What it is | Intel |
| --- | --- | --- | --- |
| OpenAI privacy-filter (`PrivacyAIBackend.openai`) | `Vendor/PrivacyFilterKit/*` (MoE transformer, `import MLX`, `MLX.loadArrays`, `MLXFast.RoPE`), `Model/PrivacyFilterModel*` | 2.8 GB bf16 sparse-MoE, MLX | **Incompatible** |
| Rampart (`PrivacyAIBackend.rampart`) | `Rampart/*` (`import RampartPII`, a vmlx-swift product), `MetalGate` | 37 MB BERT token classifier, MLX | **Incompatible** |

Evidence: both run on MLX GPU kernels (`RampartPrivacyDetector` documents the
passes as "MLX GPU producers on the shared Metal device"); upstream's
`Package.swift` targets `.macOS(.v15)` and takes `RampartPII` from
`vmlx-swift`; Intel's build links only `IntelStubs` MLX stand-ins, and local MLX
inference is already classed Apple Silicon only (`UPSTREAM_SYNC.md`, Apple
Silicon rows).
Neither can run on macOS 13 x86_64, and a cloud or CPU-only substitute would
break the owner policy, so the port keeps the rule-based layer only:

- Not ported: `Vendor/PrivacyFilterKit`, `Rampart/*`, `Model/*`,
  `PIIModelDownloadPromptView`, the two `*GlobalProxy*` downloader tests,
  `RampartWindowingTests`.
- `PrivacyAIBackend` and the config keys stay (a config copied from an
  upstream install still decodes); `PrivacyDetectorSupport.modelDetectorsRunnable`
  is `false` and `isBundleInstalled` is always `false`, so the pipeline always
  runs regex-only and never throws `.engineUnavailable`.
- Where upstream shows detector status (Privacy tab, Model sub-tab, review
  sheet footer) Intel shows "Incompatible: needs an Apple Silicon Mac" and
  disables the AI toggle. Never hidden.

## What the filter catches without the detector

Built-in patterns (`RegexEntityDetector`): phone, email, URL, US SSN and
Luhn-valid card numbers, plus numbers read out as words (spoken digits).
Presets (regional lists in `PrivacyRulePresets+*.swift`, checksum validators in `PrivacyChecksums`): IBAN,
national IDs, passports, driver's licences, tax numbers, AWS and GitHub keys
and more, enabled per region. Custom rules (builder or raw regex). Not caught
without a model: person names, street addresses, free-form dates and
free-form secrets. The UI and manual say so.

## Stages

1. **Rule engine and settings store (core, no UI, no wiring).** `Placeholder`,
   `RedactionMap`, `ScrubResult`, `PrivacyRule`, all `PrivacyRulePresets*`,
   `PrivacyChecksums`, `RegexEntityDetector`, `SpokenNumberDetector`,
   `CodeBlockMasker`, `InjectedContextSpans`, `StreamingUnscrubber`,
   `MessageScrubbing`, `PrivacyFilterConfiguration`, `PrivacyFilterStore`,
   `SessionRedactionStore`, `PrivacyDetectorSupport`; upstream tests for them.
2. **Engine and pipeline.** `PrivacyFilterEngine` (rule-only; model hooks
   removed), `PrivacyFilterPipeline` (outbound scrub, review gate, post-scrub
   invariant, inbound wrapper), `PrivacyReviewService`; their tests
   (`ApplyOutboundE2E`, `PrivacyReview*`, `InboundStreamWrapper`, ...).
3. **Wiring.** `RemoteProviderService` outbound/inbound hooks and the typed
   blocked-send error (row 16), `RemoteResponsesPrivacyStream` /
   Responses item scrub (row 40), `WireTransportProbe`, HTTP 422 for
   non-interactive review, Insights post-scrub bodies, chat inline highlights
   (`RedactionHighlighter` is already on Intel), `ChatView` review presenter.
4. **UI.** `PrivacyView` (Overview, Rules, Providers; Model tab shows
   Incompatible), `PrivacyPresetRulesSection`, `PrivacyCustomRuleEditor`,
   `RedactionReviewSheet` and state, preview views, Management tab entry,
   What's New, Ventura rules, `L()` strings in de/zh-Hans/ko/ru.
5. **Folder tools and prompt.** `detect_pii`, `redact_file`
   (`RedactionTools`, `RedactionToolSupport`), the Bulk edits prompt section,
   phone call setting the filter (`osaurus_privacy`), spoken numbers in voice.
6. **Computer Use scrubber hook and QA.** Restore upstream's `.pii` branch in
   `FrameScrubber` (hook only, marked), Insights Privacy tab wording, Rosy
   retest checklist, manual update.

## Status

- 2026-11-26: stage 1 done (rule engine, presets, config/stores; 15 test
  files). Strings: 8 `privacy.category.*` and 445 `privacy.presets.*` catalog
  entries came from `upstream/classic`'s catalog (`merge-upstream-keys.py`
  reads `upstream/main`, so do not use it for this item). Intel's older
  catalog had a stale English `privacy.presets.iban.description`; it now
  matches the source summary (`PrivacyPresetCatalogTests` pins this).
- 2026-11-26: stage 2 done. `PrivacyFilterEngine` is rule-only
  (`isLoaded` false, `modelSpans` empty, `loadIfNeeded` throws), the pipeline
  forces `useModel = false` so a config with `aiDetectionEnabled` on (the
  decode default for old files) never blocks a send. Adaptations: Intel's
  `ChatMessage` (in `HTTPHandler.swift`) has `anthropic_thinking_blocks` but no
  `responses_output_items`, so `MessageScrubbing` and the pipeline scan only
  the former (stage 3 adds the Responses scan if Intel gains the field);
  `ChatExecutionContext.voiceCallPrivacy` lives in a `PrivacyFilterPipeline`
  extension to keep the shared file untouched; `RedactionReviewState` and
  `RedactionPreviewBuilder` (plain Foundation, stage 4 files) came early because
  the review service and tests use them; `PostScrubInvariantTests` replaces
  Intel's old excluded stub (removed from the test `exclude:` list). Rampart's
  three `dropWordFragments` tests are not ported.
- 2026-11-27: stage 3 done (`914bd0a55`). `Services/Chat/IntelPrivacyWire.swift`
  hooks `CloudChatEngine` (first scrub before the stream, `scrubRound` per tool
  round, Responses replay items patched in place, `unscrubArguments` before a
  tool runs, reply / reasoning unscrub, one-shot path). `ChatCompletionRequest.messages`
  became `var`. HTTP 422 `privacy_filter` on OpenAI, Anthropic, Responses and
  Ollama handlers; Insights logs the post-scrub body and the redaction count;
  `ChatView` shows the blocked-send message; highlights in user and assistant
  bubbles. Computer Use and AppleScript loops auto-scrub as upstream. Not done:
  review presenter (stage 4: until then a needed review blocks the send, and
  the message mentions Settings → Privacy, which arrives with stage 4),
  highlights in thinking panes and activity groups, phone `/privacy/reviews`
  routes, `FrameScrubber` (stage 6). Tests: `IntelPrivacyWireTests` (13),
  including off-means-unchanged for streaming and one-shot.
- 2026-11-27: stage 4 done (`8694699c1`). Privacy tab after Permissions in
  the General sidebar group; Providers folded into the Filter tab as upstream's
  final Classic; Models tab lists both detectors Incompatible with no install.
  Review sheet + presenter in `ChatView` (dropped on disappear); Esc = Cancel.
  Not ported: Data Collection toggles (Intel keeps them in Data & Storage),
  the composer `isPrivacyReviewSheetVisible` flag (sheet is modal). The stage-3
  blocked message names "Require review for non-interactive requests" while
  the toggle says "Background Requests" (upstream wording, left). Debouncer
  flush bug fixed (see `UPSTREAM_SYNC.md`). Tests: `IntelPrivacyUITests`.
- 2026-11-27: stage 5 done (`046f1ea54`, see `UPSTREAM_SYNC.md`). Needs work:
  `ForcedToolChoiceGate` (CloudChatEngine hook). Bulk edits section: upstream
  only builds it on a path no chat reaches (folder chats take the lean path);
  `folderRedactionLine` is the live steering.
- 2026-11-27: stage 6 done (`127dd9f11`, see `UPSTREAM_SYNC.md`). All six stages
  shipped. Open: `ForcedToolChoiceGate` (wire forced tool choice into Intel's
  `ChatView` tool loop, which always sends `auto`; check whether stage 5's
  `ChatToolChoicePolicy` forcing is reached at all), Rosy QA. Blocked-send
  wording vs toggle title: upstream doesn't align them either; left.

## Waiting consumer (2026-11-27)

Done with stage 3: the screen-context block rides the user turn, so the outbound
scrub covers it when the filter is on; the preview note says so.
