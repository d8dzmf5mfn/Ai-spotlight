# AI Spotlight

**AI-powered macOS launcher. ⌘+Space → search, ask, open. Bring your own AI.**

[![Platform](https://img.shields.io/badge/platform-macOS_15+-blue)](https://github.com/d8dzmf5mfn/Ai-spotlight)
[![Swift](https://img.shields.io/badge/swift-6.4-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

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

- **AI Native Search** — describe what you want, not what it's named
- **Bring Your Own AI** — 14 presets: OpenAI, DeepSeek, Groq, OpenRouter, Anthropic (via OpenRouter), Zhipu, Moonshot, DashScope, Doubao, Hunyuan, SiliconFlow + Ollama + LM Studio + Custom
- **Dynamic model discovery** — picks model from `GET /v1/models` automatically (Picker UI)
- **Local First** — Ollama works offline, zero API key needed
- **Tool calling** — LLM can search, open, read, and list files, run shell commands, and access clipboard (7 built-in tools with consent gate)
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
| Commits | 55 |
| Tests | 149/152 (3 pre-existing) |
| App RSS (idle) | ~35 MB |
| Search provider | macOS Spotlight MDQuery |
| LLM support | 14 presets + custom |
| Hotkey | ⌘+Space (requires Accessibility) |

## Known issues

1. **Tool calling loop with DeepSeek** — occasionally calls multiple tools before answering. Set `maxToolTurns: 2` in `LLMConversationService` if it loops.
2. **2 QueryInterpreter test failures** — pre-existing, disabled AI router.
3. **Ollama idle unload** — 5-minute default. Run `launchctl setenv OLLAMA_KEEP_ALIVE 24h && killall ollama && open -a Ollama`.
4. **Large model OOM** — models ≥7B may crash Ollama on 16GB Macs. Use gemma2:2b or qwen2.5:3b.

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

## License

MIT
