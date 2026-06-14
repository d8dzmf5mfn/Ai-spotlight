# AI Spotlight

AI-powered macOS launcher. Phase 1 MVP.

See `.hermes/plans/2026-06-14_153027-ai-spotlight-phase1-mvp.md` for the full plan.

## Phase 1 scope
- ⌘+Space opens a Spotlight-like panel
- Rule-based query parser (English + Chinese keywords)
- Optional AI fallback (OpenAI / MiniMax, key in Settings)
- File search via Spotlight `MDQuery`
- App search via `/Applications` scan
- All 4 test suites pass: `swift test`

## Run

```bash
swift build
swift run AISpotlight     # dev mode
./scripts/make_app.sh    # bundle as .app
```

## Known limitations (Phase 1)

- **QueryParser uses substring matching, not word boundaries.** Edge cases: `open` in "shower" or "opening" can false-trigger find-verb logic; `show` in "shower"/"showcase" can too. Acceptable for Phase 1's 8 manual test cases; fix in Phase 3 with proper tokenization.
- **No first-responder focus on panel show** — typing into the panel requires clicking the field first time. Fix in Task 18 smoke test bug-bash.
- **MiniMax provider is a stub** in Task 16. Falls back to rule-based. OpenAI works.
- **No code signing / notarization** — `.app` is unsigned. Personal use only.

## Test

```bash
swift test
```

Phase 1 acceptance: 4 test files, 13+ tests, all green.
