local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api

local function view()
  return require("diffmerge").current()
end

local function repo()
  local dir = H.repo({ ["a.txt"] = { "a" }, ["b.txt"] = { "b" } })
  H.commit(dir, "second", { ["a.txt"] = { "a2" } })
  H.write(dir, "b.txt", { "dirty" })
  vim.cmd.cd(dir)
  return dir
end

H.describe(":DiffMerge", function()
  H.it("opens, re-uses and closes the status view", function()
    repo()
    vim.cmd("DiffMerge")
    local v = view()
    H.eq(v.kind_name, "status")
    local tabs = #api.nvim_list_tabpages()
    vim.cmd("tabprevious")
    vim.cmd("DiffMerge status")
    H.eq(view(), v, "same view")
    H.eq(#api.nvim_list_tabpages(), tabs)
    vim.cmd("DiffMerge close")
    H.eq(view(), nil)
    H.eq(#api.nvim_list_tabpages(), 1)
  end)

  H.it("diff / log / history subcommands", function()
    local dir = repo()
    vim.cmd("DiffMerge diff HEAD~1 -- a.txt")
    H.eq(view().files.title, "git diff HEAD~1 -- a.txt")
    H.eq(H.entries(view()), { "files:M:a.txt" })
    vim.cmd("DiffMerge close")
    vim.cmd("edit " .. dir .. "/a.txt")
    vim.cmd("DiffMerge history")
    H.eq(view().kind_name, "history")
    H.eq(view().path, "a.txt")
    vim.cmd("DiffMerge close")
    vim.cmd("DiffMerge log --first-parent")
    H.eq(view().kind_name, "log")
    H.ok(vim.tbl_contains(view():log_args(), "--first-parent"))
  end)

  H.it("layout and file panel toggles", function()
    repo()
    vim.cmd("DiffMerge")
    local v = view()
    vim.cmd("DiffMerge layout stacked")
    H.eq(v.layout.name, "stacked")
    vim.cmd("DiffMerge files")
    H.eq(v.layout.files_win, nil)
    vim.cmd("DiffMerge files")
    H.ok(v.layout.files_win and api.nvim_win_is_valid(v.layout.files_win), "panel back")
    H.eq(api.nvim_win_get_buf(v.layout.files_win), v.files.buf)
    H.eq(#v.layout:diff_wins(), 2)
    for _, w in ipairs(v.layout:diff_wins()) do
      H.ok(vim.wo[w].diff, "diff windows rebuilt")
    end
  end)

  H.it("close_all closes every view", function()
    repo()
    vim.cmd("DiffMerge")
    vim.cmd("DiffMerge log")
    vim.cmd("DiffMerge diff HEAD~1")
    H.eq(#api.nvim_list_tabpages(), 4)
    vim.cmd("DiffMerge close_all")
    H.eq(#api.nvim_list_tabpages(), 1)
    H.eq(vim.tbl_count(require("diffmerge.view").views), 0)
  end)

  H.it("completes subcommands, refs and layouts", function()
    repo()
    local complete = require("diffmerge.commands").complete
    H.ok(vim.tbl_contains(complete("", "DiffMerge ", 10), "history"))
    H.eq(complete("con", "DiffMerge con", 13), { "conflicts" })
    H.ok(vim.tbl_contains(complete("ma", "DiffMerge diff ma", 17), "main"))
    H.eq(complete("main...ma", "DiffMerge diff main...ma", 24), { "main...main" })
    H.eq(complete("fo", "DiffMerge layout fo", 19), { "four_way" })
  end)

  H.it("reports errors instead of throwing", function()
    repo()
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = msg
      end
    end
    vim.cmd("DiffMerge nope")
    vim.cmd("DiffMerge diff does-not-exist..HEAD")
    vim.notify = notify
    H.eq(#errors, 2)
    H.eq(view(), nil)
  end)
end)

H.describe("log preselection", function()
  H.it("previews HEAD even when another branch is newer", function()
    local dir = H.repo({ ["a.txt"] = { "a" } })
    local head = H.commit(dir, "on main", { ["a.txt"] = { "main" } })
    H.git(dir, { "checkout", "-q", "-b", "other", "HEAD~1" })
    H.commit(dir, "newer on other", { ["b.txt"] = { "b" } })
    H.git(dir, { "checkout", "-q", "main" })
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge log")
    local v = view()
    vim.wait(3000, function()
      return not v.log.loading
    end, 10)
    H.eq(v.cmp.right.oid, head)
    H.eq(api.nvim_win_get_cursor(v.layout.log_win)[1], v.log.by_sha[head])
  end)
end)

H.done()
