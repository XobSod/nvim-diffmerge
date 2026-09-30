-- HEAD | WORKING TREE | INDEX: regression tests for issues found in review.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

vim.fn.confirm = function()
  return 1
end

local function open(dir)
  vim.cmd.cd(dir)
  return require("diffmerge").status()
end

local function show(view, section, path)
  local e = H.find_entry(view, section, path)
  assert(e, ("no %s entry for %s"):format(section, path))
  view:show_entry(e, { focus = true })
end

local function press(view, role, line, action)
  local win = view.layout.wins[role]
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { line, 0 })
  view:dispatch(action or "toggle_stage_line", { win = win, buf = api.nvim_win_get_buf(win) })
end

local function index_of(dir, path)
  return H.git(dir, { "show", ":" .. path })
end

local function status(dir, path)
  return H.git(dir, { "status", "--short", "--", path })
end

H.describe("stage view review fixes", function()
  H.it("empty files: no phantom line in the index", function()
    local dir = H.repo({ ["a.txt"] = { "x" }, ["e.txt"] = "", ["h.txt"] = "" })
    H.write(dir, "a.txt", "")
    H.write(dir, "e.txt", { "y" })
    H.write(dir, "h.txt", { "x", "y" })
    H.git(dir, { "add", "h.txt" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 1, "toggle_stage_hunk")
    H.eq(index_of(dir, "a.txt"), "")
    H.eq(status(dir, "a.txt"), "M  a.txt\n")
    show(view, "unstaged", "e.txt")
    press(view, "worktree", 1)
    H.eq(index_of(dir, "e.txt"), "y\n")
    -- HEAD is empty, unstage one of two lines
    show(view, "staged", "h.txt")
    press(view, "index", 2)
    H.eq(index_of(dir, "h.txt"), "x\n")
  end)

  H.it("symlinks are shown as links and staged only as a whole", function()
    local dir = H.repo({ ["a.txt"] = { "alpha" }, ["b.txt"] = { "beta1", "beta2" } })
    vim.uv.fs_symlink("a.txt", dir .. "/link")
    H.git(dir, { "add", "link" })
    H.git(dir, { "commit", "-q", "-m", "link" })
    os.remove(dir .. "/link")
    vim.uv.fs_symlink("b.txt", dir .. "/link")
    local view = open(dir)
    show(view, "unstaged", "link")
    H.eq(H.buf_lines(api.nvim_win_get_buf(view.layout.wins.worktree)), { "Symbolic link → b.txt" })
    press(view, "worktree", 1, "toggle_stage_hunk")
    H.eq(index_of(dir, "link"), "a.txt")
  end)

  H.it("staged hunks follow the screen's HEAD -> INDEX diff", function()
    local dir = H.repo({ ["a.txt"] = { "x", "x", "a" } })
    H.write(dir, "a.txt", { "}", "a", "x" })
    H.git(dir, { "add", "a.txt" })
    local view = open(dir)
    show(view, "staged", "a.txt")
    local win = view.layout.wins.index
    local changed = api.nvim_win_call(win, function()
      return vim.fn.diff_hlID(3, 1) ~= 0
    end)
    H.ok(changed, "line 3 is a change on screen")
    local before = index_of(dir, "a.txt")
    press(view, "index", 3)
    H.ok(index_of(dir, "a.txt") ~= before, "<Space> acted on it")
  end)

  H.it("the overlay uses the screen's diff algorithm", function()
    local base = { "b", "x", "x", "x", "m1", "m2", "m3", "m4", "m5", "z" }
    local dir = H.repo({ ["a.txt"] = base })
    local idx = vim.deepcopy(base)
    idx[10] = "Z"
    H.write(dir, "a.txt", idx)
    H.git(dir, { "add", "a.txt" })
    local wt = vim.deepcopy(idx)
    wt[1], wt[2] = "x", "b"
    H.write(dir, "a.txt", wt)
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local win = view.layout.wins.worktree
    for l = 1, #wt do
      local native = api.nvim_win_call(win, function()
        return vim.fn.diff_hlID(l, 1) ~= 0
      end)
      local class = view.stagectl:class_at("worktree", l)
      H.eq(class ~= nil, native, "line " .. l)
    end
  end)

  H.it("HEAD column is classified line by line; walking never undoes", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "A", "b", "c" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "B", "C" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.eq(view.stagectl:class_at("head", 1), "staged")
    H.eq(view.stagectl:class_at("head", 2), "unstaged")
    H.eq(view.stagectl:class_at("head", 3), "unstaged")
    press(view, "head", 2)
    H.eq(index_of(dir, "a.txt"), "A\nB\nc\n")
    H.eq(api.nvim_win_get_cursor(0)[1], 3)
    view:dispatch("toggle_stage_line", { win = api.nvim_get_current_win(), buf = api.nvim_get_current_buf() })
    H.eq(index_of(dir, "a.txt"), "A\nB\nC\n")
  end)

  H.it("unstaging all of a new file with unstaged edits (AM)", function()
    local dir = H.repo({ ["x.txt"] = { "x" } })
    H.write(dir, "n.txt", { "one" })
    H.git(dir, { "add", "n.txt" })
    H.write(dir, "n.txt", { "one", "two" })
    local view = open(dir)
    show(view, "staged", "n.txt")
    press(view, "index", 1, "toggle_stage_hunk")
    H.eq(status(dir, "n.txt"), "?? n.txt\n")
    H.eq(H.read(dir, "n.txt"), "one\ntwo\n", "file kept")
  end)

  H.it("saving or unsaved edits never close the working tree column", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b" } })
    H.write(dir, "a.txt", { "A", "b" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "B" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local wt = view.layout.wins.worktree
    local buf = api.nvim_win_get_buf(wt)
    -- save the working tree identical to the index
    api.nvim_buf_set_lines(buf, 1, 2, false, { "b" })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    view:refresh()
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    H.ok(api.nvim_win_is_valid(wt), "the window being edited stays")
    -- unsaved edits: staging the last difference on disk keeps the working tree visible
    api.nvim_buf_set_lines(buf, 1, 2, false, { "B!" })
    H.write(dir, "a.txt", { "A", "B" })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent edit!")
    end)
    api.nvim_buf_set_lines(buf, 1, 2, false, { "unsaved" })
    press(view, "worktree", 1)
    H.ok(vim.tbl_contains(view.layout.roles, "worktree"), "modified buffer stays visible")
  end)

  H.it("the cursor keeps its line when INDEX goes away", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "a", "b", "C" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "X", "Y", "a", "b", "C" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "index", 3)
    H.eq(view.layout.roles, { "head", "worktree" })
    H.eq(api.nvim_get_current_win(), view.layout.wins.worktree)
    H.eq(api.nvim_get_current_line(), "C")
  end)

  H.it("final newline comes from the line that ends the result", function()
    local dir = H.repo({ ["a.txt"] = "a\nb\n" })
    H.write(dir, "a.txt", "a\nBB b\nC")
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 2)
    H.eq(index_of(dir, "a.txt"), "a\nBB b\n")
    view:close()
    dir = H.repo({ ["a.txt"] = "a\nb\nc" })
    H.write(dir, "a.txt", "a\nB\nc\n")
    view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 2)
    H.eq(index_of(dir, "a.txt"), "a\nB\nc")
  end)

  H.it("after an external commit the stale view refuses to stage", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "A", "b", "c" })
    H.git(dir, { "add", "a.txt" })
    local view = open(dir)
    show(view, "staged", "a.txt")
    api.nvim_set_current_win(view.layout.wins.index)
    H.git(dir, { "commit", "-q", "-m", "elsewhere" })
    view:refresh()
    press(view, "index", 1)
    H.eq(status(dir, "a.txt"), "")
  end)

  H.it("the Staged and Unstaged entry of a file share the view", function()
    local dir = H.repo({ ["a.txt"] = H.lines(30) })
    local wt = H.lines(30)
    wt[5] = "staged"
    H.write(dir, "a.txt", wt)
    H.git(dir, { "add", "a.txt" })
    wt[25] = "unstaged"
    H.write(dir, "a.txt", wt)
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local ctl, win = view.stagectl, view.layout.wins.worktree
    api.nvim_win_set_cursor(win, { 20, 0 })
    view:show_entry(H.find_entry(view, "staged", "a.txt"))
    H.ok(view.stagectl == ctl and view.layout.wins.worktree == win, "not rebuilt")
    H.eq(api.nvim_win_get_cursor(win)[1], 20)
  end)

  H.it("overlay colours stay out of other windows on the same file", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b" } })
    H.write(dir, "a.txt", { "A", "b" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "B" })
    vim.cmd("edit " .. dir .. "/a.txt")
    local user_win = api.nvim_get_current_win()
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.ok(#api.nvim_buf_get_extmarks(api.nvim_win_get_buf(user_win), require("diffmerge.stage").ns, 0, -1, {}) > 0)
    local ns = api.nvim__ns_get(require("diffmerge.stage").ns)
    H.ok(ns.wins and not vim.tbl_contains(ns.wins, user_win), "namespace scoped to the view's windows")
    H.ok(vim.tbl_contains(ns.wins, view.layout.wins.worktree))
  end)

  H.it("a staged pure deletion is marked", function()
    local dir = H.repo({ ["a.txt"] = { "a", "gone", "b" } })
    H.write(dir, "a.txt", { "a", "b" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "a", "b", "new" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local buf = api.nvim_win_get_buf(view.layout.wins.index)
    local signs = api.nvim_buf_get_extmarks(buf, require("diffmerge.stage").ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(signs) do
      if m[4].sign_text and vim.trim(m[4].sign_text) == "S" then
        found = true
      end
    end
    H.ok(found, "S sign in the INDEX column")
  end)

  H.it("a modified submodule does not break the view", function()
    local sub = H.repo({ ["s.txt"] = { "s" } })
    local dir = H.repo({ ["x.txt"] = { "x" } })
    H.git(dir, { "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub" })
    H.git(dir, { "commit", "-q", "-m", "sub" })
    H.commit(dir .. "/sub", "inner", { ["s.txt"] = { "s2" } })
    local view = open(dir)
    show(view, "unstaged", "sub")
    H.ok(H.buf_lines(api.nvim_win_get_buf(view.layout.wins.worktree))[1]:find("^Subproject commit"))
  end)
end)

H.done()
