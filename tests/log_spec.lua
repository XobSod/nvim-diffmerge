local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

local confirm_answer = 1
local confirmed = 0
vim.fn.confirm = function()
  confirmed = confirmed + 1
  return confirm_answer
end

local function wait_loaded(view)
  vim.wait(3000, function()
    return not view.log.loading and view.current ~= nil
  end, 10)
  H.ok(not view.log.loading, "log loaded")
end

local function line_of(view, sha)
  return view.log.by_sha[sha]
end

local function files(view)
  local out = {}
  for _, e in ipairs(view.files:all_entries()) do
    out[#out + 1] = e.status .. ":" .. e.path
  end
  return out
end

--- Linear history: l1 .. l4.
local function linear()
  local dir = H.repo({ ["a.txt"] = { "a1" }, ["b.txt"] = { "b1" } })
  local c = { vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }
  c[2] = H.commit(dir, "second", { ["a.txt"] = { "a2" } })
  c[3] = H.commit(dir, "third", { ["b.txt"] = { "b3" } })
  c[4] = H.commit(dir, "fourth", { ["a.txt"] = { "a4" }, ["c.txt"] = { "c4" } })
  return dir, c
end

--- main: m1 - m2 - m3 ; feat (from m2): f1
local function branched()
  local dir = H.repo({ ["a.txt"] = { "a" }, ["b.txt"] = { "b" } })
  local m1 = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
  local m2 = H.commit(dir, "m2", { ["a.txt"] = { "a2" } })
  H.git(dir, { "checkout", "-q", "-b", "feat" })
  local f1 = H.commit(dir, "f1", { ["b.txt"] = { "b-feat" } })
  H.git(dir, { "checkout", "-q", "main" })
  local m3 = H.commit(dir, "m3", { ["a.txt"] = { "a3" } })
  return dir, { m1 = m1, m2 = m2, m3 = m3, f1 = f1 }
end

local function open_log(dir, opts)
  vim.cmd.cd(dir)
  local view = require("diffmerge").log(opts)
  wait_loaded(view)
  return view
end

local function set_cursor(view, line)
  api.nvim_set_current_win(view.layout.log_win)
  api.nvim_win_set_cursor(view.layout.log_win, { line, 0 })
end

local function ctx(view, range)
  return { buf = view.log.buf, win = view.layout.log_win, range = range }
end

H.describe("log view", function()
  H.it("streams the graph with pseudo rows and previews HEAD", function()
    local dir, c = linear()
    local view = open_log(dir)
    H.eq(view.log.rows[1].kind, "worktree")
    H.eq(view.log.rows[2].kind, "index")
    H.eq(view.log.rows[3].sha, c[4])
    H.eq(#view.log.rows, 6)
    H.eq(files(view), { "M:a.txt", "A:c.txt" })
    H.eq(view.cmp.title, "git show " .. c[4]:sub(1, 7))
    local text = api.nvim_buf_get_lines(view.log.buf, 2, 3, false)[1]
    H.ok(text:find("fourth", 1, true) and text:find("by Tester", 1, true), "mytreeview-like format: " .. text)
    H.ok(not text:find("\27", 1, true), "ANSI codes stripped")
  end)

  H.it("marks two commits: git diff A B, older on the left whatever the order", function()
    local dir, c = linear()
    local view = open_log(dir)
    set_cursor(view, line_of(view, c[3]))
    view:dispatch("mark", ctx(view))
    set_cursor(view, line_of(view, c[1]))
    view:dispatch("mark", ctx(view))
    H.eq(view.cmp.left.oid, c[1])
    H.eq(view.cmp.right.oid, c[3])
    H.eq(files(view), { "M:a.txt", "M:b.txt" })
    H.ok(view.cmp.title:match("^git diff %x+ %x+$"), view.cmp.title)
    -- marks stick while the cursor moves
    set_cursor(view, line_of(view, c[4]))
    H.eq(view.cmp.right.oid, c[3])
    view:dispatch("clear_marks", ctx(view))
    H.eq(view.cmp.right.oid, c[4])
  end)

  H.it("diverged marks: snapshots, t toggles A...B (merge base)", function()
    local dir, c = branched()
    local view = open_log(dir)
    set_cursor(view, line_of(view, c.f1))
    view:dispatch("mark", ctx(view))
    set_cursor(view, line_of(view, c.m3))
    view:dispatch("mark", ctx(view))
    local left_first = view.cmp.left.oid
    H.ok(left_first == c.f1 or left_first == c.m3, "one of the marked commits")
    H.eq(#files(view), 2, "both files differ between the snapshots")
    view:dispatch("toggle_range_mode", ctx(view))
    H.eq(view.cmp.left.oid, c.m2, "merge base")
    H.ok(view.cmp.title:find("...", 1, true), view.cmp.title)
  end)

  H.it("visual selection: combined changes of adjacent commits (git diff O^ N)", function()
    local dir, c = linear()
    local view = open_log(dir)
    local l2, l3 = line_of(view, c[2]), line_of(view, c[3])
    confirmed = 0
    view:dispatch("select", ctx(view, { math.min(l2, l3), math.max(l2, l3) }))
    H.eq(confirmed, 0, "a straight line of history needs no confirmation")
    H.eq(view.cmp.left.oid, c[1])
    H.eq(view.cmp.right.oid, c[3])
    H.eq(files(view), { "M:a.txt", "M:b.txt" })
    H.ok(view.cmp.described:find("combined changes of 2 commits", 1, true), view.cmp.described)
  end)

  H.it("visual selection across branches asks first", function()
    local dir, c = branched()
    local view = open_log(dir)
    local lines = { line_of(view, c.m3), line_of(view, c.f1) }
    table.sort(lines)
    confirmed = 0
    confirm_answer = 2
    view:dispatch("select", ctx(view, { lines[1], lines[2] }))
    H.eq(confirmed, 1)
    confirm_answer = 1
  end)

  H.it("pseudo rows compare the working tree and the index", function()
    local dir, c = linear()
    H.write(dir, "a.txt", { "dirty" })
    H.write(dir, "b.txt", { "staged" })
    H.git(dir, { "add", "b.txt" })
    local view = open_log(dir)
    set_cursor(view, 1)
    view:select_line(1)
    H.eq(view.cmp.title, "git diff")
    H.eq(files(view), { "M:a.txt" })
    view:select_line(2)
    H.eq(view.cmp.title, "git diff --staged")
    H.eq(files(view), { "M:b.txt" })
    -- commit vs working tree through marks
    set_cursor(view, line_of(view, c[3]))
    view:dispatch("mark", ctx(view))
    set_cursor(view, 1)
    view:dispatch("mark", ctx(view))
    H.eq(view.cmp.right.kind, "worktree")
    H.eq(view.cmp.left.oid, c[3])
    H.eq(files(view), { "M:a.txt", "M:b.txt", "A:c.txt" }, "git diff <commit> (staged + unstaged)")
  end)

  H.it("file history follows renames", function()
    local dir = H.repo({ ["old.txt"] = { "1", "2", "3" } })
    local first = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
    H.commit(dir, "edit", { ["old.txt"] = { "1", "2", "3", "4" } })
    H.git(dir, { "mv", "old.txt", "new.txt" })
    H.git(dir, { "commit", "-q", "-m", "rename" })
    H.commit(dir, "unrelated", { ["other.txt"] = { "x" } })
    H.commit(dir, "edit new", { ["new.txt"] = { "1", "2", "3", "4", "5" } })
    vim.cmd.cd(dir)
    local view = require("diffmerge").history(dir .. "/new.txt")
    wait_loaded(view)
    local shas = {}
    for _, r in ipairs(view.log.rows) do
      if r.sha then
        shas[#shas + 1] = r.sha
      end
    end
    H.eq(#shas, 4, "edit new, rename, edit, initial (not the unrelated commit)")
    H.eq(files(view), { "M:new.txt" })
    view:select_line(line_of(view, shas[2]))
    H.eq(files(view), { "R:new.txt" })
    view:select_line(line_of(view, first))
    H.eq(files(view), { "A:old.txt" })
  end)

  H.it("line history (git log -L)", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b", "c", "d" } })
    local touch = H.commit(dir, "touch line 4", { ["f.txt"] = { "a", "b", "c", "D" } })
    H.commit(dir, "touch line 1", { ["f.txt"] = { "A", "b", "c", "D" } })
    vim.cmd.cd(dir)
    local view = require("diffmerge").history(dir .. "/f.txt", { range = { 3, 4 } })
    wait_loaded(view)
    local shas = {}
    for _, r in ipairs(view.log.rows) do
      if r.sha then
        shas[#shas + 1] = r.sha
      end
    end
    H.eq(#shas, 2, "initial + line 4 change")
    H.eq(shas[1], touch)
  end)

  H.it("toggles --first-parent and filters", function()
    local dir, c = branched()
    H.git(dir, { "merge", "-q", "--no-edit", "feat" })
    local view = open_log(dir)
    -- with --branches the feat branch itself would still show f1
    view:dispatch("toggle_all_branches", ctx(view))
    wait_loaded(view)
    local n_all = 0
    for _, r in ipairs(view.log.rows) do
      if r.sha then
        n_all = n_all + 1
      end
    end
    view:dispatch("toggle_first_parent", ctx(view))
    wait_loaded(view)
    local n_fp = 0
    for _, r in ipairs(view.log.rows) do
      if r.sha then
        n_fp = n_fp + 1
      end
    end
    H.eq(n_all - n_fp, 1, "feat commit hidden")
    view.filter = { "--grep=m2" }
    view:reload()
    wait_loaded(view)
    local found = {}
    for _, r in ipairs(view.log.rows) do
      if r.sha then
        found[#found + 1] = r.sha
      end
    end
    H.eq(found, { c.m2 })
  end)
end)

H.done()
