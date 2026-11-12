#!/bin/bash

# ============================================================================
# odoo-postgres image: gosu built with a current Go
# ============================================================================
# The postgres image's own entrypoint drops from root to the postgres user
# with gosu (/usr/local/bin/gosu). postgres:18 ships gosu 1.19 built with Go
# 1.24.6, and that Go's standard library has CVE-2025-68121 (critical; fixed
# in Go 1.24.13, 1.25.7 and 1.26.0). apps/odoo/image/postgres/Dockerfile
# builds gosu 1.20 from upstream's source, at a pinned commit, in a
# golang:<version>-alpine stage, the way upstream builds it (static, no cgo),
# and copies it over the base image's gosu. 1.20 is the release whose
# github.com/moby/sys/user (v0.4.1) has CVE-2026-61801's fix, and the one the
# MySQL and MariaDB images build too.
#
# The test reads the Go version from the Dockerfile's gosu stage, builds the
# image (or takes --image REF) and checks, in a container with no network:
#   - /usr/local/bin/gosu is root's, mode 755, as postgres:18 ships it;
#   - `gosu --version` names gosu 1.20 and the Dockerfile's Go, and that Go
#     is at or past the fix for CVE-2025-68121;
#   - it is static (ldd: not a dynamic executable);
#   - it still works: `gosu nobody true` exits 0 and `gosu postgres id -u`
#     prints the postgres user's id.
#
# Needs Docker. The build pulls postgres:18 and golang, runs apt-get and
# fetches gosu's source and Go modules. Every container is removed when it
# ends, and so is the image the test built.
#
# Usage: bash tests/odoo-postgres-gosu.test.sh [--image REF]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PG_DIR="$REPO_DIR/apps/odoo/image/postgres"
GOSU=/usr/local/bin/gosu
GOSU_RELEASE=1.20

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else
    fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi
}
finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then printf '%sodoo-postgres gosu checks passed.%s\n' "$GREEN" "$RESET"; exit 0; fi
  printf '%sodoo-postgres gosu checks failed.%s\n' "$RED" "$RESET"
  exit 1
}

IMAGE=""
case "${1:-}" in
  --image) IMAGE="${2:?usage: --image REF}" ;;
  "") ;;
  *) sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac

echo "odoo-postgres: gosu built with a current Go"

# The Go the Dockerfile builds gosu with: its golang:<version>-alpine stage.
GO_WANT="$(sed -nE 's/^FROM .*golang:([0-9]+\.[0-9]+\.[0-9]+)-alpine.* AS gosu$/\1/p' "$PG_DIR/Dockerfile" | head -n 1)"
if [ -z "$GO_WANT" ]; then
  fail "the Dockerfile builds gosu in a golang:<version>-alpine stage named gosu"
  GO_WANT="none"
else
  pass "the Dockerfile builds gosu with Go $GO_WANT"
fi
# CVE-2025-68121 is fixed in Go 1.24.13, 1.25.7 and 1.26.0 (and later).
if [ "$GO_WANT" != none ] && python3 -I -c '
import sys
v = tuple(int(x) for x in sys.argv[1].split("."))
fixed = {(1, 24): (1, 24, 13), (1, 25): (1, 25, 7)}
sys.exit(0 if v >= fixed.get(v[:2], (1, 26, 0)) and v >= (1, 24, 13) else 1)' "$GO_WANT"; then
  pass "Go $GO_WANT has the fix for CVE-2025-68121"
else
  fail "Go $GO_WANT has the fix for CVE-2025-68121"
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi
BUILT=""
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() { [ -n "$BUILT" ] && docker rmi -f "$BUILT" >/dev/null 2>&1; return 0; }
trap cleanup EXIT
if [ -z "$IMAGE" ]; then
  IMAGE="clouve-test/odoo-postgres:gosu-test"
  BUILDER="$(docker context show 2>/dev/null || echo default)"
  docker buildx inspect "$BUILDER" >/dev/null 2>&1 || BUILDER=default
  if log="$(docker buildx build --builder "$BUILDER" --load --provenance=false -t "$IMAGE" "$PG_DIR" 2>&1)"; then
    BUILT="$IMAGE"
    pass "the image builds"
  else
    fail "the image builds"
    printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
    finish
  fi
fi

# in_image <sh>: runs sh in a new container of the image, with no network, as root.
in_image() { docker run --rm --network none --pull=never --entrypoint sh "$IMAGE" -c "$1" 2>&1; }

assert_eq "$GOSU is root's, mode 755 (as postgres:18 ships it)" "root:root 755" "$(in_image "stat -c '%U:%G %a' $GOSU")"
version="$(in_image "$GOSU --version")"
if [[ "$version" =~ ^${GOSU_RELEASE//./\\.}\ \(go([0-9]+\.[0-9]+\.[0-9]+)\ on\ linux/ ]]; then
  assert_eq "gosu $GOSU_RELEASE reports the Dockerfile's Go ($version)" "$GO_WANT" "${BASH_REMATCH[1]}"
else
  fail "gosu --version names gosu $GOSU_RELEASE and its Go"
  printf '       %s\n' "$version"
fi
if [[ "$(in_image "ldd $GOSU")" == *"not a dynamic executable"* ]]; then
  pass "gosu is static (no libc)"
else
  fail "gosu is static (no libc)"
fi
in_image "$GOSU nobody true" >/dev/null
assert_eq "gosu nobody true exits 0" 0 "$?"
assert_eq "gosu postgres id -u prints the postgres user's id" "$(in_image 'id -u postgres')" \
  "$(in_image "$GOSU postgres id -u")"

finish
