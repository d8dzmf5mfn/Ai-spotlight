# AI Spotlight

AI-powered macOS launcher. Phase 1 MVP.

See `.hermes/plans/2026-06-14_153027-ai-spotlight-phase1-mvp.md` for the full plan.

## Phase 1 scope
- ⌘+Space opens a Spotlight-like panel
- Rule-based query parser (English + Chinese keywords)
- Optional AI fallback (OpenAI, key in Settings)
- File search via Spotlight `MDQuery`
- App search via `/Applications` scan
- First-launch helper guides user to free ⌘+Space from macOS Spotlight

## Run

```bash
swift build
swift run AISpotlight           # dev mode (no .app bundle)
./scripts/make_app.sh           # bundle as .app → build/AI Spotlight.app
```

To launch the .app:
```bash
open "build/AI Spotlight.app"   # first time: right-click → Open (Gatekeeper)
```

## Testing

Unit tests:
```bash
swift test
```

5 test files, 25 tests, all green (per `swift test` output).

**Manual smoke test** (8 acceptance cases): see `~/Documents/AI-Spotlight-Testing.md` (lives outside the repo per user decision).

## Known limitations (Phase 1)

- **QueryParser uses token-set matching with possessive-stripping.** Edge cases around word boundaries are handled, but truly novel phrasings (e.g. "yesterday's downloads") may still slip. Acceptable for Phase 1's 8 manual test cases; improve in Phase 3.
- **Hotkey rebinding is not exposed in Settings UI.** Hardcoded to ⌘+Space. A surface that didn't actually rewire the hotkey was removed to avoid misleading users; real rebinding lands with a proper text-field recorder in Phase 2.
- **MiniMax provider option removed from Settings.** The provider stub was never implemented end-to-end; Settings now only shows "None" and "OpenAI". Add back when MiniMaxProvider is real (Phase 2).
- **No code signing / notarization** — `.app` is unsigned. Personal use only.
- **No network timeout / rate limit on OpenAI calls.** Acceptable for personal use; harden before wider distribution.
- **Date filters are rolling 24h / 7d / 30d**, not calendar boundaries ("yesterday" at 11:59 PM vs midnight is ambiguous).
- **Cross-Space hotkey may not fire** while fullscreen apps have focus — known Apple limitation of `NSEvent.addGlobalMonitorForEvents`.

## Architecture overview

```
Kit (testable, no UI)
  Intent, QueryParser, QueryInterpreter, ResultMerger, SearchOrchestrator
  KeychainStore (+ InMemoryKeychain for tests)
  Providers: FileSystemProvider (MDQuery), AppProvider (Launch Services), OpenAIProvider

App (SwiftUI + AppKit)
  AISpotlightApp (@main) + AppDelegate → wires everything together
  SpotlightPanel (NSPanel) + HotkeyManager (NSEvent global monitor)
  Settings (SettingsStore + SettingsView + FirstLaunchHelper)
  UI (SearchField, ResultListView, ResultRowView, SearchWindowView)
  AIFactory, MiniMaxProvider (stub)
```
