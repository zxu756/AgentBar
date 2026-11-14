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
    if [ "$M" != "0" ]; then
      echo "Unsupported milestone: $M (only milestone 0 is implemented on m0/honest)" >&2
      exit 2
    fi
    TMP_REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentbar-m0-reports.XXXXXX")"
    trap 'rm -rf "$TMP_REPORT_DIR"' EXIT

    echo "==> [M0 1/4] Running scoped unit test suites..."
    swift test --no-parallel \
      --filter AgentBarCoreTests.AgentBarCoreTests \
      --filter AgentBarCoreTests.CollectorsTests \
      --filter AgentBarCoreTests.PricingTests \
      --filter AgentBarCoreTests.RelayLogTests \
      --filter AgentBarCoreTests.CLITests

    echo "==> [M0 2/4] Building AgentBar executable..."
    swift build

    echo "==> [M0 3/4] Running M0 independent ledger acceptance (Scripts/acceptance/m0-ledger.py)..."
    python3 "$ROOT/Scripts/acceptance/m0-ledger.py" | scrub_user_paths | tee "$TMP_REPORT_DIR/m0-ledger.txt"

    echo "==> [M0 4/4] Replaying README commands (Scripts/acceptance/readme-commands.sh)..."
    bash "$ROOT/Scripts/acceptance/readme-commands.sh" | scrub_user_paths | tee "$TMP_REPORT_DIR/readme-commands.txt"

    if [ "$RECORD" -eq 1 ]; then
      mkdir -p "$ROOT/reports"
      cp "$TMP_REPORT_DIR/m0-ledger.txt" "$ROOT/reports/m0-ledger.txt"
      cp "$TMP_REPORT_DIR/readme-commands.txt" "$ROOT/reports/readme-commands.txt"
      echo "Recorded reports/m0-ledger.txt and reports/readme-commands.txt"
    fi
    echo "✓ Milestone 0 checks passed."
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

    echo "==> [Release 1/5] Running all unit tests..."
    swift test --no-parallel

    echo "==> [Release 2/5] Building release AgentBar.app bundle..."
    bash "$ROOT/Scripts/build-app.sh"

    echo "==> [Release 3/5] Running M0 independent ledger acceptance..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      python3 "$ROOT/Scripts/acceptance/m0-ledger.py" | scrub_user_paths | tee "$TMP_REPORT_DIR/m0-ledger.txt"

    echo "==> [Release 4/5] Replaying README commands..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      bash "$ROOT/Scripts/acceptance/readme-commands.sh" | scrub_user_paths | tee "$TMP_REPORT_DIR/readme-commands.txt"

    if [ "$RECORD" -eq 1 ]; then
      mkdir -p "$ROOT/reports"
      cp "$TMP_REPORT_DIR/m0-ledger.txt" "$ROOT/reports/m0-ledger.txt"
      cp "$TMP_REPORT_DIR/readme-commands.txt" "$ROOT/reports/readme-commands.txt"
      echo "Recorded reports/m0-ledger.txt and reports/readme-commands.txt"
    fi

    echo "==> [Release 5/5] Auditing linked libraries & zero-network static symbols..."
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
