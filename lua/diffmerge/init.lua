--- DiffMerge: diff / merge / history for git, built on Vim's diff mode.
local M = {}

local did_setup = false

---@param opts? diffmerge.Config
function M.setup(opts)
  require("diffmerge.config").setup(opts)
  require("diffmerge.highlights").setup()
  did_setup = true
end

function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

local function repo_for(path)
  local git = require("diffmerge.git")
  local view = require("diffmerge.view").current()
  if not path and view and view.repo then
    return view.repo
  end
  if not path then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" and not name:match("^%w+://") and vim.bo.buftype == "" then
      path = name
    end
  end
  local repo, err = git.find_repo(path)
  if not repo then
    require("diffmerge.util").err("not a git repository" .. (err and (": " .. err) or ""))
  end
  return repo
end

M.repo_for = repo_for

--- Status view (Conflicts / Staged / Unstaged / Untracked), showing the current file (if it
--- has changes) at the cursor's line.
---@param opts? { conflicts?: boolean, path?: string, focus?: { abs: string, line: integer, lines?: string[] } }
function M.status(opts)
  M.ensure_setup()
  opts = opts or {}
  if not opts.focus then
    -- opened from a file: show that file, at the cursor's line
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" and vim.bo.buftype == "" and not name:match("^%w+://") then
      opts.focus = {
        abs = vim.fs.normalize(name),
        line = vim.api.nvim_win_get_cursor(0)[1],
        -- the text the line refers to (showing a conflict rewrites its markers)
        lines = require("diffmerge.util").buf_lines(0),
      }
    end
  end
  local repo = repo_for(opts.path)
  if repo then
    return require("diffmerge.view.status").open(repo, opts)
  end
end

--- Any `git diff` comparison, e.g. diff({ "main...HEAD", "--", "lua/" }).
---@param args string[]
function M.diff(args)
  M.ensure_setup()
  local repo = repo_for()
  if repo then
    return require("diffmerge.view.diff").open(repo, args or {})
  end
end

--- Repository history.
---@param opts? { args?: string[] }
function M.log(opts)
  M.ensure_setup()
  local repo = repo_for()
  if repo then
    return require("diffmerge.view.log").open(repo, vim.tbl_extend("force", { mode = "log" }, opts or {}))
  end
end

--- History of a file or directory (default: current file). `range` = { first, last } for
--- the history of lines (git log -L).
---@param path? string
---@param opts? { range?: integer[] }
function M.history(path, opts)
  M.ensure_setup()
  opts = opts or {}
  if not path or path == "" or path == "%" then
    local name = vim.api.nvim_buf_get_name(0)
    local info = require("diffmerge.source").info(vim.api.nvim_get_current_buf())
    if info and info.src.path and info.repo then
      path = vim.fs.joinpath(info.repo.root, info.src.path)
    elseif name ~= "" and vim.bo.buftype == "" then
      path = name
    else
      path = vim.fn.getcwd()
    end
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local repo = repo_for(path)
  if not repo then
    return
  end
  local rel = require("diffmerge.git").relpath(repo, path)
  return require("diffmerge.view.log").open(repo, { mode = "history", path = rel, range = opts.range })
end

--- `git difftool` entry point (two files or two directories).
function M.difftool(left, right, name, opts)
  M.ensure_setup()
  return require("diffmerge.view.diff").open_difftool(left, right, name, opts)
end

--- `git mergetool` entry point.
function M.mergetool(local_path, base_path, remote_path, merged_path, opts)
  M.ensure_setup()
  return require("diffmerge.view.mergetool").open(local_path, base_path, remote_path, merged_path, opts)
end

--- View of the current tabpage.
function M.current()
  return require("diffmerge.view").current()
end

function M.close()
  local view = M.current()
  if view then
    view:close()
  end
end

return M
