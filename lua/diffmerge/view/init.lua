--- View base class: a tabpage showing a list of entries (files), one at a time, in diff mode.
local config = require("diffmerge.config")
local keymaps = require("diffmerge.keymaps")
local layout_mod = require("diffmerge.layout")
local source = require("diffmerge.source")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

---@class diffmerge.Entry
---@field path string
---@field oldpath? string
---@field status string
---@field kind "diff"|"merge"
---@field sides table<string, diffmerge.Source>
---@field stats? table
---@field section? string
---@field key? string identity across refreshes
---@field note? string

---@class diffmerge.View
---@field repo? diffmerge.Repo
---@field layout diffmerge.Layout
---@field files? diffmerge.FilePanel
---@field current? diffmerge.Entry
---@field infos table<string, diffmerge.BufInfo>
---@field merge? table merge controller
---@field layout_names table<string, string>
local View = {}
View.__index = View
M.View = View

---@type table<integer, diffmerge.View>
M.views = {}

local augroup = api.nvim_create_augroup("DiffMergeViews", { clear = true })

api.nvim_create_autocmd("TabClosed", {
  group = augroup,
  callback = function()
    for tab, view in pairs(M.views) do
      if not api.nvim_tabpage_is_valid(tab) then
        view:cleanup()
      end
    end
  end,
})

--- View of the current tabpage (or nil).
function M.current()
  return M.views[api.nvim_get_current_tabpage()]
end

--- Creates the tabpage and panels.
---@param opts { kind?: "diff"|"merge", files?: boolean, log?: boolean, title?: string }
function View.new(class, repo, opts)
  opts = opts or {}
  local self = setmetatable({
    repo = repo,
    infos = {},
    layout_names = {},
    title = opts.title,
    augroup = api.nvim_create_augroup("DiffMergeView" .. tostring(math.random(1e9)), { clear = true }),
  }, class)
  self.layout = layout_mod.new({ kind = opts.kind or "diff", files = opts.files, log = opts.log })
  M.views[self.layout.tab] = self
  if opts.files then
    self.files = require("diffmerge.panel.files").new(self)
    self:attach_files_panel()
  end
  return self
end

function View:attach_files_panel()
  local win = self.layout.files_win
  if not util.win_valid(win) then
    return
  end
  api.nvim_win_set_buf(win, self.files.buf)
  layout_mod.panel_opts(win, { winbar = "" })
  local buf = self.files.buf
  if not self.files_mapped then
    self.files_mapped = true
    local handler = function(action, ctx)
      (M.current() or self):dispatch(action, ctx)
    end
    keymaps.apply(buf, "view", handler)
    keymaps.apply(buf, "file_panel", handler, function(action)
      return self:supports(action, "file_panel")
    end)
    if config.options.auto_preview then
      local preview = util.debounce(config.options.preview_debounce, function()
        self:preview_under_cursor()
      end)
      api.nvim_create_autocmd("CursorMoved", {
        group = self.augroup,
        buffer = buf,
        callback = function()
          if not self.files.moving then
            preview()
          end
        end,
      })
    end
  end
end

--- Whether an action is available in this view (e.g. staging only in status views).
function View:supports(action, _group)
  return self["action_" .. action] ~= nil
end

function View:dispatch(action, ctx)
  local fn = self["action_" .. action]
  if fn then
    fn(self, ctx)
  else
    util.warn("action not available here: " .. action)
  end
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

--- Entries in display order.
function View:entry_list()
  if self.files then
    return self.files:all_entries()
  end
  return self.entries or {}
end

local function source_fingerprint(entry)
  local parts = {}
  for role, src in pairs(entry.sides) do
    parts[#parts + 1] = role .. "=" .. src.kind .. ":" .. (src.rev or "") .. ":" .. (src.path or src.abspath or "")
  end
  table.sort(parts)
  if entry.columns then
    parts[#parts + 1] = "columns=" .. table.concat(entry.columns, ",")
  end
  return table.concat(parts, "|")
end

M.source_fingerprint = source_fingerprint

--- Updates the file panel with new sections, keeping the current entry when possible.
---@param data { title: string, subtitle?: string, sections: diffmerge.Section[], empty_text?: string }
function View:set_sections(data, opts)
  opts = opts or {}
  self.sections = data.sections
  local previous = self.current
  local match
  if previous then
    for _, s in ipairs(data.sections) do
      for _, e in ipairs(s.entries) do
        if previous.key and e.key == previous.key then
          match = e
        end
      end
    end
    if not match then
      -- same path in another section (e.g. staged completely)
      for _, s in ipairs(data.sections) do
        for _, e in ipairs(s.entries) do
          if not match and e.path == previous.path then
            match = e
          end
        end
      end
    end
  end
  if self.files then
    self.files:set_data(data)
  end
  if match and source_fingerprint(match) == source_fingerprint(previous) then
    -- keep showing the same buffers; only the entry object changes
    self.current = match
    if self.files then
      self.files:render()
    end
    return
  end
  if self.files then
    self.files:render()
  end
  if not match and previous and self.layout:complete() and self.layout:role_of(api.nvim_get_current_win()) then
    -- the file being edited no longer differs (e.g. saved identical to the index):
    -- keep it on screen instead of switching files under the cursor
    return
  end
  local target = match or self:entry_list()[1]
  if target then
    self:show_entry(target, { focus = opts.focus })
  else
    self:show_nothing()
  end
end

--- Shows empty buffers when there is nothing to compare.
function View:show_nothing()
  self:detach_entry()
  self.current = nil
  self.layout:set("diff", self.layout_names.diff or config.options.layout.diff)
  local infos = {}
  for _, role in ipairs(self.layout.roles) do
    infos[role] = source.acquire(nil, source.empty("", role))
  end
  for role, win in pairs(self.layout.wins) do
    M.clean_window(win)
    api.nvim_win_set_buf(win, infos[role].buf)
    self:watch_window(win)
  end
  self:release_infos()
  self.infos = infos
  if self.files then
    self.files:render()
  end
end

--- Is `buf` shown by another view (same real buffer in two tabs)?
function View:shared_buf(buf)
  for _, v in pairs(M.views) do
    if v ~= self then
      for _, info in pairs(v.infos or {}) do
        if info.buf == buf then
          return true
        end
      end
    end
  end
  return false
end

function View:clear_keymaps(buf)
  if not self:shared_buf(buf) then
    keymaps.clear(buf)
  end
end

function View:release_infos(keep)
  for role, info in pairs(self.infos or {}) do
    if not keep or keep[role] ~= info then
      self:clear_keymaps(info.buf)
      source.release(info)
    end
  end
end

function View:detach_entry()
  if self.merge then
    self.merge:detach()
    self.merge = nil
  end
  if self.stagectl then
    self.stagectl:detach()
    self.stagectl = nil
  end
end

local function escape_bar(s)
  return ((s or ""):gsub("%%", "%%%%"))
end

--- Window bar text for a side.
function View:winbar_for(role, info, entry)
  local src = info.src
  local label = src.label or role
  local path = src.path or (src.abspath and vim.fn.fnamemodify(src.abspath, ":~:.")) or ""
  if entry and src.kind ~= "empty" and path == entry.path and src.kind ~= "file" then
    path = entry.path
  end
  -- %<: when too narrow, cut what follows the label, never the label itself
  local parts = { "%#DiffMergeWinbarLabel# ", escape_bar(label), "%<" }
  if src.kind ~= "empty" and path ~= "" then
    parts[#parts + 1] = "%#DiffMergeWinbarInfo# · " .. escape_bar(path)
  end
  if info.editable then
    parts[#parts + 1] = " %#DiffMergeWinbarEdit#%m"
  end
  if self.stagectl and (role == "worktree" or role == "index") then
    local n = self.stagectl:count(role == "worktree" and "unstaged" or "staged")
    if n > 0 then
      local hl = role == "worktree" and "DiffMergeUnstagedSign" or "DiffMergeStagedSign"
      parts[#parts + 1] = ("%%#%s# · %d %s"):format(hl, n, role == "worktree" and "unstaged" or "staged")
    end
  end
  if role == "merged" and self.merge then
    local st = self.merge:stats()
    if st.conflicts > 0 then
      local hl = st.unresolved > 0 and "DiffMergeWinbarConflict" or "DiffMergeWinbarEdit"
      parts[#parts + 1] = ("%%#%s# · %d/%d conflicts resolved"):format(hl, st.conflicts - st.unresolved, st.conflicts)
    end
  end
  parts[#parts + 1] = "%*"
  return table.concat(parts)
end

function View:update_winbars()
  if not self.current then
    return
  end
  for role, win in pairs(self.layout.wins) do
    local info = self.infos[role]
    if util.win_valid(win) and info then
      vim.wo[win].winbar = self:winbar_for(role, info, self.current)
    end
  end
end

--- Shows an entry in the diff windows.
---@param entry diffmerge.Entry
---@param opts? { focus?: boolean, force?: boolean }
function View:show_entry(entry, opts)
  opts = opts or {}
  if not entry or not self.layout:is_valid() then
    return
  end
  if entry == self.current and not opts.force and self.layout:complete() then
    if opts.focus then
      self:focus_main()
    end
    return
  end
  if
    self.current
    and not opts.force
    and self.layout:complete()
    and source_fingerprint(entry) == source_fingerprint(self.current)
  then
    -- the same buffers and columns (e.g. the Staged and Unstaged entry of one file):
    -- keep the windows, cursor and overlay as they are
    self.current = entry
    if self.files then
      self.files:render()
      if api.nvim_get_current_win() ~= self.layout.files_win or opts.sync_cursor then
        self.files:set_cursor_to(entry)
      end
    end
    self:update_winbars()
    if opts.focus then
      self:focus_main()
    end
    return
  end
  local cur_win = api.nvim_get_current_win()
  local focus_panel = self.files and cur_win == self.layout.files_win
  local focus_log = cur_win == self.layout.log_win
  self:detach_entry()

  local kind = entry.kind
  self.layout:set(kind, self.layout_names[kind] or layout_mod.default_name(kind), entry.columns)

  local infos = {}
  for _, role in ipairs(self.layout.roles) do
    local src = entry.sides[role] or source.empty("(none)", role)
    infos[role] = source.acquire(self.repo, src)
  end
  local special = false
  for _, info in pairs(infos) do
    if info.special then
      special = true
    end
  end

  for _, win in pairs(self.layout.wins) do
    M.clean_window(win)
  end
  for role, win in pairs(self.layout.wins) do
    api.nvim_win_set_buf(win, infos[role].buf)
    self:watch_window(win)
  end
  local old = self.infos
  self.infos = infos
  -- release after the new buffers are displayed so shared buffers survive
  for role, info in pairs(old or {}) do
    self:clear_keymaps(info.buf)
    source.release(info)
    old[role] = nil
  end
  self.current = entry

  for _, role in ipairs(self.layout.roles) do
    local win = self.layout.wins[role]
    api.nvim_win_call(win, function()
      if not special then
        vim.cmd("diffthis")
      end
    end)
    vim.wo[win].winhighlight = ""
  end
  if not special then
    api.nvim_win_call(self.layout.wins[self.layout.roles[1]], function()
      vim.cmd("diffupdate")
    end)
  end

  local handler = function(action, ctx)
    (M.current() or self):dispatch(action, ctx)
  end
  for _, info in pairs(infos) do
    keymaps.apply(info.buf, "view", handler)
    if kind == "merge" then
      keymaps.apply(info.buf, "merge", handler)
    else
      keymaps.apply(info.buf, "diff", handler, function(action)
        return self:supports(action, "diff")
      end)
    end
  end

  if kind == "merge" and not special then
    self.merge = require("diffmerge.merge").attach(self, entry, infos)
  elseif kind == "stage" and not special and #self.layout.roles == 3 then
    self.stagectl = require("diffmerge.stage").attach(self, entry, infos)
  end
  self:update_winbars()

  if self.files then
    self.files:reveal(entry)
    self.files:render()
    if not focus_panel then
      self.files:set_cursor_to(entry)
    elseif opts.sync_cursor then
      self.files:set_cursor_to(entry)
    end
  end

  if not special then
    self:goto_first_change()
  end
  if opts.focus then
    self:focus_main()
  elseif focus_panel and util.win_valid(self.layout.files_win) then
    api.nvim_set_current_win(self.layout.files_win)
  elseif focus_log and util.win_valid(self.layout.log_win) then
    api.nvim_set_current_win(self.layout.log_win)
  elseif util.win_valid(cur_win) then
    api.nvim_set_current_win(cur_win)
  else
    self:focus_main()
  end
  self:on_entry_shown(entry)
end

function View:on_entry_shown(_) end

--- Resets what DiffMerge set on a diff window. Vim remembers window-local options per
--- buffer, so leaving them would leak the window bar / diff mode into other windows that
--- later show the same (real) buffer.
function M.clean_window(win)
  if not util.win_valid(win) then
    return
  end
  api.nvim_win_call(win, function()
    if vim.wo.diff then
      vim.cmd("diffoff")
    end
  end)
  vim.wo[win].winbar = api.nvim_get_option_value("winbar", { scope = "global" })
  vim.wo[win].winhighlight = api.nvim_get_option_value("winhighlight", { scope = "global" })
end

function View:watch_window(win)
  self.watched_wins = self.watched_wins or {}
  if self.watched_wins[win] then
    return
  end
  self.watched_wins[win] = true
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(win),
    once = true,
    callback = function()
      self.watched_wins[win] = nil
      pcall(M.clean_window, win)
    end,
  })
end

--- Window where the user usually works: the merged / right side.
function View:main_win()
  local wins = self.layout.wins
  return wins.merged or wins.worktree or wins.b or wins.index or wins[self.layout.roles[1]]
end

function View:focus_main()
  local win = self:main_win()
  if util.win_valid(win) then
    api.nvim_set_current_win(win)
  end
end

function View:goto_first_change()
  if self.merge then
    self.merge:goto_first()
    return
  end
  if self.stagectl then
    self.stagectl:goto_first()
    return
  end
  local win = self:main_win()
  if not util.win_valid(win) then
    return
  end
  api.nvim_win_call(win, function()
    vim.cmd("normal! gg")
    if vim.fn.diff_hlID(1, 1) == 0 and vim.fn.diff_filler(1) == 0 then
      pcall(vim.cmd, "normal! ]c")
    end
  end)
end

--- Shows the entry under the cursor of the file panel.
function View:preview_under_cursor()
  if not self.files or not util.win_valid(self.layout.files_win) then
    return
  end
  if api.nvim_get_current_win() ~= self.layout.files_win then
    return
  end
  local line = api.nvim_win_get_cursor(self.layout.files_win)[1]
  local item = self.files:item_at(line)
  if item and item.kind == "file" and item.entry ~= self.current then
    self:show_entry(item.entry)
  end
end

---------------------------------------------------------------------------
-- Common actions
---------------------------------------------------------------------------

function View:step_file(delta)
  local list = self:entry_list()
  if #list == 0 then
    return
  end
  local idx = 0
  for i, e in ipairs(list) do
    if e == self.current then
      idx = i
    end
  end
  local next_idx = ((idx - 1 + delta) % #list) + 1
  if idx == 0 then
    next_idx = delta > 0 and 1 or #list
  end
  local in_diff = self.layout:role_of(api.nvim_get_current_win()) ~= nil
  self:show_entry(list[next_idx], { focus = in_diff, sync_cursor = true })
end

function View:action_next_file()
  self:step_file(1)
end

function View:action_prev_file()
  self:step_file(-1)
end

function View:action_cycle_layout()
  local kind = self.layout.kind
  local name = self.layout:next_name()
  self.layout_names[kind] = name
  local role = self.layout:role_of(api.nvim_get_current_win())
  local cursor = api.nvim_win_get_cursor(0)
  if self.current then
    self:show_entry(self.current, { force = true })
  else
    self.layout:set(kind, name)
  end
  if role and util.win_valid(self.layout.wins[role]) then
    api.nvim_set_current_win(self.layout.wins[role])
    pcall(api.nvim_win_set_cursor, 0, cursor)
  end
  util.info("layout: " .. name:gsub("_", " "))
end

function View:set_layout(name)
  local kind = self.layout.kind
  local valid = {}
  for _, n in ipairs(config.layouts(kind)) do
    valid[n] = true
  end
  if not valid[name] then
    util.err(("unknown %s layout %q"):format(kind, name))
    return
  end
  self.layout_names[kind] = name
  if self.current then
    self:show_entry(self.current, { force = true })
  end
end

--- Ignores whitespace changes in the native diff (global 'diffopt', like :set diffopt+=iwhite).
function View:action_toggle_whitespace()
  local ignoring = vim.tbl_contains(vim.opt.diffopt:get(), "iwhite")
  if ignoring then
    vim.opt.diffopt:remove("iwhite")
  else
    vim.opt.diffopt:append("iwhite")
  end
  util.info(ignoring and "showing whitespace changes" or "ignoring whitespace changes (diffopt+=iwhite)")
end

function View:action_help(ctx)
  keymaps.help(ctx.buf)
end

function View:action_close()
  self:close()
end

function View:action_refresh()
  if self.refresh then
    self:refresh()
  end
end

function View:toggle_files()
  if not self.files then
    return
  end
  self.layout:toggle_files()
  self:attach_files_panel()
  if self.current then
    self:show_entry(self.current, { force = true })
  end
end

function View:focus_files()
  if not self.files then
    return
  end
  if not util.win_valid(self.layout.files_win) then
    self:toggle_files()
  end
  api.nvim_set_current_win(self.layout.files_win)
  if self.current then
    self.files:set_cursor_to(self.current)
  end
end

--- Panel actions shared by all views with a file panel.
function View:panel_item(ctx)
  if not self.files or ctx.buf ~= self.files.buf then
    return nil
  end
  local line = ctx.range and ctx.range[1] or api.nvim_win_get_cursor(0)[1]
  return self.files:item_at(line)
end

function View:action_select(ctx)
  local item = self:panel_item(ctx)
  if not item then
    return
  end
  if item.kind == "file" then
    self:show_entry(item.entry, { focus = true })
  elseif item.kind == "dir" or item.kind == "section" then
    self.files:toggle_collapse(item)
  end
end

function View:action_expand(ctx)
  local item = self:panel_item(ctx)
  if not item then
    return
  end
  if item.kind == "file" then
    self:show_entry(item.entry, { focus = true })
  elseif (item.kind == "dir" and self.files.collapsed[item.key]) or (item.kind == "section" and self.files.collapsed[item.section.id]) then
    self.files:toggle_collapse(item)
  end
end

function View:action_collapse(ctx)
  local item = self:panel_item(ctx)
  if not item then
    return
  end
  if item.kind == "dir" and not self.files.collapsed[item.key] then
    self.files:toggle_collapse(item)
    return
  end
  if item.kind == "section" and not self.files.collapsed[item.section.id] then
    self.files:toggle_collapse(item)
    return
  end
  -- go to the parent directory / section line
  local line = api.nvim_win_get_cursor(0)[1]
  local path = item.kind == "file" and item.entry.path or (item.node and item.node.path) or ""
  for l = line - 1, 1, -1 do
    local it = self.files:item_at(l)
    if it and it.kind == "section" then
      api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
    if it and it.kind == "dir" and it.section == item.section and vim.startswith(path, it.node.path .. "/") then
      api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
  end
end

function View:action_toggle_tree()
  if not self.files then
    return
  end
  self.files.tree = not self.files.tree
  self.files:render()
  if self.current then
    self.files:set_cursor_to(self.current)
  end
end

-- merge actions are forwarded to the merge controller
local merge_actions = {
  toggle_local = function(m, ctx)
    m:toggle(1, ctx)
  end,
  toggle_base = function(m, ctx)
    m:toggle(2, ctx)
  end,
  toggle_remote = function(m, ctx)
    m:toggle(3, ctx)
  end,
  take_none = function(m, ctx)
    m:take_none(ctx)
  end,
  put_side = function(m, ctx)
    m:put_side(ctx)
  end,
  next_conflict = function(m, ctx)
    m:jump(ctx, 1, true)
  end,
  prev_conflict = function(m, ctx)
    m:jump(ctx, -1, true)
  end,
  next_chunk = function(m, ctx)
    m:jump(ctx, 1, false)
  end,
  prev_chunk = function(m, ctx)
    m:jump(ctx, -1, false)
  end,
}

for name, fn in pairs(merge_actions) do
  View["action_" .. name] = function(self, ctx)
    if not self.merge then
      -- fall back to the native keys in 2-way diffs
      if name == "next_chunk" then
        pcall(vim.cmd, "normal! " .. vim.v.count1 .. "]c")
      elseif name == "prev_chunk" then
        pcall(vim.cmd, "normal! " .. vim.v.count1 .. "[c")
      end
      return
    end
    fn(self.merge, ctx)
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function View:close()
  local tab = self.layout.tab
  if not api.nvim_tabpage_is_valid(tab) then
    self:cleanup()
    return
  end
  self:detach_entry()
  for _, win in ipairs(self.layout:diff_wins()) do
    M.clean_window(win)
  end
  if #api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end
  local ok, err = pcall(function()
    local nr = api.nvim_tabpage_get_number(tab)
    vim.cmd(nr .. "tabclose!")
  end)
  if not ok then
    util.err(err)
  end
  self:cleanup()
end

function View:cleanup()
  if self.cleaned then
    return
  end
  self.cleaned = true
  M.views[self.layout.tab] = nil
  self:detach_entry()
  if self.on_cleanup then
    self:on_cleanup()
  end
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, win in ipairs(self.layout:is_valid() and self.layout:diff_wins() or {}) do
    pcall(M.clean_window, win)
  end
  self:release_infos()
  self.infos = {}
  if self.files and api.nvim_buf_is_valid(self.files.buf) then
    pcall(api.nvim_buf_delete, self.files.buf, { force = true })
  end
end

return M
