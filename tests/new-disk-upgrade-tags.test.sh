#!/bin/bash

# ============================================================================
# new-disk-start.test.sh --upgrade-from: which images phase 1 runs
# ============================================================================
# --upgrade-from TAG installs a target with its images at TAG, then starts the
# current images on the same volumes. Two ways that can prove nothing:
#   - TAG latest: the build the test has just made is :latest, so both phases
#     run the same images. The runner refuses it.
#   - TAG on only some of the target's images: phase 1 would run the others
#     at their current images, and the move under test never happens for
#     them. The runner refuses that too, and names the services with no TAG.
# With TAG on every image, phase 1 runs each service at TAG.
#
# Runs tests/lib/new_disk_start.py's image lookup (Target.older_images) with a
# fake docker on PATH that knows which images exist. No Docker needed.
#
# Usage: bash tests/new-disk-upgrade-tags.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# The fake docker: `docker image inspect REF` succeeds for the references listed in $FAKE_IMAGES.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "image inspect" ]; then
  for ref in "${@:3}"; do grep -qxF -- "$ref" "$FAKE_IMAGES" || exit 1; done
  exit 0
fi
exit 1
EOF
chmod +x "$WORK/bin/docker"

# lookup TAG IMAGE...: runs older_images for a target with an app and a db service, the images listed being on this
# machine. Prints its lines and "error: <message>" when it refuses.
lookup() {
  local tag="$1"
  shift
  printf '%s\n' "$@" > "$WORK/images"
  PATH="$WORK/bin:$PATH" FAKE_IMAGES="$WORK/images" python3 -I -B - "$SCRIPT_DIR/lib" "$tag" <<'PY'
import sys, types
sys.path.insert(0, sys.argv[1])
import new_disk_start as nd
target = types.SimpleNamespace(upgrade_from=sys.argv[2], label="shop")
config = {"services": {"app": {"image": "r.clv.zone/e2eorg/shop"}, "db": {"image": "r.clv.zone/e2eorg/shop-db"}}}
try:
    nd.Target.older_images(target, config, ["app", "db"])
except nd.SetupError as err:
    print("error: %s" % err)
PY
}

echo "Every image has the tag: phase 1 runs each at it"
out="$(lookup envpin455 r.clv.zone/e2eorg/shop:envpin455 r.clv.zone/e2eorg/shop-db:envpin455)"
assert_eq "app at the tag" "1" "$(grep -cxF '  phase 1 runs app as r.clv.zone/e2eorg/shop:envpin455' <<< "$out")"
assert_eq "db at the tag" "1" "$(grep -cxF '  phase 1 runs db as r.clv.zone/e2eorg/shop-db:envpin455' <<< "$out")"
assert_eq "no refusal" "0" "$(grep -c '^error:' <<< "$out")"

echo "Only some images have the tag: refused, naming the others"
out="$(lookup envpin455 r.clv.zone/e2eorg/shop:envpin455)"
assert_eq "refused" "1" "$(grep -c '^error: .*have the tag envpin455' <<< "$out")"
assert_eq "it names the service with no such image" "1" "$(grep -c '^error: .*: db' <<< "$out")"
assert_eq "phase 1 isn't announced" "0" "$(grep -c 'phase 1 runs' <<< "$out")"

echo "No image has the tag: refused, as before"
out="$(lookup envpin455)"
assert_eq "refused" "1" "$(grep -c '^error: no image of shop has the tag envpin455' <<< "$out")"

echo "--upgrade-from latest: refused, the current build is :latest"
out="$(lookup latest r.clv.zone/e2eorg/shop:latest r.clv.zone/e2eorg/shop-db:latest)"
assert_eq "refused" "1" "$(grep -c '^error: .*latest' <<< "$out")"
assert_eq "phase 1 isn't announced" "0" "$(grep -c 'phase 1 runs' <<< "$out")"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%s--upgrade-from image checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%s--upgrade-from image checks failed.%s\n' "$RED" "$RESET"
exit 1
