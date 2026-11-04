#!/bin/bash

# ============================================================================
# Odoo image: Odoo runs as the odoo user, and no password is on a command line
# ============================================================================
# Odoo runs as the image's odoo user, never as root. It reads the database
# password from /etc/odoo/odoo.conf only, a file of odoo's that no other user
# can read. No password goes on a command line, where any process in the
# container can read it. A master password the image makes up itself is
# never printed.
#
# The test builds both Odoo images (apps/odoo/image and image/postgres) and a
# small SSH client image (alpine with sshpass). It starts them with no
# network: the database with --network none, Odoo and the client in the
# database container's network namespace (--network container:), so all of
# them reach each other on 127.0.0.1 and nothing else. The database gets no
# CLOUVE_OPS_PASSWORD, so only Odoo's sshd listens on port 22. Every volume
# starts as a new cluster disk does: a top folder of root's with lost+found in
# it (lib/new-disk-volumes.sh). The passwords are throwaway values made for
# this run. The test looks for them inside the container and never prints
# them.
#
# 1. First start, with no ODOO_MASTER_PASSWORD (the image makes one up):
#    - no process in the container has a password on its command line: the
#      test looks about five times a second through the whole start, the
#      first install included, and once more when Odoo answers;
#    - the Odoo server is PID 1's child (tini, whose command line still holds
#      "odoo"), runs as odoo (user, group, no root group, no capabilities),
#      can't gain privileges (no_new_privs) and has no password in its
#      environment (read as odoo, since root in a container can't read it);
#    - the container's log holds no password, the made-up master password
#      included, and Odoo never logged that it runs as root;
#    - odoo.conf is odoo's, mode 600 or tighter, and holds the database
#      password;
#    - the new disks' top folders went to odoo, nothing under /var/lib/odoo
#      is root's (lost+found aside), a sign-in as the admin works, with Odoo
#      writing its session as odoo, and the admin downloads a PDF report
#      (the server runs wkhtmltopdf).
# 2. The SSH check the release runbook makes, from the client:
#    sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@<host> true
#    (the password in SSHPASS). Then the AI Assistant's restart, over SSH:
#    grep -q odoo /proc/1/cmdline && sudo kill -HUP 1. Odoo starts again in
#    the same process and answers, still as odoo, still with no password on
#    a command line, and the SSH check passes again with the host key the
#    client saved.
# 3. Odoo commands that clouve-ops runs with sudo, as the AI Assistant does:
#    odoo shell (it reports its user and no_new_privs, and saves an
#    attachment), odoo --stop-after-init, and a backup the way the skill's
#    backup.sh takes one: root's mkdir -p of /var/lib/odoo/backups (the
#    entrypoint has made that folder already), then odoo db dump into it.
#    Each runs as odoo, an error keeps Odoo's exit status, and nothing under
#    /var/lib/odoo is root's afterwards.
# 4. An upgraded disk: the test stops Odoo and gives root, as an older image
#    that ran Odoo as root left them, the sessions folder, the filestore, the
#    backups (mode 755), Odoo's addons folder and the install marker. A new
#    container starts on the same volumes, now with ODOO_MASTER_PASSWORD set.
#    Those files go to odoo, the backups folder is mode 700 again, a sign-in
#    and an attachment work again, and the given master password is in
#    odoo.conf but on no command line and not in the log.
# 5. What code running as odoo could leave in its own folder for root to
#    trip on, one new container each: the install marker as a link to a file
#    that doesn't exist in /etc, and backups as a file, as a link to nothing
#    and as a link to a folder of root's. Odoo must start each time, root
#    must not follow a link (no target appears, the folder it points to
#    keeps its mode), backups must end up a folder of odoo's, mode 700, and
#    the files of odoo's outside the volumes must be the ones the first
#    start had.
# 6. The database container, started on its own (its own network namespace,
#    a second client beside it) with CLOUVE_OPS_PASSWORD set, as the platform
#    sets it in every container. Odoo's database role is the superuser, so
#    code running as odoo could read the database server's environment
#    (COPY ... FROM PROGRAM 'env' runs a program as postgres) and, with
#    CLOUVE_OPS_PASSWORD, log in to the Odoo container's sshd and sudo to
#    root. So no PostgreSQL process may hold CLOUVE_OPS_PASSWORD (looked up by
#    name in /proc/<pid>/environ, read as postgres: root in a container has no
#    CAP_SYS_PTRACE, so it can't read another user's environment; and through
#    COPY ... FROM PROGRAM), while tini (PID 1) keeps it for the AI Assistant's
#    settings read. The SSH check
#    (sshpass -e ssh -o StrictHostKeyChecking=accept-new
#    -o UserKnownHostsFile=/dev/null clouve-ops@<host> true) passes, and
#    PostgreSQL restarts and stops cleanly, with the same checks after the
#    restart.
#
# --image odoo=REF and --image odoo-postgres=REF use images that are already
# built instead, and the test leaves them in place: for example an older
# build, to see what the test finds there.
#
# Needs Docker. The builds pull odoo:19.0, postgres:18 and alpine, and run
# apt-get and apk. Every container and volume the test makes is named
# odoo-nonroot-t-*, and they are removed when it exits, with the images it
# built.
#
# Usage: bash tests/odoo-non-root.test.sh [--image odoo=REF] [--image odoo-postgres=REF]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="$REPO_DIR/apps/odoo/image"
PREFIX="odoo-nonroot-t-"   # every container and volume this test makes begins with this
DB="${PREFIX}db"
APP="${PREFIX}app"
CLIENT="${PREFIX}client"
DB2="${PREFIX}db2"          # part 6: the database container on its own
CLIENT2="${PREFIX}client2"
VOL_PG2="${PREFIX}pgdata2"
VOL_PG="${PREFIX}pgdata"
VOL_DATA="${PREFIX}data"
VOL_ADDONS="${PREFIX}addons"
CLIENT_BASE="mirror.gcr.io/library/alpine:3.22"
READY_SECONDS=600          # the first start installs Odoo's base module
RESTART_SECONDS=180
# Lines Odoo logs each time its server starts: the version, and the HTTP service.
STARTED='odoo: Odoo version |HTTP service \(werkzeug\) running on'

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

ODOO_IMAGE=""
PG_IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      case "${2:-}" in
        odoo=?*) ODOO_IMAGE="${2#odoo=}" ;;
        odoo-postgres=?*) PG_IMAGE="${2#odoo-postgres=}" ;;
        *) usage ;;
      esac
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
# check <label> <status>: passes when the status is 0.
check() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi; }
# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$3" == "$2" ]]; then
    pass "$1"
  else
    fail "$1"
    printf '       expected: %q\n       actual:   %q\n' "$2" "$3"
  fi
}
# detail <text>: indented lines under the last check.
detail() { [ -n "$1" ] && printf '%s\n' "$1" | head -n 12 | sed 's/^/       /'; return 0; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi
# shellcheck source=lib/new-disk-volumes.sh
. "$REPO_DIR/lib/new-disk-volumes.sh"

BUILT=()
# Removes this test's containers (Odoo and the client first: they use the database's network) and volumes.
remove_test_containers() {
  local name
  docker rm -f -v "$APP" "$CLIENT" "$CLIENT2" >/dev/null 2>&1
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls -q 2>/dev/null)
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

finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    printf '%sOdoo non-root checks passed.%s\n' "$GREEN" "$RESET"
    exit 0
  fi
  printf '%sOdoo non-root checks failed.%s\n' "$RED" "$RESET"
  exit 1
}

# The builder of the current Docker context (the docker driver), as build.sh picks it for a local build: its images
# land in the local image store, and it finds odoo:19.0 there.
BUILDER="$(docker context show 2>/dev/null || echo default)"
docker buildx inspect "$BUILDER" >/dev/null 2>&1 || BUILDER=default

# build <tag> <context> [-]: builds an image the test removes again at the end. With "-", the Dockerfile comes on stdin.
build() {
  local log
  if log="$(docker buildx build --builder "$BUILDER" --load --provenance=false -t "$1" "$2" 2>&1)"; then
    BUILT+=("$1")
    pass "image builds ($1)"
    return 0
  fi
  fail "image builds ($1)"
  printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
  return 1
}

# secret <word>: a throwaway password for this run, made to be found: the word and 24 random hex digits.
secret() { printf 'nonroot-%s-%s' "$1" "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"; }

remove_test_containers    # leftovers of a run that was killed

echo "Odoo image: Odoo as the odoo user, no password on a command line"
if [ -z "$PG_IMAGE" ]; then
  PG_IMAGE="clouve-test/odoo-postgres:nonroot-test"
  build "$PG_IMAGE" "$IMAGE_DIR/postgres" || finish
fi
if [ -z "$ODOO_IMAGE" ]; then
  ODOO_IMAGE="clouve-test/odoo:nonroot-test"
  build "$ODOO_IMAGE" "$IMAGE_DIR" || finish
fi
CLIENT_IMAGE="clouve-test/sshpass-client:nonroot-test"
CLIENT_CONTEXT="$(mktemp -d)"
printf 'FROM %s\nRUN apk add --no-cache openssh-client sshpass\n' "$CLIENT_BASE" > "$CLIENT_CONTEXT/Dockerfile"
build "$CLIENT_IMAGE" "$CLIENT_CONTEXT"
client_built=$?
rm -rf "$CLIENT_CONTEXT"
[ "$client_built" -eq 0 ] || finish
for image in "$PG_IMAGE" "$ODOO_IMAGE"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "No image $image on this machine." >&2
    exit 2
  fi
done

DB_PW="$(secret db)"
ADMIN_PW="$(secret admin)"
OPS_PW="$(secret ops)"
MASTER_PW=""              # the first start runs without one; the upgraded-disk start gets this one
GIVEN_MASTER_PW="$(secret master)"
ADMIN_LOGIN="admin@example.com"

# --- volumes: new cluster disks ------------------------------------------------
if ! nd_shaper_ready; then
  fail "the image that shapes new volumes is here ($(nd_shaper_image))"
  finish
fi
SHAPER="$(nd_shaper_image)"
for volume in "$VOL_PG" "$VOL_DATA" "$VOL_ADDONS" "$VOL_PG2"; do
  if ! nd_make_new_disk "$volume" "${PREFIX%-}" "$volume"; then
    fail "volume $volume starts as a new disk"
    finish
  fi
done

# --- what the test runs inside the Odoo container ---------------------------
# Bash for the Odoo container, run as root by docker exec. The passwords come in T_DB, T_ADMIN, T_OPS and T_MASTER,
# through docker exec's environment (docker exec -e NAME, the value from the docker command's own environment), so
# they are on no command line here or in the container. Nothing it prints holds one.
SCAN_LIB="$(cat <<'EOF'
NAMES=(); VALUES=()
add_secret() { if [ -n "$2" ]; then NAMES+=("$1"); VALUES+=("$2"); fi; }
# conf_value KEY: sets VALUE to KEY's value in odoo.conf ("KEY = VALUE"), empty when it has none.
conf_value() {
  local line key
  VALUE=""
  [ -r /etc/odoo/odoo.conf ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; key="${key%"${key##*[![:space:]]}"}"
    if [ "$key" = "$1" ] && [ "$line" != "$key" ]; then
      VALUE="${line#*=}"
      VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"; VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
    fi
  done < /etc/odoo/odoo.conf
}
# load_secrets: the test's passwords, and the master password odoo.conf holds (the image makes one up when
# ODOO_MASTER_PASSWORD isn't set).
load_secrets() {
  NAMES=(); VALUES=()
  add_secret db "${T_DB:-}"; add_secret admin "${T_ADMIN:-}"; add_secret ops "${T_OPS:-}"
  add_secret master "${T_MASTER:-}"
  conf_value admin_passwd
  if [ "${#VALUE}" -ge 12 ] && [ "$VALUE" != "${T_MASTER:-}" ]; then add_secret master "$VALUE"; fi
}
# found_in FILE: sets FOUND to the names of the passwords in FILE (a NUL-separated /proc cmdline or environ).
found_in() {
  local -a parts
  local i joined
  FOUND=""
  { mapfile -d '' -t parts < "$1"; } 2>/dev/null || return 0
  [ "${#parts[@]}" -gt 0 ] || return 0
  joined="${parts[*]}"
  for i in "${!VALUES[@]}"; do
    if [[ "$joined" == *"${VALUES[$i]}"* ]]; then FOUND="${FOUND:+$FOUND,}${NAMES[$i]}"; fi
  done
}
# env_of DIR: FOUND as found_in, for a process's environment, and ENV_STATE: ok, unreadable (root in a container
# has no CAP_SYS_PTRACE, so only the process's own user can read it) or empty (no NAME=value in it: the process has
# written its title over that memory, as PostgreSQL's server processes other than the first do).
env_of() {
  local -a parts
  local part
  FOUND=""; ENV_STATE=unreadable
  { mapfile -d '' -t parts < "$1/environ"; } 2>/dev/null || return 0
  ENV_STATE=empty
  for part in "${parts[@]}"; do
    case "$part" in [A-Za-z_]*=*) ENV_STATE=ok; break ;; esac
  done
  found_in "$1/environ"
}
# heads DIR: A0 and A1, a process's first two arguments. Status 1 for a process with none (a kernel thread, or gone).
heads() {
  local -a parts
  A0=""; A1=""
  { mapfile -d '' -t -n 2 parts < "$1/cmdline"; } 2>/dev/null || return 1
  A0="${parts[0]:-}"; A1="${parts[1]:-}"
  [ -n "$A0" ]
}
# status DIR: a process's parent, users (real, effective, saved, file system), groups, capabilities and no_new_privs.
status() {
  local key rest
  PPID_=""; UIDS=""; GIDS=""; GROUPS_=""; CAPPRM=""; CAPEFF=""; NNP=""
  { while read -r key rest; do
      case "$key" in
        PPid:) PPID_="$rest" ;;
        Uid:) UIDS="$(printf '%s' "$rest" | tr -s ' \t' ',')" ;;
        Gid:) GIDS="$(printf '%s' "$rest" | tr -s ' \t' ',')" ;;
        Groups:) GROUPS_="$(printf '%s' "$rest" | tr -s ' \t' ',')" ;;
        CapPrm:) CAPPRM="$rest" ;;
        CapEff:) CAPEFF="$rest" ;;
        NoNewPrivs:) NNP="$rest" ;;
      esac
    done < "$1/status"; } 2>/dev/null || return 1
  [ -n "$UIDS" ]
}
# scan_cmdlines: one line for each process with a password on its command line.
scan_cmdlines() {
  local d
  for d in /proc/[0-9]*; do
    found_in "$d/cmdline"
    [ -n "$FOUND" ] || continue
    heads "$d"; status "$d"
    printf 'cmdline pid=%s uid=%s found=%s program=%s\n' "${d#/proc/}" "${UIDS:-?}" "$FOUND" "${A0##*/}"
  done
}
# scan_odoo: one line for each Odoo process (python running odoo), with its users, groups, capabilities and
# no_new_privs (all from /proc/<pid>/status, which any user can read).
scan_odoo() {
  local d
  for d in /proc/[0-9]*; do
    heads "$d" || continue
    case "${A0##*/}" in python*) ;; *) continue ;; esac
    case "${A1##*/}" in odoo|odoo-bin) ;; *) continue ;; esac
    status "$d" || continue
    printf 'odoo pid=%s ppid=%s uid=%s gid=%s groups=%s capprm=%s capeff=%s nnp=%s\n' "${d#/proc/}" \
      "$PPID_" "$UIDS" "$GIDS" "${GROUPS_:--}" "$CAPPRM" "$CAPEFF" "${NNP:--}"
  done
}
# conf_is KEY VAR: status 0 when odoo.conf's KEY holds the value of the variable VAR.
conf_is() {
  conf_value "$1"
  [ -n "$VALUE" ] && [ "$VALUE" = "${!2:-}" ]
}
EOF
)"

# The sampler: scan_cmdlines about five times a second until /tmp/t-stop appears. It appends what it finds to
# /tmp/t-hits and counts its rounds in /tmp/t-samples.
SAMPLER="$SCAN_LIB"$'\n'"$(cat <<'EOF'
rm -f /tmp/t-stop /tmp/t-hits /tmp/t-samples
: > /tmp/t-hits
n=0
while [ ! -e /tmp/t-stop ]; do
  load_secrets
  scan_cmdlines >> /tmp/t-hits
  n=$((n + 1))
  echo "$n" > /tmp/t-samples
  sleep 0.2
done
EOF
)"

# in_app <bash>: runs bash in the Odoo container with SCAN_LIB loaded and the passwords in T_*.
in_app() {
  T_DB="$DB_PW" T_ADMIN="$ADMIN_PW" T_OPS="$OPS_PW" T_MASTER="$MASTER_PW" \
    docker exec -e T_DB -e T_ADMIN -e T_OPS -e T_MASTER "$APP" bash -c "$SCAN_LIB"$'\n'"$1"
}

# in_app_as <user> <bash>: in_app, as <user> (a name or a uid).
in_app_as() {
  T_DB="$DB_PW" T_ADMIN="$ADMIN_PW" T_OPS="$OPS_PW" T_MASTER="$MASTER_PW" \
    docker exec -u "$1" -e T_DB -e T_ADMIN -e T_OPS -e T_MASTER "$APP" bash -c "$SCAN_LIB"$'\n'"$2"
}

start_sampler() {
  T_DB="$DB_PW" T_ADMIN="$ADMIN_PW" T_OPS="$OPS_PW" T_MASTER="$MASTER_PW" \
    docker exec -d -e T_DB -e T_ADMIN -e T_OPS -e T_MASTER "$APP" bash -c "$SAMPLER"
}

# stop_sampler: stops it and prints what it found, then "samples <rounds>" as the last line.
stop_sampler() {
  docker exec "$APP" touch /tmp/t-stop >/dev/null 2>&1
  sleep 1
  docker exec "$APP" sh -c 'sort -u /tmp/t-hits 2>/dev/null; echo "samples $(cat /tmp/t-samples 2>/dev/null || echo 0)"'
}

# redacted: stdin with the passwords replaced, for a log shown on failure.
redacted() {
  local text value
  text="$(cat)"
  for value in "$DB_PW" "$ADMIN_PW" "$OPS_PW" "$GIVEN_MASTER_PW" "${GENERATED_MASTER:-}"; do
    [ -n "$value" ] && text="${text//"$value"/<redacted>}"
  done
  printf '%s\n' "$text"
}

# show_logs <container>: the last lines of the container's log, indented, with the passwords taken out.
show_logs() { docker logs --tail 30 "$1" 2>&1 | redacted | sed 's/^/       | /'; }

# healthy: Odoo answers on /web/health.
healthy() {
  docker exec "$APP" curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8069/web/health >/dev/null 2>&1
}

# running: the Odoo container is still running.
running() { [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ]; }

# wait_healthy <seconds>: status 0 once Odoo answers.
wait_healthy() {
  local deadline=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$deadline" ] && running; do
    if healthy; then return 0; fi
    sleep 3
  done
  return 1
}

# start_app [ODOO_MASTER_PASSWORD]: starts the Odoo container on the test's volumes, with the database's network.
start_app() {
  local master=()
  [ -n "${1:-}" ] && master=(-e ODOO_MASTER_PASSWORD)
  ODOO_DB_PASSWORD="$DB_PW" ODOO_ADMIN_PASSWORD="$ADMIN_PW" CLOUVE_OPS_PASSWORD="$OPS_PW" \
  ODOO_MASTER_PASSWORD="${1:-}" docker run -d --pull=never --name "$APP" --network "container:$DB" \
    -v "$VOL_DATA:/var/lib/odoo" -v "$VOL_ADDONS:/mnt/extra-addons" \
    -e ODOO_DB_HOST=127.0.0.1 -e ODOO_DB_USER=odoo -e ODOO_DB_PASSWORD -e ODOO_DB_NAME=odoo \
    -e "ODOO_ADMIN_EMAIL=$ADMIN_LOGIN" -e ODOO_ADMIN_PASSWORD -e ODOO_URL=http://127.0.0.1:8069 \
    -e CLOUVE_OPS_PASSWORD ${master[@]+"${master[@]}"} "$ODOO_IMAGE" >/dev/null
}

# ssh_ops <command>: runs <command> as clouve-ops over SSH from the client, the way the AI Assistant does: sshpass -e
# with the password in SSHPASS. stdin goes to the command. Prints its output; its status is the command's.
ssh_ops() {
  SSHPASS="$OPS_PW" docker exec -i -e SSHPASS "$CLIENT" timeout 300 \
    sshpass -e ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR clouve-ops@127.0.0.1 "$1"
}

# expect_runbook_ssh <label>: the release runbook's SSH check, word for word (the host is 127.0.0.1 here). The client
# keeps the host key it saved the first time, so a changed key fails. What ssh prints shows only on a failure.
expect_runbook_ssh() {
  local out rc
  out="$(SSHPASS="$OPS_PW" docker exec -e SSHPASS "$CLIENT" timeout 60 \
    sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@127.0.0.1 true </dev/null 2>&1)"
  rc=$?
  check "$1" "$rc"
  [ "$rc" -eq 0 ] || detail "$(printf 'exit %s\n%s\n' "$rc" "$out" | redacted)"
}

# started_count: how many start lines Odoo has logged since the container started.
started_count() { docker logs "$APP" 2>&1 | grep -cE "$STARTED"; }

# expect_no_cmdline_password <label> [<sampler output>]: no command line holds a password, now and in the samples.
expect_no_cmdline_password() {
  local now samples hits
  now="$(in_app 'load_secrets; scan_cmdlines')"
  hits="$now"
  if [ -n "${2:-}" ]; then
    samples="$(printf '%s\n' "$2" | sed -n 's/^samples //p')"
    hits="$(printf '%s\n%s\n' "$now" "$(printf '%s\n' "$2" | grep '^cmdline ')" | grep . | sort -u)"
  fi
  if [ -z "$hits" ]; then
    pass "$1${samples:+ (and in $samples samples before)}"
  else
    fail "$1${samples:+ (and in $samples samples before)}"
    detail "$hits"
  fi
}

# expect_server_odoo <label suffix>: the Odoo server is PID 1's child, runs as odoo and has no password in its
# environment, and no Odoo process runs as root. Sets SERVER_PID.
expect_server_odoo() {
  local lines server count root re
  lines="$(in_app 'load_secrets; scan_odoo')"
  server="$(printf '%s\n' "$lines" | grep ' ppid=1 ')"
  count="$(printf '%s\n' "$server" | grep -c .)"
  SERVER_PID=""
  if [ "$count" -ne 1 ]; then
    fail "the Odoo server is PID 1's child ($1)"
    detail "${lines:-no Odoo process}"
    return
  fi
  re='pid=([0-9]+) ppid=1 uid=([0-9,]+) gid=([0-9,]+) groups=([^ ]+) capprm=([0-9a-f]+) capeff=([0-9a-f]+) nnp=([^ ]+)$'
  if ! [[ "$server" =~ $re ]]; then
    fail "the Odoo server's status can be read ($1)"
    detail "$server"
    return
  fi
  SERVER_PID="${BASH_REMATCH[1]}"
  pass "the Odoo server is PID 1's child, pid $SERVER_PID ($1)"
  assert_eq "it runs as odoo: user ($1)" "$ODOO_UID,$ODOO_UID,$ODOO_UID,$ODOO_UID" "${BASH_REMATCH[2]}"
  assert_eq "it runs as odoo: group ($1)" "$ODOO_GID,$ODOO_GID,$ODOO_GID,$ODOO_GID" "${BASH_REMATCH[3]}"
  if [[ ",${BASH_REMATCH[4]}," == *",0,"* ]]; then
    fail "it has no root group ($1)"
    detail "groups: ${BASH_REMATCH[4]}"
  else
    pass "it has no root group ($1)"
  fi
  assert_eq "it has no capabilities ($1)" "0000000000000000 0000000000000000" "${BASH_REMATCH[5]} ${BASH_REMATCH[6]}"
  assert_eq "it can't gain privileges: no_new_privs is set ($1)" 1 "${BASH_REMATCH[7]}"
  # Its environment, read as its own user: root in a container has no CAP_SYS_PTRACE, so it can read the
  # environment of its own processes only. "ok" says the read worked and found NAME=value entries.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  assert_eq "its environment holds no password (read as its own user, $1)" "ok -" \
    "$(in_app_as "${BASH_REMATCH[2]%%,*}" "load_secrets; env_of /proc/$SERVER_PID; printf '%s %s' \"\$ENV_STATE\" \"\${FOUND:--}\"")"
  root="$(printf '%s\n' "$lines" | grep -E ' uid=([0-9]+,)*0(,|( ))')"
  if [ -z "$root" ]; then
    pass "no Odoo process runs as root ($1)"
  else
    fail "no Odoo process runs as root ($1)"
    detail "$root"
  fi
}

# expect_nothing_root <label>: no file or folder under /var/lib/odoo is root's, lost+found aside.
expect_nothing_root() {
  local found
  found="$(docker exec "$APP" find /var/lib/odoo -path /var/lib/odoo/lost+found -prune -o -user root -print 2>&1)"
  if [ -z "$found" ]; then
    pass "$1"
  else
    fail "$1"
    detail "$(printf '%s\n' "$found" | head -n 10; echo "($(printf '%s\n' "$found" | grep -c .) in all)")"
  fi
}

# expect_log_clean <label>: the container's log holds none of the passwords, and Odoo never logged that it runs as root.
expect_log_clean() {
  local logs value names=""
  logs="$(docker logs "$APP" 2>&1)"
  for value in DB_PW ADMIN_PW OPS_PW GIVEN_MASTER_PW GENERATED_MASTER; do
    [ -n "${!value:-}" ] || continue
    if [[ "$logs" == *"${!value}"* ]]; then names="${names:+$names, }$value"; fi
  done
  if [ -z "$names" ]; then pass "$1"; else fail "$1"; detail "found: $names"; fi
  if [[ "$logs" == *"Running as user 'root' is a security risk"* ]]; then
    fail "Odoo never logged that it runs as root"
  else
    pass "Odoo never logged that it runs as root"
  fi
}

# sign_in: signs in as the admin over JSON-RPC from inside the container, the password on curl's stdin. Prints
# Odoo's answer.
sign_in() {
  printf '{"jsonrpc":"2.0","method":"call","params":{"db":"odoo","login":"%s","password":"%s"}}' \
    "$ADMIN_LOGIN" "$ADMIN_PW" |
    docker exec -i "$APP" curl -sS --max-time 60 -c /tmp/t-cookies -H 'Content-Type: application/json' --data-binary @- \
      http://127.0.0.1:8069/web/session/authenticate 2>&1
}

# odoo_sessions: how many session files of odoo's there are.
odoo_sessions() { docker exec "$APP" find /var/lib/odoo/sessions -type f -user odoo 2>/dev/null | grep -c .; }

# expect_sign_in <label>: the admin signs in, and Odoo writes a new session file as odoo.
expect_sign_in() {
  local answer before after
  before="$(odoo_sessions)"
  answer="$(sign_in)"
  if [[ "$answer" =~ \"uid\":\ ?[1-9] ]]; then
    pass "$1"
  else
    fail "$1"
    detail "$(printf '%s\n' "$answer" | redacted | cut -c1-300)"
  fi
  after="$(odoo_sessions)"
  if [ "$after" -gt "$before" ]; then
    pass "Odoo wrote the new session as odoo"
  else
    fail "Odoo wrote the new session as odoo"
    detail "$(docker exec "$APP" sh -c 'find /var/lib/odoo/sessions -exec stat -c "%U:%G %a %n" {} + 2>&1 | head')"
  fi
}

# The Python that `odoo shell` runs from stdin: who it runs as, and an attachment it saves in the filestore.
SHELL_SCRIPT="$(cat <<'PY'
import os
print("t-uid=%d" % os.getuid())
with open('/proc/self/status') as status:
    print("t-nnp=%s" % next((line.split()[1] for line in status if line.startswith('NoNewPrivs:')), '?'))
attachment = env['ir.attachment'].create({'name': 't-nonroot.txt', 'raw': os.urandom(64)})
env.cr.commit()
print("t-store=%s" % attachment.store_fname)
PY
)"

# expect_shell_run <label suffix>: sudo odoo shell, as clouve-ops runs it, runs as odoo and saves its attachment as odoo.
expect_shell_run() {
  local out rc uid store owner
  out="$(printf '%s\n' "$SHELL_SCRIPT" | ssh_ops 'sudo odoo shell -c /etc/odoo/odoo.conf -d odoo --no-http' 2>&1)"
  rc=$?
  check "sudo odoo shell exits 0 ($1)" "$rc"
  uid="$(printf '%s\n' "$out" | sed -n 's/^t-uid=//p' | tail -n 1)"
  assert_eq "sudo odoo shell runs as odoo ($1)" "$ODOO_UID" "$uid"
  assert_eq "sudo odoo shell can't gain privileges: no_new_privs ($1)" 1 \
    "$(printf '%s\n' "$out" | sed -n 's/^t-nnp=//p' | tail -n 1)"
  store="$(printf '%s\n' "$out" | sed -n 's/^t-store=//p' | tail -n 1)"
  if [ -z "$store" ]; then
    fail "the shell's attachment is in the filestore ($1)"
    detail "$(printf '%s\n' "$out" | redacted | tail -n 8)"
    return
  fi
  owner="$(docker exec "$APP" stat -c %U "/var/lib/odoo/filestore/odoo/$store" 2>&1)"
  assert_eq "the shell's attachment file is odoo's ($1)" odoo "$owner"
}

# expect_pdf_report <label>: the signed-in admin (sign_in's cookie) downloads a PDF report. The server renders it with
# wkhtmltopdf, which it runs as odoo.
expect_pdf_report() {
  local answer magic
  answer="$(docker exec "$APP" curl -sS --max-time 180 -b /tmp/t-cookies -o /tmp/t-report.pdf \
    -w '%{http_code} %{content_type}' http://127.0.0.1:8069/report/pdf/base.report_irmodeloverview/1 2>&1)"
  magic="$(docker exec "$APP" head -c 4 /tmp/t-report.pdf 2>/dev/null)"
  if [[ "$answer" == "200 application/pdf"* ]] && [ "$magic" = "%PDF" ]; then
    pass "$1"
  else
    fail "$1"
    detail "$(printf 'answer: %s, first bytes: %q' "$answer" "$magic")"
  fi
}

# odoo_files_outside: the files of odoo's on the container's own filesystem: not on a volume (find -xdev), and not
# in /proc, /sys, /dev, /run or the temporary folders. Root must never hand odoo another one.
odoo_files_outside() {
  docker exec "$APP" find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp \
    -o -path /var/tmp \) -prune -o -user odoo -print 2>/dev/null | sort
}

# expect_outside_unchanged <label>: the files of odoo's outside the volumes are the ones the first start had.
expect_outside_unchanged() {
  local now changed
  now="$(odoo_files_outside)"
  changed="$(comm -3 <(printf '%s\n' "$BASELINE_OUTSIDE") <(printf '%s\n' "$now"))"
  if [ -z "$changed" ]; then
    pass "$1 ($(printf '%s\n' "$now" | grep -c .) of odoo's, as at the first start)"
  else
    fail "$1"
    detail "$(printf 'first start only, then this start only (indented):\n%s' "$changed")"
  fi
}

# expect_not_there <path> <label>: nothing is at <path> in the Odoo container, not even a link.
expect_not_there() {
  if docker exec "$APP" sh -c '[ ! -e "$1" ] && [ ! -L "$1" ]' sh "$1"; then
    pass "$2"
  else
    fail "$2"
    detail "$(docker exec "$APP" stat -c '%F %U:%G %a %n' "$1" 2>&1)"
  fi
}

# expect_backups_folder <label>: /var/lib/odoo/backups is a real folder of odoo's that only odoo can read.
expect_backups_folder() {
  assert_eq "$1" "directory odoo 700" "$(docker exec "$APP" stat -c '%F %U %a' /var/lib/odoo/backups 2>&1)"
}

# restart_planted <what> <sh>: stops Odoo, runs <sh> as root in the shaper image on the data volume (at /v, with T_UID
# and T_GID set to odoo's: code running as odoo could have left what it makes there), and starts a new Odoo container
# on the same volumes. Status 0 when Odoo answers on /web/health.
restart_planted() {
  docker stop -t 30 "$APP" >/dev/null 2>&1
  docker rm -f "$APP" >/dev/null 2>&1
  if ! docker run --rm --network none -e "T_UID=$ODOO_UID" -e "T_GID=$ODOO_GID" -v "$VOL_DATA:/v" "$SHAPER" \
      sh -c "$2" >/dev/null 2>&1; then
    fail "the test leaves $1"
    return 1
  fi
  if ! start_app "$MASTER_PW"; then
    fail "a new Odoo container starts ($1)"
    return 1
  fi
  if wait_healthy "$READY_SECONDS"; then
    pass "Odoo starts and answers on /web/health ($1)"
    return 0
  fi
  fail "Odoo starts and answers on /web/health ($1)"
  show_logs "$APP"
  return 1
}

# --- 1. first start, on new disks ------------------------------------------------
echo
echo "First start on new disks (no ODOO_MASTER_PASSWORD)"
if ! POSTGRES_PASSWORD="$DB_PW" docker run -d --pull=never --name "$DB" --network none \
    -v "$VOL_PG:/var/lib/postgresql" -e POSTGRES_DB=postgres -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD \
    "$PG_IMAGE" >/dev/null; then
  fail "the database container starts"
  finish
fi
db_ready=false
for _ in $(seq 1 60); do
  if docker exec "$DB" pg_isready -q -h 127.0.0.1 -U odoo 2>/dev/null; then db_ready=true; break; fi
  sleep 2
done
if ! $db_ready; then
  fail "PostgreSQL answers on 127.0.0.1:5432"
  show_logs "$DB"
  finish
fi

if ! start_app ""; then
  fail "the Odoo container starts"
  finish
fi
start_sampler
if ! wait_healthy "$READY_SECONDS"; then
  fail "Odoo answers on /web/health within ${READY_SECONDS} s"
  show_logs "$APP"
  finish
fi
pass "Odoo answers on /web/health"
SAMPLES="$(stop_sampler)"

ODOO_UID="$(docker exec "$APP" id -u odoo)"
ODOO_GID="$(docker exec "$APP" id -g odoo)"
# The master password the image made up, kept in this script only, to look for it in the log.
# shellcheck disable=SC2016  # the script is for the bash inside the container
GENERATED_MASTER="$(in_app 'conf_value admin_passwd; printf "%s" "$VALUE"')"

assert_eq "PID 1 is tini" tini "$(docker exec "$APP" cat /proc/1/comm 2>/dev/null)"
docker exec "$APP" grep -q odoo /proc/1/cmdline
check "PID 1's command line holds \"odoo\" (the restart command's check)" $?
expect_no_cmdline_password "no command line in the container holds a password" "$SAMPLES"
expect_server_odoo "first start"
if [ "${#GENERATED_MASTER}" -ge 12 ]; then
  pass "odoo.conf holds the master password the image made up"
else
  fail "odoo.conf holds the master password the image made up"
fi
expect_log_clean "the container's log holds no password (the made-up master password included)"
mode="$(docker exec "$APP" stat -c '%U %a' /etc/odoo/odoo.conf 2>&1)"
if [[ "$mode" =~ ^odoo\ [0-7]?[0-7]00$ ]]; then
  pass "odoo.conf is odoo's, and no other user can read it ($mode)"
else
  fail "odoo.conf is odoo's, and no other user can read it"
  detail "owner and mode: $mode"
fi
in_app 'conf_is db_password T_DB'
check "odoo.conf holds the database password" $?
assert_eq "the new disk's top folders went to odoo (/var/lib/odoo, /mnt/extra-addons)" "odoo odoo" \
  "$(docker exec "$APP" stat -c %U /var/lib/odoo /mnt/extra-addons 2>&1 | tr '\n' ' ' | sed 's/ $//')"
expect_nothing_root "nothing under /var/lib/odoo is root's (lost+found aside)"
expect_sign_in "the admin signs in ($ADMIN_LOGIN)"
expect_pdf_report "the admin downloads a PDF report (the server runs wkhtmltopdf as odoo)"
BASELINE_OUTSIDE="$(odoo_files_outside)"

# --- 2. SSH, and the restart ------------------------------------------------------
echo
echo "SSH as clouve-ops, and the restart with SIGHUP"
if ! docker run -d --pull=never --name "$CLIENT" --network "container:$DB" "$CLIENT_IMAGE" sleep 3600 >/dev/null; then
  fail "the SSH client container starts"
  finish
fi
expect_runbook_ssh "the runbook's SSH check passes: sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@<host> true"
started_before_count="$(started_count)"
started_before="$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$APP")"
server_before="$SERVER_PID"
restart_out="$(ssh_ops 'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1' </dev/null 2>&1)"
restart_rc=$?
check "the restart command over SSH exits 0" "$restart_rc"
[ "$restart_rc" -eq 0 ] || detail "$restart_out"
back=false
deadline=$((SECONDS + RESTART_SECONDS))
while [ "$SECONDS" -lt "$deadline" ] && running; do
  if [ "$(started_count)" -gt "$started_before_count" ] && healthy; then back=true; break; fi
  sleep 2
done
if $back; then
  pass "Odoo starts again and answers on /web/health"
else
  fail "Odoo starts again and answers on /web/health within ${RESTART_SECONDS} s"
  show_logs "$APP"
fi
assert_eq "the container didn't restart" "$started_before" \
  "$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$APP")"
assert_eq "PID 1 is still tini" tini "$(docker exec "$APP" cat /proc/1/comm 2>/dev/null)"
expect_server_odoo "after the restart"
assert_eq "the same process restarted in place (Odoo re-executes itself)" "$server_before" "$SERVER_PID"
expect_no_cmdline_password "no command line holds a password after the restart"
expect_runbook_ssh "the runbook's SSH check passes again, with the host key the client saved"

# --- 3. Odoo commands that root starts --------------------------------------------
echo
echo "Odoo commands run with sudo, as the AI Assistant runs them"
expect_shell_run "first run"
ssh_ops 'sudo odoo -c /etc/odoo/odoo.conf -d odoo --stop-after-init --no-http' </dev/null >/dev/null 2>&1
check "sudo odoo -c /etc/odoo/odoo.conf -d odoo --stop-after-init exits 0" $?
ssh_ops "sudo bash -c 'mkdir -p /var/lib/odoo/backups && ODOO_RC=/etc/odoo/odoo.conf odoo db dump odoo /var/lib/odoo/backups/t-backup.zip </dev/null'" </dev/null >/dev/null 2>&1
check "a backup the way backup.sh takes one (root's mkdir -p, then odoo db dump into the backups folder the entrypoint made) exits 0" $?
assert_eq "the backup is odoo's" odoo "$(docker exec "$APP" stat -c %U /var/lib/odoo/backups/t-backup.zip 2>&1)"
docker exec "$APP" python3 -c 'import sys, zipfile; sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)' \
  /var/lib/odoo/backups/t-backup.zip 2>/dev/null
check "the backup is a ZIP" $?
ssh_ops 'sudo odoo --t-no-such-option' </dev/null >/dev/null 2>&1
assert_eq "an odoo command that fails keeps Odoo's exit status (2 for an unknown option)" 2 "$?"
expect_nothing_root "nothing under /var/lib/odoo is root's after these commands (lost+found aside)"

# --- 4. an upgraded disk -----------------------------------------------------------
echo
echo "An upgraded disk: files of root's, as an older image that ran Odoo as root left them"
docker stop -t 30 "$APP" >/dev/null 2>&1
docker rm -f "$APP" >/dev/null 2>&1
if ! docker run --rm --network none -v "$VOL_DATA:/v" "$SHAPER" sh -c '
    set -e
    mkdir -p /v/sessions/zz /v/filestore/odoo/zz /v/backups /v/addons/19.0
    echo old > /v/sessions/zz/t-old-session
    echo old > /v/filestore/odoo/zz/t-old-file
    echo old > /v/backups/t-old.zip
    chown -R 0:0 /v/sessions /v/filestore /v/backups /v/addons /v/.odoo_initialized
    chmod 700 /v/sessions /v/sessions/zz /v/addons
    chmod 500 /v/addons/19.0
    chmod 600 /v/sessions/zz/t-old-session
    chmod 755 /v/backups' >/dev/null 2>&1; then
  fail "the test gives the old files to root"
  finish
fi
MASTER_PW="$GIVEN_MASTER_PW"
if ! start_app "$MASTER_PW"; then
  fail "a new Odoo container starts on the same volumes"
  finish
fi
start_sampler
if ! wait_healthy "$READY_SECONDS"; then
  fail "Odoo answers on /web/health within ${READY_SECONDS} s"
  show_logs "$APP"
  finish
fi
pass "Odoo answers on /web/health"
SAMPLES="$(stop_sampler)"
# (A variable, not docker logs | grep -q: grep would stop reading, and pipefail would count docker's SIGPIPE.)
logs="$(docker logs "$APP" 2>&1)"
if [[ "$logs" == *"already initialized"* ]]; then
  pass "the start found the earlier install (no second install)"
else
  fail "the start found the earlier install (no second install)"
fi
# A new container makes new SSH host keys, so the client forgets the old one, as it would a new host.
docker exec "$CLIENT" rm -f /root/.ssh/known_hosts >/dev/null 2>&1
expect_runbook_ssh "the runbook's SSH check passes on the new container"
expect_nothing_root "the files of root's went to odoo: nothing under /var/lib/odoo is root's (lost+found aside)"
assert_eq "the old session and filestore files are odoo's" "odoo odoo" \
  "$(docker exec "$APP" stat -c %U /var/lib/odoo/sessions/zz/t-old-session /var/lib/odoo/filestore/odoo/zz/t-old-file \
    2>&1 | tr '\n' ' ' | sed 's/ $//')"
expect_server_odoo "upgraded disk"
expect_no_cmdline_password "no command line holds a password, the given master password included" "$SAMPLES"
in_app 'conf_is admin_passwd T_MASTER'
check "odoo.conf holds the given master password" $?
expect_log_clean "the container's log holds no password"
expect_sign_in "the admin signs in on the upgraded disk"
expect_shell_run "upgraded disk"
expect_backups_folder "the old backups folder is odoo's, and only odoo can read it"

# --- 5. what code running as odoo could leave for root ---------------------------------------
echo
echo "Links and files that code running as odoo could leave in /var/lib/odoo"
PLANTED=/etc/odoo-nonroot-t-planted
if restart_planted "the install marker as a link to $PLANTED, which doesn't exist" \
    "rm -rf /v/.odoo_initialized && ln -s $PLANTED /v/.odoo_initialized && chown -h \"\$T_UID:\$T_GID\" /v/.odoo_initialized"; then
  expect_not_there "$PLANTED" "root didn't follow the link: $PLANTED doesn't exist"
  assert_eq "the marker is a file of odoo's again" "regular file odoo" \
    "$(docker exec "$APP" stat -c '%F %U' /var/lib/odoo/.odoo_initialized 2>&1)"
  expect_outside_unchanged "no file outside the volumes went to odoo"
fi
# shellcheck disable=SC2016  # the script is for the sh in the shaper container
if restart_planted "backups as a file of odoo's" \
    'rm -rf /v/backups && echo planted > /v/backups && chown "$T_UID:$T_GID" /v/backups'; then
  expect_backups_folder "backups is a folder of odoo's again, mode 700"
fi
if restart_planted "backups as a link to ${PLANTED}-dir, which doesn't exist" \
    "rm -rf /v/backups && ln -s ${PLANTED}-dir /v/backups && chown -h \"\$T_UID:\$T_GID\" /v/backups"; then
  expect_backups_folder "backups is a folder of odoo's again, mode 700"
  expect_not_there "${PLANTED}-dir" "root didn't follow the link: ${PLANTED}-dir doesn't exist"
  expect_outside_unchanged "no file outside the volumes went to odoo"
fi
# shellcheck disable=SC2016  # the script is for the sh in the shaper container
if restart_planted "backups as a link to /opt, a folder of root's" \
    'rm -rf /v/backups && ln -s /opt /v/backups && chown -h "$T_UID:$T_GID" /v/backups'; then
  expect_backups_folder "backups is a folder of odoo's again, mode 700"
  assert_eq "root didn't follow the link: /opt keeps its owner and mode" "root 755" \
    "$(docker exec "$APP" stat -c '%U %a' /opt 2>&1)"
fi

# --- 6. the database container -----------------------------------------------------------------
echo
echo "The database container: CLOUVE_OPS_PASSWORD stays out of PostgreSQL's environment"

# pg_env_hits: one line for each PostgreSQL process in the second database container with CLOUVE_OPS_PASSWORD in its
# environment (looked up by name, the value never read), then "read <n> of <m>": the PostgreSQL processes whose
# environment could be read, of all of them. It reads as postgres: root in a container has no CAP_SYS_PTRACE, so it
# can't read another user's environment. The server processes other than the first write their titles over that
# memory, so the first one (the postmaster) is the one this can read.
pg_env_hits() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -u postgres "$DB2" bash -c '
    n=0; m=0
    for d in /proc/[0-9]*; do
      { mapfile -d "" -t argv < "$d/cmdline"; } 2>/dev/null || continue
      case "${argv[0]:-}" in postgres|postgres:*|*/bin/postgres) ;; *) continue ;; esac
      m=$((m + 1))
      { mapfile -d "" -t vars < "$d/environ"; } 2>/dev/null || continue
      ok=0
      for v in "${vars[@]}"; do
        case "$v" in
          CLOUVE_OPS_PASSWORD=*) echo "pid ${d#/proc/}: ${argv[0]%% *}"; ok=1; break ;;
          [A-Za-z_]*=*) ok=1 ;;
        esac
      done
      n=$((n + ok))
    done
    echo "read $n of $m"'
}

# pg_program_count: what a program that PostgreSQL runs sees, asked as Odoo's database role (the superuser) would ask
# it: COPY ... FROM PROGRAM runs `env` as the postgres user, and only the number of CLOUVE_OPS_PASSWORD lines comes back.
pg_program_count() {
  docker exec "$DB2" psql -U odoo -d postgres -qtA -c "CREATE TEMP TABLE t_env (n text)" \
    -c "COPY t_env FROM PROGRAM 'env | grep -c ^CLOUVE_OPS_PASSWORD= || true'" -c "SELECT n FROM t_env" 2>&1
}

# ssh_db <command>: runs <command> as clouve-ops over SSH in the second database container, from the client beside it.
ssh_db() {
  SSHPASS="$OPS_PW" docker exec -i -e SSHPASS "$CLIENT2" timeout 120 \
    sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    clouve-ops@127.0.0.1 "$1"
}

# db_ready: PostgreSQL answers in the second database container and its sshd lets clouve-ops in (the runbook's check).
db_ready() {
  docker exec "$DB2" pg_isready -q -h 127.0.0.1 -U odoo 2>/dev/null &&
    SSHPASS="$OPS_PW" docker exec -e SSHPASS "$CLIENT2" timeout 60 \
      sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@127.0.0.1 true \
      </dev/null >/dev/null 2>&1
}

# wait_db_ready <label>: up to 120 s.
wait_db_ready() {
  local deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if db_ready; then pass "$1"; return 0; fi
    sleep 2
  done
  fail "$1"
  docker logs --tail 20 "$DB2" 2>&1 | redacted | sed 's/^/       | /'
  return 1
}

# shutdowns: how many clean shutdowns PostgreSQL has logged in the second database container.
db2_shutdowns() { docker logs "$DB2" 2>&1 | grep -c 'database system is shut down'; }

# expect_db_env_clean <when>: the checks on the second database container's environment.
expect_db_env_clean() {
  local hits read agent
  hits="$(pg_env_hits)"
  read="$(printf '%s\n' "$hits" | sed -n 's/^read //p')"
  hits="$(printf '%s\n' "$hits" | grep -v '^read ')"
  if [ "${read%% *}" -gt 0 ] 2>/dev/null && [ -z "$hits" ]; then
    pass "no PostgreSQL process has CLOUVE_OPS_PASSWORD in its environment (/proc/<pid>/environ read as postgres: $read, $1)"
  else
    fail "no PostgreSQL process has CLOUVE_OPS_PASSWORD in its environment (/proc/<pid>/environ read as postgres, $1)"
    detail "${hits:-no PostgreSQL environment could be read (${read:-none})}"
  fi
  assert_eq "a program PostgreSQL runs (COPY ... FROM PROGRAM 'env', as Odoo's superuser role) sees no CLOUVE_OPS_PASSWORD ($1)" \
    0 "$(pg_program_count)"
  # shellcheck disable=SC2016  # the command is for the shell clouve-ops gets over SSH
  agent="$(ssh_db 'sudo -nu "$(stat -c %U /proc/1)" cat /proc/1/environ | tr "\0" "\n" | grep -c "^CLOUVE_OPS_PASSWORD="' \
    </dev/null 2>/dev/null)"
  assert_eq "tini (PID 1) still has it, read the way the AI Assistant reads its settings ($1)" 1 "$agent"
}

if ! POSTGRES_PASSWORD="$DB_PW" CLOUVE_OPS_PASSWORD="$OPS_PW" docker run -d --pull=never --name "$DB2" --network none \
    -v "$VOL_PG2:/var/lib/postgresql" -e POSTGRES_DB=postgres -e POSTGRES_USER=odoo -e POSTGRES_PASSWORD \
    -e CLOUVE_OPS_PASSWORD "$PG_IMAGE" >/dev/null; then
  fail "the second database container starts"
  finish
fi
if ! docker run -d --pull=never --name "$CLIENT2" --network "container:$DB2" "$CLIENT_IMAGE" sleep 3600 >/dev/null; then
  fail "the client beside it starts"
  finish
fi
if wait_db_ready "PostgreSQL answers, and the runbook's SSH check passes: sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@<db host> true"; then
  assert_eq "PID 1 is tini" tini "$(docker exec "$DB2" cat /proc/1/comm 2>/dev/null)"
  expect_db_env_clean "first start"

  shutdowns_before="$(db2_shutdowns)"
  docker restart -t 30 "$DB2" >/dev/null 2>&1
  check "docker restart -t 30 restarts the database container" $?
  # The client joined the network namespace the container had before; it joins the new one when it starts again.
  docker restart -t 1 "$CLIENT2" >/dev/null 2>&1
  if wait_db_ready "after the restart, PostgreSQL answers and the SSH check passes again"; then
    if [ "$(db2_shutdowns)" -gt "$shutdowns_before" ]; then
      pass "PostgreSQL shut down cleanly for the restart (\"database system is shut down\")"
    else
      fail "PostgreSQL shut down cleanly for the restart (\"database system is shut down\")"
    fi
    recoveries="$(docker logs "$DB2" 2>&1 | grep -c 'automatic recovery in progress')"
    assert_eq "it started again without crash recovery (no \"automatic recovery in progress\")" 0 "$recoveries"
    expect_db_env_clean "after the restart"
  fi

  shutdowns_before="$(db2_shutdowns)"
  start=$SECONDS
  docker stop -t 30 "$DB2" >/dev/null 2>&1
  took=$((SECONDS - start))
  if [ "$took" -lt 30 ]; then
    pass "docker stop -t 30 ends the database container in about $took s"
  else
    fail "docker stop -t 30 ends the database container before the grace period is up (took $took s)"
  fi
  assert_eq "PostgreSQL exits 0 on the forwarded SIGINT" 0 "$(docker inspect -f '{{.State.ExitCode}}' "$DB2" 2>/dev/null)"
  if [ "$(db2_shutdowns)" -gt "$shutdowns_before" ]; then
    pass "PostgreSQL logs a clean shutdown (\"database system is shut down\")"
  else
    fail "PostgreSQL logs a clean shutdown (\"database system is shut down\")"
  fi
fi

finish
