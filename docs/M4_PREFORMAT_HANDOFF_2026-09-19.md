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
2. Knowledge Agents with Access switches do not visibly or globally apply the
   grant. Repair the observable store update and verify runtime access in fresh
   and restored chats.
3. Knowledge collection cards need an inline Edit action and
   categorized/uncategorized status matching upstream.

## Main acceptance work still open

The authoritative item-level list remains
[`ROSY_FINAL_ACCEPTANCE_CHECKLIST.md`](ROSY_FINAL_ACCEPTANCE_CHECKLIST.md).
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
