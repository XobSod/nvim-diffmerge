-- Neovim config of the demo recordings (XDG_CONFIG_HOME=demo/env): DiffMerge from this checkout,
-- nothing else, and the keys pressed shown in a corner.
local api = vim.api

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h"))
vim.opt.rtp:prepend(root)

vim.g.mapleader = ","
vim.o.termguicolors = true
vim.o.number = true
vim.o.laststatus = 3
vim.o.showtabline = 0
vim.o.showcmd = false
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.timeoutlen = 600
vim.opt.shortmess:append("I")

require("diffmerge").setup({ file_panel = { width = 26 } })

---------------------------------------------------------------------------
-- The keys pressed, with what they do
---------------------------------------------------------------------------

-- keys worth showing that are not DiffMerge's, or that do more in visual mode
local labels = {
  n = {
    ["]c"] = "Next change",
    ["[c"] = "Previous change",
    ["V"] = "Select lines",
    ["<C-W>h"] = "Window left",
    ["<C-W>l"] = "Window right",
    ["<C-W>j"] = "Window below",
    ["<C-W>k"] = "Window above",
  },
  x = {
    ["<CR>"] = "Show the combined changes",
  },
}

local buf, win
local hide_timer = assert(vim.uv.new_timer())
local idle_timer = assert(vim.uv.new_timer())

local function hide()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  win = nil
end

local function show(keys, what)
  local text = (" %s  %s "):format(keys, what)
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = api.nvim_create_buf(false, true)
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  api.nvim_buf_set_extmark(buf, api.nvim_create_namespace("demo_keys"), 0, 1, {
    end_col = 1 + #keys,
    hl_group = "DemoKey",
  })
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) ~= api.nvim_get_current_tabpage() then
    hide()
  end
  local width = api.nvim_strwidth(text)
  local config = {
    relative = "editor",
    row = vim.o.lines - 5,
    col = vim.o.columns - width - 3,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 250,
  }
  if win and api.nvim_win_is_valid(win) then
    api.nvim_win_set_config(win, config)
  else
    config.noautocmd = true
    win = api.nvim_open_win(buf, false, config)
    vim.wo[win].winhighlight = "Normal:DemoCaption,FloatBorder:DemoBorder"
  end
  hide_timer:stop()
  hide_timer:start(2200, 0, vim.schedule_wrap(hide))
end

local function set_highlights()
  local normal = api.nvim_get_hl(0, { name = "Normal" })
  api.nvim_set_hl(0, "DemoCaption", { fg = "#e0def4", bg = "#3e3a63" })
  api.nvim_set_hl(0, "DemoBorder", { fg = "#3e3a63", bg = normal.bg })
  api.nvim_set_hl(0, "DemoKey", { fg = "#f6c177", bg = "#3e3a63", bold = true })
end
set_highlights()
api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

--- What `keys` (typed in `mode`, in `typed_buf`) do: a label above, else the description of
--- their mapping (DiffMerge's, without the details in parentheses or after a semicolon).
local function describe(keys, mode, typed_buf)
  local label = labels[mode][vim.fn.keytrans(keys)]
  if label then
    return label
  end
  local map = api.nvim_buf_call(typed_buf, function()
    return vim.fn.maparg(vim.fn.keytrans(keys), mode, false, true)
  end)
  if map.desc then
    local what = map.desc:gsub("^DiffMerge: ", ""):gsub("%s*%b()", ""):gsub(";.*$", "")
    return what
  end
end

-- the keys typed since the last pause, and where the last one was typed (a mapping can open
-- another buffer before the pause is over)
local pending, pending_mode, pending_buf = "", "n", 0

--- The keys typed since the last pause: the longest end of them that does something.
local function flush()
  local keys, mode, typed_buf = pending, pending_mode, pending_buf
  pending = ""
  if not api.nvim_buf_is_valid(typed_buf) then
    typed_buf = 0
  end
  local chars = vim.fn.split(keys, [[\zs]])
  for i = 1, #chars do
    local tail = table.concat(chars, "", i)
    local what = describe(tail, mode, typed_buf)
    if what then
      local shown = vim.fn.keytrans(tail)
      local leader = vim.g.mapleader
      if leader and vim.startswith(tail, leader) and #tail > #leader then
        shown = "<leader>" .. vim.fn.keytrans(tail:sub(#leader + 1))
      end
      return show(shown, what)
    end
  end
end

vim.on_key(function(_, typed)
  if not typed or typed == "" then
    return
  end
  local mode = api.nvim_get_mode().mode
  if mode:match("^[icrRtsS\19]") then
    -- text typed, :commands: on screen already
    pending = ""
    return
  end
  pending_mode = mode:match("^[vV\22]") and "x" or "n"
  pending_buf = api.nvim_get_current_buf()
  pending = pending .. typed
  idle_timer:stop()
  idle_timer:start(250, 0, vim.schedule_wrap(flush))
end, api.nvim_create_namespace("demo_on_key"))
