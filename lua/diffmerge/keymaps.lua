--- Buffer-local keymaps with save/restore (real file buffers get their own mappings back
--- when a view closes) and the `g?` help window.
local config = require("diffmerge.config")

local api = vim.api
local M = {}

M.descriptions = {
  next_file = "Next file",
  prev_file = "Previous file",
  cycle_layout = "Cycle layout",
  toggle_files = "Show / hide the file panel",
  toggle_log = "Show / hide the log panel",
  toggle_whitespace = "Toggle ignoring whitespace changes (diffopt iwhite)",
  help = "This help",
  toggle_stage_hunk = "Stage / unstage hunk (visual: selected lines)",
  toggle_stage_line = "Stage / unstage the line under the cursor (visual: selected lines)",
  discard_change = "Discard the unstaged hunk under the cursor (visual: selected lines)",
  toggle_local = "Toggle LOCAL (mine) in the chunk",
  toggle_base = "Toggle BASE in the chunk",
  toggle_remote = "Toggle REMOTE (theirs) in the chunk",
  take_none = "Resolve the chunk with nothing",
  next_conflict = "Next conflict",
  prev_conflict = "Previous conflict",
  next_chunk = "Next change",
  prev_chunk = "Previous change",
  select = "Open the file / fold or unfold the section",
  expand = "Open file / expand directory",
  collapse = "Collapse directory",
  toggle_stage = "Stage / unstage (file, directory, section)",
  stage_all = "Stage everything",
  unstage_all = "Unstage everything",
  discard = "Discard changes (confirm); on a stash: drop it",
  stash = "Stash staged changes / files / everything; on a stash: apply, pop, drop",
  commit_menu = "Commit / amend (menu; on a commit of the log also fixup / squash / reword / drop it); a merge, rebase, … going on: continue / skip / abort",
  commit = "Commit (the message in a window: :wq commits, :q! aborts); a merge, rebase, … going on: continue",
  commit_amend = "Amend the last commit (git commit --amend)",
  fixup_commit = "Fixup: what is staged into the commit under the cursor (a fixup! commit moved after it)",
  squash_commit = "Squash the commit under the cursor into its parent (both messages to edit)",
  reword_commit = "Reword the commit under the cursor",
  drop_commit = "Drop the commit under the cursor (asks)",
  fetch = "git fetch",
  pull = "git pull (your git config decides how)",
  push = "git push (no upstream: set it; rejected: --force-with-lease, asked)",
  branch = "Switch branch (git switch; a new branch; changes in the way: stash, switch, pop)",
  take_local_file = "Conflict: take LOCAL (ours) for the whole file",
  take_remote_file = "Conflict: take REMOTE (theirs) for the whole file",
  toggle_tree = "Toggle tree / list",
  refresh = "Refresh",
  close = "Close the view",
  mark = "Mark commit for comparison (two marks: git diff A B)",
  clear_marks = "Clear marks",
  toggle_range_mode = "Toggle A B / A...B (merge base)",
  cycle_parent = "Cycle parent of a merge commit",
  commit_details = "Commit details",
  yank_hash = "Yank commit hash",
  checkout = "Check out the commit: its branch, else asks how (Working tree / Index row: switch branch)",
  toggle_first_parent = "Toggle --first-parent",
  toggle_all_branches = "Toggle all branches / HEAD only",
  filter = "Filter log (git log arguments)",
}

-- what an action does in one group only
M.group_descriptions = {
  log_panel = {
    select = "Show the row (visual: the combined changes of the rows)",
    refresh = "Reload the log (and the status)",
  },
}

-- actions that also make sense in visual mode
M.visual = {
  toggle_stage_hunk = true,
  toggle_stage_line = true,
  discard_change = true,
  select = true,
  toggle_stage = true,
  stash = true,
}

---@type table<integer, { mode: string, lhs: string, saved?: table, desc: string, group: string, action?: string }[]>
local records = {}

--- The key of `action` in `group` (the shortest, if several), for hints; nil: none.
function M.key_for(group, action)
  local found
  for lhs, a in pairs(config.options.keymaps[group] or {}) do
    if a == action and (not found or #lhs < #found or (#lhs == #found and lhs < found)) then
      found = lhs
    end
  end
  return found
end

--- Sets buffer-local mappings for `group` from the config.
---@param handler fun(action: string, ctx: table)
function M.apply(buf, group, handler, filter)
  local maps = config.options.keymaps[group] or {}
  records[buf] = records[buf] or {}
  -- (as typed: <leader> as yours)
  local function typed_keys(lhs)
    local leader = vim.g.mapleader or "\\"
    return api.nvim_replace_termcodes(
      lhs:gsub("<[Ll]eader>", function()
        return leader
      end),
      true,
      false,
      true
    )
  end
  -- a key that longer ones start with (c: cc, ca) waits for them ('timeoutlen')
  local function starts_others(lhs)
    local keys = typed_keys(lhs)
    for other, a in pairs(maps) do
      if a and other ~= lhs and vim.startswith(typed_keys(other), keys) then
        return true
      end
    end
    return false
  end
  local function record_of(mode, lhs)
    for i, r in ipairs(records[buf]) do
      if r.mode == mode and r.lhs == lhs then
        return r, i
      end
    end
  end
  for lhs, action in pairs(maps) do
    if action == false then
      -- off here, also when another group of this buffer maps it
      for _, mode in ipairs({ "n", "x" }) do
        local r, i = record_of(mode, lhs)
        if r and r.group ~= group then
          pcall(vim.keymap.del, mode, lhs, { buffer = buf })
          if r.saved then
            pcall(api.nvim_buf_call, buf, function()
              vim.fn.mapset(mode, false, r.saved)
            end)
          end
          table.remove(records[buf], i)
        end
      end
    elseif action and (not filter or type(action) ~= "string" or filter(action)) then
      local modes = { "n" }
      if type(action) == "string" and M.visual[action] then
        modes = { "n", "x" }
      end
      local desc = "DiffMerge custom"
      if type(action) == "string" then
        desc = (M.group_descriptions[group] or {})[action] or M.descriptions[action] or action
      end
      for _, mode in ipairs(modes) do
        local saved = vim.fn.maparg(lhs, mode, false, true)
        if type(saved) ~= "table" or saved.buffer ~= 1 then
          saved = nil
        end
        -- the buffer shown again, or the key of another group here: this one's action (and
        -- what was there before any of them)
        local r = record_of(mode, lhs)
        if r then
          r.desc, r.group, r.action = desc, group, type(action) == "string" and action or nil
        else
          table.insert(records[buf], {
            mode = mode,
            lhs = lhs,
            saved = saved,
            desc = desc,
            group = group,
            action = type(action) == "string" and action or nil,
          })
        end
        vim.keymap.set(mode, lhs, function()
          -- a real file buffer can also be open in an ordinary window of another tab:
          -- there the key keeps its normal meaning
          if not require("diffmerge.view").current() then
            local keys = api.nvim_replace_termcodes(lhs, true, false, true)
            if mode == "n" and vim.v.count > 0 then
              keys = vim.v.count .. keys
            end
            api.nvim_feedkeys(keys, "n", false)
            return
          end
          local ctx = { mode = mode, buf = buf, win = api.nvim_get_current_win() }
          if mode == "x" then
            local s, e = vim.fn.line("v"), vim.fn.line(".")
            ctx.range = { math.min(s, e), math.max(s, e) }
            api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
          end
          if type(action) == "function" then
            action(ctx)
          else
            handler(action, ctx)
          end
        end, { buffer = buf, nowait = not starts_others(lhs), silent = true, desc = "DiffMerge: " .. desc })
      end
    end
  end
end

--- Removes the mappings set by apply() and restores what was there before.
function M.clear(buf)
  local list = records[buf]
  records[buf] = nil
  if not list or not api.nvim_buf_is_valid(buf) then
    return
  end
  for i = #list, 1, -1 do
    local r = list[i]
    pcall(vim.keymap.del, r.mode, r.lhs, { buffer = buf })
    if r.saved then
      pcall(api.nvim_buf_call, buf, function()
        vim.fn.mapset(r.mode, false, r.saved)
      end)
    end
  end
end

function M.clear_group(buf, group)
  local list = records[buf]
  if not list or not api.nvim_buf_is_valid(buf) then
    return
  end
  local keep = {}
  for _, r in ipairs(list) do
    if r.group == group then
      pcall(vim.keymap.del, r.mode, r.lhs, { buffer = buf })
      if r.saved then
        pcall(api.nvim_buf_call, buf, function()
          vim.fn.mapset(r.mode, false, r.saved)
        end)
      end
    else
      keep[#keep + 1] = r
    end
  end
  records[buf] = keep
end

-- What `g?` shows, by function: the sections in this order, the lines of each in this order. The
-- actions of a line share it when all of them are mapped ("S  U  Stage / unstage everything");
-- "<group>:<action>": that action of one group (the log's <CR> shows a row).
local sections = {
  {
    "Files",
    { "select" },
    { "expand", "collapse", desc = "Expand / collapse (a directory, a section)" },
    { "toggle_tree" },
    { "next_file", "prev_file", desc = "Next / previous file" },
  },
  {
    "Staging",
    { "toggle_stage" },
    { "toggle_stage_hunk" },
    { "toggle_stage_line" },
    { "stage_all", "unstage_all", desc = "Stage / unstage everything" },
    { "discard" },
    { "discard_change" },
  },
  {
    "Conflicts",
    { "next_conflict", "prev_conflict", desc = "Next / previous conflict" },
    { "next_chunk", "prev_chunk", desc = "Next / previous change" },
    { "toggle_local", "toggle_base", "toggle_remote", desc = "Toggle LOCAL / BASE / REMOTE in the chunk" },
    { "take_none" },
    { "take_local_file", "take_remote_file", desc = "Take LOCAL / REMOTE for the whole file (resolved)" },
  },
  { "Stash", { "stash" } },
  {
    "Commit",
    { "commit_menu", "commit", "commit_amend", desc = "Commit: menu / commit / amend (a merge, rebase, … going on: menu / continue)" },
    { "fixup_commit" },
    { "squash_commit" },
    { "reword_commit" },
    { "drop_commit" },
  },
  { "Remote", { "fetch", "pull", "push", desc = "git fetch / pull / push (no upstream, rejected: asked)" } },
  { "Branches", { "branch" }, { "checkout" } },
  {
    "Log",
    { "log_panel:select" },
    { "mark", "clear_marks", desc = "Mark a row (two marks: git diff A B) / clear the marks" },
    { "toggle_range_mode" },
    { "cycle_parent" },
    { "toggle_first_parent" },
    { "toggle_all_branches" },
    { "filter" },
    { "commit_details" },
    { "yank_hash" },
  },
  {
    "View",
    { "toggle_files", "toggle_log", desc = "Show / hide the file panel / the log panel" },
    { "cycle_layout" },
    { "toggle_whitespace" },
    { "refresh" },
    { "close" },
    { "help" },
  },
}

-- what the window of a buffer with these groups of keys is called, and its own section (first)
local places = {
  { "file_panel", "file panel", "Files" },
  { "log_panel", "log panel", "Log" },
  { "merge", "merge", "Conflicts" },
  { "diff", "diff window", "Staging" },
}

--- Keys as typed: <leader> as yours.
local function typed(lhs)
  local leader = vim.g.mapleader or "\\"
  return (lhs:gsub("<[Ll]eader>", function()
    return leader == " " and "<Space>" or leader
  end))
end

local function key_order(a, b)
  if (a == "<CR>") ~= (b == "<CR>") then
    return a == "<CR>"
  end
  local wa, wb = vim.fn.strdisplaywidth(a), vim.fn.strdisplaywidth(b)
  if wa ~= wb then
    return wa < wb
  end
  return a < b
end

--- What the window of `buf` is called, for the help, and its own section.
local function place_of(buf)
  local groups = {}
  for _, r in ipairs(records[buf] or {}) do
    groups[r.group] = true
  end
  for _, p in ipairs(places) do
    if groups[p[1]] then
      return p[2], p[3]
    end
  end
  return "diff window", nil
end

--- The lines of the help of `buf`: { title } for a section, { keys, desc } for a line; the
--- section of the window first.
function M.help_lines(buf)
  local _, own = place_of(buf)
  local where = {}
  for si, sec in ipairs(sections) do
    for li = 2, #sec do
      for _, id in ipairs(sec[li]) do
        where[id] = { si, li }
      end
    end
  end
  local found, other, seen = {}, {}, {}
  for _, r in ipairs(records[buf] or {}) do
    local id = r.action and (where[r.group .. ":" .. r.action] and (r.group .. ":" .. r.action) or r.action)
    local at = id and where[id]
    if at then
      local line = found[at[1] .. ":" .. at[2]] or {}
      found[at[1] .. ":" .. at[2]] = line
      line[id] = line[id] or { keys = {}, desc = r.desc }
      if not vim.tbl_contains(line[id].keys, r.lhs) then
        table.insert(line[id].keys, r.lhs)
      end
    elseif not seen[r.lhs] then
      seen[r.lhs] = true
      other[#other + 1] = { typed(r.lhs), r.desc }
    end
  end
  local function keys_of(e)
    table.sort(e.keys, key_order)
    return table.concat(vim.tbl_map(typed, e.keys), " ")
  end
  local out, first = {}, {}
  local function section(title, lines)
    if #lines > 0 then
      local into = title == own and first or out
      into[#into + 1] = { title }
      vim.list_extend(into, lines)
    end
  end
  for si, sec in ipairs(sections) do
    local lines = {}
    for li = 2, #sec do
      local spec, got = sec[li], found[si .. ":" .. li]
      if got then
        local all = true
        for _, id in ipairs(spec) do
          all = all and got[id] ~= nil
        end
        if all and #spec > 1 then
          local keys = {}
          for _, id in ipairs(spec) do
            keys[#keys + 1] = keys_of(got[id])
          end
          lines[#lines + 1] = { table.concat(keys, "  "), spec.desc }
        else
          for _, id in ipairs(spec) do
            if got[id] then
              lines[#lines + 1] = { keys_of(got[id]), got[id].desc }
            end
          end
        end
      end
    end
    section(sec[1], lines)
  end
  section("Other", other)
  return vim.list_extend(first, out)
end

--- Floating window listing the DiffMerge keys of `buf` (the window it is in), by function.
function M.help(buf)
  local place = place_of(buf)
  local rows = M.help_lines(buf)
  if #rows == 0 then
    vim.notify("DiffMerge: no keys of it here", vim.log.levels.INFO)
    return
  end
  local key = M.key_for("view", "help") or "g?"
  local width = 0
  for _, row in ipairs(rows) do
    if row[2] then
      width = math.max(width, vim.fn.strdisplaywidth(row[1]))
    end
  end
  local lines, titles = {}, {}
  for _, row in ipairs(rows) do
    if not row[2] then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = " " .. row[1]
      titles[#lines] = true
    else
      lines[#lines + 1] = ("   %s%s  %s"):format(row[1], string.rep(" ", width - vim.fn.strdisplaywidth(row[1])), row[2])
    end
  end
  local hbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(hbuf, 0, -1, false, lines)
  vim.bo[hbuf].modifiable = false
  vim.bo[hbuf].bufhidden = "wipe"
  local w = 0
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(l))
  end
  local height = math.min(#lines, vim.o.lines - 6)
  local win = api.nvim_open_win(hbuf, true, {
    relative = "editor",
    width = math.min(w + 2, vim.o.columns - 4),
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - w) / 2),
    style = "minimal",
    border = "rounded",
    title = (" %s · %s "):format(place, typed(key)),
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  local ns = api.nvim_create_namespace("diffmerge_help")
  for i in pairs(titles) do
    api.nvim_buf_set_extmark(hbuf, ns, i - 1, 0, { end_col = #lines[i], hl_group = "DiffMergeTitle" })
  end
  for _, close in ipairs({ "q", "<Esc>", key }) do
    vim.keymap.set("n", close, function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end, { buffer = hbuf, nowait = true })
  end
  api.nvim_create_autocmd("WinLeave", {
    buffer = hbuf,
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })
end

return M
