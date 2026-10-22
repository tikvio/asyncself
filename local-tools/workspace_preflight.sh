#!/bin/sh
set -eu

printf '%s\n' 'workspace-preflight'
printf 'branch: '; git branch --show-current
printf 'head: '; git rev-parse --short HEAD
printf 'status_count: '; git status --porcelain=v1 | wc -l | tr -d ' '
printf 'deps_ready: '
if [ -f .symphony/deps-ready ]; then printf 'yes\n'; else printf 'no\n'; fi
printf '%s\n' 'changed_files:'
git status --porcelain=v1 | sed -n '1,20p'
printf '%s\n' 'relevant_files:'
find src -maxdepth 4 -type f \( -name '*.ts' -o -name '*.tsx' \) -print 2>/dev/null | sed -n '1,40p'
