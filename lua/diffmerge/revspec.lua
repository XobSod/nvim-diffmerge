--- Resolution of `git diff` style arguments into the two sides of a comparison.
---
--- A side is { kind = "commit", oid, label } | { kind = "index" } | { kind = "worktree" }
--- (a tree oid is allowed as "commit", e.g. the empty tree).
local git = require("diffmerge.git")
local source = require("diffmerge.source")
local util = require("diffmerge.util")

local M = {}

---@class diffmerge.Side
---@field kind "commit"|"index"|"worktree"
---@field oid? string
---@field label? string

---@class diffmerge.Comparison
---@field left diffmerge.Side
---@field right diffmerge.Side
---@field paths string[]
---@field extra string[] pass-through flags for the file listing
---@field title string equivalent git command

local function commit_side(repo, rev, label)
  local oid = git.rev_parse(repo, rev .. "^{tree}") and git.rev_parse(repo, rev)
  if not oid then
    return nil, ("unknown revision %q"):format(rev)
  end
  -- prefer the commit id for labels/sources when the rev is a commit
  local commit = git.commit_of(repo, rev)
  return { kind = "commit", oid = commit or git.rev_parse(repo, rev .. "^{tree}"), label = label or rev }
end

M.commit_side = commit_side

local function quote(arg)
  if arg:match("^[%w%._/:@%^~%-=]+$") then
    return arg
  end
  return vim.fn.shellescape(arg)
end

--- Parses `git diff` arguments.
---@param repo diffmerge.Repo
---@param args string[]
---@return diffmerge.Comparison|nil, string|nil
function M.parse(repo, args)
  local revs, paths, extra = {}, {}, {}
  local cached, merge_base = false, false
  local after_dashdash = false
  for _, a in ipairs(args) do
    if after_dashdash then
      paths[#paths + 1] = a
    elseif a == "--" then
      after_dashdash = true
    elseif a == "--cached" or a == "--staged" then
      cached = true
    elseif a == "--merge-base" then
      merge_base = true
    elseif a:sub(1, 1) == "-" then
      extra[#extra + 1] = a
    else
      revs[#revs + 1] = a
    end
  end
  -- git allows paths without "--" when they are not revisions
  if not after_dashdash then
    local r2 = {}
    for _, r in ipairs(revs) do
      local is_rev = r:find("%.%.") or r:find("%^!$") or git.rev_parse(repo, r) ~= nil
      if is_rev then
        r2[#r2 + 1] = r
      else
        paths[#paths + 1] = r
      end
    end
    revs = r2
  end

  for i, p in ipairs(paths) do
    paths[i] = git.pathspec(repo, p)
  end
  local title = { "git", "diff" }
  for _, a in ipairs(args) do
    title[#title + 1] = quote(a)
  end
  local cmp = { paths = paths, extra = extra, title = table.concat(title, " ") }

  local head = git.head(repo)
  local function head_side()
    if not head then
      return { kind = "commit", oid = git.empty_tree(repo), label = "(no commits)" }
    end
    return { kind = "commit", oid = head, label = "HEAD" }
  end

  local err
  if #revs == 0 then
    if merge_base then
      return nil, "--merge-base needs a revision"
    end
    if cached then
      cmp.left, cmp.right = head_side(), { kind = "index" }
    else
      cmp.left, cmp.right = { kind = "index" }, { kind = "worktree" }
    end
  elseif #revs == 1 and revs[1]:find("%.%.%.") then
    local a, b = revs[1]:match("^(.-)%.%.%.(.*)$")
    a = a ~= "" and a or "HEAD"
    b = b ~= "" and b or "HEAD"
    local base = git.merge_base(repo, a, b)
    if not base then
      return nil, ("no merge base between %s and %s"):format(a, b)
    end
    cmp.left = { kind = "commit", oid = base, label = "merge-base(" .. a .. ", " .. b .. ")" }
    cmp.right, err = commit_side(repo, b)
  elseif #revs == 1 and revs[1]:find("%.%.") then
    local a, b = revs[1]:match("^(.-)%.%.(.*)$")
    a = a ~= "" and a or "HEAD"
    b = b ~= "" and b or "HEAD"
    cmp.left, err = commit_side(repo, a)
    if cmp.left then
      cmp.right, err = commit_side(repo, b)
    end
  elseif #revs == 1 and revs[1]:find("%^!$") then
    local c = revs[1]:sub(1, -3)
    cmp.right, err = commit_side(repo, c)
    if cmp.right then
      local parent = git.rev_parse(repo, c .. "^")
      cmp.left = parent and { kind = "commit", oid = parent, label = c .. "^" }
        or { kind = "commit", oid = git.empty_tree(repo), label = "(root)" }
    end
  elseif #revs == 1 then
    if merge_base then
      local base = git.merge_base(repo, revs[1], "HEAD")
      if not base then
        return nil, "no merge base with HEAD"
      end
      cmp.left = { kind = "commit", oid = base, label = "merge-base(" .. revs[1] .. ", HEAD)" }
    else
      cmp.left, err = commit_side(repo, revs[1])
    end
    cmp.right = cached and { kind = "index" } or { kind = "worktree" }
  elseif #revs == 2 then
    if merge_base then
      local base = git.merge_base(repo, revs[1], revs[2])
      if not base then
        return nil, "no merge base"
      end
      cmp.left = { kind = "commit", oid = base, label = "merge-base(" .. revs[1] .. ", " .. revs[2] .. ")" }
    else
      cmp.left, err = commit_side(repo, revs[1])
    end
    if cmp.left then
      cmp.right, err = commit_side(repo, revs[2])
    end
  else
    return nil, "combined diffs of more than two revisions are not supported"
  end
  if not cmp.left or not cmp.right then
    return nil, err
  end
  return cmp
end

--- `git diff` arguments selecting the two sides.
function M.diff_args(cmp)
  local l, r = cmp.left, cmp.right
  if l.kind == "index" and r.kind == "worktree" then
    return {}
  elseif l.kind == "commit" and r.kind == "worktree" then
    return { l.oid }
  elseif l.kind == "commit" and r.kind == "index" then
    return { "--cached", l.oid }
  elseif l.kind == "commit" and r.kind == "commit" then
    return { l.oid, r.oid }
  end
  error("unsupported comparison " .. l.kind .. " -> " .. r.kind)
end

--- Equivalent command for display, e.g. "git diff abc1234 def5678 -- lua/".
function M.describe(cmp)
  local parts = { "git", "diff" }
  local l, r = cmp.left, cmp.right
  local function name(side)
    return side.label or util.short(side.oid)
  end
  if l.kind == "commit" and r.kind == "index" then
    parts[#parts + 1] = "--staged"
    parts[#parts + 1] = name(l)
  elseif l.kind == "commit" and r.kind == "worktree" then
    parts[#parts + 1] = name(l)
  elseif l.kind == "commit" then
    parts[#parts + 1] = name(l)
    parts[#parts + 1] = name(r)
  end
  if #cmp.paths > 0 then
    parts[#parts + 1] = "--"
    for _, p in ipairs(cmp.paths) do
      parts[#parts + 1] = quote(p)
    end
  end
  return table.concat(parts, " ")
end

local function side_source(side, path)
  if side.kind == "index" then
    return source.index(path)
  elseif side.kind == "worktree" then
    return source.worktree(path)
  end
  local label = side.label or util.short(side.oid)
  if side.label and side.oid and not side.label:find(util.short(side.oid), 1, true) and side.oid:match("^%x+$") then
    label = side.label .. " · " .. util.short(side.oid)
  end
  return source.rev(side.oid, path, label)
end

M.side_source = side_source

--- Entries (files) of a comparison.
---@return diffmerge.Entry[]|nil, string|nil
function M.entries(repo, cmp)
  local base = M.diff_args(cmp)
  local args = { "diff", "--name-status", "-z", "-M", "--no-ext-diff" }
  util.extend(args, cmp.extra or {})
  util.extend(args, base)
  args[#args + 1] = "--"
  util.extend(args, cmp.paths or {})
  local out, err = git.output(repo, args)
  if not out then
    return nil, err
  end
  local stat_args = { "diff", "--numstat", "-z", "-M", "--no-ext-diff" }
  util.extend(stat_args, cmp.extra or {})
  util.extend(stat_args, base)
  stat_args[#stat_args + 1] = "--"
  util.extend(stat_args, cmp.paths or {})
  local stats = require("diffmerge.git_parse").numstat(git.output(repo, stat_args) or "")

  local entries = {}
  local seen = {}
  for _, ns in ipairs(require("diffmerge.git_parse").name_status(out)) do
    if not seen[ns.path] then
      seen[ns.path] = true
      local left, right
      if ns.status == "A" then
        left = source.empty("(new file)", "a")
      elseif ns.status == "U" then
        left = source.stage(2, ns.path, "OURS (unmerged)")
      else
        left = side_source(cmp.left, ns.oldpath or ns.path)
      end
      if ns.status == "D" then
        right = source.empty("(deleted)", "b")
      else
        right = side_source(cmp.right, ns.path)
      end
      entries[#entries + 1] = {
        kind = "diff",
        path = ns.path,
        oldpath = ns.oldpath,
        status = ns.status,
        stats = stats[ns.path],
        key = ns.path,
        sides = { a = left, b = right },
      }
    end
  end
  return entries
end

return M
