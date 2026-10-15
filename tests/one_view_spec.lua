-- The status view and its log: one view (gL shows / hides the log), the log following the
-- repository, the keys of the whole repository in the log panel.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

vim.fn.confirm = function()
  return 1
end

--- master: c1 (a1, b1) - c2 (a2) - c3 (b3)
local function repo()
  local dir = H.repo({ ["a.txt"] = { "a1" }, ["b.txt"] = { "b1" } })
  H.git(dir, { "branch", "-m", "master" })
  local c = { vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }
  c[2] = H.commit(dir, "second", { ["a.txt"] = { "a2" } })
  c[3] = H.commit(dir, "third", { ["b.txt"] = { "b3" } })
  vim.cmd.cd(dir)
  return dir, c
end

--- repo() plus `n` newer commits on a branch "other": HEAD (master) comes late in the log.
local function late_head(n)
  local dir, c = repo()
  local lines = {}
  for i = 1, n do
    local msg = "other " .. i
    lines[#lines + 1] = ("commit refs/heads/other\ncommitter T <t@x> %d +0000\ndata %d\n%s"):format(4000000000 + i, #msg, msg)
    if i == 1 then
      lines[#lines + 1] = "from " .. c[3]
    end
    lines[#lines + 1] = ""
  end
  H.git(dir, { "fast-import", "--quiet" }, table.concat(lines, "\n"))
  return dir, c
end

local function current()
  return require("diffmerge").current()
end

local function loaded(view)
  vim.wait(5000, function()
    return view.log ~= nil and not view.log.loading
  end, 10)
  H.ok(view.log and not view.log.loading, "log loaded")
end

local function in_log(view)
  return { buf = view.log.buf, win = view.layout.log_win }
end

local function in_files(view)
  return { buf = view.files.buf, win = view.layout.files_win }
end

local function cursor(view)
  return api.nvim_win_get_cursor(view.layout.log_win)[1]
end

--- The log's cursor on the row of `sha` (or a line).
local function on_row(view, what)
  local line = type(what) == "number" and what or view.log.by_sha[what]
  H.ok(line, "the row is there")
  api.nvim_set_current_win(view.layout.log_win)
  api.nvim_win_set_cursor(view.layout.log_win, { line, 0 })
  return line
end

--- What `fn` said (vim.notify).
local function said_by(fn)
  local said = {}
  local notify = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return table.concat(said, "\n")
end

local function ids(view)
  return vim.tbl_map(function(m)
    return m.id
  end, view.marks)
end

local function desc(buf, lhs)
  return api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true).desc
  end)
end

H.describe("the status view and its log", function()
  H.it(":DiffMerge: no log; gL shows it on the Working tree row and hides it, the selection stays", function()
    local dir, c = repo()
    H.write(dir, "a.txt", { "dirty" })
    vim.cmd("DiffMerge")
    local view = current()
    H.eq({ view.layout.log_win, view.log }, { nil, nil }, "made when first shown")
    H.ok((desc(view.files.buf, "gL") or ""):find("log panel", 1, true), desc(view.files.buf, "gL"))
    view:dispatch("toggle_log", in_files(view))
    loaded(view)
    H.eq(api.nvim_get_current_win(), view.layout.log_win)
    H.eq({ cursor(view), view.shows }, { 1, "worktree" }, "on the Working tree row")
    H.eq(vim.wo[view.layout.log_win].diff, false)
    view:select_line(on_row(view, c[2]))
    H.eq(view.cmp.right.oid, c[2])
    view:dispatch("toggle_log", in_log(view))
    H.eq(view.layout.log_win, nil)
    H.eq(api.nvim_get_current_win(), view.layout.files_win, "back in the file panel")
    H.eq({ view.cmp.right.oid, view.files.title }, { c[2], "git show " .. c[2]:sub(1, 7) }, "still shown")
    view:dispatch("toggle_log", in_files(view))
    H.eq(cursor(view), view.log.by_sha[c[2]], "on its row again")
    H.eq(#view.layout:diff_wins(), 2)
    vim.cmd("DiffMerge diff HEAD~1")
    H.eq(desc(current().files.buf, "gL"), nil, "not in a diff view")
  end)

  H.it(":DiffMerge log: the same view with its log; :DiffMerge: the working tree again", function()
    local _, c = repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    H.eq(view.kind_name, "status")
    H.eq(view.cmp.right.oid, c[3], "a clean tree: HEAD")
    local tabs = #api.nvim_list_tabpages()
    for _, sha in ipairs({ c[2], c[1] }) do
      on_row(view, sha)
      view:dispatch("mark", in_log(view))
    end
    H.eq(view.cmp.left.oid, c[1])
    vim.cmd("DiffMerge")
    H.eq({ current(), #api.nvim_list_tabpages() }, { view, tabs })
    H.eq({ view.shows, ids(view), cursor(view) }, { "worktree", {}, 1 }, "marks gone, on the Working tree row")
    H.ok(view:log_shown(), "the log stays")
    vim.cmd("tabprevious")
    vim.cmd("DiffMerge log")
    H.eq({ current(), #api.nvim_list_tabpages() }, { view, tabs })
    vim.cmd("DiffMerge log -n 2")
    H.eq({ current().kind_name, #api.nvim_list_tabpages() }, { "log", tabs + 1 }, "with arguments: a view of its own")
  end)

  H.it("a file's history: its Working tree row is that file's status, staging works there", function()
    local dir = repo()
    H.write(dir, "b.txt", { "stashed" })
    H.git(dir, { "stash", "push", "-q" })
    H.write(dir, "a.txt", { "dirty a" })
    H.write(dir, "b.txt", { "dirty b" })
    local view = require("diffmerge").history(dir .. "/a.txt")
    loaded(view)
    H.eq({ view.kind_name, view.shows }, { "history", "worktree" }, "it has changes: there")
    H.eq(H.entries(view), { "unstaged:M:a.txt" }, "only that file, no stashes")
    api.nvim_set_current_win(view.layout.files_win)
    api.nvim_win_set_cursor(view.layout.files_win, { view.files:first_file_line(), 0 })
    view:dispatch("toggle_stage", in_files(view))
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "a.txt\n")
    H.ok(api.nvim_buf_get_lines(view.log.buf, 1, 2, false)[1]:find("1 staged", 1, true), "the Index row counts it")
    view:dispatch("unstage_all", in_files(view))
    H.write(dir, "c.txt", { "new" })
    view:dispatch("stage_all", in_files(view))
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "a.txt\n", "S: the file of the view only")
    -- a stash takes the changes of the whole repository
    local labels = {}
    local select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      for _, it in ipairs(items) do
        labels[#labels + 1] = opts.format_item(it)
      end
      cb(nil)
    end
    view:dispatch("stash", in_log(view))
    vim.ui.select = select
    H.eq(labels[1], "Staged changes")
    view:dispatch("unstage_all", in_files(view))
    view:dispatch("toggle_log", in_files(view))
    local blank = view.layout:diff_wins()[1]
    api.nvim_set_current_win(blank)
    vim.ui.select = function(items, opts, cb)
      labels = {}
      for _, it in ipairs(items) do
        labels[#labels + 1] = opts.format_item(it)
      end
      cb(nil)
    end
    H.write(dir, "a.txt", { "a2" })
    view:refresh()
    H.eq(H.entries(view), {}, "a.txt as committed")
    view:dispatch("stash", { buf = api.nvim_get_current_buf(), win = blank })
    vim.ui.select = select
    H.eq(labels, { "All changes", "All changes and untracked files" }, "b.txt and c.txt elsewhere")
  end)

  H.it("the log follows the branches, keeping the selected row; marks of rewritten commits go", function()
    local dir, c = repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    view:select_line(on_row(view, c[2]))
    local c4 = H.commit(dir, "fourth", { ["a.txt"] = { "a4" } })
    -- (what the watchers, FocusGained or a commit from the view do)
    view:refresh()
    loaded(view)
    H.ok(view.log.by_sha[c4], "the new commit is there")
    H.eq({ cursor(view), view.cmp.right.oid }, { view.log.by_sha[c[2]], c[2] }, "the selection kept")
    for _, sha in ipairs({ c4, c[1] }) do
      on_row(view, sha)
      view:dispatch("mark", in_log(view))
    end
    view:dispatch("refresh", in_log(view))
    loaded(view)
    H.eq(ids(view), { c4, c[1] }, "R keeps the marks")
    H.eq({ view.cmp.left.oid, view.cmp.right.oid }, { c[1], c4 })
    H.git(dir, { "commit", "-q", "--amend", "-m", "fourth, amended" })
    view:refresh()
    loaded(view)
    H.eq({ ids(view), view.range }, { {}, nil }, "a marked commit is gone: the marks go")
    local row = view.log:row(cursor(view))
    H.eq(view.cmp.right.oid, row.sha, "the row under the cursor shown instead")
  end)

  H.it("a hidden log reloads when shown again, if the branches moved meanwhile", function()
    local dir = repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    view:dispatch("toggle_log", in_log(view))
    local c4 = H.commit(dir, "fourth", { ["a.txt"] = { "a4" } })
    view:refresh()
    H.eq(view.log.by_sha[c4], nil, "not while hidden")
    view:dispatch("toggle_log", in_files(view))
    loaded(view)
    H.ok(view.log.by_sha[c4], "shown: reloaded")
  end)

  H.it("the keys of the repository in the log panel; diff windows of a commit are read-only", function()
    local dir, c = repo()
    H.write(dir, "a.txt", { "dirty" })
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    for _, lhs in ipairs({ "s", "cc", "ca", "F", "p", "P" }) do
      H.ok(desc(view.log.buf, lhs), lhs)
    end
    local labels = {}
    local select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      for _, it in ipairs(items) do
        labels[#labels + 1] = opts.format_item(it)
      end
      cb(nil)
    end
    on_row(view, c[2])
    view:dispatch("stash", in_log(view))
    vim.ui.select = select
    H.eq(labels, { "All changes", "All changes and untracked files" }, "no file of the file panel")
    view:select_line(on_row(view, c[2]))
    local win = view.layout.wins.b
    local said = said_by(function()
      view:dispatch("toggle_stage_hunk", { buf = api.nvim_win_get_buf(win), win = win })
    end)
    H.ok(said:find("read-only", 1, true), said)
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "")
  end)

  H.it("a merge commit: its parents cycle with ^, as the title says", function()
    local dir = repo()
    H.git(dir, { "checkout", "-q", "-b", "side", "HEAD~1" })
    H.commit(dir, "on side", { ["c.txt"] = { "c" } })
    H.git(dir, { "checkout", "-q", "master" })
    H.git(dir, { "merge", "-q", "--no-edit", "side" })
    local merge = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    H.eq(view.cmp.right.oid, merge)
    H.ok(view.files.title:find("parent 1 of 2, ^ cycles", 1, true), view.files.title)
    on_row(view, merge)
    view:dispatch("cycle_parent", in_log(view))
    H.ok(view.files.title:find("parent 2 of 2", 1, true), view.files.title)
  end)

  H.it("an empty Index row keeps you in the log; `:DiffMerge` from a diff window shows the status", function()
    local dir, c = repo()
    H.write(dir, "a.txt", { "dirty" })
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    view:select_line(on_row(view, 2))
    H.eq({ H.entries(view), api.nvim_get_current_win() }, { {}, view.layout.log_win }, "nothing staged, still in the log")
    H.ok(desc(api.nvim_win_get_buf(view.layout:diff_wins()[1]), "gL"), "gL in the empty windows too")
    view:select_line(on_row(view, c[3]))
    api.nvim_set_current_win(view.layout.wins.b)
    vim.cmd("DiffMerge")
    H.eq(view.shows, "worktree")
    H.eq(view.current and view.current.path, "a.txt", "the status, not b.txt of the commit")
  end)

  H.it("what you choose while the log loads stays chosen; a reload leaves the log on screen", function()
    local dir, c = repo()
    local view = require("diffmerge").log()
    vim.cmd("DiffMerge")
    loaded(view)
    H.eq({ view.shows, cursor(view) }, { "worktree", 1 }, "first load: not HEAD over it")
    view:select_line(on_row(view, c[2]))
    local rows = #view.log.rows
    H.commit(dir, "fourth", { ["a.txt"] = { "a4" } })
    view:load_log()
    H.eq({ #view.log.rows, view.log.by_sha[c[2]] ~= nil }, { rows, true }, "the old log meanwhile")
    vim.cmd("DiffMerge")
    loaded(view)
    H.eq({ view.shows, cursor(view) }, { "worktree", 1 }, "a reload: not the old row over it")
  end)

  H.it("Working tree + Index selected: git diff HEAD, the HEAD of now", function()
    local dir = repo()
    H.write(dir, "a.txt", { "dirty" })
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    view:select_range(1, 2)
    H.eq(view.cmp.title, "git diff HEAD")
    H.git(dir, { "commit", "-q", "-am", "commit a" })
    view:refresh()
    H.eq(view.cmp.left.oid, vim.trim(H.git(dir, { "rev-parse", "HEAD" })))
    H.eq(H.entries(view), {}, "committed: nothing left")
  end)

  H.it("a clean main view shows its log on HEAD the first time, as a new one", function()
    local _, c = repo()
    vim.cmd("DiffMerge")
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    H.eq(view.cmp.right.oid, c[3])
  end)

  H.it("no commits yet; a path git does not take; S on a file that is gone", function()
    local dir = H.tmpdir()
    H.git(dir, { "init", "-q" })
    vim.cmd.cd(dir)
    local said = said_by(function()
      vim.cmd("DiffMerge log")
      loaded(current())
    end)
    H.eq(said, "")
    H.eq(#api.nvim_buf_get_lines(current().log.buf, 0, -1, false), 2, "the Working tree and Index rows only")
    local other = repo()
    said = said_by(function()
      vim.cmd("DiffMerge log -- :(foo)x")
    end)
    H.ok(said:find("git status failed", 1, true), said)
    H.git(other, { "rm", "-q", "b.txt" })
    H.git(other, { "commit", "-q", "-m", "b gone" })
    local view = require("diffmerge").history(other .. "/b.txt")
    loaded(view)
    view:select_line(1)
    said = said_by(function()
      view:dispatch("stage_all", in_files(view))
      view:dispatch("unstage_all", in_files(view))
    end)
    H.eq(said, "")
  end)

  H.it(":DiffMerge leaves compared marks for the working tree; :DiffMerge conflicts finds the conflict", function()
    local dir, c = repo()
    H.git(dir, { "checkout", "-q", "-b", "side", c[2] })
    H.commit(dir, "side", { ["b.txt"] = { "side" } })
    H.git(dir, { "checkout", "-q", "master" })
    vim.fn.system({ "git", "-C", dir, "merge", "-q", "side" })
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    for _, sha in ipairs({ c[2], c[1] }) do
      on_row(view, sha)
      view:dispatch("mark", in_log(view))
    end
    vim.cmd("DiffMerge conflicts")
    H.eq({ view.shows, ids(view) }, { "worktree", {} })
    H.eq(view.current and view.current.section, "conflicts")
  end)

  H.it("saving a file compared with a commit keeps it on screen", function()
    local dir, c = repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    for _, id in ipairs({ c[1], 1 }) do
      on_row(view, id)
      view:dispatch("mark", in_log(view))
    end
    H.eq(H.entries(view), { "files:M:a.txt", "files:M:b.txt" })
    view:show_entry(H.find_entry(view, "files", "a.txt"))
    api.nvim_set_current_win(view.layout.wins.b)
    api.nvim_buf_set_lines(0, 0, -1, false, { "a1" })
    vim.cmd("silent write")
    view:refresh()
    H.eq(H.entries(view), { "files:M:b.txt" })
    H.eq({ view.current.path, api.nvim_buf_get_name(api.nvim_win_get_buf(view.layout.wins.b)) }, { "a.txt", dir .. "/a.txt" })
  end)

  H.it("a long first load: what you choose stays chosen; cut short by a reload, it still comes to HEAD", function()
    local _, c = late_head(3000)
    local view = require("diffmerge").log()
    vim.wait(5000, function()
      return #view.log.rows > 2
    end, 1)
    H.ok(view.log.loading, "still loading")
    local line = on_row(view, 3)
    local chosen = view.log:row(line).sha
    view:dispatch("select", in_log(view))
    loaded(view)
    H.eq(view.cmp.right.oid, chosen, "<CR> on the first commit: not HEAD over it")
    view:close()
    view = require("diffmerge").log()
    vim.wait(5000, function()
      return #view.log.rows > 2
    end, 1)
    H.ok(view.log.loading, "still loading")
    view:dispatch("toggle_first_parent", in_log(view))
    loaded(view)
    H.eq(view.cmp.right.oid, c[3], "HEAD")
  end)

  H.it("a filter that matches nothing: the Working tree row; a stale log shown again: on the selected row", function()
    local dir, c = repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    view.filter = { "--grep=nothing like this" }
    view:load_log()
    loaded(view)
    H.eq({ view.shows, cursor(view) }, { "worktree", 1 })
    view.filter = {}
    view:load_log()
    loaded(view)
    view:select_line(on_row(view, c[2]))
    on_row(view, c[1])
    view:dispatch("toggle_log", in_log(view))
    H.commit(dir, "fourth", { ["a.txt"] = { "a4" } })
    view:refresh()
    view:dispatch("toggle_log", in_files(view))
    loaded(view)
    H.eq({ cursor(view), view.cmp.right.oid }, { view.log.by_sha[c[2]], c[2] })
  end)

  H.it("the log alone in its tab stays; no commits yet and HEAD only", function()
    repo()
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    api.nvim_set_current_win(view.layout.log_win)
    vim.cmd("only")
    local said = said_by(function()
      view:dispatch("toggle_log", in_log(view))
    end)
    H.ok(said:find("only window", 1, true), said)
    H.ok(view.layout:is_valid() and view:log_shown(), "still there")
    local dir = H.tmpdir()
    H.git(dir, { "init", "-q" })
    H.write(dir, "f.txt", { "new" })
    vim.cmd.cd(dir)
    said = said_by(function()
      loaded(require("diffmerge").history(dir .. "/f.txt"))
    end)
    H.eq(said, "")
  end)

  H.it("a reload before the first commit came still comes to HEAD; moving meanwhile is your choice", function()
    local _, c = repo()
    local view = require("diffmerge").log()
    view:load_log()
    loaded(view)
    H.eq(view.cmp and view.cmp.right.oid, c[3], "HEAD")
    view:close()
    local _, d = late_head(3000)
    view = require("diffmerge").log()
    vim.wait(5000, function()
      return #view.log.rows > 2
    end, 1)
    H.ok(view.log.loading, "still loading")
    view:dispatch("toggle_first_parent", in_log(view))
    local moved_to = view.log:row(on_row(view, 5)).sha
    api.nvim_exec_autocmds("CursorMoved", { buffer = view.log.buf })
    loaded(view)
    H.ok(view.cmp.right.oid ~= d[3], "not HEAD over your move")
    H.eq(cursor(view), view.log.by_sha[moved_to], "on the row you moved to")
  end)

  H.it("no commits on this branch yet: the revisions you name are shown; :DiffMerge clears a mark", function()
    local dir, c = repo()
    H.git(dir, { "checkout", "-q", "--orphan", "new" })
    vim.cmd("DiffMerge log master")
    local view = current()
    loaded(view)
    view:dispatch("toggle_all_branches", in_log(view))
    loaded(view)
    H.ok(view.log.by_sha[c[3]], "git log master")
    view:close()
    H.git(dir, { "checkout", "-q", "-f", "master" })
    vim.cmd("DiffMerge log")
    view = current()
    loaded(view)
    view:select_line(on_row(view, 1))
    on_row(view, c[2])
    view:dispatch("mark", in_log(view))
    vim.cmd("DiffMerge")
    H.eq({ view.shows, ids(view) }, { "worktree", {} })
  end)

  H.it("g?: the keys of that window by function, its own first, pairs on one line", function()
    local dir = repo()
    H.write(dir, "a.txt", { "dirty" })
    vim.cmd("DiffMerge log")
    local view = current()
    loaded(view)
    local function titles(rows)
      return vim.tbl_map(
        function(r)
          return r[1]
        end,
        vim.tbl_filter(function(r)
          return r[2] == nil
        end, rows)
      )
    end
    local keymaps = require("diffmerge.keymaps")
    local files = keymaps.help_lines(view.files.buf)
    H.eq(titles(files), { "Files", "Staging", "Conflicts", "Stash", "Commit", "Remote", "Branches", "View" })
    H.ok(vim.iter(files):any(function(r)
      return r[1] == "S  U" and r[2] == "Stage / unstage everything"
    end), vim.inspect(files))
    local log = keymaps.help_lines(view.log.buf)
    H.eq(titles(log), { "Log", "Files", "Stash", "Commit", "Remote", "Branches", "View" })
    H.eq(log[2], { "<CR>", "Show the row (visual: the combined changes of the rows)" })
    H.ok(vim.iter(log):any(function(r)
      return r[1] == "c  cc  ca"
    end), "the keys of the repository there too")
    local diff = keymaps.help_lines(api.nvim_win_get_buf(view.layout:diff_wins()[1]))
    H.eq(titles(diff), { "Staging", "Files", "View" })
  end)

  H.it("the keys of the repository are one group; gF / :DiffMerge files and :DiffMerge log toggle", function()
    repo()
    require("diffmerge").setup({ watch = false, auto_preview = false, keymaps = { repo = { F = false } } })
    local ok, err = pcall(function()
      vim.cmd("DiffMerge log")
      local view = current()
      loaded(view)
      H.eq({ desc(view.files.buf, "F"), desc(view.log.buf, "F") }, { nil, nil }, "off in both panels")
      H.ok(desc(view.log.buf, "P"), "the rest there")
      H.ok((desc(view.files.buf, "gW") or ""):find("whitespace", 1, true), desc(view.files.buf, "gW"))
      view:dispatch("toggle_files", in_log(view))
      H.eq(view.layout.files_win, nil)
      vim.cmd("DiffMerge files")
      H.eq(api.nvim_get_current_win(), view.layout.files_win, "shown: there")
      vim.cmd("DiffMerge log")
      H.eq({ view:log_shown(), current() }, { false, view }, "in the view: hidden")
      vim.cmd("DiffMerge log")
      H.eq({ view:log_shown(), api.nvim_get_current_win() }, { true, view.layout.log_win }, "shown: there")
    end)
    require("diffmerge").setup({ watch = false, auto_preview = false })
    assert(ok, err)
  end)

  H.it("a panel's own keys win over the repository's; false turns one off in that panel only", function()
    local dir = repo()
    H.write(dir, "a.txt", { "dirty" })
    require("diffmerge").setup({
      watch = false,
      auto_preview = false,
      keymaps = { file_panel = { s = "toggle_stage", F = false }, log_panel = { p = "cycle_parent" } },
    })
    local ok, err = pcall(function()
      vim.cmd("DiffMerge log")
      local view = current()
      loaded(view)
      H.ok(desc(view.files.buf, "s"):find("Stage / unstage", 1, true), desc(view.files.buf, "s"))
      H.eq({ desc(view.files.buf, "F"), desc(view.log.buf, "F") ~= nil }, { nil, true })
      H.ok(desc(view.log.buf, "p"):find("parent", 1, true), desc(view.log.buf, "p"))
      local keymaps = require("diffmerge.keymaps")
      local rows = vim.tbl_map(function(r)
        return r[1]
      end, keymaps.help_lines(view.files.buf))
      H.ok(not vim.tbl_contains(rows, "Stash") and vim.tbl_contains(rows, "- s <Space>"), vim.inspect(rows))
      rows = vim.tbl_map(function(r)
        return r[1]
      end, keymaps.help_lines(view.log.buf))
      H.ok(vim.tbl_contains(rows, "^ p") and vim.tbl_contains(rows, "F") and vim.tbl_contains(rows, "P"), vim.inspect(rows))
    end)
    require("diffmerge").setup({ watch = false, auto_preview = false })
    assert(ok, err)
  end)

  H.it("gF: the cursor stays where it was; the panel alone stays; hidden from it: on to the diff", function()
    local lines = {}
    for i = 1, 60 do
      lines[i] = "line " .. i
    end
    local dir = H.repo({ ["long.txt"] = lines })
    vim.cmd.cd(dir)
    lines[50] = "changed"
    H.write(dir, "long.txt", lines)
    vim.cmd("DiffMerge")
    local view = current()
    local win = view.layout.wins.worktree
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { 40, 0 })
    view:dispatch("toggle_files", { buf = api.nvim_get_current_buf(), win = win })
    H.eq({ view.layout.files_win, api.nvim_win_get_cursor(win)[1] }, { nil, 40 }, "hidden")
    view:dispatch("toggle_files", { buf = api.nvim_get_current_buf(), win = win })
    H.eq(api.nvim_win_get_cursor(view.layout.wins.worktree)[1], 40, "shown: the windows made anew, the cursor kept")
    api.nvim_set_current_win(view.layout.files_win)
    view:dispatch("toggle_files", in_files(view))
    H.eq(view.layout:role_of(api.nvim_get_current_win()), "worktree", "on to the main window")
    view:dispatch("toggle_files", { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() })
    api.nvim_set_current_win(view.layout.files_win)
    vim.cmd("only")
    local said = said_by(function()
      view:dispatch("toggle_files", in_files(view))
    end)
    H.ok(said:find("only window", 1, true), said)
    H.ok(view.layout:is_valid(), "still there")
    local left, right = dir .. "/l.txt", dir .. "/r.txt"
    H.write(dir, "l.txt", { "l" })
    H.write(dir, "r.txt", { "r" })
    local cmp = require("diffmerge").compare(left, right)
    H.eq(desc(api.nvim_win_get_buf(cmp.layout.wins.b), "gF"), nil, "no file panel: Vim's own gF")
  end)

  H.it("a stash to show: the first gL stays on the Working tree row; g? without keys there", function()
    local dir, c = repo()
    H.write(dir, "a.txt", { "stashed" })
    H.git(dir, { "stash", "push", "-q" })
    vim.cmd("DiffMerge")
    local view = current()
    view:dispatch("toggle_log", in_files(view))
    loaded(view)
    H.eq({ view.shows, cursor(view) }, { "worktree", 1 })
    local _ = c
    local buf = api.nvim_create_buf(false, true)
    local said = said_by(function()
      require("diffmerge.keymaps").help(buf)
    end)
    H.ok(said:find("no keys", 1, true), said)
  end)
end)

H.done()
