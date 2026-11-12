#!/bin/bash

# ============================================================================
# gosu in the MySQL and MariaDB images
# ============================================================================
# The official mysql and mariadb images ship gosu 1.19, built with Go 1.24.6,
# whose standard library has a critical vulnerability (CVE-2025-68121). Each
# image's entrypoint runs gosu to start the database server as the mysql
# user. The images build gosu 1.20 from its upstream source with a current Go,
# statically, and put it in the base's place. For each image this test checks
# that:
#   - /usr/local/bin/gosu is gosu GOSU_VERSION built with a Go of at least
#     MIN_GO (from gosu --version);
#   - it has the base's owner and mode (root:root, 755);
#   - it still does its job: gosu mysql id -un prints mysql.
# The containers run gosu as their entrypoint, with no network (--network
# none).
#
# --image NAME=REF uses an image that is already built; otherwise the test
# builds it and removes it at the end. Naming images limits the run to them.
# Needs Docker.
#
# Usage: bash tests/db-image-gosu.test.sh [--image NAME=REF]... [NAME...]
#   NAME  gibbon-mysql, moodle-mysql, wordpress-mariadb or nextcloud-mariadb
#         (default: all four)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GOSU_VERSION=1.20
MIN_GO=1.26.11

ALL=(gibbon-mysql moodle-mysql wordpress-mariadb nextcloud-mariadb)
declare -A CONTEXT=(
  [gibbon-mysql]="$REPO_DIR/apps/gibbon/image/mysql"
  [moodle-mysql]="$REPO_DIR/apps/moodle/image/mysql"
  [wordpress-mariadb]="$REPO_DIR/apps/wordpress/image/mariadb"
  [nextcloud-mariadb]="$REPO_DIR/apps/nextcloud/image/mariadb"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/(default: all four)/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${CONTEXT[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
    *)
      [ -n "${CONTEXT[$1]+set}" ] || usage
      SELECTED+=("$1")
      ;;
  esac
  shift
done
[ "${#SELECTED[@]}" -gt 0 ] || SELECTED=("${ALL[@]}")

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

BUILT=()
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() { local image; for image in "${BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done; }
trap cleanup EXIT

# go_at_least <have> <want>: 0 when the Go version have (1.26.11) is want or later.
go_at_least() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]; }

for name in "${SELECTED[@]}"; do
  echo
  echo "$name"
  image="${IMAGE[$name]:-}"
  if [ -z "$image" ]; then
    image="clouve-test/$name:gosu-test"
    if log="$(docker build -t "$image" "${CONTEXT[$name]}" 2>&1)"; then
      BUILT+=("$image")
    else
      fail "the image builds"
      printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
      continue
    fi
  elif ! docker image inspect "$image" >/dev/null 2>&1; then
    fail "the image $image is on this machine"
    continue
  fi
  run() { docker run --rm --pull=never --network none --entrypoint "$1" "$image" "${@:2}" 2>&1; }

  version="$(run /usr/local/bin/gosu --version)"
  # "1.20 (go1.26.11 on linux/amd64; gc)"
  assert_eq "gosu is $GOSU_VERSION" "$GOSU_VERSION" "${version%% *}"
  go="$(sed -n 's/.*(go\([0-9.]*\) .*/\1/p' <<< "$version")"
  if [ -n "$go" ] && go_at_least "$go" "$MIN_GO"; then
    pass "it was built with Go $go (at least $MIN_GO)"
  else
    fail "it was built with Go ${go:-?} (at least $MIN_GO)"
    printf '       gosu --version: %s\n' "$version"
  fi
  assert_eq "it has the base's owner and mode" "root:root 755" "$(run stat -c '%U:%G %a' /usr/local/bin/gosu)"
  assert_eq "gosu mysql id -un prints mysql" "mysql" "$(run /usr/local/bin/gosu mysql id -un)"
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sgosu checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sgosu checks failed.%s\n' "$RED" "$RESET"
exit 1
