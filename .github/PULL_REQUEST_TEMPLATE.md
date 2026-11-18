## What and why

<!-- Link the issue this fixes. -->

## Constitution checklist

- [ ] **I. Never lose work**: no new ref/index/worktree write, *or* it goes through the safety pipeline (backup refs + journal), has a preview/confirm, and a test shows `:Trellis undo` restores the previous state
- [ ] **II. Git is the source of truth**: new git invocations are listed in `docs/git-commands.md` and covered by `git_argv_spec.lua`; nothing on the never-run list
- [ ] **III. Fast on huge repos**: no git I/O on the main loop; hot paths checked against the bench budgets when touched
- [ ] **IV. Real buffers, Vim grammar**: keymaps are buffer-local, have `desc`, are remappable, and follow the keymap policy (no protected built-ins shadowed)
- [ ] **V. Visual clarity**: graph topology unchanged or verified against `git log --graph` on fixtures
- [ ] **VI. Small core**: no new hard dependency
- [ ] **VII. Test-first**: engine/parser/rebase/safety changes come with tests written first; data-loss or wrong-history fixes add a regression fixture
- [ ] **VIII. Docs**: `doc/trellis.txt` and README updated for any user-visible change

## Testing

<!-- ./scripts/test.sh ci output, manual scenarios run, platforms tried. -->
