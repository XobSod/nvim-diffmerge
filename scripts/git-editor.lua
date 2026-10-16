-- git's editor for the commands DiffMerge runs (GIT_EDITOR: a commit, a rebase going on, ...):
-- asks the Neovim that started it to edit the message file there, and waits until it is done
-- with it.
--   nvim --headless --clean -l git-editor.lua <message file>
local file = arg[1]
local server = vim.env.DIFFMERGE_SERVER or ""
-- a socket / named pipe, or host:port
local mode = server:match("^[%w.-]+:%d+$") and "tcp" or "pipe"
local ok, chan = pcall(vim.fn.sockconnect, mode, server, { rpc = true })
if not ok or not chan or chan == 0 then
  io.stderr:write("no Neovim to edit the commit message in (" .. server .. ")\n")
  os.exit(1)
end

local function written()
  local st = vim.uv.fs_stat(file)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or ""
end
local before = written()

local function call(fn)
  return vim.rpcrequest(chan, "nvim_exec_lua", "return require('diffmerge.commit')." .. fn .. "(...)", { file })
end

local opened, err = pcall(call, "edit")
if not opened then
  io.stderr:write("cannot edit the commit message: " .. tostring(err) .. "\n")
  os.exit(1)
end
while true do
  local alive, done = pcall(call, "done")
  if not alive then
    -- that Neovim is gone (e.g. :wq in its last window): what it wrote, if anything
    os.exit(written() ~= before and 0 or 1)
  end
  if done == "abort" then
    os.exit(1)
  elseif done then
    os.exit(0)
  end
  vim.wait(100)
end
