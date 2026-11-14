#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <Module...>              Run scoped Swift tests (e.g. Collectors Pricing RelayLog CLI Core)
  Scripts/test.sh milestone <N> [--record]       Run milestone <N> scoped tests + acceptance ledger + README replay
  Scripts/test.sh release [--record]             Run full unit suite, app bundle build, acceptance, README replay & binary audit
EOF
  exit 2
}

[ $# -ge 1 ] || usage
MODE="$1"
shift

map_scope_filter() {
  case "$1" in
    Collectors|collectors) echo "AgentBarCoreTests.CollectorsTests" ;;
    Pricing|pricing) echo "AgentBarCoreTests.PricingTests" ;;
    RelayLog|relaylog|relay) echo "AgentBarCoreTests.RelayLogTests" ;;
    CLI|cli) echo "AgentBarCoreTests.CLITests" ;;
    Core|core) echo "AgentBarCoreTests.AgentBarCoreTests" ;;
    *) echo "$1" ;;
  esac
}

scrub_user_paths() {
  perl -pe 's#/[U]sers/[^/\s"'\'']+#~#g'
}

case "$MODE" in
  scope)
    [ $# -ge 1 ] || usage
    FILTERS=()
    for mod in "$@"; do
      FILTERS+=( "--filter" "$(map_scope_filter "$mod")" )
    done
    swift test --no-parallel "${FILTERS[@]}"
    ;;

  milestone)
    [ $# -ge 1 ] || usage
    M="$1"
    shift
    RECORD=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --record) RECORD=1; shift ;;
        *) usage ;;
      esac
    done
    if [ "$M" != "0" ] && [ "$M" != "1" ]; then
      echo "Unsupported milestone: $M (supported milestones on m1/real: 0, 1)" >&2
      exit 2
    fi
    TMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-m${M}-reports.XXXXXX")"
    trap 'rm -rf "$TMP_REPORT_DIR"' EXIT

    echo "==> [M${M} 1/4] Running scoped unit test suites..."
    swift test --no-parallel \
      --filter AgentBarCoreTests.AgentBarCoreTests \
      --filter AgentBarCoreTests.CollectorsTests \
      --filter AgentBarCoreTests.PricingTests \
      --filter AgentBarCoreTests.RelayLogTests \
      --filter AgentBarCoreTests.CLITests

    echo "==> [M${M} 2/4] Building AgentBar executable..."
    swift build

    LEDGER_SCRIPT="$ROOT/Scripts/acceptance/m${M}-ledger.py"
    LEDGER_OUT="m${M}-ledger.txt"
    echo "==> [M${M} 3/4] Running M${M} independent ledger acceptance (Scripts/acceptance/m${M}-ledger.py)..."
    python3 "$LEDGER_SCRIPT" | scrub_user_paths | tee "$TMP_REPORT_DIR/$LEDGER_OUT"

    echo "==> [M${M} 4/4] Replaying README commands (Scripts/acceptance/readme-commands.sh)..."
    AGENTBAR_ACTIVE_MILESTONE="$M" bash "$ROOT/Scripts/acceptance/readme-commands.sh" | scrub_user_paths | tee "$TMP_REPORT_DIR/readme-commands.txt"

    if [ "$RECORD" -eq 1 ]; then
      mkdir -p "$ROOT/reports"
      cp "$TMP_REPORT_DIR/$LEDGER_OUT" "$ROOT/reports/$LEDGER_OUT"
      cp "$TMP_REPORT_DIR/readme-commands.txt" "$ROOT/reports/readme-commands.txt"
      echo "Recorded reports/$LEDGER_OUT and reports/readme-commands.txt"
    fi
    echo "✓ Milestone ${M} checks passed."
    ;;

  release)
    RECORD=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --record) RECORD=1; shift ;;
        *) usage ;;
      esac
    done
    TMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-release-reports.XXXXXX")"
    trap 'rm -rf "$TMP_REPORT_DIR"' EXIT

    echo "==> [Release 1/6] Running all unit tests..."
    swift test --no-parallel

    echo "==> [Release 2/6] Building release AgentBar.app bundle..."
    bash "$ROOT/Scripts/build-app.sh"

    echo "==> [Release 3/6] Running M0 independent ledger acceptance..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      python3 "$ROOT/Scripts/acceptance/m0-ledger.py" | scrub_user_paths | tee "$TMP_REPORT_DIR/m0-ledger.txt"

    echo "==> [Release 4/6] Running M1 independent ledger acceptance..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      python3 "$ROOT/Scripts/acceptance/m1-ledger.py" | scrub_user_paths | tee "$TMP_REPORT_DIR/m1-ledger.txt"

    echo "==> [Release 5/6] Replaying README commands..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      bash "$ROOT/Scripts/acceptance/readme-commands.sh" | scrub_user_paths | tee "$TMP_REPORT_DIR/readme-commands.txt"

    if [ "$RECORD" -eq 1 ]; then
      mkdir -p "$ROOT/reports"
      cp "$TMP_REPORT_DIR/m0-ledger.txt" "$ROOT/reports/m0-ledger.txt"
      cp "$TMP_REPORT_DIR/m1-ledger.txt" "$ROOT/reports/m1-ledger.txt"
      cp "$TMP_REPORT_DIR/readme-commands.txt" "$ROOT/reports/readme-commands.txt"
      echo "Recorded reports/m0-ledger.txt, reports/m1-ledger.txt, and reports/readme-commands.txt"
    fi

    echo "==> [Release 6/6] Auditing linked libraries & zero-network static symbols..."
    BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar"
    NON_SYS_LIBS="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
    if [ -n "$NON_SYS_LIBS" ]; then
      echo "ERROR: Non-system dynamic libraries linked:" >&2
      echo "$NON_SYS_LIBS" >&2
      exit 1
    fi
    if nm -u "$BIN" | grep -Eq 'NSURLSession|NWConnection|CFNetwork'; then
      echo "ERROR: Network symbols found in release binary!" >&2
      exit 1
    fi
    echo "✓ Release verification passed (system-only dylibs, zero network symbols)."
    ;;

  *)
    usage
    ;;
esac
