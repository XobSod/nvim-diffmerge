# Committing from the status view, then a fixup into an older commit from the log
Output demo/gifs/commit.gif
Source demo/tapes/settings.tape

Hide
Type "source demo/env/setup.sh commit && clear"
Enter
Type "nvim"
Enter
Sleep 1s
Show

Sleep 800ms
Type ":DiffMerge log"
Sleep 500ms
Enter
Wait+Screen /git log --branches/
Sleep 2s
Ctrl+W
Type "k"
Sleep 1s
Type "k"
Sleep 800ms
Type "-"
Sleep 2s
Type "cc"
Wait+Screen /Please enter the commit message/
Sleep 1.5s
Type "i"
Type "Retry failed requests"
Escape
Sleep 800ms
Type ":wq"
Sleep 400ms
Enter
Wait+Screen /\[master [0-9a-f]+\] Retry failed requests/
Sleep 2.5s
Type "-"
Sleep 2s
Ctrl+W
Type "j"
Sleep 800ms
Type@250ms "jjjj"
Sleep 2s
Type "cf"
Wait+Screen /fixed up/
Sleep 3s
Type "]f"
Sleep 3.5s
