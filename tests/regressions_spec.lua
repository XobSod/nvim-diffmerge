-- Regression tests for issues found in review.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
-- two-way Staged / Unstaged diffs (status.three_way = false); tests/stage_spec.lua covers the default
require("diffmerge.config").options.status.three_way = false
local api = vim.api

vim.fn.confirm = function()
  return 1
end

local function conflict(base, feat, main, file)
  file = file or "f.txt"
  local dir = H.repo({ [file] = base, ["other.txt"] = { "o" } })
  H.git(dir, { "checkout", "-q", "-b", "feat" })
  H.commit(dir, "feat", { [file] = feat })
  H.git(dir, { "checkout", "-q", "main" })
  H.commit(dir, "main", { [file] = main })
  vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
  vim.cmd.cd(dir)
  local view = require("diffmerge").status({ conflicts = true })
  return dir, view, api.nvim_win_get_buf(view.layout.wins.merged), view.layout.wins.merged
end

local function key_break()
  vim.cmd("let &undolevels = &undolevels")
end

H.describe("merge regions", function()
  H.it("a resolution ending with an insertion survives re-attaching", function()
    local _, view, buf, win = conflict({ "a", "x", "b", "c" }, { "a", "x", "R", "b", "c" }, { "a", "x2", "b", "c" })
    view.merge:toggle(3, { win = win })
    H.eq(H.buf_lines(buf), { "a", "x", "R", "b", "c" })
    view:dispatch("cycle_layout", { win = win, buf = buf })
    H.eq(view.merge:stats().unresolved, 0)
    win = view.layout.wins.merged
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(3, { win = win })
    H.eq(H.buf_lines(buf), { "a", "x", "b", "c" }, "toggled off, no duplicated line")
  end)

  H.it("a line typed next to an unresolved conflict stays outside of it", function()
    local _, view, buf, win = conflict({ "a", "b", "c", "d" }, { "a", "FEAT", "c", "d" }, { "a", "MAIN", "c", "d" })
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! oabove")
    api.nvim_win_set_cursor(win, { 3, 0 })
    vim.cmd("normal! obelow")
    view.merge:sync()
    H.eq(H.buf_lines(buf), { "a", "above", "b", "below", "c", "d" })
    H.eq(view.merge:stats().unresolved, 1)
  end)

  H.it("adjacent regions keep their own resolutions", function()
    -- far enough apart for git to keep two blocks
    local base = { "a", "b", "c1", "c2", "c3", "c4", "d", "e", "f" }
    local function side(x, y)
      return { "a", x, "c1", "c2", "c3", "c4", y, "e", "f" }
    end
    local _, view, buf, win = conflict(base, side("F1", "F2"), side("M1", "M2"))
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { 3, 0 })
    vim.cmd("normal! 4dd")
    view.merge:sync()
    api.nvim_win_set_cursor(win, { 3, 0 })
    view.merge:toggle(3, { win = win })
    api.nvim_win_set_cursor(win, { 2, 0 })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "a", "M1", "F2", "e", "f" })
  end)

  H.it("replacing a region (paste over it) counts as its new content", function()
    local _, view, buf, win = conflict({ "a", "b", "c" }, { "a", "FEAT", "c" }, { "a", "MAIN", "c" })
    api.nvim_buf_set_lines(buf, 1, 2, false, { "pasted", "text" })
    view.merge:sync()
    H.eq({ view.merge:range(view.merge.regions[1]) }, { 1, 3 })
    H.ok(view.merge.regions[1].edited)
    local _ = win
  end)

  H.it("add/add conflict: no phantom empty line", function()
    local dir = H.repo({ ["x.txt"] = { "x" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "FEAT1", "FEAT2" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "MAIN1", "MAIN2" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    vim.cmd.cd(dir)
    local view = require("diffmerge").status({ conflicts = true })
    local win = view.layout.wins.merged
    local buf = api.nvim_win_get_buf(win)
    view.merge:toggle(1, { win = win })
    view.merge:toggle(3, { win = win })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(H.read(dir, "f.txt"), "MAIN1\nMAIN2\nFEAT1\nFEAT2\n")
  end)

  H.it("modify/delete conflicts start unresolved", function()
    local dir = H.repo({ ["f.txt"] = H.lines(6), ["g.txt"] = { "g" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    local feat = H.lines(6)
    feat[3] = "FEAT3"
    H.commit(dir, "feat", { ["f.txt"] = feat })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = false })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    vim.cmd.cd(dir)
    local view = require("diffmerge").status({ conflicts = true })
    H.eq(view.merge:stats().unresolved, 1)
    H.eq(require("diffmerge.merge").count_unresolved(view.repo, view.current), 1)
    view.merge:toggle(3, { win = view.layout.wins.merged })
    H.eq(view.merge:stats().unresolved, 0)
  end)

  H.it("1 then 3 on an insertion conflict and at the end of the file", function()
    local _, view, buf, win = conflict({ "a", "b", "c" }, { "a", "b", "FEAT", "c" }, { "a", "b", "MAIN", "c" })
    view.merge:goto_first()
    view.merge:toggle(1, { win = win })
    key_break()
    view.merge:toggle(3, { win = win })
    H.eq(H.buf_lines(buf), { "a", "b", "MAIN", "FEAT", "c" })
    view:close()
    _, view, buf, win = conflict({ "a", "b" }, { "a", "b", "FEAT" }, { "a", "b", "MAIN" })
    view.merge:goto_first()
    view.merge:toggle(3, { win = win })
    view.merge:toggle(1, { win = win })
    H.eq(H.buf_lines(buf), { "a", "b", "FEAT", "MAIN" })
  end)

  H.it("the cursor line shows in its number only where DiffMerge paints the lines", function()
    local saved = vim.go.cursorlineopt
    local ok, err = pcall(function()
      vim.go.cursorlineopt = "both"
      local dir, view = conflict({ "a", "b", "c" }, { "a", "FEAT", "c" }, { "a", "MAIN", "c" })
      for role, win in pairs(view.layout.wins) do
        H.eq(vim.wo[win].cursorlineopt, "number", role)
      end
      -- what other windows get stays as it was
      H.eq({ vim.go.cursorlineopt, vim.go.winhighlight, vim.go.winbar }, { "both", "", "" })
      H.write(dir, "other.txt", { "changed" })
      view:refresh()
      H.flush(100)
      view:show_entry(H.find_entry(view, "unstaged", "other.txt"))
      for role, win in pairs(view.layout.wins) do
        H.eq(vim.wo[win].cursorlineopt, "both", "plain diff: " .. role)
      end
      view:close()
      vim.cmd.edit(dir .. "/f.txt")
      H.eq(vim.wo.cursorlineopt, "both", "the merged file in another window")
    end)
    vim.go.cursorlineopt = saved
    assert(ok, err)
  end)

  H.it("suspends linematch only while a merge is shown", function()
    local before = vim.o.diffopt
    H.ok(before:find("linematch", 1, true), "default has linematch")
    local _, view = conflict({ "a", "b", "c" }, { "a", "FEAT", "c" }, { "a", "MAIN", "c" })
    H.eq(vim.o.diffopt:find("linematch", 1, true), nil)
    vim.cmd("tabnew")
    H.ok(vim.o.diffopt:find("linematch", 1, true), "restored in other tabs")
    vim.cmd("tabprevious")
    H.eq(vim.o.diffopt:find("linematch", 1, true), nil)
    view:close()
    H.eq(vim.o.diffopt, before)
  end)
end)

H.describe("staging", function()
  local function status(dir)
    vim.cmd.cd(dir)
    return require("diffmerge").status()
  end

  H.it("visual selection next to deleted lines stages the deletion", function()
    local dir = H.repo({ ["a.txt"] = H.lines(10) })
    local wt = H.lines(10)
    table.remove(wt, 6)
    table.remove(wt, 5)
    table.remove(wt, 4)
    H.write(dir, "a.txt", wt)
    local view = status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
    local b = view.layout.wins.b
    view:dispatch("toggle_stage_hunk", { win = b, buf = api.nvim_win_get_buf(b), range = { 4, 5 } })
    H.eq(H.git(dir, { "show", ":a.txt" }), table.concat(wt, "\n") .. "\n")
  end)

  H.it("keeps a missing final newline", function()
    local dir = H.repo({ ["a.txt"] = "l1\nl2\nl3" })
    H.write(dir, "a.txt", "L1\nl2\nl3")
    local view = status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
    local b = view.layout.wins.b
    api.nvim_win_set_cursor(b, { 1, 0 })
    view:dispatch("toggle_stage_hunk", { win = b, buf = api.nvim_win_get_buf(b) })
    H.eq(H.git(dir, { "show", ":a.txt" }), "L1\nl2\nl3")
    H.eq(H.git(dir, { "diff", "--name-only" }), "")
  end)

  H.it("whole-file hunks stage a deletion / unstage an addition", function()
    local dir = H.repo({ ["f.txt"] = { "1", "2" }, ["keep.txt"] = { "k" } })
    os.remove(dir .. "/f.txt")
    H.write(dir, "n.txt", { "new" })
    H.git(dir, { "add", "n.txt" })
    local view = status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "f.txt"))
    local b = view.layout.wins.b
    view:dispatch("toggle_stage_hunk", { win = b, buf = api.nvim_win_get_buf(b) })
    view:show_entry(H.find_entry(view, "staged", "n.txt"))
    b = view.layout.wins.b
    view:dispatch("toggle_stage_hunk", { win = b, buf = api.nvim_win_get_buf(b) })
    H.eq(H.git(dir, { "status", "--short" }), "D  f.txt\n?? n.txt\n")
  end)
end)

H.describe("paths", function()
  H.it("pathspecs are relative to the current directory, like git", function()
    local dir = H.repo({ ["sub/a.txt"] = { "a" }, ["a.txt"] = { "root" } })
    H.write(dir, "sub/a.txt", { "A" })
    H.write(dir, "a.txt", { "ROOT" })
    vim.cmd.cd(dir .. "/sub")
    local view = require("diffmerge").diff({ "--", "a.txt" })
    H.eq(H.entries(view), { "files:M:sub/a.txt" })
  end)
end)

H.done()
