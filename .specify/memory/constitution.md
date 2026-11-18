<!--
Sync Impact Report
- Version: 1.0.0 → 1.0.1 (PATCH: Principle V glyph styles clarified to match research R13 — four styles)
- Previous: 0.0.0 → 1.0.0 (initial ratification)
- Principles added: I–VIII
- Sections added: Technical Constraints, Development Workflow, Governance
- Templates requiring updates: none (initial version)
- Deferred TODOs: none (name finalized as trellis.nvim — see research R15)
-->

# trellis.nvim Constitution

trellis.nvim is a Neovim plugin that turns git history into a first-class, explorable space inside Neovim: an interactive commit graph, commit and file inspection at any revision, blame "time travel", and a visual interactive-rebase planner — all as real Neovim buffers.

## Core Principles

### I. Never Lose Work (NON-NEGOTIABLE)

- Every operation that rewrites history or moves refs (rebase, reset, amend, drop, fixup, branch delete, force checkout) MUST create a recoverable backup ref under `refs/trellis/backup/` before running, and MUST be undoable with a single `:Trellis undo`.
- Destructive operations MUST show a preview of the resulting graph and require explicit confirmation. Defaults MUST be the safe choice (abort, keep, no force).
- trellis MUST refuse to start a history rewrite on a dirty worktree unless the user opts into autostash for that operation.
- trellis MUST never run `git push`, `git push --force`, `git gc`, or `git reflog expire` on its own.
- A bug that loses commits or uncommitted changes is a release blocker and is fixed before any feature work.

### II. Git Is the Source of Truth

- trellis MUST drive the real `git` CLI (porcelain/plumbing with stable machine-readable formats). It MUST NOT reimplement git object storage or ref updates, and MUST NOT require libgit2 or any compiled module.
- Every state trellis shows MUST be re-derivable from `git` output; trellis MUST detect external changes (other terminals, lazygit, CI hooks) and refresh instead of acting on stale state.
- Any git command trellis runs for a user action MUST be visible in `:Trellis log` with its exact argv, so users can learn and reproduce it.

### III. Fast on Huge Repositories

Performance budgets are requirements, measured on the Linux kernel repository (≈1.3M commits) on a mid-range laptop:
- Plugin startup cost: < 1 ms.
- First screen of the commit graph: < 300 ms after `:Trellis`.
- Scrolling (`<C-d>`, `G` excluded): every redraw < 16 ms; the main loop is never blocked by git I/O.
- `G` / jump to oldest commit: allowed to stream, but UI stays responsive and shows progress.
- Memory: < 60 MB for the first 50k commits; < 300 MB for a fully loaded kernel history. History is loaded on demand, so memory grows only with what the user explores.

### IV. Real Buffers, Vim Grammar

- Every view (graph, commit, file-at-revision, blame, rebase plan) MUST be a normal buffer: searchable with `/`, yankable, usable with marks, jumplist, quickfix, and `:w` where it makes sense (e.g. the rebase plan).
- File contents at any revision MUST open with the correct filetype so Treesitter highlighting and (read-only) LSP features work.
- Default keymaps MUST be buffer-local, documented, and individually remappable or disable-able. trellis MUST NOT create global mappings.
- Mouse support (click, drag to reorder in the rebase plan) is a bonus layer; every action MUST also be reachable from the keyboard.

### V. Visual Clarity Over Density

- The commit graph MUST be topologically correct (same parent/child relationships as `git log --graph`) and stable while scrolling (no lane jumping between redraws).
- Ref decorations (HEAD, local/remote branches, tags, stashes) MUST be distinguishable without color (shape/prefix), for accessibility and monochrome terminals.
- Four rendering styles ship: `ascii`, `unicode` (box drawing, works in any Nerd-Font-free terminal), `rounded` (rounded box-drawing corners), and `flog-symbols` (opt-in; needs the flog-symbols font or kitty).

### VI. Small Core, Composable Edges

- Core: git layer, graph engine, views, rebase engine, blame engine. Optional integrations (diffview.nvim, codediff.nvim, built-in `:DiffTool`, pickers through `vim.ui.select`, gitsigns, statusline) live behind adapters.
- No hard dependency on any other plugin. No dependency on plenary.
- Public Lua API and `User` events exist so other plugins (Neogit, gitsigns, AI review tools) can open trellis views.

### VII. Test-First for the Engines

- The graph layout engine, the git output parsers, and the rebase engine MUST be developed test-first.
- Tests run against generated fixture repositories (deterministic author/committer dates), including octopus merges, criss-cross merges, orphan branches, root commits, rename chains, submodules, and repos with 100k+ synthetic commits.
- The graph engine MUST be checked against `git log --graph` topology for every fixture.
- Every data-loss or wrong-history bug adds a regression fixture before the fix merges.
- CI runs Neovim stable + nightly on Linux and macOS, with git minimum version and latest.

### VIII. Documentation Is a Feature

- Every command, option, keymap, highlight group, event, and API function MUST be documented in `doc/trellis.txt` and the README.
- The README opens with a one-line pitch, a demo GIF, and a zero-config install snippet.
- Breaking changes require a migration note and one minor release of deprecation.

## Technical Constraints

- Neovim ≥ 0.11.0 (target 0.12.x stable; nightly-only APIs behind feature detection).
- git ≥ 2.30 (for `--format` atoms, `rebase --update-refs` detection, `commit-graph`). Features needing newer git (e.g. `git replay`, `--update-refs`) MUST be feature-detected.
- Pure Lua (LuaJIT). No compiled modules, no Python, no Node.
- OS: Linux and macOS tier 1; Windows (native and WSL) tier 2, best effort.
- License: MIT.

## Development Workflow

- Spec-driven: each feature lives in `specs/NNN-name/` with spec → plan → tasks before code.
- Branch per feature, squash merge, Conventional Commits, release-please, semantic versioning.
- Every user-visible release ships with a short demo clip and an r/neovim post (see ROADMAP.md).
- Weekly triage. Labels `data-loss` and `wrong-history` preempt all other work.

## Governance

- This constitution supersedes other practices. Every `plan.md` MUST include a Constitution Check that passes before implementation.
- Amendments: written proposal in an issue, version bump (MAJOR: principle removed/redefined; MINOR: added; PATCH: clarification), updated Sync Impact Report.
- Complexity that violates a principle MUST be justified in the plan's Complexity Tracking table or rejected.

**Version**: 1.0.1 | **Ratified**: 2026-11-17 | **Last Amended**: 2026-11-17
