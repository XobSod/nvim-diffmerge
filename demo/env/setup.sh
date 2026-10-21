# Sourced by the tapes (hidden): `source demo/env/setup.sh <status|merge|log|commit>` makes
# the demo repository ~/fetch.nvim in that state (repo.sh; HOME=/tmp/diffmerge-demo), goes
# there and sets up the shell.

case $1 in
status | merge | log | commit) ;;
*)
  echo "usage: source demo/env/setup.sh <status|merge|log|commit>" >&2
  return 2
  ;;
esac

XDG_CONFIG_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export HOME=/tmp/diffmerge-demo XDG_CONFIG_HOME
export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state XDG_CACHE_HOME=$HOME/.cache
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_NOSYSTEM=1
export EDITOR=nvim

# (a process of its own: a sourced file's set -e is off in `source … && clear`)
bash "$XDG_CONFIG_HOME/repo.sh" "$1" || {
  echo "demo/env/setup.sh: making the demo repository failed" >&2
  return 1
}
cd ~/fetch.nvim || return

__demo_branch() {
  local b
  b=$(git branch --show-current 2>/dev/null) || return
  [ -n "$b" ] || return
  [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && b="$b|MERGING"
  printf ' (%s)' "$b"
}
PS1='\[\e[1;34m\]\W\[\e[0;35m\]$(__demo_branch)\[\e[0m\] \$ '
