#!/bin/bash

# ============================================================================
# build.sh --pull Test Script
# ============================================================================
# Every `docker buildx build` that build.sh runs passes --pull, so each build
# starts from the newest image of the tag its Dockerfile names. Without it a
# build reuses whatever copy of the base image this machine already has: 4.5.4's
# prod review found the new-disk tests had run on an older postgres:18 than the
# one the push built.
#
# The four build calls are: the app image and each sub-container image (a
# database, say), each for a local build (--load) and for a push. The cases
# below reach all four, and a sub-container whose build context is overridden
# (<PREFIX>_CONTEXT in build.config, which adds --file).
#
# A push refuses a target whose Dockerfiles name a base image with no tag:
# --pull would push whatever :latest is that day, a new major version
# included. A local build of it still runs.
#
# It also pins the push the release runbooks use for dev: with --tag, each
# image gets that one tag and never the bare name (which Docker reads as
# :latest), so a push moves no deployment whose listing pins :latest.
#
# Runs a copy of build.sh against fake apps in a temporary directory, with
# `docker` stubbed on PATH. Every docker call is recorded; nothing is built,
# pulled or pushed, and no Docker daemon is needed.
#
# Usage: bash tests/build-pull.test.sh [path/to/build.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SH="${1:-$SCRIPT_DIR/../build.sh}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
assert_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1"; printf '       did NOT want: %q\n' "$2"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
count() { grep -cF -- "$2" <<< "$1"; }

# ============================================================================
# Sandbox: a copy of build.sh plus fake apps. alpha has a db container, beta
# none, and gamma a db container built from an overridden context.
# ============================================================================
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
M="$WORK/magneto"
mkdir -p "$M/apps/alpha/image/db" "$M/apps/beta/image" "$M/apps/gamma/image/db" "$M/apps/gamma/shared" \
  "$M/apps/delta/image/db" "$M/apps/epsilon/image" "$WORK/bin"
cp "$BUILD_SH" "$M/build.sh"
chmod +x "$M/build.sh"
printf 'FROM scratch\n' > "$M/apps/alpha/image/Dockerfile"
printf 'FROM scratch\n' > "$M/apps/alpha/image/db/Dockerfile"
printf 'APP_IMAGE="alpha"\nDB_IMAGE="alpha-db"\nDB_NAME="DB"\n' > "$M/apps/alpha/image/build.config"
printf 'FROM scratch\n' > "$M/apps/beta/image/Dockerfile"
printf 'APP_IMAGE="beta"\n' > "$M/apps/beta/image/build.config"
printf 'FROM scratch\n' > "$M/apps/gamma/image/Dockerfile"
printf 'FROM scratch\n' > "$M/apps/gamma/image/db/Dockerfile"
printf 'APP_IMAGE="gamma"\nDB_IMAGE="gamma-db"\nDB_NAME="DB"\nDB_CONTEXT="shared"\n' > "$M/apps/gamma/image/build.config"
# delta's db image names a base with no tag; its app image has a build stage, a COPY --from of it, and a digest.
printf 'FROM golang:1.26 AS tool\nFROM debian@sha256:%064d\nCOPY --from=tool /x /x\nCOPY --from=0 /y /y\n' 0 \
  > "$M/apps/delta/image/Dockerfile"
printf 'FROM \\\n  mariadb\n' > "$M/apps/delta/image/db/Dockerfile"
printf 'APP_IMAGE="delta"\nDB_IMAGE="delta-db"\nDB_NAME="DB"\n' > "$M/apps/delta/image/build.config"
# epsilon names :latest, a tag in name only: with --pull it is whatever :latest is that day.
printf 'FROM mariadb:latest AS db\nCOPY --from=composer:latest /c /c\nFROM php:8.3-apache\nCOPY --from=db /d /d\n' \
  > "$M/apps/epsilon/image/Dockerfile"
printf 'APP_IMAGE="epsilon"\n' > "$M/apps/epsilon/image/build.config"

# docker stub: records each call; every builder exists.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
case "$1 $2" in
  "context show") echo default ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/docker"

# run ARGS... -> sets RC, BUILDS (the buildx build calls, one per line). Call it directly, not in $(...).
run() {
  local state rc=0
  state="$(mktemp -d "$WORK/state.XXXX")"
  CALLS="$state/calls.log" PATH="$WORK/bin:$PATH" bash "$M/build.sh" "$@" > "$state/out.log" 2>&1 || rc=$?
  touch "$state/calls.log"
  BUILDS="$(grep -F 'docker buildx build' "$state/calls.log")"
  OUT_TXT="$(cat "$state/out.log")"
  RC="$rc"
}

# every_build_pulls LABEL EXPECTED_BUILDS: there are EXPECTED_BUILDS build calls, and each has --pull as an argument.
every_build_pulls() {
  local with_pull
  with_pull="$(grep -cE -- '(^| )--pull( |$)' <<< "$BUILDS")"
  assert_eq "$1: $2 build calls" "$2" "$(count "$BUILDS" "docker buildx build")"
  assert_eq "$1: every build call has --pull" "$2" "$with_pull"
}

# ============================================================================
# Scenarios
# ============================================================================
echo "S1: local build of an app with a db container (the two --load calls)"
run alpha
assert_eq "exits 0" "0" "$RC"
every_build_pulls "alpha" 2

echo "S2: push of an app with a db container (the two --push calls)"
run alpha --push
assert_eq "exits 0" "0" "$RC"
every_build_pulls "alpha --push" 2

echo "S3: an app with no sub-container, local and pushed"
run beta
every_build_pulls "beta" 1
run beta --push
every_build_pulls "beta --push" 1

echo "S4: a sub-container with an overridden build context (--file), local and pushed"
run gamma
every_build_pulls "gamma" 2
assert_eq "gamma: the db build names its Dockerfile" "1" "$(count "$BUILDS" "--file $M/apps/gamma/image/db/Dockerfile")"
run gamma --push
every_build_pulls "gamma --push" 2

echo "S5: --all --push builds every target that names its bases' tags, each with --pull"
run --all --push
assert_eq "exits non-zero (delta is refused)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
every_build_pulls "--all --push" 5

echo "S6: --push --tag gives each image that one tag and no bare name (no :latest)"
run alpha --push --tag 2026.11.12
assert_eq "exits 0" "0" "$RC"
assert_eq "the app image's dated tag" "1" "$(count "$BUILDS" "--tag r.clv.zone/e2eorg/alpha:2026.11.12 ")"
assert_eq "the db image's dated tag" "1" "$(count "$BUILDS" "--tag r.clv.zone/e2eorg/alpha-db:2026.11.12 ")"
assert_eq "two --tag options in all" "2" "$(grep -oE -- '--tag [^ ]+' <<< "$BUILDS" | wc -l | tr -d ' ')"
assert_eq "no tag without a version (that would be :latest)" "0" \
  "$(grep -oE -- '--tag [^ ]+' <<< "$BUILDS" | grep -cvE -- ':[^/]+$')"

echo "S7: --push refuses a target whose Dockerfiles name a base with no tag (--pull would push whatever :latest is)"
run delta --push
assert_ne "exits non-zero" "0" "$RC"
assert_eq "nothing is built" "0" "$(count "$BUILDS" "docker buildx build")"
assert_contains "it names the file and the image" "$OUT_TXT" "image/db/Dockerfile: mariadb"
assert_eq "a stage, a stage number and a digest aren't named" "0" "$(grep -cE 'Dockerfile: (tool|0|debian)' <<< "$OUT_TXT")"
echo "S7b: --push refuses :latest the same way"
run epsilon --push
assert_ne "exits non-zero" "0" "$RC"
assert_eq "nothing is built" "0" "$(count "$BUILDS" "docker buildx build")"
assert_contains "it names the FROM" "$OUT_TXT" "image/Dockerfile: mariadb:latest"
assert_contains "it names the COPY --from" "$OUT_TXT" "image/Dockerfile: composer:latest"
assert_eq "a pinned base and a stage aren't named" "0" "$(grep -cE 'Dockerfile: (php:8.3-apache|db)$' <<< "$OUT_TXT")"
echo "S8: a local build of the same target still runs"
run delta
assert_eq "exits 0" "0" "$RC"
every_build_pulls "delta" 2

echo
if [[ $FAILED -eq 0 ]]; then
  printf "${GREEN}All build.sh --pull tests passed.${NC}\n"; exit 0
else
  printf "${RED}build.sh --pull tests FAILED.${NC}\n"; exit 1
fi
