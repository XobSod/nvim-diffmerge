-- git's sequence editor for the rebases DiffMerge runs (GIT_SEQUENCE_EDITOR): the todo list
-- with one commit's command changed, DIFFMERGE_TODO="<command> <sha>" (squash, reword, drop),
-- or "move-fixup <fixup sha> <target sha>": that commit's line moved right after the target's,
-- as a fixup.
--   nvim --headless --clean -l rebase-todo.lua <todo file>
local file = arg[1]
local words = vim.split(vim.env.DIFFMERGE_TODO or "", " ", { trimempty = true })
local action, sha, target = words[1], words[2], words[3]
if not action or not sha or (action == "move-fixup" and not target) then
  io.stderr:write("rebase-todo: DIFFMERGE_TODO is not <command> <sha>\n")
  os.exit(1)
end
local lines = vim.fn.readfile(file)

--- The line of the commit `full` (a pick of it), and its parts.
local function find(full)
  for i, line in ipairs(lines) do
    local command, hex, rest = line:match("^(%a+)%s+(%x+)(.*)$")
    if command and (command == "pick" or command == "p") and vim.startswith(full, hex) then
      return i, hex, rest
    end
  end
end

local function missing(full)
  io.stderr:write(("rebase-todo: %s is not in the todo list\n"):format(full:sub(1, 7)))
  os.exit(1)
end

if action == "move-fixup" then
  local i, hex, rest = find(sha)
  if not i then
    missing(sha)
  end
  table.remove(lines, i)
  local t = find(target)
  if not t then
    missing(target)
  end
  table.insert(lines, t + 1, "fixup " .. hex .. rest)
else
  local i, hex, rest = find(sha)
  if not i then
    missing(sha)
  end
  lines[i] = action .. " " .. hex .. rest
end
vim.fn.writefile(lines, file)
