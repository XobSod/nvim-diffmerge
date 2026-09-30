local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local diff3 = require("diffmerge.diff3")
local hunks = require("diffmerge.hunks")
local merge = require("diffmerge.merge")

local function kinds(base, loc, rem)
  local out = {}
  for _, c in ipairs(diff3.compute(base, loc, rem)) do
    if c.kind ~= "equal" then
      out[#out + 1] = c.kind
    end
  end
  return out
end

local B = { "a", "b", "c", "d", "e", "f", "g" }
local function with(i, v)
  local t = vim.deepcopy(B)
  t[i] = v
  return t
end

H.describe("diff3", function()
  H.it("classifies one-sided and identical changes", function()
    H.eq(kinds(B, with(2, "L"), B), { "local" })
    H.eq(kinds(B, B, with(5, "R")), { "remote" })
    H.eq(kinds(B, with(2, "X"), with(2, "X")), { "both" })
    H.eq(kinds(B, with(2, "L"), with(6, "R")), { "local", "remote" })
  end)

  H.it("conflicts on overlapping and adjacent changes (like git)", function()
    H.eq(kinds(B, with(2, "L"), with(2, "R")), { "conflict" })
    H.eq(kinds(B, with(2, "L"), with(3, "R")), { "conflict" })
  end)

  H.it("builds the auto-merge result with base text in conflicts", function()
    local loc = with(2, "L")
    local rem = with(6, "R")
    rem[4] = "D"
    local chunks = diff3.compute(B, loc, rem)
    H.eq(diff3.result(chunks, B, loc, rem), { "a", "L", "c", "D", "e", "R", "g" })
    local conflict = diff3.compute(B, with(2, "L"), with(2, "R"))
    H.eq(diff3.result(conflict, B, with(2, "L"), with(2, "R")), B)
  end)

  H.it("handles insertions, deletions and empty files", function()
    H.eq(kinds({}, { "x" }, { "y" }), { "conflict" })
    H.eq(kinds({}, { "x" }, { "x" }), { "both" })
    H.eq(kinds(B, B, {}), { "remote" })
    local loc = vim.list_extend(vim.deepcopy(B), { "L" })
    local rem = vim.list_extend(vim.deepcopy(B), { "R" })
    H.eq(kinds(B, loc, rem), { "conflict" })
  end)
end)

H.describe("hunks", function()
  H.it("applies whole hunks", function()
    local from = { "a", "b", "c", "d", "e", "f", "g" }
    local to = { "a", "B", "c", "d", "e", "F", "g", "h" }
    local all = hunks.compute(from, to)
    H.eq(#all, 3)
    local sel = { [all[2]] = true }
    H.eq(hunks.apply(from, to, all, sel), { "a", "b", "c", "d", "e", "F", "g" })
    sel = { [all[3]] = true }
    H.eq(hunks.apply(from, to, all, sel), { "a", "b", "c", "d", "e", "f", "g", "h" })
  end)

  H.it("selects hunks by cursor line on either side", function()
    local from = { "a", "b", "c" }
    local to = { "a", "c" }
    local all = hunks.compute(from, to)
    H.eq(#hunks.select(all, "from", 2, 2), 1)
    -- deletion: next to the filler lines on the other side
    H.eq(#hunks.select(all, "to", 1, 1), 1)
    H.eq(#hunks.select(all, "to", 2, 2), 1)
  end)

  H.it("applies selected lines of a hunk", function()
    local from = { "a", "b", "c", "z" }
    local to = { "a", "B", "C", "z" }
    local all = hunks.compute(from, to)
    H.eq(#all, 1)
    local sel = { [all[1]] = { side = "to", s = 2, e = 2 } }
    H.eq(hunks.apply(from, to, all, sel), { "a", "B", "c", "z" })
    sel = { [all[1]] = { side = "to", s = 2, e = 3 } }
    H.eq(hunks.apply(from, to, all, sel), { "a", "B", "C", "z" })
    -- delete a single line of a deletion hunk
    from, to = { "a", "b", "c", "d", "z" }, { "a", "z" }
    all = hunks.compute(from, to)
    sel = { [all[1]] = { side = "from", s = 3, e = 3 } }
    H.eq(hunks.apply(from, to, all, sel), { "a", "b", "d", "z" })
    -- add a single line of an addition hunk
    from, to = { "a", "z" }, { "a", "x", "y", "w", "z" }
    all = hunks.compute(from, to)
    sel = { [all[1]] = { side = "to", s = 3, e = 3 } }
    H.eq(hunks.apply(from, to, all, sel), { "a", "y", "z" })
  end)
end)

H.describe("merge.locate", function()
  H.it("maps untouched regions and detects edited ones", function()
    local result = { "a", "BASE1", "c", "d", "BASE2", "f" }
    local ranges = { { 1, 2 }, { 4, 5 } }
    -- first region resolved to two lines, second untouched
    local current = { "a", "X", "Y", "c", "d", "BASE2", "f" }
    local loc = merge.locate(ranges, result, current)
    H.eq({ loc[1][1], loc[1][2], loc[1].touched }, { 1, 3, true })
    H.eq({ loc[2][1], loc[2][2], loc[2].touched }, { 5, 6, false })
  end)

  H.it("tracks empty regions", function()
    local result = { "a", "b" }
    local ranges = { { 1, 1 } }
    local loc = merge.locate(ranges, result, { "a", "new", "b" })
    H.eq({ loc[1][1], loc[1][2], loc[1].touched }, { 1, 2, true })
    loc = merge.locate(ranges, result, { "x", "a", "b" })
    H.eq({ loc[1][1], loc[1][2], loc[1].touched }, { 2, 2, false })
  end)
end)

H.done()
