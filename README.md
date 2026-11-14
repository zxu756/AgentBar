# AgentBar

**English** | **[简体中文](README.zh-CN.md)** | **[Technical Spec (`docs/SPEC.md`)](docs/SPEC.md)**

**Read-Only macOS Menu Bar & CLI Telemetry Ledger for Local Multi-Agent Workflows** (`Claude Code`, `Codex CLI`, `OpenCode`, `Mistral Vibe`, `Antigravity`, and [`agent-relay`](https://github.com/zxu756/agent-relay) `.relay/LOG.md` pipelines).

**Zero network calls · `SQLITE_OPEN_READONLY` · Zero fixed-ratio estimates · Live `中文 / EN` UI & Headless `--cli` · Zero third-party dependencies (`macOS 14.0+`)**

> **Release status (`Unreleased (after v0.2.0)`)**: Published Homebrew Cask `v0.2.0` contains the initial menu bar UI only. Headless `--cli snapshot`, `--home` / `--workspace` / `--now` / `--no-zstd`, `Scripts/test.sh`, five-level completeness (`complete` / `mismatch` / `totalOnly` / `relayOnly` / `noData`), explicit priced-vs-excluded cost notes, and streaming deduplication are **`Unreleased (after v0.2.0)`**—build from source below to use them.

![AgentBar Dashboard — DEMO preview fixture](docs/screenshot-dashboard.png)
*`[DEMO]` Dashboard rendered from deterministic synthetic preview data (`--demo` / `--export-screenshots`), never from personal local logs.*

<p align="center">
  <img src="docs/screenshot-menubar.png" width="410" alt="AgentBar Menu Bar Popover — DEMO preview fixture" />
  <br />
  <em><code>[DEMO]</code> Menu bar popover rendered from synthetic preview data.</em>
</p>

---

## What AgentBar Measures (and What It Does Not Guess)

Developers working across multiple coding CLIs (`claude`, `codex`, `opencode`, `vibe`, `agy`) split sessions across subscription burst windows, prepaid API credits, and file-handoff relays. **AgentBar** aggregates local telemetry strictly read-only in both a native SwiftUI menu bar app and a headless CLI (`AgentBar --cli snapshot [--json]`, `Unreleased (after v0.2.0)`):

- **Deduplicated Streaming Turn Accounting (`Claude Code`)**: Deduplicates multi-block streaming JSONL lines by `(message.id, requestId)` (taking final per-turn max usage) so thinking/text/tool chunks are never double-counted.
- **Verified Rollout Breakdown & Mismatch Detection (`Codex CLI`)**: Joins `threads` in `~/.codex/state_5.sqlite` with `rollout-*.jsonl` (and archived `.jsonl.zst` when `zstd` is installed) to read uncached input, cached input, and output tokens, and verifies the rollout sum against `threads.tokens_used`. If a rollout total disagrees with SQLite (`rollout != sqlite`), completeness is downgraded to `Total mismatch` (`mismatch`) with an explicit `rollout=X vs sqlite=Y` note. If no readable rollout exists, AgentBar reports `Total only` (`totalOnly`) and emits `null` (`Unknown`) for breakdown, cache hit rate, and cost—never fabricating fixed input/output ratios.
- **Five-Level Source Completeness Badges**: Every vendor and time window (`5h`, `Today`, `7d`, `30d`) is labeled `Complete`, `Total mismatch`, `Total only`, `Relay logs only`, or `No data` (and `Refreshing…` before the initial scan completes).
- **Honest API-Equivalent Cost Coverage (`rates unverified`)**: Every cost figure is labeled **`API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)`** and accompanied right beside the dollar amount by **`Covers N priced records only; M unknown-model records excluded`**. Unrecognized or internal model IDs are excluded from cost sums (`unmatchedModelCount`) instead of silently priced with a fallback model.
- **Strict `.relay/LOG.md` Baton Parser**: Parses `##` / `###` step headings (including conductor notes and multi-comma failure statuses), flushes open steps on every heading so trailing text never bleeds into an earlier step, and derives `vendor` strictly from the step heading (`NN-verify` stays `vendor: null`).
- **Live `中文 / EN` Bilingual UI & CLI**: Switch languages live via the **`中文 | EN`** header pill, `⇧⌘L`, or `--lang en|zh` (with localized Chinese data-source descriptions and labels).

---

## Per-CLI Data Sources & Completeness (`M0`)

| Harness | Local Files Read (`Read-Only`) | Typical Completeness | Notes & M0 Scope Boundaries |
|---|---|---|---|
| **Claude Code** | `~/.claude/projects/**/*.jsonl` (`message.id`, `requestId`, `message.usage`, `message.model`, `costUSD`, `timestamp`) | `Complete` (`complete`) | Deduplicated per `(message.id, requestId)` turn; per-turn timestamps. |
| **Codex CLI** | `~/.codex/state_5.sqlite` (`threads`) + `rollout_path` (`rollout-*.jsonl` / `.jsonl.zst`) | `Complete` / `Total mismatch` / `Total only` | Cross-checks rollout `total_token_usage` against `threads.tokens_used`. **M0 note**: bucketed by `threads.updated_at`; per-event day bucketing is scheduled for M1. |
| **OpenCode** | `~/.local/share/opencode/opencode.db` (`session_v2`: `cost`, `tokens_*`, `model`, `time_updated`) | `Complete` (`complete`) | **M0 note**: bucketed by `session_v2.time_updated`; per-event bucketing from `message`/`part` is scheduled for M1. |
| **Mistral Vibe** | `~/Projects/*/.relay/LOG.md` (`meta.json lacks token stats`) | `Relay logs only` (`relayOnly`) or `No data` | Current Vibe `meta.json` omits token counters (`journal/*.jsonl` parsing is scheduled for M1); never marked `Complete`. |
| **Antigravity** | `~/Projects/*/.relay/LOG.md` + `~/.gemini/antigravity-cli/log/cli-*.log` (`cli-*.log lacks token stats`) | `Relay logs only` (`relayOnly`) or `No data` | Standalone `cli-*.log` has no token counters; `.relay/LOG.md` provides unsplit step tokens without cost guessing. |

---

## Per-Model API-Equivalent Rate Table (`PriceCatalog`, `unverified`)

Rates below were inherited without live vendor-page verification during offline M0 rework; every model prefix therefore lists its official vendor pricing URL and `unverified` verification date (see [`docs/SPEC.md`](docs/SPEC.md) for matching rules and cache-hit formula `cache_read / (input + cache_read + cache_write)`):

<details>
<summary>Show all 29 per-model rate rows (unit price per 1M tokens, official source URL, verified date)</summary>

| Model Prefix | Input / 1M | Cached Input / 1M | Cache Write / 1M | Output / 1M | Official Source URL | Verified Date |
|---|---:|---:|---:|---:|---|---|
| `claude-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-3-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-4-opus` | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-3-5-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-3-7-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-4-sonnet` | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-3-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-3-5-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `claude-4-haiku` | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` |
| `gpt-6` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` |
| `gpt-5` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` |
| `codex-mini` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` |
| `o3` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` |
| `o4-mini` | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` |
| `deepseek-v4` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` |
| `deepseek-v3` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` |
| `deepseek-chat` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` |
| `deepseek-reasoner` | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` |
| `gemini-4-carbon` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini 4 carbon` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-2.5-pro` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-3-pro` | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-4-argon` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini 4 argon` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-2.0-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-2.5-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |
| `gemini-3-flash` | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` |

</details>

---

## Privacy & Security Architecture

1. **Zero Network Access**: `AgentBar` links only macOS system frameworks (`SwiftUI`, `Charts`, `AppKit`, `ServiceManagement`, `libsqlite3`) and contains zero `URLSession`, `NWConnection`, or `CFNetwork` symbols.
2. **Strictly Read-Only (`SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`)**: Local SQLite stores are opened read-only with a `250ms` busy timeout; running CLIs are never locked or modified.
3. **In-Memory Parsing — Zero Prompt Storage or Upload**: `AgentBar` reads local transcript/session files into memory to parse JSON lines and extracts only numeric token counts, model names, timestamps, costs, and directory basenames—it never stores, displays, or uploads prompt or reply text.

---

## Install & Build

### Build from Source (macOS 14.0+, Swift 6.0+)

```bash
git clone https://github.com/zxu756/AgentBar.git
cd AgentBar
swift build
./Scripts/test.sh scope Collectors Pricing RelayLog CLI Core
./Scripts/build-app.sh
open build/AgentBar.app
```

### Homebrew Cask (`v0.2.0` — pre-M0 GUI release)

```bash
brew install --cask zxu756/tap/agentbar
```

> Ad-hoc signed builds may prompt Gatekeeper on first launch; run `xattr -cr /Applications/AgentBar.app` if needed.

---

## Headless CLI & Verification Commands (`Unreleased (after v0.2.0)`)

`AgentBar` handles `--cli` before initializing `AppKit`, reading the same collector pipeline as the menu bar UI without opening windows or touching `~/Library/Preferences`. Passing a non-existent `--home <dir>` or `--workspace <dir>` exits with code `2` and an error on `stderr`; omitting `--home` scans `$HOME` and reports `No data` for uninstalled CLIs:

```bash
# CLI usage help (English / Simplified Chinese)
.build/debug/AgentBar --help --lang en
.build/debug/AgentBar --help --lang zh

# Human-readable local snapshot (English / Simplified Chinese)
.build/debug/AgentBar --cli snapshot --lang en
.build/debug/AgentBar --cli snapshot --lang zh

# Machine-readable JSON snapshot (explicit nulls for unknown breakdowns)
.build/debug/AgentBar --cli snapshot --json --lang en
.build/debug/AgentBar --cli snapshot --json --lang zh

# Synthetic [DEMO] snapshot & Retina screenshot export
.build/debug/AgentBar --cli snapshot --demo --lang en
.build/debug/AgentBar --cli snapshot --demo --lang zh
.build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang en
.build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang zh

# Run M0 acceptance ledger & README command replay
./Scripts/test.sh milestone 0
```

---

## License

MIT
