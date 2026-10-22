#!/bin/sh
set -eu

mkdir -p .symphony/validation
summary=.symphony/validation/summary.txt
: > "$summary"
overall=0

run_check() {
  name=$1
  shift
  log=".symphony/validation/$name.log"
  if "$@" >"$log" 2>&1; then
    status=0
  else
    status=$?
    overall=1
  fi
  printf '%s exit=%s log=%s\n' "$name" "$status" "$log" | tee -a "$summary"
  if [ "$status" -ne 0 ]; then
    printf '%s error_tail:\n' "$name" | tee -a "$summary"
    tail -n 20 "$log" | tee -a "$summary"
  fi
}

run_check build npm run build
run_check lint npm run lint

printf 'validation_overall_exit=%s summary=%s\n' "$overall" "$summary"
exit "$overall"
