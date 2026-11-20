-- README tour, recorded in a LazyVim setup with trellis keys <leader>gT/gB/gR/gz (README
-- "Install") on a clone of a small Go project prepared with: a commit referencing issues, a
-- commit lost by `reset --hard`, one stash entry. Read-only on that clone except the stash
-- apply (undone at the end) and the rescue branch.
return function(t)
  t.wait(2500)
  t.keys("cls<CR>", 800)
  t.mark()
  t.wait(600)
  t.cap("nvim .", "open the project")
  t.type("nvim .", 90, 400)
  t.keys("<CR>", 5000)

  -- Open a Go file from the explorer.
  t.press({ "j" }, "j", "move down", 600)
  t.press({ "<CR>" }, "Enter", "open folder", 1200)
  t.press({ "j", "j", "j", "j", "j", "j" }, "6j", "go to server.go", 900)
  t.press({ "<CR>" }, "Enter", "open file", 2000)
  t.press({ "<C-w>h" }, "Ctrl-w h", "to explorer", 700)
  t.press({ "q" }, "q", "close explorer", 1400)

  -- History graph.
  t.press({ " ", "g", "T" }, "Space g T", "trellis: history graph", 2600)
  t.press({ "<Tab>" }, "Tab", "files of this commit", 2600)
  t.press({ "<Tab>" }, "Tab", "close", 700)

  -- Commit view: issue links, then the diff (in the same window).
  t.press({ "<CR>" }, "Enter", "open commit", 3200)
  t.press({ "<CR>" }, "Enter", "diff of server.go", 3000)
  t.press({ "q" }, "q", "back to the commit", 1500)
  t.press({ "q" }, "q", "close commit", 1000)

  -- Find a commit with the picker you use (Snacks here).
  t.press({ "g", "p" }, "gp", "find a commit (picker)", 1500)
  t.type("initial", 120, 900)
  t.press({ "<CR>" }, "Enter", "jump to it in the graph", 2500)

  -- Reflog: a commit lost by `git reset --hard`, brought back with a branch.
  t.press({ " ", "g", "R" }, "Space g R", "trellis: reflog", 3000)
  t.cap("/wip", "find the lost commit")
  t.type("/wip", 110, 300)
  t.keys("<CR>", 1600)
  t.press({ "g", "b" }, "gb", "branch here", 1200)
  t.type("streaming", 110, 500)
  t.press({ "<CR>" }, "Enter", "get it back (undoable)", 3200)
  t.press({ "q" }, "q", "close reflog", 2600)

  -- Stash: see an entry, apply it, undo.
  t.press({ " ", "g", "z" }, "Space g z", "trellis: stashes", 2500)
  t.press({ "<CR>" }, "Enter", "what it changes", 2600)
  t.press({ "q" }, "q", "back", 1000)
  t.press({ "a" }, "a", "apply (undoable)", 3200)
  t.press({ "q" }, "q", "close", 2600)
  t.cap(":Trellis undo", "put the worktree back")
  t.keys(":", 300)
  t.type("Trellis undo", 70, 300)
  t.keys("<CR>", 3500)

  -- Blame time travel in the Go file.
  t.press({ "g", "t" }, "gt", "back to server.go", 1500)
  t.keys("37G", 600)
  t.press({ " ", "g", "B" }, "Space g B", "trellis: blame", 3000)
  t.press({ "[" }, "[", "this line, one change back", 3200)
  t.press({ "]" }, "]", "forward again", 2200)
  t.press({ "q" }, "q", "close blame", 1500)
end
