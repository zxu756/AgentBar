# AgentBar Technical Specification (`M0 / Honest Baseline`)

This specification defines the data-collection contracts, completeness taxonomy, API-equivalent pricing rules, and headless CLI schema for **AgentBar** (`v0.2.0`, branch `m0/honest`).

---

## 1. Safety, Privacy & Honesty Invariants

1. **Zero Network Access**: `Sources/` never imports or calls `URLSession`, `NWConnection`, or `CFNetwork`. Static symbol checks (`nm -u`) enforce zero network client symbols in release builds.
2. **Strictly Read-Only Storage Access**:
   - SQLite databases (`~/.codex/state_5.sqlite`, `~/.local/share/opencode/opencode.db`) are opened exclusively with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` and a `250ms` busy timeout.
   - JSONL, `.jsonl.zst`, `.log`, and `.relay/LOG.md` files are read without mutation.
   - Headless `--cli` commands never write to `~/Library/Preferences/local.xu.AgentBar.plist` or `~/Library/Application Support/`.
3. **Metadata Only — Zero Prompt Capture**: Collectors inspect only numeric token counters, model identifiers, timestamps, cost fields, and workspace/project basenames. User prompts, assistant replies, and tool payloads are never stored or printed.
4. **Zero Fixed-Ratio Fabrication**:
   - Fixed input/output split heuristics (`0.85 / 0.15`, `0.80 / 0.20`) are prohibited across `Sources/`.
   - Whenever input/cache/output breakdown or pricing cannot be verified from local records, fields are emitted as JSON `null` and rendered in UI/CLI as `Unknown` (`未知`) or `No data` (`没有数据`).
   - Initial GUI startup before the first scan finishes renders `Refreshing…` (`刷新中…`), distinct from post-scan `No data` (`没有数据`).
   - Marketing screenshots and `--demo` runs use `DemoSnapshotFactory.makePreviewSnapshot()` with `isDemoData = true` and render an explicit `DEMO` (`DEMO · 演示数据`) badge.

---

## 2. Per-Vendor Data Sources & Completeness Taxonomy

Every vendor summary and time window (`fiveHours`, `today`, `sevenDays`, `thirtyDays`) carries a `completeness` value from four levels:

| Enum (`JSON`) | English Label | Simplified Chinese Label | Meaning |
|---|---|---|---|
| `complete` | `Complete` | `完整` | Verified uncached input, output, cache-read, and cache-write token breakdown from standalone local logs/DB. |
| `totalOnly` | `Total only` | `只有总量` | Only aggregate `totalTokens` is available (e.g., a Codex thread whose rollout file is missing); breakdown, cache hit rate, and unrecorded API cost are `null`. |
| `relayOnly` | `Relay logs only` | `只有接力里的部分` | Standalone CLI logs do not expose token usage counters in M0; figures come only from `<workspace>/*/.relay/LOG.md` steps. |
| `noData` | `No data` | `没有数据` | Zero local records exist in the evaluated window. |

### Vendor Collection Rules

1. **Claude Code (`claude`)** — `~/.claude/projects/**/*.jsonl`
   - Claude Code writes one `type: "assistant"` JSONL line per streamed content block (`thinking`, `text`, `tool_use`), repeating cumulative `message.usage` under the same `(message.id, requestId)` pair.
   - `collectClaudeSamples` deduplicates all assistant usage lines by `(message.id, requestId)` (falling back to `message.id` or `requestId` if one is absent, and per-line key only when both are absent), taking the element-wise `max` across `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` so each assistant turn is counted **once**.
   - Completeness: `complete` when `recordCount > 0`.

2. **Codex CLI (`codex`)** — `~/.codex/state_5.sqlite` + `threads.rollout_path` (`.jsonl` / `.jsonl.zst`)
   - Queries `SELECT id, cwd, tokens_used, updated_at, model, rollout_path FROM threads WHERE tokens_used > 0`.
   - Reads the final `event_msg` (`payload.type == "token_count"`, `payload.info.total_token_usage`) from `rollout_path` (using tail-first 512 KB seek on plain `.jsonl` or read-only `zstd -dc` when archived as `<rollout_path>.zst`).
   - In Codex rollout `total_token_usage`, `input_tokens` includes `cached_input_tokens`, and `output_tokens` already includes `reasoning_output_tokens`:
     - `inputTokens = max(0, input_tokens - cached_input_tokens)`
     - `cacheReadTokens = cached_input_tokens`
     - `cacheWriteTokens = cache_write_input_tokens`
     - `outputTokens = output_tokens`
   - If neither `.jsonl` nor readable `.jsonl.zst` breakdown exists for a thread, emits an unsplit sample with `totalTokens = tokens_used`, setting `completeness = totalOnly` and `inputTokens = outputTokens = cacheReadTokens = cacheWriteTokens = estimatedCostUSD = cacheHitRate = null`.

3. **OpenCode (`opencode`)** — `~/.local/share/opencode/opencode.db` (`session_v2`)
   - Queries `id, directory, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, model, time_updated`.
   - `outputTokens = tokens_output + tokens_reasoning`. Uses `cost` when `> 0`, otherwise falls back to catalog pricing if `model` matches `PriceCatalog`.

4. **Mistral Vibe (`vibe`)** — `<workspace>/*/.relay/LOG.md` (+ legacy `meta.json` check)
   - Current Vibe standalone `meta.json` files omit token fields (per-turn journals live in `journal/*.jsonl`, scheduled for M1).
   - Reads recorded `cost` and `tokens` from `.relay/LOG.md` steps without fabricating input/output splits. Completeness is `relayOnly` (or `totalOnly` if legacy `meta.json` stats exist), **never `complete`**.

5. **Antigravity (`agy`)** — `<workspace>/*/.relay/LOG.md` + `~/.gemini/antigravity-cli/log/cli-*.log`
   - Standalone `cli-*.log` provides only active model (`override to backend: label="..."`) and HTTP `429` / `RESOURCE_EXHAUSTED` counts, not token usage.
   - Reads recorded `tokens` and `cost` from `.relay/LOG.md` steps without fabricating input/output splits or guessing unsplit token prices. Completeness is `relayOnly` (or `noData`), **never `complete`**.

---

## 3. `.relay/LOG.md` Step Parser Contract

- **Immediate Heading Flush**: Every line starting with `#` immediately flushes and closes any open step block before evaluating the new heading. Lines under unrecognized headings (e.g., `## Appendix`) never bleed into the preceding step.
- **Accepted Step Headings**: `^#{2,3}\s+([^\s:]+):\s*(.+)$`, handling:
  - Timed steps: `## 04-codex: ok, 403s, 2026-11-11 08:30`
  - Conductor in-session notes: `## 01-claude: ok, done in-session by the conductor, 2026-11-11 08:00`
  - Comma-containing failure payloads: `## 89-agy: failed (exit 1: agy denied [{"action": ..., "display_name": ...}]), 1378s, 2026-11-11 19:22`
- **Strict Heading-Only Vendor Attribution**: `vendor` is derived solely from `-`/`_`-delimited tokens of `<stepID>` (`claude`, `codex`, `opencode`, `vibe`, `agy`/`antigravity`). Verification steps such as `88-verify` have `vendor = null` regardless of keywords in `- checks:` or `- files changed:`.

---

## 4. Cache Hit Ratio & API-Equivalent Pricing (`2026-11`)

### Cache Hit Ratio

When window `completeness == complete` and `inputTokens + cacheReadTokens + cacheWriteTokens > 0`:

$$\text{cacheHitRate} = \frac{\text{cacheReadTokens}}{\text{inputTokens} + \text{cacheReadTokens} + \text{cacheWriteTokens}}$$

Otherwise `cacheHitRate` is `null`.

### Price Catalog (`pricingVersion = "2026-11"`)

All estimated dollar figures represent **API-equivalent conversions** (many users run Claude Max, ChatGPT Pro/Plus, or internal quotas where actual marginal billing differs) and are labeled:
- English: `API-equivalent estimate (pricing 2026-11)`
- Simplified Chinese: `按 API 价折算（价格表 2026-11）`

| Model Prefix / Family | Input / 1M | Output / 1M | Cache Read / 1M | Cache Write / 1M |
|---|---:|---:|---:|---:|
| `claude-opus*`, `claude-{3,4}-opus*` | \$15.00 | \$75.00 | \$1.50 | \$18.75 |
| `claude-sonnet*`, `claude-{3-5,3-7,4}-sonnet*` | \$3.00 | \$15.00 | \$0.30 | \$3.75 |
| `claude-haiku*`, `claude-{3,3-5,4}-haiku*` | \$0.80 | \$4.00 | \$0.08 | \$1.00 |
| `gpt-6*`, `gpt-5*`, `codex-mini*`, `o3*`, `o4-mini*` | \$2.00 | \$8.00 | \$0.50 | \$2.00 |
| `deepseek-v4*`, `deepseek-v3*`, `deepseek-chat*`, `deepseek-reasoner*` | \$0.30 | \$1.20 | \$0.007 | \$0.30 |
| `gemini-4-carbon*`, `gemini-{2.5,3}-pro*` | \$1.25 | \$5.00 | \$0.30 | \$1.25 |
| `gemini-4-argon*`, `gemini-{2.0,2.5,3}-flash*` | \$0.30 | \$1.20 | \$0.075 | \$0.30 |

Unrecognized or internal unpublished model identifiers (such as `claude-fable-*`) return `nil` rather than falling back to another model's rate, and increment `unknownModelRecordCount`.

---

## 5. Known M0 Limitations (Scheduled for M1)

1. **Session-Level Time Attribution (`B3` -> M1)**: In M0, `Codex` (`threads.updated_at`) and `OpenCode` (`session_v2.time_updated`) bucket cumulative session totals by the session's last-updated timestamp. Multi-day sessions updated today therefore attribute their cumulative total to `today` / `fiveHours`. Per-event timestamp bucketing from Codex rollout JSONL events and OpenCode `message`/`part` tables is scheduled for **M1**.
2. **Standalone Vibe `journal/*.jsonl` & Structured Rate-Limit Parsing (`B5` / `B7` -> M1)**: Parsing standalone Vibe session journals and structured rate-limit event fields (avoiding substring false positives) is scheduled for **M1**.

---

## 6. Headless CLI Contract

```text
AgentBar --cli snapshot [--json] [--lang en|zh] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
```

- Executed in `AgentBarMain.main()` **before** `AgentBarApp.main()` starts `NSApplication`; opens zero windows and touches zero preference plists.
- Exit codes:
  - `0`: Snapshot printed to `stdout`.
  - `2`: Unknown subcommand, missing subcommand, or invalid CLI flag (error + usage written to `stderr`).
  - `1`: Unexpected serialization/runtime error.
- Both `--cli snapshot` and the SwiftUI `TelemetryMonitor` invoke `LocalTelemetryCollector.collectSnapshot(...)` so GUI and CLI numbers are identical.
