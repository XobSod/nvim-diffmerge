--- :DiffMerge {subcommand} [args]
local util = require("diffmerge.util")

local M = {}

local function dm()
  return require("diffmerge")
end

local function current_view()
  local view = dm().current()
  if not view then
    util.err("no DiffMerge view in this tab")
  end
  return view
end

--- The files of a `nvim -c "DiffMerge …" -- files…` start (git's tools, a shell alias): the
--- argument list, while Neovim is starting only.
local function startup_args(args)
  if #args == 0 and vim.v.vim_did_enter == 0 then
    return vim.fn.argv(), true
  end
  return args, false
end

--- A typed file argument starting with `%` / `#` (the current / alternate file, with
--- modifiers): that part replaced, as Vim does (`%.orig`, `%:h/b.txt`); `\%`, `\#` for a
--- literal one. Nothing else is expanded: no shell commands, no variables.
local function expand(arg)
  local literal = arg:match("^\\([%%#].*)$")
  if literal then
    return literal
  end
  local special = arg:match("^[%%#]%d*")
  if not special then
    return arg
  end
  local pos = #special + 1
  while arg:match("^:[phtre~.]", pos) do
    pos = pos + 2
  end
  local expanded = vim.fn.expand(arg:sub(1, pos - 1))
  return expanded ~= "" and (expanded .. arg:sub(pos)) or arg
end

M.subcommands = {
  status = function()
    dm().status()
  end,
  conflicts = function()
    dm().status({ conflicts = true })
  end,
  diff = function(args)
    dm().diff(args)
  end,
  log = function(args)
    dm().log({ args = args })
  end,
  history = function(args, cmd)
    local range = cmd.range == 2 and { cmd.line1, cmd.line2 } or nil
    dm().history(args[1], { range = range })
  end,
  difftool = function(args)
    local startup
    args, startup = startup_args(args)
    if #args < 2 then
      util.err("usage: DiffMerge difftool {left} {right} [name]")
      return
    end
    dm().difftool(args[1], args[2], args[3], { startup = startup })
  end,
  compare = function(args)
    local startup
    args, startup = startup_args(args)
    if #args ~= 2 then
      util.err("usage: DiffMerge compare {left} {right}")
      return
    end
    if not startup then
      args = vim.tbl_map(expand, args)
    end
    dm().compare(args[1], args[2], { startup = startup })
  end,
  mergetool = function(args)
    local startup
    args, startup = startup_args(args)
    if #args < 4 then
      util.err("usage: DiffMerge mergetool {local} {base} {remote} {merged}")
      return
    end
    dm().mergetool(args[1], args[2], args[3], args[4], { startup = startup })
  end,
  close = function()
    dm().close()
  end,
  close_all = function()
    local list = vim.tbl_values(require("diffmerge.view").views)
    for _, view in ipairs(list) do
      view:close()
    end
  end,
  refresh = function()
    local view = current_view()
    if view and view.refresh then
      view:refresh()
    end
  end,
  layout = function(args)
    local view = current_view()
    if not view then
      return
    end
    if args[1] then
      view:set_layout(args[1])
    else
      view:action_cycle_layout()
    end
  end,
  files = function()
    local view = current_view()
    if view then
      view:toggle_files()
    end
  end,
  focus_files = function()
    local view = current_view()
    if view then
      view:focus_files()
    end
  end,
  abort = function()
    local view = current_view()
    if view and view.abort then
      view:abort()
    else
      util.err("abort is only available in git mergetool mode")
    end
  end,
}

function M.run(cmd)
  require("diffmerge").ensure_setup()
  local args = vim.deepcopy(cmd.fargs)
  local sub = table.remove(args, 1) or "status"
  local fn = M.subcommands[sub]
  if not fn then
    util.err(("unknown subcommand %q"):format(sub))
    return
  end
  local ok, err = xpcall(fn, debug.traceback, args, cmd)
  if not ok then
    util.err(err)
  end
end

local function refs()
  local repo = require("diffmerge.git").find_repo()
  if not repo then
    return {}
  end
  return require("diffmerge.git").refs(repo)
end

local function filter(list, lead)
  return vim.tbl_filter(function(s)
    return vim.startswith(s, lead)
  end, list)
end

function M.complete(arglead, cmdline, _)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local n = #words
  if arglead == "" then
    n = n + 1
  end
  if n <= 2 then
    local names = vim.tbl_keys(M.subcommands)
    table.sort(names)
    return filter(names, arglead)
  end
  local sub = words[2]
  if sub == "diff" or sub == "log" then
    if vim.tbl_contains(words, "--") and arglead ~= "--" then
      return vim.fn.getcompletion(arglead, "file")
    end
    local opts = sub == "diff" and { "--staged", "--cached", "--merge-base", "--" }
      or { "--all", "--first-parent", "--author=", "--grep=", "--since=", "--" }
    local list = vim.list_extend(opts, refs())
    -- A..B / A...B completion
    local prefix, rest = arglead:match("^(.-%.%.%.?)(.*)$")
    if prefix then
      return vim.tbl_map(function(r)
        return prefix .. r
      end, filter(refs(), rest))
    end
    return filter(list, arglead)
  elseif sub == "history" or sub == "difftool" or sub == "mergetool" or sub == "compare" then
    -- as typed: the arguments are split at unescaped spaces, compare expands a leading % / #
    return vim.tbl_map(function(f)
      f = f:gsub("([\\ ])", "\\%1")
      if sub == "compare" and f:match("^[%%#]") then
        f = "\\" .. f
      end
      return f
    end, vim.fn.getcompletion(arglead, "file"))
  elseif sub == "layout" then
    return filter({ "side_by_side", "stacked", "four_way" }, arglead)
  end
  return {}
end

return M
