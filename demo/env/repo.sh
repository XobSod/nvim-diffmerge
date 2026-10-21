#!/usr/bin/env bash
# The demo repository ~/fetch.nvim in the state of a tape (status, merge, log or commit): run by
# demo/env/setup.sh, which sets HOME=/tmp/diffmerge-demo.
set -euo pipefail
if [ "$HOME" != /tmp/diffmerge-demo ]; then
  echo "demo/env/repo.sh: run by demo/env/setup.sh" >&2
  exit 2
fi
export GIT_CONFIG_GLOBAL=$HOME/.gitconfig GIT_CONFIG_NOSYSTEM=1
cd /
rm -rf /tmp/diffmerge-demo
mkdir -p ~/fetch.nvim/lua/fetch
git config --global init.defaultBranch master
git config --global user.name XobSod
git config --global user.email xobsod@gmail.com
git config --global alias.mt '!nvim -c "DiffMerge conflicts"'
git config --global advice.mergeConflict false
cd ~/fetch.nvim
git init -q

demo_now=$(date +%s)
# demo_commit <hours ago> <message>
demo_commit() {
  local when="@$((demo_now - $1 * 3600)) +0000"
  git add -A
  GIT_AUTHOR_DATE=$when GIT_COMMITTER_DATE=$when git commit -q -m "$2"
}

# demo_init <version>: lua/fetch/init.lua
demo_init() {
  {
    [ "$1" = 1 ] || printf 'local config = require("fetch.config")\n\n'
    echo 'local M = {}'
    [ "$1" = retries ] && printf '\nlocal function delay(attempt)\n  return 2 ^ attempt * 100\nend\n'
    echo
    echo '--- GET `url`; `cb(err, body)`.'
    if [ "$1" = retries ]; then
      printf 'function M.get(url, cb, attempt)\n  attempt = attempt or 1\n'
    else
      echo 'function M.get(url, cb)'
    fi
    if [ "$1" = 1 ]; then
      echo '  local cmd = { "curl", "-sS", url }'
    else
      cat <<'EOF'
  local opts = config.options
  local cmd = {
    "curl", "-sS",
    "-m", tostring(opts.timeout),
    "-A", opts.user_agent,
  }
EOF
    fi
    case $1 in
    headers | errors | retries)
      cat <<'EOF'
  for k, v in pairs(opts.headers) do
    table.insert(cmd, "-H")
    table.insert(cmd, k .. ": " .. v)
  end
EOF
      ;;
    esac
    [ "$1" = 1 ] || echo '  table.insert(cmd, url)'
    echo '  vim.system(cmd, {}, function(res)'
    case $1 in
    errors)
      printf '    if res.code ~= 0 then\n      return cb(res.stderr)\n    end\n'
      ;;
    retries)
      cat <<'EOF'
    if res.code ~= 0
      and attempt <= opts.retries then
      local again = function()
        M.get(url, cb, attempt + 1)
      end
      local ms = delay(attempt)
      return vim.defer_fn(again, ms)
    elseif res.code ~= 0 then
      return cb(res.stderr)
    end
EOF
      ;;
    esac
    printf '    cb(nil, res.stdout)\n  end)\nend\n\nreturn M\n'
  } >lua/fetch/init.lua
}

cat >README.md <<'EOF'
# fetch.nvim

HTTP requests from Neovim, without
blocking the editor.
EOF
demo_init 1
demo_commit 190 "Initial commit"

cat >lua/fetch/config.lua <<'EOF'
-- Options of fetch.nvim.
local M = {}

M.defaults = {
  -- seconds before giving up
  timeout = 5,
  user_agent = "fetch.nvim",
}

M.options = M.defaults

function M.setup(opts)
  M.options = vim.tbl_extend(
    "force", M.defaults, opts or {})
end

return M
EOF
demo_commit 170 "Add options with defaults"

demo_init 2
demo_commit 150 "Use the timeout and user agent"

cat >>README.md <<'EOF'

## Usage

```lua
require("fetch").setup({ timeout = 10 })
require("fetch").get(url, function(err, body)
  -- called when the response arrives
end)
```
EOF
demo_commit 120 "Document setup() and get()"

git switch -q -c feature/headers
sed -i 's/^  user_agent = "fetch.nvim",$/&\n  headers = {},/' lua/fetch/config.lua
demo_init headers
demo_commit 100 "Send custom headers"
cat >>README.md <<'EOF'

## Options

- `timeout`: seconds before giving up
- `user_agent`: sent with every request
- `headers`: e.g. `{ Accept = "text/html" }`
EOF
demo_commit 98 "Document the options"
git switch -q master
GIT_AUTHOR_DATE="@$((demo_now - 96 * 3600)) +0000" GIT_COMMITTER_DATE="@$((demo_now - 96 * 3600)) +0000" \
  git merge -q --no-ff -m "Merge branch 'feature/headers'" feature/headers
git branch -q -d feature/headers

demo_init errors
demo_commit 80 "Report curl errors"
sed -i 's|^  user_agent = "fetch.nvim",$|  user_agent = "fetch.nvim/0.1",|' lua/fetch/config.lua
demo_commit 76 "Put the version in the user agent"
git tag v0.1.0

git switch -q -c feature/cache
cat >lua/fetch/cache.lua <<'EOF'
local M = {}

local entries = {}

function M.get(url)
  return entries[url]
end

function M.put(url, body)
  entries[url] = body
end

return M
EOF
demo_commit 50 "Cache responses in memory"
git switch -q master

sed -i 's/^  headers = {},$/&\n  follow_redirects = true,\n  verbose = false,/' lua/fetch/config.lua
cat >>README.md <<'EOF'
- `follow_redirects`: follow HTTP redirects
- `verbose`: log every reqeust
EOF
demo_commit 30 "Add follow_redirects and verbose"

cat >lua/fetch/health.lua <<'EOF'
local M = {}

function M.check()
  vim.health.start("fetch.nvim")
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found")
  else
    vim.health.error("curl not found")
  end
end

return M
EOF
demo_commit 20 "Add a health check"

case $1 in
status | commit)
  demo_init retries
  sed -i 's/^  verbose = false,$/&\n  retries = 3,/' lua/fetch/config.lua
  if [ "$1" = commit ]; then
    sed -i 's/reqeust/request/' README.md
  fi
  ;;
merge)
  # two conflicts (timeout; an option added after verbose): git joins conflicts with fewer
  # than 4 unchanged lines between them
  git switch -q -c feature/retries
  sed -i 's/^  timeout = 5,$/  timeout = 10,/; s/^  verbose = false,$/&\n  retries = 3,/; s/tbl_extend(/tbl_deep_extend(/' lua/fetch/config.lua
  demo_commit 6 "Retry failed requests"
  git switch -q master
  sed -i 's/^-- Options of fetch.nvim.$/-- Options of fetch.nvim (:h fetch)./; s/^  timeout = 5,$/  timeout = 30,/; s/^  verbose = false,$/&\n  max_size = 1e6, -- bytes/' lua/fetch/config.lua
  demo_commit 4 "Longer timeout, limit the size"
  ;;
log)
  sed -i 's/^  verbose = false,$/&\n  retries = 3,/' lua/fetch/config.lua
  ;;
esac
