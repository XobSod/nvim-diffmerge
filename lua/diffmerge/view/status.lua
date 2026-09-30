--- Status view: what `git status` shows, as Conflicts / Staged / Unstaged / Untracked sections.
---   Staged    HEAD  -> index         (git diff --staged)
---   Unstaged  index -> working tree  (git diff)
---   Untracked nothing -> working tree
local config = require("diffmerge.config")
local git = require("diffmerge.git")
local hunks = require("diffmerge.hunks")
local parse = require("diffmerge.git_parse")
local source = require("diffmerge.source")
local util = require("diffmerge.util")
local views = require("diffmerge.view")

local api = vim.api
local M = {}

---@class diffmerge.StatusView: diffmerge.View
local StatusView = setmetatable({}, { __index = views.View })
StatusView.__index = StatusView
M.StatusView = StatusView

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

---@param repo diffmerge.Repo
---@param opts? { conflicts?: boolean }
function M.open(repo, opts)
  opts = opts or {}
  for tab, v in pairs(views.views) do
    if v.kind_name == "status" and v.repo.root == repo.root and api.nvim_tabpage_is_valid(tab) then
      api.nvim_set_current_tabpage(tab)
      v:refresh()
      if opts.conflicts then
        v:show_first_conflict()
      end
      return v
    end
  end
  local self = views.View.new(StatusView, repo, { files = true, kind = "diff" })
  self.kind_name = "status"
  self:setup_watchers()
  self:refresh()
  if opts.conflicts then
    self:show_first_conflict()
  elseif self.current then
    -- start in the file panel, like `git status`
    api.nvim_set_current_win(self.layout.files_win)
    self.files:set_cursor_to(self.current)
  end
  return self
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

function StatusView:collect()
  local repo = self.repo
  local out, err = git.output(repo, { "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all" })
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
  local unstaged_stats = parse.numstat(git.output(repo, { "diff", "--numstat", "-z", "--no-ext-diff" }) or "")
  local staged_stats = parse.numstat(
    git.output(repo, { "diff", "--cached", "--numstat", "-z", "--no-ext-diff", "-M", head or git.empty_tree(repo) })
      or ""
  )

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
      local entry = self:stage_entry(e, head, head_label)
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
  local subtitle = "git status"
  if op then
    labels = labels or git.conflict_labels(repo)
    subtitle = labels.operation or op.kind:upper()
  end
  return {
    title = title,
    subtitle = subtitle,
    sections = { sections.conflicts, sections.staged, sections.unstaged, sections.untracked },
    empty_text = "Working tree clean",
  }
end

local COLUMNS = { "head", "worktree", "index" }

--- A tracked file with changes: HEAD | WORKING TREE | INDEX, only the columns that differ
--- (nothing staged: HEAD | WORKING TREE, everything staged: HEAD | INDEX). The set follows
--- the state after every (un)stage: the column a change moves into always appears, a
--- column identical to its neighbour goes.
function StatusView:stage_entry(e, head, head_label)
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
  if not self.allow_collapse and cur and cur.kind == "stage" and cur.path == e.path then
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

function StatusView:refresh()
  if self.cleaned or not self.layout:is_valid() then
    return
  end
  if api.nvim_get_current_tabpage() ~= self.layout.tab then
    self.dirty = true
    return
  end
  self.dirty = false
  local data = self:collect()
  if not data then
    return
  end
  source.reload_index(self.repo)
  self:set_sections(data)
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
end

function StatusView:on_cleanup()
  for _, w in ipairs(self.watchers or {}) do
    pcall(function()
      w:stop()
      w:close()
    end)
  end
  self.watchers = nil
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
      if content and (content:find("\n<<<<<<< ", 1, true) or content:match("^<<<<<<< ")) and content:find("\n>>>>>>> ", 1, true) then
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
  local entries = self:selected_entries(ctx)
  local by_section = { staged = {}, unstaged = {}, untracked = {}, conflicts = {} }
  for _, e in ipairs(entries) do
    table.insert(by_section[e.section], e)
  end
  self:unstage(by_section.staged)
  self:stage(by_section.unstaged)
  self:stage(by_section.untracked)
  if #by_section.conflicts > 0 then
    self:resolve(by_section.conflicts)
  end
  self:refresh()
  if self.files and ctx.buf == self.files.buf and not ctx.range then
    -- keep the cursor near where it was
    local line = math.min(api.nvim_win_get_cursor(0)[1], api.nvim_buf_line_count(self.files.buf))
    pcall(api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

function StatusView:action_stage_all()
  self:git({ "add", "-A" }, "git add -A")
  self:refresh()
end

function StatusView:action_unstage_all()
  if self.head then
    self:git({ "reset", "-q" }, "git reset")
  else
    self:git({ "rm", "--cached", "-r", "-q", "--", "." }, "git rm --cached")
  end
  self:refresh()
end

function StatusView:action_discard(ctx)
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
  self:refresh()
  for _, p in ipairs(delete) do
    local buf = util.find_buf(git.abspath(self.repo, p))
    if buf and #vim.fn.win_findbuf(buf) == 0 and not vim.bo[buf].modified then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.cmd("silent! checktime")
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

---@param mode "hunk"|"lines"|"line"
function StatusView:stage_change(ctx, mode)
  local entry = self.current
  if entry and entry.kind == "stage" then
    return self:stage_toggle(ctx, mode)
  end
  if not entry or entry.kind ~= "diff" then
    return
  end
  local role = self.layout:role_of(ctx.win)
  if not role or not self:can_stage_parts(entry) then
    return
  end
  local a, b = self.infos.a, self.infos.b
  local section = entry.section
  local index_info = section == "staged" and b or a
  if index_info and index_info.editable and vim.bo[index_info.buf].modified then
    util.warn("the INDEX buffer has unsaved edits: :w it first")
    return
  end
  if section == "staged" and entry.status == "D" then
    util.warn("staged deletion: unstage the whole file with - in the file panel")
    return
  end
  local a_lines = a.src.kind == "empty" and {} or util.buf_lines(a.buf, a)
  local b_lines = b.src.kind == "empty" and {} or util.buf_lines(b.buf, b)
  local from, to, side, direction
  if section == "unstaged" or section == "untracked" then
    from, to = a_lines, b_lines
    side = role == "a" and "from" or "to"
    direction = "stage"
  elseif section == "staged" then
    from, to = b_lines, a_lines
    side = role == "b" and "from" or "to"
    direction = "unstage"
  else
    return
  end
  local s, e
  if ctx.range then
    s, e = ctx.range[1], ctx.range[2]
  else
    s = api.nvim_win_get_cursor(ctx.win)[1]
    e = s
  end
  -- blocks as on screen: whole hunks for `-`, linematch-aligned sub-hunks for lines; always
  -- diffed in the direction of the screen (left -> right), xdiff is not symmetric
  local all = hunks.compute(a_lines, b_lines, hunks.display_opts(mode ~= "hunk"))
  if direction == "unstage" then
    all = hunks.invert(all)
  end
  local picked
  if mode == "hunk" then
    picked = hunks.select(all, side, s, e)
  else
    picked = hunks.select_lines(all, side, s, e)
    if #picked == 0 and mode == "lines" then
      -- only next to filler lines: the deletion shown there
      picked = hunks.select(all, side, s, e)
    end
  end
  if #picked == 0 then
    if mode == "line" then
      util.info("no changed line under the cursor (removed lines: <Space> in the other window, or - for the hunk)")
    else
      util.info("no change under the cursor")
    end
    return
  end
  local selected = {}
  for _, h in ipairs(picked) do
    if mode == "hunk" then
      selected[h] = true
    else
      selected[h] = { side = side, s = s, e = e, exact = mode == "line" }
    end
  end
  local result, last = hunks.apply(from, to, all, selected)
  -- whole-file changes: staging a deletion / unstaging an addition removes the index entry
  local to_missing = (direction == "stage" and b.src.kind == "empty") or (direction == "unstage" and a.src.kind == "empty")
  if to_missing and #result == 0 then
    if self:remove_from_index(entry.path) then
      self:refresh()
    end
    return
  end
  -- final newline: from whichever side the end of the result comes from
  local from_info = direction == "stage" and a or b
  local to_info = direction == "stage" and b or a
  local function noeol_of(info)
    if info.src.kind == "empty" then
      return false
    end
    if info.scratch then
      return info.noeol == true
    end
    return not vim.bo[info.buf].eol
  end
  local noeol = hunks.noeol(from, to, last, noeol_of(from_info), noeol_of(to_info))
  local fmt
  if direction == "stage" then
    fmt = { filters = true, crlf = b.src.kind ~= "empty" and vim.bo[b.buf].fileformat == "dos", noeol = noeol }
  else
    fmt = { filters = false, crlf = b.crlf, noeol = noeol }
  end
  if self:write_index(entry, result, fmt) then
    self:refresh()
    if mode == "line" then
      self:cursor_to_next_change(ctx.win, s)
    end
  end
end

--- Removes a path from the index (keeps the file): staging a deletion / unstaging an addition.
function StatusView:remove_from_index(path)
  return self:git({ "update-index", "--force-remove", "--", path }, "git update-index --force-remove")
end

--- Hunk / line staging is possible for this entry (not binary, not a symlink, still current).
function StatusView:can_stage_parts(entry)
  for _, info in pairs(self.infos) do
    if info.special then
      util.warn("binary files, symlinks and submodules are staged as a whole (- in the file panel)")
      return false
    end
  end
  if entry.symlink then
    util.warn("symlinks are staged as a whole (- in the file panel)")
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

--- Lines (and line format) of a column of a stage entry, displayed or not.
function StatusView:stage_lines(entry, role)
  local info = self.infos[role]
  local src = entry.sides[role]
  if src.kind == "empty" then
    return {}, {}
  end
  if info then
    local lines = util.buf_lines(info.buf, info)
    if info.scratch then
      return lines, { crlf = info.crlf, noeol = info.noeol }
    end
    return lines, { crlf = vim.bo[info.buf].fileformat == "dos", noeol = not vim.bo[info.buf].eol }
  end
  if src.kind == "worktree" then
    local buf = util.find_buf(git.abspath(self.repo, src.path))
    if buf and api.nvim_buf_is_loaded(buf) then
      local lines = util.buf_lines(buf)
      return lines, { crlf = vim.bo[buf].fileformat == "dos", noeol = not vim.bo[buf].eol }
    end
  end
  local lines, flags = source.read_lines(self.repo, src)
  return lines or {}, flags or {}
end

--- `-` / `<Space>` in HEAD | WORKING TREE | INDEX: toggles the change under the cursor
--- between unstaged and staged, from any column.
function StatusView:stage_toggle(ctx, mode)
  local entry = self.current
  local role = self.layout:role_of(ctx.win)
  if not role or not self:can_stage_parts(entry) then
    return
  end
  local idx_info = self.infos.index
  if idx_info and idx_info.editable and vim.bo[idx_info.buf].modified then
    util.warn("the INDEX buffer has unsaved edits: :w it first")
    return
  end
  local head, head_fmt = self:stage_lines(entry, "head")
  local wt, wt_fmt = self:stage_lines(entry, "worktree")
  local index, idx_fmt = self:stage_lines(entry, "index")
  local s, e
  if ctx.range then
    s, e = ctx.range[1], ctx.range[2]
  else
    s = api.nvim_win_get_cursor(ctx.win)[1]
    e = s
  end
  -- unstaged: index -> working tree; staged (reversed): index -> HEAD
  local opts = hunks.display_opts(mode ~= "hunk")
  local unstaged = hunks.compute(index, wt, opts)
  -- the screen diffs HEAD -> INDEX; xdiff is not symmetric, so compute that way and flip
  local staged = hunks.invert(hunks.compute(head, index, opts))
  -- candidates in order of preference: { hunks, side, first, last, direction }
  local cands
  if role == "worktree" then
    local is, ie = hunks.map_line(unstaged, s, "to"), hunks.map_line(unstaged, e, "to")
    cands = { { unstaged, "to", s, e, "stage" }, { staged, "from", is, ie, "unstage" } }
  elseif role == "index" then
    cands = { { staged, "from", s, e, "unstage" }, { unstaged, "from", s, e, "stage" } }
  else
    local is, ie = hunks.map_line(staged, s, "to"), hunks.map_line(staged, e, "to")
    cands = { { staged, "to", s, e, "unstage" }, { unstaged, "from", is, ie, "stage" } }
  end
  local op
  for _, c in ipairs(cands) do
    if c[3] and c[4] then
      local picked = hunks.select_lines(c[1], c[2], c[3], c[4])
      if #picked > 0 then
        op = { hs = c[1], picked = picked, side = c[2], s = c[3], e = c[4], direction = c[5] }
        break
      end
    end
  end
  if not op and mode ~= "line" then
    -- next to filler lines: the removal shown there
    for _, c in ipairs(cands) do
      if c[3] and c[4] then
        local picked = hunks.select(c[1], c[2], c[3], c[4])
        if #picked > 0 then
          op = { hs = c[1], picked = picked, side = c[2], s = c[3], e = c[4], direction = c[5] }
          break
        end
      end
    end
  end
  if not op then
    util.info(mode == "line" and "no changed line under the cursor (- for the hunk)" or "no change under the cursor")
    return
  end
  local selected = {}
  for _, h in ipairs(op.picked) do
    if mode == "hunk" then
      selected[h] = true
    else
      selected[h] = { side = op.side, s = op.s, e = op.e, exact = mode == "line" }
    end
  end
  local stage = op.direction == "stage"
  local to, to_fmt = stage and wt or head, stage and wt_fmt or head_fmt
  local result, last = hunks.apply(index, to, op.hs, selected)
  local target = stage and entry.sides.worktree or entry.sides.head
  local was_class = self.stagectl and self.stagectl:class_at(role, s)
  local before_text = api.nvim_buf_get_lines(api.nvim_win_get_buf(ctx.win), s - 1, s, false)[1]
  local ok
  if target.kind == "empty" and #result == 0 then
    -- staging a deleted file / unstaging an added one: remove the index entry
    ok = self:remove_from_index(entry.path)
  else
    local noeol = hunks.noeol(index, to, last, idx_fmt.noeol, to_fmt.noeol)
    local fmt
    if stage then
      fmt = { filters = true, crlf = wt_fmt.crlf, noeol = noeol }
    else
      local crlf = idx_fmt.crlf
      if entry.sides.index.kind == "empty" then
        crlf = head_fmt.crlf
      end
      fmt = { filters = false, crlf = crlf, noeol = noeol }
      if entry.sides.index.kind == "empty" and self.head then
        fmt.mode = git.tree_mode(self.repo, self.head, entry.oldpath or entry.path)
      end
    end
    ok = self:write_index(entry, result, fmt)
  end
  if not ok then
    return
  end
  -- columns follow the new state (only staging may take a column away)
  self.allow_collapse = true
  self:refresh()
  self.allow_collapse = false
  if self.stagectl then
    self.stagectl:update()
  end
  local win = self.layout.wins[role]
  if not util.win_valid(win) then
    -- the column went away (nothing left to show in it): same text in the one that stays
    win = self:main_win()
    if util.win_valid(win) then
      local line = s
      local takeover = self.layout:role_of(win)
      if role == "index" and takeover == "worktree" then
        local new_index = self:stage_lines(self.current, "index")
        local new_wt = self:stage_lines(self.current, "worktree")
        line = hunks.map_line_near(hunks.compute(new_index, new_wt, opts), s, "from")
      end
      api.nvim_set_current_win(win)
      local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
      pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(line, n)), 0 })
    end
    return
  end
  api.nvim_set_current_win(win)
  local count = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  pcall(api.nvim_win_set_cursor, win, { math.min(s, count), 0 })
  if mode == "line" then
    if self.stagectl then
      local classes = (was_class == "staged" or (not was_class and not stage)) and { "staged", "mixed" }
        or { "unstaged", "mixed" }
      -- the toggled line itself is still there: continue below it
      local now = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), s - 1, s, false)[1]
      local from = now == before_text and s + 1 or s
      local line = self.stagectl:next_line(role, from, classes) or self.stagectl:next_line(role, 1, classes)
      if line then
        pcall(api.nvim_win_set_cursor, win, { math.min(line, count), 0 })
      end
    else
      self:cursor_to_next_change(win, s)
    end
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
