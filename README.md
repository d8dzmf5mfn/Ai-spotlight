# AI Spotlight

**AI-powered macOS launcher. ⌘+Space → search, ask, open. Bring your own AI.**

[![Platform](https://img.shields.io/badge/platform-macOS_15+-blue)](https://github.com/d8dzmf5mfn/Ai-spotlight)
[![Swift](https://img.shields.io/badge/swift-6.4-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Release](https://img.shields.io/github/v/release/d8dzmf5mfn/Ai-spotlight)](https://github.com/d8dzmf5mfn/Ai-spotlight/releases/tag/v0.6.2)

---

## What it does

AI Spotlight replaces Spotlight with a natural-language interface. You describe what you want — it finds it, opens it, or answers your question.

| You type | AI Spotlight does |
|---|---|
| `find my chemistry notes about polyester` | Searches file contents via macOS Spotlight + returns files |
| `open my Swift project` | Finds the project and opens it in Xcode |
| `what is polyester` | Answers from LLM knowledge |
| `settings` | Opens Settings window |

## Features

- **Dual Mode** — Compact Spotlight panel for quick search + full Chat mode with conversation history (resize > 900px to activate)
- **AI Native Search** — describe what you want, not what it's named
- **Bring Your Own AI** — 14 presets: OpenAI, DeepSeek, Groq, OpenRouter, Anthropic (via OpenRouter), Zhipu, Moonshot, DashScope, Doubao, Hunyuan, SiliconFlow + Ollama + LM Studio + Custom
- **Dynamic model discovery** — picks model from `GET /v1/models` automatically (Picker UI)
- **Local First** — Ollama works offline, zero API key needed
- **Tool calling** — LLM can search, open, read, list apps, run shell commands, access clipboard, and read calendar (8 built-in tools with consent gate)
- **Chat history** — conversations auto-saved to disk, browsable in sidebar
- **File upload** — attach text files and images to chat messages
- **4-step connection diagnostic** — pinpoint exactly which of URL / API key / Model / Inference failed
- **Memory layer** — remembers recent files, searches, and apps across sessions
- **User consent dialog** — destructive tools (shell, read_file, clipboard_set) require Allow/Deny
- **macOS Spotlight integration** — borrows Apple's index (0 RSS overhead, 200k+ files)

## Architecture

```
┌─ Application Layer ──────────────────────────┐
│  Search Panel  │  Menu Bar  │  Settings      │
├─ Core Engine ────────────────────────────────┤
│  SearchOrchestrator  │  LLMConversationService│
│  ToolCallParser     │  ModelDiscoveryService │
├─ Provider Layer ─────────────────────────────┤
│  OpenAI  │  Ollama  │  DeepSeek  │  Custom   │
│  14 presets, dynamic discovery via /v1/models │
├─ Search Layer ───────────────────────────────┤
│  FileSystemProvider (MDQuery via Spotlight)  │
│  AppProvider (ls /Applications)              │
│  ContentSearchProvider (kMDItemTextContent)  │
└──────────────────────────────────────────────┘
```

## Quickstart

### Download a pre-built release (recommended)

[Download v0.6.2](https://github.com/d8dzmf5mfn/Ai-spotlight/releases/tag/v0.6.2) (ad-hoc signed, not notarized — see [Project notes](#project-notes) for the Gatekeeper bypass).

### Or build from source

```bash
# Clone and build
git clone https://github.com/d8dzmf5mfn/Ai-spotlight.git
cd Ai-spotlight
swift build

# Create .app bundle
./scripts/make_app.sh

# Launch (right-click → Open on first run)
open build/AI\ Spotlight.app
```

**First launch**: the panel opens automatically. Right-click the ✨ menu bar icon for Settings.

### To use cloud models (DeepSeek, OpenAI, etc.)

1. Settings → Custom → pick a preset (e.g. DeepSeek)
2. Model Picker auto-populates from `GET /v1/models`
3. Enter your API key (saved to Keychain)
4. Click "Test connection" → green

### To use Ollama (local)

1. [Install Ollama](https://ollama.com)
2. `ollama pull gemma2:2b` (or qwen2.5:3b for better tool calling)
3. Settings → Ollama → pick model → Detect

## Provider presets

| Provider | Base URL | Auth | Model discovery |
|---|---|---|---|
| OpenAI | `api.openai.com/v1` | Bearer | `GET /v1/models` |
| DeepSeek | `api.deepseek.com/v1` | Bearer | `GET /v1/models` |
| Groq | `api.groq.com/openai/v1` | Bearer | `GET /v1/models` |
| OpenRouter | `openrouter.ai/api/v1` | Bearer | `GET /v1/models` (1000+ models) |
| Ollama | `localhost:11434` | None | `GET /api/tags` |
| Anthropic | `api.anthropic.com/v1` | `x-api-key` | Static catalog |
| LM Studio | `localhost:1234/v1` | Bearer | `GET /v1/models` |
| DashScope (通义千问) | `dashscope.aliyuncs.com` | Bearer | `GET /v1/models` |
| Doubao (豆包) | `ark.cn-beijing.volces.com` | Bearer | `GET /v1/models` |
| + 6 more | | | |

## Tool calling

The LLM can call 7 built-in tools. Destructive tools (run_shell, read_file, clipboard_set) require a consent dialog — the user must click Allow before execution.

| Tool | Command / API | Consent |
|---|---|---|
| `search_files` | `mdfind` via Process | ❌ |
| `open_file` | `open <path>` via NSWorkspace | ❌ |
| `list_apps` | `ls /Applications` via Process | ❌ |
| `run_shell` | `/bin/sh -c` via Process | ✅ |
| `read_file` | FileHandle.read (up to 64KB) | ✅ |
| `clipboard_get` | NSPasteboard.general.string | ❌ |
| `clipboard_set` | NSPasteboard.general.setString | ✅ |

Tool calling uses a system-role prompt with explicit rules:
- Call **at most one** tool per question
- After the tool returns, answer in plain text

## Current state

| Metric | Value |
|---|---|
| Tests | 183/183 passing (0 failures) |
| App RSS (idle) | ~35 MB |
| Search providers | FileSystem + Content + Apps + SQLite FTS5, per-provider weighted ranking |
| LLM support | 14 presets + custom |
| Tools | 8 built-in (search, open, list apps, shell, read file, clipboard get/set, calendar) |
| Hotkey | ⌘+Space (requires Accessibility) |

> *Test count and search-provider notes updated 2026-06-17. The older "55 commits, 149/152 tests" figures are stale.* See [`docs/AUDIT_2026-06-17.md`](docs/AUDIT_2026-06-17.md) and [`docs/PROJECT_PLAN.md`](docs/PROJECT_PLAN.md) for the current roadmap.

## Known issues

1. **Tool calling loop with DeepSeek** — occasionally calls multiple tools before answering. Set `maxToolTurns: 2` in `LLMConversationService` if it loops.
2. **Ollama idle unload** — 5-minute default. Run `launchctl setenv OLLAMA_KEEP_ALIVE 24h && killall ollama && open -a Ollama`.
3. **Large model OOM** — models ≥7B may crash Ollama on 16GB Macs. Use gemma2:2b or qwen2.5:3b.
4. **LLMIntentRouter disabled by default** — see commit history. Each keystroke would otherwise fire a separate LLM call (Phase 4.2.5 decision). LLM is still active via the `askWithTools` path on Enter. See `Sources/AISpotlight/main.swift:124` for the wiring point.

## Building from source

**Requirements**: Swift 6.4+, macOS 15+, Xcode 27+ (not required but recommended).

```bash
git clone https://github.com/d8dzmf5mfn/Ai-spotlight.git
cd Ai-spotlight
swift build -c release
./scripts/make_app.sh
open build/AI\ Spotlight.app
```

The build produces a standalone `.app` bundle in `build/`. No Xcode project needed.

## Distribution (DMG)

Build a redistributable DMG after `./scripts/make_app.sh`:

```bash
./scripts/make_dmg.sh
```

Produces `build/AI-Spotlight-v0.6.x.dmg` — a drag-to-Applications installer
(volname `AI Spotlight v0.6.x`).

**Notes:**
- Version is **hardcoded to v0.6.2** in `scripts/make_dmg.sh`. Bump `DMG_NAME` and `-volname` when cutting a new release.
- DMG is **ad-hoc signed only** (inherited from `make_app.sh`), not notarized. First launch requires right-click → Open to bypass Gatekeeper.
- `build/AI-Spotlight-Installer.dmg` is a pre-v0.6.2 artifact; the current script no longer generates it.

## License

MIT

## Project notes

- **LLM-assisted development.** This project is edited with AI coding assistants. Sessions can be interrupted or wiped at any time, so the workflow is: commit early, commit often, and run `./scripts/snapshot.sh` at the end of every session. See [`docs/WORKFLOW.md`](docs/WORKFLOW.md) for the full convention.
- **DMG on GitHub Releases (ad-hoc, not notarized).** The v0.6.2 `.dmg` is published as a GitHub Release. Because the binary is **ad-hoc signed only** (no Apple Developer ID, no notarization), first launch on macOS Sonoma or later will trigger Gatekeeper's "cannot verify developer" warning. Users must either right-click → Open, or run `xattr -d com.apple.quarantine /Applications/AI\ Spotlight.app` after install. See the Releases page for download.
- **AI tooling folder.** The `.hermes/` directory at the repo root is per-machine LLM tooling (skills, debug notes). It is intentionally uncommitted.
