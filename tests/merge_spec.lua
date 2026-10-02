local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

vim.fn.confirm = function()
  return 1
end

--- Repository in the middle of a merge with one conflict (line 2) and two
--- non-conflicting changes (line 8 on main, line 15 on feat).
local function conflict_repo(extra_conflict)
  local base = H.lines(20)
  local dir = H.repo({ ["f.txt"] = base })
  H.git(dir, { "checkout", "-q", "-b", "feat" })
  local feat = vim.deepcopy(base)
  feat[2] = "FEAT"
  feat[15] = "FEAT15"
  if extra_conflict then
    feat[19] = "FEAT19"
  end
  H.commit(dir, "feat", { ["f.txt"] = feat })
  H.git(dir, { "checkout", "-q", "main" })
  local main = vim.deepcopy(base)
  main[2] = "MAIN"
  main[8] = "MAIN8"
  if extra_conflict then
    main[19] = "MAIN19"
  end
  H.commit(dir, "main", { ["f.txt"] = main })
  vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait() -- conflicts
  return dir, base
end

local function expected(base, overrides)
  local t = vim.deepcopy(base)
  for k, v in pairs(overrides) do
    t[k] = v
  end
  return t
end

local function remove(t, idx)
  table.remove(t, idx)
  return t
end

local function open_conflict(dir)
  vim.cmd.cd(dir)
  local view = require("diffmerge").status({ conflicts = true })
  H.ok(view.merge, "merge controller attached")
  return view, api.nvim_win_get_buf(view.layout.wins.merged)
end

H.describe("merge in the status view", function()
  H.it("opens conflicts in the merge layout with git's merge result", function()
    local dir, base = conflict_repo()
    local view, buf = open_conflict(dir)
    H.eq(H.entries(view), { "conflicts:U:f.txt" })
    H.eq(view.layout.kind, "merge")
    H.eq(view.layout.roles, { "local", "merged", "remote" })
    H.eq(H.buf_lines(buf), expected(base, { [8] = "MAIN8", [15] = "FEAT15" }))
    H.eq(view.merge:stats(), { conflicts = 1, unresolved = 1, chunks = 3 })
    H.ok(vim.wo[view.layout.wins.merged].winhighlight:find("DiffAdd:DiffMergeNone", 1, true), "native colours muted")
    -- cursor starts on the conflict
    H.eq(api.nvim_win_get_cursor(view.layout.wins.merged)[1], 2)
    H.ok(api.nvim_get_current_win() == view.layout.wins.merged, "focus in merged window")
  end)

  H.it("toggles LOCAL / BASE / REMOTE (KDiff3 style) and derives state from content", function()
    local dir, base = conflict_repo()
    local view, buf = open_conflict(dir)
    local win = view.layout.wins.merged
    local ctx = { win = win, buf = buf }
    local m = view.merge
    m:toggle(1, ctx)
    H.eq(H.buf_lines(buf)[2], "MAIN")
    H.eq(m:stats().unresolved, 0)
    m:toggle(3, ctx)
    H.eq(vim.list_slice(H.buf_lines(buf), 2, 3), { "MAIN", "FEAT" })
    m:toggle(1, ctx)
    H.eq(vim.list_slice(H.buf_lines(buf), 2, 3), { "FEAT", "line3" })
    m:toggle(3, ctx)
    H.eq(H.buf_lines(buf)[2], "line2", "back to unresolved (base text)")
    H.eq(m:stats().unresolved, 1)
    -- separate key presses are separate undo blocks
    vim.cmd("let &undolevels = &undolevels")
    m:take_none(ctx)
    H.eq(H.buf_lines(buf), remove(expected(base, { [8] = "MAIN8", [15] = "FEAT15" }), 2))
    H.eq(m:stats().unresolved, 0)
    -- undo restores the previous content; the state follows the content
    vim.cmd("silent undo")
    m:sync()
    H.eq(H.buf_lines(buf)[2], "line2")
    H.eq(m:stats().unresolved, 1)
    -- manual edit inside the conflict resolves it
    api.nvim_buf_set_lines(buf, 1, 2, false, { "MANUAL" })
    m:sync()
    H.eq(m:stats().unresolved, 0)
    H.ok(m.regions[1].edited, "edited")
  end)

  H.it("resolves from a side window (cursor in LOCAL)", function()
    local dir = conflict_repo()
    local view, buf = open_conflict(dir)
    local lwin = view.layout.wins["local"]
    api.nvim_set_current_win(lwin)
    api.nvim_win_set_cursor(lwin, { 2, 0 })
    view:dispatch("toggle_remote", { win = lwin, buf = api.nvim_win_get_buf(lwin) })
    H.eq(H.buf_lines(buf)[2], "FEAT")
  end)

  H.it("keeps partial resolutions across re-opening (no conflict markers written)", function()
    local dir, base = conflict_repo(true)
    local view, buf = open_conflict(dir)
    H.eq(view.merge:stats(), { conflicts = 2, unresolved = 2, chunks = 4 })
    view.merge:toggle(3, { win = view.layout.wins.merged })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    view:close()
    local view2 = open_conflict(dir)
    H.eq(view2.merge:stats().unresolved, 1)
    H.eq(H.buf_lines(api.nvim_win_get_buf(view2.layout.wins.merged))[2], "FEAT")
    H.eq(H.read(dir, "f.txt"):find("<<<<<<<", 1, true), nil)
    local _ = base
  end)

  H.it("jumps between conflicts and changes", function()
    local dir = conflict_repo(true)
    local view = open_conflict(dir)
    local win = view.layout.wins.merged
    local ctx = { win = win }
    api.nvim_win_set_cursor(win, { 1, 0 })
    view.merge:jump(ctx, 1, true)
    H.eq(api.nvim_win_get_cursor(win)[1], 2)
    view.merge:jump(ctx, 1, true)
    H.eq(api.nvim_win_get_cursor(win)[1], 19)
    view.merge:jump(ctx, 1, true)
    H.eq(api.nvim_win_get_cursor(win)[1], 2, "wraps around")
    view.merge:jump(ctx, 1, false)
    H.eq(api.nvim_win_get_cursor(win)[1], 8, "next change (auto-merged)")
  end)

  H.it("marks the file resolved with - (git add) after checking", function()
    local dir = conflict_repo()
    local view = open_conflict(dir)
    view.merge:toggle(1, { win = view.layout.wins.merged })
    api.nvim_set_current_win(view.layout.files_win)
    local e = H.find_entry(view, "conflicts", "f.txt")
    api.nvim_win_set_cursor(0, { view.files:line_of(e), 0 })
    view:dispatch("toggle_stage", { buf = view.files.buf, win = view.layout.files_win })
    H.eq(H.entries(view), { "staged:M:f.txt" })
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "f.txt\n")
    H.ok(H.read(dir, "f.txt"):find("MAIN\n", 1, true), "saved before git add")
  end)

  H.it("cycles to the four-way layout", function()
    local dir = conflict_repo()
    local view = open_conflict(dir)
    view:dispatch("cycle_layout", { win = view.layout.wins.merged, buf = 0 })
    H.eq(view.layout.name, "stacked")
    view:dispatch("cycle_layout", { win = view.layout.wins.merged, buf = 0 })
    H.eq(view.layout.name, "four_way")
    H.eq(view.layout.roles, { "local", "base", "remote", "merged" })
    H.ok(view.merge, "controller re-attached")
    H.eq(view.merge:stats().unresolved, 1)
    local base_buf = api.nvim_win_get_buf(view.layout.wins.base)
    H.eq(H.buf_lines(base_buf)[2], "line2")
  end)
end)

H.describe("git mergetool", function()
  local function temp_sides(dir)
    local out = {}
    for n, name in ipairs({ "BASE", "LOCAL", "REMOTE" }) do
      local stage = ({ 1, 2, 3 })[n]
      local p = dir .. "/f_" .. name .. "_123.txt"
      H.write(dir, "f_" .. name .. "_123.txt", H.git(dir, { "show", ":" .. stage .. ":f.txt" }))
      out[name] = p
    end
    return out
  end

  H.it("reports failure until everything is resolved and saved", function()
    local dir = conflict_repo()
    vim.cmd.cd(dir)
    local t = temp_sides(dir)
    local view = require("diffmerge").mergetool(t.LOCAL, t.BASE, t.REMOTE, dir .. "/f.txt")
    H.eq(view.layout.kind, "merge")
    H.eq(view:exit_code(), 1)
    local buf = api.nvim_win_get_buf(view.layout.wins.merged)
    H.ok(vim.wo[view.layout.wins["local"]].winbar:find("LOCAL", 1, true), "LOCAL label")
    H.ok(vim.wo[view.layout.wins.remote].winbar:find("feat", 1, true), "theirs = the merged branch")
    view.merge:toggle(3, { win = view.layout.wins.merged })
    H.eq(view:exit_code(), 1, "unsaved")
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    H.eq(view:exit_code(), 0)
    H.eq(vim.bo[api.nvim_win_get_buf(view.layout.wins["local"])].modifiable, false)
  end)
end)

H.done()
