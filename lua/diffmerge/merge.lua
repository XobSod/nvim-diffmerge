--- Merge controller: tracks the chunks of a 3-way merge inside the merged buffer, resolves
--- them (KDiff3-style toggles of LOCAL / BASE / REMOTE) and paints the overlay.
---
--- The state of a region is derived from its content, so manual edits and undo just work:
---   picks  = ordered sources whose concatenation equals the content
---            (nil = unresolved conflict showing the base text, {} = resolved as empty)
---   edited = the content matches no combination (a manual resolution)
local config = require("diffmerge.config")
local diff3 = require("diffmerge.diff3")
local hunks = require("diffmerge.hunks")
local inline = require("diffmerge.inline")
local git = require("diffmerge.git")
local markers = require("diffmerge.markers")
local source = require("diffmerge.source")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

local ns_regions = api.nvim_create_namespace("diffmerge_regions")
local ns_hl = api.nvim_create_namespace("diffmerge_merge")
M.ns_hl = ns_hl

local SRC = { "local", "base", "remote" }

-- what DiffMerge itself put into a merged buffer (an unsaved change that is not the user's)
local written = {}

--- The merged buffer has unsaved changes made by the user (not just DiffMerge's start).
function M.user_changes(buf)
  if not vim.bo[buf].modified then
    return false
  end
  local own = written[buf]
  return not (own and util.lines_equal(util.buf_lines(buf), own))
end
local SRC_INDEX = { ["local"] = 1, base = 2, remote = 3 }

local CANDIDATES = {
  {},
  { 1 },
  { 2 },
  { 3 },
  { 1, 3 },
  { 3, 1 },
  { 1, 2 },
  { 2, 1 },
  { 2, 3 },
  { 3, 2 },
  { 1, 2, 3 },
  { 1, 3, 2 },
  { 2, 1, 3 },
  { 2, 3, 1 },
  { 3, 1, 2 },
  { 3, 2, 1 },
}

local MUTE = "DiffAdd:DiffMergeNone,DiffChange:DiffMergeNone,DiffText:DiffMergeNone,DiffTextAdd:DiffMergeNone"

local function initial_picks(kind)
  if kind == "local" or kind == "both" then
    return { 1 }
  elseif kind == "remote" then
    return { 3 }
  end
  return nil
end

local function same_picks(a, b)
  if a == nil or b == nil then
    return a == b
  end
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function contains(list, v)
  for _, x in ipairs(list or {}) do
    if x == v then
      return true
    end
  end
  return false
end

--- hunks.compute's hunks as 0-based ranges { as, ae, bs, be }.
local function zero_based(d)
  local hs = {}
  for _, h in ipairs(d) do
    local as = h.ac == 0 and h.as or h.as - 1
    local bs = h.bc == 0 and h.bs or h.bs - 1
    hs[#hs + 1] = { as = as, ae = as + h.ac, bs = bs, be = bs + h.bc }
  end
  return hs
end

--- Maps region ranges of `result` onto `current` (the result after edits).
--- Lines inserted exactly at a region's edge are ambiguous (inside or outside?); such
--- regions get `alts`: the ranges including them, to be tried first (see pick_range).
---@param ranges integer[][] 0-based end-exclusive ranges in result
---@param hs? table hunks of result -> current (zero_based; default: computed)
---@return { [1]: integer, [2]: integer, touched: boolean, alts: integer[][] }[]
function M.locate(ranges, result, current, hs)
  hs = hs or zero_based(hunks.compute(result, current))
  local out = {}
  local prev_e = 0
  for idx, r in ipairs(ranges) do
    local ms, me = r[1], r[2]
    local offset, delta = 0, 0
    local first_ov, last_ov, ins_before, ins_after
    for _, h in ipairs(hs) do
      local where
      local ins = h.as == h.ae
      if ms == me then
        if ins and h.as == ms then
          where = "overlap"
        elseif h.as < ms and h.ae > ms then
          where = "overlap"
        elseif h.ae <= ms then
          where = "before"
        else
          where = "after"
        end
      else
        if h.ae <= ms then
          where = "before"
          if ins and h.as == ms then
            ins_before = h
          end
        elseif h.as >= me then
          where = "after"
          if ins and h.as == me then
            ins_after = h
          end
        else
          where = "overlap"
        end
      end
      if where == "before" then
        offset = offset + (h.be - h.bs) - (h.ae - h.as)
      elseif where == "overlap" then
        first_ov = first_ov or h
        last_ov = h
        delta = delta + (h.be - h.bs) - (h.ae - h.as)
      else
        if not (ins and h.as == me) then
          break
        end
      end
    end
    local s = ms + offset
    local e = me + offset + delta
    if first_ov and first_ov.as < ms then
      s = first_ov.bs
    end
    if last_ov and last_ov.ae > me then
      e = last_ov.be
    end
    s = math.max(s, prev_e)
    e = math.max(e, s)
    local alts = {}
    local s_ext = ins_before and math.max(s - (ins_before.be - ins_before.bs), prev_e) or s
    local e_ext = ins_after and e + (ins_after.be - ins_after.bs) or e
    if s_ext ~= s and e_ext ~= e then
      alts[#alts + 1] = { s_ext, e_ext }
    end
    if e_ext ~= e then
      alts[#alts + 1] = { s, e_ext }
    end
    if s_ext ~= s then
      alts[#alts + 1] = { s_ext, e }
    end
    prev_e = e
    out[idx] = { s, e, touched = first_ov ~= nil or #alts > 0, alts = alts }
  end
  return out
end

--- Chooses the range of a located region: the first alternative whose content is a known
--- resolution (`matches(lines)`), else the strict range.
function M.pick_range(loc, current, matches)
  for _, alt in ipairs(loc.alts or {}) do
    if matches(util.slice(current, alt[1] + 1, alt[2])) then
      return alt[1], alt[2]
    end
  end
  return loc[1], loc[2]
end

--- Every content a region can have without manual edits (base text and all pick orders).
---@param texts { local: string[], base: string[], remote: string[] }
function M.renderings(texts)
  local out = { texts.base }
  for _, cand in ipairs(CANDIDATES) do
    local r = {}
    for _, p in ipairs(cand) do
      util.extend(r, texts[SRC[p]])
    end
    out[#out + 1] = r
  end
  return out
end

local function matcher(texts)
  local renders = M.renderings(texts)
  return function(content)
    for _, r in ipairs(renders) do
      if util.lines_equal(content, r) then
        return true
      end
    end
    return false
  end
end

local function overlaps(a, b)
  if a[1] == a[2] and b[1] == b[2] then
    return a[1] == b[1]
  elseif a[1] == a[2] then
    return a[1] >= b[1] and a[1] <= b[2]
  elseif b[1] == b[2] then
    return b[1] >= a[1] and b[1] <= a[2]
  end
  return a[1] < b[2] and a[2] > b[1]
end

local function by_start(a, b)
  return a.range[1] < b.range[1] or (a.range[1] == b.range[1] and a.range[2] < b.range[2])
end

-- base -> side hunks the way git's merge computes them (histogram, no indent heuristic), per
-- pair of line lists
local git_hunks_memo = setmetatable({}, { __mode = "k" })
local function git_hunks(base, side)
  local by_side = git_hunks_memo[base]
  if not by_side then
    by_side = setmetatable({}, { __mode = "k" })
    git_hunks_memo[base] = by_side
  end
  by_side[side] = by_side[side] or diff3.hunks(base, side, "histogram", false)
  return by_side[side]
end

--- git's own merge of the three versions (`git merge-file`, in the repository's
--- merge.conflictStyle, with the histogram diff of `git merge`): its parts as markers.parse
--- gives them, nil when git cannot run.
---@param cwd? string where git runs (its config decides the conflict style)
function M.git_merge(lines, cwd)
  local files = {}
  for k, name in ipairs(SRC) do
    files[k] = vim.fn.tempname()
    local f = io.open(files[k], "wb")
    if not f then
      return nil
    end
    -- every line starting with a letter: merge-file then joins conflicts like `git merge` does
    -- (it also joins those separated only by lines without letters or digits), and no line
    -- of the files is taken for a marker
    local t = lines[name]
    f:write(#t > 0 and ("x" .. table.concat(t, "\nx") .. "\n") or "")
    f:close()
  end
  local args = { "merge-file", "-p", "--diff-algorithm=histogram" }
  vim.list_extend(args, { "-L", "ours", "-L", "base", "-L", "theirs", files[1], files[2], files[3] })
  local res = git.run(cwd, args)
  if res.code == 129 then
    -- a git without --diff-algorithm for merge-file
    table.remove(args, 3)
    res = git.run(cwd, args)
  end
  for _, f in ipairs(files) do
    os.remove(f)
  end
  -- the exit code is the number of conflicts (at most 127)
  if (res.signal and res.signal ~= 0) or res.code < 0 or res.code > 127 then
    return nil
  end
  local parts = markers.parse((util.split_lines(res.stdout)))
  for _, part in ipairs(parts) do
    for _, key in ipairs({ "text", "ours", "base", "theirs" }) do
      for i, l in ipairs(part[key] or {}) do
        part[key][i] = l:sub(2)
      end
    end
    part.lines = nil
  end
  return parts
end

--- Where `text` is in `lines`: at `range` when no change of the diff (projection -> side)
--- touches the block, else the place nearest to `range` among the lines those changes cover.
--- nil when it is not there.
---@param window integer[] those lines (with `range`), `.touched`: whether there are changes
local function exact(lines, range, text, from, window)
  local function at(p)
    for i = 1, #text do
      if lines[p + i] ~= text[i] then
        return false
      end
    end
    return true
  end
  local s = math.max(range[1], from)
  if not window.touched then
    return at(s) and { s, s + #text } or nil
  end
  if #text == 0 then
    return { s, s }
  end
  local best
  for p = math.max(window[1], from), window[2] - #text do
    if at(p) and (not best or math.abs(p - range[1]) < math.abs(best - range[1])) then
      best = p
    end
  end
  return best and { best, best + #text }
end

-- the projections differ from the sides by the other side's changes: any diff finds those
local NEAR = { algorithm = "myers", indent_heuristic = false }

--- The conflict blocks of a merged file (parts from markers.parse) in LOCAL, BASE and REMOTE:
--- where their sides are and the texts there. A block without a BASE section (git's default
--- "merge" style) gets the BASE lines its sides replace, each of them in the first block that
--- replaces it. `edited`: the block's sides are not what LOCAL / BASE / REMOTE have (changed by
--- hand).
---@return { texts: table, side: table, edited: boolean }[] one per block
function M.block_sides(parts, lines)
  local field = { ["local"] = "ours", base = "base", remote = "theirs" }
  local blocks = {}
  -- the file with every block as one of its sides
  local proj, ranges = {}, {}
  for _, role in ipairs(SRC) do
    proj[role], ranges[role] = {}, {}
  end
  for _, part in ipairs(parts) do
    if not part.text then
      blocks[#blocks + 1] = part
    end
    for _, role in ipairs(SRC) do
      if part.text then
        util.extend(proj[role], part.text)
      else
        local first = #proj[role]
        util.extend(proj[role], part[field[role]] or {})
        ranges[role][#ranges[role] + 1] = { first, #proj[role] }
      end
    end
  end
  -- strict: git's text next to a block is what LOCAL and REMOTE have there, so a change of the
  -- diff touching the block is a change by hand (BASE: zdiff3 moves changes of both sides
  -- out of a block, next to it)
  local function find(role, strict)
    local list = lines[role]
    local hs = zero_based(hunks.compute(proj[role], list, NEAR))
    local loc = M.locate(ranges[role], proj[role], list, hs)
    local found, from, j = {}, 0, 1
    for k, part in ipairs(blocks) do
      local text, pr = part[field[role]], ranges[role][k]
      local window = { loc[k][1], loc[k][2] }
      while hs[j] and hs[j].ae < pr[1] do
        j = j + 1
      end
      local i = j
      while hs[i] and hs[i].as <= pr[2] do
        window[1], window[2] = math.min(window[1], hs[i].bs), math.max(window[2], hs[i].be)
        window.touched = true
        i = i + 1
      end
      local r = text and not (strict and window.touched) and exact(list, loc[k], text, from, window) or nil
      found[k] = { range = r or { loc[k][1], loc[k][2] }, exact = r ~= nil }
      from = math.max(from, found[k].range[2])
    end
    return found
  end
  local B = lines.base
  local in_l, in_r = find("local", true), find("remote", true)
  local in_b = vim.iter(blocks):any(function(b)
    return b.base ~= nil
  end) and find("base")
  -- what a side's lines replace in BASE
  local function via(found, side)
    local hs = {}
    for _, h in ipairs(git_hunks(B, side)) do
      hs[#hs + 1] = { as = h.os, ae = h.oe, bs = h.bs, be = h.be }
    end
    local rs = {}
    for k, f in ipairs(found) do
      rs[k] = f.range
    end
    return M.locate(rs, side, B, hs)
  end
  local via_l, via_r = via(in_l, lines["local"]), via(in_r, lines.remote)
  local out, prev = {}, 0
  for k, part in ipairs(blocks) do
    local b
    if part.base then
      b = in_b[k].range
    else
      local s = math.max(math.min(via_l[k][1], via_r[k][1]), prev)
      b = { s, math.max(via_l[k][2], via_r[k][2], s) }
    end
    prev = math.max(prev, b[2])
    local side = { ["local"] = in_l[k].range, base = b, remote = in_r[k].range }
    local texts = {}
    for _, role in ipairs(SRC) do
      texts[role] = util.slice(lines[role], side[role][1] + 1, side[role][2])
    end
    out[k] = {
      texts = texts,
      side = side,
      edited = not (in_l[k].exact and in_r[k].exact and (not part.base or in_b[k].exact)),
    }
  end
  return out
end

--- Parts of a merged file (markers.parse) as lines with every block replaced by its BASE text,
--- and the blocks as conflicts. A block changed by hand stays as it is (with its markers).
local function flatten(parts, lines)
  local sides = M.block_sides(parts, lines)
  local out, blocks = {}, {}
  for _, part in ipairs(parts) do
    if part.text then
      util.extend(out, part.text)
    else
      local b = sides[#blocks + 1]
      local first = #out
      util.extend(out, b.edited and part.lines or b.texts.base)
      blocks[#blocks + 1] = { range = { first, #out }, kind = "conflict", texts = b.texts, side = b.side }
    end
  end
  return out, blocks
end

--- `block` is a run of lines of `list`.
local function occurs(list, block)
  for p = 0, #list - #block do
    if list[p + 1] == block[1] then
      local k = 2
      while k <= #block and list[p + k] == block[k] do
        k = k + 1
      end
      if k > #block then
        return true
      end
    end
  end
  return false
end

--- Blocks that LOCAL, BASE or REMOTE have as text, markers and all, are text (a file showing
--- conflict markers, e.g. documentation).
local function drop_literal(parts, lines)
  for i, part in ipairs(parts) do
    if part.lines then
      for _, role in ipairs(SRC) do
        if occurs(lines[role], part.lines) then
          parts[i] = { text = part.lines }
          break
        end
      end
    end
  end
  return parts
end

--- Git conflict markers present (the file is in git's conflicted state)? With the three
--- versions: blocks they have as text do not count.
---@param sides? table<string, string[]> local / base / remote
function M.has_markers(lines, sides)
  local parts = markers.parse(lines)
  if sides then
    parts = drop_literal(parts, sides)
  end
  for _, part in ipairs(parts) do
    if part.ours then
      return true
    end
  end
  return false
end

--- A file with git's conflict markers in the form of the model: every block replaced by its
--- BASE text.
---@return string[] lines, { range: integer[], kind: string, texts: table, side: table }[] blocks
function M.from_git_markers(current, lines)
  return flatten(drop_literal(markers.parse(current), lines), lines)
end

--- The regions of a merge and the text they are located in.
---
--- reference: git's merge with every conflict block showing its BASE text. Its blocks are the
--- conflicts; DiffMerge's one-sided and identical changes where git merged the same way are
--- regions too (signs, picks). Without git: DiffMerge's own merge.
---@param lines table<string, string[]> local / base / remote
---@param cwd? string where git runs
---@return string[] reference, { range: integer[], kind: string, texts: table, side: table }[] regions, table? parts git's merge (markers.parse)
function M.model(lines, cwd)
  local L, B, R = lines["local"], lines.base, lines.remote
  local chunks = diff3.compute(B, L, R, { d1 = git_hunks(B, L), d2 = git_hunks(B, R) })
  local result = diff3.result(chunks, B, L, R)
  local list, ranges = {}, {}
  for _, c in ipairs(chunks) do
    if c.kind ~= "equal" then
      list[#list + 1] = c
      ranges[#ranges + 1] = c.merged
    end
  end
  local function chunk_region(c, range)
    return {
      range = { range[1], range[2] },
      kind = c.kind,
      texts = {
        ["local"] = diff3.slice(L, c["local"]),
        base = diff3.slice(B, c.base),
        remote = diff3.slice(R, c.remote),
      },
      side = { ["local"] = c["local"], base = c.base, remote = c.remote },
    }
  end
  local parts = M.git_merge(lines, cwd)
  if not parts then
    local regions = {}
    for _, c in ipairs(list) do
      regions[#regions + 1] = chunk_region(c, c.merged)
    end
    return result, regions
  end
  local reference, conflicts = flatten(parts, lines)
  local regions = vim.list_slice(conflicts)
  local located = M.locate(ranges, result, reference)
  for k, c in ipairs(list) do
    local at = { located[k][1], located[k][2] }
    local inside = vim.iter(conflicts):any(function(b)
      return overlaps(b.range, at)
    end)
    if c.kind ~= "conflict" and not inside and not located[k].touched then
      regions[#regions + 1] = chunk_region(c, at)
    end
  end
  table.sort(regions, by_start)
  return reference, regions, parts
end

--- Regions of the model found in `current` (the merged file as it is now). The blocks of git's
--- markers (from_git_markers) are the conflicts where they are.
---@param blocks? table[]
---@return { range: integer[], kind: string, texts: table, side: table }[]
function M.place(reference, regions, current, blocks)
  blocks = blocks or {}
  local ranges = {}
  for k, r in ipairs(regions) do
    ranges[k] = r.range
  end
  local located = not util.lines_equal(current, reference) and M.locate(ranges, reference, current)
  local out = vim.list_slice(blocks)
  for k, r in ipairs(regions) do
    local s, e = r.range[1], r.range[2]
    if located then
      s, e = M.pick_range(located[k], current, matcher(r.texts))
    end
    local at = { s, e }
    local covered = vim.iter(blocks):any(function(b)
      return overlaps(b.range, at)
    end)
    if not covered then
      out[#out + 1] = { range = at, kind = r.kind, texts = r.texts, side = r.side }
    end
  end
  table.sort(out, by_start)
  return out
end

-- DiffMerge's conversion of a merged buffer with git's markers: the buffer before and after
-- (and the undo state after), the regions placed then and the sides they come from
local converted = {}

local function conversion(buf, lines)
  local c = buf and converted[buf]
  if not c or not api.nvim_buf_is_valid(buf) then
    return nil
  end
  for _, role in ipairs(SRC) do
    if not util.lines_equal(c.sides[role], lines[role]) then
      return nil
    end
  end
  return c
end

local function remember(buf, c)
  converted[buf] = c
  api.nvim_create_autocmd("BufReadPost", {
    buffer = buf,
    callback = function()
      if converted[buf] ~= c then
        return true
      end
      if M.has_markers(util.buf_lines(buf), c.sides) then
        -- git's conflicted file again
        converted[buf] = nil
        return true
      end
      -- the merge as saved: its conflicts are still these, the undo history is another
      c.seq = nil
    end,
  })
end

--- The merged file as the merge starts from it, and its regions there. A file with git's
--- markers is converted (if `convert`): its blocks replaced by their BASE text. A buffer
--- DiffMerge converted keeps the conflicts of then; otherwise they are git's merge of the
--- three versions.
---@param buf? integer the loaded buffer of the merged file
---@return string[] lines, table[] regions, boolean converted
function M.start(buf, current, lines, cwd, convert)
  local c = conversion(buf, lines)
  if c and not util.lines_equal(current, c.before) then
    return current, M.place(c.lines, c.regions, current), false
  end
  local reference, regions, parts = M.model(lines, cwd)
  local blocks_in = parts and vim.iter(parts):any(function(p)
    return p.ours ~= nil
  end)
  if convert and blocks_in and markers.matches(current, parts) then
    -- git's merge as git wrote it (whatever its sides contain)
    return reference, M.place(reference, regions, reference), true
  end
  if not convert or not M.has_markers(current, lines) then
    return current, M.place(reference, regions, current), false
  end
  local out, blocks = M.from_git_markers(current, lines)
  return out, M.place(reference, regions, out, blocks), true
end

---------------------------------------------------------------------------
-- Controller
---------------------------------------------------------------------------

---@class diffmerge.Region
---@field kind "local"|"remote"|"both"|"conflict"
---@field texts { local: string[], base: string[], remote: string[] }
---@field side table<string, integer[]> its lines in the LOCAL / BASE / REMOTE windows (0-based, end exclusive)
---@field picks? integer[]
---@field edited boolean
---@field sticky? string[] content that stays unresolved (modify/delete)
---@field id integer extmark id in the merged buffer

local Controller = {}
Controller.__index = Controller

local function buf_lines(info)
  if not info or info.src.kind == "empty" then
    return {}
  end
  return util.buf_lines(info.buf, info)
end

local function key_hint()
  local maps = config.options.keymaps.merge or {}
  local names = { toggle_local = true, toggle_base = true, toggle_remote = true }
  local found = {}
  for lhs, action in pairs(maps) do
    if names[action] then
      found[action] = (lhs:gsub("<[Ll]eader>", vim.g.mapleader or "\\"))
    end
  end
  local parts = {}
  for _, a in ipairs({ "toggle_local", "toggle_base", "toggle_remote" }) do
    if found[a] then
      parts[#parts + 1] = found[a]
    end
  end
  return table.concat(parts, " ")
end

--- Attaches to the merge entry currently shown by `view`.
---@param infos table<string, diffmerge.BufInfo>
function M.attach(view, entry, infos)
  if not infos.merged or infos.merged.src.kind == "empty" then
    return nil
  end
  local self = setmetatable({
    view = view,
    entry = entry,
    infos = infos,
    buf = infos.merged.buf,
    regions = {},
    hint = key_hint(),
    inline = inline.cache(),
  }, Controller)
  -- sides without a window (BASE in the 3-way layouts) are read directly
  local function lines_for(role)
    if infos[role] then
      return buf_lines(infos[role])
    end
    local src = entry.sides[role]
    if not src or src.kind == "empty" then
      return {}
    end
    return source.read_lines(view.repo, src) or {}
  end
  self.lines = {
    ["local"] = lines_for("local"),
    base = lines_for("base"),
    remote = lines_for("remote"),
  }
  -- modify/delete conflicts: the file holds git's pick of the surviving side; that is not a
  -- decision of the user, so the conflict stays unresolved until it is touched
  local L, R = entry.sides["local"], entry.sides.remote
  local modify_delete = (L and L.kind == "empty") ~= (R and R.kind == "empty")
  local before = util.buf_lines(self.buf, infos.merged)
  local c = conversion(self.buf, self.lines)
  if c and c.seq and vim.fn.undotree(self.buf).seq_cur < c.seq and util.lines_equal(before, c.before) then
    -- undone to git's markers while the merge was not shown: forward to its start (redo stays)
    api.nvim_buf_call(self.buf, function()
      pcall(vim.cmd, "silent undo " .. c.seq)
    end)
    before = util.buf_lines(self.buf, infos.merged)
  end
  local cwd = view.repo and view.repo.root ~= "" and view.repo.root or nil
  local current, placed, changed = M.start(self.buf, before, self.lines, cwd, vim.bo[self.buf].modifiable)
  if changed then
    -- git's conflicted file: its merge stays, every block starts with its BASE text (one
    -- undo step)
    local had_edits = vim.bo[self.buf].modified
    api.nvim_buf_set_lines(self.buf, 0, -1, false, current)
    written[self.buf] = not had_edits and current or nil
    remember(self.buf, {
      before = before,
      seq = vim.fn.undotree(self.buf).seq_cur,
      lines = current,
      regions = placed,
      sides = self.lines,
    })
  end
  for _, p in ipairs(placed) do
    local region = {
      kind = p.kind,
      texts = p.texts,
      side = p.side,
      picks = initial_picks(p.kind),
      edited = false,
    }
    self:set_mark(region, p.range[1], p.range[2])
    if modify_delete and p.kind == "conflict" then
      region.sticky = api.nvim_buf_get_lines(self.buf, p.range[1], p.range[2], false)
    end
    self.regions[#self.regions + 1] = region
  end
  self.conflicts = 0
  for _, r in ipairs(self.regions) do
    if r.kind == "conflict" then
      self.conflicts = self.conflicts + 1
    end
  end
  self:sync()
  M.suspend_linematch()
  api.nvim_buf_attach(self.buf, false, {
    on_lines = function()
      if self.detached then
        return true
      end
      self:schedule_sync()
    end,
  })
  for _, win in pairs(view.layout.wins) do
    if util.win_valid(win) then
      util.set_wo(win, "winhighlight", MUTE)
      -- the cursor line would cover the colours: only its number shows it
      util.set_wo(win, "cursorlineopt", "number")
    end
  end
  -- the merged file may be open in other windows too: colours and signs only here
  util.scope_ns(ns_hl, view, view.layout:diff_wins())
  -- the key hint follows the conflict under the cursor
  self.augroup = api.nvim_create_augroup("DiffMergeMerge" .. self.buf, { clear = true })
  -- the file read again (:e!, changed on disk): the regions start over
  api.nvim_create_autocmd("BufReadPost", {
    group = self.augroup,
    buffer = self.buf,
    callback = function()
      self.stale = true
      vim.schedule(function()
        if not self.detached then
          self.view:show_entry(self.entry, { force = true })
        end
      end)
    end,
  })
  local bufs = { self.buf }
  for _, role in ipairs(SRC) do
    if infos[role] then
      bufs[#bufs + 1] = infos[role].buf
    end
  end
  for _, b in ipairs(bufs) do
    api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = b,
      callback = function()
        if self.detached then
          return
        end
        local r = self:region_at(api.nvim_get_current_win())
        if r ~= self.cursor_region then
          self.cursor_region = r
          self:render()
        end
      end,
    })
  end
  -- inline differences follow 'diffopt' (inline:, iwhite, icase)
  api.nvim_create_autocmd("OptionSet", {
    group = self.augroup,
    pattern = "diffopt",
    callback = function()
      vim.schedule(function()
        self:render()
      end)
    end,
  })
  -- 'diffopt' is global: only drop linematch while this merge is on screen
  api.nvim_create_autocmd("TabLeave", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() == view.layout.tab then
        M.restore_linematch()
      end
    end,
  })
  api.nvim_create_autocmd("TabEnter", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() == view.layout.tab then
        M.suspend_linematch()
      end
    end,
  })
  self.cursor_region = self:region_at(api.nvim_get_current_win())
  self:render()
  return self
end

--- linematch aligns similar lines inside a changed block; with 3+ windows it staggers the
--- versions of a conflict on different rows. Merge views align chunks by position instead.
local saved_linematch
function M.suspend_linematch()
  if saved_linematch then
    return
  end
  for _, item in ipairs(vim.opt.diffopt:get()) do
    if item:match("^linematch:") then
      saved_linematch = item
      vim.opt.diffopt:remove(item)
      return
    end
  end
end

function M.restore_linematch()
  if saved_linematch then
    vim.opt.diffopt:append(saved_linematch)
    saved_linematch = nil
  end
end

--- Places the region mark. Text inserted at the edges of a region stays outside of it (the
--- start moves with insertions, the end does not); an empty region stays before them.
function Controller:set_mark(r, s, e)
  r.id = api.nvim_buf_set_extmark(self.buf, ns_regions, s, 0, {
    id = r.id,
    end_row = e,
    end_col = 0,
    right_gravity = e > s,
    end_right_gravity = false,
  })
  r.empty_mark = e == s
end

function Controller:detach()
  local c = converted[self.buf]
  -- (stale: the text was replaced as a whole, the marks no longer follow it)
  local current = c and not self.detached and not self.stale and api.nvim_buf_is_loaded(self.buf)
  if current and conversion(self.buf, self.lines) then
    -- the conversion as it is now: placing it again needs no guessing
    local regions = {}
    for _, r in ipairs(self.regions) do
      local s, e = self:range(r)
      regions[#regions + 1] = { range = { s, e }, kind = r.kind, texts = r.texts, side = r.side }
    end
    c.lines, c.regions = util.buf_lines(self.buf), regions
  end
  self.detached = true
  M.restore_linematch()
  util.scope_ns(ns_hl, self.view, nil)
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, info in pairs(self.infos) do
    if api.nvim_buf_is_valid(info.buf) then
      api.nvim_buf_clear_namespace(info.buf, ns_hl, 0, -1)
    end
  end
  if api.nvim_buf_is_valid(self.buf) then
    api.nvim_buf_clear_namespace(self.buf, ns_regions, 0, -1)
  end
end

function Controller:range(r)
  local m = api.nvim_buf_get_extmark_by_id(self.buf, ns_regions, r.id, { details = true })
  if not m or not m[1] then
    return 0, 0
  end
  local s, e = m[1], m[3].end_row or m[1]
  local count = api.nvim_buf_line_count(self.buf)
  s, e = math.min(s, count), math.min(e, count)
  if s > e then
    -- the whole region was replaced (paste, :s): the new text is the region
    s, e = e, s
    self:set_mark(r, s, e)
  elseif (s == e) ~= (r.empty_mark == true) then
    self:set_mark(r, s, e)
  end
  return s, e
end

function Controller:render_picks(r, picks)
  if picks == nil then
    return r.texts.base
  end
  local out = {}
  for _, p in ipairs(picks) do
    util.extend(out, r.texts[SRC[p]])
  end
  return out
end

--- Re-derives the state of every region from the buffer content.
function Controller:sync()
  local c = converted[self.buf]
  if
    c
    and not self.rewinding
    and api.nvim_buf_line_count(self.buf) == math.max(#c.before, 1)
    and util.lines_equal(util.buf_lines(self.buf), c.before)
  then
    -- undone to git's markers: forward to the start of the merge again (redo stays)
    self.rewinding, self.stale = true, true
    vim.schedule(function()
      if self.detached then
        return
      end
      api.nvim_buf_call(self.buf, function()
        pcall(vim.cmd, "silent undo " .. c.seq)
      end)
      util.info("the merge starts here: git's conflict markers are not brought back")
      self.view:show_entry(self.entry, { force = true })
    end)
    return
  end
  for _, r in ipairs(self.regions) do
    local s, e = self:range(r)
    local content = api.nvim_buf_get_lines(self.buf, s, e, false)
    if r.sticky and not util.lines_equal(content, r.sticky) then
      r.sticky = nil
    end
    if r.sticky then
      r.picks, r.edited = nil, false
    elseif util.lines_equal(content, self:render_picks(r, r.picks)) then
      r.edited = false
    else
      local found = false
      if r.kind == "conflict" and util.lines_equal(content, self:render_picks(r, nil)) then
        r.picks, found = nil, true
      end
      if not found then
        for _, cand in ipairs(CANDIDATES) do
          if util.lines_equal(content, self:render_picks(r, cand)) then
            r.picks, found = cand, true
            break
          end
        end
      end
      r.edited = not found
      if r.edited and r.kind == "conflict" and M.has_markers(content, self.lines) then
        -- git's markers in it: still open
        r.picks, r.edited = nil, false
      end
    end
  end
end

function Controller:schedule_sync()
  if self.pending then
    return
  end
  self.pending = true
  vim.schedule(function()
    self.pending = false
    if self.detached or not api.nvim_buf_is_valid(self.buf) then
      return
    end
    self:sync()
    self:render()
    self.view:update_winbars()
  end)
end

function Controller:is_unresolved(r)
  return r.kind == "conflict" and (r.sticky ~= nil or (r.picks == nil and not r.edited))
end

function Controller:stats()
  local unresolved = 0
  for _, r in ipairs(self.regions) do
    if self:is_unresolved(r) then
      unresolved = unresolved + 1
    end
  end
  return { conflicts = self.conflicts or 0, unresolved = unresolved, chunks = #self.regions }
end

local function picks_text(picks)
  if #picks == 0 then
    return "∅"
  end
  if #picks > 2 then
    return "**"
  end
  return table.concat(picks)
end

function Controller:style(r)
  if r.edited then
    return { hl = "DiffMergeEdited", sign = "✎", sign_hl = "DiffMergeEditedSign" }
  end
  if r.kind == "conflict" then
    if r.picks == nil then
      return { hl = "DiffMergeConflict", sign = "!", sign_hl = "DiffMergeConflictSign" }
    end
    return { hl = "DiffMergeResolved", sign = picks_text(r.picks), sign_hl = "DiffMergeResolvedSign" }
  end
  if not same_picks(r.picks, initial_picks(r.kind)) then
    return { hl = "DiffMergeResolved", sign = picks_text(r.picks), sign_hl = "DiffMergeResolvedSign" }
  end
  local hl = #r.texts.base == 0 and "DiffMergeAdd" or "DiffMergeChange"
  if r.kind == "local" then
    return { hl = hl, sign = "L", sign_hl = "DiffMergeLocalSign" }
  elseif r.kind == "remote" then
    return { hl = hl, sign = "R", sign_hl = "DiffMergeRemoteSign" }
  end
  return { hl = hl, sign = "=", sign_hl = "DiffMergeBothSign" }
end

-- character level differences, by the colour of their chunk
local TEXT = {
  DiffMergeConflict = "DiffMergeConflictText",
  DiffMergeResolved = "DiffMergeResolvedText",
  DiffMergeEdited = "DiffMergeEditedText",
  DiffMergeAdd = "DiffMergeChangeText",
  DiffMergeChange = "DiffMergeChangeText",
}

--- Paints the inline differences of `lines` (shown from `row` on) against `ref`.
function Controller:paint_inline(buf, row, lines, ref, group)
  local ranges = self.inline(lines, ref)
  for k, list in pairs(ranges) do
    for _, r in ipairs(list) do
      pcall(api.nvim_buf_set_extmark, buf, ns_hl, row + k - 1, r[1], {
        end_col = r[2],
        hl_group = group,
        priority = 70,
      })
    end
  end
end

local relevant = {
  ["local"] = { ["local"] = true, both = true, conflict = true },
  remote = { remote = true, both = true, conflict = true },
  base = { ["local"] = true, remote = true, both = true, conflict = true },
}

function Controller:render()
  if self.detached then
    return
  end
  local buf = self.buf
  api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
  for _, role in ipairs(SRC) do
    local info = self.infos[role]
    if info and api.nvim_buf_is_valid(info.buf) then
      api.nvim_buf_clear_namespace(info.buf, ns_hl, 0, -1)
    end
  end
  local line_count = api.nvim_buf_line_count(buf)
  local k = 0
  for _, r in ipairs(self.regions) do
    local s, e = self:range(r)
    local style = self:style(r)
    -- range highlights: diff mode ignores line_hl_group on changed lines
    if e > s then
      pcall(api.nvim_buf_set_extmark, buf, ns_hl, s, 0, {
        end_row = e,
        end_col = 0,
        hl_group = style.hl,
        hl_eol = true,
        priority = 60,
      })
    end
    local opts = { sign_text = style.sign, sign_hl_group = style.sign_hl, priority = 60 }
    if r.kind == "conflict" then
      k = k + 1
      if config.options.merge.virtual_text then
        local text = ("  ⚑ %d/%d"):format(k, self.conflicts)
        if self:is_unresolved(r) and r == self.cursor_region and self.hint ~= "" then
          text = text .. "  " .. self.hint
        end
        if s == e then
          text = text .. "   (empty below)"
        end
        opts.virt_text = { { text, "DiffMergeVirtText" } }
        opts.virt_text_pos = "eol"
      end
    end
    if e > s and not self:is_unresolved(r) then
      -- what the merge changed against BASE
      local content = api.nvim_buf_get_lines(buf, s, e, false)
      self:paint_inline(buf, s, content, r.texts.base, TEXT[style.hl])
    end
    local row = s
    if s == e and s > 0 then
      row = s - 1 -- empty region: annotate the line above
    end
    row = math.min(row, line_count - 1)
    pcall(api.nvim_buf_set_extmark, buf, ns_hl, row, 0, opts)

    for _, role in ipairs(SRC) do
      local info = self.infos[role]
      local rr = r.side[role]
      if info and relevant[role][r.kind] and api.nvim_buf_is_valid(info.buf) then
        local hl
        if r.kind == "conflict" then
          hl = style.hl
        else
          hl = #r.texts.base == 0 and "DiffMergeAdd" or "DiffMergeChange"
        end
        if rr[2] > rr[1] then
          pcall(api.nvim_buf_set_extmark, info.buf, ns_hl, rr[1], 0, {
            end_row = rr[2],
            end_col = 0,
            hl_group = hl,
            hl_eol = true,
            priority = 60,
          })
          -- a conflict's sides against each other (what the choice is about), a one-sided
          -- change (and BASE) against what replaced / was replaced
          local ref
          if r.kind == "conflict" then
            ref = role == "remote" and "local" or "remote"
            if role == "base" then
              ref = "local"
            end
          elseif role == "base" then
            ref = r.kind == "remote" and "remote" or "local"
          else
            ref = "base"
          end
          self:paint_inline(info.buf, rr[1], r.texts[role], r.texts[ref], TEXT[hl])
        end
        if rr[2] > rr[1] and r.picks and contains(r.picks, SRC_INDEX[role]) and not r.edited then
          pcall(api.nvim_buf_set_extmark, info.buf, ns_hl, rr[1], 0, {
            sign_text = "✓",
            sign_hl_group = "DiffMergeResolvedSign",
            priority = 60,
          })
        end
      end
    end
  end
end

--- Region under the cursor of `win` (any window of the merge layout).
function Controller:region_at(win)
  local role = self.view.layout:role_of(win)
  if not role then
    return nil
  end
  local lnum = api.nvim_win_get_cursor(win)[1] - 1
  local near
  for _, r in ipairs(self.regions) do
    local s, e
    if role == "merged" then
      s, e = self:range(r)
    else
      s, e = r.side[role][1], r.side[role][2]
    end
    if s < e then
      if lnum >= s and lnum < e then
        return r
      end
    elseif lnum == s or lnum == s - 1 then
      -- empty chunk next to the cursor; prefer the one being worked on
      if not near or r == self.cursor_region or (near ~= self.cursor_region and lnum == s) then
        near = r
      end
    end
  end
  return near
end

function Controller:set_region(r, picks, win)
  local lines = self:render_picks(r, picks)
  local s, e = self:range(r)
  if not vim.bo[self.buf].modifiable then
    util.warn("the merged buffer is not modifiable")
    return
  end
  local count = api.nvim_buf_line_count(self.buf)
  if count == 1 and s == 0 and api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] == "" then
    -- an empty buffer still has one (phantom) line: replace it instead of inserting before
    e = 1
  end
  api.nvim_buf_set_lines(self.buf, s, e, false, lines)
  self:set_mark(r, s, s + #lines)
  r.picks = picks
  r.edited = false
  r.sticky = nil
  -- keep the cursor on the chunk so the next toggle applies to it too
  if win and win == self.view.layout.wins.merged and util.win_valid(win) then
    local row = math.min(s, api.nvim_buf_line_count(self.buf) - 1)
    api.nvim_win_set_cursor(win, { row + 1, 0 })
  end
  self.cursor_region = r
  self:render()
  self.view:update_winbars()
end

function Controller:toggle(src, ctx)
  local r = self:region_at(ctx.win)
  if not r then
    util.info("no change under the cursor")
    return
  end
  local picks = {}
  if r.picks and not r.edited and not r.sticky then
    picks = vim.deepcopy(r.picks)
  end
  local found
  for i, p in ipairs(picks) do
    if p == src then
      found = i
    end
  end
  if found then
    table.remove(picks, found)
  else
    picks[#picks + 1] = src
  end
  if #picks == 0 and r.kind == "conflict" then
    picks = nil
  end
  self:set_region(r, picks, ctx.win)
end

function Controller:take_none(ctx)
  local r = self:region_at(ctx.win)
  if not r then
    util.info("no change under the cursor")
    return
  end
  self:set_region(r, {}, ctx.win)
end

function Controller:start_in(r, role)
  if role == "merged" then
    return (self:range(r))
  end
  return r.side[role][1]
end

function Controller:jump(ctx, dir, conflicts_only)
  local win = ctx.win
  local role = self.view.layout:role_of(win)
  if not role then
    return
  end
  local lnum = api.nvim_win_get_cursor(win)[1] - 1
  local starts = {}
  for _, r in ipairs(self.regions) do
    if not conflicts_only or r.kind == "conflict" then
      starts[#starts + 1] = self:start_in(r, role)
    end
  end
  table.sort(starts)
  for i = #starts, 2, -1 do
    if starts[i] == starts[i - 1] then
      table.remove(starts, i)
    end
  end
  if #starts == 0 then
    util.info(conflicts_only and "no conflicts" or "no changes")
    return
  end
  local target
  if dir > 0 then
    for _, s in ipairs(starts) do
      if s > lnum then
        target = s
        break
      end
    end
    target = target or starts[1]
  else
    for i = #starts, 1, -1 do
      if starts[i] < lnum then
        target = starts[i]
        break
      end
    end
    target = target or starts[#starts]
  end
  local count = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  target = math.max(0, math.min(target, count - 1))
  api.nvim_win_set_cursor(win, { target + 1, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
end

--- Cursor to the first unresolved conflict (or first change) in the merged window.
function Controller:goto_first()
  local win = self.view.layout.wins.merged
  if not util.win_valid(win) then
    return
  end
  local target
  for _, r in ipairs(self.regions) do
    if self:is_unresolved(r) then
      target = r
      break
    end
  end
  target = target or self.regions[1]
  local row = target and (self:range(target)) or 0
  row = math.min(row, api.nvim_buf_line_count(self.buf) - 1)
  api.nvim_win_set_cursor(win, { row + 1, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
  self.cursor_region = target
  self:render()
end

---------------------------------------------------------------------------
-- Without a controller (file panel, mergetool exit code)
---------------------------------------------------------------------------

--- Number of conflicts of a merge entry that are still unresolved in the merged file
--- (loaded buffer content if any, else the file on disk).
local function read(repo, src)
  if not src or src.kind == "empty" then
    return {}
  end
  return source.read_lines(repo, src) or {}
end

--- LOCAL / BASE / REMOTE of a merge entry.
function M.side_lines(repo, entry)
  return {
    ["local"] = read(repo, entry.sides["local"]),
    base = read(repo, entry.sides.base),
    remote = read(repo, entry.sides.remote),
  }
end

function M.count_unresolved(repo, entry)
  local lines = M.side_lines(repo, entry)
  local merged = entry.sides.merged
  local current, buf = {}, nil
  if merged and merged.kind ~= "empty" then
    local abs = merged.kind == "worktree" and vim.fs.joinpath(repo.root, merged.path) or merged.abspath
    buf = util.find_buf(abs)
    if buf and api.nvim_buf_is_loaded(buf) then
      current = util.buf_lines(buf)
    else
      buf = nil
      current = read(repo, merged)
    end
  end
  local L, R = entry.sides["local"], entry.sides.remote
  -- modify/delete: only an explicit decision resolves it
  local modify_delete = (L and L.kind == "empty") ~= (R and R.kind == "empty")
  local placed
  current, placed = M.start(buf, current, lines, repo.root ~= "" and repo.root or nil, true)
  local n = 0
  for _, p in ipairs(placed) do
    if p.kind == "conflict" then
      local content = util.slice(current, p.range[1] + 1, p.range[2])
      local open = modify_delete or util.lines_equal(content, p.texts.base)
      if open or (not matcher(p.texts)(content) and M.has_markers(content, lines)) then
        n = n + 1
      end
    end
  end
  return n
end

return M
