local M = {}

local api = vim.api

local function hl_attr(name, attr)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  if not ok then
    return nil
  end
  return hl[attr]
end

local function background()
  return hl_attr("Normal", "bg") or (vim.o.background == "light" and 0xffffff or 0x1a1a1a)
end

local function foreground()
  return hl_attr("Normal", "fg") or (vim.o.background == "light" and 0x000000 or 0xd0d0d0)
end

--- Mixes `color` into `base` with the given alpha (0..1).
function M.blend(color, base, alpha)
  local function ch(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(color, shift) * alpha + ch(base, shift) * (1 - alpha) + 0.5)
    out = out + v * 2 ^ shift
  end
  return out
end

local palette = {
  red = 0xe05561,
  green = 0x8cc265,
  yellow = 0xd8a657,
  blue = 0x61afef,
  violet = 0xc678dd,
}

local function defaults()
  local bg = background()
  local light = vim.o.background == "light"
  local a = light and 0.18 or 0.28
  local set = {
    DiffMergeAdd = { link = "DiffAdd" },
    DiffMergeChange = { link = "DiffChange" },
    DiffMergeText = { link = "DiffText" },
    DiffMergeDelete = { link = "DiffDelete" },
    DiffMergeConflict = { bg = M.blend(palette.red, bg, a + 0.05) },
    DiffMergeResolved = { bg = M.blend(palette.green, bg, a - 0.06) },
    DiffMergeEdited = { bg = M.blend(palette.violet, bg, a - 0.06) },
    DiffMergeNone = {},
    -- status view columns: HEAD | WORKING TREE | INDEX
    DiffMergeUnstaged = { bg = M.blend(palette.yellow, bg, a - 0.08) },
    DiffMergeStaged = { bg = M.blend(palette.green, bg, a - 0.06) },
    DiffMergeMixed = { bg = M.blend(palette.violet, bg, a - 0.04) },
    DiffMergeUnstagedSign = { fg = palette.yellow, bold = true },
    DiffMergeStagedSign = { fg = palette.green, bold = true },
    DiffMergeMixedSign = { fg = palette.violet, bold = true },
    DiffMergeConflictSign = { fg = palette.red, bold = true },
    DiffMergeResolvedSign = { fg = palette.green, bold = true },
    DiffMergeEditedSign = { fg = palette.violet, bold = true },
    DiffMergeLocalSign = { fg = palette.blue, bold = true },
    DiffMergeRemoteSign = { fg = palette.yellow, bold = true },
    DiffMergeBothSign = { link = "Comment" },
    DiffMergeVirtText = { link = "Comment" },
    DiffMergeTitle = { link = "Title" },
    DiffMergeSection = { link = "Statement" },
    DiffMergeCount = { link = "Comment" },
    DiffMergeDir = { link = "Directory" },
    DiffMergeFile = { link = "Normal" },
    DiffMergeCurrent = { link = "CursorLineNr" },
    DiffMergeCurrentLine = { bg = M.blend(palette.blue, bg, 0.12) },
    DiffMergeStatusAdded = { link = "Added" },
    DiffMergeStatusModified = { link = "Changed" },
    DiffMergeStatusDeleted = { link = "Removed" },
    DiffMergeStatusRenamed = { link = "Special" },
    DiffMergeStatusUnmerged = { link = "DiagnosticError" },
    DiffMergeStatusUntracked = { link = "Added" },
    DiffMergeStatAdd = { link = "Added" },
    DiffMergeStatDel = { link = "Removed" },
    DiffMergeDim = { link = "Comment" },
    DiffMergeHint = { link = "Comment" },
    DiffMergeMarkSign = { fg = palette.yellow, bold = true },
    DiffMergeMarkLine = { bg = M.blend(palette.yellow, bg, 0.16) },
    DiffMergeRangeLine = { bg = M.blend(palette.blue, bg, 0.16) },
    DiffMergePseudo = { link = "Special" },
    DiffMergeWinbarLabel = { link = "Title" },
    DiffMergeWinbarInfo = { link = "Comment" },
    DiffMergeWinbarEdit = { fg = palette.green, bold = true },
    DiffMergeWinbarConflict = { fg = palette.red, bold = true },
  }
  return set
end

local ansi_cache = {}

function M.setup()
  for name, spec in pairs(defaults()) do
    spec.default = true
    api.nvim_set_hl(0, name, spec)
  end
  ansi_cache = {}
  if not M._autocmd then
    M._autocmd = api.nvim_create_autocmd("ColorScheme", {
      group = api.nvim_create_augroup("DiffMergeHighlights", { clear = true }),
      callback = function()
        -- `default = true` would keep stale colours after a colorscheme switch
        for name, spec in pairs(defaults()) do
          api.nvim_set_hl(0, name, spec)
        end
        ansi_cache = {}
      end,
    })
  end
end

---------------------------------------------------------------------------
-- ANSI colours (git graph / log format)
---------------------------------------------------------------------------

local xterm16 = {
  0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
  0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff,
}

local function color_256(n)
  if n < 16 then
    local tc = vim.g["terminal_color_" .. n]
    if type(tc) == "string" and tc:match("^#%x%x%x%x%x%x$") then
      return tonumber(tc:sub(2), 16)
    end
    return xterm16[n + 1]
  elseif n < 232 then
    local levels = { 0, 95, 135, 175, 215, 255 }
    local i = n - 16
    local r = levels[math.floor(i / 36) + 1]
    local g = levels[math.floor(i / 6) % 6 + 1]
    local b = levels[i % 6 + 1]
    return r * 65536 + g * 256 + b
  else
    local v = 8 + 10 * (n - 232)
    return v * 65536 + v * 256 + v
  end
end

--- Highlight group for an ANSI style (see ansi.lua).
---@param style { fg?: integer|string, bold?: boolean, dim?: boolean, italic?: boolean, underline?: boolean }
function M.ansi_group(style)
  local fg = style.fg
  local key = ("%s_%s%s%s%s"):format(
    tostring(fg or "n"),
    style.bold and "b" or "",
    style.dim and "d" or "",
    style.italic and "i" or "",
    style.underline and "u" or ""
  )
  local cached = ansi_cache[key]
  if cached then
    return cached
  end
  local name = "DiffMergeAnsi_" .. key:gsub("#", "x")
  local spec = { bold = style.bold, italic = style.italic, underline = style.underline }
  local rgb
  if type(fg) == "number" then
    rgb = color_256(fg)
    spec.ctermfg = fg
  elseif type(fg) == "string" then
    rgb = tonumber(fg:sub(2), 16)
  end
  if style.dim then
    rgb = M.blend(rgb or foreground(), background(), 0.6)
  end
  spec.fg = rgb
  api.nvim_set_hl(0, name, spec)
  ansi_cache[key] = name
  return name
end

return M
