--- Directory comparison for `git difftool --dir-diff` and :DiffMerge compare (two plain
--- directories).
local util = require("diffmerge.util")

local M = {}

-- a walk stops here (links can multiply a tree)
local MAX_FILES = 100000
local MAX_LINKS = 1000

--- Files below `root`: relative path -> { abs, size }. Links to files are followed, links to
--- directories only inside `root` (not into a directory they are in); `.git` is left out.
--- What is not read is noted in `problems` (unreadable, outside, truncated, links).
function M.list(root, problems)
  local out, count, links = {}, 0, 0
  local top = vim.uv.fs_realpath(root) or root
  local function inside_root(real)
    return real == top or real:sub(1, #top + 1) == top .. "/"
  end
  local function walk(dir, rel, chain)
    local real = vim.uv.fs_realpath(dir)
    if not real or chain[real] then
      return
    end
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      problems.unreadable[#problems.unreadable + 1] = dir
      return
    end
    chain[real] = true
    while count < MAX_FILES do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local abs = dir .. "/" .. name
      local path = rel and (rel .. "/" .. name) or name
      local link = typ == "link"
      if typ ~= "file" and typ ~= "directory" then
        local st = vim.uv.fs_stat(abs)
        typ = st and st.type or "broken"
      end
      if name == ".git" then
        -- a repository's internals, not its files
      elseif typ == "directory" then
        if link and not inside_root(vim.uv.fs_realpath(abs) or "") then
          problems.outside[#problems.outside + 1] = abs
        elseif link and links >= MAX_LINKS then
          problems.links = MAX_LINKS
        else
          links = links + (link and 1 or 0)
          walk(abs, path, chain)
        end
      elseif typ == "file" then
        if vim.uv.fs_access(abs, "R") then
          local st = vim.uv.fs_stat(abs)
          out[path] = { abs = abs, size = st and st.size or 0 }
          count = count + 1
        else
          problems.unreadable[#problems.unreadable + 1] = abs
        end
      end
    end
    if count >= MAX_FILES then
      problems.truncated = MAX_FILES
    end
    chain[real] = nil
  end
  walk(root, nil, {})
  return out
end

--- The two files have the same content.
function M.same_file(a, b)
  return util.read_file(a) == util.read_file(b)
end

local function same(a, b)
  if a.size ~= b.size then
    return false
  end
  return util.read_file(a.abs) == util.read_file(b.abs)
end

---@class diffmerge.DirEntry
---@field status "A"|"D"|"M"|"R"
---@field path string
---@field oldpath? string
---@field left? string absolute path
---@field right? string absolute path

--- Compares two directories. `renames` (new path -> old path) keep pairs found before, while
--- both files are still there.
---@param renames? table<string, string>
---@return diffmerge.DirEntry[], { unreadable: string[], outside: string[], truncated?: integer, links?: integer }
function M.compare(left, right, renames)
  local problems = { unreadable = {}, outside = {} }
  local l, r = M.list(left, problems), M.list(right, problems)
  local out, added, deleted = {}, {}, {}
  for path, lf in pairs(l) do
    local rf = r[path]
    if not rf then
      deleted[#deleted + 1] = path
    elseif not same(lf, rf) then
      out[#out + 1] = { status = "M", path = path, left = lf.abs, right = rf.abs }
    end
  end
  for path in pairs(r) do
    if not l[path] then
      added[#added + 1] = path
    end
  end
  -- renames: the pairs known before, then same content under another path
  local used, paired = {}, {}
  for new, old in pairs(renames or {}) do
    if r[new] and not l[new] and l[old] and not r[old] then
      used[new], paired[old] = true, new
    end
  end
  table.sort(deleted)
  table.sort(added)
  for _, dp in ipairs(deleted) do
    local match = paired[dp]
    for _, ap in ipairs(match and {} or added) do
      if not used[ap] and same(l[dp], r[ap]) then
        match = ap
        break
      end
    end
    if match then
      used[match] = true
      out[#out + 1] = { status = "R", path = match, oldpath = dp, left = l[dp].abs, right = r[match].abs }
    else
      out[#out + 1] = { status = "D", path = dp, left = l[dp].abs }
    end
  end
  for _, ap in ipairs(added) do
    if not used[ap] then
      out[#out + 1] = { status = "A", path = ap, right = r[ap].abs }
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out, problems
end

return M
