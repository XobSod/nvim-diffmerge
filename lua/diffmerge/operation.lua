--- A merge, rebase, cherry-pick, revert or `git am` going on: continued, the commit being
--- applied skipped, or aborted, with git's editor here (commit.run_git).
local git = require("diffmerge.git")
local parse = require("diffmerge.git_parse")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

local kinds = { merge = true, rebase = true, ["cherry-pick"] = true, revert = true, am = true }

--- The operation going on (git.operation), or nil.
function M.current(repo)
  local op = git.operation(repo)
  return op and kinds[op.kind] and op or nil
end

--- Whether `op` has a commit to skip: the one being applied (a rebase: when it stopped in
--- conflict, not to edit a commit, at a `break` or a failing `exec`).
local function skippable(op)
  if op.kind == "merge" or op.between then
    return false
  elseif op.kind == "rebase" then
    return op.stop == "conflict"
  end
  return true
end

--- What to type next, e.g. "cc continues, c: skip / abort".
function M.hint(op)
  if op.starting then
    return "being set up (its todo list in an editor)"
  end
  local keymaps = require("diffmerge.keymaps")
  local cont, menu = keymaps.key_for("repo", "commit"), keymaps.key_for("repo", "commit_menu")
  if not cont or not menu then
    return nil
  end
  return ("%s continues · %s %s"):format(cont, menu, skippable(op) and "skip/abort" or "abort")
end

--- Files still in conflict.
local function conflicted(repo)
  return parse.records(git.output(repo, { "diff", "--name-only", "-z", "--diff-filter=U" }))
end

local function read_git_file(repo, name)
  local text = util.read_file(vim.fs.joinpath(repo.gitdir, name))
  return text and vim.trim(text) ~= "" and vim.trim(text) or nil
end

--- Files `git <op> <flag>` (--skip, --abort) writes: those in conflict, those staged; a rebase
--- resets every changed file; an abort goes back to where the operation started (a rebase, a
--- cherry-pick / revert of several commits, git am).
local function touched(repo, op, flag)
  local out = {}
  local function add(paths)
    for _, p in ipairs(paths) do
      out[p] = true
    end
  end
  local function names(args)
    return parse.records(git.output(repo, vim.list_extend({ "diff", "--name-only", "-z" }, args)))
  end
  add(conflicted(repo))
  add(names({ "--cached" }))
  if op.kind == "rebase" then
    add(names({ "HEAD" }))
  end
  if flag == "--abort" then
    local start
    if op.kind == "rebase" then
      start = read_git_file(repo, "rebase-merge/orig-head") or read_git_file(repo, "rebase-apply/orig-head")
    elseif op.kind == "am" then
      start = read_git_file(repo, "ORIG_HEAD")
    else
      start = read_git_file(repo, "sequencer/head")
    end
    if start then
      add(names({ "HEAD", start }))
    end
  end
  return out
end

local function stamp(repo, path)
  local st = vim.uv.fs_stat(git.abspath(repo, path))
  return st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or ""
end

--- Files of `repo` with your unsaved edits (not what DiffMerge put into a conflicted file to
--- show it, not git's own files such as the message being written).
local function unsaved_edits(repo)
  local merge = require("diffmerge.merge")
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if
      vim.bo[buf].modified
      and vim.bo[buf].buftype == ""
      and vim.startswith(name, repo.root .. "/")
      and not vim.startswith(name, repo.gitdir .. "/")
      and merge.user_changes(buf)
    then
      out[#out + 1] = git.relpath(repo, name)
    end
  end
  return out
end

--- Why `op` cannot be continued, skipped or aborted from here now (nil: it can).
local function busy(op)
  if op.starting then
    return "the rebase is being set up (its todo list is open in an editor)"
  end
end

--- What stops continuing now (nil: nothing).
local function not_yet(repo)
  local files = conflicted(repo)
  if #files > 0 then
    return ("%d file(s) in conflict: %s (- in the file panel marks one resolved)"):format(
      #files,
      table.concat(vim.list_slice(files, 1, 3), ", ") .. (#files > 3 and ", …" or "")
    )
  end
  local unsaved = unsaved_edits(repo)
  if #unsaved > 0 then
    return "unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first"
  end
end

--- When git is done: what DiffMerge showed of the files it wrote anew follows them, also
--- the buffers of `discard` (your unsaved edits, as asked), the views show the operation's next
--- stop.
---@param discard table<string, string> path -> its file's stamp before (read anew if git wrote it)
function M.after(repo, discard, on_done)
  return function(res)
    local views = require("diffmerge.view")
    for _, view in pairs(views.views) do
      if view.repo and view.repo.root == repo.root and view.after_change then
        if view.merge then
          view:detach_entry()
        end
        view.reshow = true
      end
    end
    require("diffmerge.merge").reread(repo, next(discard) ~= nil)
    for path, before in pairs(discard) do
      local buf = util.find_buf(git.abspath(repo, path))
      if buf and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and stamp(repo, path) ~= before then
        api.nvim_buf_call(buf, function()
          vim.cmd("silent edit!")
        end)
      end
    end
    vim.cmd("silent! checktime")
    if not M.current(repo) then
      -- (a rewrite of the log that had stopped, over now: before the views show it)
      require("diffmerge.rewrite").finished(repo)
    end
    if on_done then
      on_done(res)
    end
    local op = M.current(repo)
    if op then
      local hint = M.hint(op)
      util.info(("the %s goes on%s"):format(git.operation_name(op), hint and (": " .. hint) or ""))
    end
  end
end

--- Runs `git <op> <flag>` (asking `question` first, with your unsaved edits named).
local function run(repo, op, flag, question, on_done)
  local commit = require("diffmerge.commit")
  if commit.running() then
    -- (what is running says what to do)
    return commit.run_git(repo, { op.kind, flag }, on_done)
  end
  local why = busy(op) or commit.blocked(repo, false)
  if why then
    util.warn(why)
    return
  end
  local discard = {}
  if question then
    local written = touched(repo, op, flag)
    local edits = vim.tbl_filter(function(p)
      return written[p]
    end, unsaved_edits(repo))
    if #edits > 0 then
      question = question .. " Unsaved edits in " .. table.concat(edits, ", ") .. " are lost."
      for _, p in ipairs(edits) do
        discard[p] = stamp(repo, p)
      end
    end
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end
  commit.run_git(repo, { op.kind, flag }, M.after(repo, discard, on_done))
end

local function nothing_going_on()
  util.info("no merge, rebase, cherry-pick, revert or git am going on")
end

--- `git <operation> --continue` (its commit's message to edit, when git asks for one); not
--- while files are in conflict or unsaved.
---@param on_done? fun(res: diffmerge.RunResult)
function M.continue(repo, on_done)
  local op = M.current(repo)
  if not op then
    return nothing_going_on()
  end
  if not require("diffmerge.commit").running() and not busy(op) then
    local why = not_yet(repo)
    if why then
      util.warn(why)
      return
    end
  end
  run(repo, op, "--continue", nil, on_done)
end

--- The commit being applied, for questions ("1a2b3c4 subject").
local function this_commit(repo, op)
  if op.kind == "am" then
    return "this patch"
  end
  return op.theirs and (git.describe(repo, op.theirs) or util.short(op.theirs)) or "this commit"
end

--- `git <operation> --skip`: the commit being applied is left out.
function M.skip(repo, on_done)
  local op = M.current(repo)
  if not op then
    return nothing_going_on()
  elseif not skippable(op) then
    util.info(
      op.kind == "merge" and "a merge has no commit to skip: continue or abort it"
        or "no commit being applied to skip here: continue or abort"
    )
    return
  end
  local question = ("Skip %s? Its changes are not applied (what you resolved of it is lost)."):format(
    this_commit(repo, op)
  )
  run(repo, op, "--skip", question, on_done)
end

--- `git <operation> --abort`: everything as before it started.
function M.abort(repo, on_done)
  local op = M.current(repo)
  if not op then
    return nothing_going_on()
  end
  local question = ("Abort the %s? Everything goes back to before it started (what you resolved is lost)."):format(
    git.operation_name(op)
  )
  run(repo, op, "--abort", question, on_done)
end

--- What the commit menu offers while `op` goes on: continuing, a new commit of what is staged
--- (a rebase stopped to edit, or elsewhere: splitting a commit), skipping, aborting.
---@return { act: "continue"|"commit"|"skip"|"abort", text: string }[]
function M.choices(repo, op)
  if op.starting then
    return {}
  end
  local out = { { act = "continue", text = ("Continue the %s"):format(git.operation_name(op)) } }
  if op.kind == "rebase" and op.stop ~= "conflict" then
    out[#out + 1] = { act = "commit", text = "Commit what is staged (a new commit)" }
  end
  if skippable(op) then
    out[#out + 1] = { act = "skip", text = "Skip " .. this_commit(repo, op) }
  end
  out[#out + 1] = { act = "abort", text = ("Abort the %s"):format(git.operation_name(op)) }
  return out
end

return M
