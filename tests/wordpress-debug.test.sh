#!/bin/bash

# ============================================================================
# WordPress: WORDPRESS_DEBUG='false' leaves WP_DEBUG off, and the admin
# signs in with the password given at install
# ============================================================================
# The listing sets WORDPRESS_DEBUG: 'false'. The official image's wp-config.php
# defines WP_DEBUG as !!getenv_docker('WORDPRESS_DEBUG', ''), so any value that
# isn't empty turns it on, 'false' included. The image's entrypoint unsets the
# variable when it is false, off or no, in any case, before Apache starts, so
# Apache (PID 1) and the AI Assistant's wp.sh, which reads PID 1's
# environment, see WP_DEBUG off. Any other value, such as 1, keeps it on.
#
# The test installs WordPress for real: a wordpress-mariadb container with no
# network (--network none) and a WordPress container in its network namespace,
# the image's own entrypoint doing the first install. Then:
#   - the admin signs in (wp_authenticate, as the login form does) with the
#     password given at install, though it has spaces at both ends, a $, both
#     quotes and a backslash (the install sets it from the environment, never
#     from a command line; WordPress trims both ends at install and at sign-in),
#     and not with it a character short; the container's
#     log holds neither it nor a generated one, nor the admin's email address
#     or login: it names the admin by WordPress user id;
#   - WP_DEBUG, read the way Apache reads it (wp eval under PID 1's
#     environment alone: docker exec on its own would use the container's
#     settings, where WORDPRESS_DEBUG is still 'false'), is false for false,
#     FALSE, off and no, and true for 1. Each value is a new container on the
#     same files and database.
#
# --image NAME=REF (NAME is wordpress or wordpress-mariadb) uses an image that
# is already built; otherwise the test builds both and removes them at the end.
# Every container and volume it makes is named wpdbg-t-* and removed when it
# exits. Needs Docker.
#
# Usage: bash tests/wordpress-debug.test.sh [--image NAME=REF]...
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="wpdbg-t-"
READY_SECONDS=240

declare -A CONTEXT=(
  [wordpress]="$REPO_DIR/apps/wordpress/image"
  [wordpress-mariadb]="$REPO_DIR/apps/wordpress/image/mariadb"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${CONTEXT[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
    *) usage ;;
  esac
  shift
done

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

BUILT=()
remove_test_objects() {
  local name
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls --format '{{.Name}}' 2>/dev/null)
}
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  local image
  remove_test_objects
  for image in "${BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_objects

for name in wordpress-mariadb wordpress; do
  if [ -z "${IMAGE[$name]:-}" ]; then
    image="clouve-test/$name:wpdbg-test"
    if log="$(docker build -t "$image" "${CONTEXT[$name]}" 2>&1)"; then
      BUILT+=("$image")
      IMAGE[$name]="$image"
    else
      fail "$name builds"
      printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
      exit 1
    fi
  elif ! docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1; then
    fail "the image ${IMAGE[$name]} is on this machine"
    exit 1
  fi
done

rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
DB_PW="$(rand)"
# Spaces at both ends, a $, both quotes and a backslash.
# ADMIN_CORE is its random part, which any form of it in a log would hold (WordPress trims the ends).
ADMIN_CORE="$(rand)"
ADMIN_PW="  pw\$$ADMIN_CORE 'q' \"dq\" back\\slash  "
ADMIN_USER="First_Last"
DB="${PREFIX}db"
WP="${PREFIX}wp"
HTML="${PREFIX}html"

echo "Starting wordpress-mariadb (no network)"
if ! docker run -d --pull=never --name "$DB" --network none \
    -e MYSQL_DATABASE=wordpress -e MYSQL_USER=wordpress -e "MYSQL_PASSWORD=$DB_PW" -e "MYSQL_ROOT_PASSWORD=$(rand)" \
    "${IMAGE[wordpress-mariadb]}" >/dev/null; then
  fail "the database container starts"
  exit 1
fi
db_ready=false
for _ in $(seq 1 $((READY_SECONDS / 2))); do
  if docker exec -e "MYSQL_PWD=$DB_PW" "$DB" mariadb -h 127.0.0.1 -u wordpress -e 'SELECT 1' wordpress >/dev/null 2>&1; then
    db_ready=true
    break
  fi
  sleep 2
done
if $db_ready; then pass "the database answers"; else fail "the database answers"; exit 1; fi

# start_wp <WORDPRESS_DEBUG value>: a WordPress container on the same files ($HTML) and database. Returns 0 once
# Apache answers on port 80.
start_wp() {
  docker rm -f "$WP" >/dev/null 2>&1
  docker run -d --pull=never --name "$WP" --network "container:$DB" -v "$HTML:/var/www/html" \
    -e WORDPRESS_DB_HOST=127.0.0.1:3306 -e WORDPRESS_DB_NAME=wordpress -e WORDPRESS_DB_USER=wordpress \
    -e "WORDPRESS_DB_PASSWORD=$DB_PW" -e WORDPRESS_SITE_URL=http://localhost -e WORDPRESS_SITE_TITLE='Debug test' \
    -e WORDPRESS_ADMIN_EMAIL=admin@example.test -e "WORDPRESS_ADMIN_USER=$ADMIN_USER" \
    -e "WORDPRESS_ADMIN_PASSWORD=$ADMIN_PW" -e WORDPRESS_TABLE_PREFIX=wp_ -e "WORDPRESS_DEBUG=$1" \
    "${IMAGE[wordpress]}" >/dev/null || return 1
  local _
  for _ in $(seq 1 $((READY_SECONDS / 2))); do
    if docker exec "$WP" curl -s -o /dev/null http://127.0.0.1/ 2>/dev/null &&
       [ "$(docker exec "$WP" cat /proc/1/comm 2>/dev/null)" = apache2 ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# wp_debug: WP_DEBUG as Apache sees it: wp eval with PID 1's environment and nothing else.
wp_debug() {
  # shellcheck disable=SC2016  # the script is for the bash in the container
  docker exec "$WP" env -i bash -c '
    while IFS= read -r -d "" kv; do export "$kv"; done < /proc/1/environ
    wp eval "var_export(WP_DEBUG);" --path=/var/www/html --allow-root 2>/dev/null | tail -n 1'
}

echo "First install, WORDPRESS_DEBUG=false"
if start_wp false; then
  pass "WordPress installs and Apache answers"
else
  fail "WordPress installs and Apache answers"
  docker logs --tail 20 "$WP" 2>&1 | sed 's/^/       | /'
  exit 1
fi
# shellcheck disable=SC2016  # PHP code, for wp eval
check='var_export(!is_wp_error(wp_authenticate(getenv("T_USER"), getenv("T_PW"))));'
signs_in="$(docker exec -e "T_USER=$ADMIN_USER" -e "T_PW=$ADMIN_PW" "$WP" \
  wp eval "$check" --path=/var/www/html --allow-root 2>/dev/null | tail -n 1)"
assert_eq "the admin signs in with the password as given" "true" "$signs_in"
wrong="$(docker exec -e "T_USER=$ADMIN_USER" -e "T_PW=${ADMIN_PW/\\/}" "$WP" \
  wp eval "$check" --path=/var/www/html --allow-root 2>/dev/null | tail -n 1)"
assert_eq "and not with it a backslash short" "false" "$wrong"
log="$(docker logs "$WP" 2>&1)"
assert_eq "the log doesn't hold the admin password" "0" "$(grep -cF -- "$ADMIN_CORE" <<< "$log")"
assert_eq "nor a generated one" "0" "$(grep -c 'Admin password' <<< "$log")"
# A log line about a person names their user id or nothing: never their address, nor the login made of their name.
assert_eq "the log doesn't hold the admin's email address" "0" "$(grep -cF 'admin@example.test' <<< "$log")"
assert_eq "nor the admin's login" "0" "$(grep -cF "$ADMIN_USER" <<< "$log")"
assert_eq "it names the admin by WordPress user id" "1" "$(grep -c 'Admin account: WordPress user 1$' <<< "$log")"
assert_eq "WP_DEBUG is off for false" "false" "$(wp_debug)"

for value in FALSE off no 1; do
  want=false
  [ "$value" = 1 ] && want=true
  echo "WORDPRESS_DEBUG=$value"
  if start_wp "$value"; then
    assert_eq "WP_DEBUG is $want" "$want" "$(wp_debug)"
  else
    fail "WordPress starts again with WORDPRESS_DEBUG=$value"
    docker logs --tail 10 "$WP" 2>&1 | sed 's/^/       | /'
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sWordPress debug and install checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sWordPress debug and install checks failed.%s\n' "$RED" "$RESET"
exit 1
