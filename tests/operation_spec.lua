-- A merge, rebase, cherry-pick or revert going on: cc continues it, the c menu skips / aborts,
-- :DiffMerge continue / skip / abort.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local commit = require("diffmerge.commit")

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

--- master: a (f.txt a b c) - m (f.txt M b c); topic from a: t1 (T1 b c), t2 (T2 b c)
local function repo()
  local dir = H.repo({ ["f.txt"] = { "a", "b", "c" } })
  H.git(dir, { "branch", "-m", "master" })
  H.git(dir, { "checkout", "-q", "-b", "topic" })
  H.commit(dir, "t1", { ["f.txt"] = { "T1", "b", "c" } })
  H.commit(dir, "t2", { ["f.txt"] = { "T2", "b", "c" } })
  H.git(dir, { "checkout", "-q", "master" })
  H.commit(dir, "m", { ["f.txt"] = { "M", "b", "c" } })
  vim.cmd.cd(dir)
  return dir
end

local function open()
  local view = require("diffmerge").status()
  api.nvim_set_current_win(view.layout.files_win)
  return view
end

--- What `fn` said (vim.notify).
local function said_by(fn)
  local said, notify = {}, vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return table.concat(said, "\n")
end

local function press(view, action)
  api.nvim_set_current_win(view.layout.files_win)
  view:dispatch(action, { buf = view.files.buf, win = view.layout.files_win })
end

local function message_win()
  local win
  vim.wait(5000, function()
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_buf_get_name(api.nvim_win_get_buf(w)):match("COMMIT_EDITMSG$") then
        win = w
        return true
      end
    end
    return false
  end, 20)
  return win
end

local function finished()
  return vim.wait(10000, function()
    return not commit.running()
  end, 20)
end

local function write_message(win)
  api.nvim_set_current_win(win)
  api.nvim_feedkeys(api.nvim_replace_termcodes(":wq<CR>", true, false, true), "xt", false)
  H.ok(finished(), "git finished")
end

--- The c menu, answered with the choice whose text starts with `text`.
local function menu(view, text)
  local offered = {}
  local select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do
      offered[#offered + 1] = opts.format_item(it)
    end
    for _, it in ipairs(items) do
      if opts.format_item(it):sub(1, #text) == text then
        return cb(it)
      end
    end
    cb(nil)
  end
  press(view, "commit_menu")
  vim.ui.select = select
  H.flush(50)
  return offered
end

--- f.txt resolved as you would: in its buffer (the MERGED window's), saved, added.
local function resolve(dir, lines)
  local buf = vim.fn.bufadd(dir .. "/f.txt")
  vim.fn.bufload(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  H.git(dir, { "add", "f.txt" })
end

local function going_on(dir, name)
  return vim.uv.fs_stat(dir .. "/.git/" .. name) ~= nil
end

H.describe("an operation going on", function()
  H.it("a merge: cc waits for the conflicts, then continues it with its message", function()
    local dir = repo()
    vim.system({ "git", "merge", "-q", "topic" }, { cwd = dir }):wait()
    local view = open()
    H.ok(view.files.subtitle:find("MERGING", 1, true) and view.files.subtitle:find("cc continues · c abort", 1, true), view.files.subtitle)
    local said = said_by(function()
      press(view, "commit")
    end)
    H.ok(said:find("1 file(s) in conflict: f.txt", 1, true), said)
    resolve(dir, { "M T2", "b", "c" })
    view:refresh()
    press(view, "commit")
    write_message(message_win())
    H.eq(going_on(dir, "MERGE_HEAD"), false, "merged")
    H.eq(#vim.split(vim.trim(H.git(dir, { "log", "-1", "--format=%P" })), " "), 2, "a merge commit")
  end)

  H.it("a rebase: its progress; continued to the next stop; a commit of it skipped", function()
    local dir = repo()
    H.git(dir, { "checkout", "-q", "topic" })
    vim.system({ "git", "rebase", "master" }, { cwd = dir }):wait()
    local view = open()
    local onto = vim.trim(H.git(dir, { "rev-parse", "--short=7", "master" }))
    H.ok(view.files.subtitle:find("REBASING topic (1/2)\nonto " .. onto, 1, true), view.files.subtitle)
    H.ok(view.files.subtitle:find("c skip/abort", 1, true), view.files.subtitle)
    resolve(dir, { "M T1", "b", "c" })
    view:refresh()
    local said = said_by(function()
      press(view, "commit")
      write_message(message_win())
    end)
    H.ok(said:find("the rebase goes on", 1, true), said)
    view:refresh()
    H.ok(view.files.subtitle:find("(2/2)", 1, true), view.files.subtitle)
    asked = {}
    local offered = menu(view, "Skip")
    H.eq(offered[1], "Continue the rebase")
    H.ok(offered[2]:match("^Skip %x+ t2$"), offered[2])
    H.eq(offered[3], "Abort the rebase")
    H.ok(finished(), "git finished")
    H.ok(asked[1]:find("Its changes are not applied", 1, true), vim.inspect(asked))
    H.eq(going_on(dir, "rebase-merge"), false, "rebased")
    H.eq(vim.trim(H.git(dir, { "log", "--format=%s", "-3" })), "t1\nm\ninitial")
  end)

  H.it("a cherry-pick aborted: all as before; unsaved changes come first", function()
    local dir = repo()
    local head = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
    vim.system({ "git", "cherry-pick", "topic" }, { cwd = dir }):wait()
    local view = open()
    H.write(dir, "f.txt", { "M T2", "b", "c" })
    H.git(dir, { "add", "f.txt" })
    vim.cmd("edit " .. dir .. "/f.txt")
    api.nvim_buf_set_lines(0, 0, 1, false, { "not saved" })
    local said = said_by(function()
      vim.cmd("DiffMerge continue")
    end)
    H.ok(said:find("unsaved changes in f.txt", 1, true), said)
    vim.cmd("silent! edit!")
    menu(view, "Abort")
    H.ok(finished(), "git finished")
    H.eq({ going_on(dir, "CHERRY_PICK_HEAD"), vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }, { false, head })
  end)

  H.it("aborting names unsaved edits of a file with a tab, a quote and a backslash in its name", function()
    local name = 'we"ird\tna\\me.txt'
    local dir = H.repo({ [name] = { "a", "b", "c" } })
    H.git(dir, { "branch", "-m", "master" })
    H.git(dir, { "checkout", "-q", "-b", "topic" })
    H.commit(dir, "t", { [name] = { "T", "b", "c" } })
    H.git(dir, { "checkout", "-q", "master" })
    H.commit(dir, "m", { [name] = { "M", "b", "c" } })
    vim.cmd.cd(dir)
    vim.system({ "git", "cherry-pick", "topic" }, { cwd = dir }):wait()
    open()
    local buf = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(buf)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "not saved" })
    asked, confirm_answer = {}, 2
    vim.cmd("DiffMerge abort")
    confirm_answer, vim.bo[buf].modified = 1, false
    H.ok(#asked == 1 and asked[1]:find("Unsaved edits in " .. name, 1, true), vim.inspect(asked))
  end)

  H.it("a revert continued; :DiffMerge skip / abort with nothing going on says so", function()
    local dir = repo()
    H.commit(dir, "m2", { ["f.txt"] = { "M2", "b", "c" } })
    vim.system({ "git", "revert", "--no-edit", "HEAD~1" }, { cwd = dir }):wait()
    H.ok(going_on(dir, "REVERT_HEAD"), "a revert in conflict")
    local view = open()
    resolve(dir, { "a", "b", "c" })
    view:refresh()
    -- (no message to write: git takes the revert's)
    vim.cmd("DiffMerge continue")
    H.ok(finished(), "git finished")
    H.eq(going_on(dir, "REVERT_HEAD"), false)
    H.ok(vim.trim(H.git(dir, { "log", "-1", "--format=%s" })):find("^Revert"), "reverted")
    for _, cmd in ipairs({ "skip", "abort", "continue" }) do
      local said = said_by(function()
        vim.cmd("DiffMerge " .. cmd)
      end)
      H.ok(said:find("no merge, rebase, cherry-pick, revert or git am going on", 1, true), said)
    end
  end)

  H.it("skipped: the next commit's conflict shown anew; aborted: the file as on disk", function()
    local dir = repo()
    H.git(dir, { "checkout", "-q", "topic" })
    vim.system({ "git", "rebase", "master" }, { cwd = dir }):wait()
    local view = open()
    local merged = view.layout.wins.merged
    H.ok(merged, "the conflict shown")
    local buf = api.nvim_win_get_buf(merged)
    api.nvim_buf_set_lines(buf, 0, 1, false, { "my edit" })
    asked = {}
    menu(view, "Skip")
    H.ok(finished(), "git finished")
    H.ok(asked[1]:find("Unsaved edits in f.txt are lost", 1, true), vim.inspect(asked))
    H.ok(view.files.subtitle:find("(2/2)", 1, true), view.files.subtitle)
    local remote = api.nvim_win_get_buf(view.layout.wins.remote)
    H.eq(api.nvim_buf_get_lines(remote, 0, 1, false), { "T2" }, "the second commit's side")
    local t2 = vim.trim(H.git(dir, { "rev-parse", "--short=7", "topic" }))
    H.ok(vim.wo[view.layout.wins.remote].winbar:find(t2 .. " t2", 1, true), vim.wo[view.layout.wins.remote].winbar)
    -- (t2's BASE: t1)
    H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(view.layout.wins.merged), 0, 1, false), { "T1" }, "its BASE text")
    menu(view, "Abort")
    H.ok(finished(), "git finished")
    H.eq({ vim.bo[buf].modified, api.nvim_buf_get_lines(buf, 0, 1, false) }, { false, { "T2" } }, "as on disk")
  end)

  H.it("a rebase stopped to edit: no skip, a new commit of what is staged offered", function()
    local dir = repo()
    H.git(dir, { "checkout", "-q", "topic" })
    local base = vim.trim(H.git(dir, { "rev-parse", "HEAD~2" }))
    -- (edit the first commit)
    vim.system({ "git", "rebase", "-i", base }, {
      cwd = dir,
      env = { GIT_SEQUENCE_EDITOR = "sed -i 1s/^pick/edit/" },
    }):wait()
    local view = open()
    H.ok(view.files.subtitle:find("c abort", 1, true), view.files.subtitle)
    local offered = menu(view, "nothing")
    H.eq(offered, { "Continue the rebase", "Commit what is staged (a new commit)", "Abort the rebase" })
    H.write(dir, "split.txt", { "part" })
    H.git(dir, { "add", "split.txt" })
    menu(view, "Commit what")
    local win = message_win()
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, 0, false, { "the split part" })
    write_message(win)
    H.eq(vim.trim(H.git(dir, { "log", "-1", "--format=%s" })), "the split part")
    H.ok(H.git(dir, { "show", "--name-only", "--format=", "HEAD" }):find("split.txt", 1, true), "a new commit of it")
    view:dispatch("commit", { buf = view.files.buf, win = view.layout.files_win })
    H.ok(finished(), "git finished")
    H.eq(vim.uv.fs_stat(dir .. "/.git/rebase-merge"), nil, "continued to the end")
  end)

  H.it("resolved elsewhere: what DiffMerge showed is not an unsaved edit; git am; a rebase being set up", function()
    local dir = repo()
    vim.system({ "git", "merge", "-q", "topic" }, { cwd = dir }):wait()
    local view = open()
    local buf = api.nvim_win_get_buf(view.layout.wins.merged)
    H.ok(vim.bo[buf].modified, "the conflict shown (its BASE text, unsaved)")
    H.git(dir, { "checkout", "--theirs", "f.txt" })
    H.git(dir, { "add", "f.txt" })
    view:refresh()
    local said = said_by(function()
      press(view, "commit")
      write_message(message_win())
    end)
    H.ok(not said:find("unsaved", 1, true), said)
    H.eq(going_on(dir, "MERGE_HEAD"), false, "merged")
    H.eq({ vim.bo[buf].modified, api.nvim_buf_get_lines(buf, 0, 1, false) }, { false, { "T2" } }, "read anew")
    -- git am of a patch that does not apply
    H.git(dir, { "reset", "-q", "--hard", "HEAD~1" })
    local patch = H.git(dir, { "format-patch", "-1", "--stdout", "topic~1" })
    vim.system({ "git", "am", "-q", "-3" }, { cwd = dir, stdin = patch }):wait()
    H.ok(going_on(dir, "rebase-apply/applying"), "git am stopped")
    view:refresh()
    H.ok(view.files.subtitle:find("APPLYING PATCHES (1/1)", 1, true), view.files.subtitle)
    menu(view, "Abort the git am")
    H.ok(finished(), "git finished")
    H.eq(going_on(dir, "rebase-apply"), false, "aborted")
    -- the todo list of a rebase -i still being written
    vim.fn.mkdir(dir .. "/.git/rebase-merge", "p")
    H.write(dir, ".git/rebase-merge/head-name", { "refs/heads/master" })
    H.write(dir, ".git/rebase-merge/onto", { vim.trim(H.git(dir, { "rev-parse", "HEAD" })) })
    said = said_by(function()
      vim.cmd("DiffMerge continue")
    end)
    H.ok(said:find("being set up", 1, true), said)
    vim.fn.delete(dir .. "/.git/rebase-merge", "rf")
  end)

  H.it("aborted from the MERGED window: no conflict left on screen; only the edits git writes over go", function()
    local dir = repo()
    H.git(dir, { "checkout", "-q", "topic" })
    H.commit(dir, "t3", { ["f.txt"] = { "T3", "b", "c" }, ["g.txt"] = { "g from t3" } })
    H.git(dir, { "checkout", "-q", "master" })
    H.write(dir, "h.txt", { "h" })
    H.git(dir, { "add", "h.txt" })
    H.git(dir, { "commit", "-q", "-m", "h" })
    vim.system({ "git", "cherry-pick", "topic" }, { cwd = dir }):wait()
    local view = open()
    local g = vim.fn.bufadd(dir .. "/g.txt")
    vim.fn.bufload(g)
    api.nvim_buf_set_lines(g, 0, -1, false, { "my g" })
    local h = vim.fn.bufadd(dir .. "/h.txt")
    vim.fn.bufload(h)
    api.nvim_buf_set_lines(h, 0, -1, false, { "my h" })
    api.nvim_set_current_win(view.layout.wins.merged)
    asked = {}
    vim.cmd("DiffMerge abort")
    H.ok(finished(), "git finished")
    H.ok(asked[1]:find("Unsaved edits in g.txt are lost", 1, true) and not asked[1]:find("h.txt", 1, true), vim.inspect(asked))
    H.eq({ view.merge, view.current }, { nil, nil }, "no conflict shown")
    H.eq(vim.uv.fs_stat(dir .. "/g.txt"), nil, "gone with the cherry-pick")
    H.eq({ vim.bo[h].modified, api.nvim_buf_get_lines(h, 0, -1, false) }, { true, { "my h" } }, "not git's: kept")
  end)

  H.it("a message rejected by a hook comes back for a commit, not for an amend", function()
    local dir = repo()
    H.write(dir, ".git/hooks/commit-msg", { "#!/bin/sh", "grep -q bad \"$1\" && exit 1", "exit 0" })
    vim.uv.fs_chmod(dir .. "/.git/hooks/commit-msg", 493)
    H.write(dir, "n.txt", { "n" })
    H.git(dir, { "add", "n.txt" })
    local view = open()
    press(view, "commit")
    local win = message_win()
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, 0, false, { "a bad message" })
    write_message(win)
    H.ok(vim.trim(H.git(dir, { "log", "-1", "--format=%s" })) ~= "a bad message", "rejected")
    press(view, "commit_amend")
    win = message_win()
    H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false), { "m" }, "the last commit's message")
    api.nvim_set_current_win(win)
    api.nvim_feedkeys(api.nvim_replace_termcodes(":q!<CR>", true, false, true), "xt", false)
    H.ok(finished(), "git finished")
    press(view, "commit")
    win = message_win()
    H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false), { "a bad message" }, "offered again")
    api.nvim_set_current_win(win)
    api.nvim_feedkeys(api.nvim_replace_termcodes(":q!<CR>", true, false, true), "xt", false)
    H.ok(finished(), "git finished")
  end)

  H.it("a rebase being set up: the c menu and an amend wait; between two commits of a cherry-pick", function()
    local dir = repo()
    vim.fn.mkdir(dir .. "/.git/rebase-merge", "p")
    H.write(dir, ".git/rebase-merge/head-name", { "refs/heads/master" })
    H.write(dir, ".git/rebase-merge/onto", { vim.trim(H.git(dir, { "rev-parse", "HEAD" })) })
    local view = open()
    local offered
    local said = said_by(function()
      offered = menu(view, "Commit")
      press(view, "commit_amend")
    end)
    H.eq(offered, {})
    H.ok(select(2, said:gsub("being set up", "")) == 2, said)
    vim.fn.delete(dir .. "/.git/rebase-merge", "rf")
    -- t1, t2 picked; t1 in conflict, committed by hand
    vim.system({ "git", "cherry-pick", "topic~1", "topic" }, { cwd = dir }):wait()
    resolve(dir, { "M T1", "b", "c" })
    H.git(dir, { "commit", "-q", "--no-edit" })
    view:refresh()
    H.ok(view.files.subtitle:find("CHERRY-PICKING (between two commits)", 1, true), view.files.subtitle)
    H.eq(menu(view, "nothing"), { "Continue the cherry-pick", "Abort the cherry-pick" })
  end)

  H.it("a rebase aborted: files it writes back named (also ones only master changed)", function()
    local dir = repo()
    H.commit(dir, "g on master", { ["g.txt"] = { "gm" } })
    H.git(dir, { "checkout", "-q", "topic" })
    vim.system({ "git", "rebase", "master" }, { cwd = dir }):wait()
    local view = open()
    local g = vim.fn.bufadd(dir .. "/g.txt")
    vim.fn.bufload(g)
    api.nvim_buf_set_lines(g, 0, -1, false, { "gm + my edit" })
    asked = {}
    menu(view, "Abort")
    H.ok(finished(), "git finished")
    H.ok(asked[1]:find("Unsaved edits in g.txt are lost", 1, true), vim.inspect(asked))
    H.eq(vim.bo[g].modified, false, "read anew (topic has no g.txt)")
  end)

  H.it("a message git committed before it stopped is not offered again (a rebase's next conflict)", function()
    local dir = H.repo({ ["f.txt"] = { "a", "b", "c" } })
    H.git(dir, { "branch", "-m", "master" })
    H.git(dir, { "checkout", "-q", "-b", "topic" })
    H.commit(dir, "WIP", { ["f.txt"] = { "T1", "b", "c" } })
    H.commit(dir, "WIP", { ["f.txt"] = { "T2", "b", "c" } })
    H.git(dir, { "checkout", "-q", "master" })
    H.commit(dir, "m", { ["f.txt"] = { "M", "b", "c" } })
    H.git(dir, { "checkout", "-q", "topic" })
    vim.cmd.cd(dir)
    vim.system({ "git", "rebase", "master" }, { cwd = dir }):wait()
    local view = open()
    resolve(dir, { "M T1", "b", "c" })
    view:refresh()
    press(view, "commit")
    local win = message_win()
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, 1, false, { "Add parser" })
    write_message(win)
    view:refresh()
    resolve(dir, { "M T2", "b", "c" })
    view:refresh()
    press(view, "commit")
    win = message_win()
    H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false), { "WIP" }, "git's message")
    write_message(win)
    H.eq(vim.trim(H.git(dir, { "log", "--format=%s", "-2" })), "WIP\nAdd parser")
  end)
end)

H.done()
