--- Commits of the log applied to the branch: cherry-picked onto HEAD, reverted (a commit undoing
--- them), HEAD reset to one, one tagged. Git runs through commit.run_git (its editor here, in
--- the background): a conflict stops a cherry-pick or revert like any (operation.lua).
local git = require("diffmerge.git")
local util = require("diffmerge.util")

local M = {}

local function head(repo)
  return git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" })
end

local function lines(repo, args)
  return vim.split(git.output(repo, args) or "", "\n", { trimempty = true })
end

--- What git lists with `-z` (paths as they are, not quoted).
local function records(repo, args)
  return require("diffmerge.git_parse").records(git.output(repo, args))
end

--- Why git cannot change the branch now (nil: it can).
---@param files? boolean the files are written too (unsaved buffers would be stale)
local function why_not(repo, files)
  local op = require("diffmerge.operation").current(repo)
  if op then
    return ("a %s is in progress: finish it first"):format(git.operation_name(op))
  end
  local commit = require("diffmerge.commit")
  if commit.running() then
    return commit.busy_message()
  end
  local blocked = commit.blocked(repo, false)
  if blocked then
    return blocked
  end
  if files then
    local unsaved = require("diffmerge.remote").unsaved(repo)
    if #unsaved > 0 then
      return "unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first"
    end
  end
end

--- The merge commit among `shas`, if any.
local function merge_in(repo, shas)
  for _, line in ipairs(lines(repo, vim.list_extend({ "rev-list", "--no-walk", "--parents" }, shas))) do
    local parts = vim.split(line, " ", { trimempty = true })
    if #parts > 2 then
      return parts[1]
    end
  end
end

--- Something is staged (the index differs from HEAD).
local function staged(repo)
  return not git.run(repo, { "diff", "--cached", "--quiet", "HEAD" }).ok
end

local function in_head(repo, sha)
  return git.run(repo, { "merge-base", "--is-ancestor", sha, "HEAD" }).ok
end

local function described(repo, shas)
  return table.concat(
    vim.tbl_map(function(sha)
      return git.describe(repo, sha) or util.short(sha)
    end, shas),
    ", "
  )
end

--- `C`: `shas` (oldest first) cherry-picked onto HEAD; those already in its history left out.
function M.cherry_pick(repo, shas, on_done)
  local why = why_not(repo, true)
  local merge = not why and merge_in(repo, shas)
  if why then
    return util.warn(why)
  elseif merge then
    return util.warn(("%s is a merge commit: not cherry-picked here"):format(util.short(merge)))
  end
  local picked = vim.tbl_filter(function(sha)
    return not in_head(repo, sha)
  end, shas)
  if #picked < #shas then
    local there = vim.tbl_filter(function(sha)
      return in_head(repo, sha)
    end, shas)
    util.info("already in the history of HEAD, left out: " .. described(repo, there))
  end
  if #picked == 0 then
    return
  end
  require("diffmerge.commit").run_git(
    repo,
    vim.list_extend({ "cherry-pick" }, picked),
    require("diffmerge.operation").after(repo, {}, on_done)
  )
end

--- `X`: `shas` (oldest first) reverted, newest first: a commit undoing each (one: its message to
--- edit; `:q!` there, or an empty message, undoes the revert). A commit not in the history of
--- HEAD is asked about (the original of one cherry-picked here: fine).
function M.revert(repo, shas, on_done)
  local why = why_not(repo, true)
  local merge = not why and merge_in(repo, shas)
  if why then
    return util.warn(why)
  elseif merge then
    return util.warn(("%s is a merge commit: not reverted here"):format(util.short(merge)))
  end
  local elsewhere = vim.tbl_filter(function(sha)
    return not in_head(repo, sha)
  end, shas)
  if #elsewhere > 0 then
    local question = ("Not in the history of HEAD: %s. Revert anyway?"):format(described(repo, elsewhere))
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end
  local one = #shas == 1
  local args = { "revert", one and "--edit" or "--no-edit" }
  for i = #shas, 1, -1 do
    args[#args + 1] = shas[i]
  end
  local before = head(repo)
  local staged_before = staged(repo)
  local operation = require("diffmerge.operation")
  require("diffmerge.commit").run_git(
    repo,
    args,
    operation.after(repo, {}, function(res)
      -- the message aborted / empty: git leaves the revert staged, nothing committed (what was
      -- staged before: git refused to start)
      local failed = one and not res.ok and not staged_before and head(repo) == before
      if failed and not operation.current(repo) and staged(repo) then
        local reset = git.run(repo, { "reset", "-q", "--merge" })
        vim.cmd("silent! checktime")
        if reset.ok then
          util.info("no revert made: the files are as before")
        else
          util.warn("the revert is left staged: " .. vim.trim(reset.stderr))
        end
      end
      if on_done then
        on_done(res)
      end
    end)
  )
end

local modes = {
  { mode = "soft", text = "Soft: HEAD there, the changes since staged" },
  { mode = "mixed", text = "Mixed: HEAD there, the changes since unstaged" },
  { mode = "hard", text = "Hard: HEAD and the files there (uncommitted changes lost)" },
}

--- What a hard reset to `sha` takes away: the uncommitted changes (files), untracked files of
--- yours the commit has (written over), and the files it deletes (their buffers go).
local function hard_losses(repo, sha)
  local now = head(repo)
  local tracked = records(repo, { "ls-files", "-z" })
  local changed = now and records(repo, { "diff", "--name-only", "-z", "HEAD" }) or tracked
  local ours, dirs = {}, {}
  for _, p in ipairs(tracked) do
    ours[p] = true
    local dir = p:match("^(.*)/")
    while dir and not dirs[dir] do
      dirs[dir] = true
      dir = dir:match("^(.*)/")
    end
  end
  local theirs, overwritten = {}, {}
  for _, rec in ipairs(records(repo, { "ls-tree", "-r", "-z", sha })) do
    local kind, p = rec:match("^%S+ (%S+) %S+\t(.*)$")
    if p then
      theirs[p] = true
      -- (a submodule's checkout stays; a directory of tracked files goes with them)
      if kind ~= "commit" and not ours[p] and not dirs[p] and vim.uv.fs_lstat(repo.root .. "/" .. p) then
        overwritten[#overwritten + 1] = p
      end
    end
  end
  local gone = vim.tbl_filter(function(p)
    return not theirs[p]
  end, tracked)
  return changed, overwritten, gone
end

--- `r`: HEAD (the branch) reset to `sha`, from a menu of soft / mixed / hard; hard asks first.
function M.reset(repo, sha, on_done)
  local why = why_not(repo, false)
  if why then
    return util.warn(why)
  end
  local name = git.describe(repo, sha) or util.short(sha)
  vim.ui.select(modes, {
    prompt = "Reset to " .. name,
    format_item = function(m)
      return m.text
    end,
  }, function(choice)
    if not choice then
      return
    end
    util.after_select(function()
      local gone = {}
      if choice.mode == "hard" then
        local unsaved_why = why_not(repo, true)
        if unsaved_why then
          return util.warn(unsaved_why)
        end
        local changed, overwritten
        changed, overwritten, gone = hard_losses(repo, sha)
        local lost = {}
        if #changed > 0 then
          lost[#lost + 1] = ("Uncommitted changes in %d file(s) are lost."):format(#changed)
        end
        if #overwritten > 0 then
          lost[#lost + 1] = ("Untracked files it has are written over: %s%s"):format(
            table.concat(vim.list_slice(overwritten, 1, 5), ", "),
            #overwritten > 5 and ", …" or "."
          )
        end
        local question = ("Reset --hard to %s?%s"):format(name, #lost > 0 and (" " .. table.concat(lost, " ")) or "")
        if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
          return
        end
      end
      local before = head(repo)
      local res = git.run(repo, { "reset", "-q", "--" .. choice.mode, sha })
      if not res.ok then
        util.warn(vim.trim(res.stderr ~= "" and res.stderr or res.stdout))
      else
        vim.cmd("silent! checktime")
        if choice.mode == "hard" then
          util.drop_gone_buffers(repo.root, gone)
        end
        local old = before and (git.line(repo, { "rev-parse", "--short", before }) or util.short(before))
        local back = choice.mode == "hard" and "keep" or choice.mode
        util.info(
          ("HEAD is at %s now%s"):format(
            util.short(sha),
            old and (": it was at %s, git reset --%s %s goes back"):format(old, back, old) or ""
          )
        )
      end
      if on_done then
        on_done(res)
      end
    end)
  end)
end

--- `T`: a tag at `sha`: its name asked for, then a message (empty: a lightweight tag; Esc: no
--- tag). Signed when your config says so (annotated tags only).
function M.tag(repo, sha, on_done)
  vim.ui.input({ prompt = "Tag " .. util.short(sha) .. " as: " }, function(name)
    name = name and vim.trim(name) or ""
    if name == "" then
      return
    elseif name:match("^%-") or not git.run(repo, { "check-ref-format", "refs/tags/" .. name }).ok then
      return util.warn("not a tag name: " .. name)
    end
    util.after_select(function()
      vim.ui.input({ prompt = "Its message (empty: a lightweight tag): " }, function(message)
        if message == nil then
          return
        end
        local args = { "tag" }
        if vim.trim(message) ~= "" then
          -- (the message as written: a line starting with # is not a comment here)
          vim.list_extend(args, { "-a", "--cleanup=whitespace", "-m", message })
        else
          args[#args + 1] = "--no-sign"
        end
        vim.list_extend(args, { "--", name, sha })
        require("diffmerge.commit").run_git(repo, args, function(res)
          if res.ok then
            util.info(("tagged %s as %s"):format(util.short(sha), name))
          end
          if on_done then
            on_done(res)
          end
        end, { quiet = true })
      end)
    end)
  end)
end

return M
