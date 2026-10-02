--- Differences inside changed lines (character / word level), for the views where Vim's own
--- inline highlighting is muted (merges, HEAD | WORKING TREE | INDEX). Follows 'diffopt':
--- "inline:" char (default), word, simple or none, and iwhite / iwhiteall / iwhiteeol / icase.
local M = {}

-- longer lines are not refined (cost, and little use)
local MAX_LINE = 1000
-- remembered line pairs (all modes together); the memo starts over beyond this
local MAX_MEMO = 20000

--- Inline settings of 'diffopt'.
---@return { mode: "char"|"word"|"simple"|"none", iwhite?: boolean, iwhiteall?: boolean, iwhiteeol?: boolean, icase?: boolean }
function M.options()
  local o = { mode = "simple" }
  for _, item in ipairs(vim.opt.diffopt:get()) do
    local m = item:match("^inline:(%a+)$")
    if m then
      o.mode = m
    elseif item == "iwhite" or item == "iwhiteall" or item == "iwhiteeol" or item == "icase" then
      o[item] = true
    end
  end
  return o
end

local function key_of(o)
  return ("%s%s%s%s%s"):format(
    o.mode,
    o.iwhite and "w" or "",
    o.iwhiteall and "a" or "",
    o.iwhiteeol and "e" or "",
    o.icase and "c" or ""
  )
end

local function kind(ch, len)
  if ch:match("^[%w_]") or len > 1 then
    return "w"
  elseif ch:match("^%s") then
    return "s"
  end
  return "p"
end

--- Tokens of a line with their byte ranges (0-based start, end exclusive): characters
--- (combining marks stay with their base character), or (word mode) runs of word
--- characters / of white space and single other characters. `cmp` is what is compared.
local function tokens(s, o)
  local out = {}
  local pos, n = 1, #s
  while pos <= n do
    local len = vim.str_utf_end(s, pos) + 1
    local first = s:sub(pos, pos + len - 1)
    local stop = pos + len
    local class = kind(first, len)
    while stop <= n do
      local l2 = vim.str_utf_end(s, stop) + 1
      local ch = s:sub(stop, stop + l2 - 1)
      -- zero-width characters (combining marks, joiners) belong to the previous one
      local before = s:sub(pos, stop - 1)
      local joins = l2 > 1 and vim.fn.strdisplaywidth(before .. ch) == vim.fn.strdisplaywidth(before)
      if not joins and (o.mode ~= "word" or class == "p" or kind(ch, l2) ~= class) then
        break
      end
      stop = stop + l2
    end
    local text = s:sub(pos, stop - 1)
    local cmp = text
    if o.icase then
      cmp = vim.fn.tolower(cmp)
    end
    local space = class == "s" and not text:find("%S")
    if not (space and o.iwhiteall) then
      out[#out + 1] = { text = text, cmp = cmp, s = pos - 1, e = stop - 1, space = space }
    end
    pos = stop
  end
  if o.iwhite or o.iwhiteall or o.iwhiteeol then
    -- white space at the end of the line does not count
    while #out > 0 and out[#out].space do
      out[#out] = nil
    end
  end
  if o.iwhite then
    -- runs of white space compare equal to each other, whatever their length
    local merged = {}
    for _, t in ipairs(out) do
      local last = merged[#merged]
      if t.space and last and last.space then
        last.e = t.e
      else
        merged[#merged + 1] = t
      end
      if t.space then
        merged[#merged].cmp = " "
      end
    end
    out = merged
  end
  return out
end

local function join(toks)
  local parts = {}
  for i, t in ipairs(toks) do
    -- one token per diff "line"; newlines cannot occur inside a buffer line
    parts[i] = t.cmp
  end
  return #parts == 0 and "" or (table.concat(parts, "\n") .. "\n")
end

local function merge(ranges)
  table.sort(ranges, function(x, y)
    return x[1] < y[1]
  end)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and r[1] <= last[2] then
      last[2] = math.max(last[2], r[2])
    elseif r[2] > r[1] then
      out[#out + 1] = { r[1], r[2] }
    end
  end
  return out
end

--- Moves a byte position back to the start of its UTF-8 character.
local function char_start(s, p)
  while p > 0 and p < #s do
    local b = s:byte(p + 1)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    p = p - 1
  end
  return p
end

local function simple(a, b)
  local p = 0
  while p < #a and p < #b and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  p = char_start(a, p)
  local q = 0
  while q < #a - p and q < #b - p and a:byte(#a - q) == b:byte(#b - q) do
    q = q + 1
  end
  -- the change has to end at a character boundary too
  while q > 0 and char_start(a, #a - q) ~= #a - q do
    q = q - 1
  end
  local ra = #a - q > p and { { p, #a - q } } or {}
  local rb = #b - q > p and { { p, #b - q } } or {}
  return ra, rb
end

--- Changed byte ranges of two versions of one line: { {start, end}, ... } for each side
--- (0-based, end exclusive). Equal lines give empty lists.
---@param o? table options (default: from 'diffopt')
function M.line_diff(a, b, o)
  o = o or M.options()
  if type(o) == "string" then
    o = { mode = o }
  end
  if a == b or o.mode == "none" or #a > MAX_LINE or #b > MAX_LINE then
    return {}, {}
  end
  if o.mode == "simple" then
    return simple(a, b)
  end
  local ta, tb = tokens(a, o), tokens(b, o)
  local idx = vim.text.diff(join(ta), join(tb), { result_type = "indices" }) or {}
  local ra, rb = {}, {}
  for _, h in ipairs(idx) do
    local as, ac, bs, bc = h[1], h[2], h[3], h[4]
    if ac > 0 then
      ra[#ra + 1] = { ta[as].s, ta[as + ac - 1].e }
    end
    if bc > 0 then
      rb[#rb + 1] = { tb[bs].s, tb[bs + bc - 1].e }
    end
  end
  if o.mode == "char" then
    -- equal runs of a single character between two changes are noise: join them
    local function absorb(r, s)
      local out = {}
      for _, x in ipairs(r) do
        local last = out[#out]
        if last and x[1] - last[2] <= vim.str_utf_end(s, last[2] + 1) + 1 then
          last[2] = x[2]
        else
          out[#out + 1] = { x[1], x[2] }
        end
      end
      return out
    end
    ra, rb = absorb(ra, a), absorb(rb, b)
  end
  return merge(ra), merge(rb)
end

--- Inline differences between two versions of a block, paired row by row: the views that
--- use these (merges, three columns) show changed blocks aligned from their first line.
---@return table<integer, integer[][]> a_ranges, table<integer, integer[][]> b_ranges by line (1-based in the block)
function M.block(a, b, o, line_diff)
  o = o or M.options()
  line_diff = line_diff or M.line_diff
  local ra, rb = {}, {}
  if o.mode == "none" then
    return ra, rb
  end
  for k = 1, math.min(#a, #b) do
    local x, y = line_diff(a[k], b[k], o)
    if #x > 0 then
      ra[k] = x
    end
    if #y > 0 then
      rb[k] = y
    end
  end
  return ra, rb
end

--- A block() remembering line pairs (views re-render on every edit; most lines repeat).
function M.cache()
  local memo, count = {}, 0
  local function line_diff(a, b, o)
    local key = key_of(o)
    local by_mode = memo[key]
    if not by_mode then
      by_mode = {}
      memo[key] = by_mode
    end
    local by_a = by_mode[a]
    if not by_a then
      by_a = {}
      by_mode[a] = by_a
    end
    local hit = by_a[b]
    if not hit then
      if count >= MAX_MEMO then
        memo, count = {}, 0
        return M.line_diff(a, b, o)
      end
      local x, y = M.line_diff(a, b, o)
      hit = { x, y }
      by_a[b] = hit
      count = count + 1
    end
    return hit[1], hit[2]
  end
  return function(a, b)
    return M.block(a, b, M.options(), line_diff)
  end
end

return M
