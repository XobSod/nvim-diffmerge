--- `git diff` views (any two sides) and the `git difftool` / compare view (files or
--- directories).
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
  if self.cleaned or not self.layout:is_valid() then
    return
  end
  if self.listing then
    return self:refresh_listing()
  end
  if not self.cmp then
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
-- git difftool, compare
---------------------------------------------------------------------------

local function unlist_args()
  for _, arg in ipairs(vim.fn.argv()) do
    local buf = util.find_buf(vim.fs.normalize(vim.fn.fnamemodify(arg, ":p")))
    if buf then
      vim.bo[buf].buflisted = false
    end
  end
end

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

--- Entries of two compared directories; `side(role, abspath, entry)` makes a side's source.
local function dir_entries(left, right, side, renames)
  local list, problems = dircmp.compare(left, right, renames)
  local entries = {}
  for _, d in ipairs(list) do
    entries[#entries + 1] = {
      kind = "diff",
      path = d.path,
      oldpath = d.oldpath,
      status = d.status,
      key = d.path,
      sides = { a = side("a", d.left, d), b = side("b", d.right, d) },
    }
  end
  return entries, problems
end

--- A view of two files (`entry`) or two directories (`listing`: rebuilt on refresh).
---@param o { kind_name: string, entry?: table, listing?: { title: string, subtitle: string, build: fun(renames: table): table[], table }, startup?: boolean }
local function open_files(repo, o)
  local self = views.View.new(DiffView, repo, { files = o.listing ~= nil, kind = "diff" })
  self.kind_name = o.kind_name
  self.listing = o.listing
  local ok, err = pcall(function()
    if o.listing then
      self:refresh()
    else
      self.entries = { o.entry }
      self:show_entry(o.entry, { focus = true })
    end
  end)
  if not ok then
    self:close()
    util.err(err)
    return nil
  end
  if o.startup then
    unlist_args()
    pcall(vim.cmd, "tabonly")
  end
  return self
end

local function problems_text(problems)
  local function list(paths)
    local shown = vim.tbl_map(function(p)
      return vim.fn.fnamemodify(p, ":~:.")
    end, vim.list_slice(paths, 1, 3))
    return table.concat(shown, ", ") .. (#paths > 3 and ", …" or "")
  end
  local parts = {}
  if #problems.unreadable > 0 then
    parts[#parts + 1] = "cannot read " .. list(problems.unreadable)
  end
  if #problems.outside > 0 then
    parts[#parts + 1] = "not followed (links out of the compared directory): " .. list(problems.outside)
  end
  if problems.truncated then
    parts[#parts + 1] = ("more than %d files: compared up to there"):format(problems.truncated)
  end
  if problems.links then
    parts[#parts + 1] = ("more than %d links to directories: the rest not followed"):format(problems.links)
  end
  return table.concat(parts, "; ")
end

function DiffView:refresh_listing()
  local renames = {}
  for _, e in ipairs(self.entries or {}) do
    if e.oldpath then
      renames[e.path] = e.oldpath
    end
  end
  local entries, problems = self.listing.build(renames)
  local text = problems_text(problems)
  if text ~= "" and text ~= self.listing.problems then
    util.warn(text)
  end
  self.listing.problems = text
  self:show_listing(entries)
end

function DiffView:show_listing(entries)
  self.entries = entries
  self:set_sections({
    title = self.listing.title,
    subtitle = self.listing.subtitle,
    sections = { { id = "files", title = "Files", entries = entries } },
    empty_text = "No differences",
  })
end

--- After `buf` was saved: whether its entry still differs (the rest is checked on refresh).
function DiffView:recheck(buf)
  local name = api.nvim_buf_get_name(buf)
  for k, e in ipairs(self.entries or {}) do
    local a, b = e.sides.a, e.sides.b
    if a.kind == "file" and b.kind == "file" then
      local function is(src)
        return src.abspath == name or vim.uv.fs_realpath(src.abspath) == name
      end
      if (is(a) or is(b)) and dircmp.same_file(a.abspath, b.abspath) then
        local entries = vim.list_slice(self.entries)
        table.remove(entries, k)
        self:show_listing(entries)
        return
      end
    end
  end
end

--- Opens the difftool view for two files or two directories (git's temporary copies).
---@param left string
---@param right string
---@param name? string path shown for single files ($MERGED)
---@param opts? { startup?: boolean }
function M.open_difftool(left, right, name, opts)
  opts = opts or {}
  left = vim.fs.normalize(vim.fn.fnamemodify(left, ":p"))
  right = vim.fs.normalize(vim.fn.fnamemodify(right, ":p"))
  local repo = git.find_repo(name and name ~= "" and name or vim.fn.getcwd())
  if is_dir(left) and is_dir(right) then
    return open_files(repo, {
      kind_name = "difftool",
      startup = opts.startup,
      listing = {
        title = "git difftool --dir-diff",
        subtitle = vim.fn.fnamemodify(left, ":~") .. " → " .. vim.fn.fnamemodify(right, ":t"),
        build = function(renames)
          return dir_entries(left, right, function(role, abs, d)
            if role == "a" then
              return abs and source.file(abs, { readonly = true, label = "a/ (old)", path = d.oldpath or d.path })
                or source.empty("(new file)", "a")
            end
            -- without --no-symlinks git links the working tree files: edit those
            return abs and source.file(abs, { label = "b/ (new)", path = d.path, follow = true })
              or source.empty("(deleted)", "b")
          end, renames)
        end,
      },
    })
  end
  local display = name and name ~= "" and name or vim.fn.fnamemodify(right, ":t")
  return open_files(repo, {
    kind_name = "difftool",
    startup = opts.startup,
    entry = {
      kind = "diff",
      path = display,
      status = "M",
      key = display,
      sides = {
        a = source.file(left, { readonly = true, label = "LOCAL (old)", path = display }),
        b = source.file(right, { label = "REMOTE (new)", path = display }),
      },
    },
  })
end

--- Opens two files or two directories of the user's side by side, both editable.
---@param opts? { startup?: boolean }
function M.open_compare(left, right, opts)
  opts = opts or {}
  local function shown(path)
    return vim.fn.fnamemodify(path, ":~:.")
  end
  left = vim.fs.normalize(vim.fn.fnamemodify(left, ":p"))
  right = vim.fs.normalize(vim.fn.fnamemodify(right, ":p"))
  for _, p in ipairs({ left, right }) do
    if not vim.uv.fs_stat(p) then
      util.err("no such file or directory: " .. shown(p))
      return nil
    elseif not vim.uv.fs_access(p, "R") then
      util.err("cannot read " .. shown(p))
      return nil
    end
  end
  if is_dir(left) ~= is_dir(right) then
    util.err("compare two files or two directories")
    return nil
  end
  local real = vim.uv.fs_realpath(left)
  if real and real == vim.uv.fs_realpath(right) then
    util.err("the same " .. (is_dir(left) and "directory" or "file") .. " twice: " .. shown(left))
    return nil
  end
  local function side(role, abs)
    return abs and source.file(abs, { label = role == "a" and "LEFT" or "RIGHT", follow = true })
      or source.empty("(missing)", role)
  end
  local repo = git.find_repo(right)
  if is_dir(left) then
    local self = open_files(repo, {
      kind_name = "compare",
      startup = opts.startup,
      listing = {
        title = "compare",
        subtitle = shown(left) .. " ↔ " .. shown(right),
        build = function(renames)
          return dir_entries(left, right, side, renames)
        end,
      },
    })
    if self then
      -- a saved file may no longer differ
      api.nvim_create_autocmd("BufWritePost", {
        group = self.augroup,
        callback = function(ev)
          if not self.cleaned then
            self:recheck(ev.buf)
          end
        end,
      })
    end
    return self
  end
  return open_files(repo, {
    kind_name = "compare",
    startup = opts.startup,
    entry = {
      kind = "diff",
      path = shown(right),
      status = "M",
      key = right,
      sides = { a = side("a", left), b = side("b", right) },
    },
  })
end

M.unlist_args = unlist_args

return M
