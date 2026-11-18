# Contributing to trellis.nvim

Thanks for helping. trellis rewrites git history, so the bar for correctness is high. Please read
[the constitution](.specify/memory/constitution.md) first; it overrides everything in this file.

## Priorities

Issues labelled **`data-loss`** or **`wrong-history`** preempt all other work, including releases.
If you think trellis lost a commit, moved a ref, or discarded uncommitted changes, open a
"Data loss" issue right away. Your work is very likely still recoverable:

```sh
git for-each-ref refs/trellis/backup/   # trellis backup refs, newest last
git reflog                              # git's own safety net
```

## Development workflow

- **Design first** for larger features: open an issue describing the behaviour before code.
  Changes in behaviour update `doc/trellis.txt` (and `docs/git-commands.md` if git is involved)
  in the same PR.
- **Branch per feature**, squash merge, **Conventional Commits** (`feat:`, `fix:`, `docs:`,
  `perf:`, `test:`, `refactor:`, `chore:`). Releases are cut by release-please from these
  messages.
- **Test-first** for the graph layout engine, the git output parsers, the rebase engine, and the
  safety/undo layer. Every data-loss or wrong-history fix adds a regression fixture first.
- Every new git invocation is added to
  [docs/git-commands.md](docs/git-commands.md) and
  `tests/unit/git_argv_spec.lua`.
- Every new command, option, keymap, highlight group, event and API function is documented in
  `doc/trellis.txt` and the README.

## Requirements

- Neovim ≥ 0.11, git ≥ 2.30
- [StyLua](https://github.com/JohnnyMorganz/StyLua) and [selene](https://github.com/Kampfkarren/selene) for linting

## Running tests

```sh
./scripts/test.sh                 # unit + integration
./scripts/test.sh unit            # one suite: unit | integration | e2e | bench
./scripts/test.sh ci              # unit + integration + e2e, as in CI
./scripts/test.sh tests/unit/harness_spec.lua   # one file
./scripts/bench_kernel.sh /path/to/linux        # optional, large
```

The first run installs [mini.test](https://github.com/nvim-mini/mini.test) into `.tests/deps`.
Tests run with isolated `XDG_*` directories and with git's global and system config disabled,
so your own config, hooks and signing never leak into fixtures.

Spec files are named `*_spec.lua` and live in `tests/{unit,integration,e2e,bench}/`.

## Linting

```sh
stylua --check lua tests helpers plugin
selene lua helpers plugin
```

## Trying a checkout

```sh
nvim -u tests/minimal_init.lua
```

## Pull requests

Fill in the PR template's constitution checklist. PRs that add or change a write operation
(anything that moves refs, the index, or the worktree) need a test showing that `:Trellis undo`
restores the previous state.
