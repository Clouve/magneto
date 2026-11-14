#!/bin/bash

# ============================================================================
# build.sh and its wrappers: a push to dev, UAT or prod needs a new dated --tag
# ============================================================================
# Without --tag, build.sh tags each image :<DATE> and :latest, and a push moves
# :latest, which every deployment that pins it pulls at its next restart.
# Rebuilt images reach UAT and prod only as dated tags, through a listing's new
# version (AJ, 2026-11-11), and never over a dated tag or :latest (4.5.6). So a
# push to dev's, UAT's or prod's registry needs --tag
# with a date (YYYY.MM.DD, with an optional suffix such as 2026.11.11-2 for a
# second build that day), or build.sh refuses it: one line, a non-zero exit,
# and no docker call at all. --tag latest is refused the same way, and so is a
# date that doesn't exist (2026.02.30), one outside 2000 to 2099, and a suffix
# after a dot (2026.11.11.2). Each wrapper passes its arguments on unchanged:
# one that holds a space stays one argument. That holds
# however the push gets there: build-uat.sh or build-prod.sh, or build.sh
# itself with REGISTRY set by hand to any project on UAT's or prod's Harbor, in
# any case, with a port or a scheme, in name, path and app-directory mode, and
# with --all. Each Harbor answers on two hosts: the one the wrappers push to
# (read from them here) and its externalURL host, which strato copies Harbor's
# whole Ingress rule to (strato cluster/k8s/manifests/clouve-<env>/harbor/
# values.yaml, cluster/k8s/actions/setup-harbor and upgrade-harbor): UAT
# demo.cr0.io and demo.reg.clouve.com, prod cr0.io and registry.clouve.com.
# When a strato checkout is next to this repo (or STRATO_DIR names one), the
# test also reads both hosts of each environment from those values files.
# Dev's Harbor (dev.cr0.io, dev.reg.clouve.com) follows the same rule since
# 4.5.6: a dev push without --tag would move dev's :latest.
# A dated tag that one of the target's images already has in the registry is
# refused too, before anything is built: build.sh looks every image up with
# docker buildx imagetools inspect, pushes only when each lookup says "not
# found", and refuses when a lookup finds the tag or fails for another reason.
# With --all it looks every target up before it builds any. No refusal echoes
# the tag that was typed. PUSH_NEEDS_DATED_TAG=1 turns both rules on for any
# registry. A local build (no --push), with or without --tag, works as before,
# and so do pushes to the rig's registry (build-e2e.sh, and build.sh's
# default), which also re-push the E2E suite's fixture tag.
#
# Runs copies of build.sh and the four wrappers against three fake apps in a
# temporary directory, with `docker` stubbed on PATH. Every docker call is
# recorded; nothing is built or pushed, and no Docker daemon is needed. The
# pushes that go ahead pass --skip-new-disk-check, so the new-disk gate (its own
# test is tests/new-disk-volumes.test.sh) stays out of the way.
#
# Usage: bash tests/build-push-tag.test.sh [path/to/magneto]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$SCRIPT_DIR/..}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
assert_lacks() { if grep -qF -- "$3" <<< "$2"; then
  fail "$1"; printf '       did NOT want: %q\n' "$3"; else pass "$1"; fi; }
count() { grep -cF -- "$2" <<< "$1"; }

# ============================================================================
# Sandbox: copies of build.sh and the wrappers, plus two fake apps
# ============================================================================
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
M="$WORK/magneto"
mkdir -p "$M/apps/alpha/image" "$M/apps/beta/image" "$M/apps/gamma/image/db" "$WORK/bin"
for f in build.sh build-uat.sh build-prod.sh build-dev.sh build-e2e.sh; do
  cp "$SRC/$f" "$M/$f"
  chmod +x "$M/$f"
done
printf 'FROM scratch\n' > "$M/apps/alpha/image/Dockerfile"
printf 'APP_IMAGE="alpha"\n' > "$M/apps/alpha/image/build.config"
printf 'FROM scratch\n' > "$M/apps/beta/image/Dockerfile"
printf 'APP_IMAGE="beta"\n' > "$M/apps/beta/image/build.config"
printf 'FROM scratch\n' > "$M/apps/gamma/image/Dockerfile"
printf 'FROM scratch\n' > "$M/apps/gamma/image/db/Dockerfile"
printf 'APP_IMAGE="gamma"\nDB_IMAGE="gamma-db"\nDB_NAME="DB"\n' > "$M/apps/gamma/image/build.config"

# docker stub: records each call; every builder exists, every call succeeds. buildx imagetools inspect finds the
# refs listed in the file $EXISTING; any other ref is "not found", or, with INSPECT_FAILS=1, the lookup fails the way
# a registry that refuses the login answers.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
if [ "$1 $2 $3" = "buildx imagetools inspect" ]; then
  if [ -n "${EXISTING:-}" ] && grep -qxF -- "$4" "$EXISTING"; then echo "Name: $4"; exit 0; fi
  if [ -n "${INSPECT_FAILS:-}" ]; then echo "ERROR: unexpected status from HEAD request: 401 Unauthorized" >&2; exit 1; fi
  if [ -n "${INSPECT_SAYS:-}" ]; then echo "$INSPECT_SAYS" >&2; exit 1; fi
  echo "ERROR: $4: not found" >&2
  exit 1
fi
case "$1 $2" in
  "context show") echo default ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/bin/docker"

# run SCRIPT ARGS... -> sets RC, CALLS_TXT, OUT_TXT. Call it directly (not in $(...)). SCRIPT is relative to the
# sandbox's magneto folder, or, with RUN_DIR set, run as given from RUN_DIR (the app-directory mode).
run() {
  local script="$1" state rc=0
  shift
  state="$(mktemp -d "$WORK/state.XXXX")"
  if [ -n "${RUN_DIR:-}" ]; then
    (cd "$RUN_DIR" && CALLS="$state/calls.log" PATH="$WORK/bin:$PATH" bash "$script" "$@") > "$state/out.log" 2>&1 || rc=$?
  else
    CALLS="$state/calls.log" PATH="$WORK/bin:$PATH" bash "$M/$script" "$@" > "$state/out.log" 2>&1 || rc=$?
  fi
  touch "$state/calls.log"
  CALLS_TXT="$(cat "$state/calls.log")"
  OUT_TXT="$(cat "$state/out.log")"
  RC="$rc"
}

DATE_TAG="$(date +%Y.%m.%d)"

# The registries, as the wrappers set them.
reg_of() { sed -n 's/^export REGISTRY=//p' "$SRC/$1"; }
UAT_REG="$(reg_of build-uat.sh)"
PROD_REG="$(reg_of build-prod.sh)"
DEV_REG="$(reg_of build-dev.sh)"
E2E_REG="$(reg_of build-e2e.sh)"
for v in UAT_REG PROD_REG DEV_REG E2E_REG; do
  if [ -z "${!v}" ]; then fail "read $v from its wrapper"; fi
done

# refused <label> SCRIPT ARGS...: exits non-zero with one line that names the fix, and calls no docker command.
refused() {
  local label="$1"
  shift
  run "$@"
  if [ "$RC" -ne 0 ]; then pass "$label: exits non-zero"; else fail "$label: exits non-zero"; fi
  assert_eq "$label: says why in one line" 1 "$(grep -c . <<< "$OUT_TXT")"
  assert_contains "$label: names the fix" "$OUT_TXT" "--push needs --tag <YYYY.MM.DD>"
  assert_eq "$label: no docker call at all" 0 "$(grep -c . <<< "$CALLS_TXT")"
}

# ============================================================================
# Scenarios
# ============================================================================
echo "build-uat.sh and build-prod.sh refuse a push without a dated --tag"
refused "uat alpha --push" build-uat.sh alpha --push
refused "prod alpha --push" build-prod.sh alpha --push
refused "uat --all --push" build-uat.sh --all --push
refused "uat alpha --push --skip-new-disk-check" build-uat.sh alpha --push --skip-new-disk-check
refused "prod alpha --push --tag latest" build-prod.sh alpha --push --tag latest
refused "uat alpha --push --tag=nightly" build-uat.sh alpha --push --tag=nightly
refused "uat alpha --tag 2026.11.1 --push" build-uat.sh alpha --tag 2026.11.1 --push
refused "uat apps/alpha --push (path mode through the wrapper)" build-uat.sh apps/alpha --push
refused "prod --tag 2026.11.11 --tag latest (the last --tag wins)" build-prod.sh alpha --push --tag 2026.11.11 --tag latest

echo "The dated tag is a real date, with only a '-' suffix"
# 2026.09.31 and 2026.08.32 hold an 08 or a 09, which bash reads as a bad octal number unless told base 10: an
# arithmetic error there would skip the whole check, and the push would go ahead.
for bad in 9999.99.99 2026.13.01 2026.00.10 2026.11.00 2026.02.30 2026.04.31 2026.06.31 2026.09.31 2026.11.31 \
           2026.08.32 2025.02.29 2100.02.29 2100.01.01 1999.12.31 2026.11.11.2 2026.11.11- 2026.11.11-a.b; do
  refused "uat --tag $bad" build-uat.sh alpha --push --tag "$bad" --skip-new-disk-check
  assert_lacks "uat --tag $bad: echoes nothing typed" "$OUT_TXT" "$bad"
done
refused "prod --tag=2026.02.30" build-prod.sh alpha --push --tag=2026.02.30 --skip-new-disk-check
for good in 2028.02.29 2000.02.29 2026.08.09 2026.09.08 2026.12.31-rc1; do
  run build-prod.sh alpha --push --tag "$good" --skip-new-disk-check
  assert_eq "prod --tag $good: exits 0" 0 "$RC"
  assert_contains "prod --tag $good: pushes that tag" "$CALLS_TXT" "--tag cr0.io/clouveinc327/alpha:$good"
done

echo "Every wrapper hands its arguments to build.sh unchanged"
for w in build-uat.sh build-prod.sh build-dev.sh build-e2e.sh; do
  assert_eq "$w ends with \"\$SCRIPT_DIR\"/build.sh \"\$@\"" '"$SCRIPT_DIR"/build.sh "$@"' "$(tail -n 1 "$SRC/$w")"
done
# One argument that holds a space stays one argument: build.sh finds no app of that name and calls no docker
# command. Split on the space, it would build and push alpha.
for w in build-dev.sh build-e2e.sh build-uat.sh; do
  run "$w" "alpha --push"
  if [ "$RC" -ne 0 ]; then pass "$w \"alpha --push\": exits non-zero"; else fail "$w \"alpha --push\": exits non-zero"; fi
  assert_eq "$w \"alpha --push\": no docker call" 0 "$(grep -c . <<< "$CALLS_TXT")"
done

echo "A push with a dated --tag goes ahead, with that tag only"
run build-uat.sh alpha --push --tag 2026.11.11 --skip-new-disk-check
assert_eq "uat --push --tag 2026.11.11: exits 0" 0 "$RC"
assert_contains "pushes demo.cr0.io/clouveinc8/alpha:2026.11.11" "$CALLS_TXT" "--tag demo.cr0.io/clouveinc8/alpha:2026.11.11"
assert_lacks "and no :latest" "$CALLS_TXT" "--tag demo.cr0.io/clouveinc8/alpha "
assert_eq "one build, pushed" 1 "$(count "$CALLS_TXT" "--push")"
run build-prod.sh alpha --tag=2026.11.11-2 --push --skip-new-disk-check
assert_eq "prod --tag=2026.11.11-2 --push: exits 0" 0 "$RC"
assert_contains "pushes cr0.io/clouveinc327/alpha:2026.11.11-2" "$CALLS_TXT" "--tag cr0.io/clouveinc327/alpha:2026.11.11-2"
run build-uat.sh --all --push --tag 2026.11.11 --skip-new-disk-check
assert_eq "uat --all --push --tag 2026.11.11: exits 0" 0 "$RC"
assert_eq "pushes all three apps' four images" 4 "$(grep -F -- "buildx build" <<< "$CALLS_TXT" | grep -cF -- ":2026.11.11")"

echo "build.sh refuses a push to UAT's or prod's registry however REGISTRY is set"
REGISTRY="$PROD_REG" refused "REGISTRY=$PROD_REG build.sh alpha --push" build.sh alpha --push
REGISTRY="$UAT_REG" refused "REGISTRY=$UAT_REG build.sh alpha --push" build.sh alpha --push
UAT_HOST="${UAT_REG%%/*}"
PROD_HOST="${PROD_REG%%/*}"
E2E_HOST="${E2E_REG%%/*}"
UPPER_PROD="$(printf '%s' "$PROD_HOST" | tr '[:lower:]' '[:upper:]')"
REGISTRY="$PROD_HOST/another-project" refused "another project on prod's Harbor" build.sh alpha --push
REGISTRY="$UPPER_PROD/clouveinc327" refused "prod's host in upper case" build.sh alpha --push
REGISTRY="$PROD_HOST:443/clouveinc327" refused "prod's host with a port" build.sh alpha --push
REGISTRY="https://$UAT_HOST/clouveinc8" refused "UAT's host with a scheme" build.sh alpha --push
REGISTRY="$UAT_HOST./clouveinc8" refused "UAT's host with a trailing dot" build.sh alpha --push
REGISTRY="registry.clouve.com/clouveinc327" refused "prod's externalURL host, registry.clouve.com" build.sh alpha --push
REGISTRY="demo.reg.clouve.com/clouveinc8" refused "UAT's externalURL host, demo.reg.clouve.com" build.sh alpha --push
# harbor_hosts ENV: the two hosts strato's values give that environment's Harbor (core, then externalURL).
STRATO="${STRATO_DIR:-$SRC/../strato}"
harbor_hosts() {
  local v="$STRATO/cluster/k8s/manifests/clouve-$1/harbor/values.yaml"
  [ -r "$v" ] || return 1
  sed -nE 's/^ +core: *([A-Za-z0-9.-]+).*/\1/p' "$v" | head -n 1
  sed -nE 's#^externalURL: *https?://([A-Za-z0-9.-]+).*#\1#p' "$v"
}
if harbor_hosts uat >/dev/null && harbor_hosts prod >/dev/null; then
  for env in uat prod; do
    for host in $(harbor_hosts "$env"); do
      REGISTRY="$host/any-project" refused "$env Harbor host $host (strato's values)" build.sh alpha --push
    done
  done
  for host in $(harbor_hosts develop); do
    REGISTRY="$host/clouveinc8" refused "dev Harbor host $host (strato's values)" build.sh alpha --push
  done
else
  echo "  - skipped the strato values check: no strato checkout at $STRATO"
fi
REGISTRY="$PROD_REG" refused "path mode: build.sh apps/alpha --push" build.sh apps/alpha --push
REGISTRY="$PROD_REG" RUN_DIR="$M/apps/alpha" refused "app-directory mode: ../../build.sh ./ --push" ../../build.sh ./ --push
REGISTRY="$PROD_REG" RUN_DIR="$M/apps/alpha" refused "app-directory mode, no target: ../../build.sh --push" \
  ../../build.sh --push
REGISTRY="$PROD_REG" refused "REGISTRY=$PROD_REG build.sh --all --push" build.sh --all --push
REGISTRY="$PROD_REG" run build.sh alpha --push --tag 2026.11.11
assert_eq "REGISTRY=$PROD_REG build.sh alpha --push --tag 2026.11.11: exits 0" 0 "$RC"
assert_contains "pushes $PROD_REG/alpha:2026.11.11" "$CALLS_TXT" "--tag $PROD_REG/alpha:2026.11.11"
assert_lacks "and no :latest" "$CALLS_TXT" "--tag $PROD_REG/alpha "
REGISTRY="$PROD_REG" run build.sh alpha
assert_eq "REGISTRY=$PROD_REG build.sh alpha (local): exits 0" 0 "$RC"
PUSH_NEEDS_DATED_TAG=1 refused "PUSH_NEEDS_DATED_TAG=1 build.sh alpha --push (any registry)" build.sh alpha --push

echo "Local builds, build.sh itself and build-dev.sh work as before"
run build-uat.sh alpha
assert_eq "uat alpha (local): exits 0" 0 "$RC"
assert_contains "tags :<DATE> locally" "$CALLS_TXT" "--tag demo.cr0.io/clouveinc8/alpha:$DATE_TAG"
assert_lacks "and pushes nothing" "$CALLS_TXT" "--push"
run build-prod.sh alpha --tag 2026.11.11
assert_eq "prod alpha --tag 2026.11.11 (local): exits 0" 0 "$RC"
run build.sh alpha --push
assert_eq "build.sh alpha --push: exits 0" 0 "$RC"
assert_contains "pushes :latest as before" "$CALLS_TXT" "--tag r.clv.zone/e2eorg/alpha --provenance"
refused "build-dev.sh alpha --push (it would move dev's :latest)" build-dev.sh alpha --push
REGISTRY="$DEV_REG" refused "REGISTRY=$DEV_REG build.sh alpha --push" build.sh alpha --push
run build-e2e.sh alpha --push
assert_eq "build-e2e.sh alpha --push: exits 0" 0 "$RC"
assert_contains "pushes :latest to the rig's registry as before" "$CALLS_TXT" "--tag $E2E_REG/alpha --provenance"
REGISTRY="dev.reg.clouve.com/clouveinc8" refused "dev's externalURL host, dev.reg.clouve.com" build.sh alpha --push
echo "Every registry but the rig's follows both rules"
REGISTRY="evil-$PROD_HOST/x" refused "a host that only ends in prod's host is held to the rules like any other" \
  build.sh alpha --push
REGISTRY="harbor.new-env.example/proj" refused "a registry no list names yet (a new environment's Harbor)" \
  build.sh alpha --push
REGISTRY="$E2E_HOST.evil.com/x" refused "a host that only starts with the rig's isn't the rig's" build.sh alpha --push
REGISTRY="registry.clouve.dev/e2eorg" run build.sh alpha --push
assert_eq "the rig's other name, registry.clouve.dev, needs neither rule: exits 0" 0 "$RC"
REGISTRY="$(printf '%s' "$E2E_HOST" | tr '[:lower:]' '[:upper:]'):443/e2eorg" run build.sh alpha --push
assert_eq "the rig's host in upper case with a port: exits 0" 0 "$RC"
if harbor_hosts e2e >/dev/null; then
  for host in $(harbor_hosts e2e); do
    REGISTRY="$host/e2eorg" run build.sh alpha --push
    assert_eq "the rig's Harbor host $host (strato's values) needs neither rule: exits 0" 0 "$RC"
  done
fi

echo "Dev pushes need a dated tag too, and no image of the target may have it already"
run build-dev.sh alpha --push --tag 2026.11.13
assert_eq "build-dev.sh alpha --push --tag 2026.11.13: exits 0" 0 "$RC"
assert_contains "looks the tag up first" "$CALLS_TXT" "docker buildx imagetools inspect $DEV_REG/alpha:2026.11.13"
assert_contains "pushes $DEV_REG/alpha:2026.11.13" "$CALLS_TXT" "--tag $DEV_REG/alpha:2026.11.13"
assert_lacks "and no :latest" "$CALLS_TXT" "--tag $DEV_REG/alpha "
first_lookup="$(grep -n -F -- "imagetools inspect" <<< "$CALLS_TXT" | head -n 1 | cut -d: -f1)"
first_build="$(grep -n -F -- "buildx build" <<< "$CALLS_TXT" | head -n 1 | cut -d: -f1)"
if [ -n "$first_lookup" ] && [ -n "$first_build" ] && [ "$first_lookup" -lt "$first_build" ]; then
  pass "the lookup comes before the build"
else
  fail "the lookup comes before the build"
fi

# refused_existing LABEL SCRIPT ARGS...: exits non-zero, says why in a line that names the rule and not the typed tag,
# and builds nothing.
refused_existing() {
  local label="$1" tag
  shift
  run "$@"
  if [ "$RC" -ne 0 ]; then pass "$label: exits non-zero"; else fail "$label: exits non-zero"; fi
  assert_contains "$label: says the tag is already there" "$OUT_TXT" "already"
  assert_eq "$label: builds nothing" 0 "$(grep -cF -- "buildx build" <<< "$CALLS_TXT")"
  assert_eq "$label: prunes nothing" 0 "$(grep -cF -- "buildx prune" <<< "$CALLS_TXT")"
  for tag in "$@"; do
    case "$tag" in 20*) assert_lacks "$label: echoes nothing typed" "$OUT_TXT" "$tag" ;; esac
  done
}
EXISTING="$WORK/existing"
cat > "$EXISTING" <<EOT
$PROD_REG/alpha:2026.11.12
$UAT_REG/gamma-db:2026.11.12
$DEV_REG/alpha:2026.11.12
$E2E_REG/alpha:2026.10.12
EOT
export EXISTING
refused_existing "prod alpha --push --tag 2026.11.12 (4.5.5's tag on prod)" \
  build-prod.sh alpha --push --tag 2026.11.12 --skip-new-disk-check
refused_existing "uat gamma --push --tag 2026.11.12 (only its db image has the tag)" \
  build-uat.sh gamma --push --tag 2026.11.12 --skip-new-disk-check
assert_contains "uat gamma: looks up the app image" "$CALLS_TXT" "imagetools inspect $UAT_REG/gamma:2026.11.12"
assert_contains "uat gamma: looks up the db image" "$CALLS_TXT" "imagetools inspect $UAT_REG/gamma-db:2026.11.12"
refused_existing "dev alpha --push --tag 2026.11.12" build-dev.sh alpha --push --tag 2026.11.12
REGISTRY="$PROD_REG" refused_existing "REGISTRY=$PROD_REG build.sh alpha --push --tag 2026.11.12" \
  build.sh alpha --push --tag 2026.11.12
refused_existing "uat --all --push --tag 2026.11.12 (gamma's db image has it): no target is built" \
  build-uat.sh --all --push --tag 2026.11.12 --skip-new-disk-check
run build-uat.sh gamma --push --tag 2026.11.13 --skip-new-disk-check
assert_eq "uat gamma --push --tag 2026.11.13 (neither image has it): exits 0" 0 "$RC"
assert_eq "both of gamma's images are built" 2 "$(grep -cF -- "buildx build" <<< "$CALLS_TXT")"
INSPECT_SAYS='ERROR: context "x": not found' run build-prod.sh beta --push --tag 2026.11.13 --skip-new-disk-check
if [ "$RC" -ne 0 ]; then pass "an error that ends in \"not found\" but isn't about the image: exits non-zero"; else
  fail "an error that ends in \"not found\" but isn't about the image: exits non-zero"; fi
assert_eq "... and builds nothing" 0 "$(grep -cF -- "buildx build" <<< "$CALLS_TXT")"
INSPECT_SAYS="ERROR: $PROD_REG/beta:2026.11.13: manifest unknown: MANIFEST_UNKNOWN" \
  run build-prod.sh beta --push --tag 2026.11.13 --skip-new-disk-check
assert_eq "the registry's own MANIFEST_UNKNOWN for that image counts as not found: exits 0" 0 "$RC"
INSPECT_FAILS=1 run build-prod.sh beta --push --tag 2026.11.13 --skip-new-disk-check
if [ "$RC" -ne 0 ]; then pass "a lookup that fails (not \"not found\"): exits non-zero"; else fail "a lookup that fails (not \"not found\"): exits non-zero"; fi
assert_contains "a lookup that fails: says it couldn't check" "$OUT_TXT" "couldn't check"
assert_eq "a lookup that fails: builds nothing" 0 "$(grep -cF -- "buildx build" <<< "$CALLS_TXT")"
assert_lacks "a lookup that fails: echoes nothing typed" "$OUT_TXT" "2026.11.13"
run build-e2e.sh alpha --push --tag 2026.10.12
assert_eq "the rig: build-e2e.sh re-pushes the E2E fixture tag (exits 0)" 0 "$RC"
assert_eq "the rig: no lookup" 0 "$(grep -cF -- "imagetools inspect" <<< "$CALLS_TXT")"
PUSH_NEEDS_DATED_TAG=1 refused_existing "PUSH_NEEDS_DATED_TAG=1 build-e2e.sh alpha --push --tag 2026.10.12" \
  build-e2e.sh alpha --push --tag 2026.10.12
unset EXISTING

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All build push-tag tests passed."
else
  echo "Some build push-tag tests FAILED."
fi
exit "$FAILED"
