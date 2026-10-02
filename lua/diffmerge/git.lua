--- Git runner and plumbing helpers.
--- Every call is hardened against user config that would change the output format.
local M = {}

M.binary = "git"

-- Config overrides applied to every git call made by DiffMerge.
local config_overrides = {
  "core.quotePath=false",
  "color.ui=false",
  "log.showSignature=false",
  "log.follow=false",
  "diff.noprefix=false",
  "diff.mnemonicPrefix=false",
  "diff.relative=false",
  "status.relativePaths=false",
}

local env = {
  GIT_OPTIONAL_LOCKS = "0",
  GIT_TERMINAL_PROMPT = "0",
  GIT_PAGER = "cat",
  PAGER = "cat",
}

---@class diffmerge.Repo
---@field root string absolute path of the work tree
---@field gitdir string absolute path of the git dir

local function build_cmd(args)
  local cmd = { M.binary, "--no-pager" }
  for _, c in ipairs(config_overrides) do
    cmd[#cmd + 1] = "-c"
    cmd[#cmd + 1] = c
  end
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  return cmd
end

M.build_cmd = build_cmd

local function cwd_of(repo)
  if type(repo) == "string" then
    return repo
  end
  return repo and repo.root or nil
end

---@class diffmerge.RunResult
---@field ok boolean
---@field code integer
---@field stdout string
---@field stderr string
---@field signal? integer the signal that ended git (a timeout ends it too)

--- Runs git synchronously.
---@param repo diffmerge.Repo|string|nil repo or cwd
---@param args string[]
---@param opts? { stdin?: string, timeout?: integer }
---@return diffmerge.RunResult
function M.run(repo, args, opts)
  opts = opts or {}
  local ok, obj = pcall(vim.system, build_cmd(args), {
    cwd = cwd_of(repo),
    env = env,
    stdin = opts.stdin,
    text = false,
  })
  if not ok then
    return { ok = false, code = -1, stdout = "", stderr = tostring(obj) }
  end
  local res = obj:wait(opts.timeout or 30000)
  return {
    ok = res.code == 0,
    code = res.code,
    stdout = res.stdout or "",
    stderr = res.stderr or "",
    signal = res.signal,
  }
end

--- Runs git asynchronously; `cb` is called on the main loop.
---@param cb fun(res: diffmerge.RunResult)
function M.run_async(repo, args, opts, cb)
  opts = opts or {}
  local ok, err = pcall(vim.system, build_cmd(args), {
    cwd = cwd_of(repo),
    env = env,
    stdin = opts.stdin,
    text = false,
  }, function(res)
    vim.schedule(function()
      cb({ ok = res.code == 0, code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" })
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb({ ok = false, code = -1, stdout = "", stderr = tostring(err) })
    end)
  end
end

--- Streams stdout line by line (split on `sep`, default "\n").
--- `on_lines` receives batches on the main loop; `on_exit(res)` is called last.
---@return { kill: fun() }
function M.stream(repo, args, opts, on_lines, on_exit)
  opts = opts or {}
  local sep = opts.sep or "\n"
  local pending = ""
  local queue = {}
  local scheduled = false
  local killed = false

  local function flush()
    scheduled = false
    if killed or #queue == 0 then
      return
    end
    local batch = queue
    queue = {}
    on_lines(batch)
  end

  local function push(data)
    pending = pending .. data
    local start = 1
    while true do
      local s, e = pending:find(sep, start, true)
      if not s then
        break
      end
      queue[#queue + 1] = pending:sub(start, s - 1)
      start = e + 1
    end
    pending = pending:sub(start)
    if not scheduled and #queue > 0 then
      scheduled = true
      vim.schedule(flush)
    end
  end

  local stderr = {}
  local ok, obj = pcall(vim.system, build_cmd(args), {
    cwd = cwd_of(repo),
    env = env,
    text = false,
    stdout = function(_, data)
      if data then
        push(data)
      end
    end,
    stderr = function(_, data)
      if data then
        stderr[#stderr + 1] = data
      end
    end,
  }, function(res)
    vim.schedule(function()
      if pending ~= "" then
        queue[#queue + 1] = pending
        pending = ""
      end
      flush()
      if not killed then
        on_exit({ ok = res.code == 0, code = res.code, stdout = "", stderr = table.concat(stderr) })
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      on_exit({ ok = false, code = -1, stdout = "", stderr = tostring(obj) })
    end)
    return { kill = function() end }
  end
  return {
    kill = function()
      killed = true
      pcall(function()
        obj:kill(15)
      end)
    end,
  }
end

--- Runs git and returns stdout or nil + error message.
function M.output(repo, args, opts)
  local res = M.run(repo, args, opts)
  if not res.ok then
    return nil, vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  end
  return res.stdout
end

--- Like output() but trims the result.
function M.line(repo, args)
  local out, err = M.output(repo, args)
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

---------------------------------------------------------------------------
-- Repository discovery
---------------------------------------------------------------------------

local repos = {}

--- Finds the repository containing `path` (file or directory, default: cwd).
---@return diffmerge.Repo|nil, string|nil
function M.find_repo(path)
  path = path and path ~= "" and vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) or vim.fn.getcwd()
  local dir = path
  while dir and vim.fn.isdirectory(dir) == 0 do
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  local out, err = M.output(dir, { "rev-parse", "--show-toplevel", "--absolute-git-dir" })
  if not out then
    return nil, err
  end
  local lines = vim.split(vim.trim(out), "\n", { plain = true })
  if #lines < 2 or lines[1] == "" then
    return nil, "not inside a git work tree"
  end
  local root = vim.fs.normalize(lines[1])
  if not repos[root] then
    repos[root] = { root = root, gitdir = vim.fs.normalize(lines[2]) }
  end
  return repos[root]
end

--- Path relative to the repo root.
function M.relpath(repo, abs)
  abs = vim.fs.normalize(vim.fn.fnamemodify(abs, ":p"))
  local rel = vim.fs.relpath(repo.root, abs)
  if rel == "." then
    return ""
  end
  return rel
end

--- A pathspec typed by the user is relative to the current directory (as for git on the
--- command line); DiffMerge runs git in the repository root, so make it root-relative.
--- Magic pathspecs (":(glob)…", ":/…") are passed through.
function M.pathspec(repo, p)
  if p:sub(1, 1) == ":" then
    return p
  end
  local abs = vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
  local rel = vim.fs.relpath(repo.root, abs)
  if not rel then
    return p
  end
  return rel
end

function M.abspath(repo, rel)
  return vim.fs.joinpath(repo.root, rel)
end

---------------------------------------------------------------------------
-- Plumbing
---------------------------------------------------------------------------

--- Resolves a revision to an object id (nil if it does not exist).
function M.rev_parse(repo, rev)
  local out = M.line(repo, { "rev-parse", "--verify", "--quiet", "--end-of-options", rev })
  if out == nil or out == "" then
    return nil
  end
  return out
end

function M.commit_of(repo, rev)
  return M.rev_parse(repo, rev .. "^{commit}")
end

function M.head(repo)
  return M.rev_parse(repo, "HEAD")
end

--- Current branch name, or nil when detached / unborn.
function M.branch(repo)
  local out = M.line(repo, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  if out == nil or out == "" then
    return nil
  end
  return out
end

function M.merge_base(repo, a, b)
  return M.line(repo, { "merge-base", a, b })
end

function M.is_ancestor(repo, a, b)
  return M.run(repo, { "merge-base", "--is-ancestor", a, b }).code == 0
end

local empty_trees = {}
function M.empty_tree(repo)
  local key = repo.root
  if not empty_trees[key] then
    empty_trees[key] = M.line(repo, { "hash-object", "-t", "tree", "--stdin" }) or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  end
  return empty_trees[key]
end

--- Raw content of an object (`<rev>:<path>`, `:<n>:<path>`), nil if missing.
function M.cat_blob(repo, spec)
  local res = M.run(repo, { "cat-file", "blob", spec })
  if not res.ok then
    return nil, vim.trim(res.stderr)
  end
  return res.stdout
end

--- Type and object id of `<rev>:<path>` (nil if missing).
---@return { type: string, oid: string, mode?: string }|nil
function M.object_info(repo, spec)
  local out = M.line(repo, { "rev-parse", "--verify", "--quiet", spec })
  if not out or out == "" then
    return nil
  end
  local typ = M.line(repo, { "cat-file", "-t", out })
  return { type = typ or "unknown", oid = out }
end

--- Writes content as a blob into the object database.
---@param filters boolean apply clean filters for `path` (like `git add`)
function M.hash_object(repo, content, path, filters)
  local args = { "hash-object", "-w", "--stdin" }
  if filters and path then
    args[#args + 1] = "--path=" .. path
  else
    args[#args + 1] = "--no-filters"
  end
  local out, err = M.output(repo, args, { stdin = content })
  if not out then
    return nil, err
  end
  return vim.trim(out)
end

function M.update_index(repo, mode, oid, path)
  return M.run(repo, { "update-index", "--add", "--cacheinfo", ("%s,%s,%s"):format(mode, oid, path) })
end

--- Index entries for a path: { [stage] = { mode, oid } }
function M.index_entries(repo, path)
  local out = M.output(repo, { "ls-files", "--stage", "-z", "--", ":(literal)" .. path })
  local entries = {}
  if not out then
    return entries
  end
  for rec in out:gmatch("([^%z]+)") do
    local mode, oid, stage, p = rec:match("^(%d+) (%x+) (%d)\t(.*)$")
    if mode and p == path then
      entries[tonumber(stage)] = { mode = mode, oid = oid }
    end
  end
  return entries
end

--- Mode of a path in a tree-ish ("100644", "100755", ...), nil if missing.
function M.tree_mode(repo, rev, path)
  local out = M.output(repo, { "ls-tree", "-z", rev, "--", ":(literal)" .. path })
  return out and out:match("^(%d+) ") or nil
end

--- Operation in progress: merge / rebase / cherry-pick / revert (or nil).
---@return { kind: string, theirs?: string, onto?: string }|nil
function M.operation(repo)
  local function exists(p)
    return vim.uv.fs_stat(vim.fs.joinpath(repo.gitdir, p)) ~= nil
  end
  local function read(p)
    local f = io.open(vim.fs.joinpath(repo.gitdir, p), "r")
    if not f then
      return nil
    end
    local s = f:read("*l")
    f:close()
    return s and vim.trim(s) or nil
  end
  if exists("rebase-merge") or exists("rebase-apply") then
    local dir = exists("rebase-merge") and "rebase-merge" or "rebase-apply"
    local head_name = read(dir .. "/head-name")
    return {
      kind = "rebase",
      onto = read(dir .. "/onto"),
      branch = head_name and head_name:gsub("^refs/heads/", "") or nil,
      theirs = read("REBASE_HEAD"),
    }
  end
  if exists("MERGE_HEAD") then
    return { kind = "merge", theirs = read("MERGE_HEAD"), theirs_name = read("MERGE_MSG") }
  end
  if exists("CHERRY_PICK_HEAD") then
    return { kind = "cherry-pick", theirs = read("CHERRY_PICK_HEAD") }
  end
  if exists("REVERT_HEAD") then
    return { kind = "revert", theirs = read("REVERT_HEAD") }
  end
  return nil
end

--- One-line description of a commit ("abc1234 subject").
function M.describe(repo, rev)
  local out = M.line(repo, { "log", "-1", "--format=%h %s", rev, "--" })
  return out
end

--- Human readable labels for the conflict sides of the operation in progress.
--- During a rebase "ours" is the upstream being rebased onto and "theirs" is your commit.
---@return { ["local"]: string, base: string, remote: string, operation?: string }
function M.conflict_labels(repo)
  local op = M.operation(repo)
  local branch = M.branch(repo)
  local function short(sha)
    return sha and sha:sub(1, 7) or "?"
  end
  local function describe(sha)
    if not sha then
      return "?"
    end
    return M.describe(repo, sha) or short(sha)
  end
  local function name(sha)
    if not sha then
      return "?"
    end
    local n = M.line(repo, { "name-rev", "--name-only", "--no-undefined", "--exclude=refs/tags/*", sha })
    if n and n ~= "" then
      return n
    end
    return short(sha)
  end
  local head = branch or short(M.head(repo))
  local labels = { base = "BASE · common ancestor" }
  if not op then
    labels["local"] = "LOCAL · ours · " .. head
    labels.remote = "REMOTE · theirs"
  elseif op.kind == "merge" then
    labels["local"] = "LOCAL · ours · " .. head
    labels.remote = "REMOTE · theirs · " .. name(op.theirs)
    labels.operation = "MERGING " .. name(op.theirs)
  elseif op.kind == "rebase" then
    labels["local"] = "LOCAL · upstream · " .. describe(op.onto)
    labels.remote = "REMOTE · your commit · " .. describe(op.theirs)
    labels.operation = "REBASING " .. (op.branch or "")
  elseif op.kind == "cherry-pick" then
    labels["local"] = "LOCAL · HEAD · " .. head
    labels.remote = "REMOTE · picked · " .. describe(op.theirs)
    labels.operation = "CHERRY-PICKING " .. short(op.theirs)
  else
    labels["local"] = "LOCAL · HEAD · " .. head
    labels.remote = "REMOTE · reverting · " .. describe(op.theirs)
    labels.operation = "REVERTING " .. short(op.theirs)
  end
  return labels
end

--- Names of branches (local + remote) and tags, for completion.
function M.refs(repo)
  local out = M.output(repo, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags" })
  if not out then
    return {}
  end
  return vim.split(vim.trim(out), "\n", { plain = true, trimempty = true })
end

--- git version as { major, minor, patch }.
function M.version()
  local out = M.line(nil, { "--version" })
  if not out then
    return nil
  end
  local a, b, c = out:match("(%d+)%.(%d+)%.?(%d*)")
  if not a then
    return nil
  end
  return { tonumber(a), tonumber(b), tonumber(c) or 0 }, out
end

return M
