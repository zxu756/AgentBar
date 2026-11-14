#!/usr/bin/env bash
# Replays every CLI, test, and screenshot command documented in README.md and README.zh-CN.md.
# Strictly read-only against local stores; writes temporary screenshot outputs only to mktemp -d.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ -n "${AGENTBAR_BIN:-}" ] && [ -x "${AGENTBAR_BIN}" ]; then
  BIN="${AGENTBAR_BIN}"
elif [ -x "$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" ]; then
  BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar"
elif [ -x "$ROOT/.build/debug/AgentBar" ]; then
  BIN="$ROOT/.build/debug/AgentBar"
else
  swift build
  BIN="$ROOT/.build/debug/AgentBar"
fi

PLIST="$HOME/Library/Preferences/local.xu.AgentBar.plist"
MTIME_BEFORE="$(stat -f '%m' "$PLIST" 2>/dev/null || echo 'none')"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-readme-replay.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

REL_BIN="${BIN#"$ROOT/"}"
echo "=============================================================================="
echo "AgentBar README Command Replay ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"
echo "Binary: $REL_BIN"
echo "=============================================================================="

echo ""
echo "$ AgentBar --help --lang en"
"$BIN" --help --lang en

echo ""
echo "$ AgentBar --help --lang zh"
"$BIN" --help --lang zh

echo ""
echo "$ AgentBar --cli snapshot --lang en"
"$BIN" --cli snapshot --lang en

echo ""
echo "$ AgentBar --cli snapshot --lang zh"
"$BIN" --cli snapshot --lang zh

echo ""
echo "$ AgentBar --cli snapshot --json --lang en | python3 -c '<validate schema>'"
"$BIN" --cli snapshot --json --lang en | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == "1.0"
assert doc["pricingVersion"] == "2026-11"
assert doc["isDemoData"] is False
assert set(doc["vendors"].keys()) == {"claude", "codex", "opencode", "vibe", "agy"}
assert doc["vendors"]["vibe"]["completeness"] != "complete"
assert doc["vendors"]["agy"]["completeness"] != "complete"
print("JSON (en) validated:", {k: v["completeness"] for k, v in doc["vendors"].items()})
'

echo ""
echo "$ AgentBar --cli snapshot --json --lang zh | python3 -c '<validate zh labels>'"
"$BIN" --cli snapshot --json --lang zh | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["costDisclaimer"] == "按 API 价折算（价格表 2026-11）"
assert doc["vendors"]["vibe"]["completenessLabel"] != "完整"
assert doc["vendors"]["agy"]["completenessLabel"] != "完整"
print("JSON (zh) validated:", {k: v["completenessLabel"] for k, v in doc["vendors"].items()})
'

echo ""
echo "$ AgentBar --cli snapshot --demo --lang en"
"$BIN" --cli snapshot --demo --lang en

echo ""
echo "$ AgentBar --cli snapshot --demo --lang zh"
"$BIN" --cli snapshot --demo --lang zh

echo ""
echo "$ AgentBar --export-screenshots <tmp_dir> --lang en && --lang zh"
"$BIN" --export-screenshots "$TMP_DIR/shots" --lang en >/dev/null
"$BIN" --export-screenshots "$TMP_DIR/shots" --lang zh >/dev/null
for f in screenshot-dashboard.png screenshot-menubar.png screenshot-dashboard-zh.png screenshot-menubar-zh.png; do
  test -s "$TMP_DIR/shots/$f"
done
echo "Verified 4 non-empty Retina DEMO screenshots in temporary directory."

echo ""
echo "$ AgentBar --cli invalid-subcommand  # expects exit code 2"
set +e
"$BIN" --cli invalid-subcommand >/dev/null 2>"$TMP_DIR/err.txt"
BAD_RC=$?
set -e
if [ "$BAD_RC" -ne 2 ]; then
  echo "ERROR: expected exit code 2 on invalid subcommand, got $BAD_RC" >&2
  exit 1
fi
echo "Verified exit code 2 on unknown subcommand."

MTIME_AFTER="$(stat -f '%m' "$PLIST" 2>/dev/null || echo 'none')"
if [ "$MTIME_BEFORE" != "$MTIME_AFTER" ]; then
  echo "ERROR: $PLIST mtime changed ($MTIME_BEFORE -> $MTIME_AFTER)" >&2
  exit 1
fi

echo ""
echo "RESULT: ALL DOCUMENTED README COMMANDS REPLAYED CLEANLY (plist untouched)."
