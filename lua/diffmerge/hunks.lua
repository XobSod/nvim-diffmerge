--- Two-way hunks and applying (parts of) them — the core of hunk / line staging.
local config = require("diffmerge.config")

local M = {}

---@class diffmerge.Hunk
---@field as integer first line in `from` (1-based; for insertions: the line after which)
---@field ac integer number of lines in `from`
---@field bs integer first line in `to`
---@field bc integer number of lines in `to`

local function text(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

M.text = text

---@param opts? { algorithm?: string, indent_heuristic?: boolean, linematch?: integer }
---@return diffmerge.Hunk[]
function M.compute(from, to, opts)
  opts = opts or {}
  local indent = opts.indent_heuristic
  if indent == nil then
    indent = true
  end
  local idx = vim.text.diff(text(from), text(to), {
    result_type = "indices",
    algorithm = opts.algorithm or config.options.diff.algorithm,
    indent_heuristic = indent,
    linematch = opts.linematch,
  })
  local out = {}
  for _, h in ipairs(idx or {}) do
    out[#out + 1] = { as = h[1], ac = h[2], bs = h[3], bc = h[4] }
  end
  return out
end

--- Range of a hunk on one side as [first, last] (1-based). Insertions (count 0) return
--- first = last + 1 = the line after which the other side's lines are inserted.
local function side_range(h, side)
  if side == "from" then
    if h.ac == 0 then
      return h.as + 1, h.as
    end
    return h.as, h.as + h.ac - 1
  end
  if h.bc == 0 then
    return h.bs + 1, h.bs
  end
  return h.bs, h.bs + h.bc - 1
end

M.side_range = side_range

--- Options that reproduce the blocks of the diff windows ('diffopt'), so "the hunk / line
--- under the cursor" is exactly what is on screen. With `linematch` a changed block is split
--- into sub-hunks whose lines are aligned 1:1, like the display.
---@param with_linematch boolean
function M.display_opts(with_linematch)
  local o = { algorithm = "myers", indent_heuristic = false }
  for _, item in ipairs(vim.opt.diffopt:get()) do
    local alg = item:match("^algorithm:(%w+)$")
    if alg then
      o.algorithm = alg
    elseif item == "indent-heuristic" then
      o.indent_heuristic = true
    elseif with_linematch then
      local n = item:match("^linematch:(%d+)$")
      if n then
        o.linematch = tonumber(n)
      end
    end
  end
  return o
end

--- Swaps the sides of hunks: the hunks of b -> a, with the boundaries of a -> b. Used so
--- hunks have the same boundaries as the diff on screen (xdiff is not symmetric).
function M.invert(list)
  local out = {}
  for i, h in ipairs(list) do
    out[i] = { as = h.bs, ac = h.bc, bs = h.as, bc = h.ac }
  end
  return out
end

--- The line of the other side that shows the same text as `line` of `side` (nil when `line`
--- is part of a hunk, i.e. has no unchanged counterpart).
function M.map_line(hunks, line, side)
  if not line then
    return nil
  end
  local delta = 0
  for _, h in ipairs(hunks) do
    local first, last = side_range(h, side)
    if line < first then
      break
    end
    if first <= last and line <= last then
      return nil
    end
    if side == "to" then
      delta = delta + h.ac - h.bc
    else
      delta = delta + h.bc - h.ac
    end
  end
  return line + delta
end

--- Like map_line, but a line inside a hunk maps to the start of the hunk on the other side.
function M.map_line_near(hunks, line, side)
  local mapped = M.map_line(hunks, line, side)
  if mapped then
    return mapped
  end
  for _, h in ipairs(hunks) do
    local first, last = side_range(h, side)
    if first <= line and line <= last then
      local other = side == "from" and "to" or "from"
      local ofirst = side_range(h, other)
      return math.max(1, ofirst)
    end
  end
  return line
end

--- Hunks that have lines inside [s, e] on `side` (hunks that are only filler lines on that
--- side do not count).
function M.select_lines(hunks, side, s, e)
  local out = {}
  for _, h in ipairs(hunks) do
    local first, last = side_range(h, side)
    if first <= last and first <= e and last >= s then
      out[#out + 1] = h
    end
  end
  return out
end

--- Hunks touched by lines [s, e] of one side. An empty range (the line above / below
--- filler lines) counts as touched when the cursor is next to it.
function M.select(hunks, side, s, e)
  local out = {}
  for _, h in ipairs(hunks) do
    local first, last = side_range(h, side)
    local hit
    if first <= last then
      hit = first <= e and last >= s
    else
      -- empty: between line `last` and `first`; the lines on either side count
      hit = s <= first and e >= last
    end
    if hit then
      out[#out + 1] = h
    end
  end
  return out
end

--- Applies selected hunks (or selected lines of them) from `to` onto `from`.
---@param from string[] current content (e.g. index)
---@param to string[] desired content (e.g. working tree)
---@param hunks diffmerge.Hunk[] all hunks between from and to
---@param selected table<diffmerge.Hunk, true|{ side: "from"|"to", s: integer, e: integer, exact?: boolean }>
---@return string[] lines, { src: "from"|"to", idx: integer }? last where the last line came
---        from (its final-newline state is the result's; nil for an empty result)
function M.apply(from, to, hunks, selected)
  local out = {}
  local last
  local function emit(src, idx)
    out[#out + 1] = (src == "to" and to or from)[idx]
    last = { src = src, idx = idx }
  end
  local pos = 1 -- next line of `from` to copy
  for _, h in ipairs(hunks) do
    local sel = selected[h]
    if sel then
      local a_first = h.ac == 0 and h.as + 1 or h.as
      local b_first = h.bc == 0 and h.bs + 1 or h.bs
      for i = pos, a_first - 1 do
        emit("from", i)
      end
      if sel == true then
        for i = h.bs, h.bs + h.bc - 1 do
          emit("to", i)
        end
      else
        -- partial: offsets inside the hunk that are selected on the chosen side;
        -- the other side uses the same offsets (display alignment)
        local s_off, e_off
        if sel.side == "from" then
          s_off, e_off = sel.s - a_first, sel.e - a_first
        else
          s_off, e_off = sel.s - b_first, sel.e - b_first
        end
        local side_count = sel.side == "from" and h.ac or h.bc
        -- nothing to select on that side (filler lines): the whole hunk; a visual selection
        -- of every line of one side also takes the lines only the other side has
        local full_side = side_count == 0 or (not sel.exact and s_off <= 0 and e_off >= side_count - 1)
        if full_side then
          s_off, e_off = 0, math.max(h.ac, h.bc) - 1
        end
        -- side-by-side lines are aligned by offset: a selected offset takes the new line
        -- (if any), an unselected one keeps the old line (if any)
        for k = 0, math.max(h.ac, h.bc) - 1 do
          if k >= s_off and k <= e_off then
            if k < h.bc then
              emit("to", h.bs + k)
            end
          elseif k < h.ac then
            emit("from", a_first + k)
          end
        end
      end
      pos = a_first + h.ac
    end
  end
  for i = pos, #from do
    emit("from", i)
  end
  if last then
    last.result = out
  end
  return out, last
end

--- Final-newline state of an apply() result: that of the source its last line came from,
--- if it was that source's last line; any other line has a newline after it.
function M.noeol(from, to, last, from_noeol, to_noeol)
  if not last then
    return false
  end
  local result_is_to = true
  -- (the caller passes the result as `last.result` when it may equal `to`)
  if last.result then
    result_is_to = #last.result == #to
    for i = 1, #to do
      if not result_is_to or last.result[i] ~= to[i] then
        result_is_to = false
        break
      end
    end
    if result_is_to then
      -- every visible difference moved: the final newline (invisible to a line diff) too
      return to_noeol == true
    end
  end
  if last.src == "to" then
    return last.idx == #to and to_noeol == true
  end
  return last.idx == #from and from_noeol == true
end

return M
