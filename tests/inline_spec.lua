local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local inline = require("diffmerge.inline")

--- "a[b]c" notation of the changed ranges.
local function mark(s, ranges)
  local out, pos = {}, 0
  for _, r in ipairs(ranges) do
    out[#out + 1] = s:sub(pos + 1, r[1]) .. "[" .. s:sub(r[1] + 1, r[2]) .. "]"
    pos = r[2]
  end
  out[#out + 1] = s:sub(pos + 1)
  return table.concat(out)
end

local function diff(a, b, mode)
  local ra, rb = inline.line_diff(a, b, mode)
  return { mark(a, ra), mark(b, rb) }
end

H.describe("inline differences", function()
  H.it("character level (diffopt inline:char)", function()
    H.eq(diff('name = "app"', 'name = "STAGED"', "char"), { 'name = "[app]"', 'name = "[STAGED]"' })
    H.eq(diff("return a + b", "return (a or 0) + (b or 0)", "char"), {
      "return a + b",
      "return [(]a [or 0) ]+ [(b or 0)]",
    })
    H.eq(diff("same", "same", "char"), { "same", "same" })
  end)

  H.it("word level and simple", function()
    H.eq(diff("local foo = bar", "local fob = bar", "word"), { "local [foo] = bar", "local [fob] = bar" })
    H.eq(diff("abcdef", "abXdef", "simple"), { "ab[c]def", "ab[X]def" })
    H.eq(diff("abc", "abXc", "simple"), { "abc", "ab[X]c" })
    H.eq(inline.line_diff("a", "b", "none"), {})
  end)

  H.it("multibyte characters stay whole", function()
    H.eq(diff("čaj", "čáj", "char"), { "č[a]j", "č[á]j" })
  end)

  H.it("pairs the lines of a block row by row, like the views show them", function()
    local ra, rb = inline.block({ "foo = 1", "bar = 2" }, { "foo = 10", "bar = 3", "new" }, { mode = "char" })
    H.eq(ra, { [2] = { { 6, 7 } } })
    H.eq(rb, { [1] = { { 7, 8 } }, [2] = { { 6, 7 } } })
  end)

  H.it("simple mode keeps whole characters", function()
    H.eq(diff("pąk", "pęk", "simple"), { "p[ą]k", "p[ę]k" })
    H.eq(diff("日本語テキスト", "日本語テスト", "simple"), { "日本語テ[キ]スト", "日本語テスト" })
  end)

  H.it("combining marks stay with their character", function()
    local e1, e2 = "e\u{301}", "e\u{302}"
    H.eq(diff("x" .. e1 .. "y", "x" .. e2 .. "y", "char"), { "x[" .. e1 .. "]y", "x[" .. e2 .. "]y" })
  end)

  H.it("iwhite / iwhiteall / iwhiteeol / icase", function()
    H.eq(inline.line_diff("a  b", "a b", { mode = "char", iwhite = true }), {})
    H.eq(inline.line_diff("a b ", "a b", { mode = "char", iwhiteeol = true }), {})
    H.eq(inline.line_diff("ab", "a b", { mode = "char", iwhiteall = true }), {})
    H.eq(inline.line_diff("Foo", "foo", { mode = "char", icase = true }), {})
    H.eq(diff("a  b", "a b", "char"), { "a [ ]b", "a b" })
  end)

  H.it("remembers line pairs: a big block costs little after the first time", function()
    local a, b = {}, {}
    for i = 1, 5000 do
      a[i] = ("local value_%d = compute(%d)"):format(i, i)
      b[i] = "  " .. a[i]
    end
    local block = inline.cache()
    block(a, b)
    b[2500] = b[2500] .. " -- edited"
    local t = vim.uv.hrtime()
    block(a, b)
    local ms = (vim.uv.hrtime() - t) / 1e6
    H.ok(ms < 150, ("second pass took %.0f ms"):format(ms))
  end)

  H.it("its colours do not depend on the groups the views mute", function()
    for _, name in ipairs({ "DiffMergeAdd", "DiffMergeChange", "DiffMergeText", "DiffMergeChangeText" }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      H.eq(hl.link, nil, name .. " must not link to a Diff* group")
    end
  end)
end)

--- Inline highlights in a buffer: "row:text" of every range painted with `group`.
local function painted(buf, ns, group)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group == group and d.end_col and (d.end_row or m[2]) == m[2] then
      local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
      out[#out + 1] = (m[2] + 1) .. ":" .. line:sub(m[3] + 1, d.end_col)
    end
  end
  table.sort(out)
  return out
end

H.describe("inline differences in the views", function()
  local api = vim.api

  H.it("merge: a conflict's sides against each other, MERGED against BASE", function()
    local dir = H.repo({ ["f.txt"] = { "x = 1", "keep", "name = app", "z" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "x = 1", "keep", "name = theirs", "z" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "x = 2", "keep", "name = ours", "z" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    vim.cmd.cd(dir)
    local view = require("diffmerge").status({ conflicts = true })
    local ns = require("diffmerge.merge").ns_hl
    local L = api.nvim_win_get_buf(view.layout.wins["local"])
    local R = api.nvim_win_get_buf(view.layout.wins.remote)
    local M = api.nvim_win_get_buf(view.layout.wins.merged)
    H.eq(painted(L, ns, "DiffMergeConflictText"), { "3:ou" }, "\"rs\" is shared")
    H.eq(painted(R, ns, "DiffMergeConflictText"), { "3:thei" })
    -- the auto-merged x = 2 against BASE; nothing inline in the unresolved conflict
    H.eq(painted(M, ns, "DiffMergeChangeText"), { "1:2" })
    H.eq(painted(M, ns, "DiffMergeConflictText"), {})
    view.merge:toggle(3, { win = view.layout.wins.merged })
    H.eq(painted(M, ns, "DiffMergeResolvedText"), { "3:theirs" })
  end)

  H.it("three columns: unstaged against INDEX, staged against HEAD", function()
    local dir = H.repo({ ["a.txt"] = { "name = app", "keep", "debug = false" } })
    H.write(dir, "a.txt", { "name = STAGED", "keep", "debug = false" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "name = STAGED", "keep", "debug = true" })
    vim.cmd.cd(dir)
    local view = require("diffmerge").status()
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    local ns = require("diffmerge.stage").ns
    local W = api.nvim_win_get_buf(view.layout.wins.worktree)
    local I = api.nvim_win_get_buf(view.layout.wins.index)
    local Hd = api.nvim_win_get_buf(view.layout.wins.head)
    H.eq(painted(W, ns, "DiffMergeStagedText"), { "1:STAGED" })
    H.eq(painted(W, ns, "DiffMergeUnstagedText"), { "3:tru" })
    H.eq(painted(I, ns, "DiffMergeStagedText"), { "1:STAGED" })
    H.eq(painted(I, ns, "DiffMergeUnstagedText"), { "3:fals" })
    H.eq(painted(Hd, ns, "DiffMergeStagedText"), { "1:app" })
  end)

  H.it("follows 'diffopt' changes at once", function()
    local saved = vim.o.diffopt
    local ok, err = pcall(function()
      local dir = H.repo({ ["a.txt"] = { "name = app" } })
      H.write(dir, "a.txt", { "name = new" })
      H.git(dir, { "add", "a.txt" })
      H.write(dir, "a.txt", { "name = newer" })
      vim.cmd.cd(dir)
      local view = require("diffmerge").status()
      view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
      local W = api.nvim_win_get_buf(view.layout.wins.worktree)
      local ns = require("diffmerge.stage").ns
      H.ok(#painted(W, ns, "DiffMergeMixedText") + #painted(W, ns, "DiffMergeUnstagedText") > 0)
      vim.cmd("set diffopt-=inline:char diffopt+=inline:none")
      H.flush(50)
      H.eq(painted(W, ns, "DiffMergeMixedText"), {})
      H.eq(painted(W, ns, "DiffMergeUnstagedText"), {})
    end)
    vim.o.diffopt = saved
    assert(ok, err)
  end)

  H.it("diffopt inline:none turns it off", function()
    local saved = vim.o.diffopt
    vim.opt.diffopt:remove("inline:char")
    vim.opt.diffopt:append("inline:none")
    local ok, err = pcall(function()
      local dir = H.repo({ ["a.txt"] = { "name = app" } })
      H.write(dir, "a.txt", { "name = new" })
      H.git(dir, { "add", "a.txt" })
      H.write(dir, "a.txt", { "name = newer" })
      vim.cmd.cd(dir)
      local view = require("diffmerge").status()
      view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
      local W = api.nvim_win_get_buf(view.layout.wins.worktree)
      local ns = require("diffmerge.stage").ns
      H.eq(painted(W, ns, "DiffMergeUnstagedText"), {})
      H.eq(painted(W, ns, "DiffMergeMixedText"), {})
    end)
    vim.o.diffopt = saved
    assert(ok, err)
  end)
end)

H.done()
