#!/bin/sh
set -eu

# Optional JavaScript workspace preparation used by after_create and before_run.
if [ ! -f package-lock.json ]; then
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "workspace dependency preparation failed: npm is unavailable" >&2
  exit 1
fi

mkdir -p .symphony
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exclude_file=$(git rev-parse --git-path info/exclude)
  if [ -f "$exclude_file" ] && ! grep -Fqx '.symphony/' "$exclude_file"; then
    printf '\n.symphony/\n' >> "$exclude_file"
  fi
fi

exec 9>.symphony/deps.lock
flock -w 10 9 || {
  echo "workspace dependency preparation failed: lock busy" >&2
  exit 1
}

lock_hash=$(sha256sum package-lock.json | cut -d ' ' -f 1)
if [ -d node_modules ] && [ -f .symphony/deps-ready ] &&
   [ "$(cat .symphony/deps-ready)" = "$lock_hash" ]; then
  exit 0
fi

# Keep the command below the 300-second workspace hook ceiling.
timeout --signal=TERM --kill-after=5s 240s npm ci --no-audit --no-fund
if [ ! -d node_modules ]; then
  echo "workspace dependency preparation failed: node_modules missing after npm ci" >&2
  exit 1
fi
printf '%s\n' "$lock_hash" > .symphony/deps-ready.tmp
mv .symphony/deps-ready.tmp .symphony/deps-ready
