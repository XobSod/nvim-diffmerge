-- A conflicted file with git's markers keeps git's merge; only the blocks start over.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

vim.fn.confirm = function()
  return 1
end

local BASE = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" }

local function with(changes)
  local t = vim.deepcopy(BASE)
  for k, v in pairs(changes) do
    t[k] = v
  end
  return t
end

--- feat and main change lines 2 and 9 differently: two conflicts, far enough apart for
--- git to keep them as two blocks.
local function conflicted(style)
  local dir = H.repo({ ["f.txt"] = BASE })
  if style then
    H.git(dir, { "config", "merge.conflictStyle", style })
  end
  H.git(dir, { "checkout", "-q", "-b", "feat" })
  H.commit(dir, "feat", { ["f.txt"] = with({ [2] = "FEAT2", [9] = "FEAT9" }) })
  H.git(dir, { "checkout", "-q", "main" })
  H.commit(dir, "main", { ["f.txt"] = with({ [2] = "MAIN2", [9] = "MAIN9" }) })
  vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
  return dir
end

--- `base` changed into `feat` and `main`; main merges feat (in `style`).
local function merged(base, feat, main, style)
  local dir = H.repo({ ["f.txt"] = base })
  if style then
    H.git(dir, { "config", "merge.conflictStyle", style })
  end
  H.git(dir, { "checkout", "-q", "-b", "feat" })
  H.commit(dir, "feat", { ["f.txt"] = feat })
  H.git(dir, { "checkout", "-q", "main" })
  H.commit(dir, "main", { ["f.txt"] = main })
  vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
  return dir
end

local function key_break()
  vim.cmd("let &undolevels = &undolevels")
end

local function open(dir)
  vim.cmd.cd(dir)
  local view = require("diffmerge").status({ conflicts = true })
  return view, api.nvim_win_get_buf(view.layout.wins.merged), view.layout.wins.merged
end

local function file_lines(dir)
  local lines = vim.split(H.read(dir, "f.txt"), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function replace_block(lines, k, with)
  -- the k-th block of git's markers replaced by `with`
  local out, n, skipping = {}, 0, false
  for _, l in ipairs(lines) do
    if l:match("^<<<<<<<") then
      n = n + 1
      skipping = n == k
      if skipping then
        vim.list_extend(out, with)
      else
        out[#out + 1] = l
      end
    elseif skipping then
      if l:match("^>>>>>>>") then
        skipping = false
      end
    else
      out[#out + 1] = l
    end
  end
  return out
end

H.describe("git's merge result", function()
  H.it("edits outside the blocks and a block resolved by hand are kept", function()
    local dir = conflicted()
    local lines = replace_block(file_lines(dir), 1, { "BY HAND" })
    for i, l in ipairs(lines) do
      if l == "e" then
        lines[i] = "e (edited)"
      end
    end
    H.write(dir, "f.txt", lines)
    local view, buf = open(dir)
    H.eq(H.buf_lines(buf), with({ [2] = "BY HAND", [5] = "e (edited)" }))
    H.eq(view.merge:stats().conflicts, 2)
    H.eq(view.merge:stats().unresolved, 1)
    H.eq(view.merge.regions[1].edited, true)
    H.eq(require("diffmerge.merge").count_unresolved(view.repo, view.current), 1)
  end)

  H.it("rerere resolutions are kept", function()
    local dir = conflicted()
    H.git(dir, { "merge", "--abort" })
    H.git(dir, { "config", "rerere.enabled", "true" })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    -- rerere records a file's resolution once no markers are left
    local resolved = replace_block(file_lines(dir), 1, { "REMEMBERED2" })
    H.write(dir, "f.txt", replace_block(resolved, 1, { "REMEMBERED9" }))
    H.git(dir, { "rerere" })
    H.git(dir, { "merge", "--abort" })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    H.ok(H.read(dir, "f.txt"):find("REMEMBERED2", 1, true), "rerere applied by git")
    H.eq(H.git(dir, { "ls-files", "-u", "--", "f.txt" }) ~= "", true, "still unmerged in the index")
    local view, buf = open(dir)
    H.eq(H.buf_lines(buf), with({ [2] = "REMEMBERED2", [9] = "REMEMBERED9" }))
    H.eq(view.merge:stats().unresolved, 0)
  end)

  H.it("diff3 and zdiff3 markers, no duplicated lines when picking", function()
    for _, style in ipairs({ "diff3", "zdiff3" }) do
      local dir = H.repo({ ["f.txt"] = { "q", "old", "end" } })
      H.git(dir, { "config", "merge.conflictStyle", style })
      H.git(dir, { "checkout", "-q", "-b", "feat" })
      H.commit(dir, "feat", { ["f.txt"] = { "q", "common", "B1", "end" } })
      H.git(dir, { "checkout", "-q", "main" })
      H.commit(dir, "main", { ["f.txt"] = { "q", "common", "A1", "end" } })
      vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
      local view, buf, win = open(dir)
      -- zdiff3 leaves the common line out of the block, diff3 does not
      local start = style == "diff3" and { "q", "old", "end" } or { "q", "common", "old", "end" }
      H.eq(H.buf_lines(buf), start, style .. ": the block is back to BASE")
      api.nvim_win_set_cursor(win, { #start - 1, 0 })
      view.merge:toggle(1, { win = win })
      H.eq(H.buf_lines(buf), { "q", "common", "A1", "end" }, style)
      view:close()
    end
  end)

  H.it("nearby conflicts joined into one block by git", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b", "c", "d", "e" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "a", "F1", "c", "F2", "e" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "a", "M1", "c", "M2", "e" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "a", "b", "c", "d", "e" })
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 1 })
    api.nvim_win_set_cursor(win, { 3, 0 })
    view.merge:toggle(3, { win = win })
    H.eq(H.buf_lines(buf), { "a", "F1", "c", "F2", "e" })
  end)

  H.it("conflicts git splits (merge style): every BASE line in one block only", function()
    local dir = H.repo({ ["f.txt"] = { "a", "old", "z" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "a", "F1", "k1", "k2", "k3", "k4", "F2", "z" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "a", "M1", "k1", "k2", "k3", "k4", "M2", "z" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "a", "old", "k1", "k2", "k3", "k4", "z" })
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    view.merge:toggle(3, { win = win })
    api.nvim_win_set_cursor(win, { 6, 0 })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "a", "F1", "k1", "k2", "k3", "k4", "M2", "z" })
    H.eq(view.merge:stats().unresolved, 0)
  end)

  H.it("a block where DiffMerge would merge on its own is a conflict", function()
    local dir = H.tmpdir()
    H.write(dir, "L.txt", { "a", "LOCAL", "c" })
    H.write(dir, "B.txt", { "a", "b", "c" })
    H.write(dir, "R.txt", { "a", "b", "c" })
    -- markers around a change only one side made (e.g. a custom merge driver)
    H.write(dir, "M.txt", { "a", "<<<<<<< ours", "LOCAL", "=======", "b", ">>>>>>> theirs", "c" })
    local view = require("diffmerge").mergetool(dir .. "/L.txt", dir .. "/B.txt", dir .. "/R.txt", dir .. "/M.txt")
    local buf = api.nvim_win_get_buf(view.layout.wins.merged)
    H.eq(H.buf_lines(buf), { "a", "b", "c" })
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 1 })
    view.merge:toggle(1, { win = view.layout.wins.merged })
    H.eq(H.buf_lines(buf), { "a", "LOCAL", "c" })
  end)

  H.it("a block around a line nobody changed is a conflict of its own", function()
    local dir = H.tmpdir()
    H.write(dir, "L.txt", { "a", "LOCAL", "c", "d", "e" })
    H.write(dir, "B.txt", { "a", "b", "c", "d", "e" })
    H.write(dir, "R.txt", { "a", "b", "c", "d", "e" })
    H.write(dir, "M.txt", { "a", "LOCAL", "c", "d", "<<<<<<< ours", "e", "=======", "e", ">>>>>>> theirs" })
    local view = require("diffmerge").mergetool(dir .. "/L.txt", dir .. "/B.txt", dir .. "/R.txt", dir .. "/M.txt")
    H.eq(H.buf_lines(api.nvim_win_get_buf(view.layout.wins.merged)), { "a", "LOCAL", "c", "d", "e" })
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 2 })
    H.eq({ view.merge:range(view.merge.regions[2]) }, { 4, 5 })
  end)

  H.it("conflict-marker-size from .gitattributes; shorter marker lines are text", function()
    local dir = H.repo({ ["f.txt"] = { "Title", "-----", "a" }, [".gitattributes"] = { "f.txt conflict-marker-size=12" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "T", "-----", "a" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "T2", "=======", "a" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    H.ok(H.read(dir, "f.txt"):find("<<<<<<<<<<<< ", 1, true), "git wrote long markers")
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "Title", "-----", "a" })
    H.eq(view.merge:stats().unresolved, 1)
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "T2", "=======", "a" })
  end)

  H.it("undo stops at the start of the merge, redo stays", function()
    local dir = conflicted()
    local view, buf, win = open(dir)
    key_break()
    view.merge:toggle(1, { win = win })
    key_break()
    H.eq(H.buf_lines(buf), with({ [2] = "MAIN2" }))
    local function undo(cmd)
      api.nvim_buf_call(buf, function()
        vim.cmd("silent " .. cmd)
      end)
      H.flush(50)
    end
    undo("undo")
    H.eq(H.buf_lines(buf), BASE)
    undo("undo")
    H.eq(H.buf_lines(buf), BASE, "not back to the markers")
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    undo("redo")
    H.eq(H.buf_lines(buf), with({ [2] = "MAIN2" }))
    H.eq(view.merge:stats().unresolved, 1)
  end)

  H.it("conflict markers typed or pasted in the view are text", function()
    local dir = conflicted()
    local view, buf = open(dir)
    local controller = view.merge
    local example = { "<<<<<<< example", "mine", "=======", "theirs", ">>>>>>> example" }
    api.nvim_buf_set_lines(buf, 4, 4, false, example)
    H.flush(50)
    H.eq(view.merge, controller, "not attached again")
    H.eq(vim.list_slice(H.buf_lines(buf), 5, 9), example)
    H.eq(view.merge:stats().unresolved, 2)
  end)

  H.it("unsaved edits of the file are the starting point", function()
    local dir = conflicted()
    vim.cmd.edit(dir .. "/f.txt")
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, false, replace_block(H.buf_lines(buf), 1, { "BY HAND" }))
    local view = open(dir)
    H.eq(api.nvim_win_get_buf(view.layout.wins.merged), buf)
    H.eq(H.buf_lines(buf), with({ [2] = "BY HAND" }))
    H.eq(view.merge:stats().unresolved, 1)
    H.eq(require("diffmerge.merge").user_changes(buf), true)
  end)

  H.it("add/add with common lines: the block is git's, empty in BASE", function()
    local dir = H.repo({ ["x.txt"] = { "x" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "F", "common1", "common2" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "M", "common1", "common2" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "common1", "common2" })
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 1 })
    api.nvim_win_set_cursor(win, { 1, 0 })
    view.merge:toggle(3, { win = win })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "F", "M", "common1", "common2" })
  end)

  H.it("without git the blocks still get their BASE text", function()
    local merge = require("diffmerge.merge")
    local git_merge = merge.git_merge
    merge.git_merge = function()
      return nil
    end
    local ok, err = pcall(function()
      local dir = conflicted()
      local view, buf = open(dir)
      H.eq(H.buf_lines(buf), BASE)
      H.eq(view.merge:stats().unresolved, 2)
    end)
    merge.git_merge = git_merge
    assert(ok, err)
  end)
  H.it("a merged buffer that cannot be changed keeps its markers, read once", function()
    local dir = conflicted()
    vim.cmd.edit(dir .. "/f.txt")
    local buf = api.nvim_get_current_buf()
    vim.bo[buf].modifiable = false
    local view = open(dir)
    local controller = view.merge
    H.flush(100)
    H.eq(view.merge, controller, "not attached again")
    H.ok(require("diffmerge.markers").has(H.buf_lines(buf)), "markers kept")
    H.eq(view.merge:stats().unresolved, 2, "blocks with markers are not resolved")
    vim.bo[buf].modifiable = true
  end)
  H.it("conflicts apart by lines without letters stay apart: re-attached, saved, opened again", function()
    local dir = merged(
      { "a", "x", "}", "}", "}", "}", "y", "z" },
      { "a", "X2", "}", "}", "}", "}", "Y2", "z" },
      { "a", "X1", "}", "}", "}", "}", "Y1", "z" }
    )
    local merge = require("diffmerge.merge")
    local view, buf, win = open(dir)
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    view:dispatch("cycle_layout", { win = win, buf = buf })
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 1, chunks = 2 })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(merge.count_unresolved(view.repo, view.current), 1)
    view:close()
    vim.cmd("silent! bwipe! " .. buf)
    local view2, buf2 = open(dir)
    H.eq(H.buf_lines(buf2), { "a", "X1", "}", "}", "}", "}", "y", "z" })
    H.eq(view2.merge:stats(), { conflicts = 2, unresolved = 1, chunks = 2 })
    H.eq(merge.count_unresolved(view2.repo, view2.current), 1)
  end)

  H.it("a file in another style than merge.conflictStyle (git checkout --conflict)", function()
    -- git's merge style joins the two conflicts, diff3 does not
    local dir = merged(
      { "a", "b", "c", "d", "e", "f", "g" },
      { "a", "B2", "c", "d", "E2", "f", "g" },
      { "a", "B1", "c", "d", "E1", "f", "g" }
    )
    H.git(dir, { "checkout", "--conflict=diff3", "--", "f.txt" })
    local merge = require("diffmerge.merge")
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "a", "b", "c", "d", "e", "f", "g" })
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    H.eq(merge.count_unresolved(view.repo, view.current), 2)
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    view:dispatch("cycle_layout", { win = win, buf = buf })
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 1, chunks = 2 })
    H.eq(merge.count_unresolved(view.repo, view.current), 1)
    -- saved and read again: still the same conflicts
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
      vim.cmd("silent edit!")
    end)
    H.flush(50)
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 1, chunks = 2 })
    H.eq(merge.count_unresolved(view.repo, view.current), 1)
  end)

  H.it("a marker line inside a block's text", function()
    local intro = { "Intro", "" }
    local dir = merged(
      vim.list_extend(vim.deepcopy(intro), { "Install", "-------", "", "pip install x" }),
      vim.list_extend(vim.deepcopy(intro), { "Setup", "~~~~~", "", "pip install x" }),
      vim.list_extend(vim.deepcopy(intro), { "Install", "=======", "", "pip install x" })
    )
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "Intro", "", "Install", "-------", "", "pip install x" })
    H.eq(view.merge:stats().unresolved, 1)
    api.nvim_win_set_cursor(win, { 3, 0 })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "Intro", "", "Install", "=======", "", "pip install x" })
  end)

  H.it("a file showing conflict markers as its text, edited by hand", function()
    local example = { "<<<<<<< HEAD", "mine", "=======", "yours", ">>>>>>> branch" }
    local function doc(x)
      return vim.list_extend({ "Title", x, "Example:" }, vim.list_extend(vim.deepcopy(example), { "end" }))
    end
    local dir = merged(doc("x"), doc("THEIRS"), doc("OURS"))
    local lines = file_lines(dir)
    lines[#lines] = "end (edited)"
    H.write(dir, "f.txt", lines)
    local view, buf = open(dir)
    local want = doc("x")
    want[#want] = "end (edited)"
    H.eq(H.buf_lines(buf), want)
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 1 })
  end)

  H.it("BASE text of merge-style blocks: what the sides replace, as git's diff3 shows it", function()
    local cases = {
      -- base, theirs (feat), ours (main), merged with the block at BASE
      { { "c", "x", "c", "a", "x" }, { "B2", "x", "c", "x", "d" }, { "c", "x", "c", "a", "c", "x" }, { "B2", "x", "c", "a", "x", "d" } },
      { { "d", "x" }, { "X9", "x", "d" }, { "d", "x", "END3" }, { "X9", "x" } },
      { { "b", "c", "a", "c", "b" }, { "b", "c", "c", "d", "b" }, { "A8", "c", "b", "a", "x", "c", "b" }, { "A8", "c", "a", "c", "d", "b" } },
    }
    for k, c in ipairs(cases) do
      local view, buf = open(merged(c[1], c[2], c[3]))
      H.eq(H.buf_lines(buf), c[4], "case " .. k)
      H.eq(view.merge:stats().unresolved, 1, "case " .. k)
      view:close()
    end
  end)

  H.it("the sides of every block are git's ours / base / theirs (random merges, every style)", function()
    local merge = require("diffmerge.merge")
    local markers = require("diffmerge.markers")
    local util = require("diffmerge.util")
    -- few distinct lines: repeated lines are where diffs disagree
    local words = { "a", "b", "c", "d", "x" }
    math.randomseed(1)
    local function random_lines(n)
      local t = {}
      for i = 1, n do
        t[i] = words[math.random(#words)]
      end
      return t
    end
    local function mutate(t)
      local out = {}
      for _, l in ipairs(t) do
        local r = math.random()
        if r < 0.15 then
          -- deleted
        elseif r < 0.3 then
          out[#out + 1] = words[math.random(#words)]:upper() .. math.random(9)
        elseif r < 0.4 then
          vim.list_extend(out, { l, words[math.random(#words)] })
        else
          out[#out + 1] = l
        end
      end
      if math.random() < 0.2 then
        out[#out + 1] = "END" .. math.random(3)
      end
      return out
    end
    local dir = H.tmpdir()
    local checked = 0
    -- found by fuzzing: base / local / remote
    local found = {
      { { "a", "c", "a", "a", "c", "a" }, { "a", "X2", "a", "A7", "a", "END1" }, { "a", "c", "C7", "a", "c", "a" } },
      {
        { "b", "b", "x", "d", "b", "c", "b", "x", "d" },
        { "b", "d", "b", "x", "x", "d", "b", "b", "A8", "d" },
        { "b", "d", "b", "x", "b", "c", "b", "x" },
      },
    }
    for n = 1, #found + 150 do
      local lines = {}
      if found[n] then
        lines.base, lines["local"], lines.remote = unpack(found[n])
      else
        lines.base = random_lines(math.random(0, 10))
        lines["local"], lines.remote = mutate(lines.base), mutate(lines.base)
      end
      H.write(dir, "L", lines["local"])
      H.write(dir, "B", lines.base)
      H.write(dir, "R", lines.remote)
      for _, style in ipairs({ "--no-diff3", "--diff3", "--zdiff3" }) do
        local res = vim.system({ "git", "merge-file", "-p", style, "L", "B", "R" }, { cwd = dir, text = true }):wait()
        local current = vim.split(res.stdout, "\n", { plain = true })
        current[#current] = nil
        local parts = vim.tbl_filter(function(p)
          return p.ours ~= nil
        end, markers.parse(current))
        local _, blocks = merge.from_git_markers(current, lines)
        H.eq(#blocks, #parts)
        for k, b in ipairs(blocks) do
          local where = ("%s %s block %d"):format(vim.inspect(lines), style, k)
          local function at(role)
            return util.slice(lines[role], b.side[role][1] + 1, b.side[role][2])
          end
          H.eq({ b.texts["local"], at("local") }, { parts[k].ours, parts[k].ours }, where)
          H.eq({ b.texts.remote, at("remote") }, { parts[k].theirs, parts[k].theirs }, where)
          if parts[k].base then
            H.eq({ b.texts.base, at("base") }, { parts[k].base, parts[k].base }, where)
          end
          checked = checked + 1
        end
      end
    end
    H.ok(checked > 50, "blocks checked: " .. checked)
  end)

  H.it("a block changed by hand before opening keeps its text", function()
    local dir = conflicted()
    local lines = file_lines(dir)
    for i, l in ipairs(lines) do
      if l == "MAIN2" then
        lines[i] = "MAIN2 tweaked"
      end
    end
    H.write(dir, "f.txt", lines)
    local view, buf, win = open(dir)
    local now = H.buf_lines(buf)
    H.eq(vim.list_slice(now, 2, 6), { "<<<<<<< HEAD", "MAIN2 tweaked", "=======", "FEAT2", ">>>>>>> feat" })
    H.eq(view.merge:stats().unresolved, 2)
    api.nvim_win_set_cursor(win, { 3, 0 })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), with({ [2] = "MAIN2" }), "LOCAL as it is in LOCAL")
  end)

  H.it("CRLF files", function()
    local crlf = function(t)
      return vim.tbl_map(function(l)
        return l .. "\r"
      end, t)
    end
    local dir = merged(crlf({ "a", "b", "c" }), crlf({ "a", "F", "c" }), crlf({ "a", "M", "c" }))
    local view, buf, win = open(dir)
    H.eq(vim.bo[buf].fileformat, "dos")
    H.eq(H.buf_lines(buf), { "a", "b", "c" })
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(3, { win = win })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(H.read(dir, "f.txt"), "a\r\nF\r\nc\r\n")
  end)

  H.it("git merge-file: without --diff-algorithm, and a timeout", function()
    local git = require("diffmerge.git")
    local merge = require("diffmerge.merge")
    local run = git.run
    local calls = 0
    local ok, err = pcall(function()
      git.run = function(cwd, args, opts)
        calls = calls + 1
        if vim.tbl_contains(args, "--diff-algorithm=histogram") then
          return { ok = false, code = 129, stdout = "", stderr = "unknown option" }
        end
        return run(cwd, args, opts)
      end
      local parts = merge.git_merge({ ["local"] = { "a", "L" }, base = { "a", "b" }, remote = { "a", "R" } })
      H.eq(calls, 2)
      H.eq(parts, { { text = { "a" } }, { ours = { "L" }, theirs = { "R" } } })
      git.run = function()
        return { ok = false, code = 124, stdout = "x<<<<<<< ours\n", stderr = "", signal = 15 }
      end
      H.eq(merge.git_merge({ ["local"] = { "a" }, base = {}, remote = { "b" } }), nil)
    end)
    git.run = run
    assert(ok, err)
  end)
  H.it("the file read again: :e! of the unconverted file, git checkout -m on disk", function()
    local dir = conflicted()
    local merge = require("diffmerge.merge")
    local view, buf, win = open(dir)
    api.nvim_buf_call(buf, function()
      vim.cmd("silent edit!")
    end)
    H.flush(50)
    H.eq(H.buf_lines(buf), BASE)
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    win = view.layout.wins.merged
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(view.merge:stats().unresolved, 1)
    H.git(dir, { "checkout", "-m", "--", "f.txt" })
    vim.cmd("silent! checktime")
    H.flush(50)
    H.eq(H.buf_lines(buf), BASE)
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 2 })
    H.eq(merge.count_unresolved(view.repo, view.current), 2)
  end)

  H.it("undo to the markers while the merge is not shown, then shown again: redo stays", function()
    local dir = conflicted()
    local view, buf, win = open(dir)
    key_break()
    view.merge:toggle(1, { win = win })
    key_break()
    view:close()
    api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
      vim.cmd("silent undo")
    end)
    H.ok(require("diffmerge.markers").has(H.buf_lines(buf)), "markers in the buffer")
    view = open(dir)
    H.eq(H.buf_lines(buf), BASE)
    api.nvim_buf_call(buf, function()
      vim.cmd("silent redo")
    end)
    H.flush(50)
    H.eq(H.buf_lines(buf), with({ [2] = "MAIN2" }))
    H.eq(view.merge:stats().unresolved, 1)
  end)

  H.it("sides edited by hand to nothing, or to a line next to the block", function()
    for _, to in ipairs({ {}, { "c" } }) do
      local dir = conflicted()
      local lines = {}
      for _, l in ipairs(file_lines(dir)) do
        if l == "MAIN2" then
          vim.list_extend(lines, to)
        else
          lines[#lines + 1] = l
        end
      end
      H.write(dir, "f.txt", lines)
      local view, buf, win = open(dir)
      local block = vim.list_extend(vim.list_extend({ "<<<<<<< HEAD" }, to), { "=======", "FEAT2", ">>>>>>> feat" })
      H.eq(vim.list_slice(H.buf_lines(buf), 2, 1 + #block), block, "kept: " .. vim.inspect(to))
      api.nvim_win_set_cursor(win, { 2, 0 })
      view.merge:toggle(1, { win = win })
      H.eq(H.buf_lines(buf), with({ [2] = "MAIN2" }))
      view:close()
    end
  end)

  H.it("markers committed in the file, a new conflict and an edit next to it", function()
    local base = { "top", "a", "<<<<<<< HEAD", "x", "=======", "y", ">>>>>>> feat", "end" }
    local ours, theirs = vim.deepcopy(base), vim.deepcopy(base)
    ours[2], theirs[2] = "MAIN", "FEAT"
    local dir = merged(base, theirs, ours)
    local lines = file_lines(dir)
    lines[1] = "top (edited)"
    H.write(dir, "f.txt", lines)
    local view, buf, win = open(dir)
    H.eq(view.merge:stats().unresolved, 1)
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "top (edited)", "MAIN", "<<<<<<< HEAD", "x", "=======", "y", ">>>>>>> feat", "end" })
    H.eq(view.merge:stats().unresolved, 0)
  end)

  H.it("a side adding conflict markers as text", function()
    local example = { "<<<<<<< HEAD", "mine", "=======", "yours", ">>>>>>> branch" }
    local ours = vim.list_extend(vim.list_extend({ "Title" }, example), { "end" })
    local dir = merged({ "Title", "x", "end" }, { "Title", "y", "end" }, ours)
    local merge = require("diffmerge.merge")
    local view, buf, win = open(dir)
    H.eq(H.buf_lines(buf), { "Title", "x", "end" })
    H.eq(view.merge:stats().unresolved, 1)
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    H.flush(50)
    H.eq(H.buf_lines(buf), ours)
    H.eq(view.merge:stats().unresolved, 0)
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    view:close()
    H.eq(merge.count_unresolved(view.repo, view.current), 0)
  end)

  H.it("mergetool: a resolved file showing conflict markers as text exits 0", function()
    local dir = H.tmpdir()
    local base = { "Title", "x", "Example:", "<<<<<<< HEAD", "mine", "=======", "yours", ">>>>>>> branch", "end" }
    local L, R = vim.deepcopy(base), vim.deepcopy(base)
    L[2], R[2] = "OURS", "THEIRS"
    H.write(dir, "B.txt", base)
    H.write(dir, "L.txt", L)
    H.write(dir, "R.txt", R)
    local merged_file = vim.deepcopy(base)
    merged_file[2] = "<<<<<<< HEAD"
    table.insert(merged_file, 3, "OURS")
    table.insert(merged_file, 4, "=======")
    table.insert(merged_file, 5, "THEIRS")
    table.insert(merged_file, 6, ">>>>>>> feat")
    H.write(dir, "M.txt", merged_file)
    local view = require("diffmerge").mergetool(dir .. "/L.txt", dir .. "/B.txt", dir .. "/R.txt", dir .. "/M.txt")
    local win = view.layout.wins.merged
    local buf = api.nvim_win_get_buf(win)
    H.eq(H.buf_lines(buf), base)
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(view:exit_code(), 0)
  end)

  H.it("conflicts counted for a merge no longer shown agree with the view", function()
    local B = { "}", "", "local y = 1", "end", "  return x", "}", "end", "a", "a", "", "local y = 1", "}" }
    local L = { "}", "", "local y = 1", "end", "changed 85", "}", "changed 17", "a", "a", "}", "", "local y = 1", "}" }
    local R = { "changed 14", "", "local y = 1", "end", "end", "  return x", "}", "end", "a", "a", "", "local y = 1", "a", "}" }
    local dir = merged(B, R, L, "diff3")
    local merge = require("diffmerge.merge")
    local view, _, win = open(dir)
    for _, r in ipairs(view.merge.regions) do
      if r.kind == "conflict" then
        api.nvim_win_set_cursor(win, { view.merge:range(r) + 1, 0 })
        view.merge:toggle(3, { win = win })
      end
    end
    local unresolved, entry = view.merge:stats().unresolved, view.current
    view:close()
    H.eq(merge.count_unresolved(view.repo, entry), unresolved)
  end)
end)

H.done()
