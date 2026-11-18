local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local todo = require("trellis.git.parse.todo")

T["git todo with every command, full and abbreviated"] = function()
  local text = table.concat({
    "pick 1a2b3c4 add login form",
    "r 2b3c4d5 wip",
    "edit 3c4d5e6 # subject after hash",
    "s 4d5e6f7 squash me",
    "fixup 5e6f7a8 fix typo",
    "fixup -C 6f7a8b9 keep my message",
    "f -c 7a8b9c0 edit my message",
    "d 8b9c0d1 dropped",
    "exec make test",
    "x echo   spaced   args",
    "break",
    "b",
    "label onto",
    "reset onto",
    "t [new root]",
    "merge -C 9c0d1e2 feature # Merge branch 'feature'",
    "merge feature2",
    "update-ref refs/heads/stack-1",
    "",
    "# Rebase abc..def onto abc (3 commands)",
    "#",
  }, "\n")
  local entries, errors = todo.parse(text)
  eq(errors, {})
  eq(#entries, 18)
  eq(
    entries[1],
    { kind = "entry", action = "pick", sha = "1a2b3c4", subject = "add login form", lnum = 1 }
  )
  eq(entries[2].action, "reword")
  eq(entries[3].subject, "subject after hash")
  eq(entries[6].action, "fixup_C")
  eq(entries[7].action, "fixup_c")
  eq(entries[7].sha, "7a8b9c0")
  eq(entries[10].arg, "echo   spaced   args")
  eq(entries[12].action, "break")
  eq(entries[15].arg, "[new root]")
  eq(entries[16].merge_flag, "-C")
  eq(entries[16].sha, "9c0d1e2")
  eq(entries[16].arg, "feature")
  eq(entries[16].subject, "Merge branch 'feature'")
  eq(entries[17].arg, "feature2")
  eq(entries[18], { kind = "entry", action = "update_ref", arg = "refs/heads/stack-1", lnum = 18 })
end

T["round trip through serialize"] = function()
  local text = table.concat({
    "pick 1a2b3c4 add login form",
    "fixup -C 6f7a8b9 keep",
    "fixup -c 7a8b9c0 edit",
    "exec make test",
    "break",
    "label onto",
    "merge -C 9c0d1e2 feature # Merge branch 'feature'",
    "update-ref refs/heads/x",
    "drop 8b9c0d1 bye",
  }, "\n") .. "\n"
  local entries = todo.parse(text)
  eq(todo.serialize(entries), text)
  -- Abbreviations are expanded on output.
  eq(
    todo.serialize((todo.parse("p abc1234 x\nf abc1235 y\n"))),
    "pick abc1234 x\nfixup abc1235 y\n"
  )
end

T["errors carry line numbers"] = function()
  local _, errors = todo.parse("pick abc1234 ok\nfrobnicate abc\npick\nexec\nlabel\n")
  eq(
    vim.tbl_map(function(e)
      return e.lnum
    end, errors),
    { 2, 3, 4, 5 }
  )
  eq(errors[1].message, 'unknown action "frobnicate"')
end

T["trellis plan alias F"] = function()
  eq(todo.parse_line("F abc1234 msg").kind, "error")
  eq(todo.parse_line("F abc1234 msg", { trellis_aliases = true }).action, "fixup_C")
end

T["CRLF todo files"] = function()
  local entries = todo.parse("pick abc1234 one\r\npick abc1235 two\r\n")
  eq(entries[2].subject, "two")
end

return T
