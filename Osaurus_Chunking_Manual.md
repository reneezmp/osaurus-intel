# Osaurus Chunking Manual 🧠

How the Intel Knowledge indexer turns your files into searchable chunks, and how to write files so they chunk *beautifully*. Every rule here is anchored to the real code so you can verify it yourself.

**Source of truth:**
- `Packages/OsaurusCore/Services/Knowledge/KnowledgeDocumentParser.swift`
- `Packages/OsaurusCore/Services/Knowledge/KnowledgeIndexService.swift`
- `Packages/OsaurusCore/Services/Knowledge/KnowledgeSearchService.swift`

---

## The pipeline at a glance 🏗️

```
source folder
   │  scan (md/markdown/mdx/txt read raw; other formats via adapters)
   ▼
extract text
   │  KnowledgeDocumentParser.parse()  → strips YAML frontmatter
   ▼
body
   │  KnowledgeDocumentParser.chunk() → heading-aware sections, size-split
   ▼
chunks (headingPath + content)
   │  FTS index + embeddings (headingPath is embedded too!)
   ▼
hybrid search (BM25 text + vector cosine)
```

---

## The rules, in plain language 📜

### 1. YAML frontmatter is metadata only — it is NOT searched 🔒
An opening `---` on the **very first line** opens a frontmatter block, closed by the next `---` or `...`. Recognized fields:

| Key | Stored as | Notes |
|---|---|---|
| `type` | docType | free text |
| `title` | title | used as the document title |
| `description` | summary | free text |
| `tags` | tagsCSV | list (`- a` or `[a, b]`), **lowercased** |

Any other field (e.g. `time:`, `participants:`) falls into a generic `extras` bucket that is **stored nowhere and never embedded**. Frontmatter lines must start at column 0 (no leading space/tab).

> ⚠️ Retrievable info (names, dates, people) must live in the **body**, not frontmatter.

### 2. Headings `#`…`######` are the ONLY structural boundaries ✂️
Every ATX heading — any level from 1 to 6 — starts a new section. Conditions:
- 1–6 `#` characters, followed by a **space**, then non-empty text
- leading whitespace is tolerated
- a heading **clears all deeper sub-headings** and starts a fresh breadcrumb

`##` is not special; `###`, `####`, etc. all split too. `#`/`##`/`###` is a stylistic choice, not a parsing one.

### 3. `---` horizontal rules are DECORATIVE 💤
A bare `---` in the body does **nothing** — it is not a chunk boundary. It becomes a stray line glued onto the previous chunk's tail. The only `---` that matter are the frontmatter fences at the very top.

> 💡 **Nota (Renée):** nada impede manter `---` como **separador visual entre seções `##`** para leitura/escaneamento no Obsidian. Funciona porque é só cosmético; o cuidado é **não tratar o `---` como limite** — quem delimita o chunk é o heading. Então pode-se usar um `---` entre tópicos **desde que cada tópico tenha o próprio `##`**. Mantenha-os **entre** headings, jamais no lugar de um heading, e nunca substitua um `##` por `---` (senão o tópico vira ruído e some da busca).

### 4. Sections only split when too big 📏
Each heading section becomes **one chunk** unless it exceeds **2,400 characters** (`maxChunkChars`). Then:
- split on **blank lines** (paragraphs, i.e. `\n\n`), greedily packing toward a **1,600-char target**
- any leftover paragraph-group still over 2,400 is hard-cut at 2,400 chars (may split mid-word)

So: paragraphs separated by blank lines = clean cut points. A wall of text = ugly hard cuts.

### 5. Code fences protect their contents 🔐
Lines starting with ```` ``` ```` or `~~~` toggle a fence. Headings **inside** fences are ignored as boundaries.

### 6. Heading breadcrumbs are meaningful 🧭
Chunks remember their nesting as a path joined with ` > `, e.g. `2026-09-09 · Planejamento > Riscos`. That path is **embedded and FTS-indexed alongside the content**, so topic names are searchable even before the body text.

### 7. Empty sections vanish 🫥
A heading with no real content produces **no chunk** — its heading never makes it into retrieval. Don't leave empty headings around.

---

## Retrieval: what actually gets searched 🔎

Search is **hybrid**:
1. **Lexical (FTS5, BM25)** over `content` + `heading_path`
2. **Semantic (vector cosine)** when the cached local embedding model is present — the vector is computed over `headingPath + "\n" + content` (or just `content` when the path is empty)

Result: meaningful heading words help *both* retrievers. Retrieval is per-chunk, so the chunk is your unit of truth — make each chunk self-contained.

---

## Anatomy of a well-formed document 🧬

```markdown
---                          ← frontmatter fence (metadata ONLY: type/title/description/tags)
title: 2026-09-09 · Planejamento do Sprint
tags: [planejamento, sprint]
---

# 2026-09-09 · Planejamento do Sprint     ← H1 = document-level breadcrumb

## Dados da reunião                        ← retrievable details live HERE (not YAML)
- Data: 2026-09-09 · 14:00
- Participantes: Renée, Jacques, Rumi

## Cronograma                              ← one topic = one chunk
Parágrafo um sobre o cronograma.

Parágrafo dois, separado por linha em branco
para dar ao split() um ponto de corte limpo.

## Riscos
**Mitigação:** rótulo em negrito NÃO quebra o chunk.

- item solto também fica no mesmo chunk.
```

Chunks produced: `Dados da reunião`, `Cronograma`, `Riscos` — plus their breadcrumbs inherit the H1.

---

## Do's & Don'ts ✅🚫

| ✅ Do | ✅ Why |
|---|---|
| One `# H1` per file | All topics nest under a clean breadcrumb |
| Write **meaningful, keyword-rich headings** | Boosted in both FTS and vector search |
| Put people/dates/details in a body section | They're only retrievable if they're in the body |
| Keep each topic ≤ ~2,400 chars | Stays ONE atomic chunk |
| Separate paragraphs with **blank lines** | Clean split points for oversized sections |
| Use `---` only as the top frontmatter fence, OR as a **visual** separator between `##` sections | Cosmetic only; headings still do the chunking |
| Use `###` for genuinely self-contained subsections | Each becomes its own retrievable unit |
| Use `**bold:**`/bullets for light sub-labels | Structure without fragmenting the chunk |

| 🚫 Don't | 🚫 Why |
|---|---|
| Rely on `---` as a section divider **instead of a heading** | It's not a boundary — just tail noise. (OK as a visual separator between topics, **as long as each topic keeps its own `##` heading**) |
| Put searchable facts *only* in YAML | Never embedded; frontmatter extras are dropped |
| Write 2,400+ char walls with no blank lines | Hard mid-word cuts |
| Leave empty headings | They produce zero chunks and vanish |
| Repeat the same H1 level carelessly | Every heading fragments retrieval granularity |

---

## Non-heading files (.txt, imported docs) 📄

Files without markdown headings (plain text or adapter-extracted docs) become **one preamble section with an empty heading path**, split purely by size at paragraph boundaries. For those, blank-line discipline is everything. If you want structure, add real `##` headings.

---

## Quick reference ⚡

| Question | Answer |
|---|---|
| What starts a new chunk? | Any `#`–`######` heading (with space + text) |
| Does `##` beat `#`? | No — all levels behave identically |
| Does `---` separate chunks? | No. Decorative except frontmatter fences |
| What splits oversized sections? | Blank lines, packing toward ~1,600 chars |
| Hard cap per chunk? | 2,400 chars (hard cut above that) |
| Are headings searchable? | Yes — embedded and FTS-indexed as a breadcrumb |
| Is frontmatter searchable? | No — metadata only |
| Which files are scanned? | `md`, `markdown`, `mdx`, `txt` + adapter-supported docs (≤2 MB / 10 MB, ≤5,000 files) |
