# AgentBar `v0.2.0`

**English** | **[简体中文](README.zh-CN.md)**

**Native macOS Menu Bar & Swift Charts Telemetry Monitor for Multi-Agent Coding Workflows** (`Claude Code`, `Codex CLI`, `OpenCode`, `Mistral Vibe`, `Antigravity`, and [`agent-relay`](https://github.com/zxu756/agent-relay) pipelines).

**Zero network calls · `SQLITE_OPEN_READONLY` · Live `中文 / EN` Bilingual UI · Zero third-party dependencies · Pure SwiftPM (`macOS 14.0+`)**

![AgentBar Dashboard](docs/screenshot-dashboard.png)

<p align="center">
  <img src="docs/screenshot-menubar.png" width="410" alt="AgentBar Menu Bar Popover" />
</p>

---

## Why AgentBar?

Developers running modern multi-CLI coding harnesses (`claude`, `codex`, `opencode`, `vibe`, `agy`) split work across flat-rate 5-hour burst windows, prepaid API credits, and headless file-handoff relays—yet usage visibility is scattered across incompatible SQLite databases, JSONL transcripts, and `.relay/LOG.md` files.

**AgentBar `v0.2.0`** unifies all five harnesses into a ~1.5 MB native SwiftUI + Swift Charts instrument panel that sits quietly in your macOS menu bar:

- **Proportional Multi-CLI Fuel Strip**: Instant breakdown of today's API-equivalent spend and token volume across Claude Code, Codex CLI, OpenCode, Mistral Vibe, and Antigravity.
- **5-Hour Rolling Burst Gauges**: Tracks rolling 5-hour token velocity per CLI alongside 24-hour HTTP `429` / `RESOURCE_EXHAUSTED` rate-limit counters.
- **14-Day Stacked Velocity Chart (`Swift Charts`)**: Toggle between daily API-equivalent USD spend and million-token throughput.
- **Prompt Cache Efficiency**: Computes real cache-read hit ratios (`cache_read / (input + cache_read + cache_write)`) per CLI.
- **Native [`agent-relay`](https://github.com/zxu756/agent-relay) Baton Inspector**: Automatically discovers `<workspace>/*/.relay/LOG.md` pipelines and surfaces step durations, active models, per-baton costs, and flagged statuses.
- **Live `中文 / EN` Bilingual Switching (`v0.2.0`)**: Auto-detects Simplified Chinese macOS system locales on first launch, provides a one-click **`中文 | EN`** segmented pill in both the main ledger header and menu bar popover, supports `⇧⌘L` (`切换语言 / Toggle Language`), and accepts `--lang zh|en` from the CLI.

---

## Privacy & Security Architecture

Unlike Electron dashboards or cloud proxies that ask for session cookies, OAuth tokens, or API keys:

1. **Zero Network Access**: `AgentBar` never imports `URLSession` or opens sockets. Nothing ever leaves your Mac.
2. **Strictly Read-Only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`)**: Local SQLite databases (`~/.codex/state_5.sqlite`, `~/.local/share/opencode/opencode.db`) are opened strictly read-only with a `250ms` busy timeout so running CLIs are never locked or mutated.
3. **Metadata Only — Never Reads Prompts**: JSONL and SQLite collectors extract only numeric token counters, `cost`, `model` IDs, timestamps, and basename project labels—prompt and assistant message bodies are never read into memory.

| Harness | Local Telemetry Source Read (Read-Only) |
|---|---|
| **Claude Code** | `~/.claude/projects/*/*.jsonl` (`message.usage`, `message.model`, `costUSD`, `timestamp`) |
| **Codex CLI** | `~/.codex/state_5.sqlite` (`threads`: `tokens_used`, `model`, `updated_at`, `cwd`) |
| **OpenCode** | `~/.local/share/opencode/opencode.db` (`session_v2`: `cost`, `tokens_*`, `model`, `time_updated`) |
| **Mistral Vibe** | `~/.vibe/logs/session/unified/*/meta.json` + `.relay/LOG.md` batons |
| **Antigravity** | `~/.gemini/antigravity-cli/log/cli-*.log` (`label="..."` active model & `429` markers) + `.relay/LOG.md` |
| **agent-relay** | `~/Projects/*/.relay/LOG.md` (`## NN-agent` step headers, duration, cost, tokens) |

---

## Install (`v0.2.0`)

### Homebrew Cask (Recommended)

```bash
brew install --cask zxu756/tap/agentbar
```

> Since builds are ad-hoc signed rather than notarized with a paid Apple Developer ID, run `xattr -cr /Applications/AgentBar.app` on first launch if Gatekeeper prompts.

### Build from Source (Zero `.xcodeproj`)

Requires macOS 14.0+ (Sonoma or newer) and Swift 6.0+ / Command Line Tools:

```bash
git clone https://github.com/zxu756/AgentBar.git
cd AgentBar
swift test --no-parallel
./Scripts/build-app.sh
open build/AgentBar.app
```

---

## License

MIT
