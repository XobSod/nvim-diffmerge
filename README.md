# DiffMerge

Diff, merge and browse git history in Neovim, built on Vim's own diff mode. Pure Lua, no
dependencies, Neovim 0.12+.

- **Status view** — Conflicts / Staged / Unstaged / Untracked, like `git status`. Files open as
  `HEAD | WORKING TREE | INDEX` (only the columns that differ); `<Space>` toggles the line
  under the cursor between unstaged and staged (lazygit style), `-` the hunk, visual mode the
  selection — the change stays in view and changes colour; `X` discards it. Opened from a file,
  it shows that file at the cursor's line. The log of the repository goes below it (`gL`; `gF`
  the file panel); `g?` lists the keys of the window you are in, by function.
- **Stashing what you staged** — `s` stashes the staged lines and hunks only (also next to
  unstaged changes, where `git stash --staged` fails), files, or everything; stashes are listed
  below the changes and open like changes, read-only; apply, pop, drop.
- **Ignoring** — `i` on a file or directory adds it to `.gitignore` or `.git/info/exclude`, by
  path or by extension (`*.log`); a tracked file stops being tracked, after a question that says
  what that means for the repository.
- **Committing** — `cc` / `ca` (amend) in the status view: git's own commit (template, hooks,
  merge message), the message in a window below, `:wq` commits, `:q!` aborts. While a merge,
  rebase, cherry-pick or revert goes on, `cc` continues it and `c` skips / aborts. On a commit
  of the log: `cf` fixup with what is staged, `cs` squash into its parent, `cr` reword, `cd`
  drop; `C` cherry-pick, `X` revert, `r` reset there, `T` tag.
- **Fetch / pull / push** — `F` / `p` / `P` in the background; pull follows your git config;
  push offers to set an upstream and, when rejected, `--force-with-lease` (never `--force`).
- **Branches** — `b` switches (`git switch`) from a picker of local and remote branches, or to a
  new one; `b` on a commit in the log checks it out (its branch, else a branch following a remote
  one there, detached, or a new branch there); uncommitted changes in the way go along (stash,
  switch, pop).
- **Changed characters** are highlighted in merges and in the three columns too (following
  `'diffopt'` `inline:`), where Vim's own colours would compare every window with every other.
- **Any `git diff`** — `:DiffMerge diff master...HEAD -- lua/`; the view shows the git command.
- **Merges, meld-style** — git's merge result in the middle (rerere and fixes by hand kept),
  every conflict shows the base text;
  resolve with `<leader>1` `<leader>2` `<leader>3` (toggle mine / base / theirs, KDiff3-style),
  undo just works; `<leader>1` / `<leader>3` in the file panel take a side for the whole file.
  Layouts: `mine | merged | other` (side by side or stacked) and `mine | base | other / merged`.
- **Log & history** — `git log --graph` with git's colours, in the status view: its Working
  tree row is the status, a commit shows what it changed; mark two rows (`m` `m`: `git diff A
  B`, `t`: `A...B`) or select a range (`V` … `<CR>`: combined changes); it follows commits,
  fetches and switches, keeping your place; file, directory and line (`-L`) history.
- **git difftool / mergetool** — files and `--dir-diff` directories; proper exit codes.
- **Any two files or directories** — `nvim -c "DiffMerge compare" -- old new` (e.g. as a
  shell alias), both sides editable.

```
 master                  │ LOCAL · ours · master       │ MERGED · 1/2 conflicts resolved │ REMOTE · theirs · feature
 MERGING feature         │  5 M.name = opts.name       │     5 M.name = opts.name        │  5 M.name = opts.name
                         │  6 M.debug = … DEBUG ~= nil │ 3   6 M.debug = … == true  ⚑ 1/2│ ✓ 6 M.debug = … == true
  Conflicts 1  unmerged  │  7 end                      │     7 end                       │  7 end
    U  init.lua          │ …                           │ !  14 return a + b    ⚑ 2/2 ,1 …│ 14 return (a or 0) + …
 ────────────────────────┴─────────────────────────────┴─────────────────────────────────┴──────────────────────────
```

## Install

lazy.nvim:

```lua
{
  "XobSod/nvim-diffmerge",
  cmd = "DiffMerge",
  opts = {},
  keys = {
    { "<leader>do", "<CMD>DiffMerge<CR>", desc = "Status" },
    { "<leader>dl", "<CMD>DiffMerge log<CR>", desc = "Log (show / hide)" },
    { "<leader>df", "<CMD>DiffMerge files<CR>", desc = "Files (show / hide)" },
    { "<leader>dh", "<CMD>DiffMerge history<CR>", desc = "History (file)" },
    { "<leader>dh", ":DiffMerge history<CR>", mode = "x", desc = "History (lines)" },
    { "<leader>dc", "<CMD>DiffMerge conflicts<CR>", desc = "Conflicts" },
    { "<leader>dq", "<CMD>DiffMerge close<CR>", desc = "Close" },
  },
}
```

## git integration

```gitconfig
[diff]
  tool = diffmerge
[difftool]
  prompt = false
[difftool "diffmerge"]
  cmd = nvim -c \"DiffMerge difftool\" -- \"$LOCAL\" \"$REMOTE\" \"$MERGED\"
[merge]
  tool = diffmerge
[mergetool "diffmerge"]
  cmd = nvim -c \"DiffMerge mergetool\" -- \"$LOCAL\" \"$BASE\" \"$REMOTE\" \"$MERGED\"
  trustExitCode = true
[alias]
  mt = !nvim -c \"DiffMerge conflicts\"
```

`git mergetool` gets exit code 0 only when every conflict is resolved and saved; otherwise git
restores the file and reports the merge as failed. `git mt` resolves all conflicts in one
Neovim.

## Documentation

`:help diffmerge` — commands, views, keymaps (`g?` in any view), configuration, highlights.

## Compatibility

### Breadcrumb plugins (winbar)

DiffMerge labels every side in the window bar (`WORKING TREE`, `INDEX`, `LOCAL · ours · master`, …).
Breadcrumb plugins that write the winbar of any window with an LSP client can overwrite the label
of working-tree files. lspsaga means to leave diff windows alone but only checks when it
attaches to a buffer; this makes it check every time it draws:

```lua
-- after require("lspsaga").setup(opts)
local crumbs = require("lspsaga").config.symbol_in_winbar
local enabled = crumbs.enable
crumbs.enable = nil
setmetatable(crumbs, {
  __index = function(_, key)
    if key == "enable" then
      return enabled and not vim.wo.diff -- no breadcrumbs in diff windows
    end
  end,
})
```

## Tests

```sh
./tests/run.sh                  # all specs, headless, against throwaway repositories
./tests/run.sh tests/merge_spec.lua
```

## License

MIT, see [LICENSE](LICENSE).
