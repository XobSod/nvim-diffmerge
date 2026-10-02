-- Discarding changes (X), opening on the current file, taking a side for a whole conflict.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

local function open(dir)
  vim.cmd.cd(dir)
  return require("diffmerge").status()
end

local function show(view, section, path)
  local e = H.find_entry(view, section, path)
  assert(e, ("no %s entry for %s"):format(section, path))
  view:show_entry(e, { focus = true })
end

local function press(view, role, line, action, range)
  local win = view.layout.wins[role]
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { line, 0 })
  view:dispatch(action, { win = win, buf = api.nvim_win_get_buf(win), range = range })
end

local function index_of(dir, path)
  return H.git(dir, { "show", ":" .. path })
end

--- Messages shown while running fn.
local function messages(fn)
  local got = {}
  local notify = vim.notify
  vim.notify = function(msg)
    got[#got + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return table.concat(got, "\n")
end

local questions = {}
vim.fn.confirm = function(q)
  questions[#questions + 1] = q
  return 1
end

H.describe("X discards changes", function()
  H.it("the unstaged hunk under the cursor, saved without autocommands", function()
    local base = H.lines(20)
    local dir = H.repo({ ["a.txt"] = base })
    local wt = vim.deepcopy(base)
    wt[2], wt[18] = "FIRST", "SECOND"
    H.write(dir, "a.txt", wt)
    local formatted = false
    api.nvim_create_autocmd("BufWritePre", {
      group = api.nvim_create_augroup("FormatOnSave", { clear = true }),
      callback = function()
        formatted = true
      end,
    })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local buf = api.nvim_win_get_buf(view.layout.wins.worktree)
    press(view, "worktree", 18, "discard_change")
    local expected = vim.deepcopy(base)
    expected[2] = "FIRST"
    H.eq(H.read(dir, "a.txt"), table.concat(expected, "\n") .. "\n")
    H.eq(vim.bo[buf].modified, false)
    H.eq(formatted, false, "no format-on-save")
    api.nvim_del_augroup_by_name("FormatOnSave")
    H.eq(index_of(dir, "a.txt"), table.concat(base, "\n") .. "\n", "index untouched")
    -- undo brings it back
    api.nvim_buf_call(buf, function()
      vim.cmd("silent undo")
    end)
    H.eq(H.buf_lines(buf)[18], "SECOND")
  end)

  H.it("selected lines only (visual)", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "z" } })
    H.write(dir, "a.txt", { "a", "B", "C", "z" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 3, "discard_change", { 3, 3 })
    H.eq(H.read(dir, "a.txt"), "a\nB\nc\nz\n")
  end)

  H.it("refuses staged changes and keeps unsaved edits unsaved", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "d", "e" } })
    H.write(dir, "a.txt", { "A", "b", "c", "d", "e" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "b", "c", "d", "E" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    local msg = messages(function()
      press(view, "worktree", 1, "discard_change")
    end)
    H.ok(msg:find("staged: unstage it first", 1, true), msg)
    H.eq(H.read(dir, "a.txt"), "A\nb\nc\nd\nE\n", "a staged change stays")
    local buf = api.nvim_win_get_buf(view.layout.wins.worktree)
    api.nvim_buf_set_lines(buf, 2, 3, false, { "edited" })
    press(view, "worktree", 5, "discard_change")
    H.eq(H.buf_lines(buf), { "A", "b", "edited", "d", "e" })
    H.eq(vim.bo[buf].modified, true, "not saved: it had other edits")
    H.eq(H.read(dir, "a.txt"), "A\nb\nc\nd\nE\n")
  end)

  H.it("from the INDEX column, and in the two-way Unstaged view", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "A", "b", "c" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "b", "C" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "index", 3, "discard_change")
    H.eq(H.read(dir, "a.txt"), "A\nb\nc\n")
    view:close()
    local config = require("diffmerge.config")
    config.options.status.three_way = false
    local ok, err = pcall(function()
      dir = H.repo({ ["b.txt"] = { "1", "2" } })
      H.write(dir, "b.txt", { "1", "TWO" })
      view = open(dir)
      show(view, "unstaged", "b.txt")
      press(view, "b", 2, "discard_change")
      H.eq(H.read(dir, "b.txt"), "1\n2\n")
    end)
    config.options.status.three_way = true
    assert(ok, err)
  end)

  H.it("keeps the INDEX version's final newline (or its absence)", function()
    local dir = H.repo({ ["a.txt"] = "a\nb\nc" })
    H.write(dir, "a.txt", "A\nb\nc\n")
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 1, "discard_change")
    H.eq(H.read(dir, "a.txt"), "a\nb\nc")
    view:close()
    dir = H.repo({ ["b.txt"] = "a\nb\n" })
    H.write(dir, "b.txt", "a\nB")
    view = open(dir)
    show(view, "unstaged", "b.txt")
    press(view, "worktree", 2, "discard_change")
    H.eq(H.read(dir, "b.txt"), "a\nb\n")
    H.eq(H.git(dir, { "status", "--short" }), "")
  end)

  H.it("into an emptied file", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b" } })
    H.write(dir, "a.txt", "")
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 1, "discard_change")
    H.eq(H.read(dir, "a.txt"), "a\nb\n")
    H.eq(H.git(dir, { "status", "--short" }), "")
  end)

  H.it("from the HEAD column, with the right message in the WORKING TREE column", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "a", "B", "c" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "new", "a", "B", "C" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    -- worktree line 3 ("B") is staged; line 2 ("a") is no change at all
    local msg = messages(function()
      press(view, "worktree", 3, "discard_change")
    end)
    H.ok(msg:find("staged", 1, true), msg)
    msg = messages(function()
      press(view, "worktree", 2, "discard_change")
    end)
    H.ok(msg:find("no unstaged change", 1, true), msg)
    -- HEAD line 3 ("c") is changed in the working tree only: discard from HEAD
    press(view, "head", 3, "discard_change")
    H.eq(H.read(dir, "a.txt"), "new\na\nB\nc\n")
  end)

  H.it("refuses new files, the Staged view and binary files", function()
    local config = require("diffmerge.config")
    local dir = H.repo({ ["a.txt"] = { "a" } })
    H.write(dir, "u.txt", { "untracked" })
    H.write(dir, "n.txt", { "intent" })
    H.git(dir, { "add", "-N", "n.txt" })
    local view = open(dir)
    for _, name in ipairs({ "u.txt", "n.txt" }) do
      show(view, name == "u.txt" and "untracked" or "unstaged", name)
      local win = view.layout.wins.b or view.layout.wins.worktree
      local msg = messages(function()
        view:dispatch("discard_change", { win = win, buf = api.nvim_win_get_buf(win) })
      end)
      H.ok(msg:find("new file", 1, true), name .. ": " .. msg)
    end
    H.eq(H.read(dir, "u.txt"), "untracked\n")
    H.eq(H.read(dir, "n.txt"), "intent\n")
    view:close()
    config.options.status.three_way = false
    local ok, err = pcall(function()
      dir = H.repo({ ["a.txt"] = { "a" }, ["bin"] = "x\0y" })
      H.write(dir, "a.txt", { "A" })
      H.git(dir, { "add", "a.txt" })
      H.write(dir, "bin", "x\0z")
      view = open(dir)
      show(view, "staged", "a.txt")
      local msg = messages(function()
        press(view, "b", 1, "discard_change")
      end)
      H.ok(msg:find("unstage first", 1, true), msg)
      show(view, "unstaged", "bin")
      msg = messages(function()
        view:dispatch("discard_change", { win = view.layout.wins.b, buf = api.nvim_win_get_buf(view.layout.wins.b) })
      end)
      H.ok(msg:find("as a whole", 1, true), msg)
    end)
    config.options.status.three_way = true
    assert(ok, err)
  end)

  H.it("picks up changes made on disk before discarding", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "d" } })
    H.write(dir, "a.txt", { "A", "b", "c", "d" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    -- changed outside Neovim (lazygit, a terminal): one more change at the end
    vim.uv.sleep(1100)
    H.write(dir, "a.txt", { "A", "b", "c", "D" })
    press(view, "worktree", 1, "discard_change")
    H.eq(H.read(dir, "a.txt"), "a\nb\nc\nD\n")
  end)

  H.it("keeps the cursor's place when the working tree column goes away", function()
    local base = H.lines(5)
    local dir = H.repo({ ["a.txt"] = base })
    local idx = vim.deepcopy(base)
    idx[1] = "LINE1"
    H.write(dir, "a.txt", idx)
    H.git(dir, { "add", "a.txt" })
    local wt = vim.deepcopy(idx)
    for k = 8, 1, -1 do
      table.insert(wt, 3, "added" .. k)
    end
    H.write(dir, "a.txt", wt)
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 9, "discard_change")
    H.eq(view.layout.roles, { "head", "index" })
    H.eq(api.nvim_get_current_win(), view.layout.wins.index)
    H.eq(api.nvim_win_get_cursor(0)[1], 3)
  end)

  H.it("brings back a file deleted in the working tree", function()
    local dir = H.repo({ ["a.txt"] = { "a" }, ["k.txt"] = { "k" } })
    os.remove(dir .. "/a.txt")
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 1, "discard_change")
    H.eq(H.read(dir, "a.txt"), "a\n")
  end)
end)

H.describe("opening the status view", function()
  H.it("shows the current file at the cursor's line", function()
    local base = H.lines(40)
    local dir = H.repo({ ["a.txt"] = { "a" }, ["b.txt"] = base })
    H.write(dir, "a.txt", { "A" })
    local wt = vim.deepcopy(base)
    wt[30] = "changed"
    H.write(dir, "b.txt", wt)
    vim.cmd.cd(dir)
    vim.cmd("edit b.txt")
    api.nvim_win_set_cursor(0, { 31, 0 })
    local view = require("diffmerge").status()
    H.eq(view.current.path, "b.txt")
    H.eq(api.nvim_get_current_win(), view.layout.wins.worktree)
    H.eq(api.nvim_win_get_cursor(0)[1], 31)
    -- from another file, into the open view
    vim.cmd("tabfirst")
    vim.cmd("edit a.txt")
    local again = require("diffmerge").status()
    H.eq(again, view)
    H.eq(view.current.path, "a.txt")
  end)

  H.it("a conflicted file: the cursor stays on its text", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b", "c", "d", "e", "f" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "a", "FEAT", "c", "d", "e", "f" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "a", "MAIN", "c", "d", "e", "f" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    vim.cmd.cd(dir)
    vim.cmd("edit f.txt")
    -- "d" is line 8 below the conflict markers
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    local at
    for i, l in ipairs(lines) do
      if l == "d" then
        at = i
      end
    end
    api.nvim_win_set_cursor(0, { at, 0 })
    local view = require("diffmerge").status({ conflicts = true })
    H.eq(view.current.path, "f.txt")
    H.eq(api.nvim_get_current_line(), "d")
  end)

  H.it(":DiffMerge conflicts from another file goes to the first conflict", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b" }, ["g.txt"] = { "g" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "a", "FEAT" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "a", "MAIN" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    H.write(dir, "g.txt", { "G" })
    vim.cmd.cd(dir)
    vim.cmd("edit g.txt")
    local view = require("diffmerge").status({ conflicts = true })
    H.eq(view.current.path, "f.txt")
  end)

  H.it("a file without changes opens the view as usual", function()
    local dir = H.repo({ ["a.txt"] = { "a" }, ["b.txt"] = { "b" } })
    H.write(dir, "a.txt", { "A" })
    vim.cmd.cd(dir)
    vim.cmd("edit b.txt")
    local view = require("diffmerge").status()
    H.eq(view.current.path, "a.txt")
    H.eq(api.nvim_get_current_win(), view.layout.files_win)
  end)
end)

H.describe("taking a side for a whole conflicted file", function()
  local function conflict(files_feat, files_main)
    local dir = H.repo({ ["f.txt"] = { "base" }, ["g.txt"] = { "g" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", files_feat)
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", files_main)
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    return dir
  end

  local function panel(view, path, action)
    api.nvim_set_current_win(view.layout.files_win)
    api.nvim_win_set_cursor(0, { view.files:line_of(H.find_entry(view, "conflicts", path)), 0 })
    view:dispatch(action, { buf = view.files.buf, win = view.layout.files_win })
  end

  H.it("ours / theirs, marked resolved", function()
    local dir = conflict({ ["f.txt"] = { "theirs" } }, { ["f.txt"] = { "ours" } })
    local view = open(dir)
    questions = {}
    panel(view, "f.txt", "take_remote_file")
    H.eq(#questions, 1)
    H.eq(questions[1]:find("Unsaved", 1, true), nil, "DiffMerge's own start is not the user's change")
    H.eq(H.read(dir, "f.txt"), "theirs\n")
    H.eq(H.git(dir, { "status", "--short" }), "M  f.txt\n")
    H.eq(H.buf_lines(require("diffmerge.util").find_buf(dir .. "/f.txt")), { "theirs" }, "file buffer reloaded")
    view:close()
    dir = conflict({ ["f.txt"] = { "theirs" } }, { ["f.txt"] = { "ours" } })
    view = open(dir)
    panel(view, "f.txt", "take_local_file")
    H.eq(H.read(dir, "f.txt"), "ours\n")
    H.eq(H.git(dir, { "status", "--short" }), "")
  end)

  H.it("binary files and a side that deleted the file", function()
    local dir = conflict({ ["f.txt"] = "bin\0theirs" }, { ["f.txt"] = "bin\0ours" })
    local view = open(dir)
    panel(view, "f.txt", "take_remote_file")
    H.eq(H.read(dir, "f.txt"), "bin\0theirs")
    view:close()
    dir = conflict({ ["f.txt"] = { "changed" } }, { ["f.txt"] = false })
    view = open(dir)
    local buf = api.nvim_win_get_buf(view.layout.wins.merged)
    api.nvim_buf_set_lines(buf, 0, 0, false, { "user edit" })
    questions = {}
    panel(view, "f.txt", "take_local_file")
    H.ok(questions[1]:find("Unsaved", 1, true), "the user's edit is announced")
    H.eq(H.read(dir, "f.txt"), nil)
    H.eq(H.git(dir, { "status", "--short" }), "", "deleted, as on our side")
    H.eq(api.nvim_buf_is_valid(buf), false, "no buffer of the deleted file left")
  end)
end)

H.describe("merge windows", function()
  H.it("have no dp mapping", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b", "c" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["f.txt"] = { "a", "FEAT", "c" } })
    H.git(dir, { "checkout", "-q", "main" })
    H.commit(dir, "main", { ["f.txt"] = { "a", "MAIN", "c" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    vim.cmd.cd(dir)
    local view = require("diffmerge").status({ conflicts = true })
    H.eq(view.layout.kind, "merge")
    for _, win in pairs(view.layout.wins) do
      api.nvim_win_call(win, function()
        local m = vim.fn.maparg("dp", "n", false, true)
        H.ok(type(m) ~= "table" or m.buffer ~= 1, "no buffer-local dp")
      end)
    end
  end)
end)

H.done()
