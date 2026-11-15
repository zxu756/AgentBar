# AgentBar Technical Specification (`M1` — since `v0.3.0`)

This specification defines the data-collection contracts, per-event timestamp attribution, five-level completeness taxonomy, structured `429` rate-limit detection, API-equivalent pricing table, and headless CLI schema (`schemaVersion: "1.1"`) for **AgentBar** (since `v0.3.0`).

---

## 1. Safety, Privacy & Honesty Invariants

1. **Zero Network Access**: `Sources/` never imports or calls `URLSession`, `NWConnection`, or `CFNetwork`. Static symbol checks (`nm -u`) enforce zero network client symbols in release builds.
2. **Strictly Read-Only Storage Access**:
   - SQLite databases (`~/.codex/state_5.sqlite`, `~/.local/share/opencode/opencode.db`) are opened exclusively with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` and a `250ms` busy timeout.
   - JSONL, `.jsonl.zst`, `.log`, and `.relay/LOG.md` files are read without mutation.
   - Headless `--cli` commands and unit tests never write to `~/Library/Preferences/` or `~/Library/Application Support/` (tests and previews inject `InMemoryPreferenceStore` rather than `UserDefaults`).
3. **In-Memory JSON Parsing — Zero Prompt Storage or Display**: Collectors read local JSONL, `.log`, and `.relay/LOG.md` files into memory to parse lines and extract only numeric token counters, model identifiers, timestamps, cost fields, and workspace/project basenames. Prompt text, assistant reply text, and tool payloads are never persisted, displayed, or uploaded.
4. **Zero Fixed-Ratio Fabrication**:
   - Fixed input/output split heuristics (`0.85 / 0.15`, `0.80 / 0.20`) are prohibited across collector, pricing, and CLI code (`Sources/AgentBarCore/Collectors/`, `Sources/AgentBarCore/CLI/`, and pricing logic in `TelemetryModels.swift`).
   - Whenever input/cache/output breakdown or pricing cannot be verified from local records, fields are emitted as JSON `null` and rendered in UI/CLI as `Unknown` (`未知`) or `No data` (`没有数据`).
   - Initial GUI startup before the first scan finishes renders `Refreshing…` (`刷新中…`), distinct from post-scan `No data` (`没有数据`).
   - Marketing screenshots and `--demo` runs use `DemoSnapshotFactory.makePreviewSnapshot()` with `isDemoData = true` and render an explicit `DEMO` (`DEMO · 演示数据`) badge.

---

## 2. Per-Vendor Data Sources & Completeness Taxonomy

Every vendor summary and time window (`fiveHours`, `today`, `sevenDays`, `thirtyDays`) carries a `completeness` value from five levels:

| Enum (`JSON`) | English Label | Simplified Chinese Label | Meaning |
|---|---|---|---|
| `complete` | `Complete` | `完整` | Verified uncached input, output, cache-read, and cache-write token breakdown from standalone local logs/DB, with zero rollout total discrepancies. |
| `mismatch` | `Total mismatch` | `总量不一致` | Codex rollout `total_token_usage` sum disagrees with `state_5.sqlite` `threads.tokens_used`; discrepancy is flagged in `hasRolloutMismatch` / `mismatchNote` and never marked `complete`. |
| `totalOnly` | `Total only` | `只有总量` | Only aggregate `totalTokens` is available (e.g., a Codex thread whose rollout file is missing); breakdown, cache hit rate, and unrecorded API cost are `null`. |
| `relayOnly` | `Relay logs only` | `只有接力里的部分` | Standalone CLI logs do not expose token usage counters (e.g., `Antigravity` `cli-*.log`, or `Mistral Vibe` when only `.relay/LOG.md` steps exist); figures come from `<workspace>/*/.relay/LOG.md` steps. |
| `noData` | `No data` | `没有数据` | Zero local records exist in the evaluated window. |

### Vendor Collection Rules (M1 Per-Event Timestamp Attribution)

1. **Claude Code (`claude`)** — `~/.claude/projects/**/*.jsonl`
   - Claude Code writes one `type: "assistant"` JSONL line per streamed content block (`thinking`, `text`, `tool_use`), repeating cumulative `message.usage` under the same `(message.id, requestId)` pair.
   - `collectClaudeTelemetry` scans all `.jsonl` files without filesystem `mtime` pre-skipping and deduplicates assistant usage lines by `(message.id, requestId)` (falling back to `message.id` or `requestId` if one is absent, and per-line key only when both are absent), taking the element-wise `max` across `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` so each assistant turn is counted **once** at its ISO-8601 `timestamp` (`nil` -> `untimestamped` when `"timestamp"` is missing or malformed; never falls back to `now`).
   - Completeness: `complete` when `recordCount > 0`.

2. **Codex CLI (`codex`)** — `~/.codex/state_5.sqlite` + `threads.rollout_path` (`.jsonl` / `.jsonl.zst` full stream)
   - Queries `SELECT id, cwd, tokens_used, updated_at, created_at, model, rollout_path FROM threads WHERE tokens_used > 0`.
   - Reads the **entire** rollout event stream from `rollout_path` (or read-only `zstd -dc` when archived as `<rollout_path>.zst`), without tail-only truncation:
     - Tracks `turn_context` (`payload.model`) to attribute mid-thread model switches accurately to subsequent turns.
     - Computes per-turn incremental deltas across `event_msg` (`payload.type == "token_count"`, `payload.info.total_token_usage`): `delta = current_cumulative - previous_cumulative`, skipping duplicate consecutive zero-delta `token_count` events and handling session counter resets when `current_cumulative < previous_cumulative`.
     - Attributes each turn delta strictly to that event's own top-level ISO-8601 `"timestamp"`. If a rollout event lacks a valid `"timestamp"`, it never borrows `threads.updated_at` or `now` and instead routes to `untimestamped`.
   - In Codex rollout `total_token_usage`, `input_tokens` includes `cached_input_tokens`, and `output_tokens` already includes `reasoning_output_tokens`:
     - `inputTokens = max(0, delta_input - delta_cached_input)`
     - `cacheReadTokens = delta_cached_input`
     - `cacheWriteTokens = delta_cache_write`
     - `outputTokens = delta_output`
   - **Rollout vs SQLite Total Verification (`B15`, Window & Per-Day)**: Compares the thread's full rollout delta sum (`rolloutTotal`) and `total_token_usage.total_tokens` against `threads.tokens_used`. When they differ, sets `hasRolloutMismatch = true`, records `<threadID>: rollout=<rolloutTotal> vs sqlite=<tokens_used>` in `mismatchNote` / `codexMismatchNote` on both the summary windows AND every calendar day in `dailyBreakdown` touched by that thread, and downgrades completeness to `mismatch` (`Total mismatch` / `总量不一致`).
   - **Aggregate-Only Fallback**: Only when neither `.jsonl` nor readable `.jsonl.zst` turn events exist for a thread (`0` rollout events) does `AgentBar` emit an unsplit sample (`totalTokens = tokens_used`, `completeness = totalOnly`, `null` breakdown/cost/cacheHitRate), using `threads.updated_at` (`created_at`) when `> 0` or routing to `untimestamped` when `updated_at <= 0`.

3. **OpenCode (`opencode`)** — `~/.local/share/opencode/opencode.db` (`session_message` / `message` + `session_v2` fallback)
   - Reads per-message token events from `session_message` (or `message` if a schema uses that table name) where `type IN ('assistant', 'compaction')`, parsing `data` JSON (`time.created` / `time.completed` or `time_created` / `time_updated` Unix ms, `model.id` / `model`, `cost`, and `tokens.{input, output, reasoning, cache.{read, write}}`). If a `session_message` row lacks a valid positive timestamp, it routes strictly to `untimestamped` and never borrows `session_v2.time_updated` or `now`.
   - In OpenCode `session_message`, `tokens.input` is already uncached input (`input + output + reasoning + cache.read + cache.write` matches `session_v2` totals); `outputTokens = tokens.output + tokens.reasoning`.
   - Falls back to `session_v2` (`time_updated`) **only** for aggregate-only sessions that have `0` token-bearing rows in `session_message` (routing to `untimestamped` if `time_updated <= 0`).

4. **Mistral Vibe (`vibe`)** — `~/.vibe/logs/session/unified/<session_id>/{meta.json,journal/*.jsonl}` + `~/.vibe/config.toml` + `<workspace>/*/.relay/LOG.md`
   - Reads `meta.json` (`session_id`, `start_time`, `end_time`, `config.active_model` / `config.model_name`) with model fallback to `~/.vibe/config.toml` (`active_model`).
   - Reads all `journal/*.jsonl` segment files in lexicographic/sequence order, maintaining a running Unix-ms timestamp strictly from valid journal timestamps (`payload.input.determinism.time_unix_ms`, `payload.delta[].entry.{updatedAt,createdAt}`, `payload.session_api.turn_outcomes.*.completedAt`, or top-level `timestamp`). Journal `action_result` events lacking a valid timestamp (or preceded by a corrupt timestamp) never borrow `meta.json` `start_time`/`end_time`, directory `mtime`, or `now`, and route to `untimestamped` (`meta.json` timestamps are used only for aggregate-only `meta.json` `stats` fallback when `0` journal records exist).
   - Extracts `type == "action_result"` records with `payload.state == "succeeded"` and `payload.result.type == "completion_succeeded"`, deduplicated by `payload.action_id`.
   - In Vibe `usage`, `input_tokens` already includes `cached_input_tokens` and `output_tokens` already includes `reasoning_tokens`:
     - `inputTokens = max(0, input_tokens - cached_input_tokens)`
     - `cacheReadTokens = cached_input_tokens`
     - `cacheWriteTokens = cache_write_tokens`
     - `outputTokens = output_tokens`
   - **Relay Deduplication**: Inspects `<workspace>/<proj>/.relay/<stepID>.vibe/export.json` (and `session/meta.json`) for `session_id`; if that `session_id` was already collected from `~/.vibe/logs/session/unified/`, the `.relay/LOG.md` step is skipped so Vibe usage is never double-counted. Completeness is `complete` when all Vibe samples come from `journal/*.jsonl`, or `relayOnly` when unlinked `.relay/LOG.md` Vibe steps are present.

5. **Antigravity (`agy`)** — `<workspace>/*/.relay/LOG.md` + `~/.gemini/antigravity-cli/log/cli-*.log` (`cli-*.log lacks token stats` / `cli-*.log 无 Token 统计`)
   - Standalone `cli-*.log` provides only active model (`override to backend: label="..."`) and ISO-timestamped structured `status=429` markers (lines without a valid leading ISO-8601 timestamp never borrow file `mtime`).
   - Reads recorded `tokens` and `cost` from `.relay/LOG.md` steps without fabricating input/output splits or guessing unsplit token prices. Step timestamps (`yyyy-MM-dd HH:mm` or `yyyy-MM-dd HH:mm:ss`) are strictly validated in the evaluation `timeZone` (`--tz`) via `Calendar` / `DateComponents.isValidDate(in:)`; missing or invalid wall-clock step dates (including non-existent spring-forward DST gap minutes) never borrow `LOG.md` `mtime` and route to `untimestamped`. Completeness is `relayOnly` (or `noData`), **never `complete`**.

### Window & Calendar-Day Boundary Rules (`BR1`, `BR2`, `BR3`)

- **Rolling & Current-Day Windows**: Evaluated against `now` and `cal` (`cal.timeZone = timeZone`):
  - `fiveHours`: `timestamp >= now - 18_000s && timestamp <= now`
  - `today`: `timestamp >= cal.startOfDay(for: now) && timestamp <= now`
  - `sevenDays`: `timestamp >= now - 604_800s && timestamp <= now`
  - `thirtyDays`: `timestamp >= now - 2_592_000s && timestamp <= now`
- **14-Day `dailyBreakdown` Calendar Rows**: Half-open per-day intervals `[dayStart, nextDayStart)` computed via `cal.date(byAdding: .day, ...)` in `timeZone` (handling 23-hour spring-forward and 25-hour fall-back DST transitions such as `Pacific/Auckland` NZDT): `timestamp >= dayStart && timestamp < nextDayStart && timestamp <= now`.
- **`untimestamped` Bucket (`No timestamp` / `没有时间`)**: Records with `timestamp == nil` contribute `0` tokens and `0` records to `fiveHours`, `today`, `sevenDays`, `thirtyDays`, and all 14 dated `dailyBreakdown` rows, and are reported separately in `vendors.<id>.untimestamped`, top-level `untimestamped` (`date: "No timestamp"` in English / `"没有时间"` in Simplified Chinese), and CLI/UI output when `recordCount > 0`.

### Structured `429` Rate-Limit Detection (`B7`)

`AgentBar` counts `429` rate-limit events strictly from structured fields—**never** by matching `"rate"` or `"429"` substrings in free-form conversation text, prompt previews, or log prose:
- **HTTP Status Fields**: `status == 429`, `status_code == 429`, `statusCode == 429`, `http_status == 429`, `httpStatus == 429` (plus Antigravity structured key-value token `status=429` / `http_status=429` / `status_code=429` bounded by whitespace/delimiters).
- **Structured Error Codes/Types**: `error.code` / `error.type` / `error` (when `isApiErrorMessage == true` or `type == "error"` or Vibe `action_result` `state == "failed"`) equal to `"429"`, `"rate_limit"`, `"rate_limit_error"`, `"rate_limit_exceeded"`, `"too_many_requests"`, or `"resource_exhausted"` (case-insensitive exact token match).
- Exposed per window (`rateLimit429Count`), per 24h (`rateLimitHits24h`), and per calendar day (`dailyBreakdown[].rateLimit429Count` and `dailyBreakdown[].vendors.<vendor>.rateLimit429Count`).

---

## 3. `.relay/LOG.md` Step Parser Contract

- **Immediate Heading Flush**: Every line starting with `#` immediately flushes and closes any open step block before evaluating the new heading. Lines under unrecognized headings (e.g., `## Appendix`) never bleed into the preceding step.
- **Accepted Step Headings**: `^#{2,3}\s+([^\s:]+):\s*(.+)$`, handling timed steps, conductor in-session notes, and comma-containing failure payloads.
- **Strict Heading-Only Vendor Attribution**: `vendor` is derived solely from `-`/`_`-delimited tokens of `<stepID>` (`claude`, `codex`, `opencode`, `vibe`, `agy`/`antigravity`). Verification steps such as `88-verify` have `vendor = null` regardless of keywords in `- checks:` or `- files changed:`.

---

## 4. Cache Hit Ratio, Priced Coverage Note & Price Catalog (`pricingVersion = "unverified"`)

### Cache Hit Ratio

When window `completeness` has full breakdown (`complete`, or `mismatch` when all records have rollout breakdowns) and `inputTokens + cacheReadTokens + cacheWriteTokens > 0`:

$$\text{cacheHitRate} = \frac{\text{cacheReadTokens}}{\text{inputTokens} + \text{cacheReadTokens} + \text{cacheWriteTokens}}$$

Otherwise `cacheHitRate` is `null`.

### Priced vs Excluded Unknown-Model Coverage (`B14`)

Every window and daily entry tracks `pricedRecordCount` ($N$) and `unmatchedModelCount` ($M$, plus vendor-level `unmatchedModelCount30d`) separately and emits `costNote` alongside every cost figure:
- English: `Covers N priced record(s) only; M unknown-model record(s) excluded` (singular `record` when count is `1`, plural `records` otherwise)
- Simplified Chinese ($M > 0$): `只含已计价的 N 条，另有 M 条未知型号未计入`
- Simplified Chinese ($M = 0$): `含已计价的 N 条，0 条未知型号未计入`

Unrecognized or internal unpublished model identifiers (such as `claude-fable-*`) return `nil` rather than falling back to another model's rate.

### Per-Model Price Catalog (`PriceCatalog.entries`, `pricingVersion = "unverified"`)

Rates below were inherited from the offline baseline without live network verification against vendor pricing pages during the M0 rework; every row therefore explicitly records its official vendor pricing URL and marks `verifiedAt` as `unverified` (`未核对`):

| Model Prefix (`matchKind`) | Input / 1M | Cached Input / 1M | Cache Write / 1M | Output / 1M | Official Pricing Source URL | Verified Date |
|---|---:|---:|---:|---:|---|---|
| `claude-opus` (`prefix`) | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-3-opus` (`prefix`) | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-4-opus` (`prefix`) | \$15.00 | \$1.50 | \$18.75 | \$75.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-sonnet` (`prefix`) | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-3-5-sonnet` (`prefix`) | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-3-7-sonnet` (`prefix`) | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-4-sonnet` (`prefix`) | \$3.00 | \$0.30 | \$3.75 | \$15.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-haiku` (`prefix`) | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-3-haiku` (`prefix`) | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-3-5-haiku` (`prefix`) | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `claude-4-haiku` (`prefix`) | \$0.80 | \$0.08 | \$1.00 | \$4.00 | https://docs.anthropic.com/en/docs/about-claude/pricing | `unverified` (`未核对`) |
| `gpt-6` (`prefix`) | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` (`未核对`) |
| `gpt-5` (`prefix`) | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` (`未核对`) |
| `codex-mini` (`prefix`) | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` (`未核对`) |
| `o3` (`exactOrHyphenPrefix`) | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` (`未核对`) |
| `o4-mini` (`prefix`) | \$2.00 | \$0.50 | \$2.00 | \$8.00 | https://platform.openai.com/docs/pricing | `unverified` (`未核对`) |
| `deepseek-v4` (`prefix`) | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` (`未核对`) |
| `deepseek-v3` (`prefix`) | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` (`未核对`) |
| `deepseek-chat` (`prefix`) | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` (`未核对`) |
| `deepseek-reasoner` (`prefix`) | \$0.30 | \$0.007 | \$0.30 | \$1.20 | https://api-docs.deepseek.com/quick_start/pricing | `unverified` (`未核对`) |
| `gemini-4-carbon` (`prefix`) | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini 4 carbon` (`prefix`) | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-2.5-pro` (`prefix`) | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-3-pro` (`prefix`) | \$1.25 | \$0.30 | \$1.25 | \$5.00 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-4-argon` (`prefix`) | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini 4 argon` (`prefix`) | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-2.0-flash` (`prefix`) | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-2.5-flash` (`prefix`) | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |
| `gemini-3-flash` (`prefix`) | \$0.30 | \$0.075 | \$0.30 | \$1.20 | https://ai.google.dev/gemini-api/docs/pricing | `unverified` (`未核对`) |

---

## 5. Known M1 Limitations & M2+ Scope Boundaries

1. **Antigravity Standalone Logs Omit Token Counters (M2+)**: Standalone `~/.gemini/antigravity-cli/log/cli-*.log` does not emit token usage counters; standalone Antigravity protobuf/SQLite state inspection is out of scope for M1 (`completeness` remains `relayOnly` or `noData`).
2. **Mistral Vibe Journal Compaction**: When Mistral Vibe compacts long sessions into `chunks/*.json` and deletes early `journal/0000000000000001.jsonl` segments, `chunks/*.json` omit `usage` fields, so only unpruned `journal/*.jsonl` segments remain on disk to be summed.
3. **OpenCode Non-Message Overhead (`session_v2` vs `session_message`)**: On sessions with `session_message` rows, `AgentBar` sums `assistant` and `compaction` message rows for exact per-event timestamps; non-message background calls (such as automatic title generation or pruned rows, observed on `10/240` live sessions at `+445` to `+420,607` tokens — `0.0088%` of the 30-day total, single-session max relative diff `2.86%`) appear only in `session_v2` session aggregates and have no per-event `assistant`/`compaction` row in `session_message`.
4. **Full Scan vs Incremental SQLite Cursor Cache (M2)**: M1 parses 30-day files directly in memory (with an in-process `(path, mtime, size)` cache for Codex rollouts); persistent SQLite cursor caching and budget alerts belong to M2.
5. **Unverified API Rate Table (`pricingVersion = "unverified"`)**: Catalog unit rates remain marked `unverified` (`未核对`) until live vendor-page verification.

---

## 6. Headless CLI Contract (`schemaVersion = "1.1"`, `since v0.3.0`)

```text
AgentBar --cli snapshot [--json] [--lang en|zh] [--tz <UTC|local|tzID>] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
AgentBar --cli daily    [--json] [--lang en|zh] [--tz <UTC|local|tzID>] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
```

- Executed in `AgentBarMain.main()` **before** `AgentBarApp.main()` starts `NSApplication`; opens zero windows and touches zero preference plists.
- `--tz <UTC|local|tzID>` sets deterministic calendar-day boundaries for `today` and the 14-day `dailyBreakdown` array (each entry includes `date`, `uncachedInputTokens`, `cachedInputTokens`, `cacheWriteTokens`, `outputTokens`, `totalTokens`, `recordCount`, `pricedRecordCount`, `unmatchedModelCount`, `estimatedCostUSD`, `costNote`, `hasCodexRolloutMismatch`, `codexMismatchNote`, `rateLimit429Count`, and per-vendor `vendors.<id>`).
- Exit codes:
  - `0`: Snapshot or daily ledger printed to `stdout` (when default `$HOME` lacks optional CLI subdirectories, affected vendors report `noData`).
  - `2`: Unknown subcommand, missing subcommand, invalid CLI flag (`--lang`, `--tz`, `--now`), or an explicitly provided `--home <dir>` / `--workspace <dir>` path that does not exist or is not a directory (error written to `stderr`).
  - `1`: Unexpected serialization/runtime error.
- Both `--cli snapshot|daily` and the SwiftUI `TelemetryMonitor` invoke `LocalTelemetryCollector.collectSnapshot(...)` so GUI and CLI numbers are identical.
