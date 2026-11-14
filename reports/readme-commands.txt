==============================================================================
AgentBar README Command Replay (Extracted from README.md & README.zh-CN.md)
==============================================================================
[PARITY] Verified 21/21 fenced bash commands match identically across README.md and README.zh-CN.md.

[SKIP] git clone https://github.com/zxu756/AgentBar.git — Reason: network git clone skipped in offline local verification.

[SKIP] cd AgentBar — Reason: runner is already rooted at the repository directory.

[RUN]  swift build
  -> exit=0, verified 'Build complete!'

[RUN]  ./Scripts/test.sh scope Collectors Pricing RelayLog CLI Core
  -> exit=0, verified scoped test suites passed

[SKIP] ./Scripts/build-app.sh — Reason: signed .app bundle build runs in 'Scripts/test.sh release' to keep milestone 0 side-effect free.

[SKIP] open build/AgentBar.app — Reason: launching GUI windows is prohibited during automated headless verification.

[SKIP] brew install --cask zxu756/tap/agentbar — Reason: external Homebrew installation touches host /Applications and network.

[RUN]  .build/debug/AgentBar --help --lang en
  -> exit=0, verified English usage output

[RUN]  .build/debug/AgentBar --help --lang zh
  -> exit=0, verified Chinese usage output

[RUN]  .build/debug/AgentBar --cli snapshot --lang en
  -> exit=0, verified EN snapshot disclaimer, priced/excluded costNote, Vibe Complete & Antigravity Relay logs only

[RUN]  .build/debug/AgentBar --cli snapshot --lang zh
  -> exit=0, verified ZH snapshot disclaimer, priced/excluded costNote, and localized dataSource

[RUN]  .build/debug/AgentBar --cli daily --tz UTC --lang en
  -> exit=0, verified EN 14-day daily ledger (14 rows) & per-day B14 costNote

[RUN]  .build/debug/AgentBar --cli daily --tz UTC --lang zh
  -> exit=0, verified ZH 14-day daily ledger (14 rows) & per-day B14 costNote

[RUN]  .build/debug/AgentBar --cli snapshot --json --tz UTC --lang en
  -> exit=0, verified EN JSON schemaVersion=1.1, 14-day dailyBreakdown, Vibe complete & AGY != complete

[RUN]  .build/debug/AgentBar --cli snapshot --json --tz UTC --lang zh
  -> exit=0, verified ZH JSON schemaVersion=1.1, 14-day dailyBreakdown & localized dataSource/costNote

[RUN]  .build/debug/AgentBar --cli snapshot --demo --lang en
  -> exit=0, verified EN [DEMO] banner and costNote

[RUN]  .build/debug/AgentBar --cli snapshot --demo --lang zh
  -> exit=0, verified ZH [DEMO / 演示数据] banner and costNote

[RUN]  .build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang en
  -> exit=0, verified non-empty EN Retina PNG files

[RUN]  .build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang zh
  -> exit=0, verified non-empty ZH Retina PNG files

[SKIP] ./Scripts/test.sh milestone 0 — Reason: milestone runner is orchestrated at top level (prevents recursive invocation).

[SKIP] ./Scripts/test.sh milestone 1 — Reason: milestone runner is orchestrated at top level (prevents recursive invocation).

[RUN]  .build/debug/AgentBar --cli snapshot --home /nonexistent_agentbar_readme_check (expect exit 2)
  -> exit=2, stderr verified: 错误：--home 指定的目录不存在或不是目录：'/nonexistent_agentbar_readme_check'。 

RESULT: README COMMAND REPLAY PASSED (passed=14/21 README commands + 1 negative check, skipped=7/21 not counted as passed, failed=0; plist untouched).
