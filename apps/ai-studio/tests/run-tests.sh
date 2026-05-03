#!/usr/bin/env bash
# Runs every *.bats file under apps/ai-studio/tests/.
# Usage: ./run-tests.sh [bats-args...]   (e.g. --filter url-parser)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_BIN="$SCRIPT_DIR/bats/bin/bats"
[ -x "$BATS_BIN" ] || { echo "bats not found at $BATS_BIN — run: cd $SCRIPT_DIR/bats && git clone..." >&2; exit 2; }
exec "$BATS_BIN" "$@" "$SCRIPT_DIR"
