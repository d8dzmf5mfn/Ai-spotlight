# AI Spotlight

AI-powered macOS launcher. Phase 1 MVP.

See `.hermes/plans/2026-06-14_153027-ai-spotlight-phase1-mvp.md` for the full plan.

## Phase 1 scope

- Menu bar icon (🔍) opens a Spotlight-like panel
- Rule-based query parser (English + Chinese keywords)
- Optional AI fallback (OpenAI, key in Settings)
- File search via Spotlight `MDQuery`
- App search via `/Applications` scan
- (⌘+Space hotkey deferred to Phase 2 — see Post-mortem below)

## Post-mortem (Phase 1)

Three skills encode the lessons from this build — in `~/.hermes/skills/`:

- **swift-release-logging** — `NSLog` and `print` are unreliable in SwiftPM release
  builds; always write to `/tmp` first.
- **swift-app-entry-point** — for SwiftPM `.executable` targets with AppKit, use
  `main.swift` + `NSApplication.run()`; `@main struct App` is unreliable.
- **macos-global-hotkey-diagnosis** — when global hotkey isn't firing, build a
  50-line minimal test app first; don't debug hotkey in your 2000-line main app.

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

Then click the menu bar icon (🔍) to summon the panel. Global hotkey is
deferred to Phase 2 — see "Known limitations" above.

## Architecture overview

```
Kit (testable, no UI)
  Intent, QueryParser, QueryInterpreter, ResultMerger, SearchOrchestrator
  KeychainStore (+ InMemoryKeychain for tests)
  Providers: FileSystemProvider (MDQuery), AppProvider (Launch Services), OpenAIProvider

App (SwiftUI + AppKit)
  main.swift + AppLauncher (NSApplication setup, traditional main.swift pattern)
  SpotlightPanel (NSPanel) + StatusBarController (menu bar icon — always-on fallback)
  HotkeyService (KeyboardShortcuts wrapper; ⌘+Space by default, user-rebindable)
  Settings (SettingsStore + SettingsView + FirstLaunchHelper + KeyboardShortcuts.Recorder)
  UI (SearchField, ResultListView, ResultRowView, SearchWindowView)
  AIFactory, MiniMaxProvider (stub)
```

## Testing

Unit tests:
```bash
swift test
```

5 test files, 25 tests, all green (per `swift test` output).

**Manual smoke test** (8 acceptance cases): see `~/Documents/AI-Spotlight-Testing.md` (lives outside the repo per user decision).

## Known limitations (Phase 1)

- **Hotkey rebinding UI not exposed.** Hardcoded no-op. With no hotkey
  to rebind, the surface would be misleading. (Phase 2: use
  `KeyboardShortcuts.Recorder`.)
- **MiniMax provider option removed from Settings UI.** Stub was never
  implemented end-to-end; only "None" and "OpenAI" remain.
- **No code signing / notarization** — `.app` is unsigned. Personal use only.
- **No network timeout / rate limit on OpenAI calls.** Acceptable for
  personal use; harden before wider distribution.
- **Date filters are rolling 24h / 7d / 30d**, not calendar boundaries
  ("yesterday" at 11:59 PM vs midnight is ambiguous).
- **QueryParser uses token-set matching with possessive-stripping.** Edge
  cases around word boundaries are handled, but truly novel phrasings
  (e.g. "yesterday's downloads") may still slip. Improve in Phase 3.

## Hotkey (Phase 2, shipped via `HotkeyService`)

Global hotkey via [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts)
2.4.0. **Default: ⌘+Space** (requires disabling the system Spotlight binding;
see `FirstLaunchHelper`). The user can rebind via `KeyboardShortcuts.Recorder`
in the Settings panel. The menu bar icon (🔍) is the fallback entry point
and always works regardless of system Spotlight state.

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
