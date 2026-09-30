--- `git diff` views (any two sides) and the `git difftool` view (files or directories).
local dircmp = require("diffmerge.dircmp")
local git = require("diffmerge.git")
local revspec = require("diffmerge.revspec")
local source = require("diffmerge.source")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

---@class diffmerge.DiffView: diffmerge.View
local DiffView = setmetatable({}, { __index = views.View })
DiffView.__index = DiffView
M.DiffView = DiffView

---@param repo diffmerge.Repo
---@param args string[] git diff arguments
function M.open(repo, args)
  local cmp, err = revspec.parse(repo, args)
  if not cmp then
    util.err(err or "invalid arguments")
    return
  end
  return M.open_comparison(repo, cmp)
end

---@param cmp diffmerge.Comparison
function M.open_comparison(repo, cmp)
  local self = views.View.new(DiffView, repo, { files = true, kind = "diff" })
  self.kind_name = "diff"
  self.cmp = cmp
  if cmp.left.kind ~= "commit" or cmp.right.kind ~= "commit" then
    self:watch_changes()
  end
  self:refresh()
  if util.win_valid(self.layout.files_win) and self.current then
    api.nvim_set_current_win(self.layout.files_win)
    self.files:set_cursor_to(self.current)
  end
  return self
end

function DiffView:refresh()
  if self.cleaned or not self.layout:is_valid() or not self.cmp then
    return
  end
  local entries, err = revspec.entries(self.repo, self.cmp)
  if not entries then
    util.err(err or "git diff failed")
    entries = {}
  end
  source.reload_index(self.repo)
  local described = revspec.describe(self.cmp)
  self:set_sections({
    title = self.cmp.title,
    subtitle = described ~= self.cmp.title and ("= " .. described) or nil,
    sections = { { id = "files", title = "Files", entries = entries } },
    empty_text = "No differences",
  })
end

--- Comparisons against the index / working tree follow changes.
function DiffView:watch_changes()
  local refresh = util.debounce(150, function()
    if api.nvim_get_current_tabpage() == self.layout.tab then
      self:refresh()
    end
  end)
  api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "TermLeave" }, {
    group = self.augroup,
    callback = function()
      refresh()
    end,
  })
  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = "DiffMergeIndexChanged",
    callback = function()
      refresh()
    end,
  })
end

---------------------------------------------------------------------------
-- git difftool
---------------------------------------------------------------------------

local function unlist_args()
  for _, arg in ipairs(vim.fn.argv()) do
    local buf = util.find_buf(vim.fs.normalize(vim.fn.fnamemodify(arg, ":p")))
    if buf then
      vim.bo[buf].buflisted = false
    end
  end
end

--- Opens the difftool view for two files or two directories.
---@param left string
---@param right string
---@param name? string path shown for single files ($MERGED)
---@param opts? { startup?: boolean }
function M.open_difftool(left, right, name, opts)
  opts = opts or {}
  left = vim.fs.normalize(vim.fn.fnamemodify(left, ":p"))
  right = vim.fs.normalize(vim.fn.fnamemodify(right, ":p"))
  local repo = git.find_repo(name and name ~= "" and name or vim.fn.getcwd())
  local dirs = vim.fn.isdirectory(left) == 1 and vim.fn.isdirectory(right) == 1
  local entries = {}
  if dirs then
    for _, d in ipairs(dircmp.compare(left, right)) do
      entries[#entries + 1] = {
        kind = "diff",
        path = d.path,
        oldpath = d.oldpath,
        status = d.status,
        key = d.path,
        sides = {
          a = d.left and source.file(d.left, { readonly = true, label = "a/ (old)", path = d.oldpath or d.path })
            or source.empty("(new file)", "a"),
          b = d.right and source.file(d.right, { label = "b/ (new)", path = d.path }) or source.empty("(deleted)", "b"),
        },
      }
    end
  else
    local display = name and name ~= "" and name or vim.fn.fnamemodify(right, ":t")
    entries[1] = {
      kind = "diff",
      path = display,
      status = "M",
      key = display,
      sides = {
        a = source.file(left, { readonly = true, label = "LOCAL (old)", path = display }),
        b = source.file(right, { label = "REMOTE (new)", path = display }),
      },
    }
  end
  local self = views.View.new(DiffView, repo, { files = dirs, kind = "diff" })
  self.kind_name = "difftool"
  self.entries = entries
  if dirs then
    self:set_sections({
      title = "git difftool --dir-diff",
      subtitle = vim.fn.fnamemodify(left, ":~") .. " → " .. vim.fn.fnamemodify(right, ":t"),
      sections = { { id = "files", title = "Files", entries = entries } },
      empty_text = "No differences",
    })
  elseif entries[1] then
    self:show_entry(entries[1], { focus = true })
  end
  if opts.startup then
    unlist_args()
    pcall(vim.cmd, "tabonly")
  end
  return self
end

M.unlist_args = unlist_args

return M
