--- File panel: sections of entries shown as a tree or a flat list.
local config = require("diffmerge.config")
local util = require("diffmerge.util")

local api = vim.api
local ns = api.nvim_create_namespace("diffmerge_files")

local M = {}

---@class diffmerge.Section
---@field id string
---@field title string
---@field hint? string equivalent git command
---@field entries diffmerge.Entry[]

---@class diffmerge.FilePanel
---@field view table
---@field buf integer
---@field items table<integer, table> line (1-based) -> item
---@field sections diffmerge.Section[]
---@field collapsed table<string, boolean>
---@field tree boolean
local Panel = {}
Panel.__index = Panel

local status_hl = {
  A = "DiffMergeStatusAdded",
  M = "DiffMergeStatusModified",
  D = "DiffMergeStatusDeleted",
  R = "DiffMergeStatusRenamed",
  C = "DiffMergeStatusRenamed",
  T = "DiffMergeStatusModified",
  U = "DiffMergeStatusUnmerged",
  ["?"] = "DiffMergeStatusUntracked",
  ["!"] = "DiffMergeStatusUnmerged",
}

local function file_icon(name)
  if _G.MiniIcons or package.loaded["mini.icons"] or pcall(require, "mini.icons") then
    local ok, icon, hl = pcall(function()
      return require("mini.icons").get("file", name)
    end)
    if ok and icon then
      return icon, hl
    end
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok and devicons.get_icon then
    local icon, hl = devicons.get_icon(name, vim.fn.fnamemodify(name, ":e"), { default = true })
    return icon, hl
  end
  return nil
end

local function dir_icon(name)
  if _G.MiniIcons or package.loaded["mini.icons"] or pcall(require, "mini.icons") then
    local ok, icon, hl = pcall(function()
      return require("mini.icons").get("directory", name)
    end)
    if ok and icon then
      return icon, hl
    end
  end
  return nil
end

function M.new(view)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "diffmerge-files"
  vim.bo[buf].modifiable = false
  M.count = (M.count or 0) + 1
  pcall(api.nvim_buf_set_name, buf, M.count == 1 and "DiffMerge" or ("DiffMerge (" .. M.count .. ")"))
  local self = setmetatable({
    view = view,
    buf = buf,
    items = {},
    sections = {},
    collapsed = {},
    tree = config.options.file_panel.tree,
    title = "",
  }, Panel)
  return self
end

--- Sets the content; call render() afterwards.
---@param data { title: string, subtitle?: string, sections: diffmerge.Section[], empty_text?: string }
function Panel:set_data(data)
  self.title = data.title or ""
  self.subtitle = data.subtitle
  self.sections = data.sections or {}
  self.empty_text = data.empty_text
end

local function build_tree(entries)
  local root = { name = "", path = "", dirs = {}, dir_order = {}, files = {} }
  for _, e in ipairs(entries) do
    local parts = vim.split(e.path, "/", { plain = true })
    local node = root
    for i = 1, #parts - 1 do
      local name = parts[i]
      local child = node.dirs[name]
      if not child then
        child = {
          name = name,
          path = node.path == "" and name or (node.path .. "/" .. name),
          dirs = {},
          dir_order = {},
          files = {},
        }
        node.dirs[name] = child
        node.dir_order[#node.dir_order + 1] = name
      end
      node = child
    end
    node.files[#node.files + 1] = e
  end
  -- compress chains of single directories ("lua/diffmerge")
  local function compress(node)
    for _, name in ipairs(node.dir_order) do
      local child = node.dirs[name]
      while #child.files == 0 and #child.dir_order == 1 do
        local only = child.dirs[child.dir_order[1]]
        only.name = child.name .. "/" .. only.name
        child = only
      end
      node.dirs[name] = child
      compress(child)
    end
  end
  compress(root)
  return root
end

local function sorted_dirs(node)
  local list = {}
  for _, name in ipairs(node.dir_order) do
    list[#list + 1] = node.dirs[name]
  end
  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return list
end

local function sorted_files(files)
  local list = vim.list_slice(files)
  table.sort(list, function(a, b)
    return a.path:lower() < b.path:lower()
  end)
  return list
end

--- Entries of a section in display order.
function Panel:ordered_entries(section)
  if not self.tree then
    return sorted_files(section.entries)
  end
  local out = {}
  local function walk(node)
    for _, d in ipairs(sorted_dirs(node)) do
      walk(d)
    end
    for _, f in ipairs(sorted_files(node.files)) do
      out[#out + 1] = f
    end
  end
  walk(build_tree(section.entries))
  return out
end

--- All entries in display order (for ]f / [f), skipping collapsed sections/dirs is not needed.
function Panel:all_entries()
  local out = {}
  for _, s in ipairs(self.sections) do
    util.extend(out, self:ordered_entries(s))
  end
  return out
end

function Panel:render()
  local lines, hls, items = {}, {}, {}
  local function add(line, item, marks)
    lines[#lines + 1] = line
    items[#lines] = item
    for _, m in ipairs(marks or {}) do
      hls[#hls + 1] = { #lines - 1, m[1], m[2], m[3] }
    end
  end
  local current = self.view.current
  local current_line

  add(" " .. self.title, { kind = "header" }, { { 0, #self.title + 1, "DiffMergeTitle" } })
  if self.subtitle and self.subtitle ~= "" then
    add(" " .. self.subtitle, { kind = "header" }, { { 0, #self.subtitle + 1, "DiffMergeHint" } })
  end
  local total = 0
  for _, s in ipairs(self.sections) do
    total = total + #s.entries
  end
  if total == 0 then
    add("", { kind = "blank" })
    local t = "  " .. (self.empty_text or "No changes")
    add(t, { kind = "blank" }, { { 0, #t, "DiffMergeDim" } })
  end

  local function file_line(section, e, indent, show_dir)
    local st = e.status or " "
    local name = show_dir and util.basename(e.path) or util.basename(e.path)
    local icon, icon_hl = file_icon(util.basename(e.path))
    local parts = { indent, st, " " }
    local marks = {}
    local col = #indent
    marks[#marks + 1] = { col, col + #st, status_hl[st] or "DiffMergeFile" }
    col = col + #st + 1
    if icon then
      parts[#parts + 1] = icon .. " "
      marks[#marks + 1] = { col, col + #icon, icon_hl }
      col = col + #icon + 1
    end
    parts[#parts + 1] = name
    local name_hl = e == current and "DiffMergeCurrent" or "DiffMergeFile"
    marks[#marks + 1] = { col, col + #name, name_hl }
    col = col + #name
    if show_dir then
      local dir = util.dirname(e.path)
      if dir ~= "" then
        parts[#parts + 1] = " " .. dir
        marks[#marks + 1] = { col + 1, col + 1 + #dir, "DiffMergeDim" }
        col = col + 1 + #dir
      end
    end
    if e.oldpath and e.oldpath ~= e.path then
      local t = " ← " .. (self.tree and util.basename(e.oldpath) or e.oldpath)
      parts[#parts + 1] = t
      marks[#marks + 1] = { col, col + #t, "DiffMergeDim" }
      col = col + #t
    end
    if e.note then
      local t = " " .. e.note
      parts[#parts + 1] = t
      marks[#marks + 1] = { col, col + #t, e.note_hl or "DiffMergeDim" }
      col = col + #t
    end
    if config.options.file_panel.show_stats and e.stats then
      if e.stats.binary then
        parts[#parts + 1] = " bin"
        marks[#marks + 1] = { col + 1, col + 4, "DiffMergeDim" }
      else
        if e.stats.added and e.stats.added > 0 then
          local t = " +" .. e.stats.added
          parts[#parts + 1] = t
          marks[#marks + 1] = { col + 1, col + #t, "DiffMergeStatAdd" }
          col = col + #t
        end
        if e.stats.deleted and e.stats.deleted > 0 then
          local t = " -" .. e.stats.deleted
          parts[#parts + 1] = t
          marks[#marks + 1] = { col + 1, col + #t, "DiffMergeStatDel" }
          col = col + #t
        end
      end
    end
    add(table.concat(parts), { kind = "file", section = section, entry = e }, marks)
    if e == current then
      current_line = #lines
    end
  end

  for _, section in ipairs(self.sections) do
    if #section.entries > 0 or section.always then
      add("", { kind = "blank" })
      local collapsed = self.collapsed[section.id]
      local exp = collapsed and config.options.icons.expander_closed or config.options.icons.expander_open
      local head = (" %s %s"):format(exp, section.title)
      local count = (" %d"):format(#section.entries)
      local hint = section.hint and ("  " .. section.hint) or ""
      add(head .. count .. hint, { kind = "section", section = section }, {
        { 1, 1 + #exp, "DiffMergeDim" },
        { 2 + #exp, #head, "DiffMergeSection" },
        { #head, #head + #count, "DiffMergeCount" },
        { #head + #count, #head + #count + #hint, "DiffMergeHint" },
      })
      if not collapsed then
        if self.tree then
          local function walk(node, depth)
            local indent = string.rep("  ", depth)
            for _, d in ipairs(sorted_dirs(node)) do
              local key = section.id .. ":" .. d.path
              local dcollapsed = self.collapsed[key]
              local exp = dcollapsed and config.options.icons.folder_closed or config.options.icons.folder_open
              local marks = { { #indent, #indent + #exp, "DiffMergeDim" } }
              local col = #indent + #exp + 1
              local prefix = indent .. exp .. " "
              local icon, icon_hl = dir_icon(d.name)
              if icon then
                prefix = prefix .. icon .. " "
                marks[#marks + 1] = { col, col + #icon, icon_hl or "DiffMergeDir" }
                col = col + #icon + 1
              end
              local line = prefix .. d.name
              marks[#marks + 1] = { col, #line, "DiffMergeDir" }
              add(line, { kind = "dir", section = section, node = d, key = key }, marks)
              if not dcollapsed then
                walk(d, depth + 1)
              end
            end
            for _, f in ipairs(sorted_files(node.files)) do
              file_line(section, f, indent, false)
            end
          end
          walk(build_tree(section.entries), 1)
        else
          for _, f in ipairs(sorted_files(section.entries)) do
            file_line(section, f, "  ", true)
          end
        end
      end
    end
  end

  util.set_lines(self.buf, lines)
  api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    if h[4] then
      pcall(api.nvim_buf_set_extmark, self.buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
    end
  end
  if current_line then
    api.nvim_buf_set_extmark(self.buf, ns, current_line - 1, 0, { line_hl_group = "DiffMergeCurrentLine" })
  end
  self.items = items
  self.current_line = current_line
end

function Panel:item_at(line)
  return self.items[line]
end

--- Line of an entry (expands collapsed parents when `reveal`).
function Panel:line_of(entry)
  for l, item in pairs(self.items) do
    if item.kind == "file" and item.entry == entry then
      return l
    end
  end
end

function Panel:reveal(entry)
  local changed = false
  for _, s in ipairs(self.sections) do
    for _, e in ipairs(s.entries) do
      if e == entry then
        if self.collapsed[s.id] then
          self.collapsed[s.id] = nil
          changed = true
        end
        local dir = util.dirname(e.path)
        for key in pairs(self.collapsed) do
          local d = key:match("^" .. vim.pesc(s.id) .. ":(.*)$")
          if d and (dir == d or vim.startswith(dir, d .. "/")) then
            self.collapsed[key] = nil
            changed = true
          end
        end
      end
    end
  end
  if changed then
    self:render()
  end
end

function Panel:win()
  local wins = vim.fn.win_findbuf(self.buf)
  for _, w in ipairs(wins) do
    if api.nvim_win_get_tabpage(w) == self.view.layout.tab then
      return w
    end
  end
end

function Panel:set_cursor_to(entry)
  local win = self:win()
  local line = self:line_of(entry)
  if win and line then
    self.moving = true
    pcall(api.nvim_win_set_cursor, win, { line, 0 })
    self.moving = false
  end
end

function Panel:first_file_line()
  for l = 1, #self.items do
    local item = self.items[l]
    if item and item.kind == "file" then
      return l
    end
  end
end

function Panel:toggle_collapse(item)
  if item.kind == "section" then
    self.collapsed[item.section.id] = not self.collapsed[item.section.id] or nil
  elseif item.kind == "dir" then
    self.collapsed[item.key] = not self.collapsed[item.key] or nil
  end
  self:render()
end

--- Entries below an item (file: itself, dir: all files under it, section: all).
function Panel:entries_of(item)
  if item.kind == "file" then
    return { item.entry }
  elseif item.kind == "section" then
    return item.section.entries
  elseif item.kind == "dir" then
    local out = {}
    for _, e in ipairs(item.section.entries) do
      if vim.startswith(e.path, item.node.path .. "/") then
        out[#out + 1] = e
      end
    end
    return out
  end
  return {}
end

M.Panel = Panel
return M
