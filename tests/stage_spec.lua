-- Status view with HEAD | WORKING TREE | INDEX columns (status.three_way, the default).
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
  view:show_entry(H.find_entry(view, section, path), { focus = true })
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

local function buf_of(view, role)
  return api.nvim_win_get_buf(view.layout.wins[role])
end

H.describe("status columns", function()
  H.it("shows only the columns that differ", function()
    local dir = H.repo({ ["u.txt"] = { "u" }, ["s.txt"] = { "s" }, ["b.txt"] = { "1", "2", "3" } })
    H.write(dir, "u.txt", { "U" })
    H.write(dir, "s.txt", { "S" })
    H.git(dir, { "add", "s.txt" })
    H.write(dir, "b.txt", { "ONE", "2", "3" })
    H.git(dir, { "add", "b.txt" })
    H.write(dir, "b.txt", { "ONE", "2", "THREE" })
    local view = open(dir)
    show(view, "unstaged", "u.txt")
    H.eq(view.layout.roles, { "head", "worktree" })
    H.ok(vim.wo[view.layout.wins.head].winbar:find("HEAD", 1, true))
    H.ok(vim.wo[view.layout.wins.worktree].winbar:find("WORKING TREE", 1, true))
    show(view, "staged", "s.txt")
    H.eq(view.layout.roles, { "head", "index" })
    H.ok(vim.wo[view.layout.wins.index].winbar:find("INDEX · to be committed", 1, true))
    show(view, "unstaged", "b.txt")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    H.ok(view.stagectl, "state overlay")
    H.eq(view.stagectl:count("staged"), 1)
    H.eq(view.stagectl:count("unstaged"), 1)
    H.eq(view.stagectl:class_at("worktree", 1), "staged")
    H.eq(view.stagectl:class_at("worktree", 3), "unstaged")
    H.ok(vim.wo[view.layout.wins.worktree].winhighlight:find("DiffChange:DiffMergeNone", 1, true), "native colours muted")
    H.eq(vim.o.diffopt:find("linematch", 1, true), nil)
    -- the Staged entry of the same file shows the same windows
    local win = view.layout.wins.worktree
    view:show_entry(H.find_entry(view, "staged", "b.txt"))
    H.eq(view.layout.wins.worktree, win)
  end)

  H.it("staging a line brings in the INDEX column, the line stays visible", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "d" } })
    H.write(dir, "a.txt", { "A", "b", "C", "d" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.eq(view.layout.roles, { "head", "worktree" })
    press(view, "worktree", 1)
    H.eq(index_of(dir, "a.txt"), "A\nb\nc\nd\n")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    H.eq(H.buf_lines(buf_of(view, "index")), { "A", "b", "c", "d" })
    H.eq(view.stagectl:class_at("worktree", 1), "staged")
    H.eq(view.stagectl:class_at("index", 1), "staged")
    H.eq(api.nvim_get_current_win(), view.layout.wins.worktree)
    H.eq(api.nvim_win_get_cursor(0)[1], 3, "on to the next unstaged line")
    press(view, "worktree", 3)
    H.eq(index_of(dir, "a.txt"), "A\nb\nC\nd\n")
    -- everything staged: the working tree column is redundant, INDEX takes over
    H.eq(view.layout.roles, { "head", "index" })
    H.eq(api.nvim_get_current_win(), view.layout.wins.index)
    H.eq(api.nvim_win_get_cursor(0)[1], 3, "same line")
  end)

  H.it("INDEX is read-only", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b" } })
    H.write(dir, "a.txt", { "A", "b" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "A", "B" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    local buf = buf_of(view, "index")
    H.eq(vim.bo[buf].modifiable, false)
    H.eq(vim.bo[buf].buftype, "nofile", "no :w to the index")
    H.eq(vim.wo[view.layout.wins.index].winbar:find("%m", 1, true), nil)
    H.eq(vim.bo[buf_of(view, "worktree")].modifiable, true)
    -- the index buffer follows staging
    press(view, "worktree", 2)
    H.eq(H.buf_lines(buf_of(view, "index")), { "A", "B" })
  end)

  H.it("unstaging a line brings in the WORKING TREE column", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "A", "b", "C" })
    H.git(dir, { "add", "a.txt" })
    local view = open(dir)
    show(view, "staged", "a.txt")
    H.eq(view.layout.roles, { "head", "index" })
    press(view, "index", 3)
    H.eq(index_of(dir, "a.txt"), "A\nb\nc\n")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    H.eq(view.stagectl:class_at("worktree", 3), "unstaged")
    H.eq(api.nvim_get_current_win(), view.layout.wins.index)
    -- nothing staged any more: the INDEX column is redundant
    press(view, "index", 1)
    H.eq(index_of(dir, "a.txt"), "a\nb\nc\n")
    H.eq(view.layout.roles, { "head", "worktree" })
  end)

  H.it("<Space> toggles from any column", function()
    local dir = H.repo({ ["a.txt"] = { "alpha", "beta", "gamma" } })
    H.write(dir, "a.txt", { "alpha1", "beta", "gamma1" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "alpha1", "beta", "gamma1", "new line" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    -- a staged line, from the WORKING TREE column: unstage
    press(view, "worktree", 1)
    H.eq(index_of(dir, "a.txt"), "alpha\nbeta\ngamma1\n")
    -- the same line from the HEAD column: stage again
    press(view, "head", 1)
    H.eq(index_of(dir, "a.txt"), "alpha1\nbeta\ngamma1\n")
    -- an unstaged addition from the WORKING TREE column: stage (everything staged now)
    press(view, "worktree", 4)
    H.eq(index_of(dir, "a.txt"), "alpha1\nbeta\ngamma1\nnew line\n")
    H.eq(view.layout.roles, { "head", "index" })
    -- from the INDEX column: unstage
    press(view, "index", 3)
    H.eq(index_of(dir, "a.txt"), "alpha1\nbeta\ngamma\nnew line\n")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
  end)

  H.it("- toggles whole hunks", function()
    local base = H.lines(20)
    local dir = H.repo({ ["a.txt"] = base })
    local wt = vim.deepcopy(base)
    wt[2], wt[3] = "X2", "X3"
    wt[18] = "X18"
    H.write(dir, "a.txt", wt)
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    press(view, "worktree", 2, "toggle_stage_hunk")
    local expected = vim.deepcopy(base)
    expected[2], expected[3] = "X2", "X3"
    H.eq(index_of(dir, "a.txt"), table.concat(expected, "\n") .. "\n")
    press(view, "worktree", 3, "toggle_stage_hunk")
    H.eq(index_of(dir, "a.txt"), table.concat(base, "\n") .. "\n")
  end)

  H.it("whole-file changes: deleted and new files", function()
    local dir = H.repo({ ["gone.txt"] = { "1", "2" }, ["keep.txt"] = { "k" } })
    os.remove(dir .. "/gone.txt")
    H.write(dir, "new.txt", { "n1", "n2" })
    H.git(dir, { "add", "new.txt" })
    H.write(dir, "new.txt", { "n1", "n2", "n3" })
    local view = open(dir)
    show(view, "unstaged", "gone.txt")
    H.eq(view.layout.roles, { "head", "worktree" })
    press(view, "worktree", 1, "toggle_stage_hunk")
    H.eq(H.git(dir, { "status", "--short", "--", "gone.txt" }), "D  gone.txt\n")
    show(view, "unstaged", "new.txt")
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    H.ok(vim.wo[view.layout.wins.head].winbar:find("(new file)", 1, true))
    press(view, "worktree", 3)
    H.eq(index_of(dir, "new.txt"), "n1\nn2\nn3\n")
  end)

  H.it("neighbouring staged and unstaged lines keep their own state", function()
    local dir = H.repo({ ["a.txt"] = { "a", "name = app", "debug", "z" } })
    H.write(dir, "a.txt", { "a", "name = STAGED", "z" })
    H.git(dir, { "add", "a.txt" })
    H.write(dir, "a.txt", { "a", "name = STAGED", "extra", "z" })
    local view = open(dir)
    show(view, "unstaged", "a.txt")
    H.eq(view.stagectl:class_at("worktree", 2), "staged")
    H.eq(view.stagectl:class_at("worktree", 3), "unstaged")
    -- unstage the STAGED line from the INDEX column: it becomes an unstaged change
    press(view, "index", 2)
    H.eq(index_of(dir, "a.txt"), "a\nname = app\nz\n")
    H.eq(view.stagectl:class_at("worktree", 2), "unstaged")
    H.eq(view.stagectl:class_at("worktree", 3), "unstaged")
  end)

  H.it("file panel and diff windows end in the same layout", function()
    -- a partly staged file, three columns
    local function setup()
      local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
      H.write(dir, "a.txt", { "A", "b", "c" })
      H.git(dir, { "add", "a.txt" })
      H.write(dir, "a.txt", { "A", "b", "C" })
      local view = open(dir)
      show(view, "unstaged", "a.txt")
      H.eq(view.layout.roles, { "head", "worktree", "index" })
      return dir, view
    end
    local function panel(view, action, section)
      api.nvim_set_current_win(view.layout.files_win)
      local entry = section and H.find_entry(view, section, "a.txt")
      if entry then
        api.nvim_win_set_cursor(0, { view.files:line_of(entry), 0 })
      end
      view:dispatch(action, { buf = view.files.buf, win = view.layout.files_win })
    end
    local results = {}
    -- stage what is left: from the diff ...
    local dir, view = setup()
    press(view, "worktree", 3, "toggle_stage_hunk")
    results.diff_stage = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    -- ... from the file panel (the Unstaged entry), and with S
    dir, view = setup()
    panel(view, "toggle_stage", "unstaged")
    results.panel_stage = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    dir, view = setup()
    panel(view, "stage_all")
    results.panel_stage_all = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    H.eq(results.panel_stage, results.diff_stage)
    H.eq(results.panel_stage_all, results.diff_stage)
    H.eq(results.diff_stage[1], { "head", "index" })
    -- unstage everything: from the diff, the file panel (the Staged entry) and with U
    dir, view = setup()
    press(view, "index", 1, "toggle_stage_hunk")
    results.diff_unstage = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    dir, view = setup()
    panel(view, "toggle_stage", "staged")
    results.panel_unstage = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    dir, view = setup()
    panel(view, "unstage_all")
    results.panel_unstage_all = { view.layout.roles, H.git(dir, { "status", "--short" }) }
    view:close()
    H.eq(results.panel_unstage, results.diff_unstage)
    H.eq(results.panel_unstage_all, results.diff_unstage)
    H.eq(results.diff_unstage[1], { "head", "worktree" })
    -- discarding the unstaged change leaves HEAD | INDEX too
    dir, view = setup()
    panel(view, "discard", "unstaged")
    H.eq(view.layout.roles, { "head", "index" })
  end)

  H.it("the two-way mode is still available", function()
    local config = require("diffmerge.config")
    config.options.status.three_way = false
    local dir = H.repo({ ["a.txt"] = { "a" } })
    H.write(dir, "a.txt", { "b" })
    local ok, err = pcall(function()
      local view = open(dir)
      show(view, "unstaged", "a.txt")
      H.eq(view.layout.roles, { "a", "b" })
      -- same staging code: a staged deletion can be unstaged from the Staged diff
      local dir2 = H.repo({ ["d.txt"] = { "1", "2" }, ["k.txt"] = { "k" } })
      H.git(dir2, { "rm", "-q", "d.txt" })
      view:close()
      view = open(dir2)
      show(view, "staged", "d.txt")
      press(view, "a", 1, "toggle_stage_hunk")
      H.eq(H.git(dir2, { "status", "--short", "--", "d.txt" }), " D d.txt\n")
      H.eq(index_of(dir2, "d.txt"), "1\n2\n")
    end)
    config.options.status.three_way = true
    assert(ok, err)
  end)
end)

H.done()
