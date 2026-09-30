--- Parsers for git's machine-readable (-z) output formats.
local M = {}

local function records(out)
  local recs = {}
  for rec in (out or ""):gmatch("([^%z]*)%z") do
    recs[#recs + 1] = rec
  end
  -- output without a trailing NUL
  local tail = (out or ""):match("([^%z]+)$")
  if tail then
    recs[#recs + 1] = tail
  end
  return recs
end

M.records = records

--- Splits the first `n` space separated fields; the rest (a path, may contain spaces) is returned last.
local function fields(rec, n)
  local out = {}
  local pos = 1
  for _ = 1, n do
    local s = rec:find(" ", pos, true)
    if not s then
      return nil
    end
    out[#out + 1] = rec:sub(pos, s - 1)
    pos = s + 1
  end
  out[#out + 1] = rec:sub(pos)
  return out
end

---@class diffmerge.StatusEntry
---@field kind "changed"|"renamed"|"unmerged"|"untracked"
---@field x string index status ('.' = unmodified)
---@field y string worktree status
---@field path string
---@field orig? string original path (renames)
---@field modes? table
---@field stages? table<integer, boolean> present stages (unmerged)

--- Parses `git status --porcelain=v2 -z --branch`.
---@return { branch: table, entries: diffmerge.StatusEntry[] }
function M.status(out)
  local recs = records(out)
  local result = { branch = {}, entries = {} }
  local i = 1
  while i <= #recs do
    local rec = recs[i]
    local t = rec:sub(1, 1)
    if t == "#" then
      local key, value = rec:match("^# ([%w%.]+) (.*)$")
      if key then
        result.branch[key] = value
      end
    elseif t == "1" then
      local f = fields(rec, 8)
      if f then
        result.entries[#result.entries + 1] = {
          kind = "changed",
          x = f[2]:sub(1, 1),
          y = f[2]:sub(2, 2),
          modes = { head = f[4], index = f[5], worktree = f[6] },
          path = f[9],
        }
      end
    elseif t == "2" then
      local f = fields(rec, 9)
      if f then
        i = i + 1
        result.entries[#result.entries + 1] = {
          kind = "renamed",
          x = f[2]:sub(1, 1),
          y = f[2]:sub(2, 2),
          modes = { head = f[4], index = f[5], worktree = f[6] },
          score = f[9],
          path = f[10],
          orig = recs[i],
        }
      end
    elseif t == "u" then
      local f = fields(rec, 10)
      if f then
        result.entries[#result.entries + 1] = {
          kind = "unmerged",
          x = f[2]:sub(1, 1),
          y = f[2]:sub(2, 2),
          xy = f[2],
          stages = { [1] = f[4] ~= "000000", [2] = f[5] ~= "000000", [3] = f[6] ~= "000000" },
          modes = { [1] = f[4], [2] = f[5], [3] = f[6], worktree = f[7] },
          path = f[11],
        }
      end
    elseif t == "?" then
      result.entries[#result.entries + 1] = { kind = "untracked", x = "?", y = "?", path = rec:sub(3) }
    end
    i = i + 1
  end
  return result
end

---@class diffmerge.NameStatus
---@field status string single letter (A, M, D, R, C, T, U, X)
---@field score? integer
---@field path string new path
---@field oldpath? string

--- Parses `git diff --name-status -z`.
---@return diffmerge.NameStatus[]
function M.name_status(out)
  local recs = records(out)
  local list = {}
  local i = 1
  while i <= #recs do
    local st = recs[i]
    if st ~= "" then
      local letter = st:sub(1, 1)
      local score = tonumber(st:sub(2))
      if letter == "R" or letter == "C" then
        list[#list + 1] = { status = letter, score = score, oldpath = recs[i + 1], path = recs[i + 2] }
        i = i + 3
      else
        list[#list + 1] = { status = letter, path = recs[i + 1] }
        i = i + 2
      end
    else
      i = i + 1
    end
  end
  return list
end

--- Parses `git diff --numstat -z`. Returns map path -> { added, deleted } (nil counts for binary).
function M.numstat(out)
  local recs = records(out)
  local map = {}
  local i = 1
  while i <= #recs do
    local added, deleted, path = recs[i]:match("^(%S+)\t(%S+)\t(.*)$")
    if added then
      local stat = { added = tonumber(added), deleted = tonumber(deleted), binary = added == "-" }
      if path == "" then
        -- rename: old and new path follow
        map[recs[i + 2]] = stat
        i = i + 3
      else
        map[path] = stat
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return map
end

return M
