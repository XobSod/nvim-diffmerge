# Merge conflicts: git merge in the shell, resolved in the merge view, committed
Output demo/gifs/merge.gif
Source demo/tapes/settings.tape

Hide
Type "source demo/env/setup.sh merge && clear"
Enter
Sleep 500ms
Show

Sleep 1s
Type "git merge feature/retries"
Sleep 500ms
Enter
Wait+Screen /Automatic merge failed/
Sleep 1.5s
Type "git mt"
Sleep 500ms
Enter
Wait+Screen /conflicts resolved/
Sleep 2.5s
Type ",1"
Sleep 2s
Type "]x"
Sleep 1.2s
Type ",1"
Sleep 1.5s
Type ",3"
Sleep 2.5s
Type "gl"
Sleep 1.5s
Type "gl"
Sleep 3s
Type ":w"
Sleep 400ms
Enter
Sleep 1s
Ctrl+W
Type "h"
Sleep 1s
Type "-"
Sleep 2s
Type "cc"
Wait+Screen /Please enter the commit message/
Sleep 2s
Type ":wq"
Sleep 400ms
Enter
Wait+Screen /\[master [0-9a-f]+\] Merge branch/
Sleep 1.5s
Type "gL"
Sleep 3.5s
