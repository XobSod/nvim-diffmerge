-- Stashing from the status view, and stashes in its file panel.
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

local confirm_answer, asked = 1, {}
vim.fn.confirm = function(question)
  asked[#asked + 1] = question
  return confirm_answer
end

local function repo(files)
  local dir = H.repo(files)
  H.git(dir, { "branch", "-m", "master" })
  vim.cmd.cd(dir)
  return dir
end

local function open()
  local view = require("diffmerge").status()
  api.nvim_set_current_win(view.layout.files_win)
  return view
end

--- Answers the next menu with the choice whose text starts with `text`, and the message
--- prompt with `message`.
local function answer(text, message)
  vim.ui.select = function(items, opts, cb)
    for _, it in ipairs(items) do
      if opts.format_item(it):sub(1, #text) == text then
        return cb(it)
      end
    end
    error("no choice " .. text .. " in " .. vim.inspect(vim.tbl_map(opts.format_item, items)))
  end
  vim.ui.input = function(_, cb)
    cb(message or "")
  end
end

--- Runs a file panel action with the cursor on `line` (a { first, last } pair: visual).
local function press(view, action, line)
  api.nvim_set_current_win(view.layout.files_win)
  local range
  if type(line) == "table" then
    range, line = line, line[1]
  end
  if line then
    api.nvim_win_set_cursor(0, { line, 0 })
  end
  view:dispatch(action, { buf = view.files.buf, win = view.layout.files_win, range = range })
  -- the message is asked for after the menu has closed
  H.flush(50)
end

local function section_line(view, id)
  for l = 1, api.nvim_buf_line_count(view.files.buf) do
    local it = view.files:item_at(l)
    if it and it.kind == "section" and it.section.id:match(id) then
      return l, it.section
    end
  end
end

local function stashes(dir)
  return vim.split(vim.trim(H.git(dir, { "stash", "list", "--format=%gs" })), "\n", { trimempty = true })
end

local function messages(fn)
  local got, notify = {}, vim.notify
  vim.notify = function(msg)
    got[#got + 1] = msg
  end
  local ok, err = pcall(fn)
  vim.notify = notify
  assert(ok, err)
  return table.concat(got, "\n")
end

local BASE = { "a", "b", "c", "d", "e" }

--- f.txt: line 1 changed and staged, line 5 changed on top (unstaged).
local function staged_and_unstaged()
  local dir = repo({ ["f.txt"] = BASE })
  H.write(dir, "f.txt", { "A", "b", "c", "d", "e" })
  H.git(dir, { "add", "f.txt" })
  H.write(dir, "f.txt", { "A", "b", "c", "d", "E" })
  return dir
end

H.describe("stashing", function()
  H.it("the staged changes only: the rest stays", function()
    local dir = staged_and_unstaged()
    local view = open()
    answer("Staged changes", "parser")
    press(view, "stash")
    H.eq(stashes(dir), { "On master: parser" })
    H.eq(H.read(dir, "f.txt"), "a\nb\nc\nd\nE\n")
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "")
    H.eq(H.git(dir, { "show", "stash@{0}:f.txt" }), "A\nb\nc\nd\ne\n")
  end)

  H.it("an empty message: git's own, with the branch", function()
    local dir = staged_and_unstaged()
    local view = open()
    answer("All changes", "")
    press(view, "stash")
    H.ok(stashes(dir)[1]:match("^WIP on master: %x+ initial$"), stashes(dir)[1])
    H.eq(H.read(dir, "f.txt"), table.concat(BASE, "\n") .. "\n")
  end)

  H.it("the selected file, untracked too; nothing else", function()
    local dir = repo({ ["f.txt"] = BASE, ["g.txt"] = { "g" } })
    H.write(dir, "g.txt", { "g changed" })
    H.write(dir, "new.txt", { "new" })
    local view = open()
    answer("This file: new.txt", "just new")
    press(view, "stash", view.files:line_of(H.find_entry(view, "untracked", "new.txt")))
    H.eq(stashes(dir), { "On master: just new" })
    H.eq(vim.uv.fs_stat(dir .. "/new.txt"), nil)
    H.eq(H.read(dir, "g.txt"), "g changed\n")
    H.eq(H.git(dir, { "show", "stash@{0}^3:new.txt" }), "new\n")
  end)

  H.it("keeping the staged changes in place", function()
    local dir = staged_and_unstaged()
    local view = open()
    answer("All changes, keeping", "keep")
    press(view, "stash")
    H.eq(H.read(dir, "f.txt"), "A\nb\nc\nd\ne\n")
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "f.txt\n")
  end)

  H.it("files with unsaved changes: nothing is stashed until they are saved", function()
    local dir = staged_and_unstaged()
    vim.cmd.edit(dir .. "/f.txt")
    api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved" })
    local view = open()
    answer("All changes", "x")
    local said = messages(function()
      press(view, "stash")
    end)
    H.ok(said:find("unsaved changes in f.txt", 1, true), said)
    H.eq(stashes(dir), {})
  end)

  H.it("staged and unstaged changes on neighbouring lines: only the staged one goes", function()
    local dir = repo({ ["f.txt"] = BASE, ["g.txt"] = { "g" }, ["new.txt"] = {} })
    H.git(dir, { "rm", "-q", "new.txt" })
    H.commit(dir, "no new.txt")
    H.write(dir, "f.txt", { "a", "B", "c", "d", "e" })
    H.write(dir, "g.txt", { "G" })
    H.write(dir, "new.txt", { "new" })
    H.git(dir, { "add", "f.txt", "g.txt", "new.txt" })
    H.write(dir, "f.txt", { "a", "B", "C", "d", "e" })
    -- git's own --staged cannot do this
    local probe = vim.system({ "git", "apply", "-R", "--check" }, {
      cwd = dir,
      stdin = H.git(dir, { "diff", "--cached", "--binary" }),
    }):wait()
    H.ok(probe.code ~= 0, "git's patch does not apply")
    local view = open()
    answer("Staged changes", "line two")
    press(view, "stash")
    H.eq(stashes(dir), { "On master: line two" })
    H.eq(H.read(dir, "f.txt"), "a\nb\nC\nd\ne\n")
    H.eq(H.read(dir, "g.txt"), "g\n")
    H.eq(vim.uv.fs_stat(dir .. "/new.txt"), nil)
    H.eq(H.git(dir, { "diff", "--cached", "--name-only" }), "")
    H.eq(H.git(dir, { "show", "stash@{0}:f.txt" }), "a\nB\nc\nd\ne\n")
    -- a stash like git's: it comes back staged (git applies stashes to unchanged files)
    H.git(dir, { "checkout", "--", "f.txt" })
    H.git(dir, { "stash", "pop", "--index" })
    H.eq(H.git(dir, { "show", ":f.txt" }), "a\nB\nc\nd\ne\n")
    H.eq(H.git(dir, { "show", ":g.txt" }), "G\n")
    H.eq(H.git(dir, { "show", ":new.txt" }), "new\n")
  end)

  H.it("the same line staged and changed again: nothing is stashed or changed", function()
    local dir = repo({ ["f.txt"] = BASE })
    H.write(dir, "f.txt", { "a", "B1", "c", "d", "e" })
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", { "a", "B2", "c", "d", "e" })
    local view = open()
    answer("Staged changes", "x")
    local said = messages(function()
      press(view, "stash")
    end)
    H.ok(said:find("staged and unstaged changes are on the same lines", 1, true), said)
    H.eq(stashes(dir), {})
    H.eq(H.read(dir, "f.txt"), "a\nB2\nc\nd\ne\n")
    H.eq(H.git(dir, { "show", ":f.txt" }), "a\nB1\nc\nd\ne\n")
  end)

  H.it("neighbouring lines in a CRLF file without a final newline: both kept", function()
    local dir = repo({ ["f.txt"] = "a\r\nb\r\nc\r\nd" })
    H.write(dir, "f.txt", "a\r\nB\r\nc\r\nd")
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", "a\r\nB\r\nC\r\nd")
    local view = open()
    answer("Staged changes", "crlf")
    press(view, "stash")
    H.eq(stashes(dir), { "On master: crlf" })
    H.eq(H.read(dir, "f.txt"), "a\r\nb\r\nC\r\nd")
  end)

  H.it("a staged deletion of a file kept on disk (git rm --cached): the file stays", function()
    local dir = repo({ ["f.txt"] = BASE, ["keep.txt"] = { "v1" } })
    H.write(dir, "f.txt", { "a", "B", "c", "d", "e" })
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", { "a", "B", "C", "d", "e" })
    H.git(dir, { "rm", "-q", "--cached", "keep.txt" })
    local view = open()
    answer("Staged changes", "x")
    press(view, "stash")
    H.eq(H.read(dir, "keep.txt"), "v1\n")
    H.eq(H.git(dir, { "ls-files", "keep.txt" }), "keep.txt\n", "tracked again")
    -- with work of its own in it: nothing happens
    H.git(dir, { "checkout", "-q", "--", "." })
    H.write(dir, "f.txt", { "a", "B", "C", "d", "e" })
    H.git(dir, { "rm", "-q", "--cached", "keep.txt" })
    H.write(dir, "keep.txt", { "v2 (uncommitted work)" })
    H.write(dir, "f.txt", { "a", "B", "c", "d", "e" })
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", { "a", "B", "C", "d", "e" })
    view:refresh()
    local before = #stashes(dir)
    local said = messages(function()
      press(view, "stash")
    end)
    H.ok(said:find("keep.txt", 1, true), said)
    H.eq(#stashes(dir), before)
    H.eq(H.read(dir, "keep.txt"), "v2 (uncommitted work)\n")
  end)

  H.it("a staged mode change goes with the stash; links are not written through", function()
    local dir = repo({ ["m.sh"] = { "1", "2", "3" } })
    vim.uv.fs_chmod(dir .. "/m.sh", 493)
    H.write(dir, "m.sh", { "1", "TWO", "3" })
    H.git(dir, { "add", "m.sh" })
    H.write(dir, "m.sh", { "1", "TWO", "THREE" })
    local view = open()
    answer("Staged changes", "mode")
    press(view, "stash")
    H.eq(H.read(dir, "m.sh"), "1\n2\nTHREE\n")
    H.eq(bit.band(vim.uv.fs_stat(dir .. "/m.sh").mode, 511), 420, "back to 644")
  end)

  H.it("a link is not written through to what it points to", function()
    local outside = H.tmpdir()
    H.write(outside, "outside.txt", { "t1", "important" })
    local dir = repo({ ["x.txt"] = { "x" } })
    vim.uv.fs_symlink("x.txt", dir .. "/link")
    H.git(dir, { "add", "link" })
    H.git(dir, { "commit", "-q", "-m", "link" })
    os.remove(dir .. "/link")
    vim.uv.fs_symlink(outside .. "/outside.txt", dir .. "/link")
    H.git(dir, { "add", "link" })
    os.remove(dir .. "/link")
    vim.uv.fs_symlink("x.txt", dir .. "/link")
    local view = open()
    answer("Staged changes", "link")
    messages(function()
      press(view, "stash")
    end)
    H.eq(H.read(outside, "outside.txt"), "t1\nimportant\n")
  end)

  H.it("without a committer identity, like git stash", function()
    local dir = repo({ ["f.txt"] = BASE })
    H.git(dir, { "config", "user.useConfigOnly", "true" })
    H.write(dir, "f.txt", { "a", "B", "c", "d", "e" })
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", { "a", "B", "C", "d", "e" })
    local names = { "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL" }
    local saved = {}
    for _, n in ipairs(names) do
      saved[n], vim.env[n] = vim.env[n], nil
    end
    local ok, err = pcall(function()
      local view = open()
      answer("Staged changes", "anon")
      press(view, "stash")
    end)
    for _, n in ipairs(names) do
      vim.env[n] = saved[n]
    end
    assert(ok, err)
    H.eq(stashes(dir), { "On master: anon" })
    H.eq(vim.trim(H.git(dir, { "log", "-1", "--format=%an", "stash@{0}" })), "git stash")
  end)

  H.it("visual selection: those files, renames with both paths", function()
    local dir = repo({ ["a.txt"] = { "a" }, ["b.txt"] = { "b" }, ["c.txt"] = { "c" }, ["old.txt"] = { "o" } })
    H.write(dir, "a.txt", { "A" })
    H.write(dir, "b.txt", { "B" })
    H.write(dir, "c.txt", { "C" })
    H.git(dir, { "mv", "old.txt", "new.txt" })
    local view = open()
    local first = view.files:line_of(H.find_entry(view, "unstaged", "a.txt"))
    answer("These 2 files", "two")
    press(view, "stash", { first, first + 1 })
    H.eq(H.read(dir, "c.txt"), "C\n")
    H.eq(H.read(dir, "a.txt"), "a\n")
    answer("This file: new.txt", "rename")
    view:refresh()
    press(view, "stash", view.files:line_of(H.find_entry(view, "staged", "new.txt")))
    H.eq(H.git(dir, { "status", "--porcelain", "--", "old.txt", "new.txt" }), "")
    H.eq(H.read(dir, "old.txt"), "o\n")
    H.git(dir, { "stash", "pop", "-q", "--index" })
    H.eq(H.git(dir, { "status", "--porcelain", "--", "old.txt", "new.txt" }), "A  new.txt\n D old.txt\n")
  end)

  H.it("git's own --staged when it can (changes two lines apart)", function()
    local dir = repo({ ["f.txt"] = BASE })
    H.write(dir, "f.txt", { "a", "B", "c", "d", "e" })
    H.git(dir, { "add", "f.txt" })
    H.write(dir, "f.txt", { "a", "B", "c", "D", "e" })
    local stash = require("diffmerge.stash")
    local push, calls = stash.push, {}
    stash.push = function(repo_, what, ...)
      calls[#calls + 1] = what
      return push(repo_, what, ...)
    end
    local ok, err = pcall(function()
      local view = open()
      answer("Staged changes", "apart")
      press(view, "stash")
    end)
    stash.push = push
    assert(ok, err)
    H.eq(calls, { "staged" })
    H.eq(H.read(dir, "f.txt"), "a\nb\nc\nD\ne\n")
  end)

  H.it("after a stash's file, the file itself shows its own columns", function()
    local dir = staged_and_unstaged()
    H.git(dir, { "stash", "push", "-q", "-m", "work" })
    H.write(dir, "f.txt", { "a", "b", "c", "d", "unstaged only" })
    local view = open()
    local _, section = section_line(view, "^stash:")
    view:show_entry(section.entries[1])
    view:refresh()
    view:show_entry(H.find_entry(view, "unstaged", "f.txt"))
    H.eq(view.layout.roles, { "head", "worktree" })
  end)
end)

H.describe("stashes in the file panel", function()
  H.it("one folded section per stash; its files open read-only in the columns", function()
    local dir = staged_and_unstaged()
    H.git(dir, { "stash", "push", "-m", "work" })
    local view = open()
    local line, section = section_line(view, "^stash:")
    H.ok(line, "a stash section")
    H.eq({ section.title, section.hint, #section.entries }, { "stash@{0}", "On master: work", 1 })
    H.ok(view.files:is_collapsed(section), "folded")
    -- ]f stays with the changes (there are none)
    H.eq(view.files:all_entries(), {})
    -- l unfolds it, <CR> on its file shows the file
    press(view, "expand", line)
    H.eq(view.files:is_collapsed(section), false)
    press(view, "select", line + 1)
    H.eq(view.current, section.entries[1])
    H.eq(view.layout.roles, { "head", "worktree", "index" })
    press(view, "collapse", line)
    H.eq(view.files:is_collapsed(section), true, "h folds it again")
    local bars = {}
    for _, role in ipairs(view.layout.roles) do
      local win = view.layout.wins[role]
      bars[#bars + 1] = vim.wo[win].winbar
      H.eq(vim.bo[api.nvim_win_get_buf(win)].modifiable, false, role)
    end
    H.ok(bars[1]:find("STASH BASE", 1, true), bars[1])
    H.ok(bars[2]:find("STASHED WORKING TREE", 1, true), bars[2])
    H.ok(bars[3]:find("STASHED INDEX", 1, true), bars[3])
    H.eq(H.buf_lines(api.nvim_win_get_buf(view.layout.wins.index)), { "A", "b", "c", "d", "e" })
    -- the staging keys do nothing to it
    local win = view.layout.wins.worktree
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { 5, 0 })
    local said = messages(function()
      view:dispatch("toggle_stage_line", { buf = api.nvim_win_get_buf(win), win = win })
    end)
    H.ok(said:find("a stash is read-only", 1, true), said)
    H.eq(H.git(dir, { "status", "--porcelain" }), "")
  end)

  H.it("apply restores the staged part; pop drops; X drops after asking", function()
    local dir = staged_and_unstaged()
    H.git(dir, { "stash", "push", "-m", "work" })
    local view = open()
    answer("Apply")
    press(view, "stash", (section_line(view, "^stash:")))
    H.eq(H.git(dir, { "diff", "--cached" }):find("+A", 1, true) ~= nil, true, "staged again")
    H.eq(H.read(dir, "f.txt"), "A\nb\nc\nd\nE\n")
    H.eq(stashes(dir), { "On master: work" })
    confirm_answer = 2
    press(view, "discard", (section_line(view, "^stash:")))
    H.eq(stashes(dir), { "On master: work" }, "kept when not confirmed")
    confirm_answer = 1
    press(view, "discard", (section_line(view, "^stash:")))
    H.eq(stashes(dir), {})
    -- pop
    H.git(dir, { "stash", "push", "-m", "again" })
    view:refresh()
    answer("Pop")
    press(view, "stash", (section_line(view, "^stash:")))
    H.eq(stashes(dir), {})
    H.eq(H.read(dir, "f.txt"), "A\nb\nc\nd\nE\n")
  end)

  H.it("an apply that conflicts shows the file under Conflicts", function()
    local dir = repo({ ["f.txt"] = BASE })
    H.write(dir, "f.txt", { "STASHED", "b", "c", "d", "e" })
    H.git(dir, { "stash", "push", "-m", "mine" })
    H.commit(dir, "other", { ["f.txt"] = { "COMMITTED", "b", "c", "d", "e" } })
    local view = open()
    answer("Apply")
    local said = messages(function()
      press(view, "stash", (section_line(view, "^stash:")))
    end)
    H.ok(said:find("CONFLICT", 1, true), said)
    H.ok(H.find_entry(view, "conflicts", "f.txt"), "listed as a conflict")
  end)

  H.it("a staged part that conflicts with the index: asks before applying it unstaged", function()
    local dir = repo({ ["f.txt"] = { "a", "b", "c" } })
    H.write(dir, "f.txt", { "A", "b", "c" })
    H.git(dir, { "add", "f.txt" })
    H.git(dir, { "stash", "push", "-q", "-m", "staged A" })
    H.write(dir, "f.txt", { "Z", "b", "c" })
    H.git(dir, { "add", "f.txt" })
    local view = open()
    asked, confirm_answer = {}, 2
    answer("Apply")
    messages(function()
      press(view, "stash", (section_line(view, "^stash:")))
    end)
    confirm_answer = 1
    H.ok(table.concat(asked, "\n"):find("conflicts with the index", 1, true), vim.inspect(asked))
    H.eq(H.git(dir, { "show", ":f.txt" }), "Z\nb\nc\n", "nothing changed")
  end)

  H.it("discarding a change does not jump to a stash's copy of the file", function()
    local dir = repo({ ["f.txt"] = BASE, ["g.txt"] = { "g" } })
    H.write(dir, "f.txt", { "old work", "b", "c", "d", "e" })
    H.git(dir, { "stash", "push", "-q", "-m", "old" })
    H.write(dir, "f.txt", { "A", "b", "c", "d", "e" })
    H.write(dir, "g.txt", { "G" })
    local view = open()
    view:show_entry(H.find_entry(view, "unstaged", "f.txt"))
    press(view, "discard", view.files:line_of(H.find_entry(view, "unstaged", "f.txt")))
    H.ok(not (view.current and view.current.stash), "not a stash: " .. tostring(view.current and view.current.key))
    local _, section = section_line(view, "^stash:")
    H.ok(view.files:is_collapsed(section), "the stash stays folded")
  end)
  H.it("a selection reaching into a stash stashes the selected changes", function()
    local dir = repo({ ["f.txt"] = BASE, ["g.txt"] = { "g" } })
    H.write(dir, "f.txt", { "old work", "b", "c", "d", "e" })
    H.git(dir, { "stash", "push", "-q", "-m", "old" })
    H.write(dir, "g.txt", { "G" })
    local view = open()
    local first = view.files:line_of(H.find_entry(view, "unstaged", "g.txt"))
    answer("This file: g.txt", "g only")
    press(view, "stash", { first, (section_line(view, "^stash:")) })
    H.eq(stashes(dir), { "On master: g only", "On master: old" })
  end)

  H.it("git's reason is shown, not the status after it", function()
    local dir = repo({ ["c.txt"] = { "c" }, ["other.txt"] = { "o" } })
    H.git(dir, { "checkout", "-q", "-b", "feat" })
    H.commit(dir, "feat", { ["c.txt"] = { "F" } })
    H.git(dir, { "checkout", "-q", "master" })
    H.commit(dir, "master", { ["c.txt"] = { "M" } })
    vim.system({ "git", "merge", "-q", "feat" }, { cwd = dir }):wait()
    H.write(dir, "other.txt", { "changed" })
    local view = open()
    answer("All changes", "x")
    local said = messages(function()
      press(view, "stash")
    end)
    H.ok(said:find("needs merge", 1, true), said)
    H.ok(not said:find("On branch", 1, true), said)
  end)
end)

H.done()
