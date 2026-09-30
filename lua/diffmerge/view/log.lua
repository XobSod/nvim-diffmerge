--- Log / history view: commit graph (bottom), files of the selected comparison (left),
--- diff windows.
---
--- What is compared:
---   cursor on a commit C       git diff C^ C        (P cycles the parent of merges)
---   cursor on Working tree     git diff             (index -> working tree)
---   cursor on Index            git diff --staged    (HEAD -> index)
---   m on two rows A, B         git diff A B         (t: git diff A...B)
---   visual rows O..N + <CR>    git diff O^ N        (combined changes of the selection)
local config = require("diffmerge.config")
local git = require("diffmerge.git")
local log_panel = require("diffmerge.panel.log")
local parse = require("diffmerge.git_parse")
local revspec = require("diffmerge.revspec")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

---@class diffmerge.LogView: diffmerge.View
local LogView = setmetatable({}, { __index = views.View })
LogView.__index = LogView
M.LogView = LogView

--- Splits a filter string into arguments (quotes supported).
local function split_args(s)
  local out = {}
  local cur, quote = nil, nil
  for ch in s:gmatch(".") do
    if quote then
      if ch == quote then
        quote = nil
      else
        cur = (cur or "") .. ch
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
      cur = cur or ""
    elseif ch:match("%s") then
      if cur then
        out[#out + 1] = cur
        cur = nil
      end
    else
      cur = (cur or "") .. ch
    end
  end
  if cur then
    out[#out + 1] = cur
  end
  return out
end

M.split_args = split_args

---@param repo diffmerge.Repo
---@param opts { mode: "log"|"history", args?: string[], path?: string, range?: integer[] }
function M.open(repo, opts)
  local self = views.View.new(LogView, repo, { files = true, log = true, kind = "diff" })
  self.kind_name = opts.mode
  self.mode = opts.mode
  self.user_args = {}
  self.paths = {}
  for i, a in ipairs(opts.args or {}) do
    if a == "--" then
      for _, p in ipairs(vim.list_slice(opts.args, i + 1)) do
        self.paths[#self.paths + 1] = git.pathspec(repo, p)
      end
      break
    end
    self.user_args[#self.user_args + 1] = a
  end
  self.path = opts.path
  if opts.path and opts.path ~= "" then
    self.paths = { opts.path }
  end
  self.line_range = opts.range
  local abs = opts.path and git.abspath(repo, opts.path)
  self.is_file = abs ~= nil and vim.fn.isdirectory(abs) == 0
  if opts.mode == "log" then
    self.all_branches = config.options.log.all_branches
  else
    self.all_branches = config.options.log.history_all_branches
  end
  self.first_parent = config.options.log.first_parent
  self.filter = {}
  self.marks = {}
  self.parent_choice = {}
  self.range_mode = ".."
  self.log = log_panel.new(self)
  api.nvim_win_set_buf(self.layout.log_win, self.log.buf)
  require("diffmerge.layout").panel_opts(self.layout.log_win, { signcolumn = "yes:1" })
  self:map_log_panel()
  self:load()
  api.nvim_set_current_win(self.layout.log_win)
  return self
end

function LogView:map_log_panel()
  local keymaps = require("diffmerge.keymaps")
  local handler = function(action, ctx)
    self:dispatch(action, ctx)
  end
  keymaps.apply(self.log.buf, "view", handler)
  keymaps.apply(self.log.buf, "log_panel", handler)
  if config.options.auto_preview then
    local preview = util.debounce(config.options.preview_debounce, function()
      if api.nvim_get_current_win() == self.layout.log_win and #self.marks < 2 and not self.range then
        self:select_line(api.nvim_win_get_cursor(self.layout.log_win)[1])
      end
    end)
    api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = self.log.buf,
      callback = function()
        if self.auto_select and api.nvim_win_get_cursor(0)[1] ~= self.auto_line then
          self.auto_select = false -- the user took over
        end
        preview()
      end,
    })
  end
end

--- git log arguments for the current toggles.
function LogView:log_args()
  local c = config.options.log
  local args = {
    "log",
    "--graph",
    "--color=always",
    "--date=" .. c.date,
    "--format=" .. c.format .. "%x1f%H%x1f%P",
  }
  if self.all_branches then
    args[#args + 1] = "--branches"
    args[#args + 1] = "--remotes"
    args[#args + 1] = "HEAD"
  end
  if self.first_parent then
    args[#args + 1] = "--first-parent"
  end
  if c.max_count then
    args[#args + 1] = "--max-count=" .. c.max_count
  end
  util.extend(args, self.user_args)
  util.extend(args, self.filter)
  if self.line_range and self.path then
    args[#args + 1] = ("-L%d,%d:%s"):format(self.line_range[1], self.line_range[2], self.path)
    args[#args + 1] = "-s"
    return args
  end
  if self.is_file and c.follow_renames then
    args[#args + 1] = "--follow"
  end
  if #self.paths > 0 then
    args[#args + 1] = "--"
    util.extend(args, self.paths)
  end
  return args
end

--- Display form of the log command (without the formatting options).
function LogView:log_title()
  local parts = { "git log" }
  if self.all_branches then
    parts[#parts + 1] = "--branches --remotes"
  end
  if self.first_parent then
    parts[#parts + 1] = "--first-parent"
  end
  for _, a in ipairs(self.user_args) do
    parts[#parts + 1] = a
  end
  for _, a in ipairs(self.filter) do
    parts[#parts + 1] = a
  end
  if self.line_range and self.path then
    parts[#parts + 1] = ("-L %d,%d:%s"):format(self.line_range[1], self.line_range[2], self.path)
  else
    if self.is_file and config.options.log.follow_renames then
      parts[#parts + 1] = "--follow"
    end
    if #self.paths > 0 then
      parts[#parts + 1] = "-- " .. table.concat(self.paths, " ")
    end
  end
  return table.concat(parts, " ")
end

function LogView:pseudo_counts()
  local args = { "status", "--porcelain=v2", "-z", "--untracked-files=all" }
  if #self.paths > 0 then
    args[#args + 1] = "--"
    util.extend(args, self.paths)
  end
  local st = parse.status(git.output(self.repo, args) or "")
  local counts = { unstaged = 0, staged = 0, untracked = 0, conflicts = 0 }
  for _, e in ipairs(st.entries) do
    if e.kind == "untracked" then
      counts.untracked = counts.untracked + 1
    elseif e.kind == "unmerged" then
      counts.conflicts = counts.conflicts + 1
    else
      if e.x ~= "." then
        counts.staged = counts.staged + 1
      end
      if e.y ~= "." then
        counts.unstaged = counts.unstaged + 1
      end
    end
  end
  return counts
end

function LogView:load()
  self.marks = {}
  self.range = nil
  self.head = git.head(self.repo)
  if self.is_file and not self.line_range then
    self:load_paths()
  end
  local pseudo = self.line_range and nil or self:pseudo_counts()
  -- preselect HEAD (or, until it shows up, the first commit) unless the user moved
  self.auto_select = true
  self.log:load(self.repo, self:log_args(), pseudo, function(first, last)
    if not self.auto_select then
      return
    end
    local head_row = self.head and self.log.by_sha[self.head]
    if head_row then
      self.auto_select = false
      self:auto_pick(head_row)
    elseif not self.current then
      for i = first, last do
        if self.log.rows[i].kind == "commit" then
          self:auto_pick(i)
          break
        end
      end
    end
  end, function(ok, err)
    self.auto_select = false
    if not ok and err and err ~= "" then
      util.err("git log: " .. vim.trim(err))
    end
  end)
  self.log:set_winbar(self:log_title())
  self.log:draw_marks({})
end

function LogView:auto_pick(line)
  local win = self.layout.log_win
  if util.win_valid(win) then
    self.auto_line = line
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
  end
  self:select_line(line)
end

--- Path of the file at each commit (single-file history follows renames).
function LogView:load_paths()
  self.path_at = {}
  if not config.options.log.follow_renames then
    return
  end
  local out = git.output(self.repo, { "log", "--follow", "--format=COMMIT:%H", "--name-only", "-M", "--", self.path })
  local sha
  for line in (out or ""):gmatch("[^\n]+") do
    local c = line:match("^COMMIT:(%x+)$")
    if c then
      sha = c
    elseif sha then
      self.path_at[sha] = line
      sha = nil
    end
  end
end

local function commit_side(repo, sha)
  return { kind = "commit", oid = sha, label = util.short(sha) }
end

local function pseudo_side(kind)
  return { kind = kind }
end

--- Side for a log row (commit / index / worktree).
function LogView:row_side(row)
  if row.kind == "commit" then
    return commit_side(self.repo, row.sha)
  elseif row.kind == "worktree" or row.kind == "index" then
    return pseudo_side(row.kind)
  end
end

function LogView:head_side()
  if self.head then
    return { kind = "commit", oid = self.head, label = "HEAD" }
  end
  return { kind = "commit", oid = git.empty_tree(self.repo), label = "(no commits)" }
end

--- Parent side of a commit row (respecting the chosen parent of merges).
function LogView:parent_side(row)
  local n = self.parent_choice[row.sha] or 1
  local parent = row.parents and row.parents[n]
  if not parent then
    -- -L / --follow logs do not always print parents
    parent = git.rev_parse(self.repo, row.sha .. "^" .. n)
  end
  if not parent then
    return { kind = "commit", oid = git.empty_tree(self.repo), label = "(root)" }
  end
  local label = util.short(row.sha) .. "^" .. (n > 1 and n or "")
  return { kind = "commit", oid = parent, label = label }
end

--- Title of a comparison, as a git command.
local function title_of(cmp, suffix)
  local t = revspec.describe(cmp)
  if suffix then
    t = t .. "  " .. suffix
  end
  return t
end

--- Shows what the row under the cursor stands for.
function LogView:select_line(line)
  local row = self.log:row(line)
  if not row or row.kind == "graph" or row.kind == "message" then
    return
  end
  self.selected_line = line
  local cmp
  if row.kind == "commit" then
    cmp = { left = self:parent_side(row), right = commit_side(self.repo, row.sha) }
    local suffix
    if #(row.parents or {}) > 1 then
      suffix = ("(merge: parent %d of %d, P cycles)"):format(self.parent_choice[row.sha] or 1, #row.parents)
    end
    cmp.title = "git show " .. util.short(row.sha) .. (suffix and ("  " .. suffix) or "")
    cmp.described = title_of({ left = cmp.left, right = cmp.right, paths = self.paths })
  elseif row.kind == "worktree" then
    cmp = { left = { kind = "index" }, right = { kind = "worktree" }, title = "git diff" }
  else
    cmp = { left = self:head_side(), right = { kind = "index" }, title = "git diff --staged" }
  end
  self:show_comparison(cmp, row)
end

--- Updates the file panel and diff windows for a comparison.
function LogView:show_comparison(cmp, row)
  cmp.paths = self.paths
  cmp.extra = {}
  if self.is_file then
    -- all files, then pick the tracked file: keeps renames visible
    cmp.paths = {}
  end
  local entries, err = revspec.entries(self.repo, cmp)
  cmp.paths = self.paths
  if not entries then
    util.err(err or "git diff failed")
    entries = {}
  end
  if self.is_file then
    local wanted = self.path
    if row and row.sha and self.path_at and self.path_at[row.sha] then
      wanted = self.path_at[row.sha]
    end
    local picked = {}
    for _, e in ipairs(entries) do
      if e.path == wanted or e.oldpath == wanted or e.path == self.path then
        picked[#picked + 1] = e
      end
    end
    entries = picked
  end
  for _, e in ipairs(entries) do
    -- identity across commits is the path, so stepping through history keeps the file
    e.key = e.path
  end
  self.cmp = cmp
  local subtitle = cmp.described
  if not subtitle then
    subtitle = title_of(cmp)
    if subtitle == cmp.title then
      subtitle = nil
    end
  end
  self:set_sections({
    title = cmp.title,
    subtitle = subtitle and ("= " .. subtitle) or nil,
    sections = { { id = "files", title = "Files", entries = entries } },
    empty_text = self.is_file and "File not changed here" or "No changes",
  })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function in_log(self, ctx)
  return ctx.buf == self.log.buf
end

function LogView:action_select(ctx)
  if not in_log(self, ctx) then
    return views.View.action_select(self, ctx)
  end
  if ctx.range and ctx.range[1] ~= ctx.range[2] then
    self:select_range(ctx.range[1], ctx.range[2])
    return
  end
  local line = ctx.range and ctx.range[1] or api.nvim_win_get_cursor(0)[1]
  if #self.marks < 2 and not self.range then
    self:select_line(line)
  end
  self:focus_main()
end

function LogView:mark_label(i)
  return i == 1 and config.options.icons.mark_from or config.options.icons.mark_to
end

function LogView:redraw_marks()
  local marks = {}
  for i, m in ipairs(self.marks) do
    marks[#marks + 1] = { line = m.line, label = self:mark_label(i) }
  end
  self.log:draw_marks(marks, self.range)
end

function LogView:action_mark(ctx)
  if not in_log(self, ctx) then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local row = self.log:row(line)
  if not row or row.kind == "graph" or row.kind == "message" then
    util.info("not a commit")
    return
  end
  self.range = nil
  for i, m in ipairs(self.marks) do
    if m.line == line then
      table.remove(self.marks, i)
      self:redraw_marks()
      if #self.marks < 2 then
        self:select_line(line)
      end
      return
    end
  end
  if #self.marks >= 2 then
    util.info("two rows are already marked (M clears the marks)")
    return
  end
  self.marks[#self.marks + 1] = { line = line, row = row }
  self:redraw_marks()
  if #self.marks == 2 then
    self:compare_marks()
  else
    util.info("marked " .. (row.sha and util.short(row.sha) or row.kind) .. ": mark a second row to compare")
  end
end

function LogView:action_clear_marks(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.marks = {}
  self.range = nil
  self:redraw_marks()
  self:select_line(api.nvim_win_get_cursor(0)[1])
end

--- Two marked rows: git diff A B (or A...B), older side on the left.
function LogView:compare_marks()
  local a, b = self.marks[1], self.marks[2]
  local order = { worktree = 3, index = 2, commit = 1 }
  -- pseudo rows are always newer than commits; index is older than the working tree
  if order[a.row.kind] > order[b.row.kind] then
    a, b = b, a
  elseif a.row.kind == "commit" and b.row.kind == "commit" then
    if git.is_ancestor(self.repo, b.row.sha, a.row.sha) then
      a, b = b, a
    elseif not git.is_ancestor(self.repo, a.row.sha, b.row.sha) then
      -- diverged: the lower row (older in the log) goes left
      if a.line < b.line then
        a, b = b, a
      end
    end
  end
  local diverged = a.row.kind == "commit"
    and b.row.kind == "commit"
    and not git.is_ancestor(self.repo, a.row.sha, b.row.sha)
  local left, right = self:row_side(a.row), self:row_side(b.row)
  local title
  if self.range_mode == "..." and a.row.kind == "commit" then
    local base = git.merge_base(self.repo, a.row.sha, b.row.kind == "commit" and b.row.sha or "HEAD")
    if not base then
      util.err("no merge base")
      return
    end
    local rname = b.row.kind == "commit" and util.short(b.row.sha) or "HEAD"
    title = ("git diff %s...%s"):format(util.short(a.row.sha), rname)
    left = { kind = "commit", oid = base, label = "merge-base " .. util.short(base) }
  end
  local cmp = { left = left, right = right }
  cmp.title = title or revspec.describe({ left = left, right = right, paths = {} })
  local hint
  if diverged then
    hint = self.range_mode == "..." and "(since the branches split; t: snapshots)"
      or "(diverged: snapshots compared; t: since split)"
  end
  cmp.described = hint
  self:show_comparison(cmp)
end

function LogView:action_toggle_range_mode(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.range_mode = self.range_mode == ".." and "..." or ".."
  if #self.marks == 2 then
    self:compare_marks()
  else
    util.info(("marks will compare %s"):format(self.range_mode == "..." and "A...B (since the branches split)" or "A B (snapshots)"))
  end
end

--- Visual selection of rows: combined changes, git diff O^ N.
function LogView:select_range(first, last)
  local commits, pseudo = {}, {}
  for l = first, last do
    local r = self.log:row(l)
    if r and r.kind == "commit" then
      commits[#commits + 1] = r
    elseif r and (r.kind == "worktree" or r.kind == "index") then
      pseudo[r.kind] = true
    end
  end
  if #commits == 0 then
    if pseudo.worktree and pseudo.index then
      local cmp = { left = self:head_side(), right = { kind = "worktree" }, title = "git diff HEAD" }
      self.marks, self.range = {}, { first, last }
      self:redraw_marks()
      self:show_comparison(cmp)
    end
    return
  end
  local newest, oldest = commits[1], commits[#commits]
  local right
  if pseudo.worktree then
    right = { kind = "worktree" }
  elseif pseudo.index then
    right = { kind = "index" }
  else
    right = commit_side(self.repo, newest.sha)
  end
  local top = (pseudo.worktree or pseudo.index) and "HEAD" or newest.sha
  -- the selection must be exactly the commits of O^..N (git's range), otherwise the
  -- "combined changes" would silently include or skip commits
  local parent = git.rev_parse(self.repo, oldest.sha .. "^")
  local args = { "rev-list", top }
  if parent then
    args[#args + 1] = "^" .. parent
  end
  if self.first_parent then
    table.insert(args, 2, "--first-parent")
  end
  if #self.paths > 0 and not self.line_range then
    args[#args + 1] = "--"
    util.extend(args, self.paths)
  end
  local out = git.output(self.repo, args) or ""
  local expected = {}
  for sha in out:gmatch("%x+") do
    expected[sha] = true
  end
  local selected, extra, missing = {}, 0, 0
  for _, c in ipairs(commits) do
    selected[c.sha] = true
    if not expected[c.sha] then
      extra = extra + 1
    end
  end
  for sha in pairs(expected) do
    if not selected[sha] then
      missing = missing + 1
    end
  end
  if not self.line_range and (extra > 0 or missing > 0) then
    local why = {}
    if missing > 0 then
      why[#why + 1] = ("%d commit(s) in that range are not selected"):format(missing)
    end
    if extra > 0 then
      why[#why + 1] = ("%d selected commit(s) are not in it (other branches)"):format(extra)
    end
    local msg = ("The selection is not one line of history: git diff %s^ %s would compare snapshots where %s.\nShow it anyway?"):format(
      util.short(oldest.sha),
      pseudo.worktree and "(working tree)" or util.short(top),
      table.concat(why, " and ")
    )
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end
  local left = parent and { kind = "commit", oid = parent, label = util.short(oldest.sha) .. "^" }
    or { kind = "commit", oid = git.empty_tree(self.repo), label = "(root)" }
  local cmp = { left = left, right = right }
  cmp.title = revspec.describe({ left = left, right = right, paths = {} })
  cmp.described = ("combined changes of %d commit%s"):format(#commits, #commits == 1 and "" or "s")
  if pseudo.worktree then
    cmp.described = cmp.described .. " + working tree"
  elseif pseudo.index then
    cmp.described = cmp.described .. " + index"
  end
  self.marks = {}
  self.range = { first, last }
  self:redraw_marks()
  self:show_comparison(cmp)
end

function LogView:current_row(ctx)
  if not in_log(self, ctx) then
    return nil
  end
  local line = api.nvim_win_get_cursor(0)[1]
  return self.log:row(line), line
end

function LogView:action_cycle_parent(ctx)
  local row, line = self:current_row(ctx)
  if not row or row.kind ~= "commit" then
    return
  end
  local n = #(row.parents or {})
  if n < 2 then
    util.info("not a merge commit")
    return
  end
  self.parent_choice[row.sha] = ((self.parent_choice[row.sha] or 1) % n) + 1
  self.marks, self.range = {}, nil
  self:redraw_marks()
  self:select_line(line)
end

function LogView:action_commit_details(ctx)
  local row = self:current_row(ctx)
  if not row or row.kind ~= "commit" then
    return
  end
  local out = git.output(self.repo, { "show", "--stat", "--format=fuller", "--no-color", row.sha }) or ""
  local lines = vim.split(out, "\n", { plain = true })
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "git"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = math.max(height, 3),
    row = math.floor((vim.o.lines - height) / 2) - 2,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. util.short(row.sha) .. " ",
  })
  for _, key in ipairs({ "q", "<Esc>", "K" }) do
    vim.keymap.set("n", key, function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end
end

function LogView:action_yank_hash(ctx)
  local row = self:current_row(ctx)
  if not row or row.kind ~= "commit" then
    return
  end
  vim.fn.setreg('"', row.sha)
  pcall(vim.fn.setreg, "+", row.sha)
  util.info("yanked " .. row.sha)
end

function LogView:action_toggle_first_parent(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.first_parent = not self.first_parent
  self:reload()
end

function LogView:action_toggle_all_branches(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.all_branches = not self.all_branches
  self:reload()
end

function LogView:action_filter(ctx)
  if not in_log(self, ctx) then
    return
  end
  vim.ui.input({
    prompt = "git log arguments (e.g. --author=me --grep=fix --since=2.weeks): ",
    default = table.concat(self.filter, " "),
  }, function(input)
    if input == nil then
      return
    end
    self.filter = split_args(input)
    self:reload()
  end)
end

function LogView:reload()
  self.current_before_reload = self.current
  self.selected_line = nil
  self.current = nil
  self:load()
end

function LogView:action_refresh(ctx)
  if ctx and not in_log(self, ctx) and self.cmp then
    self:show_comparison(self.cmp)
    return
  end
  self:reload()
end

function LogView:refresh()
  self:reload()
end

function LogView:on_cleanup()
  if self.log then
    self.log:destroy()
  end
end

return M
