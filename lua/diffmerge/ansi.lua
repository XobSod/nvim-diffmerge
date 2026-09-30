--- Minimal SGR (colour) escape sequence parser.
local M = {}

local function apply(style, params)
  local list = {}
  for p in (params .. ";"):gmatch("([^;]*);") do
    list[#list + 1] = tonumber(p) or 0
  end
  local i = 1
  while i <= #list do
    local p = list[i]
    if p == 0 then
      style = {}
    elseif p == 1 then
      style.bold = true
    elseif p == 2 then
      style.dim = true
    elseif p == 3 then
      style.italic = true
    elseif p == 4 then
      style.underline = true
    elseif p == 22 then
      style.bold, style.dim = nil, nil
    elseif p == 23 then
      style.italic = nil
    elseif p == 24 then
      style.underline = nil
    elseif p >= 30 and p <= 37 then
      style.fg = p - 30
    elseif p >= 90 and p <= 97 then
      style.fg = p - 90 + 8
    elseif p == 39 then
      style.fg = nil
    elseif p == 38 then
      if list[i + 1] == 5 and list[i + 2] then
        style.fg = list[i + 2]
        i = i + 2
      elseif list[i + 1] == 2 and list[i + 4] then
        style.fg = ("#%02x%02x%02x"):format(list[i + 2], list[i + 3], list[i + 4])
        i = i + 4
      end
    elseif p == 48 then
      -- background colours are ignored; skip their arguments
      if list[i + 1] == 5 then
        i = i + 2
      elseif list[i + 1] == 2 then
        i = i + 4
      end
    end
    i = i + 1
  end
  return style
end

local function copy(style)
  local c = {}
  for k, v in pairs(style) do
    c[k] = v
  end
  return c
end

local function is_plain(style)
  return next(style) == nil
end

--- Strips escape sequences and returns the plain text plus styled spans.
---@param s string
---@return string text, { [1]: integer, [2]: integer, [3]: table }[] spans (0-based byte start, end exclusive, style)
function M.parse(s)
  if not s:find("\27", 1, true) then
    return s, {}
  end
  local out = {}
  local spans = {}
  local style = {}
  local col = 0
  local pos = 1
  local len = #s
  while pos <= len do
    local esc = s:find("\27", pos, true)
    local chunk = s:sub(pos, (esc or len + 1) - 1)
    if #chunk > 0 then
      out[#out + 1] = chunk
      if not is_plain(style) then
        spans[#spans + 1] = { col, col + #chunk, copy(style) }
      end
      col = col + #chunk
    end
    if not esc then
      break
    end
    local params, final, e = s:match("^%[([%d;]*)([%a])()", esc + 1)
    if params then
      if final == "m" then
        style = apply(style, params)
      end
      pos = e
    else
      pos = esc + 1
    end
  end
  return table.concat(out), spans
end

return M
