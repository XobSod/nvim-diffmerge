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

---@return diffmerge.Hunk[]
function M.compute(from, to, opts)
  opts = opts or {}
  local idx = vim.text.diff(text(from), text(to), {
    result_type = "indices",
    algorithm = opts.algorithm or config.options.diff.algorithm,
    indent_heuristic = true,
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
---@param selected table<diffmerge.Hunk, true|{ side: "from"|"to", s: integer, e: integer }>
---@return string[] lines, boolean tail_from_to the end of the result comes from `to`
---        (a selected hunk reaches the end of `from`): use `to`'s final-newline state
function M.apply(from, to, hunks, selected)
  local out = {}
  local pos = 1 -- next line of `from` to copy
  local tail_from_to = false
  for _, h in ipairs(hunks) do
    local sel = selected[h]
    if sel then
      local a_first = h.ac == 0 and h.as + 1 or h.as
      local b_first = h.bc == 0 and h.bs + 1 or h.bs
      if a_first + h.ac - 1 >= #from then
        tail_from_to = true
      end
      for i = pos, a_first - 1 do
        out[#out + 1] = from[i]
      end
      if sel == true then
        for i = h.bs, h.bs + h.bc - 1 do
          out[#out + 1] = to[i]
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
        -- nothing to select on that side (filler lines): the whole hunk
        local full_side = side_count == 0 or (s_off <= 0 and e_off >= side_count - 1)
        if full_side then
          s_off, e_off = 0, math.max(h.ac, h.bc) - 1
        end
        -- side-by-side lines are aligned by offset: a selected offset takes the new line
        -- (if any), an unselected one keeps the old line (if any)
        for k = 0, math.max(h.ac, h.bc) - 1 do
          if k >= s_off and k <= e_off then
            if k < h.bc then
              out[#out + 1] = to[h.bs + k]
            end
          elseif k < h.ac then
            out[#out + 1] = from[a_first + k]
          end
        end
      end
      pos = a_first + h.ac
    end
  end
  for i = pos, #from do
    out[#out + 1] = from[i]
  end
  return out, tail_from_to
end

return M
