==============================================================================
AgentBar README Command Replay (2026-11-14T04:20:42Z)
Binary: build/AgentBar.app/Contents/MacOS/AgentBar
==============================================================================

$ AgentBar --help --lang en
Usage:
  AgentBar --cli snapshot [--json] [--lang en|zh] [--home <dir>] [--workspace <dir>] [--now <ISO8601|epoch>] [--no-zstd] [--demo]
  AgentBar [--lang en|zh] [--demo]
  AgentBar --export-screenshots <dir> [--lang en|zh]

$ AgentBar --help --lang zh
用法:
  AgentBar --cli snapshot [--json] [--lang en|zh] [--home <目录>] [--workspace <目录>] [--now <ISO8601|秒>] [--no-zstd] [--demo]
  AgentBar [--lang en|zh] [--demo]
  AgentBar --export-screenshots <输出目录> [--lang en|zh]

$ AgentBar --cli snapshot --lang en
AgentBar Read-Only Local Snapshot
API-equivalent estimate (pricing 2026-11)
M0 note: Codex and OpenCode session totals are bucketed by last-updated timestamp; per-event attribution is scheduled for M1.
------------------------------------------------------------------------------
[Claude Code] (Complete) — ~/.claude/projects/**/*.jsonl
  Today: tokens 250.3M, cost $55.05 | 30d: tokens 2.46B, cost $3678, cache hit 98%, records 8468, unmatched-model records 1263
[Codex CLI] (Complete) — ~/.codex/state_5.sqlite + rollout-*.jsonl
  Today: tokens 32.1K, cost $0.05 | 30d: tokens 871.2M, cost $480, cache hit 98%, records 105
[OpenCode] (Complete) — ~/.local/share/opencode/opencode.db (session_v2)
  Today: tokens 3.5M, cost $0.19 | 30d: tokens 4.87B, cost $94.01, cache hit 97%, records 240
[Mistral Vibe] (Relay logs only) — ~/Projects/*/.relay/LOG.md (meta.json lacks token stats)
  Today: tokens No data, cost No data | 30d: tokens Unknown, cost $5.50, cache hit Unknown, records 8
[Antigravity] (Relay logs only) — ~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)
  Today: tokens No data, cost No data | 30d: tokens 11.2M, cost Unknown, cache hit Unknown, records 14
------------------------------------------------------------------------------
Relay log (rea-lol): 126 steps, recorded cost $5.50

$ AgentBar --cli snapshot --lang zh
AgentBar 本地只读用量快照
按 API 价折算（价格表 2026-11）
M0 口径说明：Codex 与 OpenCode 按会话最后更新时间归桶；逐事件归属排在 M1。
------------------------------------------------------------------------------
[Claude Code] (完整) — ~/.claude/projects/**/*.jsonl
  今天: Token 250.3M, 折算 $55.05 | 30天: Token 2.46B, 折算 $3678, 缓存命中率 98%, 记录数 8468, 未匹配模型记录 1263 条
[Codex CLI] (完整) — ~/.codex/state_5.sqlite + rollout-*.jsonl
  今天: Token 32.1K, 折算 $0.05 | 30天: Token 871.2M, 折算 $480, 缓存命中率 98%, 记录数 105
[OpenCode] (完整) — ~/.local/share/opencode/opencode.db (session_v2)
  今天: Token 3.5M, 折算 $0.19 | 30天: Token 4.87B, 折算 $94.01, 缓存命中率 97%, 记录数 240
[Mistral Vibe] (只有接力里的部分) — ~/Projects/*/.relay/LOG.md (meta.json lacks token stats)
  今天: Token 没有数据, 折算 没有数据 | 30天: Token 未知, 折算 $5.50, 缓存命中率 未知, 记录数 8
[Antigravity] (只有接力里的部分) — ~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)
  今天: Token 没有数据, 折算 没有数据 | 30天: Token 11.2M, 折算 未知, 缓存命中率 未知, 记录数 14
------------------------------------------------------------------------------
接力日志 (rea-lol): 126 个步骤, 已记录开销 $5.50

$ AgentBar --cli snapshot --json --lang en | python3 -c '<validate schema>'
JSON (en) validated: {'agy': 'relayOnly', 'claude': 'complete', 'codex': 'complete', 'opencode': 'complete', 'vibe': 'relayOnly'}

$ AgentBar --cli snapshot --json --lang zh | python3 -c '<validate zh labels>'
JSON (zh) validated: {'agy': '只有接力里的部分', 'claude': '完整', 'codex': '完整', 'opencode': '完整', 'vibe': '只有接力里的部分'}

$ AgentBar --cli snapshot --demo --lang en
AgentBar Read-Only Local Snapshot [DEMO]
API-equivalent estimate (pricing 2026-11)
M0 note: Codex and OpenCode session totals are bucketed by last-updated timestamp; per-event attribution is scheduled for M1.
------------------------------------------------------------------------------
[Claude Code] (Complete) — ~/.claude/projects/**/*.jsonl
  Today: tokens 1.4M, cost $6.84 | 30d: tokens 28.4M, cost $94.20, cache hit 94%, records 186, unmatched-model records 4
[Codex CLI] (Complete) — ~/.codex/state_5.sqlite + rollout-*.jsonl
  Today: tokens 980.0K, cost $0.89 | 30d: tokens 19.2M, cost $14.60, cache hit 97%, records 41
[OpenCode] (Complete) — ~/.local/share/opencode/opencode.db (session_v2)
  Today: tokens 2.3M, cost $0.56 | 30d: tokens 48.9M, cost $11.80, cache hit 96%, records 83
[Mistral Vibe] (Relay logs only) — ~/Projects/*/.relay/LOG.md (meta.json lacks token stats)
  Today: tokens Unknown, cost $0.31 | 30d: tokens Unknown, cost $5.50, cache hit Unknown, records 8
[Antigravity] (Relay logs only) — ~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)
  Today: tokens 722.0K, cost Unknown | 30d: tokens 11.2M, cost Unknown, cache hit Unknown, records 14
------------------------------------------------------------------------------
Relay log (shader-pipeline): 4 steps, recorded cost $0.48

$ AgentBar --cli snapshot --demo --lang zh
AgentBar 本地只读用量快照 [DEMO / 演示数据]
按 API 价折算（价格表 2026-11）
M0 口径说明：Codex 与 OpenCode 按会话最后更新时间归桶；逐事件归属排在 M1。
------------------------------------------------------------------------------
[Claude Code] (完整) — ~/.claude/projects/**/*.jsonl
  今天: Token 1.4M, 折算 $6.84 | 30天: Token 28.4M, 折算 $94.20, 缓存命中率 94%, 记录数 186, 未匹配模型记录 4 条
[Codex CLI] (完整) — ~/.codex/state_5.sqlite + rollout-*.jsonl
  今天: Token 980.0K, 折算 $0.89 | 30天: Token 19.2M, 折算 $14.60, 缓存命中率 97%, 记录数 41
[OpenCode] (完整) — ~/.local/share/opencode/opencode.db (session_v2)
  今天: Token 2.3M, 折算 $0.56 | 30天: Token 48.9M, 折算 $11.80, 缓存命中率 96%, 记录数 83
[Mistral Vibe] (只有接力里的部分) — ~/Projects/*/.relay/LOG.md (meta.json lacks token stats)
  今天: Token 未知, 折算 $0.31 | 30天: Token 未知, 折算 $5.50, 缓存命中率 未知, 记录数 8
[Antigravity] (只有接力里的部分) — ~/Projects/*/.relay/LOG.md (cli-*.log lacks token stats)
  今天: Token 722.0K, 折算 未知 | 30天: Token 11.2M, 折算 未知, 缓存命中率 未知, 记录数 14
------------------------------------------------------------------------------
接力日志 (shader-pipeline): 4 个步骤, 已记录开销 $0.48

$ AgentBar --export-screenshots <tmp_dir> --lang en && --lang zh
Verified 4 non-empty Retina DEMO screenshots in temporary directory.

$ AgentBar --cli invalid-subcommand  # expects exit code 2
Verified exit code 2 on unknown subcommand.

RESULT: ALL DOCUMENTED README COMMANDS REPLAYED CLEANLY (plist untouched).
