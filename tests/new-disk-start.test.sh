#!/bin/bash
# ============================================================================
# New-disk start test
# ============================================================================
# Starts magneto apps and bundles the way a cluster starts a new install, and
# judges each container the way the platform does (tests/lib/new_disk_start.py):
#   - every volume is a new disk: a top folder of root's with lost+found in it
#     and none of the files the image keeps at that path (lib/new-disk-volumes.sh);
#   - each container gets its smallest plan's CPU and memory (cpuBase and
#     memoryBase in clv-docker-compose.yml);
#   - each container must pass its own probe (x-clouve-healthcheck: HTTP, TCP or
#     Command) within its liveness budget, initialDelay + failureThreshold x
#     interval seconds and never more than 600, and then keep passing through a
#     settle period without exiting or restarting.
# A run uses its own Compose project with no published ports and no fixed
# container names, so it never collides with a local stack, and it removes
# everything it made when it ends. The Magneto Agent's service is left out
# unless --with-agent is given.
#
# Without --no-build, each app target is built first with ./build.sh (host
# platform only), so what passes is the current source. A bundle runs the images
# of its apps as they are on this machine; build those apps first.
#
# When an app target that this run built passes, the run records the pass for
# the exact source it built (lib/new-disk-passes.sh), but only when the images
# it judged are the ones that build just made (it builds with REGISTRY unset, so
# its tags are the ones the compose files run). build-uat.sh and build-prod.sh
# push only an app whose current source has a pass from a full run: one with a
# --settle below the default 90 s is recorded, and doesn't count for a push. A
# --no-build or --upgrade-from run, and a bundle, records nothing.
#
# --upgrade-from TAG installs each target with its images at TAG first (the
# previous dated build, for example 2026.10.22), then starts the current images
# on the same volumes. It fails when either start fails or a volume's top folder
# changes its owner or mode: how a fix shows it leaves existing installs alone.
#
# Usage: bash tests/new-disk-start.test.sh [--no-build] [--with-agent] [--upgrade-from TAG]
#                                          [--settle SECONDS] [--keep] (TARGET... | --all)
#   TARGET  an app or bundle name (nextcloud, education-kit), or a path to a
#           folder with a docker-compose.yml (and its clv-docker-compose.yml)
#   --all   every app and bundle
#   --keep  leave each target's stack running afterwards (to look at it)
# Needs Docker, python3 with PyYAML.
# Exit status: 0 when every target passes, 1 when one fails, 2 when one can't be
# run (unknown target, a build that fails, a missing image) and none failed.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/lib/new_disk_start.py"
BUILD_CMD="${NEW_DISK_BUILD_CMD:-$REPO/build.sh}"
PREFIX="${NEW_DISK_PROJECT_PREFIX:-ndisk}"
# shellcheck source=lib/new-disk-passes.sh
. "$REPO/lib/new-disk-passes.sh"

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" | sed '$d' >&2
  exit 2
}

BUILD=true
UPGRADE=false
SETTLE=90
RUNNER_ARGS=()
TARGETS=()
ALL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=false ;;
    --with-agent|--keep) RUNNER_ARGS+=("$1") ;;
    --upgrade-from|--settle)
      [ -n "${2:-}" ] || usage
      [ "$1" = --upgrade-from ] && UPGRADE=true
      [ "$1" = --settle ] && SETTLE="$2"
      RUNNER_ARGS+=("$1" "$2")
      shift
      ;;
    --all) ALL=true ;;
    -h|--help) usage ;;
    --*) echo "Unknown option: $1" >&2; usage ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi
# Plain python3, so a PyYAML in the user's site-packages counts (pip --user puts it there on macOS).
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi
if [ "$ALL" = true ]; then
  for dir in "$REPO"/apps/*/ "$REPO"/bundles/*/; do
    [ -f "$dir/docker-compose.yml" ] && TARGETS+=("${dir%/}")
  done
fi
[ ${#TARGETS[@]} -gt 0 ] || usage

# own_images_built DIR: whether every image of the target that build.sh makes (the r.clv.zone/e2eorg/ ones) is the image
# this run's build just tagged with today's date. Otherwise the run judged something else (a pinned tag, an older
# :latest), and no pass may be recorded for this source.
own_images_built() {
  local ref repo today id built ok=0
  today="$(date +%Y.%m.%d)"
  for ref in $(docker compose -f "$1/docker-compose.yml" config --images 2>/dev/null); do
    case "$ref" in r.clv.zone/e2eorg/*) ;; *) continue ;; esac
    repo="${ref%%@*}"
    case "${repo##*/}" in *:*) repo="${repo%:*}" ;; esac
    id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)"
    built="$(docker image inspect -f '{{.Id}}' "$repo:$today" 2>/dev/null)"
    if [ -z "$id" ] || [ "$id" != "$built" ]; then
      echo "  No pass recorded: $ref is not the image this run's build made"
      ok=1
    fi
  done
  return "$ok"
}

# resolve TARGET: prints "<kind> <dir>", kind app (it has image/ to build), bundle or path; nothing when unknown
resolve() {
  local t="$1" dir=""
  if [[ "$t" == */* ]]; then
    [ -f "$t/docker-compose.yml" ] && dir="$(cd "$t" && pwd)"
  elif [ -f "$REPO/apps/$t/docker-compose.yml" ]; then
    dir="$REPO/apps/$t"
  elif [ -f "$REPO/bundles/$t/docker-compose.yml" ]; then
    dir="$REPO/bundles/$t"
  fi
  [ -n "$dir" ] || return 1
  if [ -d "$dir/image" ]; then echo "app $dir"; elif [[ "$dir" == "$REPO/bundles/"* ]]; then echo "bundle $dir"; else
    echo "path $dir"; fi
}

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT
SUMMARY=()
FAILED=0
UNRUNNABLE=0
for t in "${TARGETS[@]}"; do
  if ! resolved="$(resolve "$t")"; then
    echo "✗ Unknown target: $t (an app or bundle name, or a folder with a docker-compose.yml)"
    SUMMARY+=("ERROR $t (unknown)")
    UNRUNNABLE=1
    continue
  fi
  kind="${resolved%% *}"
  dir="${resolved#* }"
  label="$(basename "$dir")"
  # A pass is recorded only for an app this run builds, on the source it builds: the hash comes first.
  hash=""
  if [ "$BUILD" = true ] && [ "$kind" = app ] && [ "$UPGRADE" = false ]; then
    hash="$(nd_source_hash "$dir")" || hash=""
  fi
  if [ "$BUILD" = true ] && [ "$kind" = app ]; then
    echo "Building $label with $BUILD_CMD (host platform)..."
    # Without REGISTRY, build.sh tags the images the compose files run (r.clv.zone/e2eorg/...), whatever the shell has.
    if ! env -u REGISTRY "$BUILD_CMD" "$dir" > "$LOGS/build-$label.log" 2>&1; then
      tail -n 20 "$LOGS/build-$label.log" | sed 's/^/    build: /'
      echo "✗ $label: the build failed, so it wasn't started"
      SUMMARY+=("ERROR $label (build failed)")
      UNRUNNABLE=1
      continue
    fi
  fi
  project="$(printf '%s-%s-%s' "$PREFIX" "$label" "$$" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  python3 -u "$RUNNER" --dir "$dir" --project "$project" --label "$label" --repo "$REPO" \
    ${RUNNER_ARGS[@]+"${RUNNER_ARGS[@]}"}
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$hash" ] && own_images_built "$dir"; then
    # shellcheck disable=SC2046  # one argument per image reference
    if nd_record_pass "$label" "$hash" "$SETTLE" $(docker compose -f "$dir/docker-compose.yml" config --images 2>/dev/null); then
      if [ "$SETTLE" -ge 90 ] 2>/dev/null; then
        echo "  Recorded a new-disk pass for $label (source ${hash:0:12})"
      else
        echo "  Recorded a new-disk pass for $label (source ${hash:0:12}), but a ${SETTLE} s settle is too short for a UAT or prod push (they need the full 90 s)"
      fi
    fi
  fi
  case "$rc" in
    0) SUMMARY+=("PASS $label") ;;
    1) SUMMARY+=("FAIL $label"); FAILED=1 ;;
    *) SUMMARY+=("ERROR $label (couldn't run)"); UNRUNNABLE=1 ;;
  esac
  echo
done

echo "Summary:"
for line in "${SUMMARY[@]}"; do echo "  $line"; done
if [ "$FAILED" -ne 0 ]; then exit 1; fi
if [ "$UNRUNNABLE" -ne 0 ]; then exit 2; fi
exit 0
