#!/bin/bash

# ============================================================================
# SSH host keys in the images with a clouve-ops sshd
# ============================================================================
# Installing openssh-server makes SSH host keys. Kept in an image, those keys
# ship to every deployment, and every tenant's container has the same host
# key. The images delete them at build time, and each container makes its
# own when its clouve-ops sshd starts (ssh-keygen -A in
# start-clouve-ops-sshd.sh, or AI Studio's entrypoint.sh). The MySQL images
# (Oracle Linux) never had any. Moodle's image has its own test
# (tests/moodle-ssh-host-keys.test.sh). The AI Assistant keeps no sibling's host key from
# magneto-agent 4.5.3 on, so new keys at each start don't lock it out there
# (README.md, "The clouve-ops SSH channel", says where such an image can run).
#
# For each image the test checks that:
#   - the image holds no /etc/ssh/ssh_host_* file (and its /etc/ssh can be
#     listed: a failed listing finds no key either);
#   - a container that starts the image's clouve-ops sshd (with
#     CLOUVE_OPS_PASSWORD set) has host keys once sshd listens;
#   - a second container from the same image has different keys.
# The containers run the sshd script as their entrypoint, so the app and its
# database don't start, and they have no network (--network none). AI Studio
# has no such script: its sshd runs under supervisord, so its containers start
# the image's own entrypoint.
#
# --image NAME=REF uses an image that is already built instead of building it,
# and the test leaves it in place. Naming images limits the run to them.
#
# Needs Docker. A build pulls the image's base and runs its package installs.
# Every container the test starts is named ssh-keys-t-*. The containers and
# the images the test built are removed when it exits.
# tests/ssh-host-keys-checks.test.sh runs these checks with a fake docker.
#
# Usage: bash tests/ssh-host-keys.test.sh [--image NAME=REF]... [NAME...]
#   NAME  odoo, odoo-postgres, wordpress, wordpress-mariadb, gibbon,
#         gibbon-mysql, moodle-mysql, nextcloud, nextcloud-mariadb, limesurvey,
#         limesurvey-mariadb, suitecrm, suitecrm-mariadb or ai-studio
#         (default: all)
# ============================================================================

set -uo pipefail
# Byte order for sort and comm alike. In other locales they can disagree on the order of the fingerprints (uutils'
# sort follows the locale and its comm byte order), and comm then misses a key both containers share.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="ssh-keys-t-"    # every container this test starts begins with this
WAIT_SECONDS=120

# The images, where each is built from, and the script that starts its clouve-ops sshd ("" for the image's own
# entrypoint).
ALL=(odoo odoo-postgres wordpress wordpress-mariadb gibbon gibbon-mysql moodle-mysql nextcloud nextcloud-mariadb limesurvey limesurvey-mariadb suitecrm suitecrm-mariadb ai-studio)
declare -A CONTEXT=(
  [odoo]="$REPO_DIR/apps/odoo/image"
  [odoo-postgres]="$REPO_DIR/apps/odoo/image/postgres"
  [wordpress]="$REPO_DIR/apps/wordpress/image"
  [wordpress-mariadb]="$REPO_DIR/apps/wordpress/image/mariadb"
  [gibbon]="$REPO_DIR/apps/gibbon/image"
  [gibbon-mysql]="$REPO_DIR/apps/gibbon/image/mysql"
  [moodle-mysql]="$REPO_DIR/apps/moodle/image/mysql"
  [nextcloud]="$REPO_DIR/apps/nextcloud/image"
  [nextcloud-mariadb]="$REPO_DIR/apps/nextcloud/image/mariadb"
  [limesurvey]="$REPO_DIR/apps/limesurvey/image"
  [limesurvey-mariadb]="$REPO_DIR/apps/limesurvey/image/mariadb"
  [ai-studio]="$REPO_DIR/apps/ai-studio/image"
  [suitecrm]="$REPO_DIR/apps/suitecrm/image"
  [suitecrm-mariadb]="$REPO_DIR/apps/suitecrm/image/mariadb"
)
declare -A SSHD_SCRIPT=(
  [odoo]=/clouve/odoo/installer/start-clouve-ops-sshd.sh
  [odoo-postgres]=/usr/local/bin/start-clouve-ops-sshd.sh
  [wordpress]=/clouve/wordpress/installer/start-clouve-ops-sshd.sh
  [wordpress-mariadb]=/usr/local/bin/start-clouve-ops-sshd.sh
  [gibbon]=/clouve/gibbon/installer/start-clouve-ops-sshd.sh
  [gibbon-mysql]=/usr/local/bin/start-clouve-ops-sshd.sh
  [moodle-mysql]=/usr/local/bin/start-clouve-ops-sshd.sh
  [nextcloud]=/clouve/nextcloud/installer/start-clouve-ops-sshd.sh
  [nextcloud-mariadb]=/usr/local/bin/start-clouve-ops-sshd.sh
  [limesurvey]=/clouve/limesurvey/installer/start-clouve-ops-sshd.sh
  [limesurvey-mariadb]=/usr/local/bin/start-clouve-ops-sshd.sh
  [ai-studio]=""
  [suitecrm]=/clouve/suitecrm/installer/start-clouve-ops-sshd.sh
  [suitecrm-mariadb]=/usr/local/bin/start-clouve-ops-sshd.sh
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/(default: all)/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

NAMES=()

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
      NAMES+=("$1")
      ;;
  esac
  shift
done
[ "${#NAMES[@]}" -gt 0 ] || NAMES=("${ALL[@]}")

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

BUILT=()
# Removes the containers named ssh-keys-t-*, nothing else.
remove_test_containers() {
  local name
  while IFS= read -r name; do
    case "$name" in
      "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;;
    esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}

# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  local image
  remove_test_containers
  for image in "${BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remove_test_containers    # leftovers of a run that was killed

# start_sshd <container> <image> <script>: a container whose only process is the image's clouve-ops sshd, or, with no
# script, one that runs the image's own entrypoint.
start_sshd() {
  local entrypoint=()
  [ -n "$3" ] && entrypoint=(--entrypoint "$3")
  docker run -d --pull=never --name "$1" --network none \
    -e "CLOUVE_OPS_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')" \
    "${entrypoint[@]}" "$2" >/dev/null
}

# fingerprints <container>: the SHA256 fingerprint of each host key, one per line, once sshd listens on port 22.
# Prints nothing when sshd doesn't listen within WAIT_SECONDS.
fingerprints() {
  local _
  for _ in $(seq 1 "$WAIT_SECONDS"); do
    if docker exec "$1" bash -c '</dev/tcp/127.0.0.1/22' >/dev/null 2>&1; then
      # shellcheck disable=SC2016  # the script is for the sh inside the container
      docker exec "$1" sh -c 'for k in /etc/ssh/ssh_host_*_key.pub; do [ -e "$k" ] && ssh-keygen -lf "$k"; done' |
        awk '{print $2}' | sort
      return
    fi
    sleep 1
  done
}

for name in "${NAMES[@]}"; do
  echo
  echo "$name"
  image="${IMAGE[$name]:-}"
  if [ -z "$image" ]; then
    image="clouve-test/$name:ssh-keys-test"
    if log="$(docker build -t "$image" "${CONTEXT[$name]}" 2>&1)"; then
      BUILT+=("$image")
      pass "image builds ($image)"
    else
      fail "image builds ($image)"
      printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
      continue
    fi
  elif ! docker image inspect "$image" >/dev/null 2>&1; then
    fail "the image $image is on this machine"
    continue
  fi

  # /etc/ssh always holds sshd_config, so a listing without it means the run failed: no key found then proves nothing.
  listing="$(docker run --rm --pull=never --network none --entrypoint sh "$image" -c 'ls -A /etc/ssh' 2>&1)"
  baked="$(printf '%s\n' "$listing" | grep '^ssh_host_')"
  if ! printf '%s\n' "$listing" | grep -qx 'sshd_config'; then
    fail "the image holds no SSH host key (its /etc/ssh couldn't be listed)"
    printf '%s\n' "$listing" | tail -n 3 | sed 's/^/       /'
  elif [ -z "$baked" ]; then
    pass "the image holds no SSH host key"
  else
    fail "the image holds no SSH host key"
    printf '%s\n' "$baked" | sed 's/^/       baked in: /'
  fi

  first="$PREFIX$name-1"
  second="$PREFIX$name-2"
  if ! start_sshd "$first" "$image" "${SSHD_SCRIPT[$name]}" || ! start_sshd "$second" "$image" "${SSHD_SCRIPT[$name]}"; then
    fail "two containers start the clouve-ops sshd"
    continue
  fi
  keys1="$(fingerprints "$first")"
  keys2="$(fingerprints "$second")"
  if [ -n "$keys1" ] && [ -n "$keys2" ]; then
    pass "each container has host keys once its sshd listens ($(printf '%s\n' "$keys1" | wc -l) keys)"
  else
    fail "each container has host keys once its sshd listens"
    docker logs --tail 10 "$first" 2>&1 | sed 's/^/       | /'
    continue
  fi
  shared="$(comm -12 <(printf '%s\n' "$keys1") <(printf '%s\n' "$keys2"))"
  if [ -z "$shared" ]; then
    pass "a second container from the same image has different keys"
  else
    fail "a second container from the same image has different keys"
    printf '%s\n' "$shared" | sed 's/^/       in both: /'
  fi
  docker rm -f -v "$first" "$second" >/dev/null 2>&1
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sSSH host key checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sSSH host key checks failed.%s\n' "$RED" "$RESET"
exit 1
