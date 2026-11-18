#!/usr/bin/env bash
# Run the performance budget benchmarks against a large real repository, usually a Linux kernel
# clone (Constitution III, spec SC-002, tasks.md T006/T120).
#
# Usage: scripts/bench_kernel.sh /path/to/linux
#
# The repository is only read; this script never writes to it except `commit-graph write` when
# BENCH_WRITE_COMMIT_GRAPH=1 (the weekly CI job sets it on its own cached clone).
# Results go to stdout and, inside GitHub Actions, to the job summary.
set -euo pipefail

repo="${1:-}"
if [ -z "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "usage: $0 /path/to/git/repo" >&2
  exit 2
fi
repo="$(cd "$repo" && pwd)"
cd "$(dirname "$0")/.."

gitdir="$(git -C "$repo" rev-parse --absolute-git-dir)"
if [ ! -e "$gitdir/objects/info/commit-graph" ] && [ ! -d "$gitdir/objects/info/commit-graphs" ]; then
  if [ "${BENCH_WRITE_COMMIT_GRAPH:-0}" = "1" ]; then
    echo "writing commit-graph for $repo"
    git -C "$repo" commit-graph write --reachable
  else
    echo "warning: $repo has no commit-graph; first-screen budgets assume one (research R2)" >&2
  fi
fi

commits="$(git -C "$repo" rev-list --count --all)"
{
  echo "## trellis.nvim kernel benchmark"
  echo
  echo "- repo: \`$(basename "$repo")\` ($commits commits)"
  echo "- nvim: $(${NVIM:-nvim} --version | head -1)"
  echo "- git: $(git --version)"
  echo
} | tee bench-header.md

out="$(TRELLIS_BENCH_REPO="$repo" scripts/test.sh bench 2>&1)" || status=$?
echo "$out"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    cat bench-header.md
    echo '```'
    echo "$out"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
rm -f bench-header.md
exit "${status:-0}"
