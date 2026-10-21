# DiffMerge — design

This is the reference for how DiffMerge is meant to behave, and why. `:help diffmerge` describes what a user sees and types; this document holds the rules behind it.

When the code and this document disagree, one of them is wrong: fix the code, or change this document in the same commit. A rule here should have a spec in `tests/`.

## Principles

1. **Behave like git.** Every git comparison is defined by the git command it equals, and shows that command (`git diff master...HEAD -- lua/`). Repository actions run git itself, with the user's hooks, templates and config (except the output settings DiffMerge pins, see *Git semantics*); DiffMerge gives git an editor and shows the result. DiffMerge has mechanisms of its own only where git has none: its own 3-way merge when git cannot run, stashing staged changes where `git stash --staged` cannot, and the views that compare files rather than git versions (`compare`, `difftool`, `mergetool`).
2. **Vim's diff mode is the foundation.** Alignment (filler lines), scroll and cursor binding, folding of unchanged text and `]c` / `[c` come from Vim and stay familiar. Changes are moved by pointing at them (stage, unstage, discard, pick a side), not with `do` / `dp`, which know nothing about the index or a conflict's state. Merge views add an overlay of their own on top (see *Merges*).
3. **Real files stay real.** A working-tree side is the file's own buffer: editable, LSP and formatters work, `:w` saves. Other versions are unlisted scratch buffers (`diffmerge://…`, `buftype=nofile`), so LSP never attaches to them. The index is an `acwrite` buffer whose `:w` writes the index, except in the three columns of the status view, where it is read-only.
4. **One tabpage per view.** Nothing leaks into other tabs; closing the tab closes the view and restores the window options it set. Mappings are buffer-local while a view shows the buffer, and the mappings they shadowed come back. The one global setting is `gW`: it toggles "iwhite" in 'diffopt', which has no local value in Vim, so it applies to every diff and stays after the view closes.
5. **No dependencies.** mini.icons / nvim-web-devicons are used when present. Only standard Unicode glyphs, no Nerd Font. Neovim 0.12+; git 2.26+ (2.35+ for everything, see *Implementation rules*).

## Git semantics

| View / action | Left side | Right side | Equivalent git command |
| --- | --- | --- | --- |
| Status → changed file | HEAD │ WORKING TREE │ INDEX (only the columns that differ) | | `git diff` + `git diff --staged` |
| Status → Unstaged (`three_way = false`) | index | working tree (editable) | `git diff` |
| Status → Staged (`three_way = false`) | HEAD | index (editable) | `git diff --staged` |
| Status → Untracked | (nothing) | working tree | — |
| Status → Conflicts | stages 2 / 1 / 3 | working tree (merged) | `git status` unmerged paths |
| `:DiffMerge diff <commit>` | commit | working tree | `git diff <commit>` |
| `:DiffMerge diff --staged [<commit>]` | commit (HEAD) | index (editable) | `git diff --staged [<commit>]` |
| `:DiffMerge diff A B` / `A..B` | A | B | `git diff A B` (the same thing) |
| `:DiffMerge diff A...B` | merge-base(A, B) | B | `git diff A...B` |
| `:DiffMerge diff C^!` | C^ | C | `git diff C^!` |
| Log: a commit C | C^1 (`^` cycles the parents of a merge) | C | `git show C` / `git diff C^ C` |
| Log: `m` on two commits A, B (B newer) | A | B | `git diff A B` |
| Log: `m` `m` with `t` on | merge-base(A, B) | B | `git diff A...B` |
| Log: visual commits O..N + `<CR>` | O^ | N | `git diff O^ N` (combined changes) |
| Log: marking the Working tree / Index row | … | working tree / index | `git diff <A>` / `git diff --staged <A>` |

- In `git diff`, `A..B` is the same as `A B` (two snapshots); only `A...B` is special (changes on B since it forked from A). In `git log`, `A..B` means something else; the views always show the equivalent `git diff`.
- A visual selection must be exactly `git rev-list O^..N [-- path]` (with `--first-parent` when that is on). Otherwise it is not "the combined changes of these commits" (e.g. it spans two branches): the user is told what is included or missing and asked whether to show `git diff O^ N` anyway. Line history (`-L`) has no such check.
- Marks are ordered automatically, the ancestor on the left; for diverged commits the lower row is the left side. `t` is a mode that stays on: two marks then compare from their merge base (with a pseudo row: the merge base with HEAD).
- The Working tree and Index rows are pseudo rows at the top of the log, so they can be marked like commits.
- Paths after `--` are relative to the current directory, as on the git command line.
- Every git call DiffMerge makes pins the settings that would change git's output: `--no-pager`; config `core.quotePath=false`, `color.ui=false` (the log asks for `--color=always` itself), `log.showSignature=false`, `log.follow=false` (file history passes `--follow` itself), `diff.noprefix=false`, `diff.mnemonicPrefix=false`, `diff.relative=false`, `status.relativePaths=false`; environment `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat`, `PAGER=cat`. Paths are read with `-z` (*Implementation rules*).

## Views

- `:DiffMerge` opens the main view of a repository, one per repository: re-used, back on the working tree, marks cleared. `:DiffMerge log` opens the same view with its log shown, or shows / hides the log of the status view it is typed in. `:DiffMerge log <args>` and `:DiffMerge history` open views of their own, whose status is limited to those paths (they count as status views: staging, ignoring and the repository keys work there). `diff`, `difftool`, `mergetool` and `compare` open views of their own too.
- The main view is the status and the log in one: file panel on the left, log panel at the bottom (`gL`), diff windows in the rest. The log row decides what the file panel and the diff windows show (*Log and history*).
- Layouts are named by arrangement: `side_by_side` (columns) and `stacked` (rows) for 2-way views, and also `four_way` (mine | base | other, merged below) for merges. `gl` cycles them; the default of each kind is configurable. `` ` `` toggles the file panel between tree and list in every view.
- Every side is labelled in its window bar (the statusline may be global, 'laststatus' 3): `HEAD · abc1234 · path`, `INDEX · to be committed`, `LOCAL · ours · master`, `MERGED · 1/2 conflicts resolved`. During a rebase, ours / theirs are labelled with what they really are (the branch rebased onto / your commit).
- Opened from a file with changes, the status view shows that file at the cursor's line (in a conflict, the line is mapped through the markers DiffMerge rewrote).
- Status views refresh on `BufWritePost` of a file of the repository, on `FocusGained`, `TermClose`, `TermLeave` and `ShellCmdPost`, on DiffMerge's own index writes, and on a filesystem watcher of the git directory: `index`, `HEAD`, `ORIG_HEAD`, `MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `refs/heads` (not its subdirectories) and `refs/stash`. A view whose tab is not current refreshes when its tab is entered. `:DiffMerge diff` views that show the index or the working tree refresh on `BufWritePost`, `FocusGained`, `TermLeave` and DiffMerge's own index writes, without a watcher. A directory `compare` drops a file from its list when it is saved equal to its other side. Views with a file panel (directory `compare`, `difftool -d`, `:DiffMerge diff` of commits only) show changes made outside after `R`; single-file `compare` / `difftool` show real files, which Neovim reloads itself ('autoread', `:checktime`).

## Buffers

- Buffers are shared between views and reference-counted; a buffer is released when no view shows it. An editable index buffer with unsaved edits is kept (hidden), with a warning, rather than losing them.
- A file with a swap file (open in another Neovim) is shown read-only. Binary files and submodules ("Subproject commit …") are read-only placeholders with diff mode off, and so is a symlink in the working tree ("Symbolic link → target"); HEAD and INDEX show the link text git stores. `compare` and `difftool` follow links.

## Status view and staging

- Tracked files open as `HEAD | WORKING TREE | INDEX`: the read-only past, the editable present, what will be committed.
- Only the columns that differ are shown, recomputed after every change. Columns are not sticky: nothing staged shows HEAD | WORKING TREE, everything staged shows HEAD | INDEX.
- Columns are removed only after DiffMerge's own actions (staging, discarding, stashing, ignoring, committing, continue / skip / abort, resolving conflicts, fetch / pull / push, switching, the log's actions), which end in `StatusView:after_change()`. Refreshes from outside (saving, focus, the watcher) only add columns, and a working-tree buffer with unsaved edits keeps its column. That way the column a change moves into always appears, so the change stays in view, and the window being edited never closes because of something else.
- One implementation stages from the diff windows of every status view (`stage_change`): `staging_frame()` maps the windows to versions (HEAD / WORKING TREE / INDEX) and to the directions allowed. Three columns: both ways; two-way Unstaged: stage only; two-way Staged: unstage only.
- `<Space>` toggles the line under the cursor between unstaged and staged (lazygit style). In the working tree it stages if it can, else unstages; in INDEX and HEAD it unstages if it can, else stages. With three columns the cursor then moves to the next change of the same state (wrapping to the top); with two, to the next changed line. `-` toggles the hunk; visual mode the selected lines.
- "The hunk / line under the cursor" is what is on screen. Staging hunks are computed in the direction the screen diffs the two versions (INDEX → WORKING TREE, HEAD → INDEX), then inverted where needed, because a diff is not symmetric; with the 'diffopt' algorithm; for a line or a selection also with linematch when 'diffopt' has it (the three columns suspend linematch, see *Merges* 8). A changed line goes with the line shown next to it, and partly staged hunks pair lines by their offset in the hunk (the alignment on screen), not in `git add -p` order.
- Staging from a diff window stages the buffer's text, unsaved edits included: what is on screen. Staging a file from the file panel stages the file on disk (`git add`).
- The new index content is built in Lua and written with `git hash-object -w --stdin` + `git update-index --cacheinfo`. Staging builds it from the index and working-tree lines and applies clean filters (`--path`), as `git add -p` does; unstaging builds it from the index and HEAD lines, without filters (`--no-filters`).
- When staging or discarding leaves no visible difference, the final newline (which a line diff does not show) moves along, so nothing is left behind that cannot be pointed at.
- Three columns: Vim's diff colours are muted, and each change is painted by its state from diff3(base = HEAD, local = WORKING TREE, remote = INDEX): local only = unstaged, both = staged, anything else = mixed. Mixed chunks are refined line by line: lines the index shares with the working tree are staged, lines where the index still has HEAD's text are unstaged (`stage.lua`). The overlay's namespaces are scoped to the view's windows (`nvim__ns_set`), so other windows of the real file stay clean.
- `X` discards unstaged changes only (the working tree gets the INDEX version back). The file is saved without autocommands (no format-on-save), unless the buffer had other unsaved edits. Staged changes and new files are refused (the file panel's `X` deletes an untracked file, after asking).
- Staging refuses an entry that is no longer in the status (committed or discarded elsewhere). Binary files, symlinks and submodules are staged as a whole only, from the file panel. An INDEX buffer of the same view with unsaved edits (the two-way views) blocks staging and discarding from its diff windows until it is written (see *Known limitations* for what is not checked).
- Conflicts: `-` on a resolved file saves it and runs `git add`, after checking for unresolved conflicts and markers. `<leader>1` / `<leader>3` in the file panel take LOCAL / REMOTE for the whole file and mark it resolved (`git rm` when that side deleted it).
- `status.three_way = false` keeps separate two-way diffs: Staged is HEAD | INDEX, Unstaged is INDEX | WORKING TREE, and the INDEX side is editable.

## Merges

1. **Auto-merge.** `diff3.lua` computes base → local and base → remote hunks with `vim.text.diff` (histogram), groups overlapping or touching hunks (git's rule) and classifies each group: `local`, `remote`, `both` (the same change) or `conflict`. It is used for the side windows' chunks, and as the merge itself when git cannot run (`git merge-file` ended by a signal or with an exit code above 127); otherwise the conflicts come from git (4, 5).
2. **Regions.** Each non-equal chunk is an extmark region in the merged buffer. A region's state is derived from its content, so manual edits and undo just work:
   - `picks`: the ordered sources (1 = local, 2 = base, 3 = remote) whose concatenation equals the content; `nil` = unresolved (showing the base text), `{}` = resolved with nothing;
   - `edited`: the content matches no combination (a manual resolution, counts as resolved), unless it contains conflict markers (unresolved).
3. **Conflict markers are never written.** A file with git's markers is converted when shown in a modifiable buffer: every block becomes an unresolved conflict showing its BASE text. Undo back to the text before the conversion jumps to the conversion's undo state (`:undo <seq>`), so the markers do not come back, and redo survives. This holds for the buffer's undo history as DiffMerge converted it; see *Known limitations*.
4. **git's markers.** A file with git's markers keeps git's merge (rerere, fixes by hand, merge drivers). `markers.lua` parses the blocks in any style (merge, diff3, zdiff3) and any marker size of 7 or more (gitattributes `conflict-marker-size`). A block's sides are located in LOCAL / REMOTE by diffing "the file with every block as ours / theirs" against them. Its BASE text is the block's own base section (diff3, zdiff3), or in git's default style the BASE lines its sides replace: each BASE line goes to the first block that claims it, because that style can split one base change into two blocks. The conflicts are git's blocks: nearby conflicts joined, split ones split. A block changed by hand keeps its markers and stays unresolved; blocks that a side has as text (a file showing conflict markers) stay text.
5. **No markers, or shown again.** The model is git's own merge of the three versions: `git merge-file -p --diff-algorithm=histogram` (like merge-ort; retried without the option when git does not know it), run in the repository so merge.conflictStyle applies. Every line is prefixed with a letter: merge-file also joins conflicts separated only by lines without letters or digits, and with every line starting with a letter there are none, so it joins exactly as `git merge` does; and no content line can look like a marker. Every block shows its BASE text; one-sided and identical chunks that git merged the same way are regions too (signs). A file exactly equal to the model written with markers takes the model's parts. The current file is diffed against the model: untouched regions are still unresolved. When regions are placed this way (without the conversion cache, 6), insertions at a region's edge are tried as part of it first when that makes its content a known resolution.
6. **Conversion cache** (`converted[path]` in `merge.lua`): the text before and after the conversion, its undo seq, the placed regions, the sides. It exists only for files converted from markers in this Neovim session. The regions are stored when a view leaves the file; re-attaching (layout cycle, entry switch, counting unresolved conflicts, mergetool exit) reuses them, so the blocks never depend on deriving git's structure again. It is dropped when the sides change, when the file is read again with markers, and after continue / skip / abort.
7. **Region marks.** Text inserted at a region's edge stays outside it: the start mark moves with insertions, the end mark does not, so typing next to an unresolved conflict never resolves it while it is shown. A replaced region (inverted marks) takes the new text. Modify / delete conflicts stay unresolved until touched (any edit or pick); an emptied file is offered for deletion (`git rm`) when marked resolved.
8. **Overlay.** Vim's `DiffAdd` / `DiffChange` / `DiffText` / `DiffTextAdd` are muted with 'winhighlight' in merge windows (Vim compares every window with every other, which is noise in 3 and 4 columns); filler lines stay. The overlay uses range extmarks (`hl_group` + `hl_eol`), because diff mode ignores `line_hl_group` on changed lines. "linematch" is removed from 'diffopt' while a merge or the three status columns are on screen: it staggers the versions of a chunk across three or more windows. Each pane shows what that side changed relative to BASE; the merged pane shows the state: auto-merged (sign `L` / `R` / `=`), unresolved (red, `!`), resolved (the picks, e.g. `13`), edited (`✎`).
9. **Resolving.** `<leader>1` / `<leader>2` / `<leader>3` toggle LOCAL / BASE / REMOTE in the chunk under the cursor, from any window of the merge (KDiff3 style): toggling appends or removes, so `1` then `3` is "mine, then theirs"; toggling off the last pick makes the chunk unresolved again. `<leader>0` resolves with nothing. `]x` / `[x` move between conflicts, and in merge windows `]c` / `[c` are DiffMerge's own jumps between changes.
10. **git mergetool.** Neovim exits with code 1 (`cquit 1` in `VimLeavePre`) while conflicts are unresolved, the merged file is unsaved, or it still has git's markers on disk; git then restores the file and reports the merge as failed. The check is registered apart from the view, so it holds also after the view was closed, for the rest of that Neovim: `:DiffMerge mergetool` is git's entry point (inside a session, `:DiffMerge conflicts` resolves conflicts). `:DiffMerge abort` quits with 1 explicitly, also after the view was closed; in that Neovim it never aborts the merge itself. This needs `trustExitCode = true`.

## Changed characters (inline)

- Merge windows and the three status columns mute Vim's diff colours, so `inline.lua` paints the changed characters itself, following 'diffopt' (`inline:char` / `word` / `simple` / `none`, `iwhite*`, `icase`), and repaints when 'diffopt' changes.
- The lines of a changed block are compared row by row, the way the views show them (they suspend linematch); results are memoised per line pair; lines longer than 1000 bytes are not refined.
- What a line is compared with: in a conflict LOCAL against REMOTE (what the choice is about); a one-sided change against BASE; MERGED against BASE; in the status columns, per the `REF` table of `stage.lua` (an unstaged line against INDEX, a staged one against HEAD).
- Neovim draws 'cursorline' on top of these colours, so these windows set 'cursorlineopt' to `number`.

## Log and history

- The log is `git log --graph` with git's own colours (SGR parsed by `ansi.lua`), streamed, in a configurable pretty format.
- The selected row decides what the file panel and the diff windows show: the Working tree row is the status (staging), the Index row is what a commit takes (Conflicts and Staged), a commit, two marks or a range are a read-only comparison (*Git semantics*). Hiding the log keeps what it selected.
- The first time the log is shown it starts on the Working tree row, unless the status has nothing to show (no changes, no stash): then on HEAD.
- The log follows the repository. After each refresh `refs_now()` compares the branches, remote branches and tags, and HEAD's branch and commit; when they moved, the log reloads (a hidden log, when it is shown again), keeps the old log on screen until the new one is complete, and finds the selected row and the marks again by their commits. A marked commit that is gone clears the marks.
- `:DiffMerge history <path>` follows renames of a single file (`--follow`, when `log.follow_renames` is on). With a range it is line history (`git log -L`).
- Stash sections are shown in views without paths only.

## Repository actions

- **Running git.** `commit.run_git` runs a git command with `GIT_EDITOR` = `scripts/git-editor.lua`: a headless Neovim that asks the running one over RPC to edit the file in a window below, and waits. `:wq` goes on; `:q!` / `ZQ` (or an empty message) aborts. git runs in a process group of its own, so stopping it stops its hooks too. After each step `operation.after` reads the merges again, shows the view again and checks the files changed on disk.
- **One at a time.** The commands with git's editor (commit, continue / skip / abort, rewriting, cherry-pick, revert, tag) run one at a time in a Neovim, because git's editor answers here. `cc`, `ca`, `T` or continue / skip / abort in the same repository offer to stop the running one (a hook that does not end); a command with git's editor from another repository is refused, naming where the running one is; `C`, `X`, `r` and rewriting are refused while any of them runs, in any repository. Fetch / pull / push and switching run one at a time per repository (`remote.lua`); their key offers to stop the running one. While a commit runs, what is staged in its repository stays as it is (git commits the index it started with): no staging, pull or switch there; fetch and push still run.
- **No prompts.** git never asks on a terminal (`GIT_TERMINAL_PROMPT=0`, its own process group): fetch / pull / push need credentials from a helper or an agent. Quitting Neovim waits up to 20 s for a running fetch / pull / push, then stops it.
- **Unsaved edits.** Continue refuses while files have unsaved edits; skip / abort ask, naming the ones git writes over; taking a whole file asks, saying its unsaved changes are lost. What DiffMerge put into a conflicted file to show it does not count there. Pull, switch, cherry-pick, revert, a hard reset and rewriting refuse while any file of the repository has unsaved edits; stashing refuses for the files it stashes or applies; a converted conflict counts there (see *Known limitations*). `commit.blocked` stops new commands while a rebase's todo list is open in an editor, a pull runs, or the INDEX buffer has unsaved edits.
- **Commit.** `cc` / `ca` are git's own commit: template, hooks, merge message, cleanup of `#` lines. git commits the index it started with, so what is staged stays as it is until the commit is done.
- **Something going on** (`git.operation`: a merge, rebase, cherry-pick, revert or `git am`): `cc` continues it. The `c` menu offers Continue; Commit what is staged at a rebase stop that is not a conflict (edit, `break`, a failing `exec`); Skip when git can skip (not between two commits of a cherry-pick or revert); Abort. Skip and Abort ask first, naming the files whose unsaved edits git writes over.
- **Rewriting** (`rewrite.lua`: `cf` / `cs` / `cr` / `cd` on a commit of the log): `git rebase -i --autostash --no-autosquash` with `GIT_SEQUENCE_EDITOR` = `scripts/rebase-todo.lua`, which changes one line of the todo list (`squash`, `reword`, `drop`, or `move-fixup` after `git commit --fixup`); the user never edits it. Refused for a commit not in HEAD's history, a merge commit (for a squash also its parent) or one with a merge commit after it, a squash of the root commit, while an operation or another command runs, with unsaved files, and `cf` with nothing staged. A commit already in the upstream branch is asked about first. `:q!` in the message aborts the whole rewrite; a fixup that does not happen is reset softly (what was staged stays staged). Afterwards DiffMerge says where the branch was and the reset that goes back.
- **Log actions** (`commits.lua`): `C` and `X` take the visual range, else the two marks, else the commit under the cursor, oldest first; `r` and `T` take the commit under the cursor. `C` cherry-picks (commits already in HEAD left out); `X` reverts (one: its message to edit, `:q!` rolls back only if nothing was staged before; several: newest first; a commit not in HEAD's history is asked about); `r` resets soft / mixed / hard (hard asks: how many files lose changes, untracked files written over; refused with unsaved files); `T` tags (a message: annotated; empty: lightweight `--no-sign`). Merge commits are not cherry-picked or reverted. The marks are cleared after `C` / `X`, and by `^`.
- **Fetch / pull / push** (`remote.lua`): in the background. Pull is plain `git pull`, so the user's config decides how. Push offers to set an upstream; when rejected because the branch was rewritten on top of the remote's, it offers `--force-with-lease --force-if-includes`, never `--force`.
- **Branches** (`branch.lua`): `b` switches from a picker (`git switch`); `b` on a commit of the log checks it out (its branch, else a branch following a remote one there, detached, or a new branch). Uncommitted changes in the way go along: stash, switch, pop, and only that stash is taken back.
- **Stashes** (`stash.lua`): `s` stashes from a menu (staged changes, these files, all changes, with untracked files, keeping the staged ones). Staged changes go with `git stash push --staged` when `git apply -R --check` says it can take them out; otherwise (staged lines next to unstaged ones) with a fallback of DiffMerge's own. Stashes are folded sections of the status; a stashed file opens like a change, read-only.
- **Ignoring** (`ignore.lua`, `i` in the file panel): a menu of `.gitignore` / `.git/info/exclude`, each by `/path` (anchored, escaped) or `*.ext`. Tracked files under the targets stop being tracked (`git rm --cached`). It asks first when the next commit would delete committed files from the repository: files in HEAD, a staged rename's old name, or any tracked file while an operation goes on; files that were only staged are just unstaged. Refused: conflicts, stashes, `.gitignore` itself, staged content that is neither committed nor on disk. The ignore file is written first and put back when `git rm` fails. Parts of a file cannot be ignored: git's ignore rules match paths (only clean filters strip lines), and DiffMerge does not invent a mechanism of its own.

## Keys

- Groups: `view` in every window (`g` + a letter for a part of the view, `]` / `[` to move on); `repo` in both panels of status views (commit, stash, fetch / pull / push); the staging keys the same in the file panel and the diff windows (`-`, `<Space>`, `X`); `merge` in the windows of a merge. A panel's own group (`file_panel`, `log_panel`) is applied last and wins there; `false` turns a key off in that panel only.
- `<Space>` toggles a line, as in lazygit. Merge picks are `<leader>1` / `2` / `3` / `0`: bare digits would break counts. Toggle tree / list is `` ` `` (lazygit's key), because `i` ignores. In the log, `^` cycles the parent of a merge and `g^` toggles --first-parent: the mnemonic `P` / `F` are taken by push / fetch.
- Mappings are buffer-local and act only in a tab with a view. A real file buffer shown by a view keeps the key's built-in meaning in other tabs (see *Known limitations* for mappings of your own).
- `g?` lists the keys grouped by function, the current window's section first.

## git difftool, mergetool, compare

- `git difftool -d` passes two temporary directories; DiffMerge compares them itself (exact-content rename detection). When the right side is the working tree (not with `--staged`), git links its files into the temporary directory by default, so saving writes the working tree at once; with `--no-symlinks` git copies the edits back when Neovim exits.
- `git mergetool`: see *Merges* (10). `:DiffMerge conflicts` (the `git mt` alias) resolves all conflicts in one Neovim.
- git's difftool passes `GIT_WORK_TREE=.`; it is made absolute (`git.absolute_work_tree()`).
- `:DiffMerge compare` shows any two files or directories, both sides editable.

## Compatibility

- Breadcrumb plugins that write the winbar of LSP buffers can overwrite DiffMerge's labels. This is fixed in your own config (the lspsaga snippet in the README), not in DiffMerge: those writes happen inside autocommands, where `OptionSet` does not fire, so DiffMerge cannot reliably keep its label.

## Implementation rules

Rules every change must keep; each was learned from a bug. (Timings were measured on a laptop.)

- git always runs in the repository root, so user pathspecs are made root-relative (`git.pathspec`).
- Paths from git are read with `-z` (`git_parse.records`): `core.quotePath=false` still quotes `"`, `\`, tabs and newlines.
- Never one pathspec argument per file: a committed `node_modules` exceeds the command line (E2BIG). Give a list of paths on stdin (`git.run_on_paths`: `--pathspec-from-file=- --pathspec-file-nul` with `GIT_LITERAL_PATHSPECS=1`; an empty list does nothing). That removes the limit, not git's matching of every path against every pathspec, which is quadratic: where that matters, read whole listings (`ls-files -z`, `ls-tree -r`) and filter them in Lua (`ignore.under`), or pass a few directory pathspecs.
- `git rm --cached` without `-f` is quadratic (17 s for 12k files): `ignore.plan` checks for staged content that would be lost itself, then runs `rm -f`.
- Lua patterns: an unanchored `([^%z]+)$` rescans from every position (2 s for 12k records). Anchor the search or scan once.
- Window options of diff windows are set with `util.set_wo` (local scope): `vim.wo[win]` on the current window also sets the global value, which closing a view restores from.
- What follows a `vim.ui.select` choice runs through `util.after_select`: pickers that run in a terminal (fzf-lua) call back while their window closes, and closing it leaves insert mode, so an input opened from the callback would start in normal mode.
- `redraw!` runs only when a UI is attached (headless Neovim has no screen to redraw).
- git versions: `--pathspec-from-file` needs 2.25 (`add`, `reset`, `restore`) and 2.26 (`rm`); `git stash push --staged` 2.35; `--force-if-includes` 2.30. `:checkhealth diffmerge` says so.

## Known limitations

These are expected behaviour, not bugs.

- The status view is slow with many entries: about 8 s for 50k staged deletions (e.g. after ignoring a committed `node_modules`), and slower still with very long paths. The cost is in drawing the file panel, not in git.
- Staging, unstaging or discarding tens of thousands of files from the file panel is slow: git matches every path against every pathspec (12k paths: about 1.6 s on a laptop), and past roughly 35k paths git is stopped after 30 s.
- Stashing chosen files ("This file / These files") is limited by git: `git stash push` hands the paths to its own `git add` on a command line, so more paths than a command line holds fail.
- `i` on a section header writes one pattern per file, not one per directory. In views that are not status views, `i` is not mapped.
- The watcher does not see moves of remote branches, tags, `packed-refs`, `FETCH_HEAD` or branches with a `/` in their name (a commit on such a branch is still seen through the index): a fetch made elsewhere shows when Neovim gets focus or another refresh comes.
- After a conflict was shown without an operation going on (e.g. a `stash apply` that conflicts), its converted buffer counts as unsaved for pull, switch, cherry-pick, revert, a hard reset, rewriting and stashing that file: they refuse until it is saved, and saving writes what is shown (the BASE text of open conflicts).
- The file panel's staging keys check no INDEX buffer, and staging from the diff windows checks only its own view's: an editable INDEX buffer with unsaved edits in another two-way view or a `:DiffMerge diff` is not checked, and writing it afterwards overwrites what was staged.
- A conflict resolved to exactly its BASE text (`<leader>2`, or `<leader>0` where BASE is empty) looks unresolved. Without the conversion cache (a new session, or a file that had no markers when shown) it counts as unresolved.
- A modify / delete conflict resolved with a pick shows unresolved again when the file is shown anew (it has no markers, so no conversion cache); the file panel's `<leader>1` / `<leader>3` resolve the whole file.
- In a new session, a file saved half-resolved whose markers came in a style other than merge.conflictStyle (`git checkout --conflict=diff3`) can show its conflicts joined differently; a joined region that matches no combination then counts as edited, that is resolved.
- After a converted file is read again from disk ('undoreload' on `:e!`), or with an undo file in a later session, undo can reach git's markers again.
- When a key of a view is pressed in another tab that shows the same real file, it does Vim's built-in action; a mapping of your own for that key does not run there.
- Line history (`-L`) starts on HEAD and has no Working tree / Index rows.

## Testing

- `tests/run.sh` runs each `tests/*_spec.lua` in a fresh headless Neovim, with the small harness of `tests/harness.lua` (no busted / plenary), against throwaway repositories.
- Rendering is checked by hand in a terminal (tmux `capture-pane`); the README's GIFs (`demo/`, recorded with `demo/render.sh`) go through the main flows.
