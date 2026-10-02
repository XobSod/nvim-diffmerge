local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "DiffMerge" })
end

function M.info(msg)
  M.notify("DiffMerge: " .. msg, vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify("DiffMerge: " .. msg, vim.log.levels.WARN)
end

function M.err(msg)
  M.notify("DiffMerge: " .. msg, vim.log.levels.ERROR)
end

--- Returns a debounced function and a cancel function.
function M.debounce(ms, fn)
  local timer = nil
  local function cancel()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
  end
  local function call(...)
    local args = { n = select("#", ...), ... }
    cancel()
    timer = vim.uv.new_timer()
    timer:start(ms, 0, function()
      vim.schedule(function()
        cancel()
        fn(unpack(args, 1, args.n))
      end)
    end)
  end
  return call, cancel
end

--- Splits file content into buffer lines.
---@return string[] lines, boolean crlf, boolean noeol
function M.split_lines(text)
  if text == nil or text == "" then
    return {}, false, false
  end
  local lines = vim.split(text, "\n", { plain = true })
  local noeol = true
  if lines[#lines] == "" then
    lines[#lines] = nil
    noeol = false
  end
  local crlf = #lines > 0
  for _, l in ipairs(lines) do
    if l:byte(-1) ~= 13 then
      crlf = false
      break
    end
  end
  if crlf then
    for i, l in ipairs(lines) do
      lines[i] = l:sub(1, -2)
    end
  end
  return lines, crlf, noeol
end

--- Joins buffer lines back into file content.
function M.join_lines(lines, crlf, noeol)
  if #lines == 0 then
    return ""
  end
  local sep = crlf and "\r\n" or "\n"
  local text = table.concat(lines, sep)
  if not noeol then
    text = text .. sep
  end
  return text
end

--- Same heuristic as git: a NUL byte in the first 8000 bytes.
function M.is_binary(text)
  return text ~= nil and text:sub(1, 8000):find("\0", 1, true) ~= nil
end

function M.lines_equal(a, b)
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

function M.slice(list, first, last)
  local out = {}
  for i = first, last do
    out[#out + 1] = list[i]
  end
  return out
end

function M.extend(dst, src)
  for _, v in ipairs(src) do
    dst[#dst + 1] = v
  end
  return dst
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.basename(path)
  return vim.fs.basename(path)
end

function M.dirname(path)
  local d = vim.fs.dirname(path)
  if d == "." then
    return ""
  end
  return d
end

--- Lines of a buffer; an empty buffer gives {} (nvim_buf_get_lines returns { "" } for it,
--- which would add a line). Scratch buffers loaded by DiffMerge know it (`info.empty`).
---@param info? { empty?: boolean, scratch?: boolean }
function M.buf_lines(buf, info)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    local empty
    if info and info.scratch then
      empty = info.empty == true
    else
      empty = vim.api.nvim_buf_call(buf, function()
        return vim.fn.line2byte(vim.fn.line("$") + 1) == -1
      end)
    end
    if empty then
      return {}
    end
  end
  return lines
end

--- Changes a buffer from `old` to `new` lines, touching only the lines that differ (cursor,
--- marks and undo stay as local as possible).
function M.replace_lines(buf, old, new)
  if #old == 0 or #new == 0 then
    -- an empty buffer still has one (phantom) line: replace everything
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new)
    return
  end
  local text = function(lines)
    return #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
  end
  local idx = vim.text.diff(text(old), text(new), { result_type = "indices" }) or {}
  for i = #idx, 1, -1 do
    local as, ac, bs, bc = idx[i][1], idx[i][2], idx[i][3], idx[i][4]
    local first = ac == 0 and as or as - 1
    local lines = {}
    for k = bs, bs + bc - 1 do
      lines[#lines + 1] = new[k]
    end
    vim.api.nvim_buf_set_lines(buf, first, first + ac, false, lines)
  end
end

--- Limits a namespace's extmarks to the given windows of an owner (a view): overlays on
--- real file buffers must not show in the user's other windows on the same file.
--- (nvim__ns_set is experimental; without it the marks show everywhere, as before.)
local scoped = {}
function M.scope_ns(ns, owner, wins)
  scoped[ns] = scoped[ns] or {}
  scoped[ns][owner] = wins
  local all = {}
  for _, list in pairs(scoped[ns]) do
    for _, w in ipairs(list or {}) do
      if vim.api.nvim_win_is_valid(w) then
        all[#all + 1] = w
      end
    end
  end
  if vim.api.nvim__ns_set then
    pcall(vim.api.nvim__ns_set, ns, { wins = all })
  end
end

--- Buffer with exactly this name (vim.fn.bufnr() also accepts partial matches).
function M.find_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return nil
end

function M.win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Sets a window option for `win` only (`vim.wo[win]` also sets the global value when `win`
--- is the current window).
function M.set_wo(win, name, value)
  vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
end

--- The global value of a window option (what windows have without DiffMerge).
function M.global_wo(name)
  return vim.api.nvim_get_option_value(name, { scope = "global" })
end

function M.buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- Sets buffer lines on a possibly non-modifiable buffer.
function M.set_lines(buf, lines, first, last)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first or 0, last or -1, false, lines)
  vim.bo[buf].modifiable = modifiable
end

function M.short(sha)
  if not sha then
    return ""
  end
  return sha:sub(1, 7)
end

--- Display width aware right padding.
function M.pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

return M
