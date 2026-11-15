#!/bin/bash

# ============================================================================
# The MySQL images ship no MySQL Shell
# ============================================================================
# The official mysql:8.0 and mysql:8.4 images install Oracle's MySQL Shell
# (mysql-shell), which bundles its own Python and, in it, a certifi with a
# critical advisory (GHSA-6q48-6c7w-9gw2) that Oracle's newest shell still
# carries. Nothing in these images, the skills or the AI Assistant runs
# mysqlsh, and no package needs it, so gibbon-mysql and moodle-mysql remove
# it. For each image this test checks that:
#   - rpm says mysql-shell is not installed (so rpm itself answered), and no
#     file or folder named after the shell is left anywhere on the image's
#     filesystem (/usr/lib/mysqlsh held the bundled Python and its certifi);
#   - mysqld, mysql and mysqldump still run (--version), from the server
#     package.
# The containers run with no network.
#
# --image NAME=REF uses an image that is already built; otherwise the test
# builds it and removes it at the end. Naming images limits the run. Needs
# Docker.
#
# Usage: bash tests/mysql-image-shell.test.sh [--image NAME=REF]... [NAME...]
#   NAME  gibbon-mysql or moodle-mysql (default: both)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ALL=(gibbon-mysql moodle-mysql)
declare -A CONTEXT=(
  [gibbon-mysql]="$REPO_DIR/apps/gibbon/image/mysql"
  [moodle-mysql]="$REPO_DIR/apps/moodle/image/mysql"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/(default: both)/p' "${BASH_SOURCE[0]}" >&2
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

for name in "${SELECTED[@]}"; do
  echo
  echo "$name"
  image="${IMAGE[$name]:-}"
  if [ -z "$image" ]; then
    image="clouve-test/$name:shell-test"
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
  in_image() { docker run --rm --pull=never --network none --entrypoint sh "$image" -c "$1" 2>&1; }

  assert_eq "rpm says mysql-shell is not installed" "package mysql-shell is not installed" \
    "$(in_image 'rpm -q mysql-shell')"
  assert_eq "nothing named after the shell is left (mysqlsh, /usr/lib/mysqlsh and its certifi)" "" \
    "$(in_image 'find / -xdev \( -path /proc -o -path /sys \) -prune -o -name "*mysqlsh*" -print')"
  assert_eq "mysqld, mysql and mysqldump still run" "ok" \
    "$(in_image 'mysqld --version >/dev/null && mysql --version >/dev/null && mysqldump --version >/dev/null && echo ok')"
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sMySQL Shell checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sMySQL Shell checks failed.%s\n' "$RED" "$RESET"
exit 1
