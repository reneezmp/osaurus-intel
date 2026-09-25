# M4 Pre-format Handoff — 2026-09-19

This is the preservation and resumption map before Renée formats the M4. The
release cut from this state is a usable checkpoint with known Partial areas; it
is not the end of Rosy's full acceptance pass.

## Current Rosy result

The Native Ventura controls and message-chrome group is substantially repaired:
themes match upstream, traffic lights and carets render, controls are readable,
the Knowledge creation/detail surfaces are usable, and completed messages show
TTFT, tok/s, tokens, and actions.

Known remaining fixes:

1. Settings uses a separate light native titlebar. Evaluate reusing chat's
   integrated full-size chrome, preserving visible/clickable Ventura controls.
2. Knowledge Agents with Access switches did not visibly or globally apply the
   grant. The observable-store repair is implemented; verify persistence and
   runtime access in fresh and restored chats, then retest the shipped build on
   Rosy.
3. Knowledge collection cards now have inline Edit and indexed
   categorized/uncategorized status; verify both on Rosy.

### Knowledge grant diagnosis and automated gate (2026-09-21)

The source-level cause of the failed Agents with Access interaction is now
identified. Intel stores the per-agent Knowledge grant in the private
`AgentManager.knowledgeGrants` sidecar. `updateKnowledgeSettings` writes that
dictionary, persists `knowledge/agent-grants.json`, bumps the capability
revision, and posts `.agentUpdated`, but previously did not publish an
`AgentManager` object change. The Knowledge detail sheet and collection cards
observe `AgentManager.shared`; their grant values are derived inside SwiftUI
bindings/body evaluation, so the write can succeed while the visible switch
and card count remain stale. This is a UI-observability defect in addition to
the runtime/persistence acceptance gap; it is not evidence that a grant should
be moved into collection storage.

The focused implementation test
`IntelAgentRuntimeLaneTests.knowledgeGrantPublishesPersistsAndRevokesRuntimeAccess`
now covers observed-object publication, sidecar-file writes, capability
revision advancement, positive direct dispatch, and revocation denial. The
older
`IntelAgentRuntimeLaneTests.dispatchRejectsWebSearchAndKnowledgeWithoutTheirGrants`
continues to cover the no-grant denial envelope. Before Rosy retest, the
focused Knowledge lane must still prove: (1) the sidecar survives a manager
reload/relaunch boundary, and (2) a granted collection is searchable from both
a new session and a session restored from `ChatSessionData.agentId`, while
revocation denies both paths. Tests that override `OsaurusPaths` must hold
`StoragePathsTestLock` for the complete setup, execution, and cleanup. These
automated gates are implementation evidence only; the Rosy items below remain
unchecked until the shipped x86_64 candidate is retested.

Validation on 2026-09-21 passed all **9 tests in 1 suite** selected by
`--filter IntelAgentRuntimeLaneTests` with an isolated `OSAURUS_TEST_ROOT`.
The package runner reported an ARM target despite the `arch -x86_64` wrapper,
so Intel compilation was verified separately with the explicit repository gate
`swift build --package-path Packages/OsaurusCore --arch x86_64`, which passed.

## Main acceptance work still open

The authoritative item-level list remains
[`ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`](ROSY_FINAL_ACCEPTANCE_CHECKLIST.md).
The focused Knowledge repair gate is
[`ROSY_2026-09-21_KNOWLEDGE_PARITY_RETEST.md`](ROSY_2026-09-21_KNOWLEDGE_PARITY_RETEST.md).
Resume these groups after the machine is restored:

- Agent model isolation: a chat-local model change must not rewrite Settings.
- Agent General/Appearance: Claude Code controls, Delete Data reachability, and
  custom-avatar synchronization.
- Abilities/Tools: live open-chat tool revocation, unavailable explanations,
  Self-scheduling gating, and Memory off/on after distillation is healthy.
- Automation: readable controls plus complete schedule/watcher edit, pause,
  resume, run, folder inheritance, response, relaunch, and delete flows.
- Memory: distillation, pinned facts, episode summaries, compact empty state,
  and injection/saving boundaries.
- Orchestrator: chat tool exposure, admitted-target enforcement, scoped approval,
  bounded child execution, result lifecycle, target removal, and prompt/avatar
  parity.
- Declarative configuration: preview, approval, persistence, stale-plan and
  replay rejection, unsupported/secret-shaped input denial.
- Model-callable `orchestrator_config`: exposure, planning, approval card,
  apply/cancel, persistence, stale-plan rejection, cancellation, and policy.
- Final regression/postflight after all repaired groups pass.

Owner-deferred field testing remains deferred for Credits/Router, Channels,
Browser Use, Computer Use, cloud Media, Privacy, and later chat/Workspaces.
Native Web Search has already received the owner's acceptance pass.

## Preservation rule

Before formatting, verify the branch and release exist remotely and retain all
user-authored manuals. Build products and Swift/Xcode caches are reproducible;
untracked documents, stashes, ignored source, and local-only branches are not.
