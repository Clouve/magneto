#!/bin/bash

# ============================================================================
# Odoo image: tini as PID 1
# ============================================================================
# Odoo never reaps a process it didn't start itself. While Odoo was PID 1,
# every finished process whose parent had gone stayed in the process table as
# a zombie, and the AI Assistant's clouve-ops SSH sessions left about one
# each. The image runs tini as PID 1: tini reaps them and passes signals on to
# Odoo.
#
# The test builds both Odoo images (apps/odoo/image and image/postgres) and
# starts them with no network: the database with --network none, and Odoo in
# the database container's network namespace (--network container:), so Odoo
# reaches PostgreSQL on 127.0.0.1 and nothing else. The database gets no
# CLOUVE_OPS_PASSWORD, so only Odoo's sshd listens on port 22. Once Odoo
# answers on /web/health (the first start installs the base module, which
# takes a few minutes), the test checks from inside the Odoo container:
#   - PID 1 is tini, and its command line still holds "odoo": the AI
#     Assistant's restart command checks that first
#     (grep -q odoo /proc/1/cmdline && sudo kill -HUP 1);
#   - no zombie after 40 clouve-ops SSH sessions, and none after 5 sessions
#     that each leave a short background job running when they end;
#   - that restart command, sent over SSH as clouve-ops: Odoo logs a new start
#     in the same process (it re-executes itself), /web/health answers again,
#     the container doesn't restart, tini is still PID 1 and SSH still logs
#     in;
#   - docker stop -t 30 ends the container before the 30 seconds are up,
#     without a SIGKILL (exit code 137);
#   - docker stop -t 30 then ends the database in time too: tini passes the
#     postgres image's stop signal (SIGINT) on, PostgreSQL exits 0 and logs
#     one more "database system is shut down" (a clean shutdown, so the next
#     start runs no crash recovery).
#
# --image odoo=REF and --image odoo-postgres=REF use images that are already
# built instead, and the test leaves them in place: for example images built
# from an older commit, to see what the test finds there.
#
# Needs Docker. The build pulls odoo:19.0 and postgres:18 and runs apt-get.
# Every container the test starts is named odoo-init-t-*. The containers,
# their volumes and the images the test built are removed when it exits.
#
# Usage: bash tests/odoo-init.test.sh [--image odoo=REF] [--image odoo-postgres=REF]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="$REPO_DIR/apps/odoo/image"
PREFIX="odoo-init-t-"    # every container this test starts begins with this
DB="${PREFIX}db"
APP="${PREFIX}app"
READY_SECONDS=600        # the first start installs Odoo's base module
RESTART_SECONDS=180
SSH_SESSIONS=40
ORPHAN_SESSIONS=5
STOP_GRACE=30
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
# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$3" == "$2" ]]; then
    pass "$1"
  else
    fail "$1"
    printf '       expected: %q\n       actual:   %q\n' "$2" "$3"
  fi
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

BUILT=()
# Removes the containers named odoo-init-t-* (and their volumes), Odoo's first: it uses the database's network.
remove_test_containers() {
  local name
  docker rm -f -v "$APP" >/dev/null 2>&1
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

# finish: the summary line and the exit status.
finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    printf '%sOdoo init checks passed.%s\n' "$GREEN" "$RESET"
    exit 0
  fi
  printf '%sOdoo init checks failed.%s\n' "$RED" "$RESET"
  exit 1
}

# show_logs <container>: the last lines of the container's log, indented.
show_logs() {
  docker logs --tail 30 "$1" 2>&1 | sed 's/^/       | /'
}

# build <tag> <context>: builds an image the test removes again at the end.
build() {
  local log
  if log="$(docker build -t "$1" "$2" 2>&1)"; then
    BUILT+=("$1")
    pass "image builds ($1)"
    return 0
  fi
  fail "image builds ($1)"
  printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
  return 1
}

# secret: a random throwaway password for this run's containers.
secret() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }

remove_test_containers    # leftovers of a run that was killed

echo "Odoo image: tini as PID 1"
if [ -z "$PG_IMAGE" ]; then
  PG_IMAGE="clouve-test/odoo-postgres:init-test"
  build "$PG_IMAGE" "$IMAGE_DIR/postgres" || finish
fi
if [ -z "$ODOO_IMAGE" ]; then
  ODOO_IMAGE="clouve-test/odoo:init-test"
  build "$ODOO_IMAGE" "$IMAGE_DIR" || finish
fi
for image in "$PG_IMAGE" "$ODOO_IMAGE"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "No image $image on this machine." >&2
    exit 2
  fi
done

DB_PW="$(secret)"
OPS_PW="$(secret)"

# --- start ------------------------------------------------------------------
if ! docker run -d --pull=never --name "$DB" --network none \
    -e POSTGRES_DB=postgres -e POSTGRES_USER=odoo -e "POSTGRES_PASSWORD=$DB_PW" \
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

if ! docker run -d --pull=never --name "$APP" --network "container:$DB" \
    -e ODOO_DB_HOST=127.0.0.1 -e ODOO_DB_USER=odoo -e "ODOO_DB_PASSWORD=$DB_PW" \
    -e "ODOO_MASTER_PASSWORD=$(secret)" -e ODOO_DB_NAME=odoo \
    -e ODOO_ADMIN_EMAIL=admin@example.com -e "ODOO_ADMIN_PASSWORD=$(secret)" \
    -e ODOO_URL=http://127.0.0.1:8069 -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
    "$ODOO_IMAGE" >/dev/null; then
  fail "the Odoo container starts"
  finish
fi

# healthy: Odoo answers on /web/health.
healthy() {
  docker exec "$APP" curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8069/web/health >/dev/null 2>&1
}

# running: the Odoo container is still running.
running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ]
}

ready=false
deadline=$((SECONDS + READY_SECONDS))
while [ "$SECONDS" -lt "$deadline" ] && running; do
  if healthy; then ready=true; break; fi
  sleep 5
done
if ! $ready; then
  fail "Odoo answers on /web/health within ${READY_SECONDS} s"
  show_logs "$APP"
  finish
fi
pass "Odoo answers on /web/health"

# --- helpers that look inside the Odoo container -------------------------------
# comm_of <pid>: the command name of a process in the Odoo container.
comm_of() { docker exec "$APP" cat "/proc/$1/comm" 2>/dev/null; }

# odoo_pid: the PID of the Odoo server: the child of PID 1 with /usr/bin/odoo among its arguments. Its name
# changes from odoo to python3 when it re-executes itself on SIGHUP, so the name can't tell. Its command line holds
# the database password (the official entrypoint passes --db_password), so nothing here prints it.
odoo_pid() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec "$APP" bash -c '
    for f in /proc/[0-9]*/stat; do
      line="$(cat "$f" 2>/dev/null)" || continue
      set -- ${line##*) }
      [ "$2" = 1 ] || continue
      p="${f#/proc/}"; p="${p%/stat}"
      if tr "\0" "\n" < "/proc/$p/cmdline" 2>/dev/null | grep -qx "\(.*/\)\{0,1\}odoo"; then echo "$p"; fi
    done'
}

# zombies: one line per zombie process in the Odoo container, "<pid> <parent pid> <name>". It reads /proc, so the
# image needs no ps.
zombies() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec "$APP" bash -c '
    for f in /proc/[0-9]*/stat; do
      line="$(cat "$f" 2>/dev/null)" || continue
      comm="${line#*(}"; comm="${comm%)*}"
      set -- ${line##*) }
      if [ "$1" = Z ]; then p="${f#/proc/}"; echo "${p%/stat} $2 $comm"; fi
    done'
}

# expect_no_zombies <label>
expect_no_zombies() {
  local found
  found="$(zombies)"
  if [ -z "$found" ]; then
    pass "$1"
  else
    fail "$1"
    printf '%s\n' "$found" | head -n 10 | sed 's/^/       zombie (pid, parent, name): /'
    echo "       $(printf '%s\n' "$found" | wc -l) in all"
  fi
}

# ssh_ops <count> <command>: logs in <count> times as clouve-ops over SSH to 127.0.0.1 from inside the Odoo
# container, each time running <command>. Prints what the last one printed. Returns 0 when every session exited 0,
# else the status of the last one that didn't. The image has ssh but not sshpass, so an askpass script hands ssh the
# password from its environment.
ssh_ops() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "T_PW=$OPS_PW" "$APP" bash -c '
    d="$(mktemp -d)" || exit 1
    cat > "$d/askpass" <<"EOF"
#!/bin/sh
printf "%s\n" "$T_PW"
EOF
    chmod 700 "$d/askpass"
    rc=0
    for ((i = 1; i <= $1; i++)); do
      out="$(SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 30 ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 clouve-ops@127.0.0.1 "$2" </dev/null 2>/dev/null)"
      status=$?
      [ "$status" -eq 0 ] || rc=$status
    done
    rm -rf "$d"
    printf "%s" "$out"
    exit "$rc"' _ "$1" "$2"
}

# started_count: how many start lines Odoo has logged since the container started.
started_count() { docker logs "$APP" 2>&1 | grep -cE "$STARTED"; }

# --- PID 1 -------------------------------------------------------------------
echo
echo "PID 1"
assert_eq "PID 1 is tini" tini "$(comm_of 1)"
if docker exec "$APP" grep -q odoo /proc/1/cmdline; then
  pass "PID 1's command line holds \"odoo\" (the restart command's check)"
else
  fail "PID 1's command line holds \"odoo\" (the restart command's check)"
fi
server="$(odoo_pid)"
if [[ "$server" =~ ^[0-9]+$ ]]; then
  pass "the Odoo server is a child of PID 1 (pid $server)"
else
  fail "the Odoo server is a child of PID 1"
  printf '       found: %q\n' "$server"
fi

# --- zombies -----------------------------------------------------------------
echo
echo "Zombies"
expect_no_zombies "no zombie before any SSH session"
ssh_ops "$SSH_SESSIONS" true
assert_eq "$SSH_SESSIONS SSH sessions as clouve-ops log in" 0 "$?"
sleep 3    # tini reaps within a second of each exit
expect_no_zombies "no zombie after $SSH_SESSIONS SSH sessions"
ssh_ops "$ORPHAN_SESSIONS" 'nohup sleep 2 </dev/null >/dev/null 2>&1 &'
assert_eq "$ORPHAN_SESSIONS SSH sessions that leave a background job log in" 0 "$?"
sleep 6    # the background jobs end 2 s after their sessions
expect_no_zombies "no zombie after $ORPHAN_SESSIONS sessions that each leave a background job"

# --- restart by SIGHUP, as the AI Assistant does it -----------------------------
echo
echo "Restart with SIGHUP"
started_before_count="$(started_count)"
started_before="$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$APP")"
ssh_ops 1 'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1' >/dev/null
assert_eq "the restart command over SSH exits 0" 0 "$?"
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
assert_eq "the same process restarted in place (Odoo re-executes itself)" "$server" "$(odoo_pid)"
assert_eq "PID 1 is still tini" tini "$(comm_of 1)"
assert_eq "the container didn't restart" "$started_before" \
  "$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$APP")"
assert_eq "clouve-ops still logs in over SSH" clouve-ops "$(ssh_ops 1 'id -un')"
expect_no_zombies "no zombie after the restart"

# --- docker stop ----------------------------------------------------------------
# stop_in_time <container> <what>: docker stop -t STOP_GRACE has to end the container before the grace period is up,
# or Docker sends SIGKILL. SECONDS counts whole seconds, which is enough against 30 (date +%s%N is GNU-only).
stop_in_time() {
  local start=$SECONDS took
  docker stop -t "$STOP_GRACE" "$1" >/dev/null 2>&1
  took=$((SECONDS - start))
  if [ "$took" -lt "$STOP_GRACE" ]; then
    pass "docker stop -t $STOP_GRACE ends $2 in about $took s"
  else
    fail "docker stop -t $STOP_GRACE ends $2 before the grace period is up (took $took s)"
  fi
}

# exit_code <container>: the exit code of a stopped container.
exit_code() { docker inspect -f '{{.State.ExitCode}}' "$1" 2>/dev/null; }

# shutdowns: how many clean shutdowns PostgreSQL has logged. The first start's temporary server logs one too.
shutdowns() { docker logs "$DB" 2>&1 | grep -c 'database system is shut down'; }

echo
echo "Stop"
stop_in_time "$APP" "the Odoo container"
code="$(exit_code "$APP")"
if [ -n "$code" ] && [ "$code" != 137 ]; then
  pass "Odoo stops on the forwarded SIGTERM (exit code $code, not 137)"
else
  fail "Odoo stops on the forwarded SIGTERM, without a SIGKILL (exit code ${code:-unknown})"
fi

# Then the database, as a pod stop does it. Its stop signal is SIGINT (the postgres image's STOPSIGNAL), which tini
# passes on: PostgreSQL makes a fast shutdown and exits 0. Killed instead, it would run crash recovery at its next
# start.
shutdowns_before="$(shutdowns)"
stop_in_time "$DB" "the PostgreSQL container"
assert_eq "PostgreSQL exits 0 on the forwarded SIGINT (137 would be a SIGKILL)" 0 "$(exit_code "$DB")"
if [ "$(shutdowns)" -gt "$shutdowns_before" ]; then
  pass "PostgreSQL logs a clean shutdown (\"database system is shut down\")"
else
  fail "PostgreSQL logs a clean shutdown (\"database system is shut down\")"
  show_logs "$DB"
fi

finish
