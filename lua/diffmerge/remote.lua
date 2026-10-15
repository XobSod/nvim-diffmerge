--- git operations in the background (fetch, pull, push; switch and its stash steps), one at a
--- time per repository. While one runs, starting another offers to stop it (git and its hooks,
--- a process group of their own); quitting Neovim waits for them a while.
local git = require("diffmerge.git")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

M.kinds = { fetch = true, pull = true, push = true }

-- by git dir: { what = what the user started ("fetch", "pull", "push", "switch"), proc, stopped }
local running = {}
-- branches whose upstream you did not want set after a push (this session)
local untracked_ok = {}

--- git's output as you would read it: what it reports first (stderr: "From", "To"), then what
--- it did (stdout); of progress lines (\r) the last state; no hints, no empty remote lines.
local function lines_of(res)
  local out = {}
  for _, text in ipairs({ res.stderr or "", res.stdout or "" }) do
    for _, raw in ipairs(vim.split(text, "\n", { trimempty = true })) do
      local parts = vim.split(raw, "\r", { trimempty = true })
      local l = (parts[#parts] or ""):gsub("%s+$", "")
      if l ~= "" and not l:match("^hint:") and not l:match("^remote:%s*$") then
        out[#out + 1] = l
      end
    end
  end
  return out
end

local MAX = 12

--- At most MAX lines: on success the last ones, on failure git's errors (or the first ones).
local function shown(lines, failed)
  if #lines <= MAX then
    return table.concat(lines, "\n")
  end
  if failed then
    local errors = vim.tbl_filter(function(l)
      return l:match("^error:") or l:match("^fatal:") or l:match("^%s*! %[") or l:match("^CONFLICT")
    end, lines)
    if #errors > 0 then
      return table.concat(vim.list_slice(errors, 1, MAX), "\n")
    end
    return table.concat(vim.list_slice(lines, 1, MAX), "\n") .. "\n…"
  end
  local n = #lines - MAX
  return ("(%d %s before)\n"):format(n, n == 1 and "line" or "lines") .. table.concat(vim.list_slice(lines, n + 1), "\n")
end

--- "↑1 ↓2 origin/master", "up to date with origin/master" or nil (no upstream).
function M.tracking(repo)
  local upstream = git.line(repo, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  if not upstream then
    return nil
  end
  local counts = git.line(repo, { "rev-list", "--left-right", "--count", "HEAD...@{u}" }) or ""
  local ahead, behind = counts:match("^(%d+)%s+(%d+)$")
  ahead, behind = tonumber(ahead) or 0, tonumber(behind) or 0
  if ahead == 0 and behind == 0 then
    return "up to date with " .. upstream
  end
  local parts = {}
  if ahead > 0 then
    parts[#parts + 1] = "↑" .. ahead
  end
  if behind > 0 then
    parts[#parts + 1] = "↓" .. behind
  end
  return table.concat(parts, " ") .. " " .. upstream
end

--- What is running in the repository: "fetch", "pull", "push", "switch" or nil.
function M.running(repo)
  local r = running[repo.gitdir]
  return r and r.what
end

---@param plain? boolean without where the branch stands (switching, stashing)
local function report(repo, res, what, done, extra, plain)
  if res.stopped then
    return
  end
  local text = shown(lines_of(res), not res.ok)
  local where = not plain and M.tracking(repo) or nil
  local parts = vim.tbl_filter(function(p)
    return p and p ~= ""
  end, { text, extra, where })
  if res.ok then
    util.info(#parts > 0 and table.concat(parts, "\n") or (done or ("git " .. what .. ": done")))
  else
    util.warn(#parts > 0 and table.concat(parts, "\n") or ("git " .. what .. " failed"))
  end
end

-- quitting Neovim while git runs would cut it off (its output goes nowhere): wait a while,
-- without questions (`leaving`)
local leave_hook, leaving
local function wait_on_leave()
  if leave_hook then
    return
  end
  leave_hook = api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      leaving = true
      if next(running) == nil then
        return
      end
      local names = {}
      for _, r in pairs(running) do
        names[#names + 1] = "git " .. r.what
      end
      util.info("waiting for " .. table.concat(names, ", ") .. " to finish …")
      vim.wait(20000, function()
        return next(running) == nil
      end, 50)
      -- what does not end in time is stopped (a connection that hangs)
      for _, r in pairs(running) do
        pcall(vim.uv.kill, -r.proc.pid, "sigterm")
      end
    end,
  })
end

local function changed_files(repo)
  return git.output(repo, { "status", "--porcelain", "--untracked-files=no" }) or ""
end

--- After a stopped pull or switch: what it left (`before`: the changed files when it started).
local function after_stop(repo, what, before)
  local op = git.operation(repo)
  if op then
    util.warn(("git %s stopped in the middle of a %s: git %s --abort undoes it"):format(what, op.kind, op.kind))
  elseif changed_files(repo) ~= before then
    util.warn(("git %s stopped: files may be half updated (the status view shows them)"):format(what))
  else
    util.info(("git %s stopped"):format(what))
  end
end

-- operations that change the work tree: stopping them can leave it half updated
local CHANGES_FILES = { pull = true, switch = true }

--- Runs `git <what> <args>`; `on_done(res)` when git is finished.
---@param opts? { as?: string, quiet?: boolean } as: the operation it is a step of (shown, stopped as that); quiet: no "running" notice
local function run(repo, what, args, on_done, opts)
  opts = opts or {}
  local busy = running[repo.gitdir]
  if busy then
    if leaving then
      return
    end
    local question = ("git %s is still running. Stop it?"):format(busy.what)
    if CHANGES_FILES[busy.what] then
      question = ("git %s is still running. Stopping it can leave files half updated. Stop it?"):format(busy.what)
    end
    if vim.fn.confirm(question, "&Yes\n&No", 2) == 1 then
      busy.stopped = true
      pcall(vim.uv.kill, -busy.proc.pid, "sigterm")
    end
    return
  end
  local shown_as = opts.as or what
  local this = { what = shown_as, files = CHANGES_FILES[shown_as] and changed_files(repo) or nil }
  running[repo.gitdir] = this
  wait_on_leave()
  this.proc = git.run_async(repo, vim.list_extend({ what }, args), { detach = true }, function(res)
    running[repo.gitdir] = nil
    if this.stopped then
      res.stopped, res.ok = true, false
      if CHANGES_FILES[shown_as] then
        after_stop(repo, shown_as, this.files)
      else
        util.info("git " .. shown_as .. " stopped")
      end
    end
    on_done(res)
  end)
  -- most of them are done by then: a word only when it takes a while
  vim.defer_fn(function()
    if running[repo.gitdir] == this and not leaving and not opts.quiet then
      util.info(("git %s is running … (F, p, P or b stops it)"):format(shown_as))
    end
  end, 3000)
end

--- `git <what> <args>` in the background, one at a time per repository (see the top).
M.run = run
M.report = report

--- Files of the repository with unsaved changes in their buffers.
function M.unsaved(repo)
  local out = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.startswith(name, repo.root .. "/") then
      out[#out + 1] = git.relpath(repo, name)
    end
  end
  return out
end

---@param on_done? fun(res: diffmerge.RunResult)
function M.fetch(repo, args, on_done)
  run(repo, "fetch", args or {}, function(res)
    report(repo, res, "fetch", "nothing new")
    if on_done then
      on_done(res)
    end
  end)
end

--- `git pull` (your git config decides how: pull.ff, pull.rebase). Not in the middle of a
--- merge or rebase or a commit; files with unsaved changes have to be saved first: pull changes
--- the files under them.
function M.pull(repo, args, on_done)
  if running[repo.gitdir] then
    -- (the pull's own rebase is not a reason not to stop it)
    return run(repo, "pull", args or {}, on_done)
  end
  local op = git.operation(repo)
  if op then
    util.warn(("a %s is in progress: finish it first"):format(op.kind))
    return
  end
  if require("diffmerge.commit").running() then
    util.warn("a commit is running: finish it first (:wq commits, :q! aborts)")
    return
  end
  local unsaved = M.unsaved(repo)
  if #unsaved > 0 then
    util.warn("unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first")
    return
  end
  run(repo, "pull", args or {}, function(res)
    vim.cmd("silent! checktime")
    report(repo, res, "pull")
    if on_done then
      on_done(res)
    end
  end)
end

--- The remote a branch goes to: its pushRemote, remote.pushDefault, its remote, origin, the only
--- one; several: asked when `ask`. `cb(remote)` (nil: none / not asked / cancelled).
local function push_remote(repo, branch, ask, cb)
  for _, key in ipairs({ "branch." .. branch .. ".pushRemote", "remote.pushDefault", "branch." .. branch .. ".remote" }) do
    local r = git.line(repo, { "config", "--get", key })
    if r and r ~= "" then
      return cb(r)
    end
  end
  local remotes = vim.split(git.output(repo, { "remote" }) or "", "\n", { trimempty = true })
  if vim.tbl_contains(remotes, "origin") then
    return cb("origin")
  elseif #remotes == 1 then
    return cb(remotes[1])
  elseif #remotes == 0 or not ask then
    return cb(nil)
  end
  vim.ui.select(remotes, { prompt = "Push " .. branch .. " to" }, function(choice)
    util.after_select(function()
      cb(choice)
    end)
  end)
end

--- The refs a push left out: { src, dst, why } of "! [rejected] src -> dst (why)".
local function rejected(text)
  local out = {}
  for line in text:gmatch("[^\n]+") do
    local src, dst, why = line:match("^%s*! %[rejected%]%s+(%S+)%s+%->%s+(%S+)%s+%((.-)%)")
    if src then
      out[#out + 1] = { src = src, dst = dst, why = why }
    end
  end
  return out
end

--- `git push`.
---   no upstream (git says so, or there is no push destination): offered to push the branch to
---     its remote and track it there; pushed without one (push.default = current): offered to
---     track it;
---   rejected, the remote's branch has commits that are not here: when this branch was built on
---     them (a rebase), offered --force-with-lease --force-if-includes (it overwrites only what
---     was fetched last and is in this branch's history; never --force); not fetched yet: F / p.
function M.push(repo, args, on_done)
  args = args or {}
  local function finish(res)
    if on_done then
      on_done(res)
    end
  end
  local options_only = vim.iter(args):all(function(a)
    return a:match("^%-") ~= nil
  end)
  run(repo, "push", args, function(res)
    local text = (res.stdout or "") .. "\n" .. (res.stderr or "")
    -- (its whole name: --short would say heads/x next to a tag x)
    local ref = git.line(repo, { "symbolic-ref", "-q", "HEAD" })
    local branch = ref and ref:gsub("^refs/heads/", "")
    if res.stopped then
      return finish(res)
    end
    if res.ok then
      local upstream = git.line(repo, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
      if branch and not upstream and options_only and not leaving and not untracked_ok[repo.gitdir .. ":" .. branch] then
        return push_remote(repo, branch, false, function(remote)
          report(repo, res, "push")
          local ref = remote and ("refs/remotes/%s/%s"):format(remote, branch)
          if ref and git.run(repo, { "rev-parse", "-q", "--verify", ref }).ok then
            local question = ("%s has no upstream branch. Track %s/%s (git branch --set-upstream-to)? Then pull and push know where it goes, and ↑↓ show how far."):format(
              branch,
              remote,
              branch
            )
            if vim.fn.confirm(question, "&Yes\n&No", 1) == 1 then
              if git.run(repo, { "branch", "--set-upstream-to=" .. remote .. "/" .. branch }).ok then
                util.info(M.tracking(repo) or (branch .. " tracks " .. remote .. "/" .. branch))
              end
            else
              untracked_ok[repo.gitdir .. ":" .. branch] = true
            end
          end
          finish(res)
        end)
      end
      report(repo, res, "push")
      return finish(res)
    end
    local no_upstream = text:find("has no upstream branch", 1, true) or text:find("No configured push destination", 1, true)
    if branch and no_upstream and options_only and not leaving then
      return push_remote(repo, branch, true, function(remote)
        if not remote then
          report(repo, res, "push")
          return finish(res)
        end
        local again = vim.list_extend({ "--set-upstream", remote, branch }, args)
        local question = ("%s has no upstream branch. Push it to %s and track it there (git push %s)?"):format(
          branch,
          remote,
          table.concat(again, " ")
        )
        if vim.fn.confirm(question, "&Yes\n&No", 1) ~= 1 then
          report(repo, res, "push")
          return finish(res)
        end
        run(repo, "push", again, function(res2)
          report(repo, res2, "push")
          finish(res2)
        end)
      end)
    end
    local refused = rejected(text)
    local mine = #refused == 1 and refused[1].src == branch and refused[1]
    if mine and mine.why == "fetch first" then
      report(repo, res, "push", nil, "the remote has commits that are not here: F fetches them, p pulls them")
      return finish(res)
    elseif mine and mine.why == "stale info" then
      report(repo, res, "push", nil, "the remote changed since the last fetch: F fetches it")
      return finish(res)
    elseif mine and mine.why == "non-fast-forward" and not leaving then
      local remote = branch and push_remote(repo, branch, false, function(r)
        return r
      end)
      local theirs = remote and git.line(repo, { "rev-parse", "-q", "--verify", ("refs/remotes/%s/%s"):format(remote, mine.dst) })
      if theirs and git.run(repo, { "merge-base", "--is-ancestor", "HEAD", theirs }).ok then
        report(repo, res, "push", nil, "nothing here that the remote does not have: p pulls")
        return finish(res)
      end
      -- what --force-if-includes allows: the remote's branch, as fetched, is in your branch's
      -- history (its reflog: you rewrote on top of it)
      local reflog = vim.split(git.output(repo, { "rev-list", "-g", "--max-count=500", branch }) or "", "\n", { trimempty = true })
      local built_on = theirs
        and #reflog > 0
        and (git.output(repo, vim.list_extend({ "rev-list", "--max-count=1", theirs, "--not" }, reflog)) or "x") == ""
      if not built_on then
        report(repo, res, "push", nil, "the remote has commits that are not in yours: p pulls them")
        return finish(res)
      end
      local question = ("%s on the remote has commits that are not in yours. Overwrite them with yours "
        .. "(git push --force-with-lease --force-if-includes: your branch was rewritten on top of "
        .. "them, e.g. amended or rebased)?"):format(mine.dst)
      if vim.fn.confirm(question, "&Yes\n&No", 2) == 1 then
        local again = vim.list_extend(vim.deepcopy(args), { "--force-with-lease", "--force-if-includes" })
        return run(repo, "push", again, function(res2)
          local extra
          local why = (res2.stderr or "") .. (res2.stdout or "")
          if not res2.ok and (why:find("stale info", 1, true) or why:find("updated since checkout", 1, true)) then
            extra = "the remote changed since the last fetch: F fetches it, p pulls it"
          end
          report(repo, res2, "push", nil, extra)
          finish(res2)
        end)
      end
    end
    report(repo, res, "push")
    finish(res)
  end)
end

return M
