--- Switching branches: `git switch`, from a picker of the local branches and the remote ones
--- without a local branch yet, or to a new one. Uncommitted changes in the way: offered to stash
--- them, switch, and bring them back there.
local git = require("diffmerge.git")
local remote = require("diffmerge.remote")
local stash = require("diffmerge.stash")
local util = require("diffmerge.util")

local M = {}

local function lines(out)
  return vim.split(out or "", "\n", { trimempty = true })
end

--- What the picker offers: local branches (most recent first; the current one marked), remote
--- branches without a local one of that name, and a new branch.
---@return { kind: "local"|"remote"|"new", name?: string, current?: boolean, track?: string, when?: string }[]
function M.choices(repo)
  local current = git.line(repo, { "symbolic-ref", "-q", "HEAD" })
  local out, mine = {}, {}
  -- (lstrip, not short: a tag of the same name would make it "heads/x")
  local format = "--format=%(refname)%09%(refname:lstrip=2)%09%(upstream:track)%09%(committerdate:relative)"
  for _, l in ipairs(lines(git.output(repo, { "for-each-ref", "--sort=-committerdate", format, "refs/heads" }))) do
    local full, name, track, when = l:match("^(.-)\t(.-)\t(.-)\t(.*)$")
    if name then
      mine[name] = true
      out[#out + 1] = { kind = "local", name = name, current = full == current, track = track, when = when }
    end
  end
  format = "--format=%(refname:lstrip=2)%09%(symref)%09%(committerdate:relative)"
  for _, l in ipairs(lines(git.output(repo, { "for-each-ref", "--sort=-committerdate", format, "refs/remotes" }))) do
    local name, symref, when = l:match("^(.-)\t(.-)\t(.*)$")
    local branch = name and symref == "" and name:match("^[^/]+/(.+)$")
    if branch and not mine[branch] then
      out[#out + 1] = { kind = "remote", name = name, when = when }
    end
  end
  out[#out + 1] = { kind = "new" }
  return out
end

local function label(c)
  if c.kind == "new" then
    return "+ a new branch from here"
  elseif c.kind == "remote" then
    return ("  %s  (remote, %s)"):format(c.name, c.when)
  end
  local track = c.track ~= "" and (" " .. c.track) or ""
  return ("%s %s%s  (%s)"):format(c.current and "*" or " ", c.name, track, c.when)
end

--- Where `git switch <args>` goes, for messages: the branch it creates (-c), the one it tracks
--- (--track), else the last word that is not an option.
local function target(args)
  for i, a in ipairs(args) do
    local next_word = args[i + 1]
    local names = a == "-c" or a == "-C" or a == "--create" or a == "--force-create" or a == "--track"
    if names and next_word and not next_word:match("^%-") then
      return next_word
    end
  end
  for i = #args, 1, -1 do
    if not args[i]:match("^%-") then
      return args[i]
    end
  end
  return vim.tbl_contains(args, "--detach") and "a detached HEAD" or "it"
end

--- Where HEAD is: the branch (its whole name: --short would say heads/x next to a tag x), or
--- the commit when detached.
local function head(repo)
  local ref = git.line(repo, { "symbolic-ref", "-q", "HEAD" })
  return ref and ref:gsub("^refs/heads/", "") or git.line(repo, { "rev-parse", "-q", "--short", "--verify", "HEAD" })
end

--- HEAD's branch and commit: a switch moved it when this changed (also `switch -C` of the
--- branch you are on).
local function position(repo)
  return (git.line(repo, { "symbolic-ref", "-q", "HEAD" }) or "") .. "@" .. (git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" }) or "")
end

--- The files a switch took away: in the commit it left, not in the one it went to.
local function removed(repo, from, to)
  local a, b = from:match("@(.*)$"), to:match("@(.*)$")
  if a == "" or b == "" or a == b then
    return {}
  end
  return lines(git.output(repo, { "diff", "--name-only", "--no-renames", "--diff-filter=D", a, b }))
end

--- The untracked files git names as in the way ("would be overwritten").
local function untracked_in_the_way(text)
  local out, inside = {}, false
  for l in text:gmatch("[^\n]+") do
    if l:find("untracked working tree files would be overwritten", 1, true) then
      inside = true
    elseif inside and l:match("^\t") then
      out[#out + 1] = vim.trim(l)
    elseif inside then
      inside = false
    end
  end
  return out
end

local function after_switch(repo, from, to)
  vim.cmd("silent! checktime")
  util.drop_gone_buffers(repo.root, removed(repo, from, to))
end

local function switched(repo, note)
  local where = remote.tracking(repo)
  util.info(("switched to %s%s"):format(head(repo) or "?", note or "") .. (where and ("\n" .. where) or ""))
end

--- Stash, switch, pop: the uncommitted changes go along. The stash is found again by its commit:
--- other stashes are left alone.
---@param refused diffmerge.RunResult git's first answer (what is in the way)
local function carry(repo, args, refused, on_done)
  local to = target(args)
  local named = "your changes are in the stash \"DiffMerge: switching to " .. to .. "\""
  local before_stash = git.line(repo, { "rev-parse", "-q", "--verify", "refs/stash" })
  local before = position(repo)
  local step = { as = "switch", quiet = true }
  remote.run(repo, "stash", { "push", "-m", "DiffMerge: switching to " .. to }, function(stashed)
    local sha = git.line(repo, { "rev-parse", "-q", "--verify", "refs/stash" })
    if not stashed.ok or not sha or sha == before_stash then
      if sha and sha ~= before_stash then
        -- stopped after saving
        util.warn(named)
      elseif not stashed.stopped then
        -- nothing saved (files git does not look at: skip-worktree, assume-unchanged)
        remote.report(repo, refused, "switch", nil, "nothing could be stashed: not switched", true)
      end
      return on_done(stashed)
    end
    local function pop(cb)
      local ref = stash.ref(repo, sha)
      if not ref then
        -- (dropped meanwhile: never another stash in its place)
        return cb({ ok = false, code = 1, stdout = "", stderr = "the stash is gone" }, false)
      end
      remote.run(repo, "stash", { "pop", "--index", ref }, function(popped)
        if popped.stopped and stash.ref(repo, sha) then
          util.warn(named)
        end
        local why = ((popped.stderr or "") .. (popped.stdout or "")):lower()
        if not popped.ok and not popped.stopped and why:find("conflicts in index", 1, true) then
          -- the staged part does not fit the index here: back as unstaged changes
          local again_ref = stash.ref(repo, sha)
          if not again_ref then
            return cb(popped, false)
          end
          return remote.run(repo, "stash", { "pop", again_ref }, function(again)
            cb(again, true)
          end, step)
        end
        cb(popped, false)
      end, step)
    end
    remote.run(repo, "switch", args, function(res)
      if res.stopped then
        util.warn(named)
        return on_done(res)
      end
      local after = position(repo)
      if after == before then
        -- not switched: the changes come back where they were
        return pop(function(popped)
          vim.cmd("silent! checktime")
          remote.report(repo, res, "switch", nil, nil, true)
          if not popped.ok then
            util.warn(named)
          end
          on_done(res)
        end)
      end
      if not res.ok then
        -- switched, but a post-checkout hook failed: what it said
        remote.report(repo, res, "switch", nil, nil, true)
      end
      pop(function(popped, unstaged)
        after_switch(repo, before, after)
        if popped.ok then
          switched(repo, unstaged and ", your changes with you (what was staged is unstaged now: it did not fit the index there)"
            or ", your changes with you")
        elseif not popped.stopped then
          util.warn(
            ("switched to %s; your changes do not apply cleanly here: resolve them under Conflicts (the stash \"DiffMerge: switching to %s\" stays until you drop it)"):format(
              head(repo) or to,
              to
            )
          )
        end
        on_done(popped)
      end)
    end, step)
  end, step)
end

--- Why a switch cannot start now (nil: it can).
local function not_now(repo)
  local op = git.operation(repo)
  if op then
    return ("a %s is in progress: finish it first"):format(op.kind)
  elseif require("diffmerge.commit").running() then
    return "a commit is running: finish it first (:wq commits, :q! aborts)"
  end
  local unsaved = remote.unsaved(repo)
  if #unsaved > 0 then
    return "unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first"
  end
end

--- `git switch <args>`. Not during a merge, rebase or commit; files with unsaved changes have to
--- be saved first; while another git operation runs: offered to stop it. Uncommitted changes in
--- the way: offered to stash them, switch, and pop them there; untracked files in the way are
--- named (the branch has its own files there).
---@param on_done? fun(res: diffmerge.RunResult)
function M.switch(repo, args, on_done)
  on_done = on_done or function() end
  if remote.running(repo) then
    return remote.run(repo, "switch", args, on_done)
  end
  local why = not_now(repo)
  if why then
    util.warn(why)
    return
  end
  local before = position(repo)
  remote.run(repo, "switch", args, function(res)
    if res.stopped then
      return on_done(res)
    end
    local text = (res.stderr or "") .. (res.stdout or "")
    local untracked = untracked_in_the_way(text)
    if #untracked > 0 then
      util.warn(
        ("%s has its own %s: move %s away first (untracked here)"):format(
          target(args),
          table.concat(untracked, ", "),
          #untracked == 1 and "it" or "them"
        )
      )
      return on_done(res)
    end
    if text:find("Your local changes to the following files would be overwritten", 1, true) then
      local question = ("Uncommitted changes are in the way. Stash them, switch to %s, and bring them back there?"):format(
        target(args)
      )
      if vim.fn.confirm(question, "&Yes\n&No", 1) == 1 then
        return carry(repo, args, res, on_done)
      end
      remote.report(repo, res, "switch", nil, nil, true)
      return on_done(res)
    end
    local after = position(repo)
    if after ~= before then
      after_switch(repo, before, after)
      if not res.ok then
        -- switched, but a post-checkout hook failed: what it said
        remote.report(repo, res, "switch", nil, nil, true)
      end
      switched(repo)
    else
      remote.report(repo, res, "switch", nil, nil, true)
    end
    on_done(res)
  end)
end

--- The picker: switch to the branch chosen (a remote one: a local branch tracking it), or a new
--- one from here.
function M.pick(repo, on_done)
  if remote.running(repo) then
    return remote.run(repo, "switch", {}, function() end)
  end
  local why = not_now(repo)
  if why then
    util.warn(why)
    return
  end
  vim.ui.select(M.choices(repo), { prompt = "Switch to", format_item = label }, function(c)
    if not c then
      return
    end
    util.after_select(function()
      if c.kind == "local" and c.current then
        util.info("already on " .. c.name)
      elseif c.kind == "local" then
        M.switch(repo, { c.name }, on_done)
      elseif c.kind == "remote" then
        M.switch(repo, { "--track", c.name }, on_done)
      else
        vim.ui.input({ prompt = "New branch: " }, function(name)
          if not name or vim.trim(name) == "" then
            return
          end
          name = vim.trim(name)
          if not git.run(repo, { "check-ref-format", "--branch", name }).ok then
            util.warn(("not a branch name: %s"):format(name))
            return
          end
          M.switch(repo, { "-c", name }, on_done)
        end)
      end
    end)
  end)
end

return M
