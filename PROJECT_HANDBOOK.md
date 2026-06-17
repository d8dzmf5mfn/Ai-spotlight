# AI Spotlight — Project Handbook

> Quick-start for a new session on this repo. Read this file FIRST
> before doing any work. Read order:
> 1. PROJECT_HANDBOOK.md (this file)
> 2. README.md
> 3. docs/PROJECT_PLAN.md (TODOs, priorities)
> 4. docs/SEARCH_BACKEND.md (only if working on TODO-8)
> 5. docs/STEP1_PLAN.md (only if working on TODO-8 Step-1+)
> 6. docs/AUDIT_2026-06-17.md (only if validating claims about the codebase)
> 7. git log --oneline -20 (recent history)
> 8. ./scripts/snapshot.sh (state of uncommitted work)

## Repo facts

- **Repo:** `/Users/chengziyan/Developer/AI-Spotlight`
- **Remote:** git@github.com:d8dzmf5mfn/Ai-spotlight.git (SSH)
- **Build:** `swift build -c release` or `./scripts/make_app.sh` for a .app bundle
- **Test:** `swift test` (176 tests as of 2026-06-17)
- **Release:** v0.6.0 published on GitHub Releases (ad-hoc signed DMG, NOT notarized)
- **Tools:** SwiftPM 5.9, Swift 6.4 target, macOS 14+ deployment, Xcode 27+
- **Branch:** main, no other active branches

## Module layout

| Target | Path | Role |
|---|---|---|
| `AISpotlightKit` | `Sources/AISpotlightKit/` | Core library, Foundation-only. Search, providers, LLM, tools, memory. ~32 .swift files. |
| `AISpotlightMac` | `Sources/AISpotlightMac/` | AppKit-bridged extensions (rich text extraction). ~2 files. |
| `AISpotlight` | `Sources/AISpotlight/` | Executable target. SwiftUI views, AppState, Settings, hotkey wiring. ~15 files. |
| Tests | `Tests/AISpotlightKitTests/` | 23 test files, 176 tests. |

## Build artifacts

- `build/AI Spotlight.app/` — local dev bundle (NOT in git)
- `build/AI-Spotlight-v0.6.0.dmg` — release artifact (NOT in git)
- `build/.build/` — SwiftPM artifacts (NOT in git)

## Recent commits (2026-06-17 session)

- `07f410f` Revert "feat(search): Step-3 SQLite backend wiring + Settings layout polish"
- `350dd4b` feat(search): Step-3 SQLite backend wiring + Settings layout polish (REVERTED — broke Settings UI)
- `5fcdb88` feat(search): Step-2 schema migration in SQLiteBackend
- `f738a6e` docs: add 'Download a pre-built release' link to Quickstart
- `c802ff5` docs: README - update DMG distribution posture for GitHub Releases
- `af83bed` docs: record Step-2 linking spike result (auto-link works on this toolchain)
- `1313a63` docs(audit): §11.1 verified — AppState is cohesive wide class
- `0bd1cc5` docs: fix README drift (test count, QueryInterpreter, router state)
- `87dfa07` feat(ranking): per-provider weight in ResultMerger (TODO-11 partial)

## Open TODOs (from PROJECT_PLAN.md)

- **TODO-8 (active direction):** Hybrid Search Backend.
  - Step-1 ✅: `SQLiteBackend` stub with `SearchProvider` conformance. Empty `search()`.
  - Step-2 ✅: Schema migration (files + files_fts FTS5 + indexes).
  - Step-3 wiring: REVERTED by `07f410f`. Need to redo WITHOUT the layout refactor that broke Settings.
  - Step-3 follow-up: implement actual FTS5 query in `SQLiteBackend.search()`.
  - Step-4: activate the toggle by default.
  - Files: `Sources/AISpotlightKit/Search/SQLiteBackend.swift`, `Sources/AISpotlightKit/Search/SearchConfig.swift`, `Sources/AISpotlightKit/Providers/SearchProvider.swift`, `Sources/AISpotlightKit/ResultMerger.swift`, `Sources/AISpotlightKit/SearchOrchestrator.swift`, `Sources/AISpotlight/main.swift`, `Sources/AISpotlight/Settings/SettingsStore.swift`.

- **TODO-9 (deferred):** AI engagement level (Lazy / Hybrid / Eager). User decided "not B architecture" — incremental evolution, frozen at Lazy.

- **TODO-10 ✅:** AppState verification done. AppState is a cohesive wide class, NOT a god object. See audit §11.1.

- **TODO-11 (ranking):** Soft normalization landed (`87dfa07` — per-provider weights: fileSystem 1.0, contentSearch 1.2, app 1.1, sqliteAugmentation 0.0). Real ranking contract is a separate, larger change.

- **TODO-1..7:** Sparkle/Apple Developer Program/Phase numbering. Not actionable until user decides.

## Known fragility (read before touching SettingsView)

**`SettingsView.body` is sensitive to layout refactors.** On 2026-06-17 a layout refactor (Form + Group → VStack + SettingsCard) compiled cleanly but rendered as an empty window in production. The Settings window was completely blank (only title bar + Done button). No SwiftUI runtime assertion. Print debugging in body was NOT triggered, suggesting the body was never evaluated (or evaluated to empty without tracing).

**Working hypothesis:** `SettingsCard<Content: View>` with `@ViewBuilder var content: () -> Content` may fail SwiftUI generic inference in some body contexts, causing the body to render empty.

**Mitigation when resuming the layout refactor:**
1. Use SwiftUI Previews (`#Preview { SettingsView(store: SettingsStore()).frame(width: 600, height: 700) }`) — visual feedback without launching the app.
2. Add a tiny `.background(.red)` to the body and a `print` — if the window is blank but the background is red, body was evaluated but empty; if no red, body wasn't evaluated at all.
3. Commit the layout refactor and the Step-3 wiring as SEPARATE commits so a bad layout can be reverted without losing the wiring.

## Tooling / setup

- **Launch app for visual testing:** `open "build/AI Spotlight.app"` (right-click → Open first time, Gatekeeper ad-hoc warning).
- **Build .app:** `./scripts/make_app.sh`.
- **Release flow:** `./scripts/make_dmg.sh` (output `build/AI-Spotlight-v0.6.0.dmg`). Release via `gh release create v0.6.X --generate-notes --draft` then `gh release edit vX.Y.Z --draft=false`.
- **Session end protocol:** run `./scripts/snapshot.sh` to see uncommitted state before exit.
- **Test filter:** `swift test --filter <ClassName>` to run a subset.

## Skill: `verifying-before-narrating`

Lives at `~/.hermes/skills/verifying-before-narrating/SKILL.md`. USE THIS at the start of any non-trivial work. Distilled from this session's 7+ overreach incidents. Key points:
- Verify every fact a conclusion rests on. If inferred from structure, label it `INFERRED`. If reasoning about product/intent, label `INTERPRETIVE`.
- "X is done" requires both X exists AND X looks like expected. `git status M` is necessary, not sufficient.
- Never propose a build fix without running the build and seeing the failure. (LinkerSettings guessing on 2026-06-17 was a violation.)
- Reversible steps execute. Irreversible steps (public release, push, commit to main) always confirm.

## Common pitfalls in this repo

1. **`import SQLite3` works directly** in SwiftPM 5.9 on macOS 14+ SDK — no `linkerSettings`, no `systemLibrary` target. Verified by the 2026-06-17 spike (later reverted; see `/tmp/sqlite-linking-spike` if you need to re-spike). The test target's SwiftUnit tests cannot easily import raw SQLite3 C symbols; use the production `SQLiteBackend.migrateSchemaIfNeeded(at:)` entry point instead.

2. **`LLMIntentRouter` is intentionally unwired** in `main.swift:124`. Do not "fix" the commented-out line without explicit user approval — it's a Phase 4.2.5 decision.

3. **`AISpotlightMac` target exists to avoid an XCTest+AppKit deadlock** on macOS 27 beta. Don't merge it back into `AISpotlightKit`.

4. **`ContentSearchProvider` adds +100 to its raw score** as a hard-coded "content > filename" preference. Combined with `AppProvider` prefix match (+100) and `FileSystemProvider` (0..N-1), this means multi-hit queries rank unpredictably. The `ResultMerger.providerWeight(_:)` table is the current workaround. See TODO-11 and audit §11.2.

5. **`SettingsWindowController.show()` is non-activating.** It uses `NSWindowCollectionBehavior.fullScreenAuxiliary`. This is intentional (Settings should not steal focus from the search panel), but it means `pkill AISpotlight` + relaunch is the only reliable way to test Settings after a code change.

## Style / conventions

- Swift 6 strict-concurrency is the target but currently emitting warnings (not errors).
- Phase-prefixed commit messages: `feat(phase6-step1):`, `docs(phase6-step1):`, `fix(phase5-J):`.
- Doc files use `# Heading` (ATX), fenced code blocks, no emojis.
- README updates go through a separate commit from code changes.

## Next-session checklist

Before any non-trivial work:

1. `git status` and `git log --oneline -10` — see where we are.
2. Read PROJECT_HANDBOOK.md (this file).
3. Read docs/PROJECT_PLAN.md — see open TODOs and their status.
4. Run `./scripts/snapshot.sh` — see any uncommitted state from previous session.
5. Pick ONE TODO. Don't try to fix multiple in one session.
6. Verify before editing (read the code, don't infer).
7. Test before committing (`swift build` + `swift test` + launch app for visual changes).
8. Commit small. Commit often. End session with `.snapshot.sh` clean or with TODO comments in uncommitted files.
