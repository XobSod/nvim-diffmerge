#!/usr/bin/env bash
# Runs every tests/*_spec.lua (or the given ones) in a fresh headless Neovim.
set -u
cd "$(dirname "$0")/.."
specs=("$@")
if [ ${#specs[@]} -eq 0 ]; then
  specs=(tests/*_spec.lua)
fi
failed=0
for spec in "${specs[@]}"; do
  echo "== $spec"
  if ! nvim --headless --clean -l "$spec"; then
    failed=1
  fi
done
exit $failed
