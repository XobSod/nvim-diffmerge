-- Fetch, pull and push from the status view, against a real (bare) remote.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local git = require("diffmerge.git")
local remote = require("diffmerge.remote")

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

--- origin (bare), mine (where the view is) and theirs (someone else), all on master.
local function setup()
  local seed = H.repo({ ["f.txt"] = { "a", "b", "c" } })
  H.git(seed, { "branch", "-m", "master" })
  local top = H.tmpdir()
  local origin, mine, theirs = top .. "/origin.git", top .. "/mine", top .. "/theirs"
  H.git(top, { "clone", "-q", "--bare", seed, origin })
  H.git(top, { "clone", "-q", origin, mine })
  H.git(top, { "clone", "-q", origin, theirs })
  vim.cmd.cd(mine)
  return origin, mine, theirs
end

local function open()
  local view = require("diffmerge").status()
  api.nvim_set_current_win(view.layout.files_win)
  return view
end

local function finished(dir)
  local repo = git.find_repo(dir)
  return vim.wait(15000, function()
    return not remote.running(repo)
  end, 20)
end

local function press(view, action, dir)
  local said = {}
  local notify = vim.notify
  vim.notify = function(msg)
    said[#said + 1] = msg
  end
  local ok, err = pcall(function()
    api.nvim_set_current_win(view.layout.files_win)
    view:dispatch(action, { buf = view.files.buf, win = view.layout.files_win })
    H.ok(finished(dir), "git finished")
  end)
  vim.notify = notify
  assert(ok, err)
  return table.concat(said, "\n")
end

local function head(dir, rev)
  return vim.trim(H.git(dir, { "rev-parse", rev or "HEAD" }))
end

H.describe("fetch / pull / push", function()
  H.it("F fetches: how far behind, in the message and the title", function()
    local _, mine, theirs = setup()
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    local view = open()
    local said = press(view, "fetch", mine)
    H.ok(said:find("↓1 origin/master", 1, true), said)
    H.ok(view.files.title:find("↓1", 1, true), view.files.title)
  end)

  H.it("p pulls: the files and their buffers follow; unsaved changes come first", function()
    local _, mine, theirs = setup()
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    vim.cmd.edit(mine .. "/f.txt")
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 2, 3, false, { "unsaved" })
    local view = open()
    local said = press(view, "pull", mine)
    H.ok(said:find("unsaved changes in f.txt", 1, true), said)
    H.eq(H.read(mine, "f.txt"), "a\nb\nc\n", "nothing pulled")
    api.nvim_buf_call(buf, function()
      vim.cmd("silent edit!")
    end)
    said = press(view, "pull", mine)
    H.ok(said:find("up to date with origin/master", 1, true), said)
    H.eq(H.read(mine, "f.txt"), "A\nb\nc\n")
    H.eq(H.buf_lines(buf), { "A", "b", "c" })
  end)

  H.it("pull with pull.ff = only: git's refusal when the branches diverged", function()
    local _, mine, theirs = setup()
    H.git(mine, { "config", "pull.ff", "only" })
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    local view = open()
    local said = press(view, "pull", mine)
    H.ok(said:find("Not possible to fast-forward", 1, true), said)
    H.ok(not said:find("hint:", 1, true), "no hints: " .. said)
    H.ok(said:find("↑1 ↓1 origin/master", 1, true), "where it stands: " .. said)
  end)

  H.it("P pushes", function()
    local origin, mine = setup()
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    local view = open()
    local said = press(view, "push", mine)
    H.ok(said:find("master -> master", 1, true), said)
    H.eq(head(origin, "master"), head(mine))
    H.ok(said:find("up to date with origin/master", 1, true), said)
  end)

  H.it("rewritten history (an amend): pushed over with --force-with-lease when asked", function()
    local origin, mine = setup()
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    H.git(mine, { "push", "-q" })
    H.git(mine, { "commit", "-q", "--amend", "-m", "mine, amended" })
    local view = open()
    asked, confirm_answer = {}, 2
    press(view, "push", mine)
    local question = table.concat(asked, "\n")
    H.ok(question:find("master on the remote has commits that are not in yours", 1, true), question)
    H.ok(question:find("--force-with-lease --force-if-includes", 1, true), question)
    H.ok(head(origin, "master") ~= head(mine), "declined: nothing pushed")
    confirm_answer = 1
    press(view, "push", mine)
    H.eq(head(origin, "master"), head(mine))
  end)

  H.it("the remote moved on: not overwritten; fetch first, or only behind: what to do", function()
    local origin, mine, theirs = setup()
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    local view = open()
    -- not fetched: git says "fetch first"
    asked, confirm_answer = {}, 1
    local said = press(view, "push", mine)
    H.eq(asked, {}, "no question")
    H.ok(said:find("F fetches them, p pulls them", 1, true), said)
    -- fetched, but theirs is not in mine: nothing to offer, pull them
    H.git(mine, { "fetch", "-q" })
    local theirs_head = head(origin, "master")
    said = press(view, "push", mine)
    H.eq(asked, {}, "no question")
    H.eq(head(origin, "master"), theirs_head, "theirs kept")
    H.ok(said:find("not in yours: p pulls them", 1, true), said)
    -- only behind: nothing to push over
    H.git(mine, { "reset", "-q", "--hard", "origin/master~1" })
    asked = {}
    said = press(view, "push", mine)
    H.eq(asked, {}, "no question")
    H.eq(head(origin, "master"), theirs_head)
  end)

  H.it("push.default = current: a new branch pushed, then tracked when asked", function()
    local origin, mine = setup()
    H.git(mine, { "config", "push.default", "current" })
    H.git(mine, { "checkout", "-q", "-b", "topic" })
    H.commit(mine, "topic work", { ["g.txt"] = { "g" } })
    local view = open()
    asked, confirm_answer = {}, 1
    local said = press(view, "push", mine)
    H.eq(head(origin, "topic"), head(mine))
    H.ok(table.concat(asked, "\n"):find("Track origin/topic", 1, true), vim.inspect(asked))
    H.eq(vim.trim(H.git(mine, { "rev-parse", "--abbrev-ref", "topic@{u}" })), "origin/topic")
    H.ok(said:find("up to date with origin/topic", 1, true), said)
  end)

  H.it("several remotes and no push destination: which one, asked", function()
    local origin, mine = setup()
    H.git(mine, { "remote", "rename", "origin", "a" })
    H.git(mine, { "remote", "add", "b", origin })
    H.git(mine, { "checkout", "-q", "-b", "topic" })
    H.commit(mine, "topic work", { ["g.txt"] = { "g" } })
    vim.ui.select = function(items, _, cb)
      H.eq(items, { "a", "b" })
      cb("b")
    end
    local view = open()
    asked, confirm_answer = {}, 1
    press(view, "push", mine)
    vim.wait(200)
    H.ok(finished(mine), "git finished")
    H.eq(head(origin, "topic"), head(mine))
    H.eq(vim.trim(H.git(mine, { "rev-parse", "--abbrev-ref", "topic@{u}" })), "b/topic")
  end)

  H.it("a branch without upstream: pushed and tracked when asked", function()
    local origin, mine = setup()
    H.git(mine, { "checkout", "-q", "-b", "topic" })
    H.commit(mine, "topic work", { ["g.txt"] = { "g" } })
    local view = open()
    asked, confirm_answer = {}, 1
    press(view, "push", mine)
    H.ok(table.concat(asked, "\n"):find("--set-upstream origin topic", 1, true), vim.inspect(asked))
    H.eq(head(origin, "topic"), head(mine))
    H.eq(vim.trim(H.git(mine, { "rev-parse", "--abbrev-ref", "topic@{u}" })), "origin/topic")
  end)

  H.it("stopping a push whose hook does not end", function()
    local origin, mine = setup()
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    H.write(mine, ".git/hooks/pre-push", { "#!/bin/sh", "sleep 30" })
    vim.uv.fs_chmod(mine .. "/.git/hooks/pre-push", 493)
    local before = head(origin, "master")
    local view = open()
    api.nvim_set_current_win(view.layout.files_win)
    view:dispatch("push", { buf = view.files.buf, win = view.layout.files_win })
    vim.wait(300)
    confirm_answer = 1
    local t = vim.uv.hrtime()
    local said = press(view, "push", mine)
    H.ok((vim.uv.hrtime() - t) / 1e9 < 5, "stopped at once")
    H.ok(said:find("git push stopped", 1, true), said)
    H.eq(head(origin, "master"), before)
  end)

  H.it(":DiffMerge push / fetch / pull pass their arguments", function()
    local origin, mine = setup()
    H.commit(mine, "mine", { ["f.txt"] = { "a", "b", "C" } })
    local before = head(origin, "master")
    vim.cmd("DiffMerge push --dry-run")
    H.ok(finished(mine), "git finished")
    H.eq(head(origin, "master"), before, "dry run")
  end)
  H.it("F, p, P in the status view's file panel only; a clean tree starts there", function()
    local _, mine = setup()
    local view = require("diffmerge").status()
    H.eq(api.nvim_get_current_win(), view.layout.files_win, "clean: the cursor in the file panel")
    local function mapped(buf, lhs)
      return api.nvim_buf_call(buf, function()
        return vim.fn.maparg(lhs, "n", false, true).desc
      end)
    end
    for _, lhs in ipairs({ "F", "p", "P" }) do
      H.ok((mapped(view.files.buf, lhs) or ""):find("git", 1, true), lhs)
    end
    vim.cmd("DiffMerge diff HEAD")
    local diff = require("diffmerge").current()
    H.eq(mapped(diff.files.buf, "P"), nil, "not in a diff view")
    vim.cmd("DiffMerge log")
    local log = require("diffmerge").current()
    H.ok((mapped(log.log.buf, "F") or ""):find("first%-parent"), mapped(log.log.buf, "F"))
    local _ = mine
  end)

  H.it("a pull and a commit wait for each other; stopping a pull warns", function()
    local _, mine, theirs = setup()
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    H.write(mine, ".git/hooks/post-merge", { "#!/bin/sh", "sleep 2" })
    vim.uv.fs_chmod(mine .. "/.git/hooks/post-merge", 493)
    H.write(mine, "g.txt", { "g" })
    H.git(mine, { "add", "g.txt" })
    local view = open()
    api.nvim_set_current_win(view.layout.files_win)
    view:dispatch("pull", { buf = view.files.buf, win = view.layout.files_win })
    local said = {}
    local notify = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    vim.wait(500)
    view:dispatch("commit", { buf = view.files.buf, win = view.layout.files_win })
    asked, confirm_answer = {}, 2
    view:dispatch("pull", { buf = view.files.buf, win = view.layout.files_win })
    vim.notify = notify
    H.ok(table.concat(said, "\n"):find("git pull is running: commit when it is done", 1, true), vim.inspect(said))
    H.ok(table.concat(asked, "\n"):find("half updated", 1, true), vim.inspect(asked))
    H.ok(finished(mine), "pull finished")
    -- the other way round
    view:dispatch("commit", { buf = view.files.buf, win = view.layout.files_win })
    local commit = require("diffmerge.commit")
    vim.wait(5000, function()
      return commit.message_tab() ~= nil
    end, 20)
    said = {}
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
    vim.cmd("DiffMerge pull")
    vim.notify = notify
    H.ok(table.concat(said, "\n"):find("a commit is running", 1, true), vim.inspect(said))
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_buf_get_name(api.nvim_win_get_buf(w)):match("COMMIT_EDITMSG$") then
        api.nvim_set_current_win(w)
        api.nvim_feedkeys(":q!\r", "xt", false)
      end
    end
    vim.wait(5000, function()
      return not commit.running()
    end, 20)
  end)

  H.it("your own refspec: no upstream offered, git's message", function()
    local origin, mine = setup()
    H.git(mine, { "checkout", "-q", "-b", "topic" })
    H.commit(mine, "topic work", { ["g.txt"] = { "g" } })
    asked, confirm_answer = {}, 1
    vim.cmd("DiffMerge push origin topic:elsewhere")
    H.ok(finished(mine), "git finished")
    H.eq(asked, {}, "no question")
    H.eq(head(origin, "elsewhere"), head(mine))
  end)
  H.it("a log view keeps its marks; a push to a remote you named: no tracking offer", function()
    local _, mine, theirs = setup()
    H.commit(mine, "one", { ["f.txt"] = { "1" } })
    H.commit(mine, "two", { ["f.txt"] = { "2" } })
    vim.cmd("DiffMerge log")
    local log = require("diffmerge").current()
    H.flush(200)
    api.nvim_set_current_win(log.layout.log_win)
    for _, row in ipairs({ 1, 2 }) do
      api.nvim_win_set_cursor(log.layout.log_win, { row, 0 })
      log:dispatch("mark", { buf = log.log.buf, win = log.layout.log_win })
    end
    local marks = vim.deepcopy(log.marks)
    H.eq(#marks, 2, "two rows marked")
    H.commit(theirs, "theirs", { ["g.txt"] = { "g" } })
    H.git(theirs, { "push", "-q" })
    local view = open()
    press(view, "fetch", mine)
    H.eq(log.marks, marks, "marks kept")
    -- a branch pushed to the remote named: not asked to track
    H.git(mine, { "config", "push.default", "current" })
    H.git(mine, { "checkout", "-q", "-b", "topic" })
    asked = {}
    vim.cmd("DiffMerge push origin")
    H.ok(finished(mine), "git finished")
    H.eq(asked, {}, "no question")
  end)

  H.it("p offers to stop a pull that is rebasing", function()
    local _, mine, theirs = setup()
    H.git(mine, { "config", "pull.rebase", "true" })
    H.commit(theirs, "theirs", { ["f.txt"] = { "A", "b", "c" } })
    H.git(theirs, { "push", "-q" })
    H.commit(mine, "mine", { ["g.txt"] = { "g" } })
    H.write(mine, ".git/hooks/post-rewrite", { "#!/bin/sh", "sleep 2" })
    vim.uv.fs_chmod(mine .. "/.git/hooks/post-rewrite", 493)
    local view = open()
    api.nvim_set_current_win(view.layout.files_win)
    view:dispatch("pull", { buf = view.files.buf, win = view.layout.files_win })
    vim.wait(800)
    asked, confirm_answer = {}, 2
    view:dispatch("pull", { buf = view.files.buf, win = view.layout.files_win })
    H.ok(table.concat(asked, "\n"):find("Stop it?", 1, true), vim.inspect(asked))
    H.ok(finished(mine), "pull finished")
  end)
end)

H.done()
