# DiffMerge

Diff, merge and browse git history in Neovim, built on Vim's own diff mode. Pure Lua, no
dependencies, Neovim 0.12+.

- **Status view** — Conflicts / Staged / Unstaged / Untracked, like `git status`; stage files
  or hunks with `-`, the line under the cursor with `<Space>` (lazygit style), selected lines
  in visual mode; the index is an editable buffer.
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

## Tests

```sh
./tests/run.sh                  # all specs, headless, against throwaway repositories
./tests/run.sh tests/merge_spec.lua
```
