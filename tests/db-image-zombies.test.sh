#!/bin/bash

# ============================================================================
# Zombie check for the database images
# ============================================================================
# Each database image starts its clouve-ops sshd in the background and then
# execs docker-entrypoint.sh, so the database server is PID 1 unless the image
# runs tini. PID 1 has to reap every finished process whose parent has gone,
# such as what an SSH session leaves behind:
#   - mysqld and mariadbd don't reap processes they didn't start, so those
#     stay zombies;
#   - PostgreSQL reaps every child, but when one it didn't start ends with an
#     error or is killed by a signal, it treats it as a crashed server
#     process: it ends every database connection and restarts its server
#     processes ("terminating any other active server processes").
# tini as PID 1 avoids both: it reaps them, and the database server is its
# child. Both Odoo images run it (tests/odoo-init.test.sh). odoo-postgres
# also starts its sshd detached, `( start-clouve-ops-sshd.sh & )`, so that
# sshd's parent is tini: a plain `&` would make it a child of the shell that
# turns into PostgreSQL, which would then see sshd's own exit too.
#
# For each image the test builds it from its folder under apps/, starts it
# with no network (--network none) and CLOUVE_OPS_PASSWORD set, and waits
# until the database answers on 127.0.0.1 and sshd listens. When PID 1 is
# tini, it checks that the sshd listener's parent is PID 1. Then, from a
# client container in the same network namespace (the MySQL images have no
# ssh client), it:
#   1. counts the zombies, runs 40 clouve-ops SSH sessions and counts them
#      again;
#   2. runs one SSH session that leaves a background job running, kills that
#      job with SIGKILL, and checks that the job doesn't stay a zombie and
#      that the server doesn't restart (for PostgreSQL, its log).
# It also checks (release 4.5.5) that:
#   3. the database server's own environment (mysqld, mariadbd or the postgres
#      postmaster, read as the user it runs as) holds no CLOUVE_OPS_PASSWORD:
#      that password signs in as clouve-ops, who has sudo, and anything that
#      runs as the database's user can read the server's environment. PID 1
#      (tini) keeps it, but its environment is root's alone;
#   4. docker stop -t 30 ends the container within the 30 s, and the stop
#      adds the server's clean shutdown line to its log (the first start's
#      temporary server logged one already; tini passes the stop signal on);
#   5. after docker start, a clouve-ops SSH session still signs in.
# A finding is a zombie that wasn't there before, a server restart, under
# tini an sshd whose parent isn't PID 1, the password in the server's
# environment, a stop that isn't clean, or no sign-in after the restart. A new
# database image with the clouve-ops sshd goes into ALL, CONTEXT and PORT below.
#
# An image with a finding FAILs, except one in KNOWN whose PID 1 isn't tini:
# its findings are printed as KNOWN. KNOWN is empty since all five images run
# tini (4.5.5). The table at the end has what each check found.
#
# --image NAME=REF uses an image that is already built instead of building it
# (it stays in place). Naming images limits the run to them.
#
# Needs Docker. The builds pull mysql:8.0, mysql:8.4, mariadb:12.3 and
# postgres:18 and install packages. Every container the test starts is named
# db-zombies-t-*. The containers, their volumes and the images the test built
# are removed when it exits.
#
# Usage: bash tests/db-image-zombies.test.sh [--image NAME=REF]... [NAME...]
#   NAME  gibbon-mysql, moodle-mysql, wordpress-mariadb, nextcloud-mariadb or
#         odoo-postgres (default: all five)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="db-zombies-t-"    # every container this test starts begins with this
READY_SECONDS=240
SSH_SESSIONS=40
# The SSH client runs in a container of this image (it has ssh), in the database container's network namespace.
CLIENT=odoo-postgres

ALL=(gibbon-mysql moodle-mysql wordpress-mariadb nextcloud-mariadb odoo-postgres)
# Findings these images are known to have: printed, not failed, until they get tini. None since 4.5.5.
KNOWN=()
declare -A CONTEXT=(
  [gibbon-mysql]="$REPO_DIR/apps/gibbon/image/mysql"
  [moodle-mysql]="$REPO_DIR/apps/moodle/image/mysql"
  [wordpress-mariadb]="$REPO_DIR/apps/wordpress/image/mariadb"
  [nextcloud-mariadb]="$REPO_DIR/apps/nextcloud/image/mariadb"
  [odoo-postgres]="$REPO_DIR/apps/odoo/image/postgres"
)
declare -A PORT=(
  [gibbon-mysql]=3306 [moodle-mysql]=3306 [wordpress-mariadb]=3306 [nextcloud-mariadb]=3306 [odoo-postgres]=5432
)
# The line each server logs when it has shut down cleanly.
declare -A SHUTDOWN_LINE=(
  [gibbon-mysql]="Shutdown complete" [moodle-mysql]="Shutdown complete" [wordpress-mariadb]="Shutdown complete"
  [nextcloud-mariadb]="Shutdown complete" [odoo-postgres]="database system is shut down"
)
declare -A IMAGE=()

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *odoo-postgres (default/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

SELECTED=()
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
      SELECTED+=("$1")
      ;;
  esac
  shift
done
[ "${#SELECTED[@]}" -gt 0 ] || SELECTED=("${ALL[@]}")

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
known() { printf '  %sKNOWN%s %s\n' "$YELLOW" "$RESET" "$1"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

BUILT=()
# Removes the containers named db-zombies-t-* (and their volumes), nothing else.
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

# image_for <name>: makes sure IMAGE[name] is an image on this machine, building it unless --image gave one. Runs in
# this shell (never in $(...)), so that BUILT keeps what it built.
image_for() {
  local name="$1" image log
  image="${IMAGE[$name]:-}"
  if [ -n "$image" ]; then
    docker image inspect "$image" >/dev/null 2>&1 && return 0
    echo "       No image $image on this machine."
    return 1
  fi
  image="clouve-test/$name:zombies-test"
  if log="$(docker build -t "$image" "${CONTEXT[$name]}" 2>&1)"; then
    BUILT+=("$image")
    IMAGE[$name]="$image"
    return 0
  fi
  printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
  return 1
}

# The database settings each image needs for its first start.
db_env() {
  local pw="$1"
  case "$2" in
    odoo-postgres) echo "-e POSTGRES_USER=odoo -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD=$pw" ;;
    *-mariadb) echo "-e MARIADB_ROOT_PASSWORD=$pw -e MARIADB_DATABASE=app" ;;
    *) echo "-e MYSQL_ROOT_PASSWORD=$pw -e MYSQL_DATABASE=app" ;;
  esac
}

# in_db <container> <script> [arg...]: runs a bash script in the database container; the first arg is its $0.
in_db() {
  local container="$1" script="$2"
  shift 2
  docker exec "$container" bash -c "$script" "$@"
}

# zombies <container>: one line per zombie, "<pid> <parent pid> <name>", read from /proc (no ps needed).
zombies() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  in_db "$1" '
    for f in /proc/[0-9]*/stat; do
      line="$(cat "$f" 2>/dev/null)" || continue
      comm="${line#*(}"; comm="${comm%)*}"
      set -- ${line##*) }
      if [ "$1" = Z ]; then p="${f#/proc/}"; echo "${p%/stat} $2 $comm"; fi
    done'
}

# sshd_parents <container>: the parent pid of the sshd listener, the sshd whose parent isn't an sshd itself (a
# session's sshd is the listener's child). One line per such sshd; there is one.
sshd_parents() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  in_db "$1" '
    declare -A parent=()
    for f in /proc/[0-9]*/stat; do
      line="$(cat "$f" 2>/dev/null)" || continue
      comm="${line#*(}"; comm="${comm%)*}"
      [ "$comm" = sshd ] || continue
      set -- ${line##*) }
      p="${f#/proc/}"; parent[${p%/stat}]="$2"
    done
    for p in "${!parent[@]}"; do
      [ -n "${parent[${parent[$p]}]+set}" ] || echo "${parent[$p]}"
    done'
}

# server_pid <container>: the pid of the database server itself: a mysqld, mariadbd or postgres process whose parent
# isn't one of those (PostgreSQL's own processes are the postmaster's children).
server_pid() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  in_db "$1" '
    declare -A comm=() parent=()
    for f in /proc/[0-9]*/stat; do
      line="$(cat "$f" 2>/dev/null)" || continue
      c="${line#*(}"; c="${c%)*}"
      case "$c" in mysqld|mariadbd|postgres) ;; *) continue ;; esac
      set -- ${line##*) }
      p="${f#/proc/}"; p="${p%/stat}"; comm[$p]="$c"; parent[$p]="$2"
    done
    for p in "${!comm[@]}"; do [ -n "${comm[${parent[$p]}]+set}" ] || echo "$p"; done'
}

# env_names <container> <pid>: the names in that process's environment, read as the user it runs as.
env_names() {
  local owner
  owner="$(in_db "$1" 'stat -c %U "/proc/$0"' "$2" 2>/dev/null)" || return 1
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec -u "$owner" "$1" sh -c 'tr "\0" "\n" < "/proc/$0/environ" | cut -d= -f1' "$2"
}

# name_of <container> <pid>: the command name of a process in the container.
# shellcheck disable=SC2016  # the script is for the bash inside the container
name_of() { in_db "$1" 'cat "/proc/$0/comm" 2>/dev/null' "$2"; }

# count <lines>: the number of non-empty lines.
count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# ssh_from_client <container> <count> <command>: <count> clouve-ops SSH sessions to the database container, each
# running <command>, from a client container in its network namespace. Prints what the last one printed. Returns 0
# when every session exited 0.
ssh_from_client() {
  # shellcheck disable=SC2016  # the script is for the bash inside the client container
  docker run --rm --pull=never --network "container:$1" -e "T_PW=$OPS_PW" --entrypoint bash \
    "${IMAGE[$CLIENT]}" -c '
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
    exit "$rc"' _ "$2" "$3"
}

# restarts <container>: how many times PostgreSQL has ended its connections to restart after a crash, from its log.
restarts() { docker logs "$1" 2>&1 | grep -c 'terminating any other active server processes'; }

# is_known <name>
is_known() {
  local k
  for k in "${KNOWN[@]}"; do [ "$k" = "$1" ] && return 0; done
  return 1
}

declare -A ROW=()
echo "Zombie check for the database images"
if ! image_for "$CLIENT"; then
  fail "the SSH client image ($CLIENT) builds"
  exit 1
fi

for name in "${SELECTED[@]}"; do
  echo
  echo "$name"
  if ! image_for "$name"; then
    fail "image builds or is on this machine"
    ROW[$name]="-|-|-|-|-|could not run"
    continue
  fi
  image="${IMAGE[$name]}"
  c="$PREFIX$name"
  OPS_PW="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  db_pw="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  # shellcheck disable=SC2046  # db_env prints separate -e options
  if ! docker run -d --pull=never --name "$c" --network none -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
      $(db_env "$db_pw" "$name") "$image" >/dev/null; then
    fail "the container starts"
    ROW[$name]="-|-|-|-|-|could not run"
    continue
  fi

  ready=false
  deadline=$((SECONDS + READY_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if in_db "$c" "</dev/tcp/127.0.0.1/${PORT[$name]} && </dev/tcp/127.0.0.1/22" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done
  if ! $ready; then
    fail "the database answers on 127.0.0.1:${PORT[$name]} and sshd on port 22 within ${READY_SECONDS} s"
    docker logs --tail 15 "$c" 2>&1 | sed 's/^/       | /'
    ROW[$name]="-|-|-|-|-|could not run"
    docker rm -f -v "$c" >/dev/null 2>&1
    continue
  fi
  sleep 5    # the first start's temporary server has gone; let the final one settle
  pid1="$(in_db "$c" 'cat /proc/1/comm')"
  pass "ready, PID 1 is $pid1"

  findings=()
  if [ "$pid1" = tini ]; then
    parents="$(sshd_parents "$c")"
    if [ "$parents" = 1 ]; then
      pass "sshd's parent is PID 1 (tini), not the database server"
    elif [ -z "$parents" ]; then
      findings+=("no sshd listener found, so its parent can't be checked")
    else
      findings+=("sshd's parent is not PID 1 (tini): pid ${parents//$'\n'/, } ($(name_of "$c" "${parents%%$'\n'*}"))")
    fi
  fi
  before="$(count "$(zombies "$c")")"
  restarts_before="$(restarts "$c")"
  if ! ssh_from_client "$c" "$SSH_SESSIONS" true >/dev/null; then
    fail "$SSH_SESSIONS SSH sessions as clouve-ops log in"
  fi
  sleep 3
  after_list="$(zombies "$c")"
  after="$(count "$after_list")"
  if [ "$after" -gt "$before" ]; then
    findings+=("$((after - before)) zombie(s) after $SSH_SESSIONS SSH sessions")
    printf '%s\n' "$after_list" | head -n 5 | sed 's/^/       zombie (pid, parent, name): /'
  fi

  job="$(ssh_from_client "$c" 1 'nohup sleep 300 </dev/null >/dev/null 2>&1 & echo $!')"
  if [[ "$job" =~ ^[0-9]+$ ]]; then
    in_db "$c" "kill -KILL $job" >/dev/null 2>&1
    sleep 3
    # shellcheck disable=SC2016  # the script is for the bash inside the container
    state="$(in_db "$c" 'line="$(cat "/proc/$0/stat" 2>/dev/null)" || { echo gone; exit; }; set -- ${line##*) }; echo "$1"' "$job")"
    if [ "$state" = Z ]; then
      job_result="stays a zombie"
      findings+=("a killed background job stays a zombie")
    else
      job_result="reaped"
    fi
  else
    fail "an SSH session starts a background job and prints its pid"
    job_result="not run"
  fi
  if [ "$(restarts "$c")" -gt "$restarts_before" ]; then
    job_result="$job_result; server restarted"
    findings+=("PostgreSQL ended its connections and restarted (its log: terminating any other active server processes)")
  fi
  untracked="$(docker logs "$c" 2>&1 | grep -c 'untracked child process')"
  if [ "$untracked" -gt 0 ]; then
    echo "       PostgreSQL logged $untracked 'untracked child process' line(s): processes it didn't start ended as its children"
  fi

  # 3. The server's own environment.
  spid="$(server_pid "$c" | head -n 1)"
  if [ -z "$spid" ]; then
    findings+=("no database server process found, so its environment can't be read")
    env_result="not read"
  elif ! names="$(env_names "$c" "$spid")"; then
    findings+=("the database server's environment couldn't be read")
    env_result="not read"
  elif grep -qx CLOUVE_OPS_PASSWORD <<< "$names"; then
    findings+=("the database server's environment holds CLOUVE_OPS_PASSWORD")
    env_result="holds it"
  else
    pass "the database server's environment (pid $spid) holds no CLOUVE_OPS_PASSWORD"
    env_result="clean"
  fi

  # 4. A clean stop. 5. A sign-in after a restart.
  # The first start's temporary server already logged the line once, so only a line the stop added counts.
  lines_before="$(docker logs "$c" 2>&1 | grep -c "${SHUTDOWN_LINE[$name]}")"
  started=$SECONDS
  docker stop -t 30 "$c" >/dev/null 2>&1
  took=$((SECONDS - started))
  lines_after="$(docker logs "$c" 2>&1 | grep -c "${SHUTDOWN_LINE[$name]}")"
  if [ "$took" -lt 30 ] && [ "$lines_after" -gt "$lines_before" ]; then
    pass "docker stop ends it cleanly in ${took} s"
    stop_result="clean, ${took} s"
  else
    findings+=("docker stop took ${took} s or left no clean shutdown line ('${SHUTDOWN_LINE[$name]}')")
    stop_result="not clean, ${took} s"
  fi
  restart_result="no sign-in"
  if docker start "$c" >/dev/null 2>&1; then
    deadline=$((SECONDS + READY_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if in_db "$c" "</dev/tcp/127.0.0.1/${PORT[$name]} && </dev/tcp/127.0.0.1/22" >/dev/null 2>&1; then
        if [ "$(ssh_from_client "$c" 1 'echo ok')" = ok ]; then restart_result="signs in"; fi
        break
      fi
      sleep 2
    done
  fi
  if [ "$restart_result" = "signs in" ]; then
    pass "after a restart, clouve-ops still signs in"
  else
    findings+=("after a restart, clouve-ops doesn't sign in")
  fi

  if [ "${#findings[@]}" -eq 0 ]; then
    pass "no zombie after $SSH_SESSIONS SSH sessions; a killed background job is reaped and nothing restarts"
    verdict=PASS
  else
    for finding in "${findings[@]}"; do
      if [ "$pid1" != tini ] && is_known "$name"; then
        known "$finding (fixed when the image gets tini)"
        verdict=KNOWN
      else
        fail "$finding"
        verdict=FAIL
      fi
    done
  fi
  ROW[$name]="$pid1|$before / $after|$job_result|$env_result|$stop_result|$verdict"
  docker rm -f -v "$c" >/dev/null 2>&1
done

echo
printf '%-18s %-9s %-24s %-34s %-12s %-16s %s\n' image "PID 1" "zombies before / after" "killed background job" \
  "server env" "docker stop" verdict
for name in "${SELECTED[@]}"; do
  IFS='|' read -r p z j e st v <<< "${ROW[$name]:--|-|-|-|-|-}"
  printf '%-18s %-9s %-24s %-34s %-12s %-16s %s\n' "$name" "$p" "$z" "$j" "$e" "$st" "$v"
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sDatabase image zombie checks passed (KNOWN findings are listed above).%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sDatabase image zombie checks failed.%s\n' "$RED" "$RESET"
exit 1
