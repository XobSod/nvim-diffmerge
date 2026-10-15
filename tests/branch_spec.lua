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
    H.ok(labels[1]:match("^%* master"), labels[1])
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

H.done()
