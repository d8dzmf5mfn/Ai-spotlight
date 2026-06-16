# AI Spotlight

AI-powered macOS launcher — **Phase 5+** (Provider architecture rewrite)

⌘+Space → search, ask, open. Bring your own AI (local or cloud).

## Current state (June 2026)

| Dimension | Status |
|---|---|
| **Commits** | 54 in main |
| **Tests** | 149/152 (3 pre-existing QueryInterpreter failures) |
| **App RSS** | ~35MB (idle) |
| **Providers** | 14 presets, dynamic model discovery via `/v1/models` |
| **Tool calling** | 3 tools (search_files, open_file, list_apps), system role + few-shot, DeepSeek-ready |
| **Search** | macOS Spotlight via MDQuery (0 RSS overhead) |

## Phase 5 — Provider architecture (latest)

The old `ProviderPreset` struct conflated 4 independent concerns. The new architecture:

```
ProviderDescriptor (auth + discovery + health strategy enums)
  ↓
ProviderRegistry (14 descriptors: OpenAI, DeepSeek, Groq, OpenRouter, Anthropic, Ollama, ...)
  ↓
ModelDiscoveryService (4 strategies: openAIListModels, ollamaTags, staticCatalog, none)
  ↓
SettingsView Picker (auto-populated from GET /v1/models)
```

Key changes from earlier commits:

- **`ProviderDescriptor` + `Registry`** (Phase 5-A) — each provider describes its own auth style (`bearer` / `apiKeyHeader` / `none`), discovery strategy (`openAIListModels` / `ollamaTags` / `staticCatalog` / `none`), and health check strategy. 14 providers included.
- **`ModelDiscoveryService`** (Phase 5-B) — actor with 24h cache. Fetches `GET /v1/models` for OpenAI-style providers, `GET /api/tags` for Ollama, uses `staticCatalog` for Anthropic. Populates the Settings model Picker automatically.
- **`SettingsStore` wiring fix** (Phase 5-F) — `SettingsView` used `@StateObject` creating a fresh store with `liveProvider = nil`; `pushConfigToProvider` silently did nothing. Fixed by passing `main.swift`'s store through `SettingsWindowController(store:)`.
- **`applyPreset` URL fix** (Phase 5-E) — guard `if customBaseURL.isEmpty` prevented URL from updating when switching presets. Fixed: always overwrite.
- **`customAPIKey` Keychain persistence** (Phase 5-E) — `didSet` only called `pushConfigToProvider()`, never saved to Keychain. Fixed: save on every change, delete on empty.

## Tool calling (Phase 4.3)

LLM can search, open, and list files on the user's Mac:

- `search_files` — `mdfind` via macOS Spotlight. Capped client-side (`-maxresults` not supported). Max 20 results.
- `open_file` — `open <path>` via NSWorkspace.
- `list_apps` — `ls /Applications` + `~/Applications`.

Prompt architecture:
- **System role** contains tool schema + intent classification rules
- **User role** contains history (6 turns cap) + latest question
- **`<<TOOL_SYSTEM>>` marker** — split by `encodeAskBody` into system + user messages
- **Rules**: "Call AT MOST ONE tool per question. After the tool returns, answer in plain text."
- **maxToolTurns**: 3 (up from 2 for DeepSeek compatibility)

## How to run

```bash
git clone ...
cd AI-Spotlight
swift build
./scripts/make_app.sh
open build/AI\ Spotlight.app
```

First launch: the panel opens automatically. Right-click the ✨ menu bar icon for Settings.

## Settings

- **Provider**: None (rule-based only) / Ollama (local) / Custom (any OpenAI-compatible API)
- **DeepSeek preset**: auto-populates URL + model Picker from `GET /v1/models`
- **Test connection**: 4-step diagnostic (in progress — currently single POST /chat/completions)
- **Hotkey**: ⌘+Space (requires Accessibility permission)
- **Content Index**: toggle source code / rich text file scanning

## Known limitations

- **Anthropic native**: uses `x-api-key` header, not Bearer; no `/v1/models` endpoint. Works via OpenRouter (OpenAI-compatible proxy).
- **Tool calling loop**: DeepSeek occasionally loops on tool calls even with maxToolTurns=3. Reduce to 1-2 or switch model.
- **QueryInterpreter tests**: 2 pre-existing failures (disabled AI router from Phase 4.2.6).
- **Ollama idle unload**: 5-minute default. Run `launchctl setenv OLLAMA_KEEP_ALIVE 24h && killall ollama && open -a Ollama` to extend.

## Skills (.hermes/skills/)

The project has generated ~22 skills covering: provider architecture, inline tool calling, LLM conversation state, search provider protocol, borrow-the-platform-search-index, and more. Most relevant for AI Spotlight development:

- `ai-provider-integration` — multi-provider architecture reference
- `inline-tool-calling-dont-use-a-framework` — inline tool calling in 300 lines
- `borrow-the-platform-search-index` — MDQuery over self-built index
- `llm-conversation-history-in-state` — 6-turn cap + state management
- `ship-the-wiring-not-the-architecture` — the discipline that prevents over-engineering

## Credits

Built with Hermes Agent (Nous Research) and a fully automated SwiftPM toolchain. No Xcode project required.
