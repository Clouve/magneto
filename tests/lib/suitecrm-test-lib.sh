#!/bin/bash
# Shared helpers of the SuiteCRM tests (tests/suitecrm-image.test.sh, tests/suitecrm-entrypoint.test.sh and
# tests/suitecrm-upgrade.test.sh). Source this file. It defines functions and a few variables and sets no shell option.
#
# Names. Every container, volume and network a test makes starts with SC_PREFIX, which is SUITECRM_TEST_PREFIX when
# that is set and "sc-t-" otherwise, so two runs with different prefixes never touch each other. sc_cleanup removes
# what carries the prefix and nothing else.
#
# Images. sc_image NAME makes sure SC_IMAGE[NAME] is an image on this machine. NAME is one of:
#   suitecrm              apps/suitecrm/image of this checkout
#   suitecrm-mariadb      apps/suitecrm/image/mariadb of this checkout
#   suitecrm-old          the 8.9.1 image, built from the Dockerfile and installer of commit SC_OLD_REF
#   suitecrm-mariadb-old  mariadb:12.1, the MariaDB line the 8.9.1 installs were made with
# sc_parse_image_option takes the value of a test's --image NAME=REF option: that image is used as it is and stays on
# the machine. An image the test builds is tagged clouve-test/NAME:sc-test and removed by sc_cleanup.
#
# Needs Docker and git. Nothing here publishes a port or pushes an image.

SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_REPO="$(cd "$SC_LIB_DIR/../.." && pwd)"
SC_PREFIX="${SUITECRM_TEST_PREFIX:-sc-t-}"
# The last commit whose apps/suitecrm builds SuiteCRM 8.9.1.
SC_OLD_REF="${SUITECRM_OLD_REF:-cb6cca2b0fb83f658ec732764a728706296ec7df}"
SC_SHAPER="${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}"
declare -A SC_IMAGE=()
SC_BUILT=()
SC_WORK=""

SC_GREEN=$'\033[0;32m'
SC_RED=$'\033[0;31m'
SC_RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$SC_GREEN" "$SC_RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$SC_RED" "$SC_RESET" "$1"; FAILED=1; }
# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else
    fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi
}
# assert_contains <label> <text> <needle>
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"; printf '       wanted: %q\n' "$3"; fi
}
# assert_lacks <label> <text> <needle>: prints only the label when it fails, since the needle can be a secret.
assert_lacks() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1"; fi
}
# assert_ok <label> <command...>: passes when the command exits 0.
assert_ok() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

sc_need_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "This test needs Docker." >&2
    exit 2
  fi
}

# sc_parse_image_option NAME=REF: records an image that is already built. Status 1 on anything else.
sc_parse_image_option() {
  [[ "${1:-}" == ?*=?* ]] || return 1
  case "${1%%=*}" in
    suitecrm|suitecrm-mariadb|suitecrm-old|suitecrm-mariadb-old) SC_IMAGE[${1%%=*}]="${1#*=}" ;;
    *) return 1 ;;
  esac
}

# sc_workdir: a private temporary folder, made once and removed by sc_cleanup.
sc_workdir() {
  if [ -z "$SC_WORK" ]; then
    SC_WORK="$(mktemp -d)"
    chmod 700 "$SC_WORK"
  fi
}

# sc_old_context DIR: writes the 8.9.1 image's build context into DIR, from commit SC_OLD_REF.
sc_old_context() {
  local dir="$1" file
  mkdir -p "$dir/installer" || return 1
  for file in Dockerfile installer/entrypoint.sh installer/install.sh; do
    git -C "$SC_REPO" show "$SC_OLD_REF:apps/suitecrm/image/$file" > "$dir/$file" || return 1
  done
  grep -q '^ENV SUITECRM_VERSION=8.9.1$' "$dir/Dockerfile"
}

# sc_image NAME: 0 when SC_IMAGE[NAME] is on this machine afterwards. It builds or pulls what --image didn't give.
sc_image() {
  local name="$1" ref log context
  ref="${SC_IMAGE[$name]:-}"
  if [ -n "$ref" ]; then
    docker image inspect "$ref" >/dev/null 2>&1 && return 0
    echo "       No image $ref on this machine."
    return 1
  fi
  case "$name" in
    suitecrm) context="$SC_REPO/apps/suitecrm/image" ;;
    suitecrm-mariadb) context="$SC_REPO/apps/suitecrm/image/mariadb" ;;
    suitecrm-old)
      sc_workdir
      context="$SC_WORK/old-context"
      if ! sc_old_context "$context"; then
        echo "       Commit $SC_OLD_REF has no SuiteCRM 8.9.1 image to build (SUITECRM_OLD_REF names another)."
        return 1
      fi
      ;;
    suitecrm-mariadb-old)
      if docker image inspect mariadb:12.1 >/dev/null 2>&1 || docker pull -q mariadb:12.1 >/dev/null 2>&1; then
        SC_IMAGE[$name]=mariadb:12.1
        return 0
      fi
      if docker pull -q mirror.gcr.io/library/mariadb:12.1 >/dev/null 2>&1; then
        SC_IMAGE[$name]=mirror.gcr.io/library/mariadb:12.1
        return 0
      fi
      echo "       mariadb:12.1 could not be pulled."
      return 1
      ;;
    *) return 1 ;;
  esac
  ref="clouve-test/$name:sc-test"
  if log="$(docker build -t "$ref" "$context" 2>&1)"; then
    SC_BUILT+=("$ref")
    SC_IMAGE[$name]="$ref"
    return 0
  fi
  printf '%s\n' "$log" | tail -n 20 | sed 's/^/       /'
  return 1
}

# sc_save_log CONTAINER: with SUITECRM_TEST_LOG_DIR set, writes the container's log there before the test removes
# the container, for a look afterwards. The logs hold the made-up passwords of the run only if a check failed.
sc_save_log() {
  [ -n "${SUITECRM_TEST_LOG_DIR:-}" ] || return 0
  mkdir -p "$SUITECRM_TEST_LOG_DIR" && docker logs "$1" > "$SUITECRM_TEST_LOG_DIR/$1.$(date +%H%M%S).log" 2>&1
}

# sc_remove_resources: the containers, volumes and networks whose names start with SC_PREFIX, and nothing else.
sc_remove_resources() {
  local name
  while IFS= read -r name; do
    case "$name" in "$SC_PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$SC_PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls -q 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$SC_PREFIX"*) docker network rm "$name" >/dev/null 2>&1 ;; esac
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null)
}

# sc_cleanup: for the EXIT trap. SC_KEEP=true leaves the containers, volumes and networks for a look.
sc_cleanup() {
  local image
  if [ "${SC_KEEP:-false}" = true ]; then
    echo "Kept: everything named $SC_PREFIX* (docker ps -a, docker volume ls, docker network ls)"
  else
    sc_remove_resources
  fi
  for image in "${SC_BUILT[@]}"; do docker rmi -f "$image" >/dev/null 2>&1; done
  [ -n "$SC_WORK" ] && rm -rf "$SC_WORK"
}

# sc_new_disk VOLUME: a volume in the shape a cluster gives a new install: root's top folder, mode 755, lost+found
# (root's, 700) in it and nothing else. Docker then copies nothing from the image into it.
sc_new_disk() {
  docker volume create "$1" >/dev/null || return 1
  docker run --rm --network none -v "$1:/v" "$SC_SHAPER" \
    sh -c '[ -z "$(ls -A /v)" ] && chown 0:0 /v && chmod 755 /v && mkdir -m 700 /v/lost+found' >/dev/null
}

# sc_copy_volume FROM TO: TO becomes a copy of FROM, owners and modes kept. Both containers of FROM are stopped.
sc_copy_volume() {
  docker volume create "$2" >/dev/null || return 1
  docker run --rm --network none -v "$1:/from:ro" -v "$2:/to" "$SC_SHAPER" \
    sh -c 'cp -a /from/. /to/ && chown "$(stat -c %u:%g /from)" /to && chmod "$(stat -c %a /from)" /to' >/dev/null
}

# sc_wait_for SECONDS COMMAND...: 0 once the command exits 0, 1 after SECONDS.
sc_wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# sc_running CONTAINER: 0 while the container runs.
sc_running() { [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# sc_log_has CONTAINER TEXT: 0 when the container's log holds TEXT.
sc_log_has() { docker logs "$1" 2>&1 | grep -qF -- "$2"; }

# sc_wait_log CONTAINER TEXT SECONDS: 0 once the log holds TEXT, 2 when the container stopped first, 1 after SECONDS.
sc_wait_log() {
  local deadline=$((SECONDS + $3))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if sc_log_has "$1" "$2"; then return 0; fi
    if ! sc_running "$1"; then sc_log_has "$1" "$2" && return 0; return 2; fi
    sleep 1
  done
  return 1
}

# sc_http CONTAINER PATH [CURL OPTIONS...]: the status code of a request to the container's own port 80.
sc_http() {
  local container="$1" path="$2"
  shift 2
  docker exec "$container" curl -s -o /dev/null -w '%{http_code}' "$@" "http://127.0.0.1$path" 2>/dev/null
}

# sc_pid1 CONTAINER: the command name of PID 1.
sc_pid1() { docker exec "$1" cat /proc/1/comm 2>/dev/null; }

# sc_apache_serves CONTAINER: 0 once Apache is PID 1 and /session-status says SuiteCRM is installed.
sc_apache_serves() {
  [ "$(sc_pid1 "$1")" = apache2 ] &&
    docker exec "$1" curl -s http://127.0.0.1/session-status 2>/dev/null | grep -q '"installed":true'
}

# sc_sql DB_CONTAINER DATABASE QUERY: rows of a query run as root in the database container, tab-separated.
# The root password comes from the container's own environment, so it is on no command line here.
sc_sql() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec -e "T_DB=$2" -e "T_SQL=$3" "$1" sh -c \
    'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb -uroot -N -B "$T_DB" -e "$T_SQL"' 2>/dev/null
}

# sc_peak_mb CONTAINER: the most memory the container's cgroup has held, in MB (cgroup v2), or nothing.
sc_peak_mb() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec "$1" sh -c 'v=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null) && echo $((v / 1048576))' 2>/dev/null
}

# sc_watch_cmdlines CONTAINER FILE SECONDS: writes every command line seen in the container to FILE (inside the
# container, root's, mode 600), about ten times a second, for SECONDS or until sc_watch_stop. It returns at once.
sc_watch_cmdlines() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -d -e "T_FILE=$2" -e "T_FOR=$3" "$1" bash -c '
    umask 077; : > "$T_FILE"; rm -f "$T_FILE.stop"; end=$((SECONDS + T_FOR))
    while [ "$SECONDS" -lt "$end" ] && [ ! -e "$T_FILE.stop" ]; do
      for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null; echo; done >> "$T_FILE"
      sleep 0.1
    done
    : > "$T_FILE.done"'
}

# sc_watch_stop CONTAINER FILE: ends the watch, so that the test's own commands are not in FILE, and waits for
# its last pass.
sc_watch_stop() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec -e "T_FILE=$2" "$1" sh -c \
    ': > "$T_FILE.stop"; i=0; while [ ! -e "$T_FILE.done" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done' 2>/dev/null
}

# sc_count_secrets_in CONTAINER FILE SECRET...: how many of the secrets show in FILE inside the container. The
# secrets go through the environment, and the answer is a number, so none is printed.
sc_count_secrets_in() {
  local container="$1" file="$2" n=0 secret
  shift 2
  for secret in "$@"; do
    # shellcheck disable=SC2016  # the script is for the sh inside the container
    if docker exec -e "T_SECRET=$secret" -e "T_FILE=$file" "$container" sh -c 'grep -qF -- "$T_SECRET" "$T_FILE"'; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# sc_count_secrets_in_log CONTAINER SECRET...: how many of the secrets show in the container's log.
sc_count_secrets_in_log() {
  local container="$1" n=0 secret log
  shift
  log="$(docker logs "$container" 2>&1)"
  for secret in "$@"; do
    if grep -qF -- "$secret" <<< "$log"; then n=$((n + 1)); fi
  done
  echo "$n"
}
