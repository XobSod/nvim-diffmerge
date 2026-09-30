--- Buffer-local keymaps with save/restore (real file buffers get their own mappings back
--- when a view closes) and the `g?` help window.
local config = require("diffmerge.config")

local api = vim.api
local M = {}

M.descriptions = {
  next_file = "Next file",
  prev_file = "Previous file",
  cycle_layout = "Cycle layout",
  toggle_whitespace = "Toggle ignoring whitespace changes (diffopt iwhite)",
  help = "Show keymaps",
  toggle_stage_hunk = "Stage / unstage hunk (visual: selected lines)",
  toggle_stage_line = "Stage / unstage the line under the cursor (visual: selected lines)",
  toggle_local = "Toggle LOCAL (mine) in the chunk",
  toggle_base = "Toggle BASE in the chunk",
  toggle_remote = "Toggle REMOTE (theirs) in the chunk",
  take_none = "Resolve the chunk with nothing",
  put_side = "Put this side into MERGED (replaces the chunk)",
  next_conflict = "Next conflict",
  prev_conflict = "Previous conflict",
  next_chunk = "Next change",
  prev_chunk = "Previous change",
  select = "Open / select (log, visual: combined changes)",
  expand = "Open file / expand directory",
  collapse = "Collapse directory",
  toggle_stage = "Stage / unstage (file, directory, section)",
  stage_all = "Stage everything",
  unstage_all = "Unstage everything",
  discard = "Discard changes (confirm)",
  toggle_tree = "Toggle tree / list",
  refresh = "Refresh",
  close = "Close the view",
  mark = "Mark commit for comparison (two marks: git diff A B)",
  clear_marks = "Clear marks",
  toggle_range_mode = "Toggle A B / A...B (merge base)",
  cycle_parent = "Cycle parent of a merge commit",
  commit_details = "Commit details",
  yank_hash = "Yank commit hash",
  toggle_first_parent = "Toggle --first-parent",
  toggle_all_branches = "Toggle all branches / HEAD only",
  filter = "Filter log (git log arguments)",
}

-- actions that also make sense in visual mode
M.visual = {
  toggle_stage_hunk = true,
  toggle_stage_line = true,
  select = true,
  toggle_stage = true,
}

---@type table<integer, { mode: string, lhs: string, saved?: table, desc: string }[]>
local records = {}

--- Sets buffer-local mappings for `group` from the config.
---@param handler fun(action: string, ctx: table)
function M.apply(buf, group, handler, filter)
  local maps = config.options.keymaps[group] or {}
  records[buf] = records[buf] or {}
  for lhs, action in pairs(maps) do
    if action and (not filter or type(action) ~= "string" or filter(action)) then
      local modes = { "n" }
      if type(action) == "string" and M.visual[action] then
        modes = { "n", "x" }
      end
      local desc = type(action) == "string" and (M.descriptions[action] or action) or "DiffMerge custom"
      for _, mode in ipairs(modes) do
        local saved = vim.fn.maparg(lhs, mode, false, true)
        if type(saved) ~= "table" or saved.buffer ~= 1 then
          saved = nil
        end
        -- do not stack our own mappings (same buffer shown again)
        local already = false
        for _, r in ipairs(records[buf]) do
          if r.mode == mode and r.lhs == lhs then
            already = true
            break
          end
        end
        if not already then
          table.insert(records[buf], { mode = mode, lhs = lhs, saved = saved, desc = desc, group = group })
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
        end, { buffer = buf, nowait = true, silent = true, desc = "DiffMerge: " .. desc })
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

--- Floating window listing the DiffMerge mappings of the current buffer.
function M.help(buf)
  local list = records[buf] or {}
  local seen, lines = {}, { " DiffMerge keymaps", "" }
  local items = {}
  for _, r in ipairs(list) do
    local key = r.lhs .. r.desc
    if not seen[key] then
      seen[key] = true
      items[#items + 1] = r
    end
  end
  table.sort(items, function(a, b)
    if a.group ~= b.group then
      return a.group < b.group
    end
    return a.lhs < b.lhs
  end)
  local width = 0
  for _, r in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(r.lhs))
  end
  local group
  for _, r in ipairs(items) do
    if r.group ~= group then
      group = r.group
      if #lines > 2 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = " " .. group:gsub("_", " ")
    end
    local lhs = r.lhs:gsub("<leader>", vim.g.mapleader and ("<leader>(" .. vim.g.mapleader .. ")") or "<leader>")
    lines[#lines + 1] = ("   %s  %s"):format(lhs .. string.rep(" ", width - vim.fn.strdisplaywidth(r.lhs)), r.desc)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " Native diff keys keep working: do / dp / ]c / [c (2-way)"
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
    title = " g? ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = false
  local ns = api.nvim_create_namespace("diffmerge_help")
  for i, l in ipairs(lines) do
    if l:match("^ %S") then
      api.nvim_buf_set_extmark(hbuf, ns, i - 1, 0, { end_col = #l, hl_group = "DiffMergeTitle" })
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, function()
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
