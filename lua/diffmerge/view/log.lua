--- The log of the status view: the commit graph (bottom panel, shown and hidden with gL), and
--- what its rows show in the file panel and diff windows.
---
--- What is shown:
---   cursor on Working tree     the status (Conflicts / Staged / Unstaged / Untracked, stashes)
---   cursor on Index            what a commit takes (Conflicts / Staged)
---   cursor on a commit C       git diff C^ C        (^ cycles the parent of merges), read-only
---   m on two rows A, B         git diff A B         (t: git diff A...B)
---   visual rows O..N + <CR>    git diff O^ N        (combined changes of the selection)
---
--- Rows are known by their commit (pseudo rows by their kind): a reload finds the selected row
--- and the marks again.
local config = require("diffmerge.config")
local git = require("diffmerge.git")
local log_panel = require("diffmerge.panel.log")
local revspec = require("diffmerge.revspec")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

--- Methods of the status view.
local Log = {}
M.methods = Log

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

--- What a row is, found again after a reload: a commit's sha, "worktree" or "index".
local function row_id(row)
  if not row then
    return nil
  end
  if row.kind == "commit" then
    return row.sha
  elseif row.kind == "worktree" or row.kind == "index" then
    return row.kind
  end
end

local function in_log(self, ctx)
  return self.log ~= nil and ctx ~= nil and ctx.buf == self.log.buf
end

--- What the log shows: `git log <args> [-- <paths>]`, the history of a file or directory
--- (`path`), or of lines (`range`). The panel is made when first shown.
---@param opts { args?: string[], path?: string, range?: integer[], history?: boolean }
function Log:init_log(opts)
  self.user_args = {}
  self.paths = {}
  for i, a in ipairs(opts.args or {}) do
    if a == "--" then
      for _, p in ipairs(vim.list_slice(opts.args, i + 1)) do
        self.paths[#self.paths + 1] = git.pathspec(self.repo, p)
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
  local abs = opts.path and git.abspath(self.repo, opts.path)
  self.is_file = abs ~= nil and vim.fn.isdirectory(abs) == 0
  if opts.history then
    self.all_branches = config.options.log.history_all_branches
  else
    self.all_branches = config.options.log.all_branches
  end
  self.first_parent = config.options.log.first_parent
  self.filter = {}
  self.marks = {}
  self.parent_choice = {}
  self.range_mode = ".."
end

function Log:log_shown()
  return util.win_valid(self.layout.log_win)
end

--- Shows the log panel: made and loaded the first time, reloaded when the branches moved while
--- it was hidden; the cursor on the row of what is shown.
function Log:show_log()
  if self:log_shown() then
    return
  end
  self.layout:open_log(require("diffmerge.commit").message_window(self.layout.tab))
  self.layout:equalize()
  local fresh = not self.log
  if fresh then
    self.log = log_panel.new(self)
    self:map_log_panel()
  end
  api.nvim_win_set_buf(self.layout.log_win, self.log.buf)
  require("diffmerge.layout").panel_opts(self.layout.log_win, {
    signcolumn = "yes:1",
    diff = false,
    scrollbind = false,
    cursorbind = false,
    foldenable = false,
    winfixwidth = false,
    winhighlight = "",
  })
  local line = self:line_of_id(self.selected_id)
  if line then
    self:cursor_to(line)
  end
  if fresh or self.log_stale then
    self:load_log()
  else
    self.log:set_winbar(self:log_title())
    self:redraw_marks()
  end
end

--- Hides the log panel; what it selected stays shown.
function Log:hide_log()
  if not self:log_shown() then
    return
  elseif self.layout:log_alone() then
    util.info("the log is the only window here")
    return
  end
  local here = api.nvim_get_current_win() == self.layout.log_win
  self.layout:close_log()
  if here then
    if util.win_valid(self.layout.files_win) then
      api.nvim_set_current_win(self.layout.files_win)
    else
      self:focus_main()
    end
  end
end

--- `gL`: shows (and goes to) / hides the log panel.
function Log:action_toggle_log()
  if self:log_shown() then
    self:hide_log()
  else
    self:show_log()
    if self:log_shown() then
      api.nvim_set_current_win(self.layout.log_win)
    end
  end
end

function Log:map_log_panel()
  local keymaps = require("diffmerge.keymaps")
  local handler = function(action, ctx)
    self:dispatch(action, ctx)
  end
  keymaps.apply(self.log.buf, "view", handler, function(action)
    return self:supports(action, "view")
  end)
  keymaps.apply(self.log.buf, "log_panel", handler)
  local preview = config.options.auto_preview
    and util.debounce(config.options.preview_debounce, function()
      if api.nvim_get_current_win() == self.layout.log_win and #self.marks < 2 and not self.range then
        self:preview_line(api.nvim_win_get_cursor(self.layout.log_win)[1])
      end
    end)
  api.nvim_create_autocmd("CursorMoved", {
    group = self.augroup,
    buffer = self.log.buf,
    callback = function()
      local ours = self.auto_line ~= nil and api.nvim_win_get_cursor(0)[1] == self.auto_line
      self.auto_line = nil
      if ours then
        -- (a load put it there)
        return
      end
      self:user_chose()
      if preview then
        preview()
      end
    end,
  })
end

--- git log arguments for the current toggles.
function Log:log_args()
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
    if self.head then
      -- (no commits yet: git would not know it)
      args[#args + 1] = "HEAD"
    end
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
function Log:log_title()
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

--- Line of a row in the panel (nil: not there, or not loaded yet).
function Log:line_of_id(id)
  if not self.log or not id then
    return nil
  end
  if id == "worktree" or id == "index" then
    for l = 1, 2 do
      local r = self.log.rows[l]
      if r and r.kind == id then
        return l
      end
    end
    return nil
  end
  return self.log.by_sha[id]
end

--- What the log shows of the branches (their tips, HEAD): when it changes, the log reloads.
function Log:refs_now()
  local refs = git.output(self.repo, {
    "for-each-ref",
    "--format=%(objectname) %(refname)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  }) or ""
  return (self.branch_id or "") .. "\n" .. refs
end

--- After a refresh: the pseudo rows count the changes anew; when the branches moved (a commit,
--- fetch, pull, push, switch) the log reloads, or will when shown again.
function Log:log_follow()
  if not self.log then
    return
  end
  if self.counts then
    self.log:set_pseudo(self.counts)
    self:redraw_marks()
  end
  if self:refs_now() == self.log_refs then
    return
  end
  if self:log_shown() then
    self:load_log()
  else
    self.log_stale = true
  end
end

--- (Re)loads the log. The first load streams in: the cursor goes to the selected row when it
--- comes, or (nothing selected) to HEAD, which is then selected (until it comes: the first
--- commit); not once you move the cursor. A reload leaves the log on screen until the new one is
--- complete, then the cursor stays on its row (that gone, e.g. amended: on the selected one;
--- gone too: HEAD, selected). Marks and a selected range are found again by their commits; one
--- of them gone: they go.
function Log:load_log()
  self.log_stale = false
  self.log_refs = self:refs_now()
  if self.is_file and not self.line_range then
    self:load_paths()
  end
  local pseudo = nil
  if not self.line_range then
    pseudo = self.counts or { unstaged = 0, staged = 0, untracked = 0, conflicts = 0 }
  end
  local reload = #self.log.rows > 0 and not self.log.placeholder
  -- (a first load cut short before it came to HEAD; unless you choose something meanwhile)
  local unfinished = self.auto_select and self.selected_id == self.provisional_id
  local choices = self.choices
  local keep
  self.auto_select = not reload
  local function head_line()
    local line = self.head and self.log.by_sha[self.head]
    for i, r in ipairs(self.log.rows) do
      if not line and r.kind == "commit" then
        line = i
      end
    end
    return line
  end
  -- (streaming) the selected row when it is there; nothing selected: HEAD
  local function settle(first, last)
    if not self.auto_select then
      return
    end
    local id = self.selected_id
    if id and id ~= self.provisional_id then
      local line = self:line_of_id(id)
      if line then
        self.auto_select = false
        self:cursor_to(line)
      end
      return
    end
    local head_row = self.head and self.log.by_sha[self.head]
    if head_row then
      self.auto_select = false
      self:auto_pick(head_row)
    elseif first and not self.provisional_id then
      for i = first, last do
        if self.log.rows[i].kind == "commit" then
          self:auto_pick(i)
          self.provisional_id = self.selected_id
          break
        end
      end
    end
  end
  local named = #self.user_args > 0 or #self.filter > 0
  local args = (self.head or self.all_branches or named) and self:log_args() or nil
  self.log:load(self.repo, args, pseudo, function(first, last)
    if reload then
      self.provisional_id = nil
      local head = unfinished and self.choices == choices
      local line = not head and (self:line_of_id(keep) or self:line_of_id(self.selected_id))
      if line then
        self:cursor_to(line)
      elseif #self.marks < 2 and not self.range then
        -- (the first load had not come to HEAD yet; or what was there is gone)
        line = head_line() or self:line_of_id("worktree")
        if line then
          self:auto_pick(line)
        end
      end
    else
      settle(first, last)
    end
    self:redraw_marks()
  end, function(ok, err)
    if self.auto_select and ok then
      -- the selected commit is not in the log
      local line = head_line()
      if line and row_id(self.log:row(line)) ~= self.selected_id then
        self:auto_pick(line)
      end
    end
    -- (a load that came to its end: what it picked stays)
    self.auto_select, self.provisional_id = false, nil
    self:find_marks_again()
    if not ok and err and err ~= "" then
      util.err("git log: " .. vim.trim(err))
    end
  end, function()
    local win = self.layout.log_win
    keep = util.win_valid(win) and row_id(self.log:row(api.nvim_win_get_cursor(win)[1])) or nil
  end)
  if not reload then
    -- the pseudo rows are there already
    settle()
  end
  if self.auto_select then
    -- where the new lines put the cursor: not the user moving it
    local win = self.layout.log_win
    self.auto_line = util.win_valid(win) and api.nvim_win_get_cursor(win)[1] or nil
  end
  self.log:set_winbar(self:log_title())
  self:redraw_marks()
end

--- After a reload: marks and a range whose commits are gone go too (what they compared: the row
--- under the cursor instead).
function Log:find_marks_again()
  local lost = self.range ~= nil and not self:range_lines()
  for _, m in ipairs(self.marks) do
    if not self:line_of_id(m.id) then
      lost = true
    end
  end
  if not lost then
    self:redraw_marks()
    return
  end
  local compared = #self.marks == 2 or self.range ~= nil
  self.marks, self.range = {}, nil
  self:redraw_marks()
  if compared and self:log_shown() then
    self:select_line(api.nvim_win_get_cursor(self.layout.log_win)[1])
  end
end

--- You moved the log's cursor or chose a row: a load in progress chooses nothing any more.
function Log:user_chose()
  self.auto_select = false
  self.provisional_id = nil
  self.choices = (self.choices or 0) + 1
end

--- Puts the log's cursor on `line` (not counted as you moving it).
function Log:cursor_to(line)
  local win = self.layout.log_win
  self.auto_line = line
  if util.win_valid(win) then
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
  end
end

function Log:auto_pick(line)
  self:cursor_to(line)
  self:select_line(line)
end

--- Path of the file at each commit (single-file history follows renames).
function Log:load_paths()
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

local function commit_side(sha)
  return { kind = "commit", oid = sha, label = util.short(sha) }
end

--- Side for a log row (commit / index / worktree).
function Log:row_side(row)
  if row.kind == "commit" then
    return commit_side(row.sha)
  elseif row.kind == "worktree" or row.kind == "index" then
    return { kind = row.kind }
  end
end

function Log:head_side()
  if self.head then
    return { kind = "commit", oid = self.head, label = "HEAD" }
  end
  return { kind = "commit", oid = git.empty_tree(self.repo), label = "(no commits)" }
end

--- Parent side of a commit row (respecting the chosen parent of merges).
function Log:parent_side(row)
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

--- Shows what the row on `line` stands for.
function Log:select_line(line)
  local row = self.log:row(line)
  if not row or row.kind == "graph" or row.kind == "message" then
    return
  end
  if row.kind == "worktree" or row.kind == "index" then
    return self:show_status(row.kind)
  end
  self.selected_id = row.sha
  local cmp = { left = self:parent_side(row), right = commit_side(row.sha) }
  local suffix
  if #(row.parents or {}) > 1 then
    local key = require("diffmerge.keymaps").key_for("log_panel", "cycle_parent")
    suffix = ("(merge: parent %d of %d%s)"):format(
      self.parent_choice[row.sha] or 1,
      #row.parents,
      key and (", " .. key .. " cycles") or ""
    )
  end
  cmp.title = "git show " .. util.short(row.sha) .. (suffix and ("  " .. suffix) or "")
  cmp.described = title_of({ left = cmp.left, right = cmp.right, paths = self.paths })
  self:show_comparison(cmp, row)
end

--- The row under the cursor, unless it is what is shown already.
function Log:preview_line(line)
  local id = row_id(self.log:row(line))
  if id and id == self.selected_id then
    return
  end
  self:select_line(line)
end

--- Shows a comparison (read-only) in the file panel and diff windows (`again`: the same one
--- anew, e.g. after a file was saved).
function Log:show_comparison(cmp, row, again)
  self.shows, self.displayed = "comparison", "comparison"
  self.cmp_row = row
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
  }, { switch = not again })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Log:action_select(ctx)
  if not in_log(self, ctx) then
    return views.View.action_select(self, ctx)
  end
  self:user_chose()
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

function Log:mark_label(i)
  return i == 1 and config.options.icons.mark_from or config.options.icons.mark_to
end

--- Lines of the selected range (nil: none, or not all of it loaded).
function Log:range_lines()
  if not self.range then
    return nil
  end
  local a, b = self:line_of_id(self.range[1]), self:line_of_id(self.range[2])
  if a and b then
    return { math.min(a, b), math.max(a, b) }
  end
end

function Log:redraw_marks()
  if not self.log then
    return
  end
  local marks = {}
  for i, m in ipairs(self.marks) do
    local line = self:line_of_id(m.id)
    if line then
      marks[#marks + 1] = { line = line, label = self:mark_label(i) }
    end
  end
  self.log:draw_marks(marks, self:range_lines())
end

function Log:action_mark(ctx)
  if not in_log(self, ctx) then
    return
  end
  self:user_chose()
  local line = api.nvim_win_get_cursor(0)[1]
  local row = self.log:row(line)
  local id = row_id(row)
  if not id then
    util.info("not a commit")
    return
  end
  self.range = nil
  for i, m in ipairs(self.marks) do
    if m.id == id then
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
  self.marks[#self.marks + 1] = { id = id, row = row }
  self:redraw_marks()
  if #self.marks == 2 then
    self:compare_marks()
  else
    util.info("marked " .. (row.sha and util.short(row.sha) or row.kind) .. ": mark a second row to compare")
  end
end

function Log:action_clear_marks(ctx)
  if not in_log(self, ctx) then
    return
  end
  self:user_chose()
  self.marks = {}
  self.range = nil
  self:redraw_marks()
  self:select_line(api.nvim_win_get_cursor(0)[1])
end

--- Two marked rows: git diff A B (or A...B), older side on the left.
function Log:compare_marks()
  local cmp = self:marks_comparison()
  if cmp then
    self:show_comparison(cmp)
  end
end

--- The comparison of the two marked rows (nil: none).
function Log:marks_comparison()
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
      if (self:line_of_id(a.id) or 0) < (self:line_of_id(b.id) or 0) then
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
  if title and b.row.kind ~= "commit" then
    -- the merge base with HEAD
    cmp.again = function()
      return #self.marks == 2 and self:marks_comparison() or cmp
    end
  end
  return cmp
end

function Log:action_toggle_range_mode(ctx)
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
function Log:select_range(first, last)
  local commits, pseudo, ids = {}, {}, {}
  for l = first, last do
    local r = self.log:row(l)
    if r and r.kind == "commit" then
      commits[#commits + 1] = r
    elseif r and (r.kind == "worktree" or r.kind == "index") then
      pseudo[r.kind] = true
    end
    if row_id(r) then
      ids[#ids + 1] = row_id(r)
    end
  end
  local range = { ids[1], ids[#ids] }
  if #commits == 0 then
    if pseudo.worktree and pseudo.index then
      local function head_to_worktree()
        local cmp = { left = self:head_side(), right = { kind = "worktree" }, title = "git diff HEAD" }
        cmp.again = head_to_worktree
        return cmp
      end
      self.marks, self.range = {}, range
      self:redraw_marks()
      self:show_comparison(head_to_worktree())
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
    right = commit_side(newest.sha)
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
  self.range = range
  self:redraw_marks()
  self:show_comparison(cmp)
end

function Log:current_row(ctx)
  if not in_log(self, ctx) then
    return nil
  end
  local line = api.nvim_win_get_cursor(0)[1]
  return self.log:row(line), line
end

function Log:action_cycle_parent(ctx)
  local row, line = self:current_row(ctx)
  if not row or row.kind ~= "commit" then
    return
  end
  local n = #(row.parents or {})
  if n < 2 then
    util.info("not a merge commit")
    return
  end
  self:user_chose()
  self.parent_choice[row.sha] = ((self.parent_choice[row.sha] or 1) % n) + 1
  self.marks, self.range = {}, nil
  self:redraw_marks()
  self:select_line(line)
end

function Log:action_commit_details(ctx)
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

function Log:action_yank_hash(ctx)
  local row = self:current_row(ctx)
  if not row or row.kind ~= "commit" then
    return
  end
  vim.fn.setreg('"', row.sha)
  pcall(vim.fn.setreg, "+", row.sha)
  util.info("yanked " .. row.sha)
end

--- `b`: check out the commit under the cursor (its branch; else a branch following a remote one
--- there, detached, or a new branch there); on the Working tree / Index row: the branch picker.
function Log:action_checkout(ctx)
  local row = self:current_row(ctx)
  if not row then
    return
  elseif row.kind == "worktree" or row.kind == "index" then
    return self:action_branch()
  elseif row.kind ~= "commit" then
    return
  end
  require("diffmerge.branch").at_commit(self.repo, row.sha, function()
    views.refresh_repo(self.repo)
  end)
end

function Log:action_toggle_first_parent(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.first_parent = not self.first_parent
  self:load_log()
end

function Log:action_toggle_all_branches(ctx)
  if not in_log(self, ctx) then
    return
  end
  self.all_branches = not self.all_branches
  self:load_log()
end

function Log:action_filter(ctx)
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
    self:load_log()
  end)
end

return M
