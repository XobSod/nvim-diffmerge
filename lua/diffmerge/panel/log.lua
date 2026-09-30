--- Log panel: `git log --graph` streamed into a buffer, with git's own colours, plus the
--- Working tree / Index pseudo rows at the top.
local ansi = require("diffmerge.ansi")
local git = require("diffmerge.git")
local highlights = require("diffmerge.highlights")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("diffmerge_log")
local ns_marks = api.nvim_create_namespace("diffmerge_log_marks")

---@type table<integer, diffmerge.LogPanel>
local panels = {}

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    return panels[buf] ~= nil
  end,
  on_line = function(_, _, buf, row)
    local panel = panels[buf]
    local r = panel and panel.rows[row + 1]
    if not r or not r.spans then
      return
    end
    for _, s in ipairs(r.spans) do
      api.nvim_buf_set_extmark(buf, ns, row, s[1], { end_col = s[2], hl_group = s[3], ephemeral = true })
    end
  end,
})

---@class diffmerge.LogRow
---@field kind "commit"|"graph"|"worktree"|"index"|"message"
---@field sha? string
---@field parents? string[]
---@field spans? table

---@class diffmerge.LogPanel
---@field buf integer
---@field rows diffmerge.LogRow[]
---@field by_sha table<string, integer> sha -> row
local Panel = {}
Panel.__index = Panel

function M.new(view)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "diffmerge-log"
  vim.bo[buf].modifiable = false
  M.count = (M.count or 0) + 1
  pcall(api.nvim_buf_set_name, buf, M.count == 1 and "DiffMerge log" or ("DiffMerge log (" .. M.count .. ")"))
  local self = setmetatable({ view = view, buf = buf, rows = {}, by_sha = {} }, Panel)
  panels[buf] = self
  return self
end

function Panel:destroy()
  if self.job then
    self.job.kill()
    self.job = nil
  end
  panels[self.buf] = nil
  if api.nvim_buf_is_valid(self.buf) then
    pcall(api.nvim_buf_delete, self.buf, { force = true })
  end
end

local function to_spans(spans)
  local out = {}
  for _, s in ipairs(spans) do
    out[#out + 1] = { s[1], s[2], highlights.ansi_group(s[3]) }
  end
  return out
end

--- Parses one line of `git log --graph --format=<fmt>%x1f%H%x1f%P`.
function M.parse_line(raw)
  local vis, meta = raw:match("^(.-)\31(.*)$")
  if not vis then
    local text, spans = ansi.parse(raw)
    return text, { kind = "graph", spans = to_spans(spans) }
  end
  meta = ansi.parse(meta)
  local sha, parents = meta:match("^(%x+)\31?(.*)$")
  local text, spans = ansi.parse(vis)
  text = text:gsub("%s+$", "")
  return text,
    {
      kind = "commit",
      sha = sha,
      parents = vim.split(vim.trim(parents or ""), " ", { trimempty = true }),
      spans = to_spans(spans),
    }
end

--- Pseudo rows (working tree / index) with their change counts.
function Panel:pseudo_rows(counts)
  local function row(kind, label, info)
    local icon = kind == "worktree" and "◎ " or "◉ "
    local text = icon .. label .. (info ~= "" and ("  " .. info) or "")
    return text,
      {
        kind = kind,
        spans = {
          { 0, #icon + #label, "DiffMergePseudo" },
          { #icon + #label, #text, "DiffMergeDim" },
        },
      }
  end
  local wt_info = {}
  if (counts.conflicts or 0) > 0 then
    wt_info[#wt_info + 1] = counts.conflicts .. " conflicted"
  end
  if counts.unstaged > 0 then
    wt_info[#wt_info + 1] = counts.unstaged .. " unstaged"
  end
  if counts.untracked > 0 then
    wt_info[#wt_info + 1] = counts.untracked .. " untracked"
  end
  local t1, r1 = row("worktree", "Working tree", #wt_info > 0 and table.concat(wt_info, " · ") or "clean")
  local t2, r2 = row("index", "Index", counts.staged > 0 and (counts.staged .. " staged") or "nothing staged")
  return { t1, t2 }, { r1, r2 }
end

--- Starts (or restarts) loading the log.
---@param args string[] full git arguments
---@param pseudo? { unstaged: integer, staged: integer, untracked: integer }
---@param on_batch? fun(first: integer, last: integer) rows added
---@param on_done? fun(ok: boolean, err?: string)
function Panel:load(repo, args, pseudo, on_batch, on_done)
  if self.job then
    self.job.kill()
    self.job = nil
  end
  self.rows = {}
  self.by_sha = {}
  self.loading = true
  local lines = {}
  if pseudo then
    local l, r = self:pseudo_rows(pseudo)
    lines = l
    self.rows = r
  end
  util.set_lines(self.buf, #lines > 0 and lines or { "  loading…" })
  if #lines == 0 then
    self.rows = { { kind = "message" } }
    self.placeholder = true
  end
  self.job = git.stream(repo, args, {}, function(batch)
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end
    local texts = {}
    local start = #self.rows
    if self.placeholder then
      start = 0
      self.rows = {}
    end
    for _, raw in ipairs(batch) do
      local text, row = M.parse_line(raw)
      texts[#texts + 1] = text
      self.rows[#self.rows + 1] = row
      if row.sha then
        self.by_sha[row.sha] = #self.rows
      end
    end
    if self.placeholder then
      util.set_lines(self.buf, texts, 0, -1)
      self.placeholder = false
    else
      util.set_lines(self.buf, texts, start, start)
    end
    if on_batch then
      on_batch(start + 1, #self.rows)
    end
  end, function(res)
    self.loading = false
    self.job = nil
    if not api.nvim_buf_is_valid(self.buf) then
      return
    end
    if self.placeholder then
      local msg = res.ok and "  (no commits)" or ("  " .. vim.trim(res.stderr))
      util.set_lines(self.buf, vim.split(msg, "\n", { plain = true }))
      self.rows = { { kind = "message" } }
    end
    if on_done then
      on_done(res.ok, res.stderr)
    end
  end)
end

function Panel:row(line)
  return self.rows[line]
end

function Panel:win()
  for _, w in ipairs(vim.fn.win_findbuf(self.buf)) do
    if api.nvim_win_get_tabpage(w) == self.view.layout.tab then
      return w
    end
  end
end

--- Draws marks (A / B) and the selected range.
---@param marks { line: integer, label: string }[]
---@param range? integer[] { first, last }
function Panel:draw_marks(marks, range)
  api.nvim_buf_clear_namespace(self.buf, ns_marks, 0, -1)
  if range then
    for l = range[1], range[2] do
      local r = self.rows[l]
      if r and r.kind ~= "graph" then
        api.nvim_buf_set_extmark(self.buf, ns_marks, l - 1, 0, { line_hl_group = "DiffMergeRangeLine" })
      end
    end
  end
  for _, m in ipairs(marks) do
    if m.line <= api.nvim_buf_line_count(self.buf) then
      api.nvim_buf_set_extmark(self.buf, ns_marks, m.line - 1, 0, {
        sign_text = m.label,
        sign_hl_group = "DiffMergeMarkSign",
        line_hl_group = "DiffMergeMarkLine",
      })
    end
  end
end

function Panel:set_winbar(text)
  local win = self:win()
  if win then
    vim.wo[win].winbar = "%#DiffMergeWinbarLabel# " .. text:gsub("%%", "%%%%") .. "%*"
  end
end

M.Panel = Panel
M.ns = ns
return M
