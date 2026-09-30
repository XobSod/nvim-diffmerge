local M = {}

function M.check()
  local h = vim.health
  local git = require("diffmerge.git")
  local config = require("diffmerge.config")

  h.start("DiffMerge: requirements")
  if vim.fn.has("nvim-0.12") == 1 then
    local nv = vim.version()
    h.ok(("Neovim %d.%d.%d"):format(nv.major, nv.minor, nv.patch))
  else
    h.error("Neovim 0.12+ is required (vim.text.diff, diffopt inline/linematch)")
  end
  local v, raw = git.version()
  if not v then
    h.error("git not found in $PATH")
  elseif v[1] < 2 or (v[1] == 2 and v[2] < 23) then
    h.warn(raw .. ": git 2.23+ is recommended (git restore)")
  else
    h.ok(raw)
  end
  if vim.tbl_contains(vim.opt.diffopt:get(), "internal") then
    h.ok("'diffopt' uses the internal diff engine")
  else
    h.warn("'diffopt' does not contain 'internal': linematch / inline highlighting are unavailable")
  end

  h.start("DiffMerge: configuration")
  if #config.errors == 0 then
    h.ok("configuration is valid")
  else
    for _, e in ipairs(config.errors) do
      h.error(e)
    end
  end
  local icons = pcall(require, "mini.icons") and "mini.icons"
    or (pcall(require, "nvim-web-devicons") and "nvim-web-devicons")
  if icons then
    h.ok("file icons: " .. icons)
  else
    h.info("no icon provider (mini.icons / nvim-web-devicons): file icons are not shown")
  end

  h.start("DiffMerge: git integration")
  local function get(key)
    return git.line(nil, { "config", "--get", key })
  end
  local mtool, dtool = get("merge.tool"), get("diff.tool")
  local mcmd, dcmd = mtool and get("mergetool." .. mtool .. ".cmd"), dtool and get("difftool." .. dtool .. ".cmd")
  if mcmd and mcmd:find("DiffMerge mergetool", 1, true) then
    h.ok(("git mergetool uses DiffMerge (merge.tool = %s)"):format(mtool))
    if get("mergetool." .. mtool .. ".trustExitCode") ~= "true" then
      h.warn(("set mergetool.%s.trustExitCode = true so git knows when a merge was not finished"):format(mtool))
    end
  else
    h.info("git mergetool does not use DiffMerge (see |diffmerge-git|)")
  end
  if dcmd and dcmd:find("DiffMerge difftool", 1, true) then
    h.ok(("git difftool uses DiffMerge (diff.tool = %s)"):format(dtool))
  else
    h.info("git difftool does not use DiffMerge (see |diffmerge-git|)")
  end
  local repo = git.find_repo()
  if repo then
    h.ok("current directory is in a repository: " .. repo.root)
  else
    h.info("current directory is not inside a git repository")
  end
end

return M
