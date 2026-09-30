--- Sides of a comparison ("sources") and the buffers that display them.
---
--- Buffers are shared between views through a reference-counted registry:
--- git revisions are unlisted scratch buffers, the index is an `acwrite` buffer that writes
--- to the index, and working tree / plain files are the real file buffers.
local git = require("diffmerge.git")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

---@class diffmerge.Source
---@field kind "rev"|"index"|"stage"|"worktree"|"file"|"empty"
---@field rev? string object id of a commit or tree (kind "rev")
---@field stage? integer 1..3 (kind "stage")
---@field path? string repo-relative path
---@field abspath? string absolute path (kind "file")
---@field label? string short description for window bars
---@field readonly? boolean
---@field role? string used to keep "empty" buffers of different windows apart

function M.rev(rev, path, label)
  return { kind = "rev", rev = rev, path = path, label = label }
end

function M.index(path)
  return { kind = "index", path = path, label = "INDEX" }
end

function M.stage(n, path, label)
  return { kind = "stage", stage = n, path = path, label = label }
end

function M.worktree(path)
  return { kind = "worktree", path = path, label = "WORKING TREE" }
end

function M.file(abspath, opts)
  opts = opts or {}
  return { kind = "file", abspath = abspath, label = opts.label, readonly = opts.readonly, path = opts.path }
end

function M.empty(label, role)
  return { kind = "empty", label = label or "(does not exist)", role = role }
end

---@class diffmerge.BufInfo
---@field buf integer
---@field key string
---@field refs integer
---@field scratch boolean
---@field created boolean real buffer created by DiffMerge
---@field changed_opts? table options to restore on release
---@field binary? boolean
---@field crlf? boolean
---@field noeol? boolean
---@field editable boolean
---@field repo? diffmerge.Repo
---@field src diffmerge.Source

---@type table<string, diffmerge.BufInfo>
local registry = {}
---@type table<integer, diffmerge.BufInfo>
local by_buf = {}

local function key_of(repo, src)
  local root = repo and repo.root or ""
  if src.kind == "rev" then
    return ("rev:%s:%s:%s"):format(root, src.rev, src.path)
  elseif src.kind == "index" then
    return ("index:%s:%s"):format(root, src.path)
  elseif src.kind == "stage" then
    return ("stage:%s:%d:%s"):format(root, src.stage, src.path)
  elseif src.kind == "worktree" then
    return "file:" .. vim.fs.joinpath(root, src.path)
  elseif src.kind == "file" then
    return "file:" .. src.abspath
  end
  return ("empty:%s:%s"):format(src.role or "", src.label or "")
end

local function spec_of(src)
  if src.kind == "rev" then
    return src.rev .. ":" .. src.path
  elseif src.kind == "index" then
    return ":0:" .. src.path
  elseif src.kind == "stage" then
    return (":%d:%s"):format(src.stage, src.path)
  end
end

local function buf_name(repo, src)
  local root = repo and repo.root or ""
  if src.kind == "rev" then
    return ("diffmerge://%s/.git/%s/%s"):format(root, util.short(src.rev), src.path)
  elseif src.kind == "index" then
    return ("diffmerge://%s/.git/:0/%s"):format(root, src.path)
  elseif src.kind == "stage" then
    return ("diffmerge://%s/.git/:%d/%s"):format(root, src.stage, src.path)
  end
  return ("diffmerge://empty/%s/%s"):format(src.role or "", src.label or "")
end

local function set_filetype(buf, path)
  if not path then
    return
  end
  local ok, ft = pcall(vim.filetype.match, { filename = path, buf = buf })
  if ok and ft then
    vim.bo[buf].filetype = ft
  end
end

--- Reads a git object for a source; returns lines + flags.
local function load_git(repo, src)
  local spec = spec_of(src)
  local content, err = git.cat_blob(repo, spec)
  if content == nil then
    -- submodules (gitlinks) are commits, not blobs: show what `git diff` shows
    local oid = git.rev_parse(repo, spec)
    if oid then
      return { "Subproject commit " .. oid }, { submodule = true }
    end
    return { "(" .. (err ~= "" and err or "missing") .. ")" }, { missing = true }
  end
  if util.is_binary(content) then
    return { ("Binary file %s (%d bytes)"):format(src.path, #content) }, { binary = true }
  end
  local lines, crlf, noeol = util.split_lines(content)
  return lines, { crlf = crlf, noeol = noeol }
end

local function write_index(info)
  local buf, repo, src = info.buf, info.repo, info.src
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local content = util.join_lines(lines, info.crlf, info.noeol)
  local oid, err = git.hash_object(repo, content, src.path, false)
  if not oid then
    util.err("writing the index failed: " .. (err or ""))
    return false
  end
  local entries = git.index_entries(repo, src.path)
  local mode = entries[0] and entries[0].mode or "100644"
  local res = git.update_index(repo, mode, oid, src.path)
  if not res.ok then
    util.err("git update-index failed: " .. vim.trim(res.stderr))
    return false
  end
  vim.bo[buf].modified = false
  api.nvim_exec_autocmds("User", { pattern = "DiffMergeIndexChanged", data = { repo = repo.root, path = src.path } })
  return true
end

local function create_scratch(repo, src)
  local buf = api.nvim_create_buf(false, true)
  local name = buf_name(repo, src)
  if vim.fn.bufexists(name) == 1 then
    name = name .. "#" .. buf
  end
  api.nvim_buf_set_name(buf, name)
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].undolevels = -1
  local info = { buf = buf, scratch = true, created = true, editable = false, repo = repo, src = src }
  if src.kind == "empty" then
    vim.bo[buf].modifiable = false
    return info
  end
  local lines, flags = load_git(repo, src)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  info.binary = flags.binary
  info.crlf = flags.crlf
  info.noeol = flags.noeol
  info.special = flags.binary or flags.submodule or flags.missing
  if src.kind == "index" and not info.special then
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].undolevels = -123456 -- use global value
    vim.bo[buf].modifiable = true
    vim.bo[buf].modified = false
    info.editable = true
    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        write_index(info)
      end,
    })
  else
    vim.bo[buf].modifiable = false
  end
  if not info.special then
    set_filetype(buf, src.path)
  end
  return info
end

local function create_real(repo, src)
  local abs = src.kind == "worktree" and vim.fs.joinpath(repo.root, src.path) or src.abspath
  -- binary files are not loaded into a real buffer
  local stat = vim.uv.fs_stat(abs)
  if stat and stat.type == "file" then
    local f = io.open(abs, "rb")
    local head = f and f:read(8000) or ""
    if f then
      f:close()
    end
    if util.is_binary(head) then
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, { ("Binary file %s (%d bytes)"):format(src.path or abs, stat.size) })
      vim.bo[buf].modifiable = false
      return { buf = buf, scratch = true, created = true, binary = true, special = true, editable = false, src = src }
    end
  end
  local existed = vim.fn.bufexists(abs) == 1
  local buf = vim.fn.bufadd(abs)
  local was_loaded = api.nvim_buf_is_loaded(buf)
  if not was_loaded then
    vim.fn.bufload(buf)
  end
  local info = {
    buf = buf,
    scratch = false,
    created = not existed,
    was_loaded = was_loaded,
    editable = not src.readonly,
    repo = repo,
    src = src,
  }
  if src.readonly and vim.bo[buf].modifiable then
    info.changed_opts = { modifiable = true, readonly = vim.bo[buf].readonly }
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  end
  return info
end

--- Acquires the buffer for a source (reference counted).
---@param repo diffmerge.Repo|nil
---@param src diffmerge.Source
---@return diffmerge.BufInfo
function M.acquire(repo, src)
  local key = key_of(repo, src)
  local info = registry[key]
  if info and not api.nvim_buf_is_valid(info.buf) then
    registry[key] = nil
    info = nil
  end
  if not info then
    if src.kind == "worktree" or src.kind == "file" then
      info = create_real(repo, src)
    else
      info = create_scratch(repo, src)
    end
    info.key = key
    info.refs = 0
    registry[key] = info
    by_buf[info.buf] = info
  end
  info.refs = info.refs + 1
  return info
end

--- Releases a buffer acquired with acquire().
---@param info diffmerge.BufInfo
function M.release(info)
  if not info or registry[info.key] ~= info then
    return
  end
  info.refs = info.refs - 1
  if info.refs > 0 then
    return
  end
  registry[info.key] = nil
  by_buf[info.buf] = nil
  local buf = info.buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  if info.scratch then
    if info.editable and vim.bo[buf].modified then
      -- unsaved index edits: keep the buffer around rather than losing them silently
      util.warn(("unsaved index changes kept in hidden buffer %d (%s)"):format(buf, api.nvim_buf_get_name(buf)))
      return
    end
    pcall(api.nvim_buf_delete, buf, { force = true })
    return
  end
  if info.changed_opts then
    for k, v in pairs(info.changed_opts) do
      vim.bo[buf][k] = v
    end
  end
  if info.created and not vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 0 and not vim.bo[buf].buflisted then
    pcall(api.nvim_buf_delete, buf, {})
  end
end

--- Reloads the content of a git-backed scratch buffer (e.g. the index after staging).
function M.reload(info)
  if not info.scratch or info.src.kind == "empty" or not api.nvim_buf_is_valid(info.buf) then
    return
  end
  if info.editable and vim.bo[info.buf].modified then
    return
  end
  local lines, flags = load_git(info.repo, info.src)
  local current = api.nvim_buf_get_lines(info.buf, 0, -1, false)
  if util.lines_equal(current, lines) then
    return
  end
  local view
  local wins = vim.fn.win_findbuf(info.buf)
  if #wins > 0 then
    view = api.nvim_win_call(wins[1], vim.fn.winsaveview)
  end
  util.set_lines(info.buf, lines)
  info.crlf, info.noeol = flags.crlf, flags.noeol
  if info.editable then
    vim.bo[info.buf].modified = false
  end
  if view then
    api.nvim_win_call(wins[1], function()
      vim.fn.winrestview(view)
    end)
  end
end

--- Reloads every index buffer of a repository.
function M.reload_index(repo)
  for _, info in pairs(registry) do
    if info.src.kind == "index" and info.repo and info.repo.root == repo.root then
      M.reload(info)
    end
  end
end

function M.info(buf)
  return by_buf[buf]
end

--- Lines of a source without creating a buffer (used by the merge engine and staging).
---@return string[]|nil lines, table flags
function M.read_lines(repo, src)
  if src.kind == "empty" then
    return {}, {}
  end
  if src.kind == "worktree" or src.kind == "file" then
    local abs = src.kind == "worktree" and vim.fs.joinpath(repo.root, src.path) or src.abspath
    local content = util.read_file(abs)
    if content == nil then
      return {}, { missing = true }
    end
    if util.is_binary(content) then
      return nil, { binary = true }
    end
    local lines, crlf, noeol = util.split_lines(content)
    return lines, { crlf = crlf, noeol = noeol }
  end
  local lines, flags = load_git(repo, src)
  if flags.binary or flags.submodule then
    return nil, flags
  end
  return lines, flags
end

return M
