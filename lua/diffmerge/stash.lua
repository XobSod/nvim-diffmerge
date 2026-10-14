--- Stashes for the status view: each one a folded section of its files, which show like a
--- change (STASH BASE | STASHED WORKING TREE | STASHED INDEX, read-only), and stashing.
local diff3 = require("diffmerge.diff3")
local git = require("diffmerge.git")
local parse = require("diffmerge.git_parse")
local source = require("diffmerge.source")
local util = require("diffmerge.util")

local M = {}

---@class diffmerge.Stash
---@field ref string stash@{n} (changes as stashes come and go)
---@field sha string
---@field subject string "On master: message" / "WIP on master: 1a2b3c subject"

--- Stashes, newest first.
---@return diffmerge.Stash[]
function M.list(repo)
  local out = git.output(repo, { "stash", "list", "--format=%gd%x09%H%x09%gs" }) or ""
  local list = {}
  for _, line in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local ref, sha, subject = line:match("^(%S+)\t(%x+)\t(.*)$")
    if ref then
      list[#list + 1] = { ref = ref, sha = sha, subject = subject }
    end
  end
  return list
end

--- The current stash@{n} of a stash, nil when it is gone.
function M.ref(repo, sha)
  for _, s in ipairs(M.list(repo)) do
    if s.sha == sha then
      return s.ref
    end
  end
end

-- what each stash changes, by its commit (a stash never changes)
local changes_of = {}

--- A stash's commit has the working tree, its first parent the commit it was made on, its
--- second the index, its third (with --include-untracked) the untracked files.
local function changes(repo, sha)
  if changes_of[sha] then
    return changes_of[sha]
  end
  local function names(a, b)
    local map = {}
    local out = git.output(repo, { "diff", "--name-status", "-z", "--no-renames", "--no-ext-diff", a, b })
    for _, r in ipairs(parse.name_status(out or "")) do
      map[r.path] = r.status
    end
    return map
  end
  local base, index = sha .. "^1", sha .. "^2"
  local c = { worktree = names(base, sha), index = names(base, index), unstaged = names(index, sha), untracked = {} }
  local u = sha .. "^3"
  if git.run(repo, { "rev-parse", "-q", "--verify", u .. "^{commit}" }).ok then
    for _, p in ipairs(parse.records(git.output(repo, { "ls-tree", "-r", "-z", "--name-only", u }) or "")) do
      if p ~= "" then
        c.untracked[#c.untracked + 1] = p
      end
    end
  end
  changes_of[sha] = c
  return c
end

--- Every file a stash touches.
function M.paths(repo, sha)
  local c = changes(repo, sha)
  local set = {}
  for _, part in ipairs({ c.worktree, c.index }) do
    for p in pairs(part) do
      set[p] = true
    end
  end
  for _, p in ipairs(c.untracked) do
    set[p] = true
  end
  return vim.tbl_keys(set)
end

--- The stashes as sections of the file panel, folded; their files as entries of the
--- HEAD | WORKING TREE | INDEX kind (only the columns that differ).
function M.sections(repo)
  local out = {}
  for _, s in ipairs(M.list(repo)) do
    local c = changes(repo, s.sha)
    local id = "stash:" .. s.sha
    local tracked = {}
    for _, part in ipairs({ c.worktree, c.index }) do
      for p in pairs(part) do
        tracked[p] = true
      end
    end
    local paths = vim.tbl_keys(tracked)
    table.sort(paths)
    local entries = {}
    for _, p in ipairs(paths) do
      local added = c.worktree[p] == "A" or c.index[p] == "A"
      local columns = { "head" }
      if c.unstaged[p] or not c.index[p] then
        columns[#columns + 1] = "worktree"
      end
      if c.index[p] then
        columns[#columns + 1] = "index"
      end
      entries[#entries + 1] = {
        kind = "stage",
        path = p,
        status = c.worktree[p] or c.index[p],
        section = id,
        key = id .. ":" .. p,
        columns = columns,
        stash = s,
        sides = {
          head = added and source.empty("(new file)", "head") or source.rev(s.sha .. "^1", p, "STASH BASE"),
          worktree = c.worktree[p] == "D" and source.empty("(deleted)", "worktree")
            or source.rev(s.sha, p, "STASHED WORKING TREE"),
          index = c.index[p] == "D" and source.empty("(deleted)", "index")
            or source.rev(s.sha .. "^2", p, "STASHED INDEX"),
        },
      }
    end
    for _, p in ipairs(c.untracked) do
      entries[#entries + 1] = {
        kind = "stage",
        path = p,
        status = "?",
        section = id,
        key = id .. ":?" .. p,
        columns = { "head", "worktree" },
        stash = s,
        sides = {
          head = source.empty("(untracked)", "head"),
          worktree = source.rev(s.sha .. "^3", p, "STASHED UNTRACKED"),
        },
      }
    end
    out[#out + 1] = { id = id, title = s.ref, hint = s.subject, entries = entries, folded = true, stash = s }
  end
  return out
end

--- `git stash push`: what = "staged" (--staged), "keep_index" (--keep-index), "all", "untracked"
--- (--include-untracked) or "paths" (those files; `untracked`: some of them are).
---@param message? string empty: git's own ("WIP on <branch>: <commit>")
---@param paths? string[]
---@return diffmerge.RunResult
function M.push(repo, what, message, paths, untracked)
  local args = { "stash", "push" }
  if what == "staged" then
    args[#args + 1] = "--staged"
  elseif what == "keep_index" then
    args[#args + 1] = "--keep-index"
  elseif what == "untracked" or (what == "paths" and untracked) then
    args[#args + 1] = "--include-untracked"
  end
  if message and message ~= "" then
    vim.list_extend(args, { "-m", message })
  end
  if what == "paths" then
    args[#args + 1] = "--"
    for _, p in ipairs(paths or {}) do
      args[#args + 1] = ":(literal)" .. p
    end
  end
  return git.run(repo, args)
end

local function failed(message)
  return { ok = false, code = 1, stdout = "", stderr = message }
end

-- modes of plain files (not links, not submodules)
local PLAIN = { ["100644"] = true, ["100755"] = true }

local function mode_of(repo, args)
  local out = git.output(repo, args) or ""
  return out:match("^(%d+) ")
end

--- The working tree file `path` without its staged change: a three-way merge (base INDEX, one
--- side the working tree, the other HEAD) in which changes on neighbouring lines stay apart.
---@return string|nil content, string? why not
local function without_staged(repo, path)
  local head = git.cat_blob(repo, "HEAD:" .. path)
  local index = git.cat_blob(repo, ":" .. path)
  local wt = util.read_file(git.abspath(repo, path))
  if not (head and index and wt) or util.is_binary(head) or util.is_binary(index) or util.is_binary(wt) then
    return nil, path .. ": git cannot take the staged change out of it"
  end
  local b, _, b_noeol = util.split_lines(index)
  local l, crlf, l_noeol = util.split_lines(wt)
  local r, _, r_noeol = util.split_lines(head)
  local chunks = diff3.compute(b, l, r, { apart = true })
  for _, c in ipairs(chunks) do
    if c.kind == "conflict" then
      return nil, path .. ": its staged and unstaged changes are on the same lines"
    end
  end
  local noeol = l_noeol
  if b_noeol ~= r_noeol then
    -- the final newline is part of the staged change
    noeol = r_noeol
  end
  return util.join_lines(diff3.result(chunks, b, l, r), crlf, noeol)
end

--- What each staged file becomes once its staged change is gone: a git command (no unstaged
--- changes in it) or its new content.
---@return table[]|nil plan, string? why not
local function plan_without_staged(repo, tree)
  local plan = {}
  local out = git.output(repo, { "diff-tree", "-r", "--name-status", "-z", "--no-renames", "HEAD", tree }) or ""
  for _, r in ipairs(parse.name_status(out)) do
    local p = r.path
    local abs = git.abspath(repo, p)
    local on_disk = vim.uv.fs_lstat(abs)
    if r.status == "D" then
      if not on_disk then
        plan[#plan + 1] = { path = p, args = { "checkout", "HEAD" } }
      elseif on_disk.type == "file" and util.read_file(abs) == git.cat_blob(repo, "HEAD:" .. p) then
        -- taken out of the index only (git rm --cached): the index gets it back
        plan[#plan + 1] = { path = p, args = { "reset", "-q" } }
      else
        return nil, p .. ": git cannot take the staged change out of it"
      end
    elseif git.run(repo, { "diff", "--quiet", "--no-ext-diff", "--", ":(literal)" .. p }).ok then
      -- no unstaged changes: the file goes back to HEAD (or away)
      plan[#plan + 1] = { path = p, args = r.status == "A" and { "rm", "-q", "-f" } or { "checkout", "HEAD" } }
    else
      local head_mode = mode_of(repo, { "ls-tree", "HEAD", "--", ":(literal)" .. p })
      local index_mode = mode_of(repo, { "ls-files", "-s", "--", ":(literal)" .. p })
      if r.status ~= "M" or not (on_disk and on_disk.type == "file") or not PLAIN[head_mode or ""] or not PLAIN[index_mode or ""] then
        return nil, p .. ": git cannot take the staged change out of it"
      end
      local content, why = without_staged(repo, p)
      if not content then
        return nil, why
      end
      plan[#plan + 1] = { path = p, content = content, mode = head_mode ~= index_mode and head_mode or nil }
    end
  end
  return plan
end

--- Stashes the staged changes only; the rest stays. git's `stash push --staged` takes them out
--- of the working tree with a patch that needs a context line, so next to unstaged changes it
--- fails after saving the stash. Then the stash is made here, the way git makes it, and each
--- file loses its staged change by plan_without_staged(); what cannot be taken apart stops it
--- before anything is changed.
---@return diffmerge.RunResult
function M.push_staged(repo, message)
  local head = git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" })
  if not head then
    return failed("You do not have the initial commit yet")
  end
  local tree, err = git.line(repo, { "write-tree" })
  if not tree then
    return failed(err or "git write-tree failed")
  end
  -- what git's own --staged takes out of the working tree
  local patch = git.run(repo, { "diff-tree", "-p", "--binary", "--no-color", "-U1", "HEAD", tree })
  if patch.ok and patch.stdout == "" then
    return failed("No staged changes")
  end
  if patch.ok and git.run(repo, { "apply", "-R", "--check" }, { stdin = patch.stdout }).ok then
    return M.push(repo, "staged", message)
  end
  local plan, why = plan_without_staged(repo, tree)
  if not plan then
    return failed(why)
  end
  -- the stash: its index and working tree both what is staged
  local branch = git.line(repo, { "symbolic-ref", "--short", "-q", "HEAD" }) or "(no branch)"
  local about = git.line(repo, { "log", "-1", "--format=%h %s", "HEAD" }) or head
  local title = message ~= "" and ("On %s: %s"):format(branch, message) or ("WIP on %s: %s"):format(branch, about)
  -- without a configured identity, git stash signs as "git stash"
  local env
  if not git.run(repo, { "var", "GIT_COMMITTER_IDENT" }).ok then
    env = { GIT_AUTHOR_NAME = "git stash", GIT_AUTHOR_EMAIL = "git@stash" }
    env.GIT_COMMITTER_NAME, env.GIT_COMMITTER_EMAIL = env.GIT_AUTHOR_NAME, env.GIT_AUTHOR_EMAIL
  end
  local function commit(args)
    local res = git.run(repo, args, { env = env })
    return res.ok and vim.trim(res.stdout) or nil, res
  end
  local index, res = commit({ "commit-tree", tree, "-p", head, "-m", "index on " .. branch .. ": " .. about })
  local stash_commit
  if index then
    stash_commit, res = commit({ "commit-tree", tree, "-p", head, "-p", index, "-m", title })
  end
  if not stash_commit then
    return res
  end
  local stored = git.run(repo, { "stash", "store", "-m", title, stash_commit })
  if not stored.ok then
    return stored
  end
  for _, step in ipairs(plan) do
    local spec = ":(literal)" .. step.path
    if step.content then
      local abs = git.abspath(repo, step.path)
      local f = io.open(abs, "wb")
      if not f then
        return failed("cannot write " .. step.path .. " (the stash is saved: " .. title .. ")")
      end
      f:write(step.content)
      f:close()
      if step.mode then
        vim.uv.fs_chmod(abs, tonumber(step.mode:sub(-3), 8))
      end
      git.run(repo, { "reset", "-q", "--", spec })
    else
      git.run(repo, vim.list_extend(vim.deepcopy(step.args), { "--", spec }))
    end
  end
  return { ok = true, code = 0, stdout = "Saved working directory and index state " .. title, stderr = "" }
end

return M
