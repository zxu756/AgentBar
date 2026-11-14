#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'EOF'
Usage:
  Scripts/test.sh scope <Module...>    Run scoped Swift tests (e.g. Collectors Pricing RelayLog CLI Core)
  Scripts/test.sh milestone <N>        Run milestone <N> scoped tests + acceptance ledger + README replay
  Scripts/test.sh release              Run full unit suite, app bundle build, acceptance, README replay & binary audit
EOF
  exit 2
}

[ $# -ge 1 ] || usage
MODE="$1"
shift

map_scope_filter() {
  case "$1" in
    Collectors|collectors) echo "CollectorsTests" ;;
    Pricing|pricing) echo "PricingTests" ;;
    RelayLog|relaylog|relay) echo "RelayLogTests" ;;
    CLI|cli) echo "CLITests" ;;
    Core|core) echo "AgentBarCoreTests" ;;
    *) echo "$1" ;;
  esac
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
    [ $# -eq 1 ] || usage
    M="$1"
    if [ "$M" != "0" ]; then
      echo "Unsupported milestone: $M (only milestone 0 is implemented on m0/honest)" >&2
      exit 2
    fi
    echo "==> [M0 1/4] Running scoped unit test suites..."
    swift test --no-parallel \
      --filter AgentBarCoreTests \
      --filter CollectorsTests \
      --filter PricingTests \
      --filter RelayLogTests \
      --filter CLITests

    echo "==> [M0 2/4] Building AgentBar executable..."
    swift build

    echo "==> [M0 3/4] Running M0 independent ledger acceptance (Scripts/acceptance/m0-ledger.py)..."
    mkdir -p "$ROOT/reports"
    python3 "$ROOT/Scripts/acceptance/m0-ledger.py" | tee "$ROOT/reports/m0-ledger.txt"

    echo "==> [M0 4/4] Replaying README commands (Scripts/acceptance/readme-commands.sh)..."
    bash "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$ROOT/reports/readme-commands.txt"
    echo "✓ Milestone 0 checks passed."
    ;;

  release)
    echo "==> [Release 1/5] Running all unit tests..."
    swift test --no-parallel

    echo "==> [Release 2/5] Building release AgentBar.app bundle..."
    bash "$ROOT/Scripts/build-app.sh"

    echo "==> [Release 3/5] Running M0 independent ledger acceptance..."
    mkdir -p "$ROOT/reports"
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      python3 "$ROOT/Scripts/acceptance/m0-ledger.py" | tee "$ROOT/reports/m0-ledger.txt"

    echo "==> [Release 4/5] Replaying README commands..."
    AGENTBAR_BIN="$ROOT/build/AgentBar.app/Contents/MacOS/AgentBar" \
      bash "$ROOT/Scripts/acceptance/readme-commands.sh" | tee "$ROOT/reports/readme-commands.txt"

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
