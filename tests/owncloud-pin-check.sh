#!/bin/bash

# ============================================================================
# ownCloud's pins against what an environment runs: the gate before a new
# ownCloud listing version goes there
# ============================================================================
# The ownCloud image is pinned to one ownCloud release and one MariaDB series
# (the FROM lines of apps/owncloud/image/Dockerfile and its mariadb/Dockerfile).
# A site upgrades in place when it moves to them, but neither ownCloud nor
# MariaDB runs older code on data a newer one wrote. So before an environment
# gets a new ownCloud listing version, run this on every ownCloud and
# owncloud-mariadb image that environment's ownCloud deployments run (pulled
# by digest; see CLAUDE.md, "Testing on new cluster disks", for the envpin
# pull). It reads each image's version with no network and prints one line
# per image, then two summary lines:
#   ownCloud pin <version>: ok      every ownCloud image is that release or older
#   MariaDB pin <series>: ok        every database image is that series or older
# Each says "NOT ok" otherwise, or when a version can't be read. Publish the
# listing version only when both say ok (exit 0); otherwise the pins have to
# move first. It prints versions only.
#
# Usage: bash tests/owncloud-pin-check.sh --owncloud REF [--owncloud REF]... --mariadb REF [--mariadb REF]...
# Exit status: 0 when both pins are ok, 1 when one isn't, 2 on a usage error.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

APPS=()
DBS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --owncloud) [ -n "${2:-}" ] || usage; APPS+=("$2"); shift ;;
    --mariadb) [ -n "${2:-}" ] || usage; DBS+=("$2"); shift ;;
    *) usage ;;
  esac
  shift
done
[ "${#APPS[@]}" -gt 0 ] && [ "${#DBS[@]}" -gt 0 ] || usage

# The pins, from the FROM lines.
oc_pin="$(sed -n 's#^FROM owncloud/server:\([0-9][0-9.]*\)[[:space:]]*$#\1#p' "$REPO_DIR/apps/owncloud/image/Dockerfile" | head -n 1)"
db_pin="$(sed -n 's#^FROM mariadb:\([0-9][0-9]*\.[0-9][0-9]*\)[[:space:]]*$#\1#p' "$REPO_DIR/apps/owncloud/image/mariadb/Dockerfile" |
  head -n 1)"
if [ -z "$oc_pin" ] || [ -z "$db_pin" ]; then
  echo "The ownCloud Dockerfiles name no owncloud/server:<version> or mariadb:<major.minor> pin." >&2
  exit 2
fi

# not_newer HAVE PIN: 0 when the version HAVE is PIN or older.
not_newer() { [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]; }

oc_ok=1
for ref in "${APPS[@]}"; do
  have="$(docker run --rm --pull=never --network none --entrypoint sh "$ref" -c \
    "sed -n \"s/^\\\$OC_VersionString = '\\([0-9][0-9.]*\\)';.*/\\1/p\" /var/www/owncloud/version.php" 2>/dev/null | head -n 1)"
  if not_newer "$have" "$oc_pin"; then
    echo "  $ref: ownCloud $have, not newer than $oc_pin"
  else
    echo "  $ref: ownCloud ${have:-unreadable}, newer than $oc_pin or unreadable"
    oc_ok=0
  fi
done
db_ok=1
for ref in "${DBS[@]}"; do
  line="$(docker run --rm --pull=never --network none --entrypoint mariadbd "$ref" --version 2>/dev/null ||
    docker run --rm --pull=never --network none --entrypoint mysqld "$ref" --version 2>/dev/null)"
  have="$(sed -n 's/.*Ver \([0-9][0-9]*\.[0-9][0-9]*\)\.[0-9][0-9]*-MariaDB.*/\1/p' <<< "$line" | head -n 1)"
  if not_newer "$have" "$db_pin"; then
    echo "  $ref: MariaDB $have, not newer than $db_pin"
  else
    echo "  $ref: MariaDB ${have:-unreadable}, newer than $db_pin or unreadable"
    db_ok=0
  fi
done

[ "$oc_ok" = 1 ] && echo "ownCloud pin $oc_pin: ok" || echo "ownCloud pin $oc_pin: NOT ok"
[ "$db_ok" = 1 ] && echo "MariaDB pin $db_pin: ok" || echo "MariaDB pin $db_pin: NOT ok"
[ "$oc_ok" = 1 ] && [ "$db_ok" = 1 ]
