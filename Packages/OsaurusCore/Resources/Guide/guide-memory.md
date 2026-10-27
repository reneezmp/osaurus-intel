---
title: Memory
summary: What Osaurus learns from conversations, how distillation works on this Mac, and how to inspect or clear it.
order: 100
---

# Memory

Memory is what Osaurus learns from your conversations; Knowledge is what you teach it from your own documents (see Knowledge Collections). Both stay on your Mac.

## How it works

- Osaurus distills conversations into compact memory — your identity, pinned facts, and episode summaries — and adds only a small relevant slice to each turn, never a full transcript.
- On this Mac distillation runs on a cloud model, the **Core Model** (Settings → General). Because that can cost money and sends the conversation to that model, distillation is **opt-in per agent and off by default**: Settings → Memory → Diagnostics lists each agent with on/off and an **Enable** button. **Distill pending** runs the queue now. If no Core Model is set, distillation doesn't run and Memory says so.
- Recall (using what was learned) and distillation are separate: an agent can use memory in its context without distilling new chats.

## Managing memory

- Settings… (⌘,) → Memory: the Memory console (search, inspect, forget items), your Identity, **Your Overrides** (explicit facts always included), episode retention, consolidation, diagnostics, a bounded context preview, and Clear All Memory (irreversible).
- Per-agent **Memory Recall** (a `search_memory` tool) is a separate opt-in: agent → Abilities → Overview → Memory Recall.

## Storage

Memory lives in `~/.osaurus/memory/memory.sqlite`, encrypted with the storage key; its settings are in `~/.osaurus/config/memory.json`.
