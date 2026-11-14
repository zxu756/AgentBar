#!/usr/bin/env bash
# Extracts fenced bash/sh commands directly from BOTH README.md and README.zh-CN.md,
# verifies 1-to-1 parity, executes local CLI commands against an isolated seeded HOME,
# asserts both exit code and output content, and logs explicit skip reasons for external/GUI steps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REAL_HOME="$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
PLIST="$REAL_HOME/Library/Preferences/local.xu.AgentBar.plist"
MTIME_BEFORE="$(stat -f '%m' "$PLIST" 2>/dev/null || echo 'none')"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-readme-replay.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR" /tmp/agentbar-screenshots
}
trap cleanup EXIT

extract_commands() {
  python3 - "$1" <<'PY'
import pathlib, sys
in_fence = False
for raw in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    s = raw.strip()
    if s.startswith("```"):
        if not in_fence and s in ("```bash", "```sh"):
            in_fence = True
        elif in_fence:
            in_fence = False
        continue
    if in_fence and s and not s.startswith("#"):
        print(s)
PY
}

extract_commands "$ROOT/README.md" > "$TMP_DIR/en_cmds.txt"
extract_commands "$ROOT/README.zh-CN.md" > "$TMP_DIR/zh_cmds.txt"

echo "=============================================================================="
echo "AgentBar README Command Replay (Extracted from README.md & README.zh-CN.md)"
echo "=============================================================================="

if ! diff -u "$TMP_DIR/en_cmds.txt" "$TMP_DIR/zh_cmds.txt" > "$TMP_DIR/parity.diff"; then
  echo "ERROR: Fenced bash commands differ between README.md and README.zh-CN.md:" >&2
  cat "$TMP_DIR/parity.diff" >&2
  exit 1
fi
CMD_COUNT="$(wc -l < "$TMP_DIR/en_cmds.txt" | tr -d ' ')"
echo "[PARITY] Verified $CMD_COUNT/$CMD_COUNT fenced bash commands match identically across README.md and README.zh-CN.md."

# Seed deterministic fixture HOME so README snapshot/daily commands do not depend on or touch real user ~/.claude
SEEDED_HOME="$TMP_DIR/seeded_home"
mkdir -p \
  "$SEEDED_HOME/.claude/projects/-tmp-app" \
  "$SEEDED_HOME/.codex" \
  "$SEEDED_HOME/.local/share/opencode" \
  "$SEEDED_HOME/.vibe/logs/session/unified/vs-demo/journal" \
  "$SEEDED_HOME/Projects/demo-pipe/.relay/01-vibe.vibe"

NOW_EPOCH="$(python3 -c 'import time; print(int(time.time()) - 300)')"
NOW_MS="$((NOW_EPOCH * 1000))"
NOW_ISO="$(python3 -c "import datetime as dt; print(dt.datetime.fromtimestamp($NOW_EPOCH, tz=dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
NOW_LOCAL="$(python3 -c "import datetime as dt; print(dt.datetime.fromtimestamp($NOW_EPOCH).strftime('%Y-%m-%d %H:%M'))")"

cat > "$SEEDED_HOME/.claude/projects/-tmp-app/s1.jsonl" <<EOF
{"type":"assistant","timestamp":"$NOW_ISO","sessionId":"s1","requestId":"r1","cwd":"/tmp/app","message":{"id":"m1","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":100000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"$NOW_ISO","sessionId":"s1","requestId":"r2","cwd":"/tmp/app","message":{"id":"m2","model":"claude-fable-5-1","usage":{"input_tokens":50000,"output_tokens":5000}}}
{"type":"assistant","timestamp":"$NOW_ISO","sessionId":"s1","requestId":"r3","cwd":"/tmp/app","message":{"id":"m3","model":"custom-local-llm","usage":{"input_tokens":50000,"output_tokens":5000}}}
EOF

cat > "$SEEDED_HOME/.codex/rollout-s1.jsonl" <<EOF
{"timestamp":"$NOW_ISO","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
{"timestamp":"$NOW_ISO","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100000,"cached_input_tokens":80000,"cache_write_input_tokens":0,"output_tokens":5000,"total_tokens":105000}}}}
EOF

python3 - "$SEEDED_HOME/.codex/state_5.sqlite" "$SEEDED_HOME/.codex/rollout-s1.jsonl" "$NOW_EPOCH" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, tokens_used INTEGER, updated_at INTEGER, model TEXT, rollout_path TEXT)")
conn.execute("INSERT INTO threads VALUES ('th-1', '/tmp/app', 105000, ?, 'gpt-6.1-sol', ?)", (int(sys.argv[3]), sys.argv[2]))
conn.commit()
conn.close()
PY

python3 - "$SEEDED_HOME/.local/share/opencode/opencode.db" "$NOW_MS" <<'PY'
import json, sqlite3, sys
ms = int(sys.argv[2])
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, model TEXT, time_updated INTEGER)")
conn.execute("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
conn.execute("INSERT INTO session_v2 VALUES ('oc-1', '/tmp/app', 0.08, 12000, 3000, 0, 45000, 0, 'deepseek-v4.1-flash', ?)", (ms,))
data_json = json.dumps({"model": {"id": "deepseek-v4.1-flash"}, "cost": 0.08, "time": {"created": ms}, "tokens": {"input": 12000, "output": 3000, "reasoning": 0, "cache": {"read": 45000, "write": 0}}})
conn.execute("INSERT INTO session_message VALUES ('om-1', 'oc-1', 'assistant', 1, ?, ?, ?)", (ms, ms, data_json))
conn.commit()
conn.close()
PY

cat > "$SEEDED_HOME/.vibe/logs/session/unified/vs-demo/meta.json" <<EOF
{"session_id":"vs-demo","start_time":"$NOW_ISO","config":{"active_model":"deepseek-v4-1-flash-1017"}}
EOF

cat > "$SEEDED_HOME/.vibe/logs/session/unified/vs-demo/journal/0000000000000001.jsonl" <<EOF
{"sequence":1,"type":"core_input","payload":{"input":{"determinism":{"time_unix_ms":$NOW_MS}}}}
{"sequence":2,"type":"action_result","payload":{"action_id":"act-demo-1","state":"succeeded","result":{"type":"completion_succeeded","result":{"usage":{"input_tokens":20000,"cached_input_tokens":15000,"cache_write_tokens":0,"output_tokens":1000,"total_tokens":21000}}}}}
EOF

cat > "$SEEDED_HOME/Projects/demo-pipe/.relay/01-vibe.vibe/export.json" <<'EOF'
{"session_id":"vs-demo"}
EOF

cat > "$SEEDED_HOME/Projects/demo-pipe/.relay/LOG.md" <<EOF
# Agent Relay Log

## 01-vibe: ok, 35s, $NOW_LOCAL
- vibe: model deepseek-v4-1-flash-1017, cost \$0.1200

## 02-agy: ok, 42s, $NOW_LOCAL
- agy: model gemini-4-carbon-high, tokens 210,000
EOF

EXECUTED=0
SKIPPED=0

while IFS= read -r cmd; do
  echo ""
  case "$cmd" in
    "git clone "*)
      echo "[SKIP] $cmd — Reason: network git clone skipped in offline local verification."
      SKIPPED=$((SKIPPED + 1))
      ;;
    "cd AgentBar")
      echo "[SKIP] $cmd — Reason: runner is already rooted at the repository directory."
      SKIPPED=$((SKIPPED + 1))
      ;;
    "./Scripts/build-app.sh")
      echo "[SKIP] $cmd — Reason: signed .app bundle build runs in 'Scripts/test.sh release' to keep milestone 0 side-effect free."
      SKIPPED=$((SKIPPED + 1))
      ;;
    "open build/AgentBar.app")
      echo "[SKIP] $cmd — Reason: launching GUI windows is prohibited during automated headless verification."
      SKIPPED=$((SKIPPED + 1))
      ;;
    "brew install "*)
      echo "[SKIP] $cmd — Reason: external Homebrew installation touches host /Applications and network."
      SKIPPED=$((SKIPPED + 1))
      ;;
    "./Scripts/test.sh milestone "*)
      echo "[SKIP] $cmd — Reason: milestone runner is orchestrated at top level (prevents recursive invocation)."
      SKIPPED=$((SKIPPED + 1))
      ;;
    *)
      echo "[RUN]  $cmd"
      OUT_FILE="$TMP_DIR/cmd_${EXECUTED}.out"
      set +e
      HOME="$SEEDED_HOME" bash -c "$cmd" >"$OUT_FILE" 2>&1
      RC=$?
      set -e
      if [ "$RC" -ne 0 ]; then
        echo "ERROR: Command exited with $RC: $cmd" >&2
        cat "$OUT_FILE" >&2
        exit 1
      fi

      # Assert specific stdout / JSON invariants per command
      case "$cmd" in
        "swift build")
          grep -Eq "Build complete!" "$OUT_FILE"
          echo "  -> exit=0, verified 'Build complete!'"
          ;;
        "./Scripts/test.sh scope "*)
          grep -Eq "Test run with [0-9]+ tests in [0-9]+ suites passed" "$OUT_FILE"
          echo "  -> exit=0, verified scoped test suites passed"
          ;;
        *".build/debug/AgentBar --help --lang en")
          grep -Fq "Usage:" "$OUT_FILE"
          grep -Fq "AgentBar --cli snapshot" "$OUT_FILE"
          echo "  -> exit=0, verified English usage output"
          ;;
        *".build/debug/AgentBar --help --lang zh")
          grep -Fq "用法:" "$OUT_FILE"
          grep -Fq "AgentBar --cli snapshot" "$OUT_FILE"
          echo "  -> exit=0, verified Chinese usage output"
          ;;
        *".build/debug/AgentBar --cli snapshot --lang en")
          grep -Fq "API-equivalent estimate (rates unverified; covers priced records only, unknown models excluded)" "$OUT_FILE"
          grep -Fq '$4.50 (Covers 1 priced records only; 2 unknown-model records excluded)' "$OUT_FILE"
          grep -Fq "[Mistral Vibe] (Complete)" "$OUT_FILE"
          grep -Fq "[Antigravity] (Relay logs only)" "$OUT_FILE"
          echo "  -> exit=0, verified EN snapshot disclaimer, priced/excluded costNote, Vibe Complete & Antigravity Relay logs only"
          ;;
        *".build/debug/AgentBar --cli snapshot --lang zh")
          grep -Fq "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）" "$OUT_FILE"
          grep -Fq '$4.50（只含已计价的 1 条，另有 2 条未知型号未计入）' "$OUT_FILE"
          grep -Fq "session_message 逐事件" "$OUT_FILE"
          grep -Fq "cli-*.log 无 Token 统计" "$OUT_FILE"
          if grep -Fq "lacks token stats" "$OUT_FILE"; then
            echo "ERROR: Untranslated 'lacks token stats' found in zh output!" >&2
            exit 1
          fi
          echo "  -> exit=0, verified ZH snapshot disclaimer, priced/excluded costNote, and localized dataSource"
          ;;
        *".build/debug/AgentBar --cli daily --tz UTC --lang en")
          grep -Fq "AgentBar 14-Day Per-Event Daily Ledger" "$OUT_FILE"
          grep -Fq "Covers 4 priced records only; 2 unknown-model records excluded" "$OUT_FILE"
          DAY_LINES="$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$OUT_FILE")"
          test "$DAY_LINES" -eq 14
          echo "  -> exit=0, verified EN 14-day daily ledger ($DAY_LINES rows) & per-day B14 costNote"
          ;;
        *".build/debug/AgentBar --cli daily --tz UTC --lang zh")
          grep -Fq "AgentBar 14 天按日事件细账" "$OUT_FILE"
          grep -Fq "只含已计价的 4 条，另有 2 条未知型号未计入" "$OUT_FILE"
          DAY_LINES="$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$OUT_FILE")"
          test "$DAY_LINES" -eq 14
          echo "  -> exit=0, verified ZH 14-day daily ledger ($DAY_LINES rows) & per-day B14 costNote"
          ;;
        *".build/debug/AgentBar --cli snapshot --json --tz UTC --lang en")
          python3 - "$OUT_FILE" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert doc["schemaVersion"] == "1.1"
assert doc["timeZone"] in ("UTC", "GMT")
assert doc["pricingVersion"] == "unverified"
assert doc["isDemoData"] is False
assert len(doc["dailyBreakdown"]) == 14
c30 = doc["vendors"]["claude"]["windows"]["thirtyDays"]
assert c30["pricedRecordCount"] == 1 and c30["unmatchedModelCount"] == 2
assert c30["costNote"] == "Covers 1 priced records only; 2 unknown-model records excluded"
assert doc["vendors"]["vibe"]["completeness"] == "complete"
assert doc["vendors"]["agy"]["completeness"] != "complete"
PY
          echo "  -> exit=0, verified EN JSON schemaVersion=1.1, 14-day dailyBreakdown, Vibe complete & AGY != complete"
          ;;
        *".build/debug/AgentBar --cli snapshot --json --tz UTC --lang zh")
          python3 - "$OUT_FILE" <<'PY'
import json, pathlib, sys
doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert doc["schemaVersion"] == "1.1"
assert doc["pricingVersion"] == "unverified"
assert doc["costDisclaimer"] == "按 API 价折算（单价未核对；只含已计价记录，未知型号未计入）"
assert len(doc["dailyBreakdown"]) == 14
assert "session_message 逐事件" in doc["vendors"]["opencode"]["dataSource"]
assert "cli-*.log 无 Token 统计" in doc["vendors"]["agy"]["dataSource"]
c30 = doc["vendors"]["claude"]["windows"]["thirtyDays"]
assert c30["costNote"] == "只含已计价的 1 条，另有 2 条未知型号未计入"
PY
          echo "  -> exit=0, verified ZH JSON schemaVersion=1.1, 14-day dailyBreakdown & localized dataSource/costNote"
          ;;
        *".build/debug/AgentBar --cli snapshot --demo --lang en")
          grep -Fq "[DEMO]" "$OUT_FILE"
          grep -Fq "Covers 182 priced records only; 4 unknown-model records excluded" "$OUT_FILE"
          echo "  -> exit=0, verified EN [DEMO] banner and costNote"
          ;;
        *".build/debug/AgentBar --cli snapshot --demo --lang zh")
          grep -Fq "[DEMO / 演示数据]" "$OUT_FILE"
          grep -Fq "只含已计价的 182 条，另有 4 条未知型号未计入" "$OUT_FILE"
          echo "  -> exit=0, verified ZH [DEMO / 演示数据] banner and costNote"
          ;;
        *".build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang en")
          test -s /tmp/agentbar-screenshots/screenshot-dashboard.png
          test -s /tmp/agentbar-screenshots/screenshot-menubar.png
          echo "  -> exit=0, verified non-empty EN Retina PNG files"
          ;;
        *".build/debug/AgentBar --export-screenshots /tmp/agentbar-screenshots --lang zh")
          test -s /tmp/agentbar-screenshots/screenshot-dashboard-zh.png
          test -s /tmp/agentbar-screenshots/screenshot-menubar-zh.png
          echo "  -> exit=0, verified non-empty ZH Retina PNG files"
          ;;
      esac
      EXECUTED=$((EXECUTED + 1))
      ;;
  esac
done < "$TMP_DIR/en_cmds.txt"

echo ""
echo "[RUN]  .build/debug/AgentBar --cli snapshot --home /nonexistent_agentbar_readme_check (expect exit 2)"
set +e
"$ROOT/.build/debug/AgentBar" --cli snapshot --home /nonexistent_agentbar_readme_check >/dev/null 2>"$TMP_DIR/b16.err"
B16_RC=$?
set -e
if [ "$B16_RC" -ne 2 ] || [ ! -s "$TMP_DIR/b16.err" ]; then
  echo "ERROR: expected exit code 2 + stderr on nonexistent --home, got rc=$B16_RC" >&2
  exit 1
fi
echo "  -> exit=2, stderr verified: $(tr '\n' ' ' < "$TMP_DIR/b16.err")"

MTIME_AFTER="$(stat -f '%m' "$PLIST" 2>/dev/null || echo 'none')"
if [ "$MTIME_BEFORE" != "$MTIME_AFTER" ]; then
  echo "ERROR: $PLIST mtime changed ($MTIME_BEFORE -> $MTIME_AFTER)" >&2
  exit 1
fi

echo ""
echo "RESULT: ALL $CMD_COUNT README COMMANDS VERIFIED ($EXECUTED executed, $SKIPPED explicitly skipped; plist untouched)."
