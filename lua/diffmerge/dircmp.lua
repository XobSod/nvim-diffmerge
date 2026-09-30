--- Directory comparison for `git difftool --dir-diff` (two plain directories).
local util = require("diffmerge.util")

local M = {}

--- Files below `root`: relative path -> { abs, size }. Symlinks to files are followed.
function M.list(root)
  local out = {}
  for name, typ in vim.fs.dir(root, { depth = math.huge }) do
    local abs = vim.fs.joinpath(root, name)
    if typ == "link" then
      local st = vim.uv.fs_stat(abs)
      typ = st and st.type or "broken"
    end
    if typ == "file" then
      local st = vim.uv.fs_stat(abs)
      out[name] = { abs = abs, size = st and st.size or 0 }
    end
  end
  return out
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

--- Compares two directories.
---@return diffmerge.DirEntry[]
function M.compare(left, right)
  local l, r = M.list(left), M.list(right)
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
  -- exact renames: same content, different path
  local used = {}
  table.sort(deleted)
  table.sort(added)
  for _, dp in ipairs(deleted) do
    local match
    for _, ap in ipairs(added) do
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
  return out
end

return M
