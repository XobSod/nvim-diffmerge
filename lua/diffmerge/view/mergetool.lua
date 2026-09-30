--- `git mergetool` view: one conflicted file (LOCAL, BASE, REMOTE temp files + MERGED).
---
--- Exit code (configure `trustExitCode = true`): 0 when every conflict is resolved and the
--- merged file is saved, 1 otherwise. On 1 git restores the original file and reports
--- the merge as failed.
local git = require("diffmerge.git")
local merge = require("diffmerge.merge")
local source = require("diffmerge.source")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

---@class diffmerge.MergetoolView: diffmerge.View
local MergetoolView = setmetatable({}, { __index = views.View })
MergetoolView.__index = MergetoolView

local function abs(p)
  return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
end

---@param opts? { startup?: boolean }
function M.open(local_path, base_path, remote_path, merged_path, opts)
  opts = opts or {}
  local merged_abs = abs(merged_path)
  local repo = git.find_repo(merged_abs)
  local labels = repo and git.conflict_labels(repo)
    or { ["local"] = "LOCAL · ours", base = "BASE · common ancestor", remote = "REMOTE · theirs" }
  local rel = repo and git.relpath(repo, merged_abs) or vim.fn.fnamemodify(merged_abs, ":~:.")
  local function side(p, label)
    if not p or p == "" or not vim.uv.fs_stat(abs(p)) then
      return source.empty(label .. " (none)", label)
    end
    return source.file(abs(p), { readonly = true, label = label, path = rel })
  end
  local entry = {
    kind = "merge",
    path = rel,
    status = "U",
    key = rel,
    sides = {
      ["local"] = side(local_path, labels["local"]),
      base = side(base_path, labels.base),
      remote = side(remote_path, labels.remote),
      merged = source.file(merged_abs, { label = "MERGED", path = rel }),
    },
  }
  local self = views.View.new(MergetoolView, repo, { files = false, kind = "merge" })
  self.kind_name = "mergetool"
  self.entries = { entry }
  self:show_entry(entry, { focus = true })
  if opts.startup then
    require("diffmerge.view.diff").unlist_args()
    pcall(vim.cmd, "tabonly")
  end
  api.nvim_create_autocmd("VimLeavePre", {
    group = self.augroup,
    callback = function()
      local code = self:exit_code()
      if code ~= 0 then
        io.stderr:write(("DiffMerge: %s not resolved, reporting failure to git\n"):format(rel))
        vim.cmd("cquit " .. code)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if self.layout:is_valid() then
        self.layout:equalize()
      end
    end,
  })
  return self
end

--- 0 = resolved and saved, 1 = not resolved.
function MergetoolView:exit_code()
  if self.aborted then
    return 1
  end
  local entry = self.entries[1]
  local merged = entry.sides.merged
  local buf = util.find_buf(merged.abspath)
  if buf and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return 1
  end
  local unresolved
  if self.merge then
    unresolved = self.merge:stats().unresolved
  else
    unresolved = merge.count_unresolved(self.repo or { root = "" }, entry)
  end
  local content = util.read_file(merged.abspath) or ""
  local lines = util.split_lines(content)
  if merge.has_markers(lines) then
    return 1
  end
  return unresolved > 0 and 1 or 0
end

function MergetoolView:abort()
  self.aborted = true
  vim.cmd("cquit 1")
end

return M
