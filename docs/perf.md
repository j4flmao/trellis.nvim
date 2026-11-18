# Performance

Budgets come from the project constitution (Principle III). They are checked by
`tests/bench/` (`./scripts/test.sh bench`) on every run and by the weekly CI job on a Linux kernel
clone (`scripts/bench_kernel.sh`).

## Synthetic 200k-commit repository

`tests/fixtures/fastimport/gen.lua`: 200,000 commits, 8 branches, merge ratio 0.15, with a
commit-graph file. Measured 2026-11-18 on Windows 11, Neovim 0.11.5, git 2.51.0, through a child
Neovim with an attached UI (50×160).

| Measure | Result | Budget |
|---|---|---|
| Plugin startup (`plugin/trellis.lua`, median of 30) | < 1 ms | < 1 ms |
| First screen, from the `:Trellis` call | 102–155 ms | < 300 ms |
| Redraw while holding `<C-d>`, p95 | 0.6–0.8 ms | < 16 ms |
| Redraw while holding `<C-d>`, max | 1–2.4 ms | — |
| Full history (`G`, 200k commits) | 2.2–2.9 s | kernel (1.3M) < 20 s |
| Longest main-loop block during the full load | 50–100 ms | "UI stays responsive" (bench fails above 200 ms) |
| Memory growth for 50k commits (RSS) | 49–54 MB | < 60 MB |
| Memory after the full 200k load (RSS of the whole Neovim) | ~210 MB | kernel < 300 MB |

Ranges are over runs during development on the same machine (it was otherwise busy at times).

Without a commit-graph file the first `--topo-order` record takes ~650 ms on this repository;
trellis then shows a provisional first screen until the topological stream arrives.

### What keeps it fast

- One `git log` process per graph, paused through pipe backpressure while the user is not near
  the end of the loaded rows (`perf.prefetch_rows`).
- Parsing and lane layout run in slices of at most ~4 ms per main-loop turn, scheduled on timers
  so input and redraws happen in between; buffer lines are appended in slices with the same budget.
- Colors come from a decoration provider for visible lines only; no extmarks are stored per row.
- Rows are stored as strings in struct-of-arrays tables.

### Known limits

- During a full load, the main loop is still occasionally blocked for 50–100 ms; slices are
  ~4 ms, so these are most likely LuaJIT garbage-collection steps on a ~200 MB heap. trellis does
  not tune the GC (it would affect the user's whole Neovim).
- Commit-filtered graphs (`--author`, `--grep`, `-S`, dates) read the whole result before drawing
  edges; a pickaxe over a very large history takes as long as git needs.

## Linux kernel

Not measured yet: the numbers above are from the synthetic repository. Run

```sh
git clone --filter=blob:none --no-checkout https://github.com/torvalds/linux /tmp/linux
git -C /tmp/linux commit-graph write --reachable
./scripts/bench_kernel.sh /tmp/linux
```

or let the weekly `bench-weekly.yml` job do it, and record the results here.
