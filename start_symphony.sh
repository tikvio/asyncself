#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASYNCSELF_SETTING_SUFFIXES=(
  ROOT ACTIVE_PROFILE_FILE PROFILE CODE_HOST ENV_FILE SHARED_ENV_FILE WORKFLOW
  LINEAR_PROJECT_SLUG LINEAR_PROJECT_SLUG_ID LINEAR_PROJECT_ID
  GATEKEEPER_ACTIVE_LABEL REPOSITORY_URL GITHUB_REPOSITORY GITHUB_REQUIRED_CHECK
  GITLAB_HOST GITLAB_PROJECT TARGET_BRANCH SOURCE_REPO WORKSPACE_ROOT
  GATEKEEPER_PIPELINE_ROOT RUNTIME_DIR GATEKEEPER_STATE_FILE
  GATEKEEPER_LOCK_FILE GATEKEEPER_OBSERVATION_FILE MR_WATCHER_LOCK_ROOT
  WEBHOOK_CONFIG PORT AUX_STACK_LOCK AUX_RESTART_DELAY_SECONDS
  MR_WATCHER_POLL_SECONDS GATEKEEPER_POLL_SECONDS WEBHOOK_PYTHON
)

sync_asyncself_settings() {
  local suffix new_name legacy_name new_value legacy_value
  for suffix in "${ASYNCSELF_SETTING_SUFFIXES[@]}"; do
    new_name="ASYNCSELF_${suffix}"
    legacy_name="SYMPHONY_${suffix}"
    new_value="${!new_name:-}"
    legacy_value="${!legacy_name:-}"
    if [[ -n "$new_value" && -n "$legacy_value" && "$new_value" != "$legacy_value" ]]; then
      printf 'Configuration conflict: %s and %s differ\n' "$new_name" "$legacy_name" >&2
      exit 2
    fi
    if [[ -n "$new_value" ]]; then
      printf -v "$legacy_name" '%s' "$new_value"
      export "$legacy_name"
    elif [[ -n "$legacy_value" ]]; then
      printf -v "$new_name" '%s' "$legacy_value"
      export "$new_name"
    fi
  done
}

sync_asyncself_settings
ASYNCSELF_ROOT="${ASYNCSELF_ROOT:-${SYMPHONY_ROOT:-$SCRIPT_DIR}}"
SYMPHONY_ROOT="$ASYNCSELF_ROOT"
export ASYNCSELF_ROOT SYMPHONY_ROOT
sync_asyncself_settings
ACTIVE_PROFILE_FILE="${SYMPHONY_ACTIVE_PROFILE_FILE:-$SYMPHONY_ROOT/local-config/active-profile}"
CLI_PROFILE=""
AUX_ONLY=0
CHECK_ONLY=0

usage() {
  printf 'Usage: %s [--profile gitlab|github] [--check] [--aux-only]\n' "$0"
}

while (($#)); do
  case "$1" in
    --profile)
      shift
      (($#)) || { printf '%s\n' '--profile requires a value' >&2; exit 2; }
      CLI_PROFILE="$1"
      ;;
    --profile=*) CLI_PROFILE="${1#*=}" ;;
    --check) CHECK_ONLY=1 ;;
    --aux-only) AUX_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$CLI_PROFILE" && -n "${SYMPHONY_PROFILE:-}" && "$CLI_PROFILE" != "$SYMPHONY_PROFILE" ]]; then
  printf 'Profile conflict: --profile=%s but SYMPHONY_PROFILE=%s\n' "$CLI_PROFILE" "$SYMPHONY_PROFILE" >&2
  exit 2
fi

PROFILE="${CLI_PROFILE:-${SYMPHONY_PROFILE:-}}"
if [[ -z "$PROFILE" && -f "$ACTIVE_PROFILE_FILE" ]]; then
  IFS= read -r PROFILE < "$ACTIVE_PROFILE_FILE" || true
  PROFILE="${PROFILE//[[:space:]]/}"
fi
PROFILE="${PROFILE:-gitlab}"
case "$PROFILE" in
  gitlab|github) ;;
  *) printf 'Unsupported AsyncSelf profile: %s\n' "$PROFILE" >&2; exit 2 ;;
esac

PROFILE_ENV_DEFAULT="$SYMPHONY_ROOT/local-config/profiles/$PROFILE.env"
ENV_FILE="${SYMPHONY_ENV_FILE:-$PROFILE_ENV_DEFAULT}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ -n "${SYMPHONY_ENV_FILE:-}" ]]; then
  printf 'Explicit environment file is missing: %s\n' "$ENV_FILE" >&2
  exit 2
elif [[ "$PROFILE" == gitlab && -f "$SYMPHONY_ROOT/local-config/symphony.env" ]]; then
  # Backward compatibility for installations that predate profiles.
  ENV_FILE="$SYMPHONY_ROOT/local-config/symphony.env"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

sync_asyncself_settings

if [[ -n "${SYMPHONY_SHARED_ENV_FILE:-}" ]]; then
  if [[ ! -f "$SYMPHONY_SHARED_ENV_FILE" ]]; then
    printf 'Shared environment file is missing: %s\n' "$SYMPHONY_SHARED_ENV_FILE" >&2
    exit 2
  fi
  set -a
  # shellcheck disable=SC1090
  source "$SYMPHONY_SHARED_ENV_FILE"
  # Re-apply non-secret profile settings after shared credentials.
  [[ ! -f "$ENV_FILE" ]] || source "$ENV_FILE"
  set +a
fi

sync_asyncself_settings

if [[ -n "${SYMPHONY_PROFILE:-}" && "$SYMPHONY_PROFILE" != "$PROFILE" ]]; then
  printf 'Profile file mismatch: selected=%s configured=%s\n' "$PROFILE" "$SYMPHONY_PROFILE" >&2
  exit 2
fi
CODE_HOST="${SYMPHONY_CODE_HOST:-$PROFILE}"
if [[ "$CODE_HOST" != "$PROFILE" ]]; then
  printf 'Code host mismatch: profile=%s code_host=%s\n' "$PROFILE" "$CODE_HOST" >&2
  exit 2
fi

PORT="${SYMPHONY_PORT:-4000}"
RUNTIME_DIR="${SYMPHONY_RUNTIME_DIR:-$SYMPHONY_ROOT/local-config/runtime/$PROFILE}"
PIPELINE_ROOT="${SYMPHONY_GATEKEEPER_PIPELINE_ROOT:-$SYMPHONY_ROOT/local-tools/dependency_pipeline}"
PROJECT_SLUG="${SYMPHONY_LINEAR_PROJECT_SLUG:-}"
PROJECT_SLUG_ID="${SYMPHONY_LINEAR_PROJECT_SLUG_ID:-}"
PROJECT_ID="${SYMPHONY_LINEAR_PROJECT_ID:-}"
ACTIVE_LABEL="${SYMPHONY_GATEKEEPER_ACTIVE_LABEL:-your-required-label}"
SOURCE_REPO="${SYMPHONY_SOURCE_REPO:-$HOME/code/asyncself-sources/your-project}"
WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-$HOME/code/asyncself-workspaces}"
REPOSITORY_URL="${SYMPHONY_REPOSITORY_URL:-}"
GITHUB_REPOSITORY="${SYMPHONY_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
SYMPHONY_GITHUB_REPOSITORY="$GITHUB_REPOSITORY"
GITLAB_HOST="${SYMPHONY_GITLAB_HOST:-}"
GITLAB_PROJECT="${SYMPHONY_GITLAB_PROJECT:-}"
TARGET_BRANCH="${SYMPHONY_TARGET_BRANCH:-your-target-branch}"

case "$PROFILE" in
  gitlab)
    WORKFLOW_PATH="${SYMPHONY_WORKFLOW:-$SYMPHONY_ROOT/elixir/WORKFLOW.md}"
    WEBHOOK_CONFIG="${SYMPHONY_WEBHOOK_CONFIG:-$SYMPHONY_ROOT/local-config/profiles/gitlab.webhook.json}"
    [[ -f "$WEBHOOK_CONFIG" || ! -f "$SYMPHONY_ROOT/local-config/webhook.json" ]] || \
      WEBHOOK_CONFIG="$SYMPHONY_ROOT/local-config/webhook.json"
    ;;
  github)
    WORKFLOW_PATH="${SYMPHONY_WORKFLOW:-$SYMPHONY_ROOT/elixir/WORKFLOW.github.md}"
    WEBHOOK_CONFIG="${SYMPHONY_WEBHOOK_CONFIG:-$SYMPHONY_ROOT/local-config/profiles/github.webhook.json}"
    ;;
esac

export SYMPHONY_ROOT SYMPHONY_PROFILE="$PROFILE" SYMPHONY_CODE_HOST="$CODE_HOST"
export SYMPHONY_RUNTIME_DIR="$RUNTIME_DIR" SYMPHONY_GATEKEEPER_PIPELINE_ROOT="$PIPELINE_ROOT"
export SYMPHONY_LINEAR_PROJECT_SLUG="$PROJECT_SLUG" SYMPHONY_LINEAR_PROJECT_SLUG_ID="$PROJECT_SLUG_ID"
export SYMPHONY_LINEAR_PROJECT_ID="$PROJECT_ID"
export SYMPHONY_GATEKEEPER_ACTIVE_LABEL="$ACTIVE_LABEL" SYMPHONY_SOURCE_REPO="$SOURCE_REPO"
export SYMPHONY_WORKSPACE_ROOT="$WORKSPACE_ROOT" SYMPHONY_REPOSITORY_URL="$REPOSITORY_URL"
export SYMPHONY_GITHUB_REPOSITORY="$GITHUB_REPOSITORY" GITHUB_REPOSITORY="$GITHUB_REPOSITORY"
export SYMPHONY_GITLAB_HOST="$GITLAB_HOST" SYMPHONY_GITLAB_PROJECT="$GITLAB_PROJECT"
export SYMPHONY_TARGET_BRANCH="$TARGET_BRANCH" SYMPHONY_WEBHOOK_CONFIG="$WEBHOOK_CONFIG"
export SYMPHONY_GATEKEEPER_STATE_FILE="${SYMPHONY_GATEKEEPER_STATE_FILE:-$RUNTIME_DIR/gatekeeper-state.json}"
export SYMPHONY_GATEKEEPER_LOCK_FILE="${SYMPHONY_GATEKEEPER_LOCK_FILE:-$RUNTIME_DIR/gatekeeper.lock}"
export SYMPHONY_GATEKEEPER_OBSERVATION_FILE="${SYMPHONY_GATEKEEPER_OBSERVATION_FILE:-$RUNTIME_DIR/gatekeeper-observation.json}"
export SYMPHONY_MR_WATCHER_LOCK_ROOT="${SYMPHONY_MR_WATCHER_LOCK_ROOT:-$RUNTIME_DIR/mr-watcher-locks}"
sync_asyncself_settings

present() { [[ -n "${!1:-}" ]] && printf present || printf missing; }

configuration_check() {
  local failures=0
  local path
  for path in "$WORKFLOW_PATH" "$SOURCE_REPO" "$PIPELINE_ROOT/symphony_dependency_pipeline/gatekeeper.py" \
    "$SYMPHONY_ROOT/local-tools/symphony_gatekeeper_watch.py" "$WEBHOOK_CONFIG"; do
    if [[ ! -e "$path" ]]; then
      printf 'check error: missing %s\n' "$path" >&2
      failures=$((failures + 1))
    fi
  done
  if [[ -z "$PROJECT_SLUG" || -z "$PROJECT_SLUG_ID" || -z "$REPOSITORY_URL" || -z "$TARGET_BRANCH" ]]; then
    printf '%s\n' 'check error: project slug/slug ID, repository URL and target branch are required' >&2
    failures=$((failures + 1))
  fi
  if [[ "$PROJECT_SLUG" != "$PROJECT_SLUG_ID" && "$PROJECT_SLUG" != *-"$PROJECT_SLUG_ID" ]]; then
    printf '%s\n' 'check error: project slug does not match project slug ID' >&2
    failures=$((failures + 1))
  fi
  if [[ "$PROFILE" == github && -z "$PROJECT_ID" ]]; then
    printf '%s\n' 'check error: Linear project UUID is required for the GitHub profile' >&2
    failures=$((failures + 1))
  fi
  if [[ "$TARGET_BRANCH" == main ]]; then
    printf '%s\n' 'check error: main is forbidden as the experiment target branch' >&2
    failures=$((failures + 1))
  fi
  if [[ -d "$SOURCE_REPO/.git" ]] && ! git -C "$SOURCE_REPO" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH" && \
     ! git -C "$SOURCE_REPO" show-ref --verify --quiet "refs/remotes/origin/$TARGET_BRANCH"; then
    printf 'check error: target branch is absent from source clone: %s\n' "$TARGET_BRANCH" >&2
    failures=$((failures + 1))
  fi
  if [[ -f "$WEBHOOK_CONFIG" ]] && ! (cd "$SYMPHONY_ROOT/local-tools" && python3 -m symphony_aux.cli --config "$WEBHOOK_CONFIG" check-config >/dev/null); then
    printf '%s\n' 'check error: invalid webhook configuration' >&2
    failures=$((failures + 1))
  fi
  if [[ "$PROFILE" == gitlab ]]; then
    [[ -f "$SYMPHONY_ROOT/local-tools/symphony_mr_watcher.py" ]] || { printf '%s\n' 'check error: GitLab MR watcher is missing' >&2; failures=$((failures + 1)); }
    [[ "$GITLAB_HOST" == https://* ]] || { printf '%s\n' 'check error: ASYNCSELF_GITLAB_HOST must be an HTTPS URL' >&2; failures=$((failures + 1)); }
    [[ -n "$GITLAB_PROJECT" && "$GITLAB_PROJECT" == */* ]] || { printf '%s\n' 'check error: ASYNCSELF_GITLAB_PROJECT must be group/repository' >&2; failures=$((failures + 1)); }
    [[ -n "$GITLAB_HOST" && "$REPOSITORY_URL" == "${GITLAB_HOST%/}/"* ]] || { printf '%s\n' 'check error: GitLab repository URL does not match ASYNCSELF_GITLAB_HOST' >&2; failures=$((failures + 1)); }
  else
    [[ "$REPOSITORY_URL" == https://github.com/* ]] || { printf '%s\n' 'check error: GitHub profile repository URL is not GitHub' >&2; failures=$((failures + 1)); }
    [[ -n "$GITHUB_REPOSITORY" ]] || { printf '%s\n' 'check error: ASYNCSELF_GITHUB_REPOSITORY is missing' >&2; failures=$((failures + 1)); }
    [[ -f "$SYMPHONY_ROOT/local-tools/symphony_github_merger.py" ]] || { printf '%s\n' 'check error: deterministic GitHub merger is missing' >&2; failures=$((failures + 1)); }
    command -v gh >/dev/null 2>&1 || { printf '%s\n' 'check error: GitHub CLI (gh) is missing' >&2; failures=$((failures + 1)); }
    [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] || { printf '%s\n' 'check error: GH_TOKEN or GITHUB_TOKEN is missing' >&2; failures=$((failures + 1)); }
  fi
  printf 'profile=%s code_host=%s project=%s repository=%s target=%s\n' \
    "$PROFILE" "$CODE_HOST" "$PROJECT_SLUG" "$REPOSITORY_URL" "$TARGET_BRANCH"
  printf 'workflow=%s runtime=%s webhook=%s linear_key=%s github_key=%s gitlab_key=%s\n' \
    "$WORKFLOW_PATH" "$RUNTIME_DIR" "$WEBHOOK_CONFIG" "$(present LINEAR_API_KEY)" \
    "$([[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]] && printf present || printf missing)" "$(present GITLAB_TOKEN)"
  ((failures == 0))
}

if ! configuration_check; then
  exit 3
fi
if [[ "$CHECK_ONLY" == 1 ]]; then
  exit 0
fi

mkdir -p "$RUNTIME_DIR"
AUX_STACK_LOCK="${SYMPHONY_AUX_STACK_LOCK:-$RUNTIME_DIR/aux-stack.lock}"
exec 9>"$AUX_STACK_LOCK"
if ! flock -n 9; then
  printf 'Auxiliary stack is already running (lock: %s)\n' "$AUX_STACK_LOCK" >&2
  exit 5
fi

declare -a CHILD_PIDS=()
SYMPHONY_PID=""

cleanup() {
  trap - EXIT INT TERM
  if ((${#CHILD_PIDS[@]})); then
    kill "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait "${CHILD_PIDS[@]}" 2>/dev/null || true
  fi
  if [[ -n "$SYMPHONY_PID" ]]; then
    kill "$SYMPHONY_PID" 2>/dev/null || true
    wait "$SYMPHONY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

run_auxiliary_with_restart() {
  local name="$1"
  shift
  local child_pid=""
  local status=0
  local delay="${SYMPHONY_AUX_RESTART_DELAY_SECONDS:-5}"
  trap 'if [[ -n "${child_pid:-}" ]]; then kill "$child_pid" 2>/dev/null || true; fi; exit 0' TERM INT
  while true; do
    "$@" &
    child_pid=$!
    if wait "$child_pid"; then status=0; else status=$?; fi
    child_pid=""
    printf '%s exited status=%s; restarting in %ss\n' "$name" "$status" "$delay" >&2
    sleep "$delay"
  done
}

printf 'Starting AsyncSelf profile=%s project=%s repository=%s target=%s\n' \
  "$PROFILE" "$PROJECT_SLUG" "$REPOSITORY_URL" "$TARGET_BRANCH"

if [[ "$AUX_ONLY" == 0 ]]; then
  cd "$SYMPHONY_ROOT/elixir"
  mise exec -- mix compile
  mise exec -- mix escript.build
  mise exec -- ./bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port "$PORT" \
    "$WORKFLOW_PATH" &
  SYMPHONY_PID=$!
fi

GATEKEEPER_SCRIPT="$SYMPHONY_ROOT/local-tools/symphony_gatekeeper_watch.py"
MR_WATCHER_SCRIPT="$SYMPHONY_ROOT/local-tools/symphony_mr_watcher.py"
[[ -f "$GATEKEEPER_SCRIPT" ]] || { printf 'Gatekeeper script missing: %s\n' "$GATEKEEPER_SCRIPT" >&2; exit 3; }
[[ "$PROFILE" != gitlab || -f "$MR_WATCHER_SCRIPT" ]] || { printf 'MR watcher missing: %s\n' "$MR_WATCHER_SCRIPT" >&2; exit 3; }

WEBHOOK_MODE=$(cd "$SYMPHONY_ROOT/local-tools" && python3 -m symphony_aux.cli --config "$WEBHOOK_CONFIG" mode)
case "$WEBHOOK_MODE" in
  polling|shadow|hybrid) ;;
  *) printf 'Unsupported webhook mode: %s\n' "$WEBHOOK_MODE" >&2; exit 4 ;;
esac

if [[ "$PROFILE" == gitlab ]]; then
  run_auxiliary_with_restart "mr-watcher" \
    python3 "$MR_WATCHER_SCRIPT" --config "$WEBHOOK_CONFIG" \
    --poll-seconds "${SYMPHONY_MR_WATCHER_POLL_SECONDS:-15}" &
  CHILD_PIDS+=("$!")
fi

run_auxiliary_with_restart "gatekeeper" \
  python3 "$GATEKEEPER_SCRIPT" --config "$WEBHOOK_CONFIG" \
  --pipeline-root "$PIPELINE_ROOT" --project-slug-id "$PROJECT_SLUG_ID" \
  --active-label "$ACTIVE_LABEL" --state-file "$SYMPHONY_GATEKEEPER_STATE_FILE" \
  --lock-file "$SYMPHONY_GATEKEEPER_LOCK_FILE" \
  --poll-seconds "${SYMPHONY_GATEKEEPER_POLL_SECONDS:-15}" &
CHILD_PIDS+=("$!")

if [[ "$WEBHOOK_MODE" == shadow || "$WEBHOOK_MODE" == hybrid ]]; then
  WEBHOOK_PYTHON="${SYMPHONY_WEBHOOK_PYTHON:-python3}"
  command -v "$WEBHOOK_PYTHON" >/dev/null 2>&1 || { printf 'Webhook Python not found: %s\n' "$WEBHOOK_PYTHON" >&2; exit 4; }
  run_auxiliary_with_restart "webhook-receiver" \
    env PYTHONPATH="$SYMPHONY_ROOT/local-tools${PYTHONPATH:+:$PYTHONPATH}" \
    "$WEBHOOK_PYTHON" -m symphony_aux.webhook_server --config "$WEBHOOK_CONFIG" &
  CHILD_PIDS+=("$!")
fi

if [[ "$AUX_ONLY" == 1 ]]; then
  wait "${CHILD_PIDS[0]}"
else
  wait "$SYMPHONY_PID"
fi
