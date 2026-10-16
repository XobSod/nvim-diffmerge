--- Ignoring files: patterns for .gitignore / .git/info/exclude, and what a pattern means for
--- tracked files (git ignores only untracked ones: ignoring a tracked file stops tracking it).
local git = require("diffmerge.git")
local parse = require("diffmerge.git_parse")
local util = require("diffmerge.util")

local M = {}

-- wildcards and the escape itself
local function escape(s)
  s = s:gsub("[\\*?%[]", "\\%0")
  -- git drops trailing spaces unless they are escaped
  return (s:gsub(" +$", function(spaces)
    return spaces:gsub(" ", "\\ ")
  end))
end

--- The pattern of exactly this path: anchored at the root, a directory with a trailing `/`.
--- nil: a name no pattern can hold (a line break in it).
function M.path_pattern(path, dir)
  if path:find("[\r\n]") then
    return nil
  end
  return "/" .. escape(path) .. (dir and "/" or "")
end

--- `*.ext` of the file's extension (at any depth); nil: it has none.
function M.ext_pattern(path)
  local ext = vim.fn.fnamemodify(util.basename(path), ":e")
  if ext == "" or ext:find("[\r\n]") then
    return nil
  end
  return "*." .. escape(ext)
end

--- The exclude file of the repository (a linked worktree shares the main one's).
function M.exclude_file(repo)
  local p = git.line(repo, { "rev-parse", "--git-path", "info/exclude" })
  if not p or p == "" then
    return nil
  end
  return vim.fn.isabsolutepath(p) == 1 and p or git.abspath(repo, p)
end

--- Appends the patterns the file does not have yet, one per line (with its line endings).
---@return string[]? added, string? err, fun()? restore puts the file back as it was
function M.append(file, patterns)
  local before = util.read_file(file)
  if not before and vim.uv.fs_stat(file) then
    return nil, "cannot read it"
  end
  local content = before or ""
  local have = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    have[(line:gsub("\r$", ""))] = true
  end
  local added = {}
  for _, p in ipairs(patterns) do
    if not have[p] then
      have[p] = true
      added[#added + 1] = p
    end
  end
  local function restore()
    if #added == 0 then
      return
    elseif not before then
      os.remove(file)
    else
      local f = io.open(file, "wb")
      if f then
        f:write(before)
        f:close()
      end
    end
  end
  if #added == 0 then
    return added, nil, restore
  end
  local nl = content:find("\r\n", 1, true) and "\r\n" or "\n"
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local f, err = io.open(file, "ab")
  if not f then
    return nil, err
  end
  local sep = (content ~= "" and not content:find("\n$")) and nl or ""
  local ok, werr = f:write(sep .. table.concat(added, nl) .. nl)
  local closed, cerr = f:close()
  if not ok or not closed then
    restore()
    return nil, werr or cerr
  end
  return added, nil, restore
end

--- Paths of `paths` that are one of `targets` or under one of them.
---@param targets { path: string }[]
function M.under(paths, targets)
  local wanted = {}
  for _, t in ipairs(targets) do
    wanted[t.path] = true
  end
  local out = {}
  for _, p in ipairs(paths) do
    local q = p
    while q and not wanted[q] do
      q = q:match("^(.*)/")
    end
    if q then
      out[#out + 1] = p
    end
  end
  return out
end

---@class diffmerge.IgnorePlan
---@field tracked string[] files of the index under the targets: they stop being tracked
---@field unmerged string[] conflicts among them
---@field lost string[] staged content neither committed nor on disk (untracking loses it)
---@field committed string[] the next commit deletes them from the repository
---@field staged_only string[] only staged, never committed: just unstaged
---@field was table<string, string> new path -> old path of staged renames

local function listing(repo, args)
  local out, err = git.output(repo, args)
  if not out then
    return nil, ("git %s failed: %s"):format(args[1], err or "")
  end
  return out
end

--- What ignoring `targets` does to the index. While a merge, rebase, … goes on, every tracked
--- file counts as committed (what the other side committed is in no commit of ours yet).
--- Whole listings, filtered here: a directory may hold more files than a command line can.
---@return diffmerge.IgnorePlan? plan, string? err
function M.plan(repo, targets)
  local args = { "ls-files", "-z", "--stage" }
  if #targets <= 100 then
    -- (else all of it: more paths than a command line holds)
    args[#args + 1] = "--"
    for _, t in ipairs(targets) do
      args[#args + 1] = ":(literal)" .. t.path
    end
  end
  local index, err = listing(repo, args)
  if not index then
    return nil, err
  end
  local stage, paths = {}, {}
  for _, rec in ipairs(parse.records(index)) do
    local n, path = rec:match("^%d+ %x+ (%d)\t(.*)$")
    if path then
      if not stage[path] then
        paths[#paths + 1] = path
      end
      stage[path] = math.max(stage[path] or 0, tonumber(n))
    end
  end
  local plan = { tracked = M.under(paths, targets), unmerged = {}, lost = {}, committed = {}, staged_only = {}, was = {} }
  for _, p in ipairs(plan.tracked) do
    if stage[p] > 0 then
      plan.unmerged[#plan.unmerged + 1] = p
    end
  end
  if #plan.tracked == 0 or #plan.unmerged > 0 then
    return plan
  end
  local head = git.rev_parse(repo, "HEAD")
  local in_head, staged = {}, {}
  if head then
    local tree
    tree, err = listing(repo, { "ls-tree", "-r", "-z", "--name-only", head })
    if not tree then
      return nil, err
    end
    for _, p in ipairs(parse.records(tree)) do
      in_head[p] = true
    end
  end
  -- (intent-to-add entries are left out: nothing of them is staged)
  local diff
  diff, err = listing(repo, { "diff", "--cached", "--name-status", "-z", "--no-ext-diff", "-M", head or git.empty_tree(repo) })
  if not diff then
    return nil, err
  end
  for _, d in ipairs(parse.name_status(diff)) do
    staged[d.path] = true
    if d.status == "R" and in_head[d.oldpath] then
      plan.was[d.path] = d.oldpath
    end
  end
  local changed
  changed, err = listing(repo, { "diff", "--name-only", "-z", "--no-ext-diff" })
  if not changed then
    return nil, err
  end
  local differs = {}
  for _, p in ipairs(parse.records(changed)) do
    differs[p] = true
  end
  local busy = git.operation(repo) ~= nil
  for _, p in ipairs(plan.tracked) do
    -- (also deleted from disk, where `git rm --cached` would let it go)
    if staged[p] and differs[p] then
      plan.lost[#plan.lost + 1] = p
    end
    table.insert((busy or in_head[p] or plan.was[p]) and plan.committed or plan.staged_only, p)
  end
  return plan
end

--- `git rm --cached` of everything under `targets` (pathspecs on stdin, taken literally). -f:
--- its check for staged content that would be lost (`lost` of the plan) is slow (quadratic)
--- in a big directory.
---@return diffmerge.RunResult
function M.untrack(repo, targets)
  local paths = vim.tbl_map(function(t)
    return t.path
  end, targets)
  return git.run(repo, {
    "rm",
    "--cached",
    "-r",
    "-f",
    "-q",
    "--ignore-unmatch",
    "--pathspec-from-file=-",
    "--pathspec-file-nul",
  }, { stdin = table.concat(paths, "\0"), env = { GIT_LITERAL_PATHSPECS = "1" } })
end

--- How many tracked files `patterns` match (as git would match them in `.gitignore`).
---@param except? table<string, boolean>
function M.count_matching_tracked(repo, patterns, except)
  local args = { "ls-files", "-z", "--cached", "--ignored" }
  for _, p in ipairs(patterns) do
    args[#args + 1] = "--exclude=" .. p
  end
  local n, seen = 0, {}
  for _, p in ipairs(parse.records(git.output(repo, args) or "")) do
    if not seen[p] and not (except or {})[p] then
      seen[p] = true
      n = n + 1
    end
  end
  return n
end

--- "a, b, c, … (+2)"
function M.names(list, max)
  max = max or 3
  local shown = util.slice(list, 1, math.min(#list, max))
  local s = table.concat(shown, ", ")
  if #list > max then
    s = s .. (", … (+%d)"):format(#list - max)
  end
  return s
end

--- What the confirm says before tracked files stop being tracked (some of them committed).
---@param o { committed: string[], staged_only: string[], file: string, exclude: boolean, others?: integer, pattern: string }
function M.question(o)
  local all = vim.list_extend(vim.list_extend({}, o.committed), o.staged_only)
  local n, nc = #all, #o.committed
  local it = n == 1 and "it" or "them"
  local lines = {
    n == 1 and (all[1] .. " is tracked.") or ("%d files are tracked: %s."):format(n, M.names(all)),
    ("git ignores untracked files only, so ignoring %s stops tracking %s (git rm --cached):"):format(it, it),
    "- your working tree is left as it is",
    ("- your next commit deletes %s from the repository, and whoever pulls that commit loses their copy"):format(
      nc == n and it or nc == 1 and o.committed[1] or (nc .. " of them")
    ),
  }
  if #o.staged_only > 0 then
    lines[#lines + 1] = #o.staged_only == 1 and ("- " .. o.staged_only[1] .. " was never committed: it is only unstaged")
      or ("- %d were never committed: they are only unstaged"):format(#o.staged_only)
  end
  if o.exclude then
    lines[#lines + 1] = "- " .. o.file .. " is yours only, but the deletion goes to everyone with the commit"
  end
  if (o.others or 0) > 0 then
    lines[#lines + 1] = ("- %d other tracked %s matching %s stay%s tracked"):format(
      o.others,
      o.others == 1 and "file" or "files",
      o.pattern,
      o.others == 1 and "s" or ""
    )
  end
  lines[#lines + 1] = "Stop tracking and ignore?"
  return table.concat(lines, "\n")
end

return M
