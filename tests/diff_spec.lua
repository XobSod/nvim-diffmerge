local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/harness.lua")
local api = vim.api
local revspec = require("diffmerge.revspec")
local git = require("diffmerge.git")

local function setup()
  local dir = H.repo({ ["a.txt"] = { "a" }, ["b.txt"] = { "b" } })
  local c1 = vim.trim(H.git(dir, { "rev-parse", "HEAD" }))
  local c2 = H.commit(dir, "c2", { ["a.txt"] = { "a2" } })
  H.git(dir, { "checkout", "-q", "-b", "feat", c1 })
  local f1 = H.commit(dir, "f1", { ["b.txt"] = { "b-feat" } })
  H.git(dir, { "checkout", "-q", "main" })
  return dir, { c1 = c1, c2 = c2, f1 = f1 }
end

local function sides(dir, args)
  local repo = git.find_repo(dir)
  local cmp = assert(revspec.parse(repo, args))
  local function s(side)
    return side.kind == "commit" and side.oid or side.kind
  end
  return { s(cmp.left), s(cmp.right) }, cmp
end

local function names(dir, args)
  local repo = git.find_repo(dir)
  local cmp = assert(revspec.parse(repo, args))
  local out = {}
  for _, e in ipairs(revspec.entries(repo, cmp)) do
    out[#out + 1] = e.status .. ":" .. e.path
  end
  table.sort(out)
  return out
end

--- What git itself lists for the same arguments.
local function git_names(dir, args)
  local cmd = { "diff", "--name-status", "-M" }
  vim.list_extend(cmd, args)
  local out = {}
  for line in H.git(dir, cmd):gmatch("[^\n]+") do
    local st, path = line:match("^(%a)%d*\t(.-)$")
    out[#out + 1] = st .. ":" .. path:gsub("^.*\t", "")
  end
  table.sort(out)
  return out
end

H.describe("git diff arguments", function()
  H.it("resolves sides exactly like git diff", function()
    local dir, c = setup()
    H.write(dir, "a.txt", { "dirty" })
    H.eq(sides(dir, {}), { "index", "worktree" })
    H.eq(sides(dir, { "--staged" }), { c.c2, "index" })
    H.eq(sides(dir, { "--cached", c.c1 }), { c.c1, "index" })
    H.eq(sides(dir, { c.c1 }), { c.c1, "worktree" })
    H.eq(sides(dir, { c.c1, "feat" }), { c.c1, c.f1 })
    H.eq(sides(dir, { c.c1 .. "..feat" }), { c.c1, c.f1 }, "A..B == A B")
    H.eq(sides(dir, { "main...feat" }), { c.c1, c.f1 }, "A...B = merge-base(A, B) -> B")
    H.eq(sides(dir, { "feat^!" }), { c.c1, c.f1 })
    H.eq(sides(dir, { "--merge-base", "feat" }), { c.c1, "worktree" })
    local _, cmp = sides(dir, { "HEAD", "--", "a.txt" })
    H.eq(cmp.paths, { "a.txt" })
    H.eq(cmp.title, "git diff HEAD -- a.txt")
  end)

  H.it("lists the same files as git", function()
    local dir, c = setup()
    H.write(dir, "a.txt", { "dirty" })
    H.write(dir, "b.txt", { "staged" })
    H.git(dir, { "add", "b.txt" })
    for _, args in ipairs({ {}, { "--staged" }, { c.c1 }, { "main...feat" }, { c.c1, "feat" } }) do
      H.eq(names(dir, args), git_names(dir, args), table.concat(args, " "))
    end
  end)

  H.it("opens a view with the git command as title", function()
    local dir = setup()
    vim.cmd.cd(dir)
    local view = require("diffmerge").diff({ "main...feat" })
    H.eq(view.files.title, "git diff main...feat")
    H.eq(H.entries(view), { "files:M:b.txt" })
    local a = api.nvim_win_get_buf(view.layout.wins.a)
    H.eq(H.buf_lines(a), { "b" })
    H.eq(vim.bo[a].modifiable, false)
  end)
end)

H.describe("git difftool", function()
  H.it("compares two files", function()
    local dir = H.tmpdir()
    H.write(dir, "left.lua", { "local a = 1" })
    H.write(dir, "right.lua", { "local a = 2" })
    local view = require("diffmerge").difftool(dir .. "/left.lua", dir .. "/right.lua", "src/x.lua")
    H.eq(view.files, nil, "no file panel for a single file")
    local a = api.nvim_win_get_buf(view.layout.wins.a)
    local b = api.nvim_win_get_buf(view.layout.wins.b)
    H.eq(vim.bo[a].modifiable, false, "left is read-only")
    H.eq(vim.bo[b].modifiable, true, "right is editable")
    H.eq(vim.bo[b].filetype, "lua")
    H.ok(vim.wo[view.layout.wins.a].winbar:find("src/x.lua", 1, true), "shows $MERGED name")
  end)

  H.it("compares directories (git difftool -d), with renames", function()
    local l, r = H.tmpdir(), H.tmpdir()
    H.write(l, "same.txt", { "same" })
    H.write(r, "same.txt", { "same" })
    H.write(l, "mod.txt", { "1" })
    H.write(r, "mod.txt", { "2" })
    H.write(l, "gone.txt", { "gone" })
    H.write(r, "sub/new.txt", { "new" })
    H.write(l, "old-name.txt", { "moved content" })
    H.write(r, "sub/new-name.txt", { "moved content" })
    local view = require("diffmerge").difftool(l, r)
    H.eq(H.entries(view), { "files:R:sub/new-name.txt", "files:A:sub/new.txt", "files:D:gone.txt", "files:M:mod.txt" })
  end)
end)

H.done()
