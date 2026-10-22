#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${SYMPHONY_ROOT:-$(dirname "$script_dir")}
profile=${SYMPHONY_PROFILE:-gitlab}

"$root/local-tools/prepare_workspace_deps.sh"

skills="commit pull push"
[ "$profile" != github ] || skills="$skills land"
for skill in $skills; do
  source_skill="$root/.codex/skills/$skill"
  target_skill=".codex/skills/$skill"
  if [ ! -f "$source_skill/SKILL.md" ]; then
    echo "workspace preparation failed: skill is missing under $source_skill" >&2
    exit 1
  fi
  if [ ! -f "$target_skill/SKILL.md" ]; then
    mkdir -p "$target_skill"
    cp "$source_skill/SKILL.md" "$target_skill/SKILL.md"
    [ ! -f "$source_skill/land_watch.py" ] || cp "$source_skill/land_watch.py" "$target_skill/land_watch.py"
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exclude_file=$(git rev-parse --git-path info/exclude)
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  if ! grep -Fqx '.codex/skills/' "$exclude_file"; then
    printf '\n.codex/skills/\n' >> "$exclude_file"
  fi
fi
