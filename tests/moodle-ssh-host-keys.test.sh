#!/bin/bash
# ============================================================================
# SSH host keys in the Moodle image
# ============================================================================
# Installing openssh-server makes SSH host keys. Kept in an image, those keys
# ship to every deployment, and every tenant's container has the same host key
# (README.md, "The clouve-ops SSH channel"). The Moodle image deletes them at
# build time, and each container makes its own when its clouve-ops sshd starts
# (ssh-keygen -A in start-clouve-ops-sshd.sh). The Moodle MySQL image (Oracle
# Linux) never had any.
#
# For each image (moodle and moodle-mysql) the test checks that:
#   - the image holds no /etc/ssh/ssh_host_* file;
#   - a container that starts the image's clouve-ops sshd (with a made-up
#     CLOUVE_OPS_PASSWORD) has host keys once sshd listens;
#   - a second container from the same image has different keys.
# The containers run the sshd script as their entrypoint, so neither Moodle nor
# MySQL starts, and they have no network (--network none).
#
# The images are the ones ./build.sh moodle tagged on this machine, at TAG
# (default latest). Every container the test starts is named moodle-ssh-keys-t-*,
# and the test removes them when it exits. Needs Docker.
#
# Usage: bash tests/moodle-ssh-host-keys.test.sh [--tag TAG]
# ============================================================================

set -uo pipefail

PREFIX="moodle-ssh-keys-t-"
WAIT_SECONDS=60
TAG=latest
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; [ -n "$TAG" ] || { echo "Usage: bash tests/moodle-ssh-host-keys.test.sh [--tag TAG]" >&2; exit 2; }
      shift ;;
    *) echo "Usage: bash tests/moodle-ssh-host-keys.test.sh [--tag TAG]" >&2; exit 2 ;;
  esac
  shift
done

NAMES=(moodle moodle-mysql)
declare -A SSHD_SCRIPT=(
  [moodle]=/clouve/moodle/installer/start-clouve-ops-sshd.sh
  [moodle-mysql]=/usr/local/bin/start-clouve-ops-sshd.sh
)

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

# Removes the containers named moodle-ssh-keys-t-*, nothing else.
remove_test_containers() {
  local name
  while IFS= read -r name; do
    case "$name" in
      "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;;
    esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}
trap remove_test_containers EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_containers    # leftovers of a run that was killed

# start_sshd <container> <image> <script>: a container whose only process is the image's clouve-ops sshd.
start_sshd() {
  docker run -d --pull=never --name "$1" --network none \
    -e "CLOUVE_OPS_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')" \
    --entrypoint "$3" "$2" >/dev/null
}

# fingerprints <container>: the SHA256 fingerprint of each host key, one per line, once sshd listens on port 22.
# Prints nothing when sshd doesn't listen within WAIT_SECONDS.
fingerprints() {
  local _
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    if docker exec "$1" bash -c '</dev/tcp/127.0.0.1/22' >/dev/null 2>&1; then
      # shellcheck disable=SC2016  # the script is for the sh inside the container
      docker exec "$1" sh -c 'for k in /etc/ssh/ssh_host_*_key.pub; do [ -e "$k" ] && ssh-keygen -lf "$k"; done' |
        awk '{print $2}' | LC_ALL=C sort
      return
    fi
    sleep 1
  done
}

for name in "${NAMES[@]}"; do
  echo
  echo "$name"
  image="r.clv.zone/e2eorg/$name:$TAG"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    fail "$image is on this machine (run ./build.sh moodle first)"
    continue
  fi
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  shipped="$(docker run --rm --pull=never --network none --entrypoint sh "$image" \
    -c 'ls /etc/ssh >/dev/null && for f in /etc/ssh/ssh_host_*; do [ -e "$f" ] && echo "$f"; done; true' 2>&1)"
  if [ -z "$shipped" ]; then
    pass "the image ships no SSH host keys"
  else
    fail "the image ships no SSH host keys"
    printf '       %s\n' $shipped
  fi
  start_sshd "${PREFIX}${name}-1" "$image" "${SSHD_SCRIPT[$name]}"
  start_sshd "${PREFIX}${name}-2" "$image" "${SSHD_SCRIPT[$name]}"
  first="$(fingerprints "${PREFIX}${name}-1")"
  second="$(fingerprints "${PREFIX}${name}-2")"
  if [ -n "$first" ]; then pass "a container makes its own keys when its sshd starts"; else
    fail "a container makes its own keys when its sshd starts (no sshd on port 22 within ${WAIT_SECONDS} s)"; fi
  if [ -n "$first" ] && [ -n "$second" ] && [ -z "$(LC_ALL=C comm -12 <(echo "$first") <(echo "$second"))" ]; then
    pass "two containers from the image have different keys"
  else
    fail "two containers from the image have different keys"
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then echo "${GREEN}All checks passed.${RESET}"; else echo "${RED}Some checks failed.${RESET}"; fi
exit "$FAILED"
