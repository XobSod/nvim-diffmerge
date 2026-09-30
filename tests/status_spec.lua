local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

vim.fn.confirm = function()
  return 1
end

local function open_status(dir)
  vim.cmd.cd(dir)
  local view = require("diffmerge").status()
  H.ok(view, "status view opened")
  return view
end

local function staged_content(dir, path)
  return H.git(dir, { "show", ":" .. path })
end

H.describe("status view", function()
  H.it("lists conflicts / staged / unstaged / untracked like git status", function()
    local dir = H.repo({ ["a.txt"] = H.lines(5), ["b.txt"] = H.lines(3), ["dir/c.txt"] = { "c" } })
    H.write(dir, "a.txt", { "line1", "CHANGED", "line3", "line4", "line5" })
    H.write(dir, "b.txt", { "line1", "staged", "line3" })
    H.git(dir, { "add", "b.txt" })
    H.write(dir, "b.txt", { "line1", "staged", "line3", "more" })
    H.write(dir, "new.txt", { "new" })
    H.git(dir, { "rm", "-q", "dir/c.txt" })
    local view = open_status(dir)
    H.eq(H.entries(view), {
      "staged:D:dir/c.txt",
      "staged:M:b.txt",
      "unstaged:M:a.txt",
      "unstaged:M:b.txt",
      "untracked:?:new.txt",
    })
    local e = H.find_entry(view, "unstaged", "a.txt")
    H.eq(e.stats, { added = 1, deleted = 1, binary = false })
  end)

  H.it("shows index vs working tree with diff mode and an editable real buffer", function()
    local dir = H.repo({ ["a.txt"] = H.lines(5) })
    H.write(dir, "a.txt", { "line1", "CHANGED", "line3", "line4", "line5" })
    local view = open_status(dir)
    local e = H.find_entry(view, "unstaged", "a.txt")
    view:show_entry(e)
    local a, b = view.layout.wins.a, view.layout.wins.b
    H.ok(vim.wo[a].diff and vim.wo[b].diff, "diff mode on both windows")
    H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(b)), dir .. "/a.txt")
    H.ok(vim.bo[api.nvim_win_get_buf(b)].modifiable, "working tree side editable")
    H.eq(vim.bo[api.nvim_win_get_buf(a)].buftype, "acwrite")
    H.eq(H.buf_lines(api.nvim_win_get_buf(a)), H.lines(5))
    H.ok(vim.wo[b].winbar:find("WORKING TREE", 1, true), "winbar label")
  end)

  H.it("stages and unstages files with the file panel", function()
    local dir = H.repo({ ["a.txt"] = H.lines(3) })
    H.write(dir, "a.txt", { "x" })
    H.write(dir, "new.txt", { "new" })
    local view = open_status(dir)
    api.nvim_set_current_win(view.layout.files_win)
    local line = view.files:line_of(H.find_entry(view, "unstaged", "a.txt"))
    api.nvim_win_set_cursor(0, { line, 0 })
    view:dispatch("toggle_stage", { buf = view.files.buf, win = view.layout.files_win })
    H.eq(H.entries(view), { "staged:M:a.txt", "untracked:?:new.txt" })
    view:dispatch("stage_all", { buf = view.files.buf })
    H.eq(H.entries(view), { "staged:M:a.txt", "staged:A:new.txt" })
    view:dispatch("unstage_all", { buf = view.files.buf })
    H.eq(H.entries(view), { "unstaged:M:a.txt", "untracked:?:new.txt" })
  end)

  H.it("stages a single hunk from the working tree window", function()
    local base = H.lines(20)
    local dir = H.repo({ ["a.txt"] = base })
    local changed = vim.deepcopy(base)
    changed[2] = "FIRST"
    changed[18] = "SECOND"
    H.write(dir, "a.txt", changed)
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local b = view.layout.wins.b
    api.nvim_set_current_win(b)
    api.nvim_win_set_cursor(b, { 18, 0 })
    view:dispatch("toggle_stage_hunk", { buf = api.nvim_win_get_buf(b), win = b })
    local expected = vim.deepcopy(base)
    expected[18] = "SECOND"
    H.eq(staged_content(dir, "a.txt"), table.concat(expected, "\n") .. "\n")
    -- the file is now in both sections
    H.eq(H.entries(view), { "staged:M:a.txt", "unstaged:M:a.txt" })
  end)

  H.it("unstages a hunk from the staged view", function()
    local base = H.lines(20)
    local dir = H.repo({ ["a.txt"] = base })
    local changed = vim.deepcopy(base)
    changed[2] = "FIRST"
    changed[18] = "SECOND"
    H.write(dir, "a.txt", changed)
    H.git(dir, { "add", "a.txt" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "staged", "a.txt"), { focus = true })
    local a = view.layout.wins.a -- HEAD side works too
    api.nvim_set_current_win(a)
    api.nvim_win_set_cursor(a, { 2, 0 })
    view:dispatch("toggle_stage_hunk", { buf = api.nvim_win_get_buf(a), win = a })
    local expected = vim.deepcopy(base)
    expected[18] = "SECOND"
    H.eq(staged_content(dir, "a.txt"), table.concat(expected, "\n") .. "\n")
  end)

  H.it("stages selected lines (visual)", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "z" } })
    H.write(dir, "a.txt", { "a", "B", "C", "z" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local b = view.layout.wins.b
    view:dispatch("toggle_stage_hunk", { buf = api.nvim_win_get_buf(b), win = b, range = { 3, 3 } })
    H.eq(staged_content(dir, "a.txt"), "a\nb\nC\nz\n")
  end)

  H.it("<Space> stages the line under the cursor and moves to the next change", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "z" } })
    H.write(dir, "a.txt", { "a", "B", "C", "z" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local b = view.layout.wins.b
    api.nvim_win_set_cursor(b, { 2, 0 })
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(b), win = b })
    H.eq(staged_content(dir, "a.txt"), "a\nB\nc\nz\n")
    H.eq(api.nvim_win_get_cursor(b)[1], 3, "on the next changed line")
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(b), win = b })
    H.eq(staged_content(dir, "a.txt"), "a\nB\nC\nz\n")
  end)

  H.it("<Space> follows the alignment on screen (linematch)", function()
    local dir = H.repo({ ["a.txt"] = { "keep", "a", "b", "z" } })
    H.write(dir, "a.txt", { "keep", "x", "a2", "b2", "z" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local b = view.layout.wins.b
    api.nvim_win_set_cursor(b, { 3, 0 }) -- a2, shown next to a
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(b), win = b })
    H.eq(staged_content(dir, "a.txt"), "keep\na2\nb\nz\n")
  end)

  H.it("<Space> on a removed line (INDEX window) stages only that removal", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c", "z" } })
    H.write(dir, "a.txt", { "a", "z" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local a, b = view.layout.wins.a, view.layout.wins.b
    -- next to the filler lines in the working tree window there is no line to stage
    api.nvim_win_set_cursor(b, { 2, 0 })
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(b), win = b })
    H.eq(staged_content(dir, "a.txt"), "a\nb\nc\nz\n")
    api.nvim_win_set_cursor(a, { 3, 0 })
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(a), win = a })
    H.eq(staged_content(dir, "a.txt"), "a\nb\nz\n")
  end)

  H.it("<Space> unstages a line in the Staged section", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b", "c" } })
    H.write(dir, "a.txt", { "A", "b", "C" })
    H.git(dir, { "add", "a.txt" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "staged", "a.txt"), { focus = true })
    local b = view.layout.wins.b
    api.nvim_win_set_cursor(b, { 3, 0 })
    view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(b), win = b })
    H.eq(staged_content(dir, "a.txt"), "A\nb\nc\n")
  end)

  H.it("<Space> in the file panel stages the file", function()
    local dir = H.repo({ ["a.txt"] = { "a" } })
    H.write(dir, "a.txt", { "b" })
    local view = open_status(dir)
    api.nvim_set_current_win(view.layout.files_win)
    api.nvim_win_set_cursor(0, { view.files:line_of(H.find_entry(view, "unstaged", "a.txt")), 0 })
    H.eq(vim.fn.maparg("<Space>", "n", false, true).desc, "DiffMerge: Stage / unstage (file, directory, section)")
    view:dispatch("toggle_stage", { buf = view.files.buf, win = view.layout.files_win })
    H.eq(H.entries(view), { "staged:M:a.txt" })
  end)

  H.it("stages part of an untracked file", function()
    local dir = H.repo({ ["x.txt"] = { "x" } })
    H.write(dir, "new.txt", { "one", "two", "three" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "untracked", "new.txt"), { focus = true })
    local b = view.layout.wins.b
    view:dispatch("toggle_stage_hunk", { buf = api.nvim_win_get_buf(b), win = b, range = { 1, 2 } })
    H.eq(staged_content(dir, "new.txt"), "one\ntwo\n")
  end)

  H.it("writes the index buffer on :w", function()
    local dir = H.repo({ ["a.txt"] = { "a", "b" } })
    H.write(dir, "a.txt", { "a", "b", "c" })
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"), { focus = true })
    local a = view.layout.wins.a
    local buf = api.nvim_win_get_buf(a)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "A-edited" })
    api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
    H.eq(staged_content(dir, "a.txt"), "A-edited\nb\n")
    H.eq(vim.bo[buf].modified, false)
  end)

  H.it("discards unstaged changes and deletes untracked files", function()
    local dir = H.repo({ ["a.txt"] = { "a" } })
    H.write(dir, "a.txt", { "changed" })
    H.write(dir, "junk.txt", { "junk" })
    local view = open_status(dir)
    api.nvim_set_current_win(view.layout.files_win)
    for _, sec in ipairs({ "unstaged", "untracked" }) do
      local e = H.find_entry(view, sec, sec == "unstaged" and "a.txt" or "junk.txt")
      api.nvim_win_set_cursor(0, { view.files:line_of(e), 0 })
      view:dispatch("discard", { buf = view.files.buf, win = 0 })
    end
    H.eq(H.read(dir, "a.txt"), "a\n")
    H.eq(H.read(dir, "junk.txt"), nil)
    H.eq(H.entries(view), {})
  end)

  H.it("closes cleanly and leaves no diff options behind", function()
    local dir = H.repo({ ["a.txt"] = { "a" } })
    H.write(dir, "a.txt", { "b" })
    vim.cmd("edit " .. dir .. "/a.txt")
    local buf = api.nvim_get_current_buf()
    local view = open_status(dir)
    view:show_entry(H.find_entry(view, "unstaged", "a.txt"))
    H.eq(api.nvim_win_get_buf(view.layout.wins.b), buf)
    view:close()
    H.eq(#api.nvim_list_tabpages(), 1)
    H.ok(api.nvim_buf_is_valid(buf), "user buffer kept")
    -- a window that never showed the buffer takes its options from the last one that did
    vim.cmd("tabnew")
    vim.cmd("buffer " .. buf)
    H.eq(vim.wo.diff, false)
    H.eq(vim.wo.winbar, "")
    H.eq(vim.wo.scrollbind, false)
    H.eq(vim.wo.foldmethod, "manual")
  end)
end)

H.done()
