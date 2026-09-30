# DiffMerge

Diff, merge and browse git history in Neovim, built on Vim's own diff mode. Pure Lua, no
dependencies, Neovim 0.12+.

- **Status view** — Conflicts / Staged / Unstaged / Untracked, like `git status`. Files open as
  `HEAD | WORKING TREE | INDEX` (only the columns that differ); `<Space>` toggles the line
  under the cursor between unstaged and staged (lazygit style), `-` the hunk, visual mode the
  selection — the change stays in view and changes colour.
- **Any `git diff`** — `:DiffMerge diff main...HEAD -- lua/`; the view shows the git command.
- **Merges, meld-style** — auto-merged result in the middle, conflicts show the base text;
  resolve with `<leader>1` `<leader>2` `<leader>3` (toggle mine / base / theirs, KDiff3-style),
  undo just works.
  Layouts: `mine | merged | other` (side by side or stacked) and `mine | base | other / merged`.
- **Log & history** — `git log --graph` with git's colours; preview commits; mark two rows
  (`m` `m`: `git diff A B`, `t`: `A...B`) or select a range (`V` … `<CR>`: combined changes);
  Working tree / Index rows; file, directory and line (`-L`) history.
- **git difftool / mergetool** — files and `--dir-diff` directories; proper exit codes.

```
 main                    │ LOCAL · ours · main         │ MERGED · 1/2 conflicts resolved │ REMOTE · theirs · feature
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
    { "<leader>dq", "<CMD>DiffMerge close<CR>", desc = "Close" },
    { "<leader>dl", "<CMD>DiffMerge log<CR>", desc = "Log (repository)" },
    { "<leader>dh", "<CMD>DiffMerge history<CR>", desc = "History (file)" },
    { "<leader>dh", ":DiffMerge history<CR>", mode = "x", desc = "History (lines)" },
    { "<leader>dc", "<CMD>DiffMerge conflicts<CR>", desc = "Conflicts" },
    { "<leader>df", "<CMD>DiffMerge files<CR>", desc = "Toggle files" },
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

DiffMerge labels every side in the window bar (`WORKING TREE`, `INDEX`, `LOCAL · ours · main`, …).
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
