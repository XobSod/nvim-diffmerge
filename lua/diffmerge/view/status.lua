--- Status view: what `git status` shows, as Conflicts / Staged / Unstaged / Untracked sections,
--- with the log of the repository below (view/log.lua): its Working tree row shows the status,
--- its Index row what a commit takes, a commit what it changed (read-only).
---   Staged    HEAD  -> index         (git diff --staged)
---   Unstaged  index -> working tree  (git diff)
---   Untracked nothing -> working tree
local config = require("diffmerge.config")
local git = require("diffmerge.git")
local hunks = require("diffmerge.hunks")
local parse = require("diffmerge.git_parse")
local source = require("diffmerge.source")
local stash = require("diffmerge.stash")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

---@class diffmerge.StatusView: diffmerge.View
local StatusView = setmetatable({}, { __index = views.View })
StatusView.__index = StatusView
M.StatusView = StatusView

for name, fn in pairs(require("diffmerge.view.log").methods) do
  StatusView[name] = fn
end

local conflict_desc = {
  DD = "both deleted",
  AU = "added by us",
  UD = "deleted by them",
  UA = "added by them",
  DU = "deleted by us",
  AA = "both added",
  UU = "both modified",
}

local function literal(paths)
  local out = {}
  for _, p in ipairs(paths) do
    out[#out + 1] = ":(literal)" .. p
  end
  return out
end

--- Opens the status view: the main one of a repository (`:DiffMerge`; `:DiffMerge log` shows
--- its log), or one of its own for `:DiffMerge log <args>` / `history <path>`: the log and the
--- status of those paths only.
---@param repo diffmerge.Repo
---@param opts? { mode?: "status"|"log"|"history", args?: string[], path?: string, range?: integer[], conflicts?: boolean, focus?: { abs: string, line: integer } }
---   mode: "status" (default): the working tree, the log as it was (a new view: hidden); "log",
---   "history": with the log shown (see show_log for where it starts)
---   focus: the file (and line) to show, e.g. the buffer the view was opened from
function M.open(repo, opts)
  opts = opts or {}
  local mode = opts.mode or "status"
  local main = mode == "status" or (mode == "log" and #(opts.args or {}) == 0)
  local self
  if main then
    for tab, v in pairs(views.views) do
      if v.main and v.repo.root == repo.root and api.nvim_tabpage_is_valid(tab) then
        api.nvim_set_current_tabpage(tab)
        self = v
      end
    end
  end
  local fresh = not self
  if fresh then
    self = views.View.new(StatusView, repo, { files = true, kind = "diff" })
    self.kind_name = main and "status" or mode
    self.main = main
    self:init_log({ args = opts.args, path = opts.path, range = opts.range, history = mode == "history" })
    self.shows, self.selected_id = "worktree", "worktree"
    self:setup_watchers()
    self:refresh()
    if mode ~= "status" then
      self:show_log()
    end
  else
    if mode == "status" and (self.shows ~= "worktree" or self.selected_id ~= "worktree" or #self.marks > 0) then
      self:select_worktree()
    else
      self:refresh()
    end
    if mode ~= "status" then
      self:show_log()
    end
  end
  if opts.focus and self:focus_file(opts.focus, opts.conflicts) then
    return self
  end
  if opts.conflicts then
    self:show_first_conflict()
  elseif mode ~= "status" and self:log_shown() then
    api.nvim_set_current_win(self.layout.log_win)
  elseif fresh then
    -- start in the file panel, like `git status` (also when it is clean: F, p, P are there)
    api.nvim_set_current_win(self.layout.files_win)
    if self.current then
      self.files:set_cursor_to(self.current)
    end
  end
  return self
end

--- Shows the status in the file panel: all of it ("worktree") or what a commit takes ("index":
--- Conflicts and Staged).
---@param which "worktree"|"index"
function StatusView:show_status(which)
  self.shows, self.selected_id, self.cmp = which, which, nil
  self:refresh()
end

--- Back to the working tree (`:DiffMerge`): marks and a selected range of the log go.
function StatusView:select_worktree()
  self:user_chose()
  self.marks, self.range = {}, nil
  self:redraw_marks()
  self:show_status("worktree")
  local line = self:line_of_id("worktree")
  if line and self:log_shown() then
    self:cursor_to(line)
  end
end

--- The status as the selection shows it: all of it, or (the Index row) what a commit takes.
function StatusView:shown_status(data)
  if self.shows ~= "index" then
    return data
  end
  local keep = { conflicts = true, staged = true }
  return {
    title = data.title,
    subtitle = data.operation or "git diff --staged",
    sections = vim.tbl_filter(function(s)
      return keep[s.id]
    end, data.sections),
    empty_text = "Nothing staged",
  }
end

--- A commit (or another comparison of the log) is shown: nothing there to stage or discard.
function StatusView:read_only()
  if self.shows == "comparison" then
    util.info("read-only: select the Working tree row to stage")
    return true
  end
  return false
end

--- Shows a file of the status (if it has changes) with the cursor on `line` of its working
--- tree side.
---@param focus { abs: string, line?: integer, lines?: string[] } the file, line and its text
---@param conflicts_only? boolean only when the file is in conflict
function StatusView:focus_file(focus, conflicts_only)
  local abs, line = focus.abs, focus.line
  local rel = git.relpath(self.repo, abs)
  local entry
  local ids = conflicts_only and { "conflicts" } or { "conflicts", "unstaged", "staged", "untracked" }
  for _, id in ipairs(ids) do
    for _, sec in ipairs(self.sections or {}) do
      if sec.id == id and not entry then
        for _, e in ipairs(sec.entries) do
          if e.path == rel then
            entry = e
          end
        end
      end
    end
  end
  if not entry then
    return false
  end
  -- showing a conflict replaces the marker text: follow the cursor's line through that
  local buf = util.find_buf(abs)
  local before = focus.lines
  self:show_entry(entry, { focus = true })
  if before and line and buf and api.nvim_buf_is_valid(buf) then
    local after = util.buf_lines(buf)
    if not util.lines_equal(before, after) then
      line = hunks.map_line_near(hunks.compute(before, after), line, "from")
    end
  end
  local wins = self.layout.wins
  local win = wins.merged or wins.worktree or wins.b or wins.index
  if util.win_valid(win) and line then
    api.nvim_set_current_win(win)
    local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
    pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(line, n)), 0 })
    api.nvim_win_call(win, function()
      vim.cmd("normal! zvzz")
    end)
  end
  return true
end

function StatusView:show_first_conflict()
  for _, s in ipairs(self.sections or {}) do
    if s.id == "conflicts" and #s.entries > 0 then
      self:show_entry(self.files:ordered_entries(s)[1], { focus = true })
      return true
    end
  end
  util.info("no conflicts")
  return false
end

--- `args` limited to the paths of the view (`:DiffMerge history <path>`, `log -- <paths>`).
function StatusView:in_paths(args)
  local paths = self.paths or {}
  if #paths > 0 then
    args[#args + 1] = "--"
    util.extend(args, paths)
  end
  return args
end

--- The status (also kept as `self.status`), with the counts of the log's pseudo rows.
---@param changed? boolean after a staging action (see after_change)
function StatusView:collect(changed)
  local repo = self.repo
  local out, err = git.output(repo, self:in_paths({ "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all" }))
  if not out then
    util.err("git status failed: " .. (err or ""))
    return nil
  end
  local st = parse.status(out)
  local head = st.branch["branch.oid"]
  if head == "(initial)" then
    head = nil
  end
  self.head = head
  self.branch_id = (st.branch["branch.head"] or "") .. "@" .. (head or "")
  local unstaged_stats = parse.numstat(git.output(repo, self:in_paths({ "diff", "--numstat", "-z", "--no-ext-diff" })) or "")
  local staged_stats = parse.numstat(
    git.output(
      repo,
      self:in_paths({ "diff", "--cached", "--numstat", "-z", "--no-ext-diff", "-M", head or git.empty_tree(repo) })
    ) or ""
  )
  local counts = { unstaged = 0, staged = 0, untracked = 0, conflicts = 0 }
  for _, e in ipairs(st.entries) do
    if e.kind == "untracked" then
      counts.untracked = counts.untracked + 1
    elseif e.kind == "unmerged" then
      counts.conflicts = counts.conflicts + 1
    else
      counts.staged = counts.staged + (e.x ~= "." and 1 or 0)
      counts.unstaged = counts.unstaged + (e.y ~= "." and 1 or 0)
    end
  end
  self.counts = counts

  local sections = {
    conflicts = { id = "conflicts", title = "Conflicts", hint = "unmerged", entries = {} },
    staged = { id = "staged", title = "Staged", hint = "git diff --staged", entries = {} },
    unstaged = { id = "unstaged", title = "Unstaged", hint = "git diff", entries = {} },
    untracked = { id = "untracked", title = "Untracked", entries = {} },
  }
  local labels
  local head_label = head and ("HEAD · " .. util.short(head)) or "HEAD"
  for _, e in ipairs(st.entries) do
    if e.kind == "unmerged" then
      labels = labels or git.conflict_labels(repo)
      local merged = source.worktree(e.path)
      merged.label = "MERGED"
      if not vim.uv.fs_stat(git.abspath(repo, e.path)) then
        merged = source.empty("MERGED (deleted)", "merged")
      end
      local sides = {
        ["local"] = e.stages[2] and source.stage(2, e.path, labels["local"])
          or source.empty(labels["local"] .. " (deleted)", "local"),
        base = e.stages[1] and source.stage(1, e.path, labels.base) or source.empty("BASE (none)", "base"),
        remote = e.stages[3] and source.stage(3, e.path, labels.remote)
          or source.empty(labels.remote .. " (deleted)", "remote"),
        merged = merged,
      }
      table.insert(sections.conflicts.entries, {
        kind = "merge",
        path = e.path,
        status = "U",
        note = conflict_desc[e.xy],
        note_hl = "DiffMergeStatusUnmerged",
        section = "conflicts",
        key = "conflicts:" .. e.path,
        sides = sides,
      })
    elseif e.kind == "untracked" then
      table.insert(sections.untracked.entries, {
        kind = "diff",
        path = e.path,
        status = "?",
        section = "untracked",
        key = "untracked:" .. e.path,
        sides = { a = source.empty("(untracked)", "a"), b = source.worktree(e.path) },
      })
    elseif config.options.status.three_way then
      local entry = self:stage_entry(e, head, head_label, changed)
      if e.x ~= "." then
        table.insert(sections.staged.entries, vim.tbl_extend("force", entry, {
          status = e.x,
          section = "staged",
          key = "staged:" .. e.path,
          stats = staged_stats[e.path],
        }))
      end
      if e.y ~= "." then
        table.insert(sections.unstaged.entries, vim.tbl_extend("force", entry, {
          status = e.y,
          section = "unstaged",
          key = "unstaged:" .. e.path,
          stats = unstaged_stats[e.path],
        }))
      end
    else
      if e.x ~= "." then
        local old = e.orig or e.path
        local a = (e.x == "A" or not head) and source.empty("(new file)", "a") or source.rev(head, old, head_label)
        local b = e.x == "D" and source.empty("(deleted)", "b") or source.index(e.path)
        table.insert(sections.staged.entries, {
          kind = "diff",
          symlink = e.modes and (e.modes.head == "120000" or e.modes.index == "120000"),
          path = e.path,
          oldpath = e.orig,
          status = e.x,
          section = "staged",
          key = "staged:" .. e.path,
          stats = staged_stats[e.path],
          sides = { a = a, b = b },
        })
      end
      if e.y ~= "." then
        local b = e.y == "D" and source.empty("(deleted)", "b") or source.worktree(e.path)
        table.insert(sections.unstaged.entries, {
          kind = "diff",
          symlink = e.modes and (e.modes.index == "120000" or e.modes.worktree == "120000"),
          path = e.path,
          status = e.y,
          section = "unstaged",
          key = "unstaged:" .. e.path,
          stats = unstaged_stats[e.path],
          sides = { a = source.index(e.path), b = b },
        })
      end
    end
  end

  local branch = st.branch["branch.head"] or "?"
  if branch == "(detached)" then
    branch = "HEAD detached at " .. util.short(head)
  end
  local title = branch
  local ab = st.branch["branch.ab"]
  if ab then
    local ahead, behind = ab:match("%+(%d+) %-(%d+)")
    if ahead and tonumber(ahead) > 0 then
      title = title .. " ↑" .. ahead
    end
    if behind and tonumber(behind) > 0 then
      title = title .. " ↓" .. behind
    end
  end
  local op = git.operation(repo)
  local operation
  if op then
    labels = labels or git.conflict_labels(repo)
    local going_on = require("diffmerge.operation").current(repo)
    local hint = going_on and require("diffmerge.operation").hint(going_on)
    operation = (labels.operation or op.kind:upper()) .. (hint and ("\n" .. hint) or "")
  end
  local list = { sections.conflicts, sections.staged, sections.unstaged, sections.untracked }
  if #(self.paths or {}) == 0 then
    vim.list_extend(list, stash.sections(repo))
  end
  self.status = {
    title = title,
    subtitle = operation or "git status",
    operation = operation,
    sections = list,
    empty_text = "Working tree clean",
  }
  return self.status
end

local COLUMNS = { "head", "worktree", "index" }

--- A tracked file with changes: HEAD | WORKING TREE | INDEX, only the columns that differ
--- (nothing staged: HEAD | WORKING TREE, everything staged: HEAD | INDEX). The set follows
--- the state after every (un)stage: the column a change moves into always appears, a
--- column identical to its neighbour goes.
function StatusView:stage_entry(e, head, head_label, changed)
  local old = e.orig or e.path
  local new_file = e.x == "A" or e.y == "A" or not head
  local index = e.x == "D" and source.empty("(deleted)", "index") or source.index(e.path, { readonly = true })
  index.label = "INDEX · to be committed"
  local sides = {
    head = new_file and source.empty("(new file)", "head") or source.rev(head, old, head_label),
    worktree = e.y == "D" and source.empty("(deleted)", "worktree") or source.worktree(e.path),
    index = index,
  }
  local show = { head = true, worktree = e.x == "." or e.y ~= ".", index = e.x ~= "." }
  -- an unsaved working tree buffer differs from the file git compares: keep it visible
  local buf = util.find_buf(git.abspath(self.repo, e.path))
  if buf and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and e.y ~= "D" then
    show.worktree = true
  end
  -- only (un)staging takes a column away; saving a file or changes made elsewhere
  -- (lazygit, a terminal) never close the window you work in
  local cur = self.current
  if not changed and cur and cur.kind == "stage" and not cur.stash and cur.path == e.path then
    for _, c in ipairs(cur.columns) do
      show[c] = true
    end
  end
  local columns = vim.tbl_filter(function(c)
    return show[c]
  end, COLUMNS)
  local modes = e.modes or {}
  local symlink = modes.head == "120000" or modes.index == "120000" or modes.worktree == "120000"
  return { kind = "stage", path = e.path, oldpath = e.orig, sides = sides, columns = columns, symlink = symlink }
end

--- Refreshes after the user changed what is staged - from a diff window or the file panel,
--- staging or unstaging, one line or everything. Unlike other refreshes (saving a file,
--- lazygit, a terminal) this lets the columns of the shown file follow the new state, so all
--- these actions end in the same layout.
function StatusView:after_change()
  self:refresh({ changed = true })
  -- colours now, not on the next tick: the cursor may move on by them
  if self.stagectl then
    self.stagectl:update()
  end
end

local function touches_worktree(cmp)
  for _, side in ipairs({ cmp.left, cmp.right }) do
    if side.kind == "worktree" or side.kind == "index" then
      return true
    end
  end
  return false
end

--- The status anew; what the log selected shows it: the status, or a comparison (anew when it
--- compares the working tree or index, or `reshow`); the log follows (see log_follow).
---@param opts? { changed?: boolean, reshow?: boolean }
function StatusView:refresh(opts)
  opts = opts or {}
  if self.cleaned or not self.layout:is_valid() then
    return
  end
  if api.nvim_get_current_tabpage() ~= self.layout.tab then
    self.dirty = true
    return
  end
  self.dirty = false
  -- (a rewrite of the log over: said, a fixup that did not happen taken back, before what is
  -- shown is read)
  require("diffmerge.rewrite").finished(self.repo)
  local data = self:collect(opts.changed)
  if not data then
    return
  end
  source.reload_index(self.repo)
  if self.shows ~= "comparison" then
    -- (git wrote the files shown anew, an operation's next stop: what is shown goes too)
    local reshow = self.reshow
    self.reshow = nil
    local switch = self.displayed ~= self.shows or reshow
    self.displayed = self.shows
    self:set_sections(self:shown_status(data), { switch = switch })
    if reshow and self.current then
      self:show_entry(self.current, { force = true })
    end
  elseif self.cmp and (opts.reshow or touches_worktree(self.cmp)) then
    -- (one made against HEAD: against the HEAD of now)
    self:show_comparison(self.cmp.again and self.cmp.again() or self.cmp, self.cmp_row, true)
  end
  self:log_follow()
end

--- `R`: the status anew, a comparison of the log too; in the log panel the log as well.
function StatusView:action_refresh(ctx)
  if self.log and ctx and ctx.buf == self.log.buf then
    self.log_refs = nil
  end
  self:refresh({ reshow = true })
end

function StatusView:setup_watchers()
  local refresh = util.debounce(150, function()
    self:refresh()
  end)
  self.debounced_refresh = refresh
  local root = self.repo.root
  api.nvim_create_autocmd("BufWritePost", {
    group = self.augroup,
    callback = function(ev)
      local name = api.nvim_buf_get_name(ev.buf)
      if vim.startswith(name, root .. "/") then
        refresh()
      end
    end,
  })
  api.nvim_create_autocmd({ "FocusGained", "TermClose", "TermLeave", "ShellCmdPost" }, {
    group = self.augroup,
    callback = function()
      refresh()
    end,
  })
  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = "DiffMergeIndexChanged",
    callback = function(ev)
      if ev.data and ev.data.repo == root then
        refresh()
      end
    end,
  })
  api.nvim_create_autocmd("TabEnter", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_tabpage() == self.layout.tab and self.dirty then
        refresh()
      end
    end,
  })
  if not config.options.watch then
    return
  end
  self.watchers = {}
  local interesting = {
    index = true,
    HEAD = true,
    ORIG_HEAD = true,
    MERGE_HEAD = true,
    REBASE_HEAD = true,
    CHERRY_PICK_HEAD = true,
    REVERT_HEAD = true,
  }
  local function watch(dir, filter)
    if not vim.uv.fs_stat(dir) then
      return
    end
    local w = vim.uv.new_fs_event()
    if not w then
      return
    end
    local ok = pcall(function()
      w:start(dir, {}, function(err, fname)
        if err then
          return
        end
        if not filter or (fname and filter[fname]) then
          vim.schedule(refresh)
        end
      end)
    end)
    if ok then
      self.watchers[#self.watchers + 1] = w
    end
  end
  watch(self.repo.gitdir, interesting)
  watch(vim.fs.joinpath(self.repo.gitdir, "refs", "heads"), nil)
  -- stashes made or dropped elsewhere
  watch(vim.fs.joinpath(self.repo.gitdir, "refs"), { stash = true })
end

function StatusView:on_cleanup()
  for _, w in ipairs(self.watchers or {}) do
    pcall(function()
      w:stop()
      w:close()
    end)
  end
  self.watchers = nil
  if self.log then
    self.log:destroy()
  end
end

---------------------------------------------------------------------------
-- File level staging
---------------------------------------------------------------------------

function StatusView:git(args, what)
  local res = git.run(self.repo, args)
  if not res.ok then
    util.err((what or "git") .. " failed: " .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout))
    return false
  end
  return true
end

--- Entries selected in the file panel (cursor line or visual range).
function StatusView:selected_entries(ctx)
  if not self.files or ctx.buf ~= self.files.buf then
    return self.current and { self.current } or {}
  end
  local first, last
  if ctx.range then
    first, last = ctx.range[1], ctx.range[2]
  else
    first = api.nvim_win_get_cursor(0)[1]
    last = first
  end
  local seen, out = {}, {}
  for l = first, last do
    local item = self.files:item_at(l)
    if item then
      for _, e in ipairs(self.files:entries_of(item)) do
        if not seen[e] then
          seen[e] = true
          out[#out + 1] = e
        end
      end
    end
  end
  return out
end

function StatusView:stage(entries)
  local paths = {}
  for _, e in ipairs(entries) do
    paths[#paths + 1] = e.path
  end
  if #paths == 0 then
    return
  end
  local args = { "add", "--" }
  util.extend(args, literal(paths))
  self:git(args, "git add")
end

function StatusView:unstage(entries)
  local paths = {}
  for _, e in ipairs(entries) do
    paths[#paths + 1] = e.path
    if e.oldpath then
      paths[#paths + 1] = e.oldpath
    end
  end
  if #paths == 0 then
    return
  end
  local args
  if self.head then
    args = { "restore", "--staged", "--" }
  else
    args = { "rm", "--cached", "-r", "-q", "--" }
  end
  util.extend(args, literal(paths))
  self:git(args, "unstage")
end

--- Marks conflicted files as resolved (git add / git rm), checking for leftovers first.
function StatusView:resolve(entries)
  local merge = require("diffmerge.merge")
  for _, e in ipairs(entries) do
    local abs = git.abspath(self.repo, e.path)
    local buf = util.find_buf(abs) or -1
    local unresolved
    if self.current == e and self.merge then
      unresolved = self.merge:stats().unresolved
    else
      unresolved = merge.count_unresolved(self.repo, e)
    end
    local ok = true
    if unresolved and unresolved > 0 then
      ok = vim.fn.confirm(
        ("%s: %d conflict(s) not resolved yet (they contain the BASE text). Mark as resolved anyway?"):format(
          e.path,
          unresolved
        ),
        "&Yes\n&No",
        2
      ) == 1
    end
    if ok and buf ~= -1 and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    if ok then
      local content = util.read_file(abs)
      if content and merge.has_markers(util.split_lines(content), merge.side_lines(self.repo, e)) then
        ok = vim.fn.confirm(e.path .. " still contains conflict markers. Stage it anyway?", "&Yes\n&No", 2) == 1
      end
    end
    if ok and vim.uv.fs_stat(abs) and e.note and e.note:find("deleted", 1, true) then
      -- modify/delete: an emptied file most likely means "delete it"
      local content = util.read_file(abs) or ""
      if vim.trim(content) == "" and vim.fn.confirm(e.path .. " is empty. Delete it (git rm)?", "&Yes\n&No", 1) == 1 then
        vim.fn.delete(abs)
      end
    end
    if ok then
      if vim.uv.fs_stat(abs) then
        self:git({ "add", "--", ":(literal)" .. e.path }, "git add")
      else
        self:git({ "rm", "-q", "--", ":(literal)" .. e.path }, "git rm")
      end
    end
  end
end

function StatusView:action_toggle_stage(ctx)
  if self:committing() or self:read_only() then
    return
  end
  local entries = self:selected_entries(ctx)
  local by_section = { staged = {}, unstaged = {}, untracked = {}, conflicts = {} }
  for _, e in ipairs(entries) do
    if e.stash then
      util.info("a stash is not staged: s applies it")
      return
    end
    table.insert(by_section[e.section], e)
  end
  self:unstage(by_section.staged)
  self:stage(by_section.unstaged)
  self:stage(by_section.untracked)
  if #by_section.conflicts > 0 then
    self:resolve(by_section.conflicts)
  end
  self:after_change()
  if self.files and ctx.buf == self.files.buf and not ctx.range then
    -- keep the cursor near where it was
    local line = math.min(api.nvim_win_get_cursor(0)[1], api.nvim_buf_line_count(self.files.buf))
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

--- The whole conflicted file becomes LOCAL / REMOTE (binary files, lockfiles, ...) and is
--- marked resolved; a side that deleted the file deletes it. `git checkout -m <file>` brings
--- the conflict back.
---@param side "local"|"remote"
function StatusView:take_whole_file(ctx, side)
  if self:committing() or self:read_only() then
    return
  end
  local entries = vim.tbl_filter(function(e)
    return e.section == "conflicts"
  end, self:selected_entries(ctx))
  if #entries == 0 then
    util.info("not a conflict")
    return
  end
  local label = git.conflict_labels(self.repo)[side]
  local paths, unsaved = {}, false
  for _, e in ipairs(entries) do
    paths[#paths + 1] = e.path
    local buf = util.find_buf(git.abspath(self.repo, e.path))
    if buf and api.nvim_buf_is_loaded(buf) and require("diffmerge.merge").user_changes(buf) then
      unsaved = true
    end
  end
  local question = ("Resolve %s with %s for the whole file?%s"):format(
    table.concat(paths, ", "),
    label,
    unsaved and " Unsaved changes in it are lost." or ""
  )
  if vim.fn.confirm(question, "&Yes\n&No", 2) ~= 1 then
    return
  end
  local removed = {}
  for _, e in ipairs(entries) do
    local spec = ":(literal)" .. e.path
    local abs = git.abspath(self.repo, e.path)
    local buf = util.find_buf(abs)
    if e.sides[side].kind == "empty" then
      if self:git({ "rm", "-q", "-f", "--", spec }, "git rm") and buf then
        -- the file is gone: so is its buffer (its changes were confirmed away)
        vim.bo[buf].modified = false
        removed[#removed + 1] = buf
      end
    elseif self:git({ "checkout", side == "local" and "--ours" or "--theirs", "--", spec }, "git checkout") then
      self:git({ "add", "--", spec }, "git add")
      if buf and api.nvim_buf_is_loaded(buf) then
        api.nvim_buf_call(buf, function()
          vim.cmd("silent edit!")
        end)
      end
    end
  end
  self:after_change()
  for _, buf in ipairs(removed) do
    if api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
end

function StatusView:action_take_local_file(ctx)
  self:take_whole_file(ctx, "local")
end

function StatusView:action_take_remote_file(ctx)
  self:take_whole_file(ctx, "remote")
end

--- Paths of the entries of the status sections `ids` (with the old path of renames when
--- `oldpaths`): for git commands limited to the view's paths, which fail on a pathspec that
--- matches nothing.
function StatusView:entry_paths(ids, oldpaths)
  local out = {}
  for _, sec in ipairs((self.status or {}).sections or {}) do
    if ids[sec.id] then
      for _, e in ipairs(sec.entries) do
        out[#out + 1] = e.path
        if oldpaths and e.oldpath then
          out[#out + 1] = e.oldpath
        end
      end
    end
  end
  return out
end

--- `S`: stages everything (of the paths the view shows).
function StatusView:action_stage_all()
  if self:committing() or self:read_only() then
    return
  end
  if #(self.paths or {}) == 0 then
    self:git({ "add", "-A" }, "git add -A")
  else
    local paths = self:entry_paths({ conflicts = true, unstaged = true, untracked = true })
    if #paths > 0 then
      self:git(vim.list_extend({ "add", "-A", "--" }, literal(paths)), "git add -A")
    end
  end
  self:after_change()
end

--- `U`: unstages everything (of the paths the view shows).
function StatusView:action_unstage_all()
  if self:committing() or self:read_only() then
    return
  end
  local paths = { "." }
  if #(self.paths or {}) > 0 then
    paths = literal(self:entry_paths({ staged = true }, true))
  end
  if #paths == 0 then
    -- (nothing staged there)
  elseif self.head then
    self:git(vim.list_extend({ "reset", "-q", "--" }, paths), "git reset")
  else
    self:git(vim.list_extend({ "rm", "--cached", "-r", "-q", "--" }, paths), "git rm --cached")
  end
  self:after_change()
end

function StatusView:action_discard(ctx)
  if self:committing() or self:read_only() then
    return
  end
  local s = self:stash_at(ctx)
  if s then
    return self:stash_drop(s)
  end
  local entries = self:selected_entries(ctx)
  local restore, delete, skipped = {}, {}, 0
  for _, e in ipairs(entries) do
    if e.section == "unstaged" then
      restore[#restore + 1] = e.path
    elseif e.section == "untracked" then
      delete[#delete + 1] = e.path
    else
      skipped = skipped + 1
    end
  end
  if #restore + #delete == 0 then
    if skipped > 0 then
      util.warn("only unstaged and untracked changes can be discarded (unstage first)")
    end
    return
  end
  local msg = {}
  if #restore > 0 then
    msg[#msg + 1] = ("discard unstaged changes in %d file(s)"):format(#restore)
  end
  if #delete > 0 then
    msg[#msg + 1] = ("DELETE %d untracked file(s)"):format(#delete)
  end
  if vim.fn.confirm(table.concat(msg, " and ") .. "?", "&Yes\n&No", 2) ~= 1 then
    return
  end
  if #restore > 0 then
    local args = { "restore", "--worktree", "--" }
    util.extend(args, literal(restore))
    self:git(args, "git restore")
  end
  for _, p in ipairs(delete) do
    vim.fn.delete(git.abspath(self.repo, p))
  end
  -- switches away from deleted files first, so their buffers are released
  self:after_change()
  for _, p in ipairs(delete) do
    local buf = util.find_buf(git.abspath(self.repo, p))
    if buf and #vim.fn.win_findbuf(buf) == 0 and not vim.bo[buf].modified then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.cmd("silent! checktime")
end

---------------------------------------------------------------------------
-- Committing
---------------------------------------------------------------------------

--- `git commit <args>`: the message in a window below; `:wq` commits, `:q!` aborts. A view of
--- some paths only says what else is staged (the commit takes it too).
function StatusView:start_commit(args)
  if #(self.paths or {}) > 0 then
    local shown = {}
    for _, p in ipairs(self:entry_paths({ staged = true })) do
      shown[p] = true
    end
    local staged = vim.split(git.output(self.repo, { "diff", "--cached", "--name-only", "-z" }) or "", "\0", { trimempty = true })
    local elsewhere = vim.tbl_filter(function(p)
      return not shown[p]
    end, staged)
    if #elsewhere > 0 then
      util.warn("the commit also takes what is staged elsewhere: " .. table.concat(elsewhere, ", "))
    end
  end
  require("diffmerge.commit").run(self.repo, args, function()
    views.refresh_repo(self.repo)
  end)
end

--- A commit or a pull is running: what is staged must stay as it is (git commits the index
--- it started with; a pull changes it).
function StatusView:committing()
  if require("diffmerge.commit").running() then
    util.warn(require("diffmerge.commit").busy_message())
    return true
  elseif require("diffmerge.remote").running(self.repo) == "pull" then
    util.warn("git pull is running: wait for it")
    return true
  end
  return false
end

--- `c`: commit or amend, from a menu (`cc` / `ca` typed together go straight there); on a
--- commit of the log also fixup / squash / reword / drop it; while a merge, rebase, cherry-pick
--- or revert goes on: continue, skip, abort it.
function StatusView:action_commit_menu(ctx)
  local operation = require("diffmerge.operation")
  local op = operation.current(self.repo)
  if op and op.starting then
    util.warn("the rebase is being set up (its todo list is open in an editor)")
    return
  elseif op then
    vim.ui.select(operation.choices(self.repo, op), {
      prompt = git.operation_name(op),
      format_item = function(c)
        return c.text
      end,
    }, function(choice)
      if choice then
        util.after_select(function()
          if choice.act == "commit" then
            return self:start_commit({})
          end
          operation[choice.act](self.repo, function()
            views.refresh_repo(self.repo)
          end)
        end)
      end
    end)
    return
  end
  local choices = { { args = {}, text = "Commit" }, { args = { "--amend" }, text = "Amend the last commit" } }
  local row = ctx and self:current_row(ctx)
  if row and row.kind == "commit" then
    local short = util.short(row.sha)
    vim.list_extend(choices, {
      { rewrite = "fixup", sha = row.sha, text = ("Fixup %s with what is staged"):format(short) },
      { rewrite = "squash", sha = row.sha, text = ("Squash %s into its parent"):format(short) },
      { rewrite = "reword", sha = row.sha, text = ("Reword %s"):format(short) },
      { rewrite = "drop", sha = row.sha, text = ("Drop %s"):format(short) },
    })
  end
  vim.ui.select(choices, {
    prompt = "git commit",
    format_item = function(c)
      return c.text
    end,
  }, function(choice)
    if choice then
      util.after_select(function()
        if choice.rewrite then
          return require("diffmerge.rewrite")[choice.rewrite](self.repo, choice.sha, function()
            views.refresh_repo(self.repo)
          end)
        end
        self:start_commit(choice.args)
      end)
    end
  end)
end

--- `cc`: commit what is staged; while a merge, rebase, cherry-pick or revert goes on: continue
--- it.
function StatusView:action_commit()
  local operation = require("diffmerge.operation")
  if operation.current(self.repo) then
    return operation.continue(self.repo, function()
      views.refresh_repo(self.repo)
    end)
  end
  self:start_commit({})
end

--- `ca`: amend the last commit (its message to edit).
function StatusView:action_commit_amend()
  self:start_commit({ "--amend" })
end

---------------------------------------------------------------------------
-- Fetch, pull, push
---------------------------------------------------------------------------

--- `F`: git fetch.
function StatusView:action_fetch()
  require("diffmerge.remote").fetch(self.repo, {}, function()
    views.refresh_repo(self.repo)
  end)
end

--- `p`: git pull (your git config decides how).
function StatusView:action_pull()
  require("diffmerge.remote").pull(self.repo, {}, function()
    views.refresh_repo(self.repo)
  end)
end

--- `P`: git push.
function StatusView:action_push()
  require("diffmerge.remote").push(self.repo, {}, function()
    views.refresh_repo(self.repo)
  end)
end

--- `b`: switch branches (a picker of local and remote branches, or a new one).
function StatusView:action_branch()
  require("diffmerge.branch").pick(self.repo, function()
    views.refresh_repo(self.repo)
  end)
end

---------------------------------------------------------------------------
-- Stashes
---------------------------------------------------------------------------

-- the sections with changes of the working tree (what can be stashed)
local WORK = { staged = true, unstaged = true, untracked = true }

--- The changes of the whole repository (a stash takes them, whatever paths the view shows):
--- their paths, and whether some are staged.
---@return string[], boolean
function StatusView:changes()
  local paths, staged = {}, false
  if #(self.paths or {}) == 0 then
    for _, sec in ipairs((self.status or {}).sections or {}) do
      if WORK[sec.id] then
        for _, e in ipairs(sec.entries) do
          paths[#paths + 1] = e.path
        end
        staged = staged or (sec.id == "staged" and #sec.entries > 0)
      end
    end
    return paths, staged
  end
  local out = git.output(self.repo, { "status", "--porcelain=v2", "-z", "--untracked-files=all" }) or ""
  for _, e in ipairs(parse.status(out).entries) do
    if e.kind ~= "unmerged" then
      paths[#paths + 1] = e.path
      staged = staged or (e.kind ~= "untracked" and e.x ~= ".")
    end
  end
  return paths, staged
end

--- The stash under the cursor in the file panel (its section or one of its files; a visual
--- range: when all of it is in one stash), or of the file shown (not from the log panel).
function StatusView:stash_at(ctx)
  if self.log and ctx.buf == self.log.buf then
    return nil
  end
  if not self.files or ctx.buf ~= self.files.buf then
    return self.current and self.current.stash
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local first, last = line, line
  if ctx.range then
    first, last = ctx.range[1], ctx.range[2]
  end
  local found
  for l = first, last do
    local item = self.files:item_at(l)
    local s = item and item.section and item.section.stash
    if not s or (found and s ~= found) then
      return nil
    end
    found = s
  end
  return found
end

--- Paths among `paths` whose buffers have unsaved changes (stashing and applying change
--- the files under them).
function StatusView:unsaved(paths)
  local out = {}
  for _, p in ipairs(paths) do
    local buf = util.find_buf(git.abspath(self.repo, p))
    if buf and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      out[#out + 1] = p
    end
  end
  return out
end

function StatusView:refuse_unsaved(paths)
  local unsaved = self:unsaved(paths)
  if #unsaved > 0 then
    util.warn("unsaved changes in " .. table.concat(unsaved, ", ") .. ": save them first")
    return true
  end
  return false
end

--- After stashing / applying: buffers and the view follow the files; buffers of files the
--- stash took away (`gone`: what it stashed) go too (saving them would bring the files back).
---@param gone? string[]
function StatusView:after_stash(res, done, gone)
  if res.ok then
    util.info(done or vim.trim(res.stdout or ""))
  else
    -- what git says, without the `git status` it prints after it
    local lines = {}
    for _, l in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
      if l:match("^On branch ") or l:match("^HEAD detached ") or l:match("^Not currently on any branch") then
        break
      end
      lines[#lines + 1] = l
    end
    vim.list_extend(lines, vim.split(vim.trim(res.stderr or ""), "\n", { trimempty = true }))
    util.warn(#lines > 0 and table.concat(lines, "\n") or vim.trim(res.stdout or ""))
  end
  vim.cmd("silent! checktime")
  self:after_change()
  util.drop_gone_buffers(self.repo.root, gone)
end

--- `s`: stash (staged changes, the selected files, everything ...); on a stash: apply, pop or
--- drop it.
function StatusView:action_stash(ctx)
  if self:committing() then
    return
  end
  local s = self:stash_at(ctx)
  if s then
    return self:stash_menu(s)
  end
  local selected, files, renamed, untracked = {}, {}, {}, false
  local work, staged = self:changes()
  if #work == 0 then
    util.info("no local changes to stash")
    return
  end
  if self.files and ctx.buf == self.files.buf then
    for _, e in ipairs(self:selected_entries(ctx)) do
      if WORK[e.section] then
        selected[#selected + 1] = e.path
        files[#files + 1] = e.path
        -- a rename: both of its paths
        if e.oldpath then
          selected[#selected + 1] = e.oldpath
          renamed[#renamed + 1] = e.oldpath
        end
        untracked = untracked or e.section == "untracked"
      end
    end
  end
  local choices = {}
  if staged then
    choices[#choices + 1] = { what = "staged", text = "Staged changes" }
  end
  if #selected > 0 then
    choices[#choices + 1] = {
      what = "paths",
      text = #files == 1 and ("This file: " .. files[1]) or ("These %d files"):format(#files),
    }
  end
  choices[#choices + 1] = { what = "all", text = "All changes" }
  choices[#choices + 1] = { what = "untracked", text = "All changes and untracked files" }
  if staged then
    choices[#choices + 1] = { what = "keep_index", text = "All changes, keeping the staged ones in place" }
  end
  vim.ui.select(choices, {
    prompt = "Stash",
    format_item = function(c)
      return c.text
    end,
  }, function(choice)
    if not choice then
      return
    end
    if self:refuse_unsaved(choice.what == "paths" and selected or work) then
      return
    end
    util.after_select(function()
      vim.ui.input({ prompt = "Stash message (empty: git's own): " }, function(message)
        if message == nil then
          return
        end
        if choice.what == "staged" then
          self:after_stash(stash.push_staged(self.repo, message), nil, work)
        else
          if choice.what == "paths" and #renamed > 0 then
            -- git stashes only paths the index knows: the old path of a rename goes back in
            -- (deleted, unstaged)
            self:git(vim.list_extend({ "reset", "-q", "--" }, literal(renamed)), "git reset")
          end
          self:after_stash(stash.push(self.repo, choice.what, message, selected, untracked), nil, work)
        end
      end)
    end)
  end)
end

function StatusView:stash_menu(s)
  local choices = {
    { act = "apply", text = "Apply" },
    { act = "pop", text = "Pop: apply and drop" },
    { act = "drop", text = "Drop" },
  }
  vim.ui.select(choices, {
    prompt = s.ref .. ": " .. s.subject,
    format_item = function(c)
      return c.text
    end,
  }, function(choice)
    if not choice then
      return
    elseif choice.act == "drop" then
      self:stash_drop(s)
    else
      self:stash_apply(s, choice.act == "pop")
    end
  end)
end

--- Applies a stash, its staged part staged again (--index); if that part conflicts, it can go
--- in as unstaged changes. Conflicts of the working tree part show under Conflicts.
function StatusView:stash_apply(s, pop)
  local ref = stash.ref(self.repo, s.sha)
  if not ref then
    util.warn("the stash is gone")
    return self:refresh()
  end
  if self:refuse_unsaved(stash.paths(self.repo, s.sha)) then
    return
  end
  local verb = pop and "pop" or "apply"
  local res = git.run(self.repo, { "stash", verb, "--index", ref })
  if not res.ok and (res.stderr .. res.stdout):lower():find("conflicts in index", 1, true) then
    local again = vim.fn.confirm(
      ("The staged part of %s conflicts with the index. Apply it as unstaged changes?"):format(ref),
      "&Yes\n&No",
      2
    )
    if again ~= 1 then
      return
    end
    res = git.run(self.repo, { "stash", verb, ref })
  end
  self:after_stash(res, res.ok and ((pop and "popped " or "applied ") .. ref) or nil)
end

function StatusView:stash_drop(s)
  local ref = stash.ref(self.repo, s.sha)
  if not ref then
    util.warn("the stash is gone")
    return self:refresh()
  end
  if vim.fn.confirm(("Drop %s: %s?"):format(ref, s.subject), "&Yes\n&No", 2) ~= 1 then
    return
  end
  if self:git({ "stash", "drop", "-q", ref }, "git stash drop") then
    util.info("dropped " .. ref)
  end
  self:refresh()
end

---------------------------------------------------------------------------
-- Hunk / line staging
---------------------------------------------------------------------------

--- `-`: the hunk under the cursor (visual: the selected lines).
function StatusView:action_toggle_stage_hunk(ctx)
  self:stage_change(ctx, ctx.range and "lines" or "hunk")
end

--- `<Space>`: only the line under the cursor (lazygit style), then on to the next change.
--- A changed line is staged together with the line shown next to it on the other side.
function StatusView:action_toggle_stage_line(ctx)
  self:stage_change(ctx, ctx.range and "lines" or "line")
end

--- Removes a path from the index (keeps the file): staging a deletion / unstaging an addition.
function StatusView:remove_from_index(path)
  return self:git({ "update-index", "--force-remove", "--", path }, "git update-index --force-remove")
end

--- Hunk / line changes are possible for this entry (not binary, not a symlink, still current).
---@param verb? string "staged" / "discarded"
function StatusView:can_stage_parts(entry, verb)
  verb = verb or "staged"
  local key = verb == "discarded" and "X" or "-"
  for _, info in pairs(self.infos) do
    if info.special then
      util.warn(("binary files, symlinks and submodules are %s as a whole (%s in the file panel)"):format(verb, key))
      return false
    end
  end
  if entry.symlink then
    util.warn(("symlinks are %s as a whole (%s in the file panel)"):format(verb, key))
    return false
  end
  local live = false
  for _, sec in ipairs(self.sections or {}) do
    for _, e in ipairs(sec.entries) do
      if e == entry then
        live = true
      end
    end
  end
  if not live then
    util.info(entry.path .. " has no changes any more (committed / discarded elsewhere?); R refreshes")
    return false
  end
  return true
end

--- What the windows of an entry show, as versions of the file (role per version), and
--- which way changes may move. HEAD | WORKING TREE | INDEX: both ways; the two-way views
--- (status.three_way = false): Unstaged (INDEX | WORKING TREE) only stages, Staged
--- (HEAD | INDEX) only unstages.
---@return { roles: table<string, string>, stage?: boolean, unstage?: boolean }|nil
function StatusView:staging_frame(entry)
  if entry.kind == "stage" then
    return { roles = { head = "head", worktree = "worktree", index = "index" }, stage = true, unstage = true }
  elseif entry.kind == "diff" and entry.section == "staged" then
    return { roles = { head = "a", index = "b" }, unstage = true }
  elseif entry.kind == "diff" and (entry.section == "unstaged" or entry.section == "untracked") then
    return { roles = { index = "a", worktree = "b" }, stage = true }
  end
end

--- Lines (and line format) of one version of the entry's file, shown or not.
---@param version "head"|"worktree"|"index"
function StatusView:version_lines(entry, frame, version)
  local role = frame.roles[version]
  local src = role and entry.sides[role]
  if not src then
    -- a version this view does not show
    if version == "index" then
      src = source.index(entry.path)
    elseif version == "worktree" then
      src = source.worktree(entry.path)
    elseif self.head then
      src = source.rev(self.head, entry.oldpath or entry.path)
    else
      src = source.empty("", "head")
    end
  end
  if src.kind == "empty" then
    return {}, {}, src
  end
  local info = role and self.infos[role]
  if info then
    local lines = util.buf_lines(info.buf, info)
    if info.scratch then
      return lines, { crlf = info.crlf, noeol = info.noeol }, src
    end
    return lines, { crlf = vim.bo[info.buf].fileformat == "dos", noeol = not vim.bo[info.buf].eol }, src
  end
  if src.kind == "worktree" then
    local buf = util.find_buf(git.abspath(self.repo, src.path))
    if buf and api.nvim_buf_is_loaded(buf) then
      return util.buf_lines(buf), { crlf = vim.bo[buf].fileformat == "dos", noeol = not vim.bo[buf].eol }, src
    end
  end
  local lines, flags = source.read_lines(self.repo, src)
  return lines or {}, flags or {}, src
end

--- What a staging / discarding key acts on: the entry, which version of the file the window
--- shows, the cursor (or visual) lines and the file's versions, loaded on demand.
function StatusView:change_context(ctx, mode, verb)
  if self:read_only() then
    return nil
  end
  local entry = self.current
  if entry and entry.stash then
    util.info("a stash is read-only: s in the file panel applies it")
    return nil
  end
  local frame = entry and self:staging_frame(entry)
  local role = self.layout:role_of(ctx.win)
  if not frame or not role or not self:can_stage_parts(entry, verb) then
    return nil
  end
  for _, info in pairs(self.infos) do
    if info.src.kind == "index" and info.editable and vim.bo[info.buf].modified then
      util.warn("the INDEX buffer has unsaved edits: :w it first")
      return nil
    end
  end
  local c = { entry = entry, frame = frame, role = role, mode = mode, L = {}, F = {}, S = {} }
  for v, r in pairs(frame.roles) do
    if r == role then
      c.version = v
    end
  end
  if ctx.range then
    c.s, c.e = ctx.range[1], ctx.range[2]
  else
    c.s = api.nvim_win_get_cursor(ctx.win)[1]
    c.e = c.s
  end
  function c.load(v)
    if not c.L[v] then
      c.L[v], c.F[v], c.S[v] = self:version_lines(entry, frame, v)
    end
    return c.L[v]
  end
  -- hunks as on screen ('diffopt'; linematch-aligned sub-hunks for lines), in the direction
  -- the screen diffs them: INDEX -> WORKING TREE, HEAD -> INDEX (xdiff is not symmetric)
  c.opts = hunks.display_opts(mode ~= "hunk")
  function c.unstaged()
    c.U = c.U or hunks.compute(c.load("index"), c.load("worktree"), c.opts)
    return c.U
  end
  function c.staged()
    c.Sh = c.Sh or hunks.invert(hunks.compute(c.load("head"), c.load("index"), c.opts))
    return c.Sh
  end
  return c
end

--- The first candidate { hunks, side, first, last, direction } with a change at the cursor:
--- lines that are part of a change first, then (not for single lines) the change next to
--- filler lines.
local function pick(cands, mode)
  local function first(select)
    for _, c in ipairs(cands) do
      if c[1] and c[3] and c[4] then
        local picked = select(c[1], c[2], c[3], c[4])
        if #picked > 0 then
          return { hs = c[1], picked = picked, side = c[2], s = c[3], e = c[4], direction = c[5] }
        end
      end
    end
  end
  return first(hunks.select_lines) or (mode ~= "line" and first(hunks.select)) or nil
end

local function selection(op, mode)
  local selected = {}
  for _, h in ipairs(op.picked) do
    if mode == "hunk" then
      selected[h] = true
    else
      selected[h] = { side = op.side, s = op.s, e = op.e, exact = mode == "line" }
    end
  end
  return selected
end

--- Stages / unstages the change under the cursor of a diff window: moves it between the
--- INDEX and the WORKING TREE (stage) or HEAD (unstage). The same code serves every view;
--- only the directions allowed by `staging_frame` differ.
---@param mode "hunk"|"lines"|"line"
function StatusView:stage_change(ctx, mode)
  if self:committing() then
    return
  end
  local c = self:change_context(ctx, mode, "staged")
  if not c then
    return
  end
  local s, e = c.s, c.e
  local unstaged = c.frame.stage and c.unstaged()
  local staged = c.frame.unstage and c.staged()
  local cands = {}
  if c.version == "worktree" then
    cands[1] = { unstaged, "to", s, e, "stage" }
    if unstaged then
      cands[2] = { staged, "from", hunks.map_line(unstaged, s, "to"), hunks.map_line(unstaged, e, "to"), "unstage" }
    end
  elseif c.version == "index" then
    cands = { { staged, "from", s, e, "unstage" }, { unstaged, "from", s, e, "stage" } }
  else
    cands[1] = { staged, "to", s, e, "unstage" }
    if staged then
      cands[2] = { unstaged, "from", hunks.map_line(staged, s, "to"), hunks.map_line(staged, e, "to"), "stage" }
    end
  end
  local op = pick(cands, mode)
  if not op then
    util.info(
      mode == "line" and "no changed line under the cursor (removed lines: <Space> where they are shown, - for the hunk)"
        or "no change under the cursor"
    )
    return
  end
  local stage = op.direction == "stage"
  local tv = stage and "worktree" or "head"
  local index, to = c.load("index"), c.load(tv)
  local result, last = hunks.apply(index, to, op.hs, selection(op, mode))
  local was_class = self.stagectl and self.stagectl:class_at(c.role, s)
  local before_text = api.nvim_buf_get_lines(api.nvim_win_get_buf(ctx.win), s - 1, s, false)[1]
  local ok
  if c.S[tv].kind == "empty" and #result == 0 then
    -- staging a deleted file / unstaging an added one: remove the index entry
    ok = self:remove_from_index(c.entry.path)
  else
    local fmt = { noeol = hunks.noeol(index, to, last, c.F.index.noeol, c.F[tv].noeol) }
    if stage then
      fmt.filters, fmt.crlf = true, c.F.worktree.crlf
    else
      -- index blob form; a staged deletion is brought back with HEAD's mode
      local no_index = c.S.index.kind == "empty"
      fmt.filters, fmt.crlf = false, (no_index and c.F.head or c.F.index).crlf
      if no_index and self.head then
        fmt.mode = git.tree_mode(self.repo, self.head, c.entry.oldpath or c.entry.path)
      end
    end
    ok = self:write_index(c.entry, result, fmt)
  end
  if not ok then
    return
  end
  self:after_change()
  self:restore_cursor(c.role, s, mode, {
    stage = stage,
    was_class = was_class,
    before_text = before_text,
    opts = c.opts,
  })
end

--- `X`: throws away the unstaged change under the cursor (visual: the selected lines): the
--- working tree gets the INDEX version back. The file is saved unless it already had unsaved
--- edits (those are never written implicitly); `u` brings the change back.
function StatusView:action_discard_change(ctx)
  if self:committing() then
    return
  end
  local mode = ctx.range and "lines" or "hunk"
  local c = self:change_context(ctx, mode, "discarded")
  if not c then
    return
  end
  local entry = c.entry
  if not c.frame.stage then
    util.info("only unstaged changes can be discarded (unstage first)")
    return
  end
  if entry.section == "untracked" or (entry.section == "unstaged" and entry.status == "A") then
    util.info("a new file has no version to go back to (X in the file panel deletes it)")
    return
  end
  local s, e = c.s, c.e
  local abs = git.abspath(self.repo, entry.path)
  local index = c.load("index")
  c.load("worktree")
  if c.S.worktree.kind == "empty" then
    -- the file is deleted in the working tree: bring it back
    if self:git({ "restore", "--worktree", "--", ":(literal)" .. entry.path }, "git restore") then
      self:after_change()
    end
    return
  end
  local wt_role = c.frame.roles.worktree
  local buf = self.infos[wt_role] and self.infos[wt_role].buf or util.find_buf(abs)
  if not buf then
    buf = vim.fn.bufadd(abs)
    vim.fn.bufload(buf)
  end
  -- the buffer is written below: pick up changes made on disk meanwhile (lazygit, a terminal)
  vim.cmd(("checktime %d"):format(buf))
  c.L.worktree, c.U = nil, nil
  local wt = c.load("worktree")
  local unstaged = c.unstaged()
  local cands
  if c.version == "worktree" then
    cands = { { unstaged, "to", s, e } }
  elseif c.version == "index" then
    cands = { { unstaged, "from", s, e } }
  else
    local staged = c.frame.unstage and c.staged() or {}
    cands = { { unstaged, "from", hunks.map_line(staged, s, "to"), hunks.map_line(staged, e, "to") } }
  end
  local op = pick(cands, mode)
  if not op then
    -- a staged change there? (looked up in INDEX lines)
    local staged_here
    if c.frame.unstage then
      if c.version == "head" then
        staged_here = pick({ { c.staged(), "to", s, e } }, mode)
      else
        local a, b = s, e
        if c.version == "worktree" then
          a, b = hunks.map_line(unstaged, s, "to"), hunks.map_line(unstaged, e, "to")
        end
        staged_here = pick({ { c.staged(), "from", a, b } }, mode)
      end
    end
    util.info(staged_here and "that change is staged: unstage it first (<Space> / -)" or "no unstaged change under the cursor")
    return
  end
  -- the same hunks seen from the working tree: apply the INDEX side onto it
  local inverted = hunks.invert(op.hs)
  local picked = selection(op, mode)
  local selected = {}
  for i, h in ipairs(op.hs) do
    local sel = picked[h]
    if sel == true then
      selected[inverted[i]] = true
    elseif sel then
      selected[inverted[i]] = { side = sel.side == "to" and "from" or "to", s = sel.s, e = sel.e }
    end
  end
  local result, last = hunks.apply(wt, index, inverted, selected)
  local noeol = hunks.noeol(wt, index, last, c.F.worktree.noeol, c.F.index.noeol)
  local unsaved = vim.bo[buf].modified
  util.replace_lines(buf, wt, result)
  vim.bo[buf].eol = not noeol
  if noeol then
    -- keep the missing final newline of the INDEX version when writing
    vim.bo[buf].fixeol = false
  end
  if unsaved then
    util.info("change discarded in the buffer (it has other unsaved edits: :w to keep it)")
  else
    -- noautocmd: format-on-save and friends must not touch the rest of the file
    api.nvim_buf_call(buf, function()
      vim.cmd("silent noautocmd write")
    end)
  end
  local line = s
  if c.version == "worktree" then
    line = hunks.map_line_near(hunks.compute(wt, result), s, "from")
  end
  self:after_change()
  self:restore_cursor(c.role, s, "hunk", { opts = c.opts, line = line })
end

--- After an (un)stage from a diff window: back to the same place, or on to the next change
--- (<Space>), also when the window's column went away.
---@param st { opts: table, line?: integer, stage?: boolean, was_class?: string, before_text?: string }
---   line: where the cursor's text is now, when the change moved it
function StatusView:restore_cursor(role, s, mode, st)
  local win = self.layout.wins[role]
  if not util.win_valid(win) then
    -- the column went away (nothing left to show in it): same text in the one that stays
    win = self:main_win()
    if util.win_valid(win) then
      local line = st.line or s
      if role == "index" and self.layout:role_of(win) == "worktree" then
        local frame = self:staging_frame(self.current)
        local new_index = self:version_lines(self.current, frame, "index")
        local new_wt = self:version_lines(self.current, frame, "worktree")
        line = hunks.map_line_near(hunks.compute(new_index, new_wt, st.opts), s, "from")
      end
      api.nvim_set_current_win(win)
      local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
      pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(line, n)), 0 })
    end
    return
  end
  api.nvim_set_current_win(win)
  local count = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(st.line or s, count)), 0 })
  if mode ~= "line" then
    return
  end
  if self.stagectl then
    local classes = (st.was_class == "staged" or (not st.was_class and not st.stage)) and { "staged", "mixed" }
      or { "unstaged", "mixed" }
    -- the toggled line itself is still there: continue below it
    local now = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), s - 1, s, false)[1]
    local from = now == st.before_text and s + 1 or s
    local line = self.stagectl:next_line(role, from, classes) or self.stagectl:next_line(role, 1, classes)
    if line then
      pcall(api.nvim_win_set_cursor, win, { math.min(line, count), 0 })
    end
  else
    self:cursor_to_next_change(win, s)
  end
end

--- Moves the cursor to the first changed line at or below `from` (repeated <Space> walks
--- through the changes).
function StatusView:cursor_to_next_change(win, from)
  if not util.win_valid(win) or not self.layout:role_of(win) then
    return
  end
  api.nvim_win_call(win, function()
    vim.cmd("diffupdate")
    local last = api.nvim_buf_line_count(0)
    for l = math.min(from, last), last do
      if vim.fn.diff_hlID(l, 1) ~= 0 then
        api.nvim_win_set_cursor(0, { l, 0 })
        return
      end
    end
  end)
end

--- Writes new index content for the entry's path.
---@param fmt { filters: boolean, crlf?: boolean, noeol?: boolean, mode?: string }
---   filters: content is in working tree form (clean filters apply, like `git add`)
function StatusView:write_index(entry, lines, fmt)
  local repo = self.repo
  local path = entry.path
  local existing = git.index_entries(repo, path)[0]
  local mode = existing and existing.mode or fmt.mode
  if not mode then
    if fmt.filters then
      local stat = vim.uv.fs_stat(git.abspath(repo, path))
      mode = (stat and bit.band(stat.mode, 73) ~= 0) and "100755" or "100644"
    else
      mode = "100644"
    end
  end
  local content = util.join_lines(lines, fmt.crlf, fmt.noeol)
  local oid, err = git.hash_object(repo, content, path, fmt.filters)
  if not oid then
    util.err("git hash-object failed: " .. (err or ""))
    return false
  end
  local res = git.update_index(repo, mode, oid, path)
  if not res.ok then
    util.err("git update-index failed: " .. vim.trim(res.stderr))
    return false
  end
  return true
end

--- Staging only exists in the status view.
function StatusView:supports(action, group)
  return views.View.supports(self, action, group)
end

return M
