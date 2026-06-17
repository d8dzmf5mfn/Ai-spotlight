# AI Spotlight — Project Plan

> **Provenance (2026-06-17)**: This document combines two sources:
>
> 1. **"Original plan (recovered)"** — pasted by the user on 2026-06-17,
>    claimed to be the long-lost planning document from an earlier LLM
>    session. **This session cannot independently verify that claim.**
>    Evidence for/against authenticity:
>    - The document references a model named **Minimax** that does not
>      appear in any commit, code, `.hermes/` note, or current provider
>      list. User has stated this was a planned-but-never-integrated
>      test target for cloud LLM connectivity. **Accepted as a
>      historical note, not verified.**
>    - The phase numbering scheme (Phase 1 = MVP, Phase 2 = AI,
>      Phase 3 = Index, Phase 4 = Tool Calling, Phase 5 = Cloud)
>      does **not** match the actual commit-message phase tags
>      (Phase 3.x = content search, Phase 4.x = LLM integration,
>      Phase 5.x = Tool Calling + Provider refactor). The recovered
>      plan is therefore either (a) a high-level vision document
>      written before the current numbering convention existed, or
>      (b) a post-hoc reconstruction. The diff in §3 below reconciles
>      both interpretations against reality.
>
> 2. **"Synthesized plan"** — reverse-engineered from `git log`,
>    `.hermes/` retrospective notes, and `4.7-architecture-redesign.md`.
>    This is the reliable source for *what actually happened*.
>
> **Last updated:** 2026-06-17

---

## 1. Original plan (recovered)

> _Pasted by the user 2026-06-17. Verbatim. Provenance caveats above._

> **Historical note on "Minimax"**: The original planning draft
> referenced a model named "Minimax" as a possible cloud LLM
> candidate alongside Ollama and OpenAI. The identity of this model
> is **unverified** — it does not appear in any commit, code,
> `.hermes/` note, or the current 14-preset provider list. Per user
> 2026-06-17, it was a planned-but-never-integrated target.
> Reference preserved for historical completeness; **no code or
> configuration currently targets it**. Active providers (per
> `README.md` and `scripts/make_app.sh`-era commit history):
> OpenAI, DeepSeek, Groq, OpenRouter, Anthropic, Zhipu, Moonshot,
> DashScope, Doubao, Hunyuan, SiliconFlow, Ollama, LM Studio,
> Custom.

### 1.0 Project goal

Build a Spotlight + Siri-style unified entry point on macOS supporting:
- File search
- App search
- Natural-language query
- AI agent tool calling
- Future cloud expansion

> "Spotlight is not a search tool, but an AI-driven system entry layer."

### 1.1 System architecture (original sketch)

```
Hotkey Trigger
    ↓
Floating Panel (UI / Input)
    ↓
Intent Router (LLM)
    ↓
File Search | App Search | AI Answer
    ↓
Result Merge
    ↓
UI Display
```

### 1.2 Module decomposition

- **Hotkey Layer** — global hotkey, panel toggle, non-blocking
- **UI Layer** — floating window, command palette input, result list, loading state
- **Intent Router** — natural language → structured intent (type / query / confidence)
- **File Search Engine** — Phase 1: recursive FileManager + name match. Phase 2: background indexer + visitedDirectories cache. Phase 3: SQLite FTS5 / inverted index.
- **App Search Engine** — `/Applications` scan, bundle id index, fuzzy match
- **AI Answer Layer** — Q&A, summary, file content explanation (later)
- **Tool Calling Layer** — `LLM → Tool Router → System Action`. Tools: File / App / System / Web.

### 1.3 Original phase roadmap

| Phase | Title | Scope |
|---|---|---|
| 1 | MVP | panel UI, hotkey, file name search, basic app search |
| 2 | AI Integration | intent classification, natural language search, simple routing |
| 3 | Index System | background indexer, perf optimization, memory reduction |
| 4 | Tool Calling | AI agent capability, system actions, file/app control |
| 5 | Cloud Expansion | cloud LLM fallback, hybrid local/cloud, multi-model (Ollama / Minimax / OpenAI) |

### 1.4 Performance principles (original)

- ❌ No runtime full disk scan
- ❌ No AI directly traversing filesystem
- ❌ No blocking UI thread
- ✅ Background indexing
- ✅ Incremental updates
- ✅ Cached results
- ✅ Lazy loading

---

## 2. Synthesized plan (from git + .hermes)

This project was developed in clearly-numbered phases. The commit-message
convention is `<major>.<minor>.<patch>` and `<major>-<letter>`.

| Phase | Title | Status | Evidence |
|---|---|---|---|
| 3.1 | Content-aware search | ✅ Shipped | `.hermes/3.1-verification-report-v2.md` |
| 3.1.1–3.1.6 | IndexStore, TextExtractor, ContentIndexer, ContentSearchProvider, IndexManager, Orchestrator wiring | ✅ Shipped | 94/94 unit tests in 3.1 report |
| 4.2.5 | LLM dev tooling — 18 skills catalog | ✅ Shipped | `.hermes/4.2.5-skills-catalog.md` |
| 4.2.7 | Skill integration testing | ✅ Shipped | `.hermes/4.2.7-step1-results.md` |
| 4.3.x | LLM tool-calling reliability (4.3.3–4.3.7) | ✅ Shipped | commit log |
| 4.4 | Clickable LLM reply + tool progress UI | ✅ Shipped | `feat(phase4.4)` |
| 4.6 | Cloud-model preset picker (Chinese + intl) | ⛔ Superseded by 4.7 + 5-A | `feat(phase4.6)`, removed in `228ea0` |
| 4.7 | Provider architecture redesign (ProviderDescriptor) | ⛔ Self-criticized, replaced by 5-A | `.hermes/4.7-architecture-redesign.md` |
| 5-A | ProviderDescriptor + ProviderRegistry | ✅ Shipped | `228490b refactor(phase5-A)` |
| 5-B | ModelDiscoveryService + Picker UI | ✅ Shipped | `b6b8695 feat(phase5-B)` |
| 5-C | 4-step ConnectionDiagnosticService | ✅ Shipped | `97d65e4 feat(phase5-C)` |
| 5-D | Ollama section uses 4-row diagnostic UI | ✅ Shipped | `03effae feat(phase5-D)` |
| 5-E | Test connection verifies `choices`; debounce flush on Enter | ✅ Shipped | `ca13b8a`, `185388c` |
| 5-F | User consent dialog + `run_shell`; live provider re-wiring | ✅ Shipped | `9c07380`, `6bdaeb1` |
| 5-G | MemoryStore (recent files/searches/apps) | ✅ Shipped | `d0f0763 feat(phase5-G)` |
| 5-H | `read_file` + clipboard tools; auto-discover models at launch | ✅ Shipped | `34e59f3`, `002f013` |
| 5-I | Strip file-system terminology from tool description | ✅ Shipped | `361b7ca` |
| 5-J | Stop DeepSeek tool-calling loop (max 1 tool) | ✅ Shipped | `bb479bc` |
| **6 (planned)** | Distribution: ad-hoc DMG → GitHub Releases → Sparkle auto-update | 🚧 In progress | this commit + `scripts/release.sh` |
| **7 (future)** | Developer ID + notarization (when user base justifies $99) | 📋 Deferred | TBD |

---

## 3. Diff: original plan vs actual execution

| Original Phase | Planned | Actual (commit / file) | Notes |
|---|---|---|---|
| 1 (MVP) | panel UI, hotkey, file name search, basic app search | ⌘+Space hotkey + `AppLauncher` + `FileSystemProvider` (MDQuery) + `AppProvider` (`ls /Applications`) | ✅ All shipped. File search uses **MDQuery** (borrowed from macOS Spotlight), not recursive FileManager — deviation but better. |
| 2 (AI Integration) | intent classification, simple routing | `LLMConversationService` + `IntentRouter` (LLM-based, not rule-based) + `QueryInterpreter` (rules fallback when AI router disabled) | ⚠️ Implementation is **LLM-first**, not rule-first. QueryInterpreter exists as disabled fallback. |
| 3 (Index System) | background indexer, perf, memory reduction | `IndexStore` (JSON) + `ContentIndexer` + symlink cycle detection + batched actor ingest | ✅ Shipped, but postmortem notes a 5GB RSS bug during first ingest on 80k files. Mitigation: `IndexManager` `@MainActor` rewrite. **Not** using SQLite FTS5 (planned Phase 3) — using JSON. Trade-off acknowledged in `.hermes/3.1.5-perf-root-cause.md`. |
| 4 (Tool Calling) | AI agent capability, system actions | **Delayed to Phase 5** (5-F, 5-H). Original intent of Phase 4 was apparently absorbed into provider work. | 🔀 Phase numbering shifted. Tools shipped: `search_files`, `open_file`, `list_apps`, `run_shell`, `read_file`, `clipboard_get`, `clipboard_set` (7 tools). |
| 5 (Cloud Expansion) | cloud LLM fallback, hybrid, multi-model (Ollama / **Minimax** / OpenAI) | **Started in Phase 4.6** (cloud-model preset picker). 14 provider presets. **Minimax was never integrated** — confirmed by user 2026-06-17 as "planned but never used". | 🔀 Phase 5 was repurposed for Provider architecture + Tool Calling. Cloud work happened earlier than planned. |

### Key architectural deviations

1. **File search backend**: MDQuery (Spotlight) instead of recursive FileManager. Chose to borrow Apple's index rather than maintain our own. This is *why* Phase 3 (Index System) was less work than planned — the heavy lifting is OS-level.
2. **Intent routing is LLM-first, not rule-first**: Original Phase 2 said "intent classification" as if a separate step. Actual implementation makes the LLM itself classify via structured output. This is more flexible but has a hard dependency on LLM availability.
3. **Tool Calling is its own phase (5)**, not Phase 4 as planned. This is because the Provider architecture (also Phase 5) had to mature before tools could be wired in.
4. **Minimax never integrated**: No code, no commit, no `ProviderPreset` for it. Per user 2026-06-17, it was a planned-but-cancelled target.
5. **Indexing uses JSON, not SQLite FTS5**: Trade-off documented in `.hermes/3.1.5-perf-root-cause.md`. Future work: migrate when ingest > 100k files.

---

## 4. Open / pending work (TODO list for next session)

> **Carried over from session 2026-06-17.** Each TODO has an owner note
> indicating what the user must decide vs. what the agent can do
> autonomously.

### TODO-1: Decide Sparkle key custody
- **What:** Sparkle 2.x needs a DSA keypair. Private key signs update
  feed; public key goes into `Info.plist`. Private key is irreplaceable
  (lose it = can't sign future updates, all users must reinstall).
- **Owner:** User
- **Decision needed:** Where to store the private key. Recommended:
  macOS Keychain + encrypted backup (1Password / USB). Reject: git.
- **Blocked on:** Nothing. User can decide anytime.

### TODO-2: Generate Sparkle keypair
- **What:** Run Sparkle's `./generate_keys` tool, paste public key back
  to agent.
- **Owner:** User (agent can run the tool with explicit approval)
- **Blocked on:** TODO-1 (need to know where to save the private key)

### TODO-3: First GitHub Release
- **What:** `gh release create v0.6.0 build/AI-Spotlight-v0.6.0.dmg
  --generate-notes --draft`
- **Owner:** User (agent will not run `gh release create` —
  irreversible public action, and the user's existing GitHub PAT was
  previously flagged by secret scanning).
- **Blocked on:** None. `scripts/release.sh 0.6.0` is ready.

### TODO-4: Sparkle Info.plist + Package.swift integration
- **What:** Add Sparkle SPM dep, add 4 Info.plist keys
  (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUAllowsAutomaticUpdates`), write `scripts/sign_update.sh`.
- **Owner:** Agent (can do this once TODO-2 supplies the public key)
- **Blocked on:** TODO-2

### TODO-5: Apple Developer Program ($99) — when?
- **What:** Upgrade ad-hoc DMG → Developer ID + notarization.
- **Owner:** User (financial decision)
- **Recommendation:** Defer until user count justifies. Per the
  `4.7-architecture-redesign.md` posture, this is a "personal
  project, users tolerate Gatekeeper bypass via right-click Open"
  decision until proven otherwise.

### TODO-6: Original plan authenticity
- **What:** Independently verify whether §1 is the actual original
  document or a post-hoc reconstruction.
- **Owner:** User (only the user has the original conversation history)
- **Status:** Documented as unverified in §provenance above.

### TODO-7: Phase roadmap reconciliation (deferred)
- **What:** Some external reviewers have suggested re-aligning the
  project phase numbering to (Phase 3 = Search, Phase 4 = AI
  Routing, Phase 5 = Distribution / Sparkle). This conflicts with
  the commit-message phase tags, which are (Phase 3.x = search,
  Phase 4.x = LLM/provider, Phase 5.x = Provider + Tool Calling).
- **Owner:** User (decision affects how the next 20+ commits get
  tagged)
- **Status:** Not adopted. Current numbering follows `git log`.
  Re-tag the entire history is out of scope.

### TODO-8: Search backend augmentation (REDEFINED, 2026-06-17 — active direction)

> **Status:** Active direction, not a "PENDING decision". Spec
> landed in `docs/SEARCH_BACKEND.md` (2026-06-17). Step-1 plan
> landed in `docs/STEP1_PLAN.md`. Step-1 is a thin foundation;
> the architecture is a 4-step rollout.

**Direction (locked 2026-06-17):** Hybrid (Option A).
- **MDQuery** = authoritative global source
- **SQLite FTS5** (`~/Library/Application Support/AISpotlight/search_augment.sqlite`)
  = augmentation layer only, scoped by an **Indexing Boundary**
  (not full-disk crawl)
- **SearchBackend protocol** = the Step-1 abstraction shape
  (not inner field, not Decorator)
- **Hard boundary:** no rebuild of Spotlight, no full content
  indexing, no replacement of MDQuery

**Sub-steps:**

- **Step 1 — Foundation Layer** (plan in `docs/STEP1_PLAN.md`):
  `SearchBackend` protocol + `MDQueryBackend` + empty
  `SQLiteBackend` + `useSQLiteAugmentation = false` flag.
  Additive only. ≤ 4 new files, ≤ 250 lines. No runtime
  integration.
- **Step 2 — Sync Layer:** FSEvents → debounce → SQLite pipeline,
  Indexing Boundary persistence. Sync writes only; queries
  still go through MDQuery.
- **Step 3 — Merge Layer:** Score fusion, dedup, HybridBackend
  route decision. Real test coverage of merge math.
- **Step 4 — Activation:** Flip `useSQLiteAugmentation = true`,
  monitor RSS / latency, tune weights, consider removing flag
  after 1 week of clean metrics.

**Anti-inflation rule:** if Step-1 grows beyond the
≤ 4 files / ≤ 250 lines bound, it has failed. Stop and ask.

**Architectural review:** the §4.4 "scope discipline" clause
in `docs/SEARCH_BACKEND.md` is non-negotiable — `user_signals`
and any future per-user table MUST stay narrowly scoped.
Forbidden: personalization, implicit feedback, ML-derived
features, cross-session tracking.

**Open items (not in Step-1):**
- `HybridBackend` shape (Step-3)
- Score fusion math (Step-3)
- FSEvents actor wrapping for Swift 6.4 strict-concurrency
  (Step-2, see `docs/SEARCH_BACKEND.md` §5.4)
- `Indexing Boundary` `Set<URL>` persistence format (Step-2)

### TODO-9: Define AI engagement level in QueryInterpreter pipeline

- **What:** AI router is currently disabled (intentional, Phase 4.2.5). Three product modes are possible:
  - **Lazy (current):** LLM only on Enter via `runLLMAsk`. Deterministic rule-based routing. Zero keystroke latency.
  - **Hybrid:** rule-based first; LLM only for `.unknown` or ambiguous queries.
  - **Eager (historical README vision):** LLM on every keystroke via `LLMIntentRouter`. Highest intelligence, highest cost, highest latency.
- **Why deferred:** current focus is "stabilize Query/Search first, then AI". This is intentionally postponed per user 2026-06-17.
- **Status:** PENDING. Decision deferred until search backend (TODO-8) and ranking contract (TODO-11) are stable.

### TODO-10: Verify §11.1 AppState god-object hypothesis

- **What:** `docs/AUDIT_2026-06-17.md` §11.1 claims `AppState` (853 lines) is a god object with 10 responsibilities, untested, with load-bearing singleton assumption. The "10 responsibilities" count is **derived from public method count**, not from a real coupling analysis. Treat as **hypothesis**, not fact, until verified.
- **What verification looks like:** read `AppState.swift` §168–225 (init) and §331–360 (runLLMAsk header). Determine whether the 10 "responsibilities" are *coupled* (cross-domain side-effect entanglement) or *layered* (small but with clear boundaries).
- **Status:** PENDING verification. Audit committed 2026-06-17 without this verification.

### TODO-11: Define ranking contract (normalization layer for inter-provider score compatibility)

- **What:** `docs/AUDIT_2026-06-17.md` §11.2 verified that `FileSystemProvider` (score 0..20), `ContentSearchProvider` (100..120, +100 base), and `AppProvider` (10 or 100, prefix-boost) all assign scores on **incompatible scales**. `ResultMerger.merge()` sorts them as if directly comparable. The system works today only because most queries hit one provider. Multi-provider queries (rare but real) produce unpredictable ranking.
- **What a contract looks like (sketch, not implementation):** every `SearchProvider` returns a score in a normalized space (e.g. `[0, 1]`); `ResultMerger` operates on normalized scores. The `ContentSearch` +100 base and `AppProvider` prefix +100 are *semantic signals* (content > filename, prefix > substring), not raw score boosts; they should be expressed as per-bucket weights, not per-result score offsets.
- **Why this blocks Step-2 / Step-3:** adding a fourth provider (SQLite augmentation) to a fan-out that is already broken by score-scale mismatch silently compounds the bug. Defining the contract is a prerequisite to safely adding more providers.
- **Status:** PENDING. Design and implementation deferred to a later session.

---

## Read order for LLM context recovery

If you (or a future LLM session) are picking this project up cold:

1. `README.md` — what the app is, how to build
2. `docs/WORKFLOW.md` — session safety / commit discipline
3. `docs/PROJECT_PLAN.md` — phases shipped, what's open
4. `docs/SEARCH_BACKEND.md` — active TODO-8 architecture spec
   (Hybrid: MDQuery + SQLite FTS5)
5. `docs/STEP1_PLAN.md` — Step-1 implementation task list
   (read this BEFORE writing any code for Step-1)
6. `.hermes/3.1-verification-report-v2.md` — content search postmortem
7. `.hermes/4.7-architecture-redesign.md` — provider refactor self-critique
8. `.hermes/5.0-governor-401-issue/` — current bug investigation notes
9. `git log --oneline` — full history
