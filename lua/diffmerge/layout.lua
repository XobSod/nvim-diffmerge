--- Window arrangement of a view: optional file panel (left), optional log panel (bottom,
--- full width) and the diff windows in the remaining area.
local config = require("diffmerge.config")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

---@class diffmerge.Layout
---@field tab integer
---@field kind "diff"|"merge"
---@field name string layout name
---@field roles string[] role per diff window
---@field wins table<string, integer> role -> window
---@field files_win? integer
---@field log_win? integer
local Layout = {}
Layout.__index = Layout

-- Role order per layout; the first role is the window everything else is split from.
local arrangements = {
  diff = {
    side_by_side = { roles = { "a", "b" } },
    stacked = { roles = { "a", "b" } },
  },
  merge = {
    side_by_side = { roles = { "local", "merged", "remote" } },
    stacked = { roles = { "local", "merged", "remote" } },
    four_way = { roles = { "local", "base", "remote", "merged" } },
  },
}

M.arrangements = arrangements

-- "stage" (status view: HEAD | WORKING TREE | INDEX) shows a varying subset of columns,
-- arranged like the 2-way diff layouts
local STAGE_NAMES = { side_by_side = true, stacked = true }

--- Layout name for a kind (the stage view follows the diff setting).
function M.default_name(kind)
  return config.options.layout[kind] or config.options.layout.diff
end

local function scratch_placeholder()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

local panel_win_opts = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
  wrap = false,
  cursorline = true,
  winfixbuf = false,
  statuscolumn = "",
  colorcolumn = "",
}

function M.panel_opts(win, extra)
  for k, v in pairs(panel_win_opts) do
    vim.wo[win][k] = v
  end
  for k, v in pairs(extra or {}) do
    vim.wo[win][k] = v
  end
end

--- Creates a new tabpage with the requested panels.
---@param opts { kind: "diff"|"merge", name?: string, files?: boolean, log?: boolean }
---@return diffmerge.Layout
function M.new(opts)
  vim.cmd("tabnew")
  local self = setmetatable({
    tab = api.nvim_get_current_tabpage(),
    kind = opts.kind,
    name = opts.name or M.default_name(opts.kind),
    wins = {},
    roles = {},
  }, Layout)
  local main = api.nvim_get_current_win()
  vim.bo[api.nvim_get_current_buf()].bufhidden = "wipe"
  if opts.log then
    vim.cmd("botright " .. config.options.log_panel.height .. "split")
    self.log_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.log_win, scratch_placeholder())
    vim.wo[self.log_win].winfixheight = true
    api.nvim_set_current_win(main)
  end
  if opts.files then
    self:open_files(main)
  end
  self:build(main)
  return self
end

function Layout:open_files(from)
  api.nvim_set_current_win(from)
  vim.cmd("leftabove " .. config.options.file_panel.width .. "vsplit")
  self.files_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.files_win, scratch_placeholder())
  vim.wo[self.files_win].winfixwidth = true
  api.nvim_set_current_win(from)
end

--- Splits `first` into the diff windows of the current layout.
function Layout:build(first)
  if self.kind == "stage" then
    self.roles = vim.deepcopy(self.stage_roles)
  else
    self.roles = arrangements[self.kind][self.name].roles
  end
  self.wins = {}
  local r = self.roles
  api.nvim_set_current_win(first)
  self.wins[r[1]] = first
  if self.kind == "stage" then
    local cmd = self.name == "stacked" and "rightbelow split" or "rightbelow vsplit"
    for i = 2, #r do
      vim.cmd(cmd)
      self.wins[r[i]] = api.nvim_get_current_win()
    end
  elseif self.kind == "diff" then
    local cmd = self.name == "stacked" and "rightbelow split" or "rightbelow vsplit"
    vim.cmd(cmd)
    self.wins[r[2]] = api.nvim_get_current_win()
  elseif self.name == "four_way" then
    vim.cmd("rightbelow split")
    self.wins.merged = api.nvim_get_current_win()
    api.nvim_set_current_win(first)
    vim.cmd("rightbelow vsplit")
    self.wins.base = api.nvim_get_current_win()
    vim.cmd("rightbelow vsplit")
    self.wins.remote = api.nvim_get_current_win()
  else
    local cmd = self.name == "stacked" and "rightbelow split" or "rightbelow vsplit"
    vim.cmd(cmd)
    self.wins[r[2]] = api.nvim_get_current_win()
    vim.cmd(cmd)
    self.wins[r[3]] = api.nvim_get_current_win()
  end
  self:equalize()
end

function Layout:equalize()
  api.nvim_win_call(self.wins[self.roles[1]], function()
    vim.cmd("wincmd =")
  end)
  if util.win_valid(self.files_win) then
    api.nvim_win_set_width(self.files_win, config.options.file_panel.width)
  end
  if util.win_valid(self.log_win) then
    api.nvim_win_set_height(self.log_win, config.options.log_panel.height)
  end
end

function Layout:diff_wins()
  local list = {}
  for _, role in ipairs(self.roles) do
    if util.win_valid(self.wins[role]) then
      list[#list + 1] = self.wins[role]
    end
  end
  return list
end

function Layout:role_of(win)
  for role, w in pairs(self.wins) do
    if w == win then
      return role
    end
  end
end

function Layout:is_valid()
  return api.nvim_tabpage_is_valid(self.tab)
end

--- Closes all diff windows but one (diff mode switched off) and returns it.
function Layout:collapse()
  local keep
  for _, role in ipairs(self.roles) do
    if util.win_valid(self.wins[role]) then
      keep = keep or self.wins[role]
    end
  end
  for _, win in pairs(self.wins) do
    if win ~= keep and util.win_valid(win) then
      api.nvim_win_call(win, function()
        if vim.wo.diff then
          vim.cmd("diffoff")
        end
      end)
      api.nvim_win_close(win, true)
    end
  end
  if not keep then
    -- every diff window was closed by the user: recreate one next to the panels
    local anchor = self.files_win or self.log_win
    api.nvim_set_current_win(anchor)
    vim.cmd(self.files_win and "rightbelow vsplit" or "aboveleft split")
    keep = api.nvim_get_current_win()
    api.nvim_win_set_buf(keep, scratch_placeholder())
  end
  api.nvim_win_call(keep, function()
    if vim.wo.diff then
      vim.cmd("diffoff")
    end
  end)
  self.wins = {}
  return keep
end

--- Changes the arrangement (kind may change too: diff <-> merge). Diff windows are rebuilt;
--- panels stay. Returns false when nothing had to change.
---@param roles? string[] columns of a "stage" layout
function Layout:set(kind, name, roles)
  name = name or M.default_name(kind)
  if kind == "stage" and not STAGE_NAMES[name] then
    name = "side_by_side"
  end
  local same_roles = kind ~= "stage" or vim.deep_equal(roles, self.roles)
  if kind == self.kind and name == self.name and same_roles and self:complete() then
    return false
  end
  local keep = self:collapse()
  self.kind = kind
  self.name = name
  self.stage_roles = roles
  self:build(keep)
  return true
end

--- All diff windows of the arrangement still exist.
function Layout:complete()
  for _, role in ipairs(self.roles) do
    if not util.win_valid(self.wins[role]) then
      return false
    end
  end
  return true
end

function Layout:next_name()
  local names = config.layouts(self.kind)
  for i, n in ipairs(names) do
    if n == self.name then
      return names[i % #names + 1]
    end
  end
  return names[1]
end

--- Toggles the file panel; returns true when the diff windows were rebuilt.
function Layout:toggle_files()
  if util.win_valid(self.files_win) then
    api.nvim_win_close(self.files_win, true)
    self.files_win = nil
    self:equalize()
    return false
  end
  local keep = self:collapse()
  self:open_files(keep)
  self:build(keep)
  return true
end

M.Layout = Layout
return M
