--- Tiny test harness: `nvim --headless --clean -l tests/<name>_spec.lua` (see tests/run.sh).
local H = {}

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
H.root = root
vim.opt.rtp:prepend(root)
-- isolate from the user's git config (log.follow, colours, pagers, signing, ...)
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME = "Tester"
vim.env.GIT_AUTHOR_EMAIL = "tester@example.com"
vim.env.GIT_COMMITTER_NAME = "Tester"
vim.env.GIT_COMMITTER_EMAIL = "tester@example.com"
vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.g.mapleader = ","

vim.cmd("runtime plugin/diffmerge.lua")
require("diffmerge").setup({ watch = false, auto_preview = false })

local results = { pass = 0, fail = 0, failures = {} }
local group = ""

function H.describe(name, fn)
  group = name
  print(name)
  fn()
end

local function reset()
  pcall(vim.cmd, "silent! tabonly!")
  pcall(vim.cmd, "silent! only!")
  pcall(vim.cmd, "enew!")
  for _, v in pairs(require("diffmerge.view").views) do
    pcall(function()
      v:cleanup()
    end)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

function H.it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    print("  ok   " .. name)
  else
    results.fail = results.fail + 1
    results.failures[#results.failures + 1] = group .. " / " .. name
    print("  FAIL " .. name .. "\n" .. err:gsub("\n", "\n       "))
  end
  reset()
end

function H.done()
  print(("\n%d passed, %d failed"):format(results.pass, results.fail))
  for _, f in ipairs(results.failures) do
    print("  failed: " .. f)
  end
  vim.cmd((results.fail > 0 and "cquit 1") or "qall!")
end

function H.eq(got, expected, msg)
  if not vim.deep_equal(got, expected) then
    error(("%s\nexpected: %s\n     got: %s"):format(msg or "values differ", vim.inspect(expected), vim.inspect(got)), 2)
  end
end

function H.ok(v, msg)
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

--- Waits for scheduled callbacks.
function H.flush(ms)
  vim.wait(ms or 30, function()
    return false
  end)
end

---------------------------------------------------------------------------
-- git fixtures
---------------------------------------------------------------------------

function H.tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fs.normalize(vim.uv.fs_realpath(d))
end

function H.git(dir, args, stdin)
  local cmd = { "git", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false" }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = dir, text = true, stdin = stdin }):wait()
  if r.code ~= 0 then
    error(("git %s failed:\n%s%s"):format(table.concat(args, " "), r.stdout or "", r.stderr or ""), 2)
  end
  return r.stdout
end

function H.write(dir, path, lines)
  local abs = vim.fs.joinpath(dir, path)
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f = assert(io.open(abs, "wb"))
  if type(lines) == "table" then
    f:write(table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
  else
    f:write(lines)
  end
  f:close()
end

function H.read(dir, path)
  local f = io.open(vim.fs.joinpath(dir, path), "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- New repository; `files` are committed as the first commit.
function H.repo(files)
  local dir = H.tmpdir()
  H.git(dir, { "init", "-q" })
  for path, lines in pairs(files or {}) do
    H.write(dir, path, lines)
  end
  if files and next(files) then
    H.git(dir, { "add", "-A" })
    H.git(dir, { "commit", "-q", "-m", "initial" })
  end
  return dir
end

function H.commit(dir, msg, files)
  for path, lines in pairs(files or {}) do
    if lines == false then
      H.git(dir, { "rm", "-q", path })
    else
      H.write(dir, path, lines)
      H.git(dir, { "add", path })
    end
  end
  H.git(dir, { "commit", "-q", "--allow-empty", "-m", msg })
  return vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
end

function H.lines(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or "line") .. i
  end
  return out
end

function H.buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Entries of a view's file panel, as "section:status:path".
function H.entries(view)
  local out = {}
  for _, s in ipairs(view.sections or {}) do
    for _, e in ipairs(view.files and view.files:ordered_entries(s) or s.entries) do
      out[#out + 1] = s.id .. ":" .. e.status .. ":" .. e.path
    end
  end
  return out
end

function H.find_entry(view, section, path)
  for _, s in ipairs(view.sections or {}) do
    if s.id == section then
      for _, e in ipairs(s.entries) do
        if e.path == path then
          return e
        end
      end
    end
  end
end

--- Runs a buffer-local mapping of the current buffer.
function H.press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

return H
