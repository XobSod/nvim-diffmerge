-- Commits of the log applied to the branch: C cherry-pick, X revert, r reset, T tag.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local commit = require("diffmerge.commit")

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

--- master: initial (f.txt a), m (m.txt); side from initial: s1 (s1.txt), s2 (s2.txt); the log open.
local function repo()
  local dir = H.repo({ ["f.txt"] = { "a" } })
  H.git(dir, { "branch", "-m", "master" })
  local c = { initial = vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }
  H.git(dir, { "checkout", "-q", "-b", "side" })
  c.s1 = H.commit(dir, "s1", { ["s1.txt"] = { "s1" } })
  c.s2 = H.commit(dir, "s2", { ["s2.txt"] = { "s2" } })
  H.git(dir, { "checkout", "-q", "master" })
  c.m = H.commit(dir, "m", { ["m.txt"] = { "m" } })
  vim.cmd.cd(dir)
  local view = require("diffmerge").log()
  vim.wait(5000, function()
    return not view.log.loading
  end, 10)
  return dir, c, view
end

local function in_log(view, range)
  return { buf = view.log.buf, win = view.layout.log_win, range = range }
end

local function line(view, sha)
  vim.wait(5000, function()
    return not view.log.loading and view.log.by_sha[sha] ~= nil
  end, 10)
  return view.log.by_sha[sha]
end

local function on(view, sha, action, range)
  api.nvim_set_current_win(view.layout.log_win)
  api.nvim_win_set_cursor(view.layout.log_win, { line(view, sha), 0 })
  view:dispatch(action, in_log(view, range))
end

local function finished()
  return vim.wait(15000, function()
    return not commit.running()
  end, 20)
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

local function subjects(dir, n)
  return vim.trim(H.git(dir, { "log", "--format=%s", "-" .. n }))
end

--- Answers the next menu with the choice whose text starts with `text`; inputs with `inputs`.
local function answers(text, inputs, fn)
  local select, input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do
      if opts.format_item(it):sub(1, #text) == text then
        return cb(it)
      end
    end
    cb(nil)
  end
  local i = 0
  vim.ui.input = function(_, cb)
    i = i + 1
    cb(inputs[i])
  end
  local ok, err = pcall(function()
    fn()
    -- (the next question comes after the menu closes)
    H.flush(100)
  end)
  vim.ui.select, vim.ui.input = select, input
  assert(ok, err)
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

H.describe("commits of the log applied to the branch", function()
  H.it("C: one commit, two marked, a visual range: oldest first; a merge is not picked", function()
    local dir, c, view = repo()
    on(view, c.s1, "cherry_pick")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 2), "s1\nm")
    H.git(dir, { "reset", "-q", "--hard", c.m })
    view:load_log()
    for _, sha in ipairs({ c.s2, c.s1 }) do
      on(view, sha, "mark")
    end
    on(view, c.s2, "cherry_pick")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 3), "s2\ns1\nm", "the marked ones, oldest first")
    H.git(dir, { "reset", "-q", "--hard", c.m })
    view:load_log()
    local first, last = line(view, c.s2), line(view, c.s1)
    on(view, c.s2, "cherry_pick", { math.min(first, last), math.max(first, last) })
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 3), "s2\ns1\nm", "the range, oldest first")
    H.git(dir, { "merge", "-q", "--no-ff", "--no-edit", "side" })
    local merge = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
    H.git(dir, { "branch", "merged" })
    H.git(dir, { "reset", "-q", "--hard", c.m })
    view:load_log()
    on(view, c.m, "clear_marks")
    local said = said_by(function()
      on(view, merge, "cherry_pick")
    end)
    H.ok(said:find("a merge commit: not cherry-picked", 1, true), said)
  end)

  H.it("C in conflict stops like any cherry-pick; X: one with its message, two newest first", function()
    local dir, c, view = repo()
    H.commit(dir, "s1 on master", { ["s1.txt"] = { "other" } })
    view:load_log()
    on(view, c.s1, "cherry_pick")
    H.ok(finished(), "git finished")
    H.ok(vim.uv.fs_stat(dir .. "/.git/CHERRY_PICK_HEAD"), "in conflict")
    asked, confirm_answer = {}, 1
    require("diffmerge.operation").abort(require("diffmerge.git").find_repo(dir))
    H.ok(finished(), "git finished")
    H.git(dir, { "reset", "-q", "--hard", c.m })
    H.git(dir, { "merge", "-q", "--no-edit", "side" })
    view:load_log()
    on(view, c.s2, "revert_commit")
    local win = message_win()
    H.ok(win, "its message to edit")
    api.nvim_set_current_win(win)
    api.nvim_feedkeys(api.nvim_replace_termcodes(":wq<CR>", true, false, true), "xt", false)
    H.ok(finished(), "git finished")
    H.ok(subjects(dir, 1):find('^Revert "s2"'), subjects(dir, 1))
    H.eq(vim.uv.fs_stat(dir .. "/s2.txt"), nil, "undone")
    H.git(dir, { "reset", "-q", "--hard", "HEAD~1" })
    view:load_log()
    for _, sha in ipairs({ c.s1, c.s2 }) do
      on(view, sha, "mark")
    end
    on(view, c.s2, "revert_commit")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 2), 'Revert "s1"\nRevert "s2"', "newest first")
  end)

  H.it("r: soft, mixed, hard (asked, unsaved files first); where HEAD was said", function()
    local dir, c, view = repo()
    H.git(dir, { "merge", "-q", "--no-edit", "side" })
    local top = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
    view:load_log()
    local said = said_by(function()
      answers("Soft", {}, function()
        on(view, c.m, "reset_to")
      end)
    end)
    H.eq(vim.trim(H.git(dir, { "rev-parse", "HEAD" })), c.m)
    H.ok(H.git(dir, { "diff", "--cached", "--name-only" }):find("s1.txt", 1, true), "staged")
    H.ok(said:find("it was at " .. top:sub(1, 7) .. ", git reset --soft", 1, true), said)
    H.git(dir, { "reset", "-q", "--hard", top })
    view:load_log()
    answers("Mixed", {}, function()
      on(view, c.m, "reset_to")
    end)
    H.eq(H.git(dir, { "status", "--short" }), "?? s1.txt\n?? s2.txt\n", "unstaged (untracked here)")
    H.git(dir, { "reset", "-q", "--hard", top })
    view:load_log()
    local buf = vim.fn.bufadd(dir .. "/f.txt")
    vim.fn.bufload(buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
    said = said_by(function()
      answers("Hard", {}, function()
        on(view, c.m, "reset_to")
      end)
    end)
    H.ok(said:find("unsaved changes in f.txt", 1, true), said)
    vim.bo[buf].modified = false
    H.write(dir, "f.txt", { "changed" })
    asked, confirm_answer = {}, 1
    answers("Hard", {}, function()
      on(view, c.m, "reset_to")
    end)
    H.ok(asked[1]:find("Uncommitted changes in 1 file(s) are lost", 1, true), vim.inspect(asked))
    H.eq({ vim.trim(H.git(dir, { "rev-parse", "HEAD" })), H.read(dir, "f.txt") }, { c.m, "a\n" })
  end)

  H.it("T: an annotated tag with a message, a lightweight one without; a bad name refused; the log shows it", function()
    local dir, c, view = repo()
    answers("", { "v1.0", "the first" }, function()
      on(view, c.m, "tag_commit")
    end)
    H.eq(vim.trim(H.git(dir, { "cat-file", "-t", "v1.0" })), "tag", "annotated")
    answers("", { "light", "" }, function()
      on(view, c.s1, "tag_commit")
    end)
    H.eq(vim.trim(H.git(dir, { "cat-file", "-t", "light" })), "commit", "lightweight")
    local said = said_by(function()
      answers("", { "bad..name" }, function()
        on(view, c.s1, "tag_commit")
      end)
    end)
    H.ok(said:find("not a tag name", 1, true), said)
    vim.wait(5000, function()
      return not view.log.loading
    end, 10)
    local text = api.nvim_buf_get_lines(view.log.buf, line(view, c.m) - 1, line(view, c.m), false)[1]
    H.ok(text:find("v1.0", 1, true), "in the log: " .. text)
  end)

  H.it("X with :q!: no revert; C leaves out commits already in HEAD; marks of a pseudo row do not count", function()
    local dir, c, view = repo()
    on(view, c.m, "revert_commit")
    local win = message_win()
    local said = said_by(function()
      api.nvim_set_current_win(win)
      api.nvim_feedkeys(api.nvim_replace_termcodes(":q!<CR>", true, false, true), "xt", false)
      H.ok(finished(), "git finished")
    end)
    H.ok(said:find("no revert made", 1, true), said)
    H.eq({ H.git(dir, { "status", "--short" }), vim.trim(H.git(dir, { "rev-parse", "HEAD" })) }, { "", c.m })
    said = said_by(function()
      on(view, c.initial, "cherry_pick")
    end)
    H.ok(said:find("already in the history of HEAD, left out", 1, true), said)
    H.eq(commit.running(), false, "nothing to pick")
    -- a range down to the fork point: the fork left out, the rest picked
    local first, last = line(view, c.s2), line(view, c.initial)
    on(view, c.s2, "cherry_pick", { math.min(first, last), math.max(first, last) })
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 3), "s2\ns1\nm")
    -- Working tree + a commit marked: the cursor's commit
    H.git(dir, { "reset", "-q", "--hard", c.m })
    view:load_log()
    on(view, c.m, "clear_marks")
    on(view, c.s1, "mark")
    api.nvim_win_set_cursor(view.layout.log_win, { 1, 0 })
    view:dispatch("mark", in_log(view))
    on(view, c.s2, "cherry_pick")
    H.ok(finished(), "git finished")
    H.eq(subjects(dir, 2), "s2\nm", "the cursor's commit")
    H.eq(#view.marks, 0, "marks gone after it")
  end)

  H.it("r hard names untracked files it writes over, drops buffers of files it deletes; X elsewhere asked", function()
    local dir, c, view = repo()
    H.write(dir, "s1.txt", { "my untracked work" })
    H.write(dir, "new.txt", { "new" })
    H.git(dir, { "add", "new.txt" })
    local new = vim.fn.bufadd(dir .. "/new.txt")
    vim.fn.bufload(new)
    asked, confirm_answer = {}, 1
    answers("Hard", {}, function()
      on(view, c.s1, "reset_to")
    end)
    H.ok(asked[1]:find("Untracked files it has are written over: s1.txt", 1, true), vim.inspect(asked))
    H.eq(api.nvim_buf_is_valid(new), false, "the deleted file's buffer gone")
    H.git(dir, { "reset", "-q", "--hard", c.m })
    view:load_log()
    asked, confirm_answer = {}, 2
    on(view, c.s2, "revert_commit")
    H.ok(asked[1] and asked[1]:find("Not in the history of HEAD", 1, true), vim.inspect(asked))
    H.eq(commit.running(), false, "not reverted")
  end)

  H.it("r hard: a name git quotes named as it is; not a directory of tracked files, not a submodule", function()
    local dir, c, view = repo()
    H.git(dir, { "update-index", "--add", "--cacheinfo", "160000," .. c.initial .. ",sub" })
    local tgt = H.commit(dir, "tgt", { ['q"a.txt'] = { "theirs" }, td = { "a file" } })
    H.git(dir, { "branch", "tgt" })
    H.git(dir, { "reset", "-q", "--hard", c.m })
    H.commit(dir, "td", { ["td/inner.txt"] = { "tracked" } })
    H.write(dir, 'q"a.txt', { "mine" })
    H.write(dir, "sub/x.txt", { "a checkout left" })
    view:load_log()
    asked, confirm_answer = {}, 2
    answers("Hard", {}, function()
      on(view, tgt, "reset_to")
    end)
    H.eq(asked[1] and asked[1]:match("written over: (.*)$"), 'q"a.txt.', vim.inspect(asked))
  end)

  H.it("X with something staged: git refuses, what is staged stays", function()
    local dir, c, view = repo()
    H.write(dir, "m.txt", { "my staged work" })
    H.write(dir, "n.txt", { "new" })
    H.git(dir, { "add", "m.txt", "n.txt" })
    local said = said_by(function()
      on(view, c.m, "revert_commit")
      H.ok(finished(), "git finished")
    end)
    H.ok(not said:find("no revert made", 1, true), said)
    H.eq({ H.git(dir, { "status", "--short" }), H.read(dir, "m.txt") }, { "M  m.txt\nA  n.txt\n", "my staged work\n" })
    H.eq(vim.trim(H.git(dir, { "rev-parse", "HEAD" })), c.m, "not reverted")
  end)

  H.it("T: a message starting with # kept, a name starting with - refused, a lightweight tag not signed", function()
    local dir, c, view = repo()
    local said = said_by(function()
      answers("", { "v2", "#42 the release" }, function()
        on(view, c.m, "tag_commit")
        H.ok(finished(), "git finished")
      end)
    end)
    H.ok(said:find("as v2", 1, true) and not said:find("done", 1, true), said)
    H.ok(H.git(dir, { "tag", "-l", "-n1", "v2" }):find("#42 the release", 1, true), "the message kept")
    said = said_by(function()
      answers("", { "-f" }, function()
        on(view, c.m, "tag_commit")
      end)
    end)
    H.ok(said:find("not a tag name: -f", 1, true), said)
    H.git(dir, { "config", "tag.gpgSign", "true" })
    answers("", { "plain", "" }, function()
      on(view, c.m, "tag_commit")
      H.ok(finished(), "git finished")
    end)
    H.eq(vim.trim(H.git(dir, { "cat-file", "-t", "plain" })), "commit", "lightweight, not signed")
  end)
end)

H.done()
