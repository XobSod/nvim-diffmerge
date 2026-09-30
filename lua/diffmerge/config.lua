local M = {}

---@class diffmerge.Config
M.defaults = {
  layout = {
    -- 2-way diffs: "side_by_side" | "stacked"
    diff = "side_by_side",
    -- merges: "side_by_side" (mine | merged | other) | "stacked" | "four_way" (mine | base | other / merged)
    merge = "side_by_side",
  },
  file_panel = {
    width = 30,
    tree = true, -- false: flat list of paths
    show_stats = true, -- "+12 -3" next to files
  },
  log_panel = {
    height = 15,
  },
  log = {
    -- git pretty format of a commit line (colours allowed). Default: short hash, refs, subject, author, date.
    format = "%<|(15)%C(yellow)%h%C(reset) %C(auto)%d%C(reset) %s %C(240)by %an%C(reset) %C(244)%ad(%ar)%C(reset)",
    date = "format:%Y-%m-%d %H:%M:%S",
    all_branches = true, -- :DiffMerge log shows --branches --remotes
    history_all_branches = false, -- :DiffMerge history (file/directory) shows only HEAD
    first_parent = false,
    follow_renames = true, -- --follow for single-file history
    max_count = nil, -- limit the number of commits (nil: everything, streamed)
  },
  diff = {
    -- algorithm used by DiffMerge's own diffs (merge chunks, hunk staging).
    -- The native diff windows use 'diffopt'.
    algorithm = "histogram",
  },
  merge = {
    virtual_text = true, -- conflict hints at the end of the first line of a conflict
  },
  status = {
    -- tracked files open as HEAD | WORKING TREE | INDEX (only the columns that differ; a column
    -- appears as soon as staging needs it). false: separate Staged (HEAD | INDEX) and
    -- Unstaged (INDEX | WORKING TREE) diffs.
    three_way = true,
  },
  auto_preview = true, -- moving the cursor in a panel shows the entry under it
  preview_debounce = 80, -- ms
  watch = true, -- refresh status views on changes inside the git dir
  icons = {
    -- file and folder icons come from mini.icons
    -- (files also from nvim-web-devicons) when installed
    folder_closed = "▸",
    folder_open = "▾",
    expander_closed = "▸", -- sections
    expander_open = "▾",
    mark_from = "A",
    mark_to = "B",
  },
  -- Buffer-local keymaps. Keys are lhs, values are action names (see :h diffmerge-actions),
  -- functions, or false to disable a default.
  keymaps = {
    -- every window of a view (panels and diff windows)
    view = {
      ["]f"] = "next_file",
      ["[f"] = "prev_file",
      ["gl"] = "cycle_layout",
      ["<leader>W"] = "toggle_whitespace",
      ["g?"] = "help",
    },
    -- diff windows of status views (staging)
    diff = {
      ["-"] = "toggle_stage_hunk",
      ["<Space>"] = "toggle_stage_line",
    },
    -- windows of a merge layout
    merge = {
      ["<leader>1"] = "toggle_local",
      ["<leader>2"] = "toggle_base",
      ["<leader>3"] = "toggle_remote",
      ["<leader>0"] = "take_none",
      ["dp"] = "put_side",
      ["]x"] = "next_conflict",
      ["[x"] = "prev_conflict",
      ["]c"] = "next_chunk",
      ["[c"] = "prev_chunk",
    },
    file_panel = {
      ["<CR>"] = "select",
      ["o"] = "select",
      ["l"] = "expand",
      ["h"] = "collapse",
      ["-"] = "toggle_stage",
      ["<Space>"] = "toggle_stage",
      ["S"] = "stage_all",
      ["U"] = "unstage_all",
      ["X"] = "discard",
      ["i"] = "toggle_tree",
      ["R"] = "refresh",
      ["q"] = "close",
    },
    log_panel = {
      ["<CR>"] = "select",
      ["m"] = "mark",
      ["M"] = "clear_marks",
      ["t"] = "toggle_range_mode",
      ["P"] = "cycle_parent",
      ["K"] = "commit_details",
      ["Y"] = "yank_hash",
      ["F"] = "toggle_first_parent",
      ["a"] = "toggle_all_branches",
      ["f"] = "filter",
      ["R"] = "refresh",
      ["q"] = "close",
    },
  },
}

---@type diffmerge.Config
M.options = vim.deepcopy(M.defaults)

local layouts = {
  diff = { side_by_side = true, stacked = true },
  merge = { side_by_side = true, stacked = true, four_way = true },
}

---@return string[] errors
function M.validate(opts)
  local errors = {}
  if not layouts.diff[opts.layout.diff] then
    errors[#errors + 1] = ("layout.diff: unknown layout %q (side_by_side, stacked)"):format(tostring(opts.layout.diff))
  end
  if not layouts.merge[opts.layout.merge] then
    errors[#errors + 1] = ("layout.merge: unknown layout %q (side_by_side, stacked, four_way)"):format(
      tostring(opts.layout.merge)
    )
  end
  if type(opts.file_panel.width) ~= "number" or opts.file_panel.width < 10 then
    errors[#errors + 1] = "file_panel.width: must be a number >= 10"
  end
  if type(opts.log_panel.height) ~= "number" or opts.log_panel.height < 3 then
    errors[#errors + 1] = "log_panel.height: must be a number >= 3"
  end
  return errors
end

M.errors = {}

function M.setup(opts)
  opts = opts or {}
  -- keymap tables are merged per key so users can add/disable single mappings
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  M.errors = M.validate(M.options)
  if #M.errors > 0 then
    vim.notify("DiffMerge: invalid config:\n" .. table.concat(M.errors, "\n"), vim.log.levels.ERROR)
    for _, key in ipairs({ "diff", "merge" }) do
      if not layouts[key][M.options.layout[key]] then
        M.options.layout[key] = M.defaults.layout[key]
      end
    end
  end
  return M.options
end

function M.layouts(kind)
  -- "diff" and "stage" (status view columns) share the 2-way names
  if kind == "merge" then
    return { "side_by_side", "stacked", "four_way" }
  end
  return { "side_by_side", "stacked" }
end

return M
