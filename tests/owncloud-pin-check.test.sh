#!/bin/bash

# ============================================================================
# tests/owncloud-pin-check.sh, the gate before an ownCloud listing version
# ============================================================================
# Runs the check with a fake docker on PATH that answers each image's version
# from a table, so no Docker is needed. Checks that it:
#   - says ok twice and exits 0 when every ownCloud image is the pinned
#     release or older and every database image the pinned MariaDB series or
#     older (a newer patch of the same series is fine, and an old database
#     image with only mysqld is read too);
#   - says NOT ok and exits 1 for a newer ownCloud (10.16.7 against 10.16.6),
#     a newer MariaDB series (13.0), one bad image among good ones, or a version
#     it can't read;
#   - reads the pins from the two Dockerfiles, so moving a pin moves the gate;
#   - asks docker for each image with no network and no pull;
#   - exits 2 on a usage error.
#
# Usage: bash tests/owncloud-pin-check.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/owncloud-pin-check.sh"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# Fake docker: "docker run ... --entrypoint sh REF -c ..." prints REF's ownCloud version, "--entrypoint mariadbd REF
# --version" (or mysqld) REF's server line, both from $WORK/table ("REF kind value"); anything else fails.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
[ "$1" = run ] || exit 1
entry="" ref=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = --entrypoint ]; then entry="${args[i+1]}"; ref="${args[i+2]}"; break; fi
done
value="$(awk -v r="$ref" -v k="$entry" '$1 == r && $2 == k { $1 = ""; $2 = ""; sub(/^  /, ""); print }' "$TABLE")"
[ -n "$value" ] || exit 1
echo "$value"
EOF
chmod +x "$WORK/bin/docker"
cat > "$WORK/table" <<'EOF'
oc-10.16.0 sh 10.16.0
oc-10.16.6 sh 10.16.6
oc-10.16.7 sh 10.16.7
db-11.4 mariadbd mariadbd  Ver 11.4.9-MariaDB-ubu2404 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)
db-12.3 mariadbd mariadbd  Ver 12.3.3-MariaDB-ubu2404 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)
db-12.3.9 mariadbd mariadbd  Ver 12.3.9-MariaDB-ubu2404 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)
db-13.0 mariadbd mariadbd  Ver 13.0.2-MariaDB-ubu2604 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)
db-10.4 mysqld mysqld  Ver 10.4.34-MariaDB-1:10.4.34+maria~ubu2004 for debian-linux-gnu on x86_64 (mariadb.org binary distribution)
EOF

# check ARGS...: runs the gate; sets RC, OUT and CALLS_TXT.
check() {
  : > "$WORK/calls"
  OUT="$(CALLS="$WORK/calls" TABLE="$WORK/table" PATH="$WORK/bin:$PATH" bash "${GATE:-$CHECK}" "$@" 2>&1)"
  RC=$?
  CALLS_TXT="$(cat "$WORK/calls")"
}
oks() { grep -c ': ok$' <<< "$OUT"; }

oc_pin="$(sed -n 's#^FROM owncloud/server:\(.*\)$#\1#p' "$REPO_DIR/apps/owncloud/image/Dockerfile")"
db_pin="$(sed -n 's#^FROM mariadb:\(.*\)$#\1#p' "$REPO_DIR/apps/owncloud/image/mariadb/Dockerfile")"
echo "The repository's pins: owncloud/server:$oc_pin, mariadb:$db_pin"
assert_eq "the cases below are written for these pins" "10.16.6 12.3" "$oc_pin $db_pin"

echo "Older or the same: ok twice"
check --owncloud oc-10.16.0 --mariadb db-11.4
assert_eq "10.16.0 on MariaDB 11.4: exit 0" 0 "$RC"
assert_eq "10.16.0 on MariaDB 11.4: two ok lines" 2 "$(oks)"
check --owncloud oc-10.16.6 --mariadb db-12.3 --mariadb db-12.3.9
assert_eq "10.16.6 on MariaDB 12.3.3 and 12.3.9: exit 0, two ok lines" "0 2" "$RC $(oks)"
check --owncloud oc-10.16.0 --mariadb db-10.4
assert_eq "an old database image with only mysqld is read: exit 0, two ok lines" "0 2" "$RC $(oks)"
assert_eq "docker runs each image with no network and no pull" 0 \
  "$(grep -v -- '--pull=never --network none' <<< "$CALLS_TXT" | grep -c .)"

echo "Newer or unreadable: NOT ok"
check --owncloud oc-10.16.7 --mariadb db-12.3
assert_eq "ownCloud 10.16.7: exit 1" 1 "$RC"
assert_eq "ownCloud 10.16.7: the ownCloud line says NOT ok" "ownCloud pin 10.16.6: NOT ok" "$(grep '^ownCloud pin' <<< "$OUT")"
check --owncloud oc-10.16.6 --mariadb db-13.0
assert_eq "MariaDB 13.0: exit 1, the MariaDB line NOT ok" "1 MariaDB pin 12.3: NOT ok" "$RC $(grep '^MariaDB pin' <<< "$OUT")"
check --owncloud oc-10.16.0 --owncloud oc-10.16.7 --owncloud oc-10.16.6 --mariadb db-12.3
assert_eq "one newer image among older ones: exit 1" 1 "$RC"
check --owncloud oc-unknown --mariadb db-12.3
assert_eq "an ownCloud version it can't read: exit 1, NOT ok" "1 ownCloud pin 10.16.6: NOT ok" "$RC $(grep '^ownCloud pin' <<< "$OUT")"
check --owncloud oc-10.16.6 --mariadb db-unknown
assert_eq "a MariaDB version it can't read: exit 1, NOT ok" "1 MariaDB pin 12.3: NOT ok" "$RC $(grep '^MariaDB pin' <<< "$OUT")"

echo "The pins come from the Dockerfiles"
mkdir -p "$WORK/repo/apps/owncloud/image/mariadb" "$WORK/repo/tests"
printf 'FROM owncloud/server:10.16.7\n' > "$WORK/repo/apps/owncloud/image/Dockerfile"
printf 'FROM mariadb:13.0\n' > "$WORK/repo/apps/owncloud/image/mariadb/Dockerfile"
cp "$CHECK" "$WORK/repo/tests/owncloud-pin-check.sh"
GATE="$WORK/repo/tests/owncloud-pin-check.sh" check --owncloud oc-10.16.7 --mariadb db-13.0
assert_eq "with the pins moved to 10.16.7 and 13.0, those images pass: exit 0, two ok lines" "0 2" "$RC $(oks)"

echo "Usage"
check
assert_eq "no image: exit 2" 2 "$RC"
check --owncloud oc-10.16.6
assert_eq "no database image: exit 2" 2 "$RC"
check --mariadb db-12.3 --bogus
assert_eq "an unknown option: exit 2" 2 "$RC"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sownCloud pin check tests passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sownCloud pin check tests failed.%s\n' "$RED" "$RESET"
exit 1
