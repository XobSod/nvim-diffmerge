--- Rewriting the history of the current branch from the log: what is staged made part of a
--- commit (fixup), a commit squashed into its parent, reworded, dropped. Each is a
--- `git rebase -i --autostash` whose todo list scripts/rebase-todo.lua changes; messages are
--- edited here (commit.run_git), conflicts stop it like any rebase (operation.lua).
local git = require("diffmerge.git")
local util = require("diffmerge.util")

local M = {}

-- by git dir: the rewrite going on, for what to say when it is over (also when it stopped on the
-- way and was continued or aborted): { before = HEAD then, fixup = the fixup commit made }
local pending = {}

local function ok(repo, args)
  return git.run(repo, args).ok
end

local function names(repo, args)
  return vim.split(git.output(repo, args) or "", "\n", { trimempty = true })
end

local function head(repo)
  return git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" })
end

--- Why the history up to `sha` cannot be rewritten now (nil: it can).
---@param parent? boolean the commit's parent is rewritten too (squash)
local function why_not(repo, sha, parent)
  local op = require("diffmerge.operation").current(repo)
  if op then
    return ("a %s is in progress: finish it first"):format(git.operation_name(op))
  end
  local commit = require("diffmerge.commit")
  if commit.running() then
    return commit.busy_message(repo)
  end
  local blocked = commit.blocked(repo, false)
  if blocked then
    return blocked
  end
  local unsaved = require("diffmerge.remote").unsaved(repo)
  if #unsaved > 0 then
    return "unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first"
  end
  if not ok(repo, { "merge-base", "--is-ancestor", sha, "HEAD" }) then
    return ("%s is not in the history of HEAD: only your branch is rewritten"):format(util.short(sha))
  end
  local from = sha
  if parent then
    from = git.rev_parse(repo, sha .. "^")
    if not from then
      return "the first commit has no parent to squash it into"
    end
  end
  for _, c in ipairs({ sha, from }) do
    local line = names(repo, { "rev-list", "--parents", "-n", "1", c })[1] or ""
    if #vim.split(line, " ", { trimempty = true }) > 2 then
      return "a merge commit is not rewritten here"
    end
  end
  if #names(repo, { "rev-list", "--merges", "-n", "1", from .. "..HEAD" }) > 0 then
    return "merges after it: not rewritten here"
  end
end

--- The base of the rebase: `sha`'s parent (its grandparent for a squash), or the root.
local function base_args(repo, sha, parent)
  local base = git.rev_parse(repo, sha .. (parent and "^^" or "^"))
  return base and { base } or { "--root" }
end

--- `sha`, the oldest commit rewritten, already in the upstream branch: pushing afterwards needs
--- --force-with-lease. Asked.
local function pushed_ok(repo, sha, what)
  local upstream = git.line(repo, { "rev-parse", "-q", "--verify", "--symbolic-full-name", "@{upstream}" })
  if not upstream or not ok(repo, { "merge-base", "--is-ancestor", sha, "@{upstream}" }) then
    return true
  end
  local name = upstream:gsub("^refs/remotes/", ""):gsub("^refs/heads/", "")
  local question = ("%s is pushed already (in %s): after %s, pushing it needs --force-with-lease (P offers it). Go on?"):format(
    git.describe(repo, sha) or util.short(sha),
    name,
    what
  )
  return vim.fn.confirm(question, "&Yes\n&No", 2) == 1
end

--- When the rewrite of `repo` is over (not when it stopped on the way; also when it was
--- finished elsewhere): where the branch was, to go back to; a fixup that did not happen
--- (refused, aborted) takes its commit back, what it took is staged again; one skipped says
--- where the fix is.
function M.finished(repo)
  local p = pending[repo.gitdir]
  if not p or require("diffmerge.operation").current(repo) or require("diffmerge.commit").running() then
    return
  end
  pending[repo.gitdir] = nil
  local now = head(repo)
  if p.fixup and now == p.fixup then
    git.run(repo, { "reset", "-q", "--soft", p.before })
    util.info("no fixup made: what was staged is staged again")
  elseif p.fixup and now == p.before then
    util.warn(("the fixup was skipped: git cherry-pick -n %s stages it again"):format(util.short(p.fixup)))
  elseif now ~= p.before then
    local old = git.line(repo, { "rev-parse", "--short", p.before }) or util.short(p.before)
    util.info(
      p.fixup and ("fixed up; the branch was at %s before: git reset --soft %s undoes it (the fix staged again)"):format(old, old)
        or ("the branch was at %s before: git reset --keep %s brings it back"):format(old, old)
    )
  end
end

--- `git rebase -i --no-autosquash --autostash <base>` whose todo list rebase-todo.lua changes
--- (`todo`: its DIFFMERGE_TODO). `:q!` in a message window of it aborts it all.
local function rebase(repo, base, todo, on_done)
  local commit = require("diffmerge.commit")
  local operation = require("diffmerge.operation")
  local args = vim.list_extend({ "rebase", "-i", "--no-autosquash", "--autostash" }, base)
  local function over(res)
    M.finished(repo)
    if on_done then
      on_done(res)
    end
  end
  commit.run_git(repo, args, function(res)
    if res.aborted and operation.current(repo) then
      util.info("the message aborted: the rewrite is undone")
      return commit.run_git(repo, { "rebase", "--abort" }, operation.after(repo, {}, over))
    end
    operation.after(repo, {}, over)(res)
  end, { env = { GIT_SEQUENCE_EDITOR = commit.script_command("rebase-todo.lua"), DIFFMERGE_TODO = todo } })
end

--- `cf`: what is staged becomes part of `sha` (`git commit --fixup`, then the rebase that
--- puts it right after `sha` as a fixup).
function M.fixup(repo, sha, on_done)
  local why = why_not(repo, sha)
  if why then
    return util.warn(why)
  elseif ok(repo, { "diff", "--cached", "--quiet" }) then
    return util.warn("nothing is staged to fix " .. util.short(sha) .. " up with")
  elseif not pushed_ok(repo, sha, "the fixup") then
    return
  end
  local before = head(repo)
  require("diffmerge.commit").run_git(repo, { "commit", "--fixup=" .. sha }, function(res)
    local fixup = head(repo)
    if not res.ok or fixup == before then
      if on_done then
        on_done(res)
      end
      return
    end
    pending[repo.gitdir] = { before = before, fixup = fixup }
    rebase(repo, base_args(repo, sha), ("move-fixup %s %s"):format(fixup, sha), on_done)
  end)
end

--- `cs`, `cr`, `cd`: `sha` squashed into its parent / reworded / dropped.
local function rewrite(repo, sha, command, what, on_done)
  local parent = command == "squash"
  local why = why_not(repo, sha, parent)
  if why then
    return util.warn(why)
  end
  if command == "drop" then
    local question = ("Drop %s? Its changes go away from the branch."):format(git.describe(repo, sha) or util.short(sha))
    if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end
  if not pushed_ok(repo, parent and git.rev_parse(repo, sha .. "^") or sha, what) then
    return
  end
  pending[repo.gitdir] = { before = head(repo) }
  rebase(repo, base_args(repo, sha, parent), command .. " " .. sha, on_done)
end

--- `cs`: `sha` squashed into its parent, both messages to edit into one.
function M.squash(repo, sha, on_done)
  rewrite(repo, sha, "squash", "squashing it", on_done)
end

--- `cr`: the message of `sha` to edit.
function M.reword(repo, sha, on_done)
  rewrite(repo, sha, "reword", "rewording it", on_done)
end

--- `cd`: `sha` left out of the branch (asked first).
function M.drop(repo, sha, on_done)
  rewrite(repo, sha, "drop", "dropping it", on_done)
end

return M
