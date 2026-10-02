--- Staging view overlay: HEAD | WORKING TREE | INDEX, every change painted by its state.
---
--- The changes are the chunks of a 3-way diff with base = HEAD, local = WORKING TREE and
--- remote = INDEX:
---   local     only the working tree changed        -> unstaged
---   both      the index has the same change         -> staged
---   remote /  the index holds another version than  -> mixed (e.g. partly staged)
---   conflict  the working tree
--- Vim's own colours are muted (with three windows every window is compared with every
--- other); a change keeps its colour in every column, so (un)staging it visibly moves it.
local diff3 = require("diffmerge.diff3")
local hunks = require("diffmerge.hunks")
local inline = require("diffmerge.inline")
local merge = require("diffmerge.merge")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("diffmerge_stage")
M.ns = ns

local MUTE = "DiffAdd:DiffMergeNone,DiffChange:DiffMergeNone,DiffText:DiffMergeNone,DiffTextAdd:DiffMergeNone"

local CLASS = { ["local"] = "unstaged", both = "staged", remote = "mixed", conflict = "mixed" }
local STYLE = {
  unstaged = { hl = "DiffMergeUnstaged", sign = "U", sign_hl = "DiffMergeUnstagedSign" },
  staged = { hl = "DiffMergeStaged", sign = "S", sign_hl = "DiffMergeStagedSign" },
  mixed = { hl = "DiffMergeMixed", sign = "±", sign_hl = "DiffMergeMixedSign" },
}
-- column -> side of the 3-way chunk
local COLUMN = { head = "base", worktree = "local", index = "remote" }
-- where a change gets its sign: in the column(s) it lives in
local SIGNS = {
  unstaged = { worktree = true },
  staged = { index = true },
  mixed = { worktree = true, index = true },
}
local ROLES = { "head", "worktree", "index" }

-- character level differences, by state
local TEXT = { unstaged = "DiffMergeUnstagedText", staged = "DiffMergeStagedText", mixed = "DiffMergeMixedText" }
-- the version a changed line is compared with: what it will become / what it replaces
local REF = {
  worktree = { unstaged = "index", mixed = "index", staged = "head" },
  index = { unstaged = "worktree", mixed = "worktree", staged = "head" },
  head = { unstaged = "worktree", mixed = "index", staged = "index" },
}

---@class diffmerge.StageController
local Controller = {}
Controller.__index = Controller

function M.attach(view, entry, infos)
  local self = setmetatable({ view = view, entry = entry, infos = infos, chunks = {}, inline = inline.cache() }, Controller)
  self:compute()
  for _, role in ipairs({ "worktree", "index" }) do
    local info = infos[role]
    if info and info.src.kind ~= "empty" then
      api.nvim_buf_attach(info.buf, false, {
        on_lines = function()
          if self.detached then
            return true
          end
          self:schedule()
        end,
      })
    end
  end
  for _, win in pairs(view.layout.wins) do
    if util.win_valid(win) then
      vim.wo[win].winhighlight = MUTE
    end
  end
  -- the working tree buffer may be open in other windows too: colours only here
  util.scope_ns(ns, view, view.layout:diff_wins())
  -- aligned by position, like merges (linematch staggers versions across 3 windows)
  merge.suspend_linematch()
  self.augroup = api.nvim_create_augroup("DiffMergeStage" .. view.layout.tab, { clear = true })
  -- colours follow 'diffopt' (algorithm, inline:, iwhite, icase)
  api.nvim_create_autocmd("OptionSet", {
    group = self.augroup,
    pattern = "diffopt",
    callback = function()
      self:schedule()
    end,
  })
  api.nvim_create_autocmd("TabLeave", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() == view.layout.tab then
        merge.restore_linematch()
      end
    end,
  })
  api.nvim_create_autocmd("TabEnter", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() == view.layout.tab then
        merge.suspend_linematch()
      end
    end,
  })
  self:render()
  return self
end

function Controller:detach()
  self.detached = true
  merge.restore_linematch()
  util.scope_ns(ns, self.view, nil)
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for _, role in ipairs(ROLES) do
    local info = self.infos[role]
    if info and api.nvim_buf_is_valid(info.buf) then
      api.nvim_buf_clear_namespace(info.buf, ns, 0, -1)
    end
  end
end

function Controller:lines(role)
  local info = self.infos[role]
  if not info or info.src.kind == "empty" or not api.nvim_buf_is_valid(info.buf) then
    return {}
  end
  return util.buf_lines(info.buf, info)
end

--- 0-based lines of `to` that differ from `from`.
local function changed_lines(from, to, opts)
  local set = {}
  for _, h in ipairs(hunks.compute(from, to, opts)) do
    for k = 0, h.bc - 1 do
      set[h.bs - 1 + k] = true
    end
  end
  return set
end

--- 0-based lines of `from` that `to` replaces or removes.
local function replaced_lines(from, to, opts)
  local set = {}
  for _, h in ipairs(hunks.compute(from, to, opts)) do
    for k = 0, h.ac - 1 do
      set[h.as - 1 + k] = true
    end
  end
  return set
end

--- Splits a chunk where the working tree and the index both differ from HEAD by comparing
--- the two: lines they share are staged (if they are a change at all), lines only the working
--- tree has - or where the index still has HEAD's text - are unstaged, the rest is mixed.
local function refine(c, wt, index, wt_changed, idx_changed, out, opts)
  local l, r = c["local"], c.remote
  local function push(class, ls, le, rs, re)
    if le > ls or re > rs then
      out[#out + 1] = { class = class, ["local"] = { ls, le }, remote = { rs, re } }
    end
  end
  local function shared(ls, le, rs)
    -- identical in both: staged where it differs from HEAD, nothing otherwise
    local start
    for k = ls, le do
      local changed = k < le and wt_changed[k]
      if changed and not start then
        start = k
      elseif not changed and start then
        push("staged", start, k, rs + (start - ls), rs + (k - ls))
        start = nil
      end
    end
  end
  local function any(set, s, e)
    for k = s, e - 1 do
      if set[k] then
        return true
      end
    end
    return false
  end
  local pos_l, pos_r = l[1], r[1]
  for _, h in ipairs(hunks.compute(diff3.slice(wt, l), diff3.slice(index, r), opts)) do
    local a_first = (h.ac == 0 and h.as + 1 or h.as) - 1 + l[1] -- 0-based in the working tree
    local b_first = (h.bc == 0 and h.bs + 1 or h.bs) - 1 + r[1]
    shared(pos_l, a_first, pos_r)
    local class = "mixed"
    if h.bc == 0 or not any(idx_changed, b_first, b_first + h.bc) then
      class = "unstaged"
    end
    push(class, a_first, a_first + h.ac, b_first, b_first + h.bc)
    pos_l, pos_r = a_first + h.ac, b_first + h.bc
  end
  shared(pos_l, l[2], pos_r)
end

function Controller:compute()
  local head, wt, index = self:lines("head"), self:lines("worktree"), self:lines("index")
  -- the same diff as on screen ('diffopt' algorithm) so colours match Vim's blocks
  local opts = hunks.display_opts(false)
  local wt_changed, idx_changed
  -- segments: working tree / index ranges with a state
  self.segments = {}
  self.chunks = {}
  self.text = { head = head, worktree = wt, index = index }
  for _, c in ipairs(diff3.compute(head, wt, index, opts)) do
    if c.kind ~= "equal" then
      self.chunks[#self.chunks + 1] = c
      local class = CLASS[c.kind]
      if c.kind == "conflict" then
        wt_changed = wt_changed or changed_lines(head, wt, opts)
        idx_changed = idx_changed or changed_lines(head, index, opts)
        refine(c, wt, index, wt_changed, idx_changed, self.segments, opts)
      else
        self.segments[#self.segments + 1] = { class = class, ["local"] = c["local"], remote = c.remote }
      end
    end
  end
  -- HEAD lines, one by one: replaced by the index and the working tree -> staged, only by
  -- the working tree -> unstaged, only by the index -> mixed
  local by_wt, by_idx = replaced_lines(head, wt, opts), replaced_lines(head, index, opts)
  self.heads = {}
  local run
  for k = 0, #head do
    local class
    if k < #head then
      if by_idx[k] and by_wt[k] then
        class = "staged"
      elseif by_wt[k] then
        class = "unstaged"
      elseif by_idx[k] then
        class = "mixed"
      end
    end
    if run and run.class ~= class then
      run.base[2] = k
      self.heads[#self.heads + 1] = run
      run = nil
    end
    if class and not run then
      run = { class = class, base = { k, k } }
    end
  end
end

--- Ranges of a column with their state.
function Controller:ranges(role)
  local out = {}
  if role == "head" then
    for _, h in ipairs(self.heads) do
      out[#out + 1] = { class = h.class, range = h.base }
    end
  else
    local side = COLUMN[role]
    for _, seg in ipairs(self.segments) do
      out[#out + 1] = { class = seg.class, range = seg[side] }
    end
  end
  return out
end

--- Recomputes now (after staging, before the cursor moves on).
function Controller:update()
  self:compute()
  self:render()
  self.view:update_winbars()
end

function Controller:schedule()
  if self.pending then
    return
  end
  self.pending = true
  vim.schedule(function()
    self.pending = false
    if self.detached then
      return
    end
    self:compute()
    self:render()
    self.view:update_winbars()
  end)
end

function Controller:render()
  for _, role in ipairs(ROLES) do
    local info = self.infos[role]
    if info and api.nvim_buf_is_valid(info.buf) then
      api.nvim_buf_clear_namespace(info.buf, ns, 0, -1)
      if info.src.kind ~= "empty" then
        local count = api.nvim_buf_line_count(info.buf)
        for _, item in ipairs(self:ranges(role)) do
          local r, style = item.range, STYLE[item.class]
          if r[2] == r[1] and SIGNS[item.class][role] then
            -- removed lines (filler on this side): mark the line after them
            pcall(api.nvim_buf_set_extmark, info.buf, ns, math.min(r[1], count - 1), 0, {
              sign_text = style.sign,
              sign_hl_group = style.sign_hl,
              priority = 60,
            })
          end
          if r[2] > r[1] then
            -- range highlights: diff mode ignores line_hl_group on changed lines
            pcall(api.nvim_buf_set_extmark, info.buf, ns, r[1], 0, {
              end_row = r[2],
              end_col = 0,
              hl_group = style.hl,
              hl_eol = true,
              priority = 60,
            })
            if SIGNS[item.class][role] then
              pcall(api.nvim_buf_set_extmark, info.buf, ns, r[1], 0, {
                sign_text = style.sign,
                sign_hl_group = style.sign_hl,
                priority = 60,
              })
            end
          end
        end
      end
    end
  end
  self:render_inline()
end

--- Character level differences: each changed line against the version it is compared with
--- (REF), lines paired the way they are shown.
function Controller:render_inline()
  local classes = {}
  for _, role in ipairs(ROLES) do
    classes[role] = {}
    for _, item in ipairs(self:ranges(role)) do
      for l = item.range[1], item.range[2] - 1 do
        classes[role][l] = item.class
      end
    end
  end
  for _, c in ipairs(self.chunks) do
    for _, role in ipairs(ROLES) do
      local info = self.infos[role]
      local r = c[COLUMN[role]]
      if info and info.src.kind ~= "empty" and r[2] > r[1] and api.nvim_buf_is_valid(info.buf) then
        local mine = diff3.slice(self.text[role], r)
        local by_ref = {}
        for l = r[1], r[2] - 1 do
          local class = classes[role][l]
          local ref = class and REF[role][class]
          if ref then
            if not by_ref[ref] then
              by_ref[ref] = self.inline(mine, diff3.slice(self.text[ref], c[COLUMN[ref]]))
            end
            for _, x in ipairs(by_ref[ref][l - r[1] + 1] or {}) do
              pcall(api.nvim_buf_set_extmark, info.buf, ns, l, x[1], {
                end_col = x[2],
                hl_group = TEXT[class],
                priority = 70,
              })
            end
          end
        end
      end
    end
  end
end

--- Number of changes that are (partly) unstaged / staged.
---@param what "unstaged"|"staged"
function Controller:count(what)
  local n = 0
  for _, seg in ipairs(self.segments) do
    if seg.class == what or seg.class == "mixed" then
      n = n + 1
    end
  end
  return n
end

--- Class of the change at `line` (1-based) of a column, or nil.
function Controller:class_at(role, line)
  for _, item in ipairs(self:ranges(role)) do
    if line - 1 >= item.range[1] and line - 1 < item.range[2] then
      return item.class
    end
  end
end

--- First line at or below `from` in a column that belongs to a change of one of `classes`.
function Controller:next_line(role, from, classes)
  local want = {}
  for _, c in ipairs(classes) do
    want[c] = true
  end
  local best
  for _, item in ipairs(self:ranges(role)) do
    local r = item.range
    if want[item.class] and r[2] > r[1] and r[2] >= from then
      local line = math.max(r[1] + 1, from)
      best = best and math.min(best, line) or line
    end
  end
  return best
end

--- Cursor to the first unstaged change (else the first change) in the working tree column.
function Controller:goto_first()
  local wins = self.view.layout.wins
  local role = wins.worktree and "worktree" or "index"
  local win = wins[role]
  if not util.win_valid(win) then
    return
  end
  local line = self:next_line(role, 1, { "unstaged", "mixed" }) or self:next_line(role, 1, { "staged" }) or 1
  line = math.min(line, api.nvim_buf_line_count(api.nvim_win_get_buf(win)))
  api.nvim_win_set_cursor(win, { line, 0 })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
end

return M
