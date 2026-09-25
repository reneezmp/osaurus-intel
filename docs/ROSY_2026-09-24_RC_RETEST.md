# Rosy RC Retest — 2026-09-24

This is the focused follow-up to
`ROSY_2026-09-22_AGENT_GENERAL_RETEST.md` after Renée completed the cumulative
General, Abilities, Automation, Memory, and initial Orchestrator pass on Rosy.
Only failures repaired after build `1.0.50` (`51`) are repeated here.

**Rosy result recorded 2026-09-25:** Renée's execution copy
(`Rosy_Test.md`) and screenshots confirm sections 2–4 and 7 pass, plus the
Memory Ventura controls/inspector in section 5. Qwen distillation remains
failed. Orchestrator target discovery is not accepted. The live plugin-tool
revocation boundary was not actually exercised by a structured stale call;
the model emitted DSML-like text instead. Build `1.0.52` (`53`) remains a
candidate, not a fully accepted release.

## Important tool-ownership distinction

`search_memory` in the live-revocation test belongs to Renée's personal
`renee.rag` plugin and searches her Obsidian vault. It is not Osaurus's built-in
semantic Memory tool. The test is valid: once `renee.rag` is disabled or the
tool is removed from the live allowlist, a stale provider call must be rejected,
display a terminal failed tool result, and perform no side effect. Do not
“repair” this by porting or advertising upstream `SearchMemoryTool`.

## Focused retest

### 1. Live plugin-tool revocation

- [x] Start with `renee.rag` enabled and verify its `search_memory` tool is
      genuinely offered to the disposable agent.
- [x] Disable the plugin/tool while keeping the chat open, then explicitly ask
      for `search_memory` again.
- [x] The stale request ends with a visible failed/rejected tool card and a
      concise security error. It must not spin forever or query the vault.
- [x] Re-enable the plugin, start a fresh chat, and verify the tool works again.

**Observed:** with the tool disabled, DeepSeek printed DSML-like
`search_memory` markup as ordinary assistant text (screenshot
`20260925073750`); no structured tool call or terminal tool card is visible.
This does **not** establish that the app dispatched the disabled plugin or that
the terminal rejection path failed—the boundary was not triggered in this
run. It does expose a separate model/tool-call presentation problem. Preserve
the no-execution guard and test a genuinely structured stale call before
closing this item; do not add upstream semantic Memory's `SearchMemoryTool`.
Renée clarified that `search_memory` worked while `renee.rag` was enabled;
after disabling it, the agent used the still-offered `search_knowledge` and
said `search_memory` was unavailable. Only after all tools were turned off did
it print the raw DSML-like text. Thus the normal offer/disable/re-enable
behavior passed; the all-tools-off output is not an executed plugin call.

### 2. Deleted-chat non-resurrection

- [x] Create one disposable chat for the disposable agent, then use **Delete
      Data** and confirm its row disappears.
- [x] Press New Chat, switch agents, and refresh the sidebar. The deleted chat
      must not reappear.
- [x] Quit and relaunch. The deleted chat remains absent while unrelated chats
      remain intact.

### 3. Custom-avatar live replacement

- [x] Upload image A and confirm it appears in Settings, Agents, chat header,
      and sidebar.
- [x] Replace it with visually distinct image B without relaunching. Every open
      surface changes to B; no surface retains A from its URL/image cache.
- [x] Relaunch and confirm B persists. Clear it and verify the fallback avatar
      appears everywhere.

### 4. Automation card actions

- [x] On the standalone Schedules page, each card visibly exposes **Edit**,
      **Run Now**, **Pause/Resume**, and **Delete** without an ellipsis menu.
- [x] Repeat on the standalone Watchers page. Confirm delete confirmation and
      paused manual-run behavior.

### 5. Memory provider and Ventura UI

- [x] Distill once with `osaurus/qwen-3-8-max`. OpenAI-compatible SSE returned
      despite `stream: false` and content arrays of text parts both decode into
      non-empty text; malformed/textless responses still fail visibly and keep
      pending work recoverable.
- [x] Memory scope choices (**All / Pinned / Episodes / Transcript**) and the
      agent filter are readable before and after selection on Ventura.
- [x] Open an episode inspector. It opens as a compact 720×500 sheet with
      internally scrollable details rather than filling almost the whole screen.

**Observed:** Qwen still reports an unsupported completion response at
2026-09-25 10:45:35, with the capped diagnostic beginning `data:` and a
`delta:{}` frame (screenshot `20260925074559`). DeepSeek distillation succeeds
and is a usable interim model, but it does not close Qwen compatibility. The
current fixture covers text-bearing SSE; the screenshot alone cannot prove
whether the live body contained later text, a different envelope, or only
textless frames. Capture a privacy-redacted full frame sequence or add a
realistic failing fixture before changing the decoder.

### 6. Orchestrator discovery

- [x] Admit exactly one disposable target and model. In a fresh Orchestrator
      chat ask which agents it can delegate to.
- [x] It names the admitted target and model and can use the exact target UUID
      supplied in its private fixed prompt; it does not claim there is no roster
      or ask the user to discover an internal UUID.
- [x] Remove the target, start a fresh chat, and verify the roster is empty and
      delegation fails closed.

**Observed:** the fresh built-in chat's private prompt reported an empty
roster after Renée allowed a cloud model (screenshots `20260925075154` and
`20260925075206`). The source requires **both** an allowed custom agent and
admission of that agent's **exact effective remote model**; a model toggle
alone does not create a target. Renée subsequently confirmed **both toggles
were on** in Orchestrator settings. Treat this as a real positive-path failure,
not a user-setup explanation. The remaining source-level suspects are an exact
effective-model/allowed-model identity mismatch, lost persistence, or roster
assembly from stale/different state; the current tests pass a fabricated roster
straight to the formatter and do not exercise settings → save → composer.
`Run One Turn…` is disabled when no runnable agent/model pair exists, but its
apparently inert state gave no explanatory feedback. The chat selector/empty
state shows the generic grey built-in icon while the transcript shows the green
dinosaur; this is a separate presentation defect, not evidence that the fixed
role was absent.

**Next candidate, not yet manually accepted:** Settings and chat share a
single admission evaluator; Settings prints the specific mismatch and write
failures; the built-in agent can call read-only `orchestrator_targets` for a
fresh roster. If the two switches still yield zero targets, record the status
line and the tool's `blocked` reasons (no private prompt needed). Also verify
the selector/empty-state mascot. For all-tools-off with a mounted folder,
the system prompt now omits the contradictory tool dispatch guide and says
not to print simulated tool-call markup. This does not replace the separate
structured stale-call rejection test.

For Qwen, the next candidate reports a privacy-safe `SSE shape:` summary
instead of raw SSE text and exposes **Copy response shape** in Memory Recent
Activity. Paste only that summary, not a generated Memory passage. Decoder
parity remains open until the live envelope is known.

#### Build 54 focused checks

- [x] With one allowed custom agent and its **exact effective remote model**
      admitted, Settings shows `1 admitted target` rather than a mismatch.
      If not, record the new status line.
- [x] In a fresh built-in chat, ask for the live target list. It calls
      `orchestrator_targets` and names the same agent/model/UUID. Then run one
      bounded turn; approval and output limits still apply.
- [x] Remove the model admission. The Settings status and live target tool
      both show the reason, and a stale delegate call is rejected before a
      child runs. Restore it and verify the target returns.
- [x] Check the built-in mascot in the sidebar, chat header/picker, and empty
      state; it should match the green dinosaur used in transcript messages.
- [x] With all tools off and a folder mounted, ask for a file inspection. No
      DSML/XML imitation or fabricated inspection should appear. A real
      structured stale plugin-tool call is still a separate security test.
- [x] Retest Qwen distillation once. If it fails, use **Copy response shape**
      in Memory → Diagnostics and share only that privacy-safe `SSE shape:`
      summary. Do not paste Memory text or credentials.

**Rosy report, 2026-09-25:** all other build 54 focused checks passed. Qwen
still failed; Copy response shape returned `frames=2, choices=1,
invalidFrames=0, deltaKeys=[], unknownDeltaKeys=0, contentKinds=[],
finishReasons=["length"]`. This is an output-budget exhaustion with no
assistant text, not evidence of a missed content decoder. A follow-up candidate
raises only Router Qwen distillation from 1,024 to 4,096 output tokens and
labels the error precisely; live acceptance is still required. No automatic
paid retry is added.

#### Next Qwen output-budget retest

- [x] Install the next Intel candidate and distill one short pending session
      with `osaurus/qwen-3-8-max`. Confirm a parsed episode is stored, not merely
      a successful HTTP response. This can spend Router credits; no automatic
      second request should occur.
- [x] If it remains empty, copy only the new metadata-only `SSE shape:` line
      and the error label. A repeated `finish_reason=length` at 4,096 means
      this model/provider may need a different reasoning control or a larger
      explicitly approved budget; do not silently retry or accept an empty
      Memory entry.

### 7. DeepSeek hosted API model refresh

- [x] Open the DeepSeek provider. Its current hosted models are presented as
      `deepseek-flash` and `deepseek-v4-pro`; the retired hosted alias
      `deepseek-v4-flash` is not offered as the API fallback.
- [x] Start a fresh chat with `deepseek-flash`, choose the direct/instruct rail,
      and confirm the request succeeds without silently enabling reasoning.
- [x] Switch to a reasoning rail and confirm reasoning content remains separate
      from the visible answer. Repeat a normal reply with `deepseek-v4-pro`.
- [x] Existing local DeepSeek V4 bundles or historical saved configuration still
      resolve instead of being invalidated by the hosted-API rename.

**Rosy result, 2026-09-25 (build `1.0.55`/`56`):** Renée reports every
remaining check in this retest passed, including the Qwen 4,096-token
distillation. This retest is closed.

## Automated evidence

- `IntelAgentPresentationPersistenceTests` verifies every avatar replacement
  receives a fresh URL, old bytes are removed, replacement bytes persist, and
  clearing removes the revisioned file.
- `IntelAgentRuntimeLaneTests` verifies an open stale session cannot save after
  deletion or reappear after a disk refresh.
- `IntelMemoryDistillationRegressionTests` verifies Qwen text-part JSON, Qwen
  SSE folding, textless rejection, and a terminal stale-tool rejection event.
- `IntelOrchestratorPromptTests` verifies admitted-target grounding and the
  truthful empty-roster prompt.
- `IntelVenturaRenderingTests` retains the Settings chrome and Core Model
  rendering contracts.

## Candidate

- Previous candidate: `1.0.53` (`54`),
  `build/rosy-deploy/Osaurus-Intel-RC-Admission-Final-2026-09-25.zip`, SHA-256
  `f3a38f54befb38e696d923ff67ea5095a5fa76987a9ff5b15981fe33deae1a29`.
  The earlier `Osaurus-Intel-RC-Admission-2026-09-25.zip` predates the final
  duplicate-agent-ID admission guard and must not be deployed.
- Current candidate: `1.0.54` (`55`),
  `build/rosy-deploy/Osaurus-Intel-RC-QwenBudget-2026-09-25.zip`, SHA-256
  `4a8107d72bc7c9e3aa97bb6d04ecb936dd09786e608305902e4be3ffa47df222`.
- Automated gate: **1,068 tests in 160 suites** passed under an isolated
  `/tmp` test root, serial Swift Testing. The Qwen output-budget and exact
  Rosy `finish_reason=length` shape fixtures are included. Live user data was
  not used for this automated run.
  `xcodebuild` succeeded for x86_64; ZIP integrity passed; canonical data
  flag and version/build were verified. The configured stable self-signed
  signing identity produced a signature, but `codesign --verify --deep
  --strict` on this Mac returned `CSSMERR_TP_NOT_TRUSTED`; this is a local
  certificate-trust result, not a claim of Rosy installation acceptance.
- Round-trip validation: ZIP integrity passed; extracted app is thin x86_64,
  declares macOS 13.0 minimum, has `OsaurusCanonicalData = true`, preserves six
  framework symlinks, and carries the stable Intel certificate designated
  requirement. The M4 host reports the expected `CSSMERR_TP_NOT_TRUSTED` for
  that self-signed Rosy identity; launch/Gatekeeper behavior remains Rosy's
  manual gate.
