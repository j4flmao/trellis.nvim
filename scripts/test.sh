#!/usr/bin/env bash
# Run trellis.nvim test suites with mini.test.
#
# Usage:
#   scripts/test.sh                 unit + integration (default)
#   scripts/test.sh unit            one suite: unit | integration | e2e | bench
#   scripts/test.sh ci              unit + integration + e2e (what CI runs)
#   scripts/test.sh all             every suite, including bench
#   scripts/test.sh tests/unit/layout_spec.lua   a single spec file
#
# Environment:
#   NVIM               Neovim binary (default: nvim)
#   TRELLIS_MINI_REF   mini.test ref installed into .tests/deps (default: see tests/minimal_init.lua)
#   TRELLIS_BENCH_REPO repository used by bench specs that need a real large repo (optional)
set -euo pipefail

cd "$(dirname "$0")/.."
NVIM="${NVIM:-nvim}"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

run_nvim() {
  # XDG dirs are isolated before Neovim starts so stdpath() of the runner itself is isolated too.
  XDG_CONFIG_HOME="$PWD/.tests/xdg/config" \
  XDG_DATA_HOME="$PWD/.tests/xdg/data" \
  XDG_STATE_HOME="$PWD/.tests/xdg/state" \
  XDG_CACHE_HOME="$PWD/.tests/xdg/cache" \
    "$NVIM" --headless -u tests/minimal_init.lua -c "lua MiniTest.run()"
}

arg="${1:-default}"
case "$arg" in
  -h | --help) usage; exit 0 ;;
  default) suites="unit integration" ;;
  ci) suites="unit integration e2e" ;;
  all) suites="unit integration e2e bench" ;;
  unit | integration | e2e | bench) suites="$arg" ;;
  *_spec.lua)
    [ -f "$arg" ] || { echo "no such spec file: $arg" >&2; exit 2; }
    echo "== $arg"
    TRELLIS_TEST_FILE="$arg" run_nvim
    exit $?
    ;;
  *) usage >&2; exit 2 ;;
esac

mkdir -p .tests/xdg/config .tests/xdg/data .tests/xdg/state .tests/xdg/cache

status=0
for suite in $suites; do
  count=$(find "tests/$suite" -name '*_spec.lua' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    echo "== $suite: no spec files yet, skipped"
    continue
  fi
  echo "== $suite ($count spec file(s))"
  TRELLIS_TEST_SUITE="$suite" run_nvim || status=1
done
exit $status
