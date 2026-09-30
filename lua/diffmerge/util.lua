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
