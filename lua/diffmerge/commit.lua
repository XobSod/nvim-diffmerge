--- Committing: `git commit` itself (its message template, hooks, merge messages, cleanup), and
--- the git commands that commit on their own (a merge, rebase, cherry-pick, revert going on),
--- with git's editor in this Neovim. scripts/git-editor.lua, git's GIT_EDITOR, asks for the
--- message file to be edited here (edit) and waits until its window is closed (done).
local git = require("diffmerge.git")
local source = require("diffmerge.source")
local util = require("diffmerge.util")

local api = vim.api
local M = {}

local script = vim.fs.joinpath(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))),
  "scripts",
  "git-editor.lua"
)

-- the git command running: { repo, what = "git commit" / "git rebase --continue" ..., kind =
-- its command, tab = where it was started, proc, editing = the message window's state,
-- aborted, stopped, head = HEAD before }
local running
-- by git dir: the message written for a command (`kind`) that failed after it (a hook,
-- signing), offered again by the next one when git offers what it was written over:
-- { kind, lines, offered }
local last_message = {}

--- Quoted for /bin/sh, which runs GIT_EDITOR whatever 'shell' is.
local function sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- The message part of a message file: its lines up to git's comments, trailing blank lines
--- left out.
local function message_part(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("^#") then
      break
    end
    out[#out + 1] = l
  end
  while #out > 0 and vim.trim(out[#out]) == "" do
    out[#out] = nil
  end
  return out
end

--- git's editor: the message file in a window below in the tab the commit was started in
--- (entered when that is where you are and nothing else is being typed).
function M.edit(file)
  local state = { file = file, done = false, written = false, history = vim.fn.histnr(":") }
  if running then
    running.editing = state
  end
  -- a buffer of the file from before is stale: git wrote the file anew
  local old = vim.fn.bufnr(file)
  if old ~= -1 then
    if api.nvim_buf_is_loaded(old) and vim.bo[old].modified then
      error("the commit message file is open with unsaved changes", 0)
    end
    api.nvim_buf_delete(old, { force = true })
  end
  local buf = vim.fn.bufadd(file)
  -- (no swap file: one left behind would stop every commit)
  vim.bo[buf].swapfile = false
  vim.fn.bufload(buf)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  state.offered = message_part(lines)
  local remembered = running and last_message[running.repo.gitdir]
  if remembered and remembered.kind == running.kind and util.lines_equal(remembered.offered, state.offered) then
    -- in place of git's message (the lines before its comments)
    local first_comment = #lines
    for i, l in ipairs(lines) do
      if l:match("^#") then
        first_comment = i - 1
        break
      end
    end
    api.nvim_buf_set_lines(buf, 0, first_comment, false, vim.list_extend(vim.deepcopy(remembered.lines), { "" }))
  end
  local tab = api.nvim_get_current_tabpage()
  if running and running.tab and api.nvim_tabpage_is_valid(running.tab) then
    tab = running.tab
  end
  local here = tab == api.nvim_get_current_tabpage() and vim.fn.mode() == "n"
  -- across the bottom of that tab (from one of its windows that is not a float)
  local anchor = vim.iter(api.nvim_tabpage_list_wins(tab)):find(function(w)
    return api.nvim_win_get_config(w).relative == ""
  end)
  local win
  api.nvim_win_call(anchor, function()
    vim.cmd("botright 15split")
    win = api.nvim_get_current_win()
  end)
  api.nvim_win_set_buf(win, buf)
  vim.wo[win].winfixbuf = true
  -- (panels shown or hidden meanwhile leave its height alone)
  vim.wo[win].winfixheight = true
  state.win = win
  if here then
    api.nvim_set_current_win(win)
    api.nvim_win_set_cursor(win, { 1, 0 })
  else
    util.info("the message is open below in the status view's tab: :wq goes on, :q! aborts")
  end
  -- :q! (ZQ) aborts; :wq, :x, ZZ (and :q of a message left as it is) commit, as in git's editor
  api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    callback = function()
      if vim.fn.histnr(":") > state.history and vim.fn.histget(":", -1):match("^%s*q%a*!%s*$") then
        state.aborted = true
      end
    end,
  })
  vim.keymap.set("n", "ZQ", function()
    state.aborted = true
    vim.cmd("quit!")
  end, { buffer = buf, desc = "DiffMerge: abort (the message)" })
  api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    callback = function()
      state.written = true
    end,
  })
  -- the window may move (<C-w>T): done when the buffer is gone
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      state.done = true
    end,
  })
  return true
end

--- git's editor asks whether `file` is done with: true, "abort" (:q!, ZQ) or false (still
--- open).
function M.done(file)
  local state = running and running.editing
  if not state or state.file ~= file then
    return true
  elseif not state.done then
    return false
  elseif state.aborted then
    running.aborted = true
    return "abort"
  end
  return true
end

--- A git command started here is running (its hooks, or waiting for its message).
function M.running()
  return running ~= nil
end

--- What to tell when something waits for the git command running: "git commit is running:
--- finish it first (...)".
function M.busy_message()
  local what = running and running.what or "git commit"
  return ("%s is running: finish it first (:wq goes on, :q! aborts)"):format(what)
end

--- Why `git <args>` cannot start now (nil: it can).
function M.blocked(repo, committing)
  local op = git.operation(repo)
  if op and op.starting then
    return "a rebase is being set up (its todo list is open in an editor): finish that first"
  elseif require("diffmerge.remote").running(repo) == "pull" then
    return committing and "git pull is running: commit when it is done" or "git pull is running: wait for it"
  elseif source.unsaved_index(repo) then
    return "the INDEX buffer has unsaved edits: :w it first"
  end
end

--- The tab with the window of a message being edited, if any.
function M.message_tab()
  local state = running and running.editing
  if state and not state.done and running.tab and api.nvim_tabpage_is_valid(running.tab) then
    return running.tab
  end
end

--- The window of a message being edited in `tab`, if any.
function M.message_window(tab)
  local state = running and running.editing
  local win = state and not state.done and state.win
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == tab then
    return win
  end
end

--- What git said: its output without hints and the `git status` listing it prints there,
--- and what went to stderr (hooks write there) as it is.
local function said(res)
  local out = {}
  for _, l in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    local listing = l:match("^On branch ")
      or l:match("^Changes ")
      or l:match("^Untracked files")
      or l:match("^Your branch ")
      or l:match("^\t")
      or l:match("^%s*$")
    if not listing and not l:match("^%s*%(use ") then
      out[#out + 1] = l
    end
  end
  for _, l in ipairs(vim.split(res.stderr or "", "\n", { trimempty = true })) do
    if not l:match("^hint: ") then
      out[#out + 1] = l
    end
  end
  return out
end

--- At most `n` lines: the last ones (where git ends with what went wrong).
local function tail(lines, n)
  if #lines <= n then
    return table.concat(lines, "\n")
  end
  return ("(%d lines before)\n"):format(#lines - n) .. table.concat(vim.list_slice(lines, #lines - n + 1), "\n")
end

--- "[master 1a2b3c4] subject · 1 file changed, 2 insertions(+)" (also when git was quiet);
--- nil when nothing was committed (--dry-run).
local function summary(repo, res, head_before)
  local head, stat
  for _, l in ipairs(vim.split(res.stdout, "\n", { trimempty = true })) do
    head = head or l:match("^%[.-%].*")
    stat = stat or l:match("^%s*(%d+ files? changed.*)")
  end
  if not head then
    if git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" }) == head_before then
      return nil
    end
    head = "committed " .. (git.line(repo, { "log", "-1", "--format=%h %s" }) or "")
  end
  return stat and (head .. " · " .. stat) or head
end

--- `git <args>` with git's editor here: a commit, or a merge / rebase / cherry-pick / revert
--- going on (`--continue`, `--skip`, `--abort`). `on_done(res)` when git is finished. While it
--- runs, starting another offers to stop it (a hook that does not end).
---@param args string[] e.g. { "commit", "--amend" }, { "rebase", "--continue" }
---@param on_done? fun(res: diffmerge.RunResult)
function M.run_git(repo, args, on_done)
  local committing = args[1] == "commit"
  local what = "git " .. args[1] .. ((not committing and args[2]) and (" " .. args[2]) or "")
  if running then
    if running.editing and not running.editing.done then
      util.warn(
        running.what == "git commit" and "a commit is waiting for its message: :wq commits it, :q! aborts"
          or ("%s is waiting for the message: :wq goes on, :q! aborts"):format(running.what)
      )
    elseif vim.fn.confirm(running.what .. " is still running (its hooks?). Stop it?", "&Yes\n&No", 2) == 1 then
      running.stopped = true
      -- git and what it started (a hook)
      pcall(vim.uv.kill, -running.proc.pid, "sigterm")
    end
    return
  end
  local why = M.blocked(repo, committing)
  if why then
    util.warn(why)
    return
  end
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end
  local editor = table.concat({ sh_quote(vim.v.progpath), "--headless", "--clean", "-l", sh_quote(script) }, " ")
  local env = { GIT_EDITOR = editor, DIFFMERGE_SERVER = vim.v.servername }
  local this = {
    repo = repo,
    what = what,
    kind = args[1],
    tab = api.nvim_get_current_tabpage(),
    head = git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" }),
  }
  running = this
  local opts = { env = env, detach = true }
  this.proc = git.run_async(repo, args, opts, function(res)
    running = nil
    -- a hook may have drawn on the terminal (pinentry); (headless: no screen to redraw)
    if #api.nvim_list_uis() > 0 then
      vim.cmd("redraw!")
    end
    if this.stopped then
      util.info(what .. " stopped")
    elseif this.aborted then
      util.info(committing and "commit aborted" or (what .. ": the message aborted, nothing committed"))
    elseif res.ok then
      last_message[repo.gitdir] = nil
      local lines = said(res)
      if committing then
        local done = summary(repo, res, this.head)
        if done then
          util.info(done)
          -- what hooks said
          lines = said({ stderr = res.stderr })
        end
        if #lines > 0 then
          util.info(tail(lines, 15))
        elseif not done then
          util.info("nothing was committed")
        end
      else
        util.info(#lines > 0 and tail(lines, 15) or (what .. ": done"))
      end
    elseif (res.stdout .. res.stderr):find("empty commit message", 1, true) then
      util.info("aborted: the message is empty")
    else
      -- (not when git committed it before it stopped: a rebase's next conflict)
      local committed = git.line(repo, { "rev-parse", "-q", "--verify", "HEAD" }) ~= this.head
      if this.editing and this.editing.written and not committed then
        last_message[repo.gitdir] = {
          kind = this.kind,
          lines = message_part(vim.split(util.read_file(this.editing.file) or "", "\n")),
          offered = this.editing.offered,
        }
      end
      local lines = said(res)
      util.warn(#lines > 0 and tail(lines, 15) or (what .. " failed"))
    end
    if on_done then
      on_done(res)
    end
  end)
  -- hooks run before the message: say what is going on when they take a while
  vim.defer_fn(function()
    if running == this and not this.editing then
      util.info(what .. " is running (its hooks?): cc again to stop it")
    end
  end, 1000)
end

--- `git commit <args>` with the message edited here (see run_git).
---@param args string[] e.g. { "--amend" }
---@param on_done? fun(res: diffmerge.RunResult)
function M.run(repo, args, on_done)
  M.run_git(repo, vim.list_extend({ "commit" }, args), on_done)
end

return M
