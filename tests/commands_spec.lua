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

H.describe(":DiffMerge compare", function()
  local function winbar(v, role)
    return vim.wo[v.layout.wins[role]].winbar
  end

  H.it("two files: both editable, each with its own path", function()
    local dir = H.tmpdir()
    H.write(dir, "config.old.toml", { "port = 80" })
    H.write(dir, "config.toml", { "port = 8080", "log = true" })
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare config.old.toml config.toml")
    local v = view()
    H.eq(v.kind_name, "compare")
    for role, name in pairs({ a = "config.old.toml", b = "config.toml" }) do
      local buf = api.nvim_win_get_buf(v.layout.wins[role])
      H.eq(api.nvim_buf_get_name(buf), dir .. "/" .. name)
      H.eq({ vim.bo[buf].modifiable, vim.bo[buf].readonly }, { true, false }, role)
      H.ok(winbar(v, role):find(name, 1, true), winbar(v, role))
    end
    H.ok(winbar(v, "a"):find("LEFT", 1, true) and not winbar(v, "a"):find("config.toml", 1, true), winbar(v, "a"))
    H.ok(winbar(v, "b"):find("RIGHT", 1, true), winbar(v, "b"))
    -- edits on the left are saved to its file
    api.nvim_buf_set_lines(api.nvim_win_get_buf(v.layout.wins.a), 0, 1, false, { "port = 81" })
    api.nvim_buf_call(api.nvim_win_get_buf(v.layout.wins.a), function()
      vim.cmd("silent write")
    end)
    H.eq(H.read(dir, "config.old.toml"), "port = 81\n")
  end)

  H.it("two directories, with the file panel", function()
    local dir = H.tmpdir()
    H.write(dir, "old/same.txt", { "s" })
    H.write(dir, "old/changed.txt", { "1" })
    H.write(dir, "old/gone.txt", { "g" })
    H.write(dir, "new/same.txt", { "s" })
    H.write(dir, "new/changed.txt", { "2" })
    H.write(dir, "new/added.txt", { "a" })
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare old new")
    local v = view()
    H.eq(v.files.title, "compare")
    H.eq(H.entries(v), { "files:A:added.txt", "files:M:changed.txt", "files:D:gone.txt" })
    v:show_entry(v.entries[2])
    H.ok(winbar(v, "a"):find("old/changed.txt", 1, true), winbar(v, "a"))
    H.eq(vim.bo[api.nvim_win_get_buf(v.layout.wins.a)].modifiable, true)
  end)

  H.it(".git, links to directories, unreadable files", function()
    local dir = H.tmpdir()
    H.write(dir, "old/changed.txt", { "1" })
    H.write(dir, "new/changed.txt", { "2" })
    H.write(dir, "old/.git/HEAD", { "ref: refs/heads/main" })
    H.write(dir, "new/.git/HEAD", { "ref: refs/heads/other" })
    -- a link inside the compared directory is followed, one out of it is not
    H.write(dir, "old/sub/x.txt", { "x" })
    H.write(dir, "new/sub/x.txt", { "x" })
    H.write(dir, "new/inside/x.txt", { "x" })
    vim.uv.fs_symlink(dir .. "/old/sub", dir .. "/old/inside")
    H.write(dir, "target/inner.txt", { "in" })
    vim.uv.fs_symlink(dir .. "/target", dir .. "/old/outside")
    H.write(dir, "old/locked.txt", { "secret" })
    H.write(dir, "new/locked.txt", { "secret" })
    vim.uv.fs_chmod(dir .. "/old/locked.txt", 0)
    vim.cmd.cd(dir)
    local warnings = {}
    local notify = vim.notify
    vim.notify = function(msg)
      warnings[#warnings + 1] = msg
    end
    vim.cmd("DiffMerge compare old new")
    vim.cmd("DiffMerge refresh")
    vim.notify = notify
    vim.uv.fs_chmod(dir .. "/old/locked.txt", 420)
    H.eq(H.entries(view()), { "files:M:changed.txt", "files:A:locked.txt" })
    H.eq(#warnings, 1, "said once: " .. vim.inspect(warnings))
    H.ok(warnings[1]:find("cannot read old/locked.txt", 1, true), warnings[1])
    H.ok(warnings[1]:find("not followed (links out of the compared directory): old/outside", 1, true), warnings[1])
  end)

  H.it("a saved file leaves the list once the same; renames stay paired; R compares again", function()
    local dir = H.tmpdir()
    H.write(dir, "old/changed.txt", { "1" })
    H.write(dir, "new/changed.txt", { "2" })
    H.write(dir, "old/moved-from.txt", { "m" })
    H.write(dir, "new/moved-to.txt", { "m" })
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare old new")
    local v = view()
    H.eq(H.entries(v), { "files:M:changed.txt", "files:R:moved-to.txt" })
    local function save(role, lines)
      local buf = api.nvim_win_get_buf(v.layout.wins[role])
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    -- an edited rename is still the rename
    v:show_entry(v.entries[2])
    save("b", { "m", "more" })
    vim.cmd("DiffMerge refresh")
    H.eq(H.entries(v), { "files:M:changed.txt", "files:R:moved-to.txt" })
    v:show_entry(v.entries[1])
    save("a", { "2" })
    H.eq(H.entries(v), { "files:R:moved-to.txt" })
    H.write(dir, "new/brand-new.txt", { "n" })
    vim.cmd("DiffMerge refresh")
    H.eq(H.entries(v), { "files:A:brand-new.txt", "files:R:moved-to.txt" })
  end)

  H.it("links to directories that multiply a tree stop early", function()
    local dir = H.tmpdir()
    local cur = dir .. "/old"
    vim.fn.mkdir(cur, "p")
    for i = 1, 16 do
      local nxt = dir .. "/old/d" .. i
      vim.fn.mkdir(nxt, "p")
      vim.uv.fs_symlink(nxt, cur .. "/x")
      vim.uv.fs_symlink(nxt, cur .. "/y")
      cur = nxt
    end
    H.write(dir, "old/d16/f.txt", { "f" })
    vim.fn.mkdir(dir .. "/new", "p")
    local warnings = {}
    local notify = vim.notify
    vim.notify = function(msg)
      warnings[#warnings + 1] = msg
    end
    local t = vim.uv.hrtime()
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare old new")
    vim.notify = notify
    H.ok((vim.uv.hrtime() - t) / 1e6 < 2000, "fast")
    H.ok(table.concat(warnings, "\n"):find("links to directories: the rest not followed", 1, true), vim.inspect(warnings))
  end)

  H.it("a side that fails to load: no tab, nothing left loaded", function()
    local dir = H.tmpdir()
    H.write(dir, "a.txt", { "a" })
    H.write(dir, "b.txt", { "b" })
    vim.cmd.cd(dir)
    local source = require("diffmerge.source")
    local acquire = source.acquire
    source.acquire = function(repo, src)
      if src.abspath and src.abspath:match("b%.txt$") then
        error("cannot load b.txt")
      end
      return acquire(repo, src)
    end
    local tabs = #api.nvim_list_tabpages()
    local notify = vim.notify
    vim.notify = function() end
    local ok, err = pcall(vim.cmd, "DiffMerge compare a.txt b.txt")
    vim.notify = notify
    source.acquire = acquire
    assert(ok, err)
    H.eq(view(), nil)
    H.eq(#api.nvim_list_tabpages(), tabs)
    H.eq(vim.fn.bufexists(dir .. "/a.txt"), 0, "a.txt released")
  end)

  H.it("a followed link opens as the file it points to", function()
    local dir = H.tmpdir()
    H.write(dir, "project/f.lua", { "return 1" })
    H.write(dir, "g.lua", { "return 2" })
    vim.uv.fs_symlink(dir .. "/project/f.lua", dir .. "/link.lua")
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare link.lua g.lua")
    local v = view()
    H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(v.layout.wins.a)), dir .. "/project/f.lua")
    H.ok(winbar(v, "a"):find("link.lua", 1, true), winbar(v, "a"))
  end)

  H.it("errors while loading a file are shown; an unreadable file is refused", function()
    local dir = H.tmpdir()
    H.write(dir, "a.txt", { "a" })
    H.write(dir, "b.txt", { "b" })
    H.write(dir, "locked.txt", { "l" })
    vim.uv.fs_chmod(dir .. "/locked.txt", 0)
    vim.cmd.cd(dir)
    local group = api.nvim_create_augroup("CompareSpecRead", { clear = true })
    api.nvim_create_autocmd("BufReadPost", {
      group = group,
      pattern = "*/b.txt",
      callback = function()
        error("broken BufReadPost")
      end,
    })
    local warnings = {}
    local notify = vim.notify
    vim.notify = function(msg)
      warnings[#warnings + 1] = msg
    end
    vim.cmd("DiffMerge compare a.txt b.txt")
    local opened = view() ~= nil
    vim.cmd("DiffMerge close_all")
    vim.cmd("DiffMerge compare a.txt locked.txt")
    vim.notify = notify
    api.nvim_del_augroup_by_id(group)
    vim.uv.fs_chmod(dir .. "/locked.txt", 420)
    H.ok(opened, "opened")
    local all = table.concat(warnings, "\n")
    H.ok(all:find("broken BufReadPost", 1, true), all)
    H.ok(all:find("cannot read locked.txt", 1, true), all)
  end)

  H.it("symbolic links show the file they point to", function()
    local dir = H.tmpdir()
    H.write(dir, "target.txt", { "one", "two" })
    H.write(dir, "b.txt", { "one", "TWO" })
    vim.uv.fs_symlink(dir .. "/target.txt", dir .. "/link.txt")
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge compare link.txt b.txt")
    local buf = api.nvim_win_get_buf(view().layout.wins.a)
    H.eq(H.buf_lines(buf), { "one", "two" })
    H.eq(vim.bo[buf].modifiable, true)
  end)

  H.it("%, history of a compared file, the same file twice, errors leave no tab", function()
    local dir = H.repo({ ["sub/a.txt"] = { "a" } })
    H.commit(dir, "second", { ["sub/a.txt"] = { "a2" } })
    H.write(dir, "sub/b.txt", { "b" })
    vim.cmd.cd(dir .. "/sub")
    vim.cmd.edit("a.txt")
    H.write(dir, "sub/a.txt.orig", { "orig" })
    vim.cmd("DiffMerge compare %.orig %")
    H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(view().layout.wins.a)), dir .. "/sub/a.txt.orig")
    vim.cmd("DiffMerge close")
    vim.cmd("DiffMerge compare % b.txt")
    local v = view()
    H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(v.layout.wins.a)), dir .. "/sub/a.txt")
    api.nvim_set_current_win(v.layout.wins.a)
    vim.cmd("DiffMerge history")
    H.eq(view().path, "sub/a.txt")
    vim.cmd("DiffMerge close_all")
    local tabs = #api.nvim_list_tabpages()
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg)
      errors[#errors + 1] = msg
    end
    vim.cmd("DiffMerge compare a.txt nope.txt")
    vim.cmd("DiffMerge compare a.txt " .. dir)
    vim.cmd("DiffMerge compare a.txt ./a.txt")
    vim.notify = notify
    H.eq(view(), nil)
    H.eq(#api.nvim_list_tabpages(), tabs)
    local all = table.concat(errors, "\n")
    H.ok(all:find("no such file or directory: nope.txt", 1, true), all)
    H.ok(all:find("two files or two directories", 1, true), all)
    H.ok(all:find("the same file twice: a.txt", 1, true), all)
  end)

  H.it("a file open in another Neovim: shown read-only, no error", function()
    local dir = H.tmpdir()
    local swapdir = H.tmpdir()
    H.write(dir, "a.txt", { "a" })
    H.write(dir, "b.txt", { "b" })
    local swap = "set swapfile directory=" .. swapdir .. "//"
    local other = vim.system({ "nvim", "--headless", "--clean", "--cmd", swap, "b.txt" }, { cwd = dir })
    vim.wait(5000, function()
      return #vim.fn.glob(swapdir .. "/*", false, true) > 0
    end)
    -- (the swap file check needs a Neovim started normally, not -l)
    local report = "lua local v = require('diffmerge').current(); local b = v and vim.api.nvim_win_get_buf(v.layout.wins.b); "
      .. "io.stdout:write(vim.inspect({ v and v.kind_name, b and vim.api.nvim_buf_get_lines(b, 0, -1, false), b and vim.bo[b].readonly }, { newline = '' }))"
    local res = vim.system({
      "nvim", "--headless", "--clean", "--cmd", "set rtp^=" .. H.root .. " | " .. swap,
      "-c", "DiffMerge compare a.txt b.txt", "-c", report, "-c", "qa!",
    }, { cwd = dir, text = true }):wait(10000)
    other:kill(9)
    H.eq(res.stdout, vim.inspect({ "compare", { "b" }, true }, { newline = "" }))
    H.ok(not res.stderr:find("E325", 1, true), res.stderr)
  end)

  H.it("file names with ` $ # are taken literally, nothing is run", function()
    local dir = H.tmpdir()
    -- file name -> what is typed before <Tab>
    local names = { "q`touch PWNED`.txt", "users.$id.tsx", "x#y.txt", "#lead.txt" }
    local prefix = { q = "q", u = "us", x = "x#", ["#"] = "#l" }
    for _, n in ipairs(names) do
      H.write(dir, n, { n })
    end
    H.write(dir, "b.txt", { "b" })
    vim.cmd.cd(dir)
    vim.cmd.edit("b.txt")
    local complete = require("diffmerge.commands").complete
    for _, n in ipairs(names) do
      local lead = prefix[n:sub(1, 1)]
      local typed = complete(lead, "DiffMerge compare " .. lead, 99)[1]
      vim.cmd("DiffMerge compare " .. typed .. " b.txt")
      local v = view()
      H.ok(v, "opened: " .. typed)
      H.eq(api.nvim_buf_get_name(api.nvim_win_get_buf(v.layout.wins.a)), dir .. "/" .. n, typed)
      vim.cmd("DiffMerge close")
    end
    H.eq(vim.uv.fs_stat(dir .. "/PWNED"), nil, "no shell command run")
  end)

  H.it("paths with spaces complete escaped", function()
    local dir = H.tmpdir()
    H.write(dir, "sp ace/x.txt", { "x" })
    vim.cmd.cd(dir)
    H.eq(require("diffmerge.commands").complete("sp", "DiffMerge compare sp", 20), { "sp\\ ace/" })
  end)

  H.it("started with the argument list (a shell alias); not later in the session", function()
    local dir = H.tmpdir()
    H.write(dir, "a.txt", { "a" })
    H.write(dir, "b.txt", { "b" })
    local function run(cmds)
      local argv = { "nvim", "--headless", "--clean", "--cmd", "set rtp^=" .. H.root, "a.txt", "b.txt" }
      for _, c in ipairs(cmds) do
        vim.list_extend(argv, { "-c", c })
      end
      local res = vim.system(argv, { cwd = dir, text = true }):wait(10000)
      return vim.trim(res.stdout or "")
    end
    local report = "io.stdout:write(vim.inspect({ kind = (require('diffmerge').current() or {}).kind_name, "
      .. "tabs = #vim.api.nvim_list_tabpages(), listed = #vim.tbl_filter(function(b) return b.name:match('[ab]%.txt$') end, "
      .. "vim.fn.getbufinfo({ buflisted = 1 })) }))"
    H.eq(run({ "tabnew", "DiffMerge compare", "lua " .. report, "qa!" }), vim.inspect({ kind = "compare", tabs = 1, listed = 0 }))
    -- later: no argument list, nothing closed
    -- (headless, the usage error is raised)
    local later = "lua vim.schedule(function() pcall(vim.cmd, 'DiffMerge compare'); " .. report .. "; vim.cmd('qa!') end)"
    H.eq(run({ "tabnew", later }), vim.inspect({ tabs = 2, listed = 2 }))
  end)

  H.it("process substitution: dmdiff <(cmd1) <(cmd2)", function()
    local report = "lua local v = require('diffmerge').current(); local function lines(r) "
      .. "return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(v.layout.wins[r]), 0, -1, false) end; "
      .. "io.stdout:write(vim.inspect({ lines('a'), lines('b') }, { newline = '' }))"
    local cmd = ("nvim --headless --clean --cmd 'set rtp^=%s' -c 'DiffMerge compare' -c \"%s\" -c 'qa!' -- "):format(H.root, report)
      .. [[<(printf 'a\nb\n') <(printf 'a\nc\n')]]
    local res = vim.system({ "bash", "-c", cmd }, { text = true }):wait(10000)
    H.eq(res.stdout, vim.inspect({ { "a", "b" }, { "a", "c" } }, { newline = "" }), res.stderr)
  end)

  H.it("git difftool keeps git's labels and title", function()
    local dir = H.tmpdir()
    H.write(dir, "l/f.txt", { "1" })
    H.write(dir, "r/f.txt", { "2" })
    vim.cmd.cd(dir)
    vim.cmd("DiffMerge difftool l/f.txt r/f.txt f.txt")
    local v = view()
    H.ok(winbar(v, "a"):find("LOCAL (old)", 1, true) and winbar(v, "b"):find("REMOTE (new)", 1, true), winbar(v, "a"))
    H.eq(vim.bo[api.nvim_win_get_buf(v.layout.wins.a)].modifiable, false)
    vim.cmd("DiffMerge close")
    vim.cmd("DiffMerge difftool l r")
    v = view()
    H.eq(v.files.title, "git difftool --dir-diff")
    H.ok(winbar(v, "a"):find("a/ (old)", 1, true) and winbar(v, "b"):find("b/ (new)", 1, true), winbar(v, "a"))
  end)
end)

H.done()
