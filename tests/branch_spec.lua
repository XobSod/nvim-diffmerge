-- Switching branches from the status view (b) and :DiffMerge switch.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local git = require("diffmerge.git")
local remote = require("diffmerge.remote")

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

--- origin (bare) and mine: master, topic (local, f.txt "topic"), feat (only on origin).
local function setup()
  local seed = H.repo({ ["f.txt"] = { "a", "b", "c" } })
  H.git(seed, { "branch", "-m", "master" })
  H.git(seed, { "checkout", "-q", "-b", "feat" })
  H.commit(seed, "feat", { ["feat.txt"] = { "feat" } })
  H.git(seed, { "checkout", "-q", "master" })
  local top = H.tmpdir()
  local origin, mine = top .. "/origin.git", top .. "/mine"
  H.git(top, { "clone", "-q", "--bare", seed, origin })
  H.git(top, { "clone", "-q", origin, mine })
  H.git(mine, { "checkout", "-q", "-b", "topic" })
  H.commit(mine, "topic", { ["f.txt"] = { "topic", "b", "c" } })
  H.git(mine, { "checkout", "-q", "master" })
  vim.cmd.cd(mine)
  return origin, mine
end

local function open()
  local view = require("diffmerge").status()
  api.nvim_set_current_win(view.layout.files_win)
  return view
end

local function finished(dir)
  local repo = git.find_repo(dir)
  return vim.wait(10000, function()
    return not remote.running(repo)
  end, 20)
end

--- `b` with the picker answering the choice whose label contains `text` (and `name` for a new
--- branch); what was said.
local function pick(view, dir, text, name)
  local said, labels = {}, {}
  local notify, select, input = vim.notify, vim.ui.select, vim.ui.input
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do
      labels[#labels + 1] = opts.format_item(it)
    end
    for _, it in ipairs(items) do
      if opts.format_item(it):find(text, 1, true) then
        return cb(it)
      end
    end
    cb(nil)
  end
  vim.ui.input = function(_, cb)
    cb(name)
  end
  local ok, err = pcall(function()
    view:dispatch("branch", { buf = view.files.buf, win = view.layout.files_win })
    H.flush(50)
    H.ok(finished(dir), "git finished")
    H.flush(50)
  end)
  vim.notify, vim.ui.select, vim.ui.input = notify, select, input
  assert(ok, err)
  return table.concat(said, "\n"), labels
end

local function current(dir)
  return (vim.trim(H.git(dir, { "symbolic-ref", "HEAD" })):gsub("^refs/heads/", ""))
end

H.describe("switching branches", function()
  H.it("the picker: local branches, the current one marked, remote ones not here yet, a new one", function()
    local _, mine = setup()
    local view = open()
    local _, labels = pick(view, mine, "nothing like this")
    -- (most recent first: topic is newer, or of the same second)
    H.ok(vim.iter(labels):any(function(l)
      return l:match("^%* master")
    end), vim.inspect(labels))
    H.ok(vim.iter(labels):any(function(l)
      return l:match("^  topic")
    end), vim.inspect(labels))
    H.ok(vim.iter(labels):any(function(l)
      return l:find("origin/feat  (remote", 1, true)
    end), vim.inspect(labels))
    H.ok(not vim.iter(labels):any(function(l)
      return l:find("origin/master", 1, true) or l:find("origin/HEAD", 1, true)
    end), "no remote branch that is here already: " .. vim.inspect(labels))
    H.eq(labels[#labels], "+ a new branch from here")
  end)

  H.it("to a local branch: files and their buffers follow", function()
    local _, mine = setup()
    vim.cmd.edit(mine .. "/f.txt")
    local buf = api.nvim_get_current_buf()
    local view = open()
    local said = pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(said:find("switched to topic", 1, true), said)
    H.eq(H.buf_lines(buf), { "topic", "b", "c" })
  end)

  H.it("to a remote branch: a local branch tracking it", function()
    local _, mine = setup()
    local view = open()
    pick(view, mine, "origin/feat")
    H.eq(current(mine), "feat")
    H.eq(vim.trim(H.git(mine, { "rev-parse", "--abbrev-ref", "feat@{u}" })), "origin/feat")
  end)

  H.it("a new branch from here; a name git does not take is refused", function()
    local _, mine = setup()
    local view = open()
    local said = pick(view, mine, "a new branch", "bad name..")
    H.ok(said:find("not a branch name", 1, true), said)
    H.eq(current(mine), "master")
    pick(view, mine, "a new branch", "new-thing")
    H.eq(current(mine), "new-thing")
  end)

  H.it("changes in the way: stashed, switched, brought back (staged stays staged); or not", function()
    local _, mine = setup()
    -- f.txt: a b c on master, topic b c on topic; the staged change far from topic's
    H.git(mine, { "checkout", "-q", "topic" })
    H.commit(mine, "longer", { ["f.txt"] = { "topic", "b", "c", "d", "e", "f", "g", "h" } })
    H.git(mine, { "checkout", "-q", "master" })
    H.commit(mine, "longer", { ["f.txt"] = { "a", "b", "c", "d", "e", "f", "g", "h" } })
    H.write(mine, "f.txt", { "a", "b", "c", "d", "e", "f", "G", "h" })
    H.git(mine, { "add", "f.txt" })
    H.write(mine, "f.txt", { "a", "b", "c", "d", "e", "f", "G", "H" })
    local view = open()
    asked, confirm_answer = {}, 2
    local said = pick(view, mine, "topic")
    H.ok(table.concat(asked, "\n"):find("Stash them, switch to topic", 1, true), vim.inspect(asked))
    H.eq(current(mine), "master", "declined")
    H.eq(H.read(mine, "f.txt"), "a\nb\nc\nd\ne\nf\nG\nH\n")
    asked, confirm_answer = {}, 1
    said = pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(said:find("your changes with you", 1, true), said)
    H.eq(H.read(mine, "f.txt"), "topic\nb\nc\nd\ne\nf\nG\nH\n")
    H.eq(H.git(mine, { "show", ":f.txt" }), "topic\nb\nc\nd\ne\nf\nG\nh\n", "the staged part staged")
    H.eq(H.git(mine, { "stash", "list" }), "")
  end)

  H.it("a staged change that does not fit the index there: brought back unstaged, and said so", function()
    local _, mine = setup()
    H.write(mine, "f.txt", { "a", "b", "C" })
    H.git(mine, { "add", "f.txt" })
    local view = open()
    asked, confirm_answer = {}, 1
    local said = pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(said:find("what was staged is unstaged now", 1, true), said)
    H.eq(H.read(mine, "f.txt"), "topic\nb\nC\n")
  end)

  H.it("changes that do not fit there: under Conflicts, the stash kept", function()
    local _, mine = setup()
    H.write(mine, "f.txt", { "MINE", "b", "c" })
    local view = open()
    asked, confirm_answer = {}, 1
    local said = pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(said:find("resolve them under Conflicts", 1, true), said)
    H.ok(H.find_entry(view, "conflicts", "f.txt"), "listed under Conflicts")
    H.ok(H.git(mine, { "stash", "list" }):find("DiffMerge: switching to topic", 1, true), "stash kept")
  end)

  H.it("unsaved files and a merge in progress come first", function()
    local _, mine = setup()
    vim.cmd.edit(mine .. "/f.txt")
    api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved" })
    local view = open()
    local said = pick(view, mine, "topic")
    H.ok(said:find("unsaved changes in f.txt", 1, true), said)
    H.eq(current(mine), "master")
    api.nvim_buf_call(vim.fn.bufnr(mine .. "/f.txt"), function()
      vim.cmd("silent edit!")
    end)
    H.write(mine, ".git/MERGE_HEAD", { H.git(mine, { "rev-parse", "topic" }) })
    said = pick(view, mine, "topic")
    H.ok(said:find("a merge is in progress", 1, true), said)
    os.remove(mine .. "/.git/MERGE_HEAD")
  end)

  H.it(":DiffMerge switch passes its arguments", function()
    local _, mine = setup()
    vim.cmd("DiffMerge switch topic")
    H.ok(finished(mine), "git finished")
    H.eq(current(mine), "topic")
    vim.cmd("DiffMerge switch -c other")
    H.ok(finished(mine), "git finished")
    H.eq(current(mine), "other")
  end)
  H.it("nothing could be stashed: not switched, your own stashes untouched", function()
    local _, mine = setup()
    H.write(mine, "g.txt", { "mine" })
    H.git(mine, { "stash", "push", "-q", "-u", "-m", "MY OWN OLD STASH" })
    H.git(mine, { "update-index", "--skip-worktree", "f.txt" })
    H.write(mine, "f.txt", { "local config", "b", "c" })
    local view = open()
    asked, confirm_answer = {}, 1
    local said = pick(view, mine, "topic")
    H.eq(current(mine), "master")
    H.ok(said:find("nothing could be stashed", 1, true), said)
    H.ok(H.git(mine, { "stash", "list" }):find("MY OWN OLD STASH", 1, true), "your stash is still there")
    H.eq(vim.uv.fs_stat(mine .. "/g.txt"), nil, "and not popped")
  end)

  H.it("untracked files in the way: named, nothing stashed", function()
    local _, mine = setup()
    H.git(mine, { "checkout", "-q", "topic" })
    H.commit(mine, "t", { ["t.txt"] = { "topic's" } })
    H.git(mine, { "checkout", "-q", "master" })
    H.write(mine, "t.txt", { "mine, untracked" })
    local view = open()
    asked = {}
    local said = pick(view, mine, "topic")
    H.eq(asked, {}, "no question")
    H.ok(said:find("topic has its own t.txt: move it away first", 1, true), said)
    H.eq(current(mine), "master")
    H.eq(H.git(mine, { "stash", "list" }), "")
  end)

  H.it("a stopped switch is not a switch; a failing post-checkout hook still is", function()
    local _, mine = setup()
    H.git(mine, { "config", "filter.slow.smudge", "sleep 3; cat" })
    H.git(mine, { "config", "filter.slow.clean", "cat" })
    H.git(mine, { "checkout", "-q", "topic" })
    H.commit(mine, "slow", { [".gitattributes"] = { "*.slow filter=slow" }, ["x.slow"] = { "x" } })
    H.git(mine, { "checkout", "-q", "master" })
    local view = open()
    local said = {}
    local notify, select = vim.notify, vim.ui.select
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    vim.ui.select = function(items, opts, cb)
      for _, it in ipairs(items) do
        if opts.format_item(it):find("topic", 1, true) then
          return cb(it)
        end
      end
    end
    view:dispatch("branch", { buf = view.files.buf, win = view.layout.files_win })
    vim.wait(800)
    asked, confirm_answer = {}, 1
    view:dispatch("branch", { buf = view.files.buf, win = view.layout.files_win })
    H.ok(finished(mine), "stopped")
    vim.notify, vim.ui.select = notify, select
    H.ok(table.concat(asked, "\n"):find("half updated", 1, true), vim.inspect(asked))
    H.ok(not table.concat(said, "\n"):find("switched to topic", 1, true), vim.inspect(said))
    -- a post-checkout hook that fails: switched all the same, and what it said
    H.git(mine, { "checkout", "-q", "-f", "master" })
    H.git(mine, { "clean", "-q", "-fd" })
    H.git(mine, { "config", "--unset", "filter.slow.smudge" })
    H.write(mine, ".git/hooks/post-checkout", { "#!/bin/sh", "echo 'hook says no' >&2", "exit 1" })
    vim.uv.fs_chmod(mine .. "/.git/hooks/post-checkout", 493)
    view:refresh()
    local text = pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(text:find("hook says no", 1, true) and text:find("switched to topic", 1, true), text)
  end)

  H.it("b while a fetch runs offers to stop it; the picker waits for a merge", function()
    local _, mine = setup()
    local view = open()
    remote.run(git.find_repo(mine), "fetch", {}, function() end)
    asked, confirm_answer = {}, 2
    local opened = false
    local select = vim.ui.select
    vim.ui.select = function()
      opened = true
    end
    view:dispatch("branch", { buf = view.files.buf, win = view.layout.files_win })
    H.ok(table.concat(asked, "\n"):find("git fetch is still running. Stop it?", 1, true), vim.inspect(asked))
    H.ok(finished(mine), "fetch finished")
    H.write(mine, ".git/MERGE_HEAD", { H.git(mine, { "rev-parse", "topic" }) })
    local said = {}
    local notify = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    view:dispatch("branch", { buf = view.files.buf, win = view.layout.files_win })
    vim.notify, vim.ui.select = notify, select
    os.remove(mine .. "/.git/MERGE_HEAD")
    H.eq(opened, false, "no picker")
    H.ok(table.concat(said, "\n"):find("a merge is in progress", 1, true), vim.inspect(said))
  end)

  H.it("names: a tag like a branch, -c with a start; buffers of files gone; the log follows", function()
    local _, mine = setup()
    H.git(mine, { "tag", "topic", "master" })
    H.git(mine, { "checkout", "-q", "topic" })
    H.commit(mine, "only here", { ["only.txt"] = { "only on topic" } })
    H.git(mine, { "checkout", "-q", "master" })
    vim.cmd("DiffMerge log")
    local log = require("diffmerge").current()
    local log_head = log.head
    local view = open()
    local _, labels = pick(view, mine, "  topic")
    H.ok(vim.tbl_contains(labels, labels[2]) and not table.concat(labels, "\n"):find("heads/", 1, true), vim.inspect(labels))
    H.eq(current(mine), "topic")
    H.ok(log.head ~= log_head, "the log view reloaded")
    local buf = vim.fn.bufadd(mine .. "/only.txt")
    vim.fn.bufload(buf)
    local said = pick(view, mine, "* topic")
    H.ok(said:find("already on topic", 1, true), said)
    vim.cmd("DiffMerge switch -c fresh master")
    H.ok(finished(mine), "git finished")
    H.eq(current(mine), "fresh")
    H.eq(api.nvim_buf_is_valid(buf), false, "the buffer of a file gone went too")
  end)
  H.it("the buffer of a file with a tab, a quote and a backslash in its name goes with it", function()
    local _, mine = setup()
    local name = 'we"ird\tna\\me.txt'
    H.commit(mine, "weird", { [name] = { "only on master" } })
    local buf = vim.fn.bufadd(mine .. "/" .. name)
    vim.fn.bufload(buf)
    local view = open()
    pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(not api.nvim_buf_is_valid(buf), "the switch took the file away: its buffer goes too")
  end)

  H.it("only the buffers of files the switch took away go; -C onto another commit is a switch", function()
    local _, mine = setup()
    H.write(mine, "notes.txt", { "only copy" })
    local notes = vim.fn.bufadd(mine .. "/notes.txt")
    vim.fn.bufload(notes)
    os.remove(mine .. "/notes.txt")
    local unsaved_new = vim.fn.bufadd(mine .. "/brand-new.txt")
    vim.fn.bufload(unsaved_new)
    local view = open()
    pick(view, mine, "topic")
    H.eq(current(mine), "topic")
    H.ok(api.nvim_buf_is_valid(notes), "a buffer of a file deleted elsewhere stays")
    H.ok(api.nvim_buf_is_valid(unsaved_new), "a new file never written stays")
    -- on work, -C work topic: the same name, another commit
    H.git(mine, { "checkout", "-q", "-b", "work", "master" })
    -- (shown in a window: hidden buffers are reloaded when shown again)
    vim.cmd("tabnew " .. mine .. "/f.txt")
    local f = api.nvim_get_current_buf()
    vim.cmd("checktime")
    H.eq(H.buf_lines(f), { "a", "b", "c" })
    vim.cmd("DiffMerge switch -C work topic")
    H.ok(finished(mine), "git finished")
    H.flush(50)
    H.eq({ current(mine), H.read(mine, "f.txt") }, { "work", "topic\nb\nc\n" }, "switched")
    H.eq(H.buf_lines(f), { "topic", "b", "c" }, "the buffer followed")
  end)

  H.it("the branch named in the question: --track -c name remote/branch", function()
    local _, mine = setup()
    H.write(mine, "f.txt", { "changed", "b", "c" })
    H.git(mine, { "checkout", "-q", "-b", "elsewhere" })
    H.commit(mine, "elsewhere", { ["f.txt"] = { "else", "b", "c" } })
    H.git(mine, { "checkout", "-q", "master" })
    H.write(mine, "f.txt", { "changed", "b", "c" })
    asked, confirm_answer = {}, 2
    vim.cmd("DiffMerge switch -c mine-elsewhere elsewhere")
    H.ok(finished(mine), "git finished")
    H.ok(table.concat(asked, "\n"):find("switch to mine-elsewhere,", 1, true), vim.inspect(asked))
  end)
end)

--- The log view of mine, loaded.
local function open_log()
  local view = require("diffmerge").log()
  vim.wait(5000, function()
    return not view.log.loading and view.current ~= nil
  end, 10)
  H.ok(not view.log.loading, "log loaded")
  return view
end

--- `b` on the log row of `sha`, the menu answering the choice whose label contains `text` (and
--- `name` for a new branch): what was said, the labels, the menu's prompt (nil: no menu).
local function checkout(view, dir, sha, text, name)
  local said, labels, prompt = {}, {}, nil
  local notify, select, input = vim.notify, vim.ui.select, vim.ui.input
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  vim.ui.select = function(items, opts, cb)
    prompt = opts.prompt
    for _, it in ipairs(items) do
      labels[#labels + 1] = opts.format_item(it)
    end
    for _, it in ipairs(items) do
      if text and opts.format_item(it):find(text, 1, true) then
        return cb(it)
      end
    end
    cb(nil)
  end
  vim.ui.input = function(_, cb)
    cb(name)
  end
  local ok, err = pcall(function()
    vim.wait(5000, function()
      return not view.log.loading and view.log.by_sha[sha] ~= nil
    end, 10)
    local line = view.log.by_sha[sha]
    H.ok(line, "the commit is in the log")
    api.nvim_set_current_win(view.layout.log_win)
    api.nvim_win_set_cursor(view.layout.log_win, { line, 0 })
    view:dispatch("checkout", { buf = view.log.buf, win = view.layout.log_win })
    H.flush(50)
    H.ok(finished(dir), "git finished")
    H.flush(50)
  end)
  vim.notify, vim.ui.select, vim.ui.input = notify, select, input
  assert(ok, err)
  return table.concat(said, "\n"), labels, prompt
end

local function rev(dir, what)
  return vim.trim(H.git(dir, { "rev-parse", what }))
end

H.describe("checking out a commit of the log", function()
  H.it("the tip of a local branch: that branch, no menu; the current one: already on it", function()
    local _, mine = setup()
    local view = open_log()
    local said, _, prompt = checkout(view, mine, rev(mine, "topic"))
    H.eq(prompt, nil, "no menu")
    H.eq(current(mine), "topic")
    H.ok(said:find("switched to topic", 1, true), said)
    H.eq(view.head, rev(mine, "topic"), "the log followed")
    said, _, prompt = checkout(view, mine, rev(mine, "topic"))
    H.eq(prompt, nil, "no menu")
    H.ok(said:find("already on topic", 1, true), said)
    H.git(mine, { "checkout", "-q", "--detach", "topic" })
    _, _, prompt = checkout(view, mine, rev(mine, "topic"))
    H.eq({ prompt, current(mine) }, { nil, "topic" }, "detached at its tip: the branch")
  end)

  H.it("several local branches there: which one", function()
    local _, mine = setup()
    H.git(mine, { "branch", "twin", "topic" })
    local view = open_log()
    local _, labels, prompt = checkout(view, mine, rev(mine, "topic"), "twin")
    H.eq(prompt, ("Switch to (at %s)"):format(rev(mine, "topic"):sub(1, 7)))
    H.eq(labels, { "  topic", "  twin" })
    H.eq(current(mine), "twin")
    local said
    said, labels = checkout(view, mine, rev(mine, "topic"), "* twin")
    H.eq(labels, { "  topic", "* twin" })
    H.ok(said:find("already on twin", 1, true), said)
  end)

  H.it("a remote branch only: a local branch following it (first), detached, a new branch", function()
    local _, mine = setup()
    local feat = rev(mine, "origin/feat")
    -- not origin/HEAD; a tag of the same name does not get in the way
    H.git(mine, { "remote", "set-head", "origin", "feat" })
    H.git(mine, { "tag", "origin/feat", "master" })
    local short = feat:sub(1, 7)
    local view = open_log()
    local _, labels, prompt = checkout(view, mine, feat)
    H.eq(prompt, "Check out " .. short)
    H.eq(labels, { "feat, following origin/feat", short .. ", detached (no branch)", "+ a new branch at " .. short })
    H.eq(current(mine), "master", "nothing chosen")
    checkout(view, mine, feat, "following")
    H.eq({ current(mine), rev(mine, "HEAD") }, { "feat", feat })
    H.eq(H.git(mine, { "config", "branch.feat.merge" }), "refs/heads/feat\n")
    H.eq(H.git(mine, { "config", "branch.feat.remote" }), "origin\n")
  end)

  H.it("a branch checked out in another worktree: named, not offered", function()
    local _, mine = setup()
    local tip = rev(mine, "topic")
    local short = tip:sub(1, 7)
    local wt = vim.fs.dirname(mine) .. "/wt"
    H.git(mine, { "worktree", "add", "-q", wt, "topic" })
    local view = open_log()
    local _, labels, prompt = checkout(view, mine, tip, "detached")
    H.ok(prompt:find("topic is checked out in " .. vim.fn.fnamemodify(wt, ":~"), 1, true), prompt)
    H.eq(labels, { short .. ", detached (no branch)", "+ a new branch at " .. short })
    H.eq(rev(mine, "HEAD"), tip)
    H.git(mine, { "switch", "-q", "master" })
    H.git(mine, { "branch", "twin", "topic" })
    _, _, prompt = checkout(view, mine, tip)
    H.eq({ prompt, current(mine) }, { nil, "twin" }, "the one branch there that can be")
  end)

  H.it("a merge in progress comes first; a switch that fails leaves the log as it was", function()
    local _, mine = setup()
    local view = open_log()
    H.write(mine, ".git/MERGE_HEAD", { rev(mine, "topic") })
    local said, _, prompt = checkout(view, mine, rev(mine, "origin/feat"))
    os.remove(mine .. "/.git/MERGE_HEAD")
    H.eq(prompt, nil, "no menu")
    H.ok(said:find("a merge is in progress", 1, true), said)
    api.nvim_set_current_win(view.layout.log_win)
    api.nvim_win_set_cursor(view.layout.log_win, { view.log.by_sha[rev(mine, "topic")], 0 })
    view:dispatch("mark", { buf = view.log.buf, win = view.layout.log_win })
    H.eq(#view.marks, 1)
    H.write(mine, "feat.txt", { "mine, untracked" })
    said = checkout(view, mine, rev(mine, "origin/feat"), "following")
    H.ok(said:find("move it away first", 1, true), said)
    H.eq(current(mine), "master")
    H.eq(#view.marks, 1, "the log kept its mark")
  end)

  H.it("a remote branch whose name is a local branch elsewhere: not offered to follow", function()
    local _, mine = setup()
    local older = rev(mine, "master")
    H.git(mine, { "update-ref", "refs/remotes/origin/topic", older })
    H.git(mine, { "checkout", "-q", "topic" })
    local view = open_log()
    local _, labels = checkout(view, mine, rev(mine, "origin/topic"))
    -- (master is there: switching to it)
    H.eq(labels, {})
    H.eq(current(mine), "master")
    H.git(mine, { "checkout", "-q", "topic" })
    local behind = H.commit(mine, "more", { ["more.txt"] = { "more" } })
    H.git(mine, { "update-ref", "refs/remotes/origin/topic", behind })
    H.commit(mine, "even more", { ["more.txt"] = { "even more" } })
    view = open_log()
    local short = behind:sub(1, 7)
    _, labels = checkout(view, mine, behind)
    H.eq(labels, { short .. ", detached (no branch)", "+ a new branch at " .. short })
  end)

  H.it("any other commit: detached, then a new branch there (not detached again)", function()
    local _, mine = setup()
    local first = rev(mine, "topic")
    H.git(mine, { "checkout", "-q", "topic" })
    local inner = H.commit(mine, "inner", { ["inner.txt"] = { "inner" } })
    H.commit(mine, "tip", { ["tip.txt"] = { "tip" } })
    local short = inner:sub(1, 7)
    local view = open_log()
    local said, labels = checkout(view, mine, inner, "detached")
    H.eq(labels, { short .. ", detached (no branch)", "+ a new branch at " .. short })
    H.eq(vim.trim(H.git(mine, { "rev-parse", "--abbrev-ref", "HEAD" })), "HEAD", "detached")
    H.eq(rev(mine, "HEAD"), inner)
    H.ok(said:find("switched to " .. short, 1, true), said)
    said, labels = checkout(view, mine, inner, "+ a new branch", "bad..name")
    H.eq(labels, { "+ a new branch at " .. short }, "already there: not offered")
    H.ok(said:find("not a branch name", 1, true), said)
    checkout(view, mine, inner, "+ a new branch", "from-inner")
    H.eq({ current(mine), rev(mine, "HEAD") }, { "from-inner", inner })
    checkout(view, mine, first, "+ a new branch", "from-first")
    H.eq({ current(mine), rev(mine, "HEAD") }, { "from-first", first }, "-c name sha: at that commit")
  end)

  H.it("changes in the way: the question names the commit; Working tree / Index rows: the picker", function()
    local _, mine = setup()
    H.git(mine, { "checkout", "-q", "topic" })
    local inner = H.commit(mine, "inner", { ["f.txt"] = { "inner", "b", "c", "d", "e", "f", "g", "h" } })
    H.commit(mine, "tip", { ["f.txt"] = { "tip", "b", "c", "d", "e", "f", "g", "h" } })
    H.write(mine, "f.txt", { "tip", "b", "c", "d", "e", "f", "g", "CHANGED" })
    local view = open_log()
    asked, confirm_answer = {}, 1
    local said = checkout(view, mine, inner, "detached")
    local question = table.concat(asked, "\n")
    H.ok(question:find("Stash them, switch to " .. inner:sub(1, 7) .. ",", 1, true), question)
    H.eq(rev(mine, "HEAD"), inner)
    H.eq(H.read(mine, "f.txt"), "inner\nb\nc\nd\ne\nf\ng\nCHANGED\n")
    H.ok(said:find("your changes with you", 1, true), said)
    local prompts = {}
    local select = vim.ui.select
    vim.ui.select = function(_, opts)
      prompts[#prompts + 1] = opts.prompt
    end
    for _, line in ipairs({ 1, 2 }) do
      api.nvim_set_current_win(view.layout.log_win)
      api.nvim_win_set_cursor(view.layout.log_win, { line, 0 })
      view:dispatch("checkout", { buf = view.log.buf, win = view.layout.log_win })
    end
    vim.ui.select = select
    H.eq(prompts, { "Switch to", "Switch to" })
    H.eq(rev(mine, "HEAD"), inner)
  end)
end)

H.done()
