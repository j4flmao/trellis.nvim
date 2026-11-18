# Git invocations

Every git command trellis runs is listed here. Adding a new invocation requires updating this file and the tests in `tests/unit/git_argv_spec.lua`. All commands are run with:

- `git -C <root> -c core.quotepath=off -c color.ui=false --no-pager ...`
- env: `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat`; read-only commands also set `GIT_OPTIONAL_LOCKS=0`; writing commands (`W`, `O`) set `GIT_EDITOR=:` and `GIT_SEQUENCE_EDITOR=:` (sh no-op: never wait for an editor) unless the caller supplies its own (rebase helpers).
- stdin closed unless stated.
- Separators: fields `%x00` (NUL), records `%x1e` (RS).
- Commands that print diffs pass `--src-prefix=a/ --dst-prefix=b/` so user config (`diff.noprefix`, `diff.mnemonicPrefix`) cannot change paths.
- Builders live in `lua/trellis/git/argv.lua`, one function per ID; `tests/unit/git_argv_spec.lua` fails if this table and the module disagree.

`R` = read-only, `W` = writes refs/index/worktree (journaled, backup first), `O` = writes objects only (no refs).

## Discovery & state

| ID | Command | Kind | Parsed into |
|---|---|---|---|
| G01 | `git rev-parse --show-toplevel --absolute-git-dir --git-common-dir --is-shallow-repository --show-object-format` | R | Repository |
| G02 | `git version` | R | GitFeatures.version |
| G03 | `git worktree list --porcelain -z` | R | Worktree[]; `-z` only on git ≥ 2.36, newline-separated output before |
| G04 | `git for-each-ref --format=%(objectname)%00%(*objectname)%00%(refname)%00%(upstream)%00%(HEAD)%1e` | R | RefMap |
| G05 | `git symbolic-ref -q HEAD` / `git rev-parse -q --verify HEAD` | R | RefMap.head |
| G07 | `git status --porcelain=v2 -z --untracked-files=no` | R | Dirty check, conflict panel file list |
| G08 | `git merge-base --is-ancestor <a> <b>` | R | Unmerged-branch warning, cherry-pick ordering; exit 1 = no |
| G09 | `git for-each-ref --format=%(refname)%00%(objectname) <refname...>` | R | Raw ref values for operation snapshots (annotated tags: the tag object) |
| G06 | file reads: `<gitdir>/rebase-merge/{done,git-rebase-todo,stopped-sha,onto,head-name}`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG` | R | RepoState |

## Graph & search

| ID | Command | Kind | Notes |
|---|---|---|---|
| G10 | `git log --topo-order --format=%H%x00%P%x00%an%x00%at%x00%s%x1e <revs> [--author=] [--since=] [--until=] [--grep=] [-S/-G] [--first-parent] [--regexp-ignore-case] [--parents -- paths]` | R | `--parents` with paths makes git rewrite %P to shown ancestors; commit filters (author, grep, pickaxe, dates) do not rewrite parents, so the view lays them out again once the stream ends (only edges between shown commits). Streamed with backpressure; `--date-order` when `order=date` or fast-first-screen fallback |
| G11 | `git show -s --date=raw --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%ad%x00%cn%x00%ce%x00%ct%x00%cd%x00%G?%x00%GS%x00%B <sha>` | R | CommitDetails (lazy, LRU); `%ad`/`%cd` raw give both time zones |
| G12 | `git diff-tree --no-commit-id -r -z --numstat --find-renames --root <sha>`; merge against parent N: `… --find-renames <parent> <sha>`; combined: `… --cc <sha>` | R | FileChange[]; `--root` instead of `<sha>^!` so root commits work |
| G13 | `git diff-tree --no-commit-id -r -z --name-status` with the same revision forms as G12 | R | statuses (merged with G12); combined form gives one status letter per parent |
| G14 | `git log --no-walk --format=%H%x00%s <sha...>` | R | Parent subjects in the commit view |

## Diffs & files

| ID | Command | Kind | Notes |
|---|---|---|---|
| G15 | `git log --format=%h %s <a>..<b>` | R | Reset preview: commits that leave the branch |
| G16 | `git for-each-ref --format=%(refname) refs/trellis/backup/<id>/` | R | Backup refs of one operation (prune) |
| G20 | `git diff --patch --find-renames --no-ext-diff --no-color <a> <b> [-- path]` | R | Unified diff view |
| G21 | `git cat-file -s <sha>:<path>` (index stage: `:<n>:<path>`) | R | Size guard |
| G22 | `git cat-file --filters <sha>:<path>` | R | trellis:// content (fallback `git show <sha>:<path>` if `--filters` unsupported) |
| G23 | `git log --follow --format=%x1e%H%x00%P%x00%an%x00%at%x00%s%x00 --name-status [<rev>] -- <path>` | R | File history with old paths; RS starts each record so the name-status lines stay with their commit |
| G24 | `git rev-parse --verify -q <rev>^{commit}` | R | Resolve abbreviated shas / revisions (trellis:// names, `:Trellis commit`); exit 1 = unknown |
| G25 | `git rev-list -1 <rev> -- <path>` | R | Newest commit at or before `<rev>` that changed `<path>` (position for `]r`/`[r`) |

## Blame & line history

| ID | Command | Kind | Notes |
|---|---|---|---|
| G26 | `git cat-file blob <sha>` | R | Restore a saved working-tree file (undo of restore_file) |
| G30 | `git blame --incremental [-w] [-M] [-C] [--ignore-revs-file=<f>] [--contents -] <rev> -- <path>` | R | Incremental format (porcelain-like headers incl. `previous`, `filename`); stdin = buffer text when `--contents -` |
| G31 | `git diff -U0 --no-color <parent> <commit> -- <old_path> <new_path>` | R | Line mapping for time travel |
| G32 | `git log -L<s>,<e>:<path> --format=%x1e%H%x00%P%x00%an%x00%at%x00%s%x00 <rev>` | R | Range history; RS starts each record so the patch after a commit stays in its record |
| G33 | `git remote get-url <remote>` | R | Permalink base URL |

## Rebase planning & prediction

| ID | Command | Kind | Notes |
|---|---|---|---|
| G40 | `git rev-list --reverse --topo-order [--no-merges unless rebase_merges] <base>..HEAD` | R | Plan entries |
| G41 | `git rev-list <base>..HEAD --not --remotes` | R | Unpublished set |
| G42 | `git cherry <onto> HEAD <base>` | R | Duplicate detection (`-` lines). Only when `plan.onto ≠ plan.base`; a rebase in place onto its own base has no other side, so G42 is skipped |
| G43 | `git merge-tree --write-tree --messages --name-only -z --merge-base=<c>^ <tip> <c>` | O | Exact prediction (git ≥ 2.40); exit 1 = conflict |
| G44 | `git commit-tree <tree> -p <tip> -m trellis-sim` | O | Creates dangling sim commit to chain G43 |
| G45 | `git diff-tree -p -U0 --no-color --root <sha>` | R | Heuristic prediction cache |

## Writes (all journaled; backup first)

| ID | Command | Kind | Notes |
|---|---|---|---|
| W01 | `git update-ref --stdin` with `start`/`create`/`update`/`verify`/`commit` lines | W | Backup refs and undo restores, atomic |
| W02 | `git stash create` then W01 `create refs/trellis/backup/<id>/stash <sha>` | O+W | Preserve uncommitted changes without touching worktree |
| W10 | `git rebase -i [--autostash] <base>` with env `GIT_SEQUENCE_EDITOR`, `GIT_EDITOR` (see uri-and-buffers.md §Helpers) | W | The planned todo is authoritative: `update-ref` lines are written by trellis (git ≥ 2.38), so `--update-refs` is not passed; `--rebase-merges` plans are not supported yet |
| W11 | `git rebase --continue` / `--skip` / `--abort` (same env) | W | |
| W20 | `git switch <branch>` / `git switch --detach <sha>` | W | Refuses if dirty and conflicting (git's own check) |
| W21 | `git branch <name> <sha>` / `git branch -m <old> <new>` / `git branch -D <name>` | W | -D only after confirm; backup tip |
| W22 | `git tag <name> <sha>` / `git tag -a <name> -m <msg> <sha>` / `git tag -d <name>` | W | |
| W23 | `git cherry-pick <sha...>` / `--continue` / `--skip` / `--abort` | W | `-x` optional by config |
| W24 | `git revert --no-edit <sha>` (merge: `-m <n>`) / `--continue` / `--skip` / `--abort` | W | |
| W25 | `git reset --soft|--mixed|--hard <sha>` | W | `--hard` requires W02 first if dirty |
| W26 | `git add -- <path>` (mark resolved) / `git checkout --ours|--theirs -- <path>` | W | Conflict panel |
| W27 | `git commit-graph write --reachable` | O | Only on explicit user action or `perf.write_commit_graph = true` |
| W28 | `git stash apply --index <sha>` (fallback without `--index` if the staged state cannot be restored) | W | Undo of a discarding operation |
| W29 | `git hash-object -w --no-filters -- <path>` | O | Save a working-tree file before `restore_file` overwrites it |
| W30 | `git reset --keep\|--soft\|--mixed <sha>` | W | Undo/redo moving the checked-out branch (`--keep` refuses to lose local changes) |
| W31 | `git stash push -m <msg>` | W | Offered before an undo on a dirty worktree (never automatic) |

## Never run

`git push` (any form), `git gc`, `git prune`, `git reflog expire|delete`, `git filter-branch`, `git clean`, `git stash drop|clear`, `git update-ref -d` on non-trellis refs outside a journaled operation. Enforced in `runner.check_allowed()`.
