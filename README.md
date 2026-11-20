# trellis.nvim

> Git history you can walk through. A fast commit graph, any file at any commit, blame that
> travels back in time, and history actions you can undo — all in real Neovim buffers.

![trellis.nvim demo: graph, commit view with issue links, picker, reflog rescue, stash apply and undo, blame time travel](docs/media/trellis-demo.gif)

<sub>A real LazyVim session on a small Go project: open `server.go` → `<leader>gT` graph and
`<Tab>` file list → `<CR>` commit view with issue links → diff of a file → `gp` find a commit with
the picker → `<leader>gR` reflog: a commit lost by `reset --hard`, back with `gb` → `<leader>gz`
stash, `a` apply, `:Trellis undo` → `<leader>gB` blame, `[` one change back. Keys pressed are shown
bottom right; recorded with [scripts/demo](scripts/demo).</sub>

> [!NOTE]
> **Status: 1.0 release candidate.** Every feature of the plan is in: graph, filters and
> history search, inspection, blame time travel, undoable history actions, the visual rebase
> planner and `:checkhealth trellis`. Before 1.0: kernel-scale benchmarks, Linux/macOS runs and
> a usability round. See [docs/perf.md](docs/perf.md) for measurements.

## Features

- **Commit graph in a real buffer.** `:Trellis` streams history, so the first screen appears in
  about 100 ms even on a 200k-commit repository, and scrolling never waits for git. `/`, marks,
  `yy` and the jumplist work; refs read without color (`@main`, `~origin/main`, `#v1.0.0`). The
  graph refreshes by itself when you commit, fetch or switch branches elsewhere, and a line above
  HEAD shows uncommitted changes (`<CR>` for their diff).
- **Inspect anything.** `<CR>` opens a commit (metadata, parents, message, files and stats; merges
  against any parent). `o` opens a file *as it was* at that commit, with its filetype and
  Treesitter highlighting; `]r` / `[r` step through the file's revisions, following renames.
  Unified diffs with a fold per file, or side by side.
- **Blame that travels back in time.** `:Trellis blame` shows a blame column bound to your file.
  On a line, `[` shows the file just before the commit that last changed that line, with the
  cursor on the same line — keep pressing to walk through the line's whole history; `]` comes
  back. Unsaved edits read "Not committed yet".
- **Line history.** `:'<,'>Trellis history` lists every commit that touched the selected lines,
  with the hunk for each.
- **Actions you can undo.** Checkout, branches, tags, cherry-pick (several commits at once),
  revert, reset and restoring a file — from graph keys or `:Trellis`. Each shows what will
  happen, saves backup refs (and your uncommitted changes when they would be discarded) and is
  undone with `:Trellis undo` (`u` in the graph). Conflicts open a guided panel.
- **Interactive rebase you can see before you run it.** `gr` on a commit opens the plan as an
  ordinary editable buffer — reorder with `<M-j>`/`<M-k>` (or `dd`/`p`, mouse drag), change
  actions with `<M-s>` squash, `<M-f>` fixup, `<M-r>` reword, `<M-d>` drop, write messages with
  `<M-m>` — next to a live preview of the resulting history. Conflicts are predicted before
  anything runs (`git merge-tree`). `:w` runs it with git's own `rebase -i`, and `:Trellis undo`
  puts everything back.
- **Get lost commits back.** `:Trellis reflog` shows where HEAD has been and marks commits no
  branch reaches any more; `gb` puts a branch on one.
- **Stashes.** `:Trellis stash` lists them; `<CR>` shows the changes, `a` applies one (undoable;
  trellis never drops a stash).
- **Find a commit with your picker.** `:Trellis pick` (`gp` in the graph) uses Snacks, Telescope
  or fzf-lua — whichever you have — or `vim.ui.select`.
- **Issue and PR links.** `#12`, `GH-12`, `owner/repo#12` and GitLab's `!12` in a commit message
  become links in the commit view (`<CR>` opens them).
- **Permalinks** for lines or commits on GitHub, GitLab, Gitea/Codeberg and Bitbucket.
- **Pure Lua, no dependencies.** Only the `git` command line; every command trellis runs is a
  documented, tested invocation ([docs/git-commands.md](docs/git-commands.md)), and the ones it
ran are listed in `:Trellis log`. trellis never pushes, never runs
  `git gc`, never expires reflogs.

## Install

**Requirements:** Neovim ≥ 0.11 and git ≥ 2.30 on `PATH`. Newer git unlocks more: ≥ 2.38 for
`update-ref` lines in rebase plans, ≥ 2.40 for exact rebase conflict prediction. No Nerd Font
needed: the graph uses plain box-drawing characters (or ASCII).

### lazy.nvim / LazyVim

Create `~/.config/nvim/lua/plugins/trellis.lua` (on Windows
`%LOCALAPPDATA%\nvim\lua\plugins\trellis.lua`):

```lua
return {
  {
    "j4flmao/trellis.nvim",
    lazy = false, -- startup cost < 1 ms; keeps trellis:// buffers working in every session
    opts = {},    -- see "Configuration" below; calling setup() is optional
    keys = {
      { "<leader>gT", "<cmd>Trellis<cr>", desc = "Trellis: history graph" },
      { "<leader>gB", "<cmd>Trellis blame<cr>", desc = "Trellis: blame time travel" },
      { "<leader>gF", "<cmd>Trellis file<cr>", desc = "Trellis: file history" },
      { "<leader>gO", "<cmd>Trellis ops<cr>", desc = "Trellis: operations (undo)" },
      { "<leader>g/", "<cmd>Trellis pick<cr>", desc = "Trellis: find a commit" },
      { "<leader>gR", "<cmd>Trellis reflog<cr>", desc = "Trellis: reflog (lost commits)" },
      { "<leader>gz", "<cmd>Trellis stash<cr>", desc = "Trellis: stashes" },
    },
  },
}
```

Restart Neovim (or run `:Lazy sync`). These keys sit next to LazyVim's own `<leader>g…` git
keys without replacing any of them.

### Neovim 0.12 `vim.pack`

```lua
vim.pack.add({ "https://github.com/j4flmao/trellis.nvim" })
```

### mini.deps

```lua
MiniDeps.add({ source = "j4flmao/trellis.nvim" })
```

### Without a plugin manager

```sh
git clone https://github.com/j4flmao/trellis.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/trellis.nvim
```

On Windows (PowerShell):

```powershell
git clone https://github.com/j4flmao/trellis.nvim "$env:LOCALAPPDATA\nvim-data\site\pack\plugins\start\trellis.nvim"
```

### After installing

1. Run `:checkhealth trellis` once: it checks Neovim and git versions, the features your git
   supports, and whether the graph glyphs render in your font.
2. Open any file in a git repository and run `:Trellis` (or `<leader>gT` with the keys above).
3. Press `g?` in any trellis view to see its keys. `:help trellis` documents everything below.

To update, use your plugin manager (`:Lazy update`). trellis has no build step and no
dependencies.

## Quick tour

| In… | Key / command | Does |
|---|---|---|
| anywhere | `:Trellis` | open the graph (`:Trellis main -- src/` to narrow it) |
| graph | `F` / `g/` | edit filters (`--author=… -S… -- path`) / search all history |
| graph | `<CR>` / `<Tab>` | commit view / inline file list |
| graph | `o` / `d` | a file of the commit at that revision / the commit's diff |
| graph | `M` then `=` | compare two commits |
| graph | `J` `K` / `]b` `[b` / `gH` / `G` | next commit / next ref / HEAD / load all |
| graph | `gy` `gY` `gL` | copy short sha / full sha / permalink |
| graph | `c` / `x` / `gco` / `gR` | cherry-pick (visual: several) / revert / checkout / reset |
| graph | `gb` / `gA` / `u` | new branch / new tag / undo |
| graph | `gr` | rebase planner with this commit as base (`:Trellis rebase <base>`) |
| plan | `<M-j>`/`<M-k>`, `<M-s>` `<M-f>` `<M-r>` `<M-d>`, `<M-m>`, `:w` | move, squash/fixup/reword/drop, message, run |
| file | `:Trellis blame` | blame column; `[` back in time, `]` forward, `<CR>` commit |
| file | `:'<,'>Trellis history` | history of the selected lines |
| file | `:Trellis file` | history of the file, following renames |
| file at a revision | `]r` / `[r` | newer / older revision of this file |
| anywhere | `:Trellis undo` / `redo` / `ops` / `log` | undo, redo, the journal, git commands run |
| anywhere | `:Trellis pick` / `reflog` / `stash` | find a commit / where HEAD has been / stashes |
| any view | `g?` | keys of this view |

Large repositories: write a commit-graph once (`git commit-graph write --reachable`, or
`:Trellis commit-graph`) and the graph's first screen stays fast regardless of history size.

## Configuration

Everything is optional; unknown keys are reported with a suggestion.

```lua
require("trellis").setup({
  graph = { style = "rounded", date_format = "relative", open = "tab" },
  blame = { ignore_whitespace = true, detect_moves = "file", width = 40 },
  safety = { confirm = "destructive" }, -- "always" | "destructive" | "never"
  keymaps = { graph = { yank_permalink = "<leader>gl" } }, -- or false to disable one
})
```

See `:help trellis-config` for every option.

## FAQ

**How is this different from Neogit?** Neogit is a Magit-style status and staging UI; its log is
one view among many. trellis focuses on history only — graph, inspection, time travel, undoable
actions and previewed rebases — and works fine alongside Neogit, fugitive or gitsigns for
staging.

**…from vim-flog?** vim-flog is a fast, well-loved graph viewer built on fugitive. trellis needs no
other plugin, streams huge histories with backpressure, and adds file-at-revision buffers, blame
time travel, undoable actions and an interactive rebase planner with preview.

**…from lazygit in a floating terminal?** lazygit is excellent and does a lot more git. trellis
keeps history in Neovim buffers, so file contents at any commit get Treesitter highlighting,
searching and yanking work with Vim motions, and nothing context-switches to a TUI.

**…from tardis.nvim / agitator.nvim?** Those step through one file's history. trellis steps through
one *line's* history (blame-driven), and connects it to the graph, commit and diff views.

**Does trellis ever change my repository?** Only when you run an action, after showing what it
will do. Before anything moves, trellis writes backup refs under `refs/trellis/backup/` and a
journal entry in `.git/trellis/ops.jsonl`; `:Trellis undo` restores the previous state, including
uncommitted changes a hard reset discarded. See `:help trellis-safety` for what is written and
how to remove it.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues labelled `data-loss` or `wrong-history` are fixed
before anything else.

## License

[MIT](LICENSE)
