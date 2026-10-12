#!/bin/bash

# ============================================================================
# build.sh --prune Test Script
# ============================================================================
# Verifies that --prune clears the build cache of the buildx builder the build
# uses (multiplatform-builder for --push, the current context's builder for
# local builds) exactly once, before anything is built; that --all prunes once
# up front rather than once per target; that a failed prune stops the build;
# and that --prune on its own is rejected.
#
# Runs a copy of build.sh against two fake apps in a temporary directory, with
# `docker` stubbed on PATH. Every docker call is recorded; nothing is built,
# pruned or pushed, and no Docker daemon is needed.
#
# Usage: bash tests/build-prune.test.sh [path/to/build.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SH="${1:-$SCRIPT_DIR/../build.sh}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
assert_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$2"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
assert_before() { # label haystack first second
  local a b
  a=$(grep -nF -- "$3" <<< "$2" | head -1 | cut -d: -f1)
  b=$(grep -nF -- "$4" <<< "$2" | head -1 | cut -d: -f1)
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then pass "$1"; else
    fail "$1"; printf '       expected %q (line %s) before %q (line %s)\n' "$3" "$a" "$4" "$b"; fi
}
count() { grep -cF -- "$2" <<< "$1"; }

# ============================================================================
# Sandbox: a copy of build.sh plus two fake apps (alpha has a db container)
# ============================================================================
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
M="$WORK/magneto"
mkdir -p "$M/apps/alpha/image/db" "$M/apps/beta/image" "$WORK/bin"
cp "$BUILD_SH" "$M/build.sh"
chmod +x "$M/build.sh"
printf 'FROM scratch\n' > "$M/apps/alpha/image/Dockerfile"
printf 'FROM scratch\n' > "$M/apps/alpha/image/db/Dockerfile"
printf 'APP_IMAGE="alpha"\nDB_IMAGE="alpha-db"\nDB_NAME="DB"\n' > "$M/apps/alpha/image/build.config"
printf 'FROM scratch\n' > "$M/apps/beta/image/Dockerfile"
printf 'APP_IMAGE="beta"\n' > "$M/apps/beta/image/build.config"

# docker stub: records each call; a builder "exists" when $STATE/builder-<name> does.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
case "$1 $2" in
  "buildx version") exit 0 ;;
  "buildx inspect") [[ -f "$STATE/builder-$3" ]] ;;
  "buildx create")  for a in "$@"; do [[ "${prev:-}" == "--name" ]] && touch "$STATE/builder-$a"; prev="$a"; done ;;
  "buildx prune")   [[ ! -f "$STATE/prune-fails" ]] ;;
  "context show")   echo default ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/docker"

# run ARGS... -> sets RC, CALLS_TXT, OUT_TXT. Call it directly (not in $(...)),
# so the variables reach the assertions. NO_PUSH_BUILDER=1 / PRUNE_FAILS=1 tweak
# the stub's state for one run.
run() {
  local state rc=0
  state="$(mktemp -d "$WORK/state.XXXX")"
  touch "$state/builder-default" "$state/builder-multiplatform-builder"
  [[ "${NO_PUSH_BUILDER:-0}" == 1 ]] && rm "$state/builder-multiplatform-builder"
  [[ "${PRUNE_FAILS:-0}" == 1 ]] && touch "$state/prune-fails"
  CALLS="$state/calls.log" STATE="$state" PATH="$WORK/bin:$PATH" \
    bash "$M/build.sh" "$@" > "$state/out.log" 2>&1 || rc=$?
  touch "$state/calls.log"
  CALLS_TXT="$(cat "$state/calls.log")"
  OUT_TXT="$(cat "$state/out.log")"
  RC="$rc"
}

# ============================================================================
# Scenarios
# ============================================================================
echo "S1: single target --push --prune -> prunes multiplatform-builder once, before building"
run alpha --push --prune
assert_eq "exits 0" "0" "$RC"
assert_eq "one prune call" "1" "$(count "$CALLS_TXT" "buildx prune")"
assert_contains "prunes the push builder, all records, no prompt" "$CALLS_TXT" "docker buildx prune --builder multiplatform-builder --all --force"
assert_before "prunes after selecting the builder" "$CALLS_TXT" "buildx use multiplatform-builder" "buildx prune"
assert_before "prunes before the first build" "$CALLS_TXT" "buildx prune" "buildx build"
assert_eq "still builds both images" "2" "$(count "$CALLS_TXT" "buildx build")"

echo "S2: single target --prune (local build) -> prunes the local builder"
run alpha --prune
assert_eq "exits 0" "0" "$RC"
assert_contains "prunes the local builder" "$CALLS_TXT" "docker buildx prune --builder default --all --force"
assert_eq "one prune call" "1" "$(count "$CALLS_TXT" "buildx prune")"

echo "S3: --all --push --prune -> prunes once up front, not per target"
run --all --push --prune
assert_eq "exits 0" "0" "$RC"
assert_eq "exactly one prune call" "1" "$(count "$CALLS_TXT" "buildx prune")"
assert_contains "prunes the push builder" "$CALLS_TXT" "docker buildx prune --builder multiplatform-builder --all --force"
assert_before "prunes before any build" "$CALLS_TXT" "buildx prune" "buildx build"
assert_eq "builds all three images" "3" "$(count "$CALLS_TXT" "buildx build")"

echo "S4: --push without --prune -> never prunes"
run alpha --push
assert_eq "exits 0" "0" "$RC"
assert_eq "no prune call" "0" "$(count "$CALLS_TXT" "buildx prune")"

echo "S5: --all --push --prune, push builder not created yet -> nothing to prune, still builds"
NO_PUSH_BUILDER=1 run --all --push --prune
assert_eq "exits 0" "0" "$RC"
assert_eq "no prune call" "0" "$(count "$CALLS_TXT" "buildx prune")"
assert_contains "says there is nothing to prune" "$OUT_TXT" "nothing to prune"
assert_eq "builds all three images" "3" "$(count "$CALLS_TXT" "buildx build")"

echo "S6: --prune as the first argument -> usage error, nothing pruned or built"
run --prune
assert_ne "exits non-zero" "0" "$RC"
assert_contains "explains --prune needs a target" "$OUT_TXT" "--prune must be used with an app/bundle name or --all"
assert_eq "no prune call" "0" "$(count "$CALLS_TXT" "buildx prune")"
assert_eq "no build" "0" "$(count "$CALLS_TXT" "buildx build")"

echo "S7: flag order --prune --push -> same as S1"
run alpha --prune --push
assert_eq "exits 0" "0" "$RC"
assert_contains "prunes the push builder" "$CALLS_TXT" "docker buildx prune --builder multiplatform-builder --all --force"

echo "S8: prune fails -> stop before building (single target and --all)"
PRUNE_FAILS=1 run alpha --push --prune
assert_ne "single: exits non-zero" "0" "$RC"
assert_eq "single: no build" "0" "$(count "$CALLS_TXT" "buildx build")"
PRUNE_FAILS=1 run --all --push --prune
assert_ne "--all: exits non-zero" "0" "$RC"
assert_eq "--all: no build" "0" "$(count "$CALLS_TXT" "buildx build")"

echo "S9: usage text lists --prune"
run
assert_contains "usage mentions --prune" "$OUT_TXT" "--prune"

echo
if [[ $FAILED -eq 0 ]]; then
  printf "${GREEN}All build.sh --prune tests passed.${NC}\n"; exit 0
else
  printf "${RED}build.sh --prune tests FAILED.${NC}\n"; exit 1
fi
