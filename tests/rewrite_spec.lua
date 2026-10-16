-- Rewriting the branch from the log: cf fixup, cs squash, cr reword, cd drop.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local commit = require("diffmerge.commit")

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

--- master: c1 .. c4, each adding its own file; the log view open.
local function repo()
  local dir = H.repo({ ["f1.txt"] = { "1" } })
  H.git(dir, { "branch", "-m", "master" })
  local c = { vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }
  for i = 2, 4 do
    c[i] = H.commit(dir, "c" .. i, { ["f" .. i .. ".txt"] = { tostring(i) } })
  end
  vim.cmd.cd(dir)
  local view = require("diffmerge").log()
  vim.wait(5000, function()
    return not view.log.loading
  end, 10)
  return dir, c, view
end

local function in_log(view)
  return { buf = view.log.buf, win = view.layout.log_win }
end

--- `action` on the log row of `sha`.
local function on(view, sha, action)
  vim.wait(5000, function()
    return not view.log.loading and view.log.by_sha[sha] ~= nil
  end, 10)
  H.ok(view.log.by_sha[sha], "the row is there")
  api.nvim_set_current_win(view.layout.log_win)
  api.nvim_win_set_cursor(view.layout.log_win, { view.log.by_sha[sha], 0 })
  view:dispatch(action, in_log(view))
end

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
  return vim.wait(15000, function()
    return not commit.running()
  end, 20)
end

--- The message window's first line set to `first`, then `:wq`.
local function write_message(first)
  local win = message_win()
  H.ok(win, "the message window")
  if first then
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, 1, false, { first })
  end
  api.nvim_set_current_win(win)
  api.nvim_feedkeys(api.nvim_replace_termcodes(":wq<CR>", true, false, true), "xt", false)
  H.ok(finished(), "git finished")
end

local function subjects(dir)
  return vim.trim(H.git(dir, { "log", "--format=%s" }))
end

H.describe("rewriting the branch from the log", function()
  H.it("cf: what is staged goes into that commit; unstaged changes stay", function()
    local dir, c, view = repo()
    H.write(dir, "fix.txt", { "fix" })
    H.git(dir, { "add", "fix.txt" })
    H.write(dir, "f4.txt", { "4, not staged" })
    local said = said_by(function()
      on(view, c[2], "fixup_commit")
      H.ok(finished(), "git finished")
    end)
    H.ok(said:find("the branch was at " .. c[4]:sub(1, 7), 1, true), "before the fixup commit: " .. said)
    H.eq(subjects(dir), "c4\nc3\nc2\ninitial")
    H.ok(H.git(dir, { "show", "--name-only", "--format=", "HEAD~2" }):find("fix.txt", 1, true), "in c2")
    H.eq(H.git(dir, { "status", "--short" }), " M f4.txt\n", "the unstaged change back")
  end)

  H.it("cs: squashed into its parent with both messages; cr: reworded", function()
    local dir, c, view = repo()
    on(view, c[3], "squash_commit")
    local win = message_win()
    local text = table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), "\n")
    H.ok(text:find("c2", 1, true) and text:find("c3", 1, true), text)
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, -1, false, { "c2 and c3" })
    write_message()
    H.eq(subjects(dir), "c4\nc2 and c3\ninitial")
    vim.wait(100, function()
      return false
    end)
    H.eq(api.nvim_get_current_win(), view.layout.log_win, "back in the log after the message")
    local c2 = vim.trim(H.git(dir, { "rev-parse", "HEAD~1" }))
    vim.wait(5000, function()
      return view.log.by_sha[c2] ~= nil
    end, 10)
    on(view, c2, "reword_commit")
    write_message("both")
    H.eq(subjects(dir), "c4\nboth\ninitial")
    -- the first commit too
    on(view, c[1], "reword_commit")
    write_message("the first")
    H.eq(subjects(dir), "c4\nboth\nthe first")
  end)

  H.it("cd: dropped when you say so; where the branch was is said", function()
    local dir, c, view = repo()
    asked, confirm_answer = {}, 2
    on(view, c[3], "drop_commit")
    H.ok(asked[1]:find("Drop " .. c[3]:sub(1, 7) .. " c3", 1, true), vim.inspect(asked))
    H.eq(subjects(dir), "c4\nc3\nc2\ninitial", "not dropped")
    confirm_answer = 1
    local said = said_by(function()
      on(view, c[3], "drop_commit")
      H.ok(finished(), "git finished")
    end)
    H.eq(subjects(dir), "c4\nc2\ninitial")
    H.ok(said:find("the branch was at " .. c[4]:sub(1, 7), 1, true), said)
  end)

  H.it("not rewritten: another branch, the first commit squashed, unsaved files, nothing staged, merges after", function()
    local dir, c, view = repo()
    H.git(dir, { "checkout", "-q", "-b", "side", c[2] })
    local side = H.commit(dir, "side", { ["s.txt"] = { "s" } })
    H.git(dir, { "checkout", "-q", "master" })
    view:load_log()
    local said = said_by(function()
      on(view, side, "reword_commit")
      on(view, c[1], "squash_commit")
      on(view, c[3], "fixup_commit")
      local f4 = vim.fn.bufadd(dir .. "/f4.txt")
      vim.fn.bufload(f4)
      api.nvim_buf_set_lines(f4, 0, -1, false, { "unsaved" })
      on(view, c[3], "drop_commit")
      vim.bo[f4].modified = false
    end)
    for _, why in ipairs({ "not in the history of HEAD", "no parent to squash it into", "nothing is staged", "unsaved changes in f4.txt" }) do
      H.ok(said:find(why, 1, true), why .. ": " .. said)
    end
    H.git(dir, { "merge", "-q", "--no-ff", "--no-edit", "side" })
    view:load_log()
    said = said_by(function()
      on(view, c[3], "reword_commit")
    end)
    H.ok(said:find("merges after it", 1, true), said)
    H.eq(commit.running(), false, "nothing ran")
  end)

  H.it("pushed already: asked; a drop in conflict stops like a rebase, aborted", function()
    local dir, c, view = repo()
    local origin = H.tmpdir() .. "/origin.git"
    H.git(dir, { "clone", "-q", "--bare", dir, origin })
    H.git(dir, { "remote", "add", "origin", origin })
    H.git(dir, { "fetch", "-q", "origin" })
    H.git(dir, { "branch", "-q", "--set-upstream-to=origin/master" })
    asked, confirm_answer = {}, 2
    on(view, c[3], "reword_commit")
    H.ok(asked[1]:find("pushed already (in origin/master)", 1, true), vim.inspect(asked))
    H.eq(commit.running(), false, "not reworded")
    -- c5 changes f3.txt: dropping c3 leaves it nothing to apply to
    confirm_answer = 1
    local c5 = H.commit(dir, "c5", { ["f3.txt"] = { "3", "more" } })
    view:load_log()
    on(view, c[3], "drop_commit")
    H.ok(finished(), "git finished")
    H.ok(vim.uv.fs_stat(dir .. "/.git/rebase-merge"), "the rebase stopped in conflict")
    require("diffmerge.operation").abort(require("diffmerge.git").find_repo(dir))
    H.ok(finished(), "git finished")
    H.eq(vim.trim(H.git(dir, { "rev-parse", "HEAD" })), c5, "as before")
  end)

  H.it("the c menu on a commit lists them; on the Working tree row commit and amend only", function()
    local _, c, view = repo()
    local offered
    local select = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      offered = vim.tbl_map(opts.format_item, items)
      cb(nil)
    end
    on(view, c[3], "commit_menu")
    local short = c[3]:sub(1, 7)
    H.eq(offered, {
      "Commit",
      "Amend the last commit",
      "Fixup " .. short .. " with what is staged",
      "Squash " .. short .. " into its parent",
      "Reword " .. short,
      "Drop " .. short,
    })
    api.nvim_win_set_cursor(view.layout.log_win, { 1, 0 })
    view:dispatch("commit_menu", in_log(view))
    vim.ui.select = select
    H.eq(offered, { "Commit", "Amend the last commit" })
  end)

  H.it("rebase.autosquash=true: pending fixup! commits are left as they are by cd / cr", function()
    local dir, c, view = repo()
    H.git(dir, { "config", "rebase.autosquash", "true" })
    local pending = H.commit(dir, "fixup! c3", { ["x.txt"] = { "x" } })
    view:load_log()
    asked, confirm_answer = {}, 1
    on(view, c[3], "drop_commit")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir), "fixup! c3\nc4\nc2\ninitial")
    local again = vim.trim(H.git(dir, { "rev-parse", "HEAD~2" }))
    view:load_log()
    on(view, again, "reword_commit")
    write_message("c2, reworded")
    H.eq(subjects(dir), "fixup! c3\nc4\nc2, reworded\ninitial", "the fixup! commit not squashed")
    local _ = pending
  end)

  H.it("cs asks when the parent is pushed; cf goes after its commit, also a fixup! one, nothing else moves", function()
    local dir, c, view = repo()
    local origin = H.tmpdir() .. "/origin.git"
    H.git(dir, { "clone", "-q", "--bare", dir, origin })
    H.git(dir, { "remote", "add", "origin", origin })
    H.git(dir, { "push", "-q", "-f", "origin", c[3] .. ":refs/heads/master" })
    H.git(dir, { "fetch", "-q", "origin" })
    H.git(dir, { "branch", "-q", "--set-upstream-to=origin/master" })
    asked, confirm_answer = {}, 2
    on(view, c[4], "squash_commit")
    H.ok(asked[1] and asked[1]:find("pushed already", 1, true), vim.inspect(asked))
    H.eq(commit.running(), false, "not squashed")
    -- a pending squash! of c2 stays where it is; a fixup of a fixup! commit lands after it
    local squash = H.commit(dir, "squash! c2", { ["y.txt"] = { "y" } })
    local fix = H.commit(dir, "fixup! c2", { ["z.txt"] = { "z" } })
    H.commit(dir, "c5", { ["f5.txt"] = { "5" } })
    view:load_log()
    H.write(dir, "w.txt", { "w" })
    H.git(dir, { "add", "w.txt" })
    on(view, fix, "fixup_commit")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir), "c5\nfixup! c2\nsquash! c2\nc4\nc3\nc2\ninitial")
    H.ok(H.git(dir, { "show", "--name-only", "--format=", "HEAD~1" }):find("w.txt", 1, true), "into the fixup! commit")
    local _ = squash
  end)

  H.it("a fixup that does not happen takes its commit back: refused by a hook, aborted in conflict", function()
    local dir, c, view = repo()
    H.write(dir, ".git/hooks/pre-rebase", { "#!/bin/sh", "exit 1" })
    vim.uv.fs_chmod(dir .. "/.git/hooks/pre-rebase", 493)
    H.write(dir, "f2.txt", { "2, fixed" })
    H.git(dir, { "add", "f2.txt" })
    local said = said_by(function()
      on(view, c[2], "fixup_commit")
      H.ok(finished(), "git finished")
    end)
    H.ok(said:find("no fixup made: what was staged is staged again", 1, true), said)
    H.eq({ vim.trim(H.git(dir, { "rev-parse", "HEAD" })), H.git(dir, { "diff", "--cached", "--name-only" }) }, { c[4], "f2.txt\n" })
    os.remove(dir .. "/.git/hooks/pre-rebase")
    -- c3 changes f2.txt too: the fixup of c2 conflicts with it
    local c5 = H.commit(dir, "c5", { ["f2.txt"] = { "2, then 5" } })
    view:load_log()
    H.write(dir, "f2.txt", { "2, fixed again" })
    H.git(dir, { "add", "f2.txt" })
    on(view, c[2], "fixup_commit")
    H.ok(finished(), "git finished")
    local op = require("diffmerge.operation").current(require("diffmerge.git").find_repo(dir))
    H.ok(op and op.stop == "conflict", "stopped in conflict, not to edit: " .. vim.inspect(op))
    H.ok(vim.iter(require("diffmerge.operation").choices(require("diffmerge.git").find_repo(dir), op)):any(function(choice)
      return choice.act == "skip"
    end), "skip offered")
    asked, confirm_answer = {}, 1
    require("diffmerge.operation").abort(require("diffmerge.git").find_repo(dir))
    H.ok(finished(), "git finished")
    H.eq({ vim.trim(H.git(dir, { "rev-parse", "HEAD" })), H.git(dir, { "diff", "--cached", "--name-only" }) }, { c5, "f2.txt\n" }, "the fix staged again")
  end)

  H.it(":q! in a reword's message undoes the rewrite; the log stays on that line", function()
    local dir, c, view = repo()
    local line = view.log.by_sha[c[2]]
    on(view, c[2], "reword_commit")
    local win = message_win()
    local said = said_by(function()
      api.nvim_set_current_win(win)
      api.nvim_feedkeys(api.nvim_replace_termcodes(":q!<CR>", true, false, true), "xt", false)
      H.ok(finished(), "git finished")
    end)
    H.ok(said:find("the rewrite is undone", 1, true), said)
    H.eq({ vim.uv.fs_stat(dir .. "/.git/rebase-merge"), vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }, { nil, c[4] })
    on(view, c[2], "reword_commit")
    write_message("c2, reworded")
    vim.wait(5000, function()
      return not view.log.loading
    end, 10)
    H.eq(api.nvim_win_get_cursor(view.layout.log_win)[1], line, "on the reworded commit's line")
    H.eq(view.log:row(line).sha, vim.trim(H.git(dir, { "rev-parse", "HEAD~2" })))
  end)

  H.it("a reword a hook refuses: ca writes it again; a fixup skipped in conflict says where the fix is", function()
    local dir, c, view = repo()
    H.write(dir, ".git/hooks/commit-msg", { "#!/bin/sh", "grep -q REFUSE \"$1\" && exit 1", "exit 0" })
    vim.uv.fs_chmod(dir .. "/.git/hooks/commit-msg", 493)
    on(view, c[2], "reword_commit")
    write_message("REFUSE me")
    H.ok(vim.uv.fs_stat(dir .. "/.git/rebase-merge"), "stopped at that commit")
    view:dispatch("commit_amend", in_log(view))
    local win = message_win()
    H.eq(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, 1, false), { "REFUSE me" }, "the message written")
    api.nvim_buf_set_lines(api.nvim_win_get_buf(win), 0, 1, false, { "c2, reworded" })
    write_message()
    require("diffmerge.operation").continue(require("diffmerge.git").find_repo(dir))
    H.ok(finished(), "git finished")
    H.eq(subjects(dir), "c4\nc3\nc2, reworded\ninitial")
    os.remove(dir .. "/.git/hooks/commit-msg")
    -- c5 changes f2.txt: the fixup of c2 conflicts, resolved, then skipped
    H.commit(dir, "c5", { ["f2.txt"] = { "2, then 5" } })
    local c2 = vim.trim(H.git(dir, { "rev-parse", "HEAD~3" }))
    view:load_log()
    H.write(dir, "f2.txt", { "2, fixed" })
    H.git(dir, { "add", "f2.txt" })
    on(view, c2, "fixup_commit")
    H.ok(finished(), "git finished")
    local repo_ = require("diffmerge.git").find_repo(dir)
    H.write(dir, "f2.txt", { "2, fixed" })
    H.git(dir, { "add", "f2.txt" })
    local op = require("diffmerge.operation").current(repo_)
    H.eq(op and op.stop, "conflict", "resolved, still the fixup's stop")
    H.eq(vim.tbl_map(function(choice)
      return choice.act
    end, require("diffmerge.operation").choices(repo_, op)), { "continue", "skip", "abort" })
    asked, confirm_answer = {}, 1
    local said = said_by(function()
      require("diffmerge.operation").skip(repo_)
      H.ok(finished(), "git finished")
      vim.wait(5000, function()
        return require("diffmerge.operation").current(repo_) == nil
      end, 20)
    end)
    H.ok(said:find("the fixup was skipped: git cherry-pick -n", 1, true), said)
  end)

  H.it("a rewrite finished elsewhere: said when the view next looks, never later for something else", function()
    local dir, c, view = repo()
    H.commit(dir, "c5", { ["f2.txt"] = { "2, then 5" } })
    view:load_log()
    H.write(dir, "f2.txt", { "2, fixed" })
    H.git(dir, { "add", "f2.txt" })
    on(view, c[2], "fixup_commit")
    H.ok(finished(), "git finished")
    H.git(dir, { "rebase", "--abort" })
    local said = said_by(function()
      view:refresh()
    end)
    H.ok(said:find("what was staged is staged again", 1, true), said)
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "f2.txt\n")
    -- a merge aborted later: nothing about that fixup
    H.git(dir, { "reset", "-q", "--hard" })
    H.git(dir, { "checkout", "-q", "-b", "other", c[2] })
    H.commit(dir, "other", { ["f2.txt"] = { "other" } })
    H.git(dir, { "checkout", "-q", "master" })
    vim.system({ "git", "merge", "-q", "other" }, { cwd = dir }):wait()
    asked, confirm_answer = {}, 1
    said = said_by(function()
      require("diffmerge.operation").abort(require("diffmerge.git").find_repo(dir))
      H.ok(finished(), "git finished")
    end)
    H.ok(not said:find("fix", 1, true), said)
  end)
end)

H.done()
