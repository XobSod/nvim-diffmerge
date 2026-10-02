--- git's conflict markers in a merged file (merge, diff3 and zdiff3 styles).
local M = {}

--- Kind and size of a marker line ("<<<<<<< ours" -> "open", 7); any size from 7 up
--- (gitattributes conflict-marker-size), the same within one block.
local function marker(line)
  local ch = line:sub(1, 1)
  local kind = ({ ["<"] = "open", ["|"] = "base", ["="] = "sep", [">"] = "close" })[ch]
  if not kind then
    return nil
  end
  local run = line:match("^" .. vim.pesc(ch) .. "+")
  local n = #run
  if n < 7 then
    return nil
  end
  if kind == "sep" then
    return #line == n and kind or nil, n
  end
  if #line == n or line:sub(n + 1, n + 1) == " " then
    return kind, n
  end
end

--- Splits a file into text and conflict blocks (`lines`: the block with its markers); an
--- unterminated block stays text.
---@return { text?: string[], ours?: string[], base?: string[], theirs?: string[], lines?: string[] }[]
function M.parse(lines)
  local out, text = {}, {}
  local function flush()
    if #text > 0 then
      out[#out + 1] = { text = text }
      text = {}
    end
  end
  local i = 1
  while i <= #lines do
    local block, stop
    local first, size = marker(lines[i])
    if first == "open" then
      local ours, base, theirs, part = {}, nil, {}, "ours"
      for j = i + 1, #lines do
        local m, n = marker(lines[j])
        if n ~= size then
          m = nil
        end
        if m == "base" and part == "ours" then
          base, part = {}, "base"
        elseif m == "sep" and part ~= "theirs" then
          part = "theirs"
        elseif m == "close" and part == "theirs" then
          block, stop = { ours = ours, base = base, theirs = theirs, lines = vim.list_slice(lines, i, j) }, j
          break
        elseif m == "open" then
          break
        else
          local into = part == "ours" and ours or (part == "base" and base or theirs)
          into[#into + 1] = lines[j]
        end
      end
    end
    if block then
      flush()
      out[#out + 1] = block
      i = stop + 1
    else
      text[#text + 1] = lines[i]
      i = i + 1
    end
  end
  flush()
  return out
end

--- `lines` are `parts` written out with conflict markers (any size; labels are not compared).
function M.matches(lines, parts)
  local i, size = 1, nil
  local function mark(kind)
    local k, n = marker(lines[i] or "")
    if k ~= kind or (size and n ~= size) then
      return false
    end
    size, i = n, i + 1
    return true
  end
  local function text(t)
    for _, l in ipairs(t) do
      if lines[i] ~= l then
        return false
      end
      i = i + 1
    end
    return true
  end
  for _, p in ipairs(parts) do
    local ok
    if p.text then
      ok = text(p.text)
    else
      size = nil
      ok = mark("open")
        and text(p.ours)
        and (p.base == nil or (mark("base") and text(p.base)))
        and mark("sep")
        and text(p.theirs)
        and mark("close")
    end
    if not ok then
      return false
    end
  end
  return i == #lines + 1
end

--- The file has at least one complete conflict block.
function M.has(lines)
  for _, part in ipairs(M.parse(lines)) do
    if part.ours then
      return true
    end
  end
  return false
end

return M
