# Search Backend Engineering Spec

> **Status (2026-06-17):** Engineering specification for TODO-8
> (Hybrid Search Backend). Decisions locked. Read together with
> `docs/PROJECT_PLAN.md` §TODO-8. No code yet — this is the
> pre-implementation contract.

---

## 0. Executive Summary

AI Spotlight's current search system is a **Spotlight query wrapper**
(`MDQuery` against `mds`), not an indexing engine. It has no local
index, no JSON, no FTS — Phase 4.2.10 removed the in-memory
`IndexStore` entirely.

This spec defines a **Hybrid Search Backend**: keep `MDQuery` as the
primary global source, add a small local **SQLite FTS5** as an
augmentation layer for things `MDQuery` cannot do (recent files,
user-scoped, ranking override), and merge the two deterministically.

**Hard boundary:** we are NOT rebuilding Spotlight. We are NOT
ingesting the full disk. We are NOT replacing `MDQuery`. The 3.1.5
5GB-RSS regression must not return.

---

## 1. Locked Decisions

| # | Question | Answer |
|---|---|---|
| Q1 | FTS5 storage mode | **B — FTS5 self-contained** (no external content table) |
| Q2 | SQLite file location | `~/Library/Application Support/AISpotlight/search_augment.sqlite` |
| Q3 | Step-1 abstraction shape | **`SearchBackend` protocol** (not inner field, not Decorator) |

### Q1 rationale (FTS5 self-contained)

- Corpus is 80k–200k files — not enterprise scale
- Augmentation only, no multi-writer, no shared external DB
- External content mode (option A) adds rowid/id mapping complexity,
  schema coupling, and debug cost for zero benefit at this scale

### Q2 rationale (Application Support)

- Matches existing `index.json` location convention
- Time Machine includes it by default
- Does not pollute repo
- `~/Library/...` is the macOS-native app data location

### Q3 rationale (protocol over inner field / Decorator)

- Inner field is fine for throwaway feature flags; this is a
  permanent hybrid system that will grow (MDQuery backend, SQLite
  backend, Hybrid backend, future LLM reranker)
- Decorator is too heavy for the current layer count; defer until
  we have an actual multi-stage pipeline (ranking → rerank → cache)
- Protocol is the only shape that survives the next 2 backends
  without rewrite

---

## 2. Architecture

```
User Query
   ↓
SearchRouter
   ↓
┌─────────────────────────────┐
│ Route Decision              │
│  - MDQueryOnly              │
│  - SQLiteOnly               │
│  - Hybrid                   │
└─────────────────────────────┘
   ↓
┌──────────────┬──────────────┐
│ MDQuery      │ SQLite FTS5  │
│ backend      │ backend      │
└──────────────┴──────────────┘
   ↓
Result Merge Layer
   ↓
Ranked Results
   ↓
UI
```

`SearchBackend` is the protocol; `MDQueryBackend` and
`SQLiteBackend` are the implementations; `HybridBackend` is the
composite that fans out and merges.

---

## 3. Routing Contract

### 3.1 Route types

- **Route A: `MDQueryOnly`** — system-wide file discovery, filename search, general text search
- **Route B: `SQLiteOnly`** — user-pinned files, recent files cache, app-generated metadata
- **Route C: `Hybrid`** — ambiguous queries, fuzzy search, ranking-sensitive queries, "best match" scenarios

### 3.2 Routing rules (defaults)

- `findFile` with terms → `Hybrid` (C)
- `findFile` by exact path → `MDQueryOnly` (A) (SQLite may be stale)
- "open recent" / "pinned" → `SQLiteOnly` (B)
- Everything else → `MDQueryOnly` (A) until proven otherwise

The router is data-driven (a function of `Intent`), not a hardcoded
`switch` — adding a new route type should be one line, not a refactor.

---

## 4. SQLite Augmentation Layer

### 4.1 Schema (Q1 = B, self-contained)

```sql
-- Bounded metadata only. No full file content.
CREATE TABLE files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT UNIQUE NOT NULL,
  filename TEXT NOT NULL,
  last_modified INTEGER NOT NULL,  -- unix timestamp
  file_type TEXT,
  is_deleted INTEGER NOT NULL DEFAULT 0
);

-- FTS5 self-contained. Indexes filename + path + bounded preview.
CREATE VIRTUAL TABLE files_fts USING fts5(
  filename,
  path,
  content_preview,   -- ≤ 2KB snippet, populated only when user explicitly asks
  tokenize = 'porter unicode61'
);

-- OPTIONAL: user_signals (separate table, NOT in core schema).
-- Only used for: pinned files, recently accessed cache.
-- MUST NOT be extended to ranking training, personalization,
-- or any ML-derived signal. This is a signal table, not a
-- behavior DB. See §4.4 below.
CREATE TABLE user_signals (
  path TEXT PRIMARY KEY,
  last_opened INTEGER,
  open_count INTEGER DEFAULT 0,
  is_pinned INTEGER DEFAULT 0
);
```

### 4.2 Hard limits (the 3.1.5 firewall)

- ❌ No full file content indexing
- ❌ No recursive filesystem crawling
- ❌ No system-wide ingestion
- ❌ No full-text search across `content_preview` for arbitrary paths
- ✔ Only: filename, path, bounded preview (≤ 2KB), user signals
- ✔ `content_preview` is populated **only** when the user has opened
  or pinned the file — never as a side effect of indexing

### 4.3 Indexing Boundary (formerly "enrollment predicate")

**Definition:** the rule that determines which paths enter the
SQLite augmentation layer. The boundary is the **only** filter
between the filesystem and our index.

**Why this matters:** without an explicit boundary, the natural
implementation drift is "crawl `/Users` and add everything" — which
is exactly the 3.1.5 5GB-RSS regression in disguise. The boundary
is the firewall.

**Properties:**
- Explicit (named rule, not a side effect of a `for` loop)
- User-visible (the user can see what's enrolled and revoke)
- Minimal default (a small set of opt-in paths; not a wildcard)
- Non-extensible (it MUST NOT grow into a policy engine, ACL
  system, or permission model — see §4.4)

**Concrete shape (TBD in Step-2 implementation):**
likely a `Set<URL>` of enrolled root paths, persisted next to the
SQLite file. The exact persistence format is deferred to Step-2.

### 4.4 Scope discipline (user_signals and friends)

`user_signals` and any future per-user table MUST stay narrowly
scoped. Forbidden extensions:

- ❌ Personalization / recommendation scores
- ❌ Implicit feedback signals ("user dwelled 3s on this row")
- ❌ ML-derived features
- ❌ Cross-session behavior tracking
- ❌ Anything that turns SQLite into a "user behavior DB"

Allowed extensions:

- ✔ Explicit user actions (open, pin, unpin)
- ✔ Counts and timestamps of those actions
- ✔ Per-path metadata that aids search relevance (e.g. custom
  tags the user adds)

If a future feature needs richer behavior modeling, it goes in a
**separate store**, not in `search_augment.sqlite`.

---

## 5. Sync Strategy

### 5.1 Source of truth

The filesystem (via `FSEvents`), but **filtered by an enrollment
predicate**. We do not watch the world.

### 5.2 Pipeline

```
FSEvent
  ↓
Debounce Queue (1–5s batch)
  ↓
Filter (enrolled paths only)
  ↓
SQLite Upsert (batch write, single transaction)
  ↓
FTS5 Update (in same transaction)
```

### 5.3 Consistency model

- Eventual consistency
- No locking with `MDQuery` (different stores, different writers)
- No dependency on `mds` state

### 5.4 Implementation note (not in this spec)

> `FSEvents` in Swift 6.4 strict-concurrency requires actor wrapping
> of the `FSEventStream` C callbacks. The exact pattern is deferred
> to Step-2 implementation; this spec only fixes the contract.

---

## 6. Result Merge & Ranking

### 6.1 Score model (Hybrid)

```
final_score =
    0.6 * mdquery_score          -- primary, from MDQuery's own ranking
  + 0.4 * sqlite_score            -- FTS5 BM25, normalized
  + recency_boost                 -- +N if opened in last 24h
  + user_scope_boost              -- +M if pinned or in user_signals
```

Weights (`0.6` / `0.4` / boost constants) are **configuration**,
not hardcoded — they live in `SearchConfig` and can be tuned
without recompile.

### 6.2 Deduplication

If the same `path` appears in both sources:
- Keep the higher `final_score`
- Merge `metadata` from both (e.g. MDQuery's `kMDItem*` + SQLite's
  `user_signals`)
- Tie-break by `mdquery_score` (MDQuery is the global truth)

### 6.3 Merge resolution rule (NOT a fallback)

**`MDQuery` is the authoritative global source.**
**`SQLite` is augmentation only.**

There is no "fallback" path. The merge is **always** dual-source:
both backends are queried (in parallel, when both apply to a route),
results are merged, dedup is applied per §6.2.

- If SQLite returns 0 rows for a `Hybrid` route query → MDQuery
  results are still returned. SQLite's silence is **not a failure
  signal**, just "no augmentation data for this query".
- If MDQuery returns 0 rows → SQLite results are still returned
  (Route B: user-pinned / recent, can be useful even if system
  index has no content match).
- The merge engine never short-circuits on one side's emptiness.

---

## 7. Cache & Invalidation

| Event | SQLite action |
|---|---|
| file created (enrolled) | insert into `files` + `files_fts` |
| file modified (enrolled) | update `files.last_modified` + `files_fts` |
| file deleted (enrolled) | soft delete: `is_deleted = 1` (never hard delete — preserves FTS5 integrity) |
| user opens file | upsert `user_signals` (`last_opened`, `open_count++`) |
| user pins file | `user_signals.is_pinned = 1` |
| MDQuery state | **never invalidated** (we don't own it) |

The SQLite store is authoritative for the augmentation layer only.
`MDQuery` is never invalidated by us; if its state is wrong, the
user runs `mdutil -i on /` themselves (documented in README "Known
issues" as part of TODO-8 Option B, even though we're going with A).

---

## 8. What NOT to Build (Hard Boundaries)

This section is non-negotiable. Any PR that violates it should be
rejected on review:

- ❌ Do NOT rebuild Spotlight
- ❌ Do NOT ingest the full disk corpus
- ❌ Do NOT store full file contents
- ❌ Do NOT replace `MDQuery`
- ❌ Do NOT create a global inverted index
- ❌ Do NOT bypass the enrollment predicate
- ❌ Do NOT touch `MDQuery`'s black-box state

---

## 9. Test Strategy

Existing 152 tests assume `MDQuery`-only. Step-1 must not break any
of them.

### 9.1 New tests (Step-1 scope) — soft validation

Step-1 must NOT touch existing runtime integration, so the 152
existing tests are not a hard gate. The soft validation is:

- Compile success (no warnings from the new files)
- Schema migration runs cleanly on a temp file
- Dry-run mode (`useSQLiteAugmentation = false`) produces zero
  observable behavior change vs. current `ContentSearchProvider`

Real test coverage is added in Step-3, when the merge engine is
implemented and we can assert actual hybrid correctness.

### 9.2 New tests (Step-2 scope)

- `FSEvent`-driven SQLite upsert (using `DispatchSourceFileSystemObject`
  in test fixtures, not real FSEvents)
- Debounce queue correctness (insert 100 events in 100ms, verify
  one batch write)

### 9.3 Performance test (Step-3 scope)

- 200k file fixture → measure RSS, query latency, ingest time
- Hard ceiling: RSS < 200MB at idle, query latency < 50ms p95
- If ceiling broken → stop, do not ship

---

### 10. Step-by-Step Execution Plan

**Constraint (applies to all steps):** Step-1 must be very thin.
No sync, no ranking, no FSEvents until Step-2 explicitly opens them.
The risk of architecture inflation is the dominant failure mode;
thickness is a code-review smell.

### Step 1 — Foundation Layer (THIS STEP)

- Create `SearchBackend` protocol (1 file, ≤ 50 lines)
- Implement `MDQueryBackend` (wrap current `ContentSearchProvider`,
  no behavior change)
- Implement empty `SQLiteBackend` (schema only, hardcoded
  connection to `~/Library/Application Support/AISpotlight/search_augment.sqlite`,
  no data writes yet)
- Add `useSQLiteAugmentation: Bool = false` feature flag in
  `SearchConfig`
- `HybridBackend` exists as a stub (default flag = false → not
  invoked)
- **No sync, no ranking, no FSEvents, no merge engine.**
- **No change to existing `ContentSearchProvider` runtime path.**

**Done criterion:** compile clean, schema migration on a temp file
succeeds, dry-run mode is byte-equivalent to current behavior.

### Step 2 — Sync Layer

- `FSEvent` → debounce → SQLite pipeline
- Indexing Boundary (§4.3) — the `Set<URL>` of enrolled paths
- Batch writes in a single transaction
- `useSQLiteAugmentation` still `false` (sync writes, queries
  still go through `MDQuery`)

### Step 3 — Merge Layer

- Implement score fusion
- Implement dedup
- `HybridBackend` route decision logic
- Tests for merge math

### Step 4 — Activation

- Flip `useSQLiteAugmentation = true` (still feature-flagged)
- Monitor RSS / latency
- Tune weights in `SearchConfig`
- After 1 week of clean metrics, consider removing the flag

---

## 11. Risk Analysis

### Risk: 3.1.5 RSS regression

**Source:** unbounded content indexing + recursive crawling.
**Mitigation:** §4.2 hard limits + §4.3 enrollment predicate +
§9.3 performance test with hard ceiling.

### Risk: `MDQuery` black-box behavior

**Source:** `mds` is a system daemon, we cannot inspect or control
it.
**Mitigation:** SQLite augmentation only stores things `MDQuery`
cannot (recent, pinned, user signal). Never try to "fix" `MDQuery`
results from outside.

### Risk: `FSEvents` strict-concurrency

**Source:** `FSEventStream` callbacks are C, not async/await.
**Mitigation:** actor wrapper, isolated to Step-2. Documented in
§5.4 as deferred to implementation.

### Risk: FTS5 query syntax mismatch

**Source:** `MATCH` expressions are not the same as MDQuery's
`kMDItemTextContent == '*x*'`. Some queries that work in MDQuery
will not work in FTS5 and vice versa.
**Mitigation:** Query translation layer (deferred to Step-3). Route
fallback: if FTS5 returns empty for a query that MDQuery matches,
fall back to MDQuery-only results for that query.

### Risk: Feature flag rot

**Source:** `useSQLiteAugmentation` flag lives forever if not
removed in Step-4.
**Mitigation:** Step-4 has explicit "consider removing the flag"
acceptance criterion. Don't ship Step-4 without addressing it.

---

## 12. Final System Definition

After this spec ships:

```
AI Spotlight Search =
    MDQuery (global truth)
    + SQLite (local intelligence layer)
    + deterministic merge engine
    + enrollment-predicate-scoped sync
```

This is **not** a rebuild of Spotlight. It is **not** a full local
index. It is **not** a 3.1.5 repeat. It is a controlled
augmentation layer over system search.
