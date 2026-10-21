# The status view: staging a hunk and single lines, editing the working tree
Output demo/gifs/status.gif
Source demo/tapes/settings.tape

Hide
Type "source demo/env/setup.sh status && clear"
Enter
Type "nvim lua/fetch/init.lua"
Enter
Sleep 1.5s
Show

Sleep 1s
Type ":DiffMerge"
Sleep 500ms
Enter
Wait+Screen /git status/
Sleep 2s
Type "]c"
Sleep 1s
Type "-"
Sleep 2.5s
Type "]c"
Sleep 1s
Space
Sleep 1.5s
Space
Sleep 2.5s

Type "[f"
Sleep 2s
Type "o"
Type "backoff = 100, -- ms"
Escape
Sleep 500ms
Type ":w"
Sleep 400ms
Enter
Sleep 1.5s
Space
Sleep 3s
