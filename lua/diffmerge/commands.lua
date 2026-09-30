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
    local startup = #args == 0
    if startup then
      args = vim.fn.argv()
    end
    if #args < 2 then
      util.err("usage: DiffMerge difftool {left} {right} [name]")
      return
    end
    dm().difftool(args[1], args[2], args[3], { startup = startup })
  end,
  mergetool = function(args)
    local startup = #args == 0
    if startup then
      args = vim.fn.argv()
    end
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
  elseif sub == "history" or sub == "difftool" or sub == "mergetool" then
    return vim.fn.getcompletion(arglead, "file")
  elseif sub == "layout" then
    return filter({ "side_by_side", "stacked", "four_way" }, arglead)
  end
  return {}
end

return M
