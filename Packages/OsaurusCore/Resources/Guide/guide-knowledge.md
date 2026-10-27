---
title: Knowledge Collections
summary: Curated folders of documents that agents search and read on demand — human-governed, never modified without approval.
order: 105
---

# Knowledge Collections

Knowledge is what you teach your agents: a library of your own documents (SOPs, templates, standards, how-tos) that granted agents search and read on demand. Memory is what an agent learns from conversations; knowledge is explicit, versioned, and human-governed.

## Setup

1. Settings… (⌘,) → Knowledge → **Add Collection** — point it at any folder of guides, templates, standards, or an exported wiki.
2. Open a custom agent → Abilities → Overview → **Knowledge** — enable the toggle and choose the collections that agent may use.
3. Chat. The agent can search, list, and read the granted library when a task calls for it.

Files are indexed in place and never moved. Edits made to the folder outside Osaurus are re-indexed within a few seconds. Markdown, MDX, and plain text are read directly. PDF, Word, Excel, PowerPoint, CSV, source-code, and other formats supported by Osaurus's document adapters are converted to searchable text locally. Optional YAML frontmatter (`type`, `title`, `description`, `tags`) improves filtering and display.

Projects can share collections too. Open a project and select collections in its **Knowledge** section; every chat in that project receives those collections in addition to the running custom agent's own grants.

## Grants and safety

- Grants are per agent and enforced when a search or read runs — an agent cannot reach a collection it was not granted.
- Disabling a collection removes it from retrieval while keeping its registration available for later.
- Reading never changes your folder. Writing is a separate, approved step (below).
- The index is derived data. The folder remains the source of truth and can be backed up or edited independently.

## Writing documents

Granted agents can also write markdown documents (`.md`, `.markdown`, `.mdx`) in a collection — never other file types, and never outside the collection's folder:

- `write_knowledge` creates or replaces whole documents and `edit_knowledge` edits inside one; both ask first (with a diff of each document) unless you choose Always Allow.
- `delete_knowledge` asks on every call.
- Every change is logged before the file is touched. Knowledge → **History** lists the runs; revert a whole run or one document. A revert refuses to discard a later edit you made yourself.

## Limits and storage

The registry and derived index live under `~/.osaurus/knowledge/`. Indexing accepts up to 5,000 files per collection, with a 2 MB limit for text and a 10 MB limit for adapted documents. Removing a collection deletes only its registry entry and derived index rows; it never deletes the selected source folder.

The SQLCipher index is disposable. If a copied index belongs to another device key, is corrupt, or uses a newer schema, Osaurus quarantines only `knowledge.sqlite` and its sidecars under `~/.osaurus/knowledge/quarantine/`, then rebuilds from the copied collection registry and original source folders. The cached local `potion-base-8M` model adds semantic search; full-text search remains available without it.
