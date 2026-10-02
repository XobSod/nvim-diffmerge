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

--- Git conflict markers present (the file is in git's conflicted state)?
function M.has_markers(lines)
  local open, sep, close = false, false, false
  for _, l in ipairs(lines) do
    if l:sub(1, 8) == "<<<<<<< " or l == "<<<<<<<" then
      open = true
    elseif l == "=======" then
      sep = true
    elseif l:sub(1, 8) == ">>>>>>> " or l == ">>>>>>>" then
      close = true
    end
  end
  return open and sep and close
end

--- Maps region ranges of `result` onto `current` (the result after edits).
--- Lines inserted exactly at a region's edge are ambiguous (inside or outside?); such
--- regions get `alts`: the ranges including them, to be tried first (see pick_range).
---@param ranges integer[][] 0-based end-exclusive ranges in result
---@return { [1]: integer, [2]: integer, touched: boolean, alts: integer[][] }[]
function M.locate(ranges, result, current)
  local d = hunks.compute(result, current)
  local hs = {}
  for _, h in ipairs(d) do
    local as = h.ac == 0 and h.as or h.as - 1
    local bs = h.bc == 0 and h.bs or h.bs - 1
    hs[#hs + 1] = { as = as, ae = as + h.ac, bs = bs, be = bs + h.bc }
  end
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

--- Every content a chunk can have without manual edits (base text and all pick orders).
function M.renderings(chunk, lines)
  local function slice(name)
    return diff3.slice(lines[name], chunk[name])
  end
  local out = { slice("base") }
  for _, cand in ipairs(CANDIDATES) do
    local r = {}
    for _, p in ipairs(cand) do
      util.extend(r, slice(SRC[p]))
    end
    out[#out + 1] = r
  end
  return out
end

local function matcher(chunk, lines)
  local renders = M.renderings(chunk, lines)
  return function(content)
    for _, r in ipairs(renders) do
      if util.lines_equal(content, r) then
        return true
      end
    end
    return false
  end
end

---------------------------------------------------------------------------
-- Controller
---------------------------------------------------------------------------

---@class diffmerge.Region
---@field chunk diffmerge.Chunk
---@field kind string
---@field picks? integer[]
---@field edited boolean
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
  self.chunks = diff3.compute(self.lines.base, self.lines["local"], self.lines.remote)
  local result = diff3.result(self.chunks, self.lines.base, self.lines["local"], self.lines.remote)
  local list, ranges = {}, {}
  for _, c in ipairs(self.chunks) do
    if c.kind ~= "equal" then
      list[#list + 1] = c
      ranges[#ranges + 1] = { c.merged[1], c.merged[2] }
    end
  end
  local current = api.nvim_buf_get_lines(self.buf, 0, -1, false)
  if #current == 1 and current[1] == "" then
    current = {}
  end
  -- modify/delete conflicts: the file holds git's pick of the surviving side; that is not a
  -- decision of the user, so the conflict stays unresolved until it is touched
  local L, R = entry.sides["local"], entry.sides.remote
  local modify_delete = (L and L.kind == "empty") ~= (R and R.kind == "empty")
  local located
  if M.has_markers(current) then
    -- fresh conflict: start from the auto-merge result (one undo step)
    if vim.bo[self.buf].modifiable then
      api.nvim_buf_set_lines(self.buf, 0, -1, false, result)
      written[self.buf] = result
    end
  elseif not util.lines_equal(current, result) then
    located = M.locate(ranges, result, current)
  end
  for k, c in ipairs(list) do
    local s_, e_ = ranges[k][1], ranges[k][2]
    if located then
      s_, e_ = M.pick_range(located[k], current, matcher(c, self.lines))
    end
    local region = {
      chunk = c,
      kind = c.kind,
      picks = initial_picks(c.kind),
      edited = false,
      index = k,
    }
    self:set_mark(region, s_, e_)
    if modify_delete and c.kind == "conflict" then
      region.sticky = api.nvim_buf_get_lines(self.buf, s_, e_, false)
    end
    self.regions[#self.regions + 1] = region
  end
  self.conflicts = diff3.count_conflicts(self.chunks)
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
      vim.wo[win].winhighlight = MUTE
    end
  end
  -- the merged file may be open in other windows too: colours and signs only here
  util.scope_ns(ns_hl, view, view.layout:diff_wins())
  -- the key hint follows the conflict under the cursor
  self.augroup = api.nvim_create_augroup("DiffMergeMerge" .. self.buf, { clear = true })
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
    return diff3.slice(self.lines.base, r.chunk.base)
  end
  local out = {}
  for _, p in ipairs(picks) do
    local name = SRC[p]
    util.extend(out, diff3.slice(self.lines[name], r.chunk[name]))
  end
  return out
end

--- Re-derives the state of every region from the buffer content.
function Controller:sync()
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
  local hl = (r.chunk.base[1] == r.chunk.base[2]) and "DiffMergeAdd" or "DiffMergeChange"
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
      self:paint_inline(buf, s, content, diff3.slice(self.lines.base, r.chunk.base), TEXT[style.hl])
    end
    local row = s
    if s == e and s > 0 then
      row = s - 1 -- empty region: annotate the line above
    end
    row = math.min(row, line_count - 1)
    pcall(api.nvim_buf_set_extmark, buf, ns_hl, row, 0, opts)

    for _, role in ipairs(SRC) do
      local info = self.infos[role]
      if info and relevant[role][r.kind] and api.nvim_buf_is_valid(info.buf) then
        local rr = r.chunk[role]
        local hl
        if r.kind == "conflict" then
          hl = style.hl
        else
          hl = (r.chunk.base[1] == r.chunk.base[2]) and "DiffMergeAdd" or "DiffMergeChange"
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
          self:paint_inline(
            info.buf,
            rr[1],
            diff3.slice(self.lines[role], rr),
            diff3.slice(self.lines[ref], r.chunk[ref]),
            TEXT[hl]
          )
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
      s, e = r.chunk[role][1], r.chunk[role][2]
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
  return r.chunk[role][1]
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
function M.count_unresolved(repo, entry)
  local function read(src)
    if not src or src.kind == "empty" then
      return {}
    end
    return source.read_lines(repo, src) or {}
  end
  local lines = {
    ["local"] = read(entry.sides["local"]),
    base = read(entry.sides.base),
    remote = read(entry.sides.remote),
  }
  local merged = entry.sides.merged
  local current = {}
  if merged and merged.kind ~= "empty" then
    local abs = merged.kind == "worktree" and vim.fs.joinpath(repo.root, merged.path) or merged.abspath
    local buf = util.find_buf(abs)
    if buf and api.nvim_buf_is_loaded(buf) then
      current = api.nvim_buf_get_lines(buf, 0, -1, false)
      if #current == 1 and current[1] == "" then
        current = {}
      end
    else
      current = read(merged)
    end
  end
  local chunks = diff3.compute(lines.base, lines["local"], lines.remote)
  local result = diff3.result(chunks, lines.base, lines["local"], lines.remote)
  local conflicts = diff3.count_conflicts(chunks)
  local L, R = entry.sides["local"], entry.sides.remote
  if (L and L.kind == "empty") ~= (R and R.kind == "empty") then
    return conflicts -- modify/delete: only an explicit decision resolves it
  end
  if M.has_markers(current) or util.lines_equal(current, result) then
    return conflicts
  end
  local list, ranges = {}, {}
  for _, c in ipairs(chunks) do
    if c.kind ~= "equal" then
      list[#list + 1] = c
      ranges[#ranges + 1] = c.merged
    end
  end
  local located = M.locate(ranges, result, current)
  local n = 0
  for k, c in ipairs(list) do
    if c.kind == "conflict" then
      local s, e = M.pick_range(located[k], current, matcher(c, lines))
      if util.lines_equal(util.slice(current, s + 1, e), diff3.slice(lines.base, c.base)) then
        n = n + 1
      end
    end
  end
  return n
end

return M
