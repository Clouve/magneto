#!/bin/bash

# ============================================================================
# build.sh, build-uat.sh, build-prod.sh: a push to UAT or prod needs a dated --tag
# ============================================================================
# Without --tag, build.sh tags each image :<DATE> and :latest, and a push moves
# :latest, which every deployment that pins it pulls at its next restart.
# Rebuilt images reach UAT and prod only as dated tags, through a listing's new
# version (AJ, 2026-11-11). So a push to UAT's or prod's registry needs --tag
# with a date (YYYY.MM.DD, with an optional suffix such as 2026.11.11-2 for a
# second build that day), or build.sh refuses it: one line, a non-zero exit,
# and no docker call at all. --tag latest is refused the same way. That holds
# however the push gets there: build-uat.sh or build-prod.sh, or build.sh
# itself with REGISTRY set by hand to any project on UAT's or prod's Harbor, in
# any case, with a port or a scheme, in name, path and app-directory mode, and
# with --all. Each Harbor answers on two hosts: the one the wrappers push to
# (read from them here) and its externalURL host, which strato copies Harbor's
# whole Ingress rule to (strato cluster/k8s/manifests/clouve-<env>/harbor/
# values.yaml, cluster/k8s/actions/setup-harbor and upgrade-harbor): UAT
# demo.cr0.io and demo.reg.clouve.com, prod cr0.io and registry.clouve.com.
# When a strato checkout is next to this repo (or STRATO_DIR names one), the
# test also reads both hosts of each environment from those values files. PUSH_NEEDS_DATED_TAG=1 turns the rule on for any registry. A local
# build (no --push), with or without --tag, works as before, and so do pushes
# to dev's registry (build-dev.sh) and the rig's (build-e2e.sh, and build.sh's
# default).
#
# Runs copies of build.sh and the four wrappers against two fake apps in a
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
mkdir -p "$M/apps/alpha/image" "$M/apps/beta/image" "$WORK/bin"
for f in build.sh build-uat.sh build-prod.sh build-dev.sh build-e2e.sh; do
  cp "$SRC/$f" "$M/$f"
  chmod +x "$M/$f"
done
printf 'FROM scratch\n' > "$M/apps/alpha/image/Dockerfile"
printf 'APP_IMAGE="alpha"\n' > "$M/apps/alpha/image/build.config"
printf 'FROM scratch\n' > "$M/apps/beta/image/Dockerfile"
printf 'APP_IMAGE="beta"\n' > "$M/apps/beta/image/build.config"

# docker stub: records each call; every builder exists, every call succeeds.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
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
assert_eq "pushes both apps" 2 "$(count "$CALLS_TXT" ":2026.11.11")"

echo "build.sh refuses a push to UAT's or prod's registry however REGISTRY is set"
REGISTRY="$PROD_REG" refused "REGISTRY=$PROD_REG build.sh alpha --push" build.sh alpha --push
REGISTRY="$UAT_REG" refused "REGISTRY=$UAT_REG build.sh alpha --push" build.sh alpha --push
UAT_HOST="${UAT_REG%%/*}"
PROD_HOST="${PROD_REG%%/*}"
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
    REGISTRY="$host/clouveinc8" run build.sh alpha --push
    assert_eq "dev Harbor host $host (strato's values) still pushes: exits 0" 0 "$RC"
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
run build-dev.sh alpha --push
assert_eq "build-dev.sh alpha --push: exits 0" 0 "$RC"
assert_contains "pushes :<DATE> to dev" "$CALLS_TXT" "--tag $DEV_REG/alpha:$DATE_TAG"
REGISTRY="$DEV_REG" run build.sh alpha --push
assert_eq "REGISTRY=$DEV_REG build.sh alpha --push: exits 0" 0 "$RC"
assert_contains "pushes :latest to dev as before" "$CALLS_TXT" "--tag $DEV_REG/alpha --provenance"
run build-e2e.sh alpha --push
assert_eq "build-e2e.sh alpha --push: exits 0" 0 "$RC"
assert_contains "pushes :latest to the rig's registry as before" "$CALLS_TXT" "--tag $E2E_REG/alpha --provenance"
REGISTRY="dev.reg.clouve.com/clouveinc8" run build.sh alpha --push
assert_eq "REGISTRY=dev.reg.clouve.com/clouveinc8 build.sh alpha --push (dev's externalURL host): exits 0" 0 "$RC"
REGISTRY="evil-$PROD_HOST/x" run build.sh alpha --push
assert_eq "a host that only ends in prod's host isn't prod's: exits 0" 0 "$RC"

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  echo "All build push-tag tests passed."
else
  echo "Some build push-tag tests FAILED."
fi
exit "$FAILED"
