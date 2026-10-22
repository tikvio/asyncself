#!/usr/bin/env bash
set -euo pipefail

# Public AsyncSelf entrypoint. The implementation remains in the legacy-named
# launcher for one compatibility cycle so existing local setups keep working.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export ASYNCSELF_ROOT="${ASYNCSELF_ROOT:-${SYMPHONY_ROOT:-$SCRIPT_DIR}}"
exec "$SCRIPT_DIR/start_symphony.sh" "$@"
