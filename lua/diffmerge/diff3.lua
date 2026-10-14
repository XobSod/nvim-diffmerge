--- Three-way merge chunks.
---
--- base->local and base->remote hunks are computed with vim.text.diff and grouped when they
--- overlap *or touch* in base coordinates (the same rule git uses: changes on adjacent lines
--- conflict). Each group is classified as
---   local    only local changed        -> take local
---   remote   only remote changed       -> take remote
---   both     identical change on both  -> take either
---   conflict different changes         -> needs a decision
--- Ranges are 0-based, end-exclusive: { first, last + 1 }.
local config = require("diffmerge.config")

local M = {}

local function text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

--- base -> other hunks as { bs, be, os, oe } (0-based, end-exclusive).
local function hunks(base, other, algorithm, indent_heuristic)
  if indent_heuristic == nil then
    indent_heuristic = true
  end
  local idx = vim.text.diff(text(base), text(other), {
    result_type = "indices",
    algorithm = algorithm or config.options.diff.algorithm,
    indent_heuristic = indent_heuristic,
  })
  local out = {}
  for _, h in ipairs(idx or {}) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local bs = ca == 0 and sa or sa - 1
    local os = cb == 0 and sb or sb - 1
    out[#out + 1] = { bs = bs, be = bs + ca, os = os, oe = os + cb }
  end
  return out
end

M.hunks = hunks

local function lines_equal(a, ar, b, br)
  if ar[2] - ar[1] ~= br[2] - br[1] then
    return false
  end
  for k = 0, ar[2] - ar[1] - 1 do
    if a[ar[1] + 1 + k] ~= b[br[1] + 1 + k] then
      return false
    end
  end
  return true
end

---@class diffmerge.Chunk
---@field kind "equal"|"local"|"remote"|"both"|"conflict"
---@field base integer[]
---@field local integer[]
---@field remote integer[]

---@param base string[]
---@param loc string[]
---@param rem string[]
---@return diffmerge.Chunk[]
---@param opts? { algorithm?: string, indent_heuristic?: boolean, d1?: table, d2?: table, apart?: boolean } d1 / d2: hunks (M.hunks) of base -> loc / rem; apart: changes on neighbouring lines stay apart (only overlapping ones, or insertions at one place, are a group)
function M.compute(base, loc, rem, opts)
  opts = opts or {}
  local d1 = opts.d1 or hunks(base, loc, opts.algorithm, opts.indent_heuristic)
  local d2 = opts.d2 or hunks(base, rem, opts.algorithm, opts.indent_heuristic)
  local chunks = {}
  local i, j = 1, 1
  local bpos, lpos, rpos = 0, 0, 0

  local function push_equal(upto)
    if upto > bpos then
      local n = upto - bpos
      chunks[#chunks + 1] = {
        kind = "equal",
        base = { bpos, upto },
        ["local"] = { lpos, lpos + n },
        remote = { rpos, rpos + n },
      }
      bpos, lpos, rpos = upto, lpos + n, rpos + n
    end
  end

  while i <= #d1 or j <= #d2 do
    local h1, h2 = d1[i], d2[j]
    local gs
    if h1 and (not h2 or h1.bs <= h2.bs) then
      gs = h1.bs
    else
      gs = h2.bs
    end
    -- apart: an insertion goes before a change at the same line
    local insertion_first = opts.apart
      and h1
      and h2
      and h1.bs == h2.bs
      and (h1.be == h1.bs) ~= (h2.be == h2.bs)
    push_equal(gs)
    local ge = gs
    local delta1, delta2 = 0, 0
    local n1, n2 = 0, 0
    local function joins(h)
      if not h then
        return false
      elseif not opts.apart then
        return h.bs <= ge
      elseif n1 + n2 == 0 then
        return h.bs == gs and (not insertion_first or h.be == h.bs)
      elseif h.be > h.bs then
        -- a change: when it overlaps what the group changes
        return h.bs < ge
      end
      -- an insertion: inside a change, or where the group inserts too
      return (h.bs > gs and h.bs < ge) or (gs == ge and h.bs == ge)
    end
    local progressed = true
    while progressed do
      progressed = false
      local a = d1[i]
      if joins(a) then
        ge = math.max(ge, a.be)
        delta1 = delta1 + (a.oe - a.os) - (a.be - a.bs)
        n1 = n1 + 1
        i = i + 1
        progressed = true
      end
      local b = d2[j]
      if joins(b) then
        ge = math.max(ge, b.be)
        delta2 = delta2 + (b.oe - b.os) - (b.be - b.bs)
        n2 = n2 + 1
        j = j + 1
        progressed = true
      end
    end
    local lr = { lpos, ge + (lpos - gs) + delta1 }
    local rr = { rpos, ge + (rpos - gs) + delta2 }
    local kind
    if n2 == 0 then
      kind = "local"
    elseif n1 == 0 then
      kind = "remote"
    elseif lines_equal(loc, lr, rem, rr) then
      kind = "both"
    else
      kind = "conflict"
    end
    chunks[#chunks + 1] = { kind = kind, base = { gs, ge }, ["local"] = lr, remote = rr }
    bpos, lpos, rpos = ge, lr[2], rr[2]
  end
  push_equal(#base)
  return chunks
end

local function slice(lines, r)
  local out = {}
  for k = r[1] + 1, r[2] do
    out[#out + 1] = lines[k]
  end
  return out
end

M.slice = slice

--- Auto-merge result (meld --auto-merge): non-conflicting changes applied, conflict regions
--- contain the base text. Sets chunk.merged = range in the result.
---@return string[]
function M.result(chunks, base, loc, rem)
  local out = {}
  for _, c in ipairs(chunks) do
    local part
    if c.kind == "equal" or c.kind == "conflict" then
      part = slice(base, c.base)
    elseif c.kind == "remote" then
      part = slice(rem, c.remote)
    else
      part = slice(loc, c["local"])
    end
    local s = #out
    for _, l in ipairs(part) do
      out[#out + 1] = l
    end
    c.merged = { s, #out }
  end
  return out
end

return M
