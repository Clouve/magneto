#!/bin/bash

# ============================================================================
# Nextcloud database image test
# ============================================================================
# apps/nextcloud/image/mariadb is MariaDB 12.3 with Nextcloud's settings
# (nextcloud.cnf), an InnoDB buffer pool sized from the container's memory
# limit at every start (clouve-entrypoint.sh), and the clouve-ops sshd that
# the AI Assistant logs in to (start-clouve-ops-sshd.sh).
#
# The test builds the image and starts it three times: with a 512 MiB limit,
# with a 2 GiB limit and CLOUVE_OPS_PASSWORD set, and with no limit. Once each
# database answers, it checks from inside the container:
#   - the settings Nextcloud needs: READ-COMMITTED, ROW binlog format, utf8mb4
#     with the utf8mb4_bin collation, a file per table, a 256 MiB redo log,
#     200 connections and no name resolution;
#   - the buffer pool: a quarter of the limit, so 128 MiB, 512 MiB and, with
#     no limit, 256 MiB;
#   - MariaDB 12.3, and MARIADB_AUTO_UPGRADE=1 set in the image (a later
#     manifest can't reach a running deployment, only a new image can);
#   - the clouve-ops channel: sshd listens when CLOUVE_OPS_PASSWORD is set;
#     when it is unset, the log says so and the database starts anyway; and
#     clouve-ops has passwordless sudo;
#   - the clouve-ops password stays out of mariadbd's environment, and
#     clouve-ops still logs in over SSH with it (a wrong one is refused).
#
# A host runs one cgroup version and the wrapper has to read both, so the test
# also runs the wrapper alone (no database starts) on made-up cgroup trees,
# passed in with NC_CGROUP_ROOT: v2 and v1 layouts from 64 MiB to 64 GiB, the
# "no limit" value of each, a limit that isn't a whole number of MiB, numbers
# too big for a 64-bit integer, files that are empty or hold junk or a negative
# number, and a tree with neither file. One more run uses a read-only root
# filesystem, where the wrapper can't write its file and must still start the
# command.
#
# Needs Docker. The build pulls mariadb:12.3 and runs apt-get against the
# Ubuntu mirrors, like the other apps' database images. Every container the
# test starts is named nc-t1-*. The containers, their volumes and the image are
# removed when it exits.
#
# Usage: bash tests/nextcloud-mariadb.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="$REPO_DIR/apps/nextcloud/image/mariadb"
IMAGE="clouve-test/nextcloud-mariadb:test"
PREFIX="nc-t1-"    # every container this test starts begins with this
MEMORY_CNF="/etc/mysql/conf.d/zz-clouve-memory.cnf"
WAIT_SECONDS=120

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
# assert_contains <label> <text> <needle>
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then
    pass "$1"
  else
    fail "$1"
    printf '       wanted: %q\n' "$3"
  fi
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

# Removes the containers named nc-t1-* (and their volumes), nothing else.
remove_test_containers() {
  local name
  while IFS= read -r name; do
    case "$name" in
      "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;;
    esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}

WORK=""
cleanup() {
  remove_test_containers
  docker rmi -f "$IMAGE" >/dev/null 2>&1
  if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remove_test_containers    # leftovers of a run that was killed
WORK="$(mktemp -d)"
chmod 755 "$WORK"

# --- build -------------------------------------------------------------------
echo "Nextcloud database image"
if build_log="$(docker build --platform linux/amd64 -t "$IMAGE" "$IMAGE_DIR" 2>&1)"; then
  pass "image builds ($IMAGE)"
else
  fail "image builds ($IMAGE)"
  printf '%s\n' "$build_log" | tail -n 15 | sed 's/^/       /'
  echo
  printf '%sNextcloud database image checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi

# --- start the three databases ------------------------------------------------
# start_db <name> [docker run options...]: starts nc-t1-<name>.
start_db() {
  local name="$1"
  shift
  docker run -d --name "$PREFIX$name" \
    -e MARIADB_DATABASE=nextcloud -e MARIADB_USER=nextcloud \
    -e MARIADB_PASSWORD=pw -e MARIADB_ROOT_PASSWORD=rootpw \
    "$@" "$IMAGE" >/dev/null
}

start_db 512m --memory 512m || fail "512m: container starts"
start_db 2g --memory 2g -e CLOUVE_OPS_PASSWORD=opspw || fail "2g: container starts"
start_db none || fail "none: container starts"

# While the databases start up: the wrapper alone, on made-up cgroup trees.
echo
echo "Buffer pool from made-up cgroup trees (the wrapper alone, NC_CGROUP_ROOT)"
CG_COUNT=0
# cg_case <label> <MB wanted> <memory.max> <memory/memory.limit_in_bytes>
# Runs the image with `cat` of the file the wrapper writes as its command, so
# the wrapper runs and no database starts. "-" means the tree has no such file.
cg_case() {
  local label="$1" want="$2" v2="$3" v1="$4" dir got
  CG_COUNT=$((CG_COUNT + 1))
  dir="$WORK/cgroup$CG_COUNT"
  mkdir -p "$dir"
  if [[ "$v2" != "-" ]]; then printf '%s\n' "$v2" > "$dir/memory.max"; fi
  if [[ "$v1" != "-" ]]; then
    mkdir -p "$dir/memory"
    printf '%s\n' "$v1" > "$dir/memory/memory.limit_in_bytes"
  fi
  got="$(docker run --rm --network none --name "${PREFIX}cgroup$CG_COUNT" \
           -e NC_CGROUP_ROOT=/fake-cgroup -v "$dir:/fake-cgroup:ro" \
           "$IMAGE" cat "$MEMORY_CNF" 2>/dev/null | sed -n '/^\[mysqld\]$/,$p')"
  assert_eq "$label: ${want}M" "$(printf '[mysqld]\ninnodb_buffer_pool_size = %sM' "$want")" "$got"
}

#       label                                    MB   memory.max (v2)  memory.limit_in_bytes (v1)
cg_case "v2, 64 MiB (floor of 128)"             128   67108864         -
cg_case "v2, 512 MiB"                            128   536870912        -
cg_case "v2, 1 GiB"                              256   1073741824       -
cg_case "v2, 2 GiB"                              512   2147483648       -
cg_case "v2, 16 GiB (top of the range)"         4096   17179869184      -
cg_case "v2, 64 GiB (capped)"                   4096   68719476736      -
cg_case "v2, 1000000000 bytes (rounds down)"     238   1000000000       -
cg_case "v2, max (no limit)"                     256   max              -
cg_case "v1, 64 MiB (floor of 128)"             128   -                67108864
cg_case "v1, 512 MiB"                            128   -                536870912
cg_case "v1, 1 GiB"                              256   -                1073741824
cg_case "v1, 2 GiB"                              512   -                2147483648
cg_case "v1, 16 GiB (top of the range)"         4096   -                17179869184
cg_case "v1, 64 GiB (capped)"                   4096   -                68719476736
cg_case "v1, kernel's no limit (2^63 - 4096)"    256   -                9223372036854771712
cg_case "v1, 2^60 (no limit)"                    256   -                1152921504606846976
cg_case "v1, 2^60 - 1 (a limit, capped)"        4096   -                1152921504606846975
cg_case "v1, 20 digits (no limit, no overflow)"  256   -                18446744073709551615
cg_case "v2 file present: v1 is not read"        256   max              2147483648
cg_case "v2 and v1 both set: v2 wins"            256   1073741824       2147483648
cg_case "neither file (no limit)"                256   -                -
cg_case "v2 holds junk (no limit)"               256   abc              -
cg_case "v2 empty (no limit)"                    256   ''               -
cg_case "v2 holds a negative number (no limit)"  256   -1               -
cg_case "v1 holds junk (no limit)"               256   -                abc

# A pool that can't be sized must not stop the database from starting: on a
# read-only root filesystem the wrapper can't write its file, says so on
# stderr, and still runs the command.
ro_out="$(docker run --rm --network none --name "${PREFIX}readonly" --read-only "$IMAGE" echo started 2>"$WORK/readonly.err")"
ro_status=$?
assert_eq "unwritable file: the command still runs" "started" "$ro_out"
assert_eq "unwritable file: exit status" "0" "$ro_status"
assert_contains "unwritable file: the wrapper says so on stderr" "$(cat "$WORK/readonly.err")" \
  "WARNING: could not write $MEMORY_CNF"

# --- wait for the databases ---------------------------------------------------
# wait_ready <name>: 0 when the server answers, 1 after WAIT_SECONDS, 2 when the container stopped.
wait_ready() {
  local c="$PREFIX$1" i
  for ((i = 0; i < WAIT_SECONDS; i++)); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]]; then
      return 2
    fi
    if docker exec "$c" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo
echo "Databases (512 MiB limit, 2 GiB limit, no limit)"
for name in 512m 2g none; do
  started=$SECONDS
  wait_ready "$name"
  rc=$?
  case "$rc" in
    0) pass "$name: database is ready after $((SECONDS - started)) s" ;;
    2) fail "$name: the container stopped before the database was ready" ;;
    *) fail "$name: the database was not ready within $WAIT_SECONDS s" ;;
  esac
  if [[ "$rc" -ne 0 ]]; then
    docker logs --tail 15 "$PREFIX$name" 2>&1 | sed 's/^/       /'
  fi
done

# sql <name> <statement>: runs it as root inside nc-t1-<name> and prints the value it returns.
sql() { docker exec "$PREFIX$1" mariadb -uroot -prootpw -N -e "$2" 2>&1; }

# expect_var <variable> <value>: every container reports this value for the global variable.
expect_var() {
  local name
  for name in 512m 2g none; do
    assert_eq "$name: $1 is $2" "$2" "$(sql "$name" "SELECT @@global.$1")"
  done
}

# expect_pool <name> <bytes>: InnoDB's buffer pool has this size.
expect_pool() {
  assert_eq "$1: innodb_buffer_pool_size is $2" "$2" "$(sql "$1" 'SELECT @@global.innodb_buffer_pool_size')"
}

# expect_version_prefix <prefix>: every container runs a server whose version starts with this.
expect_version_prefix() {
  local name got
  for name in 512m 2g none; do
    got="$(sql "$name" 'SELECT VERSION()')"
    if [[ "$got" == "$1"* ]]; then pass "$name: server version starts with $1 ($got)"; else
      fail "$name: server version starts with $1"
      printf '       actual: %q\n' "$got"
    fi
  done
}

# expect_env_in_image <NAME> <value>: the image itself sets this variable.
expect_env_in_image() {
  local env
  env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" 2>&1)"
  if grep -qxF -- "$1=$2" <<< "$env"; then pass "image sets $1=$2"; else
    fail "image sets $1=$2"
    printf '       image has: %q\n' "$(grep -- "^$1=" <<< "$env")"
  fi
}

# expect_sshd_listening <name>: something listens on port 22 inside the container (sshd takes a moment).
expect_sshd_listening() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec "$PREFIX$1" bash -c '</dev/tcp/127.0.0.1/22' >/dev/null 2>&1; then
      pass "$1: sshd listens on port 22"
      return
    fi
    sleep 1
  done
  fail "$1: sshd listens on port 22"
}

# expect_log_contains <name> <text>: the container's log (stdout and stderr) holds this text.
expect_log_contains() {
  assert_contains "$1: log says '$2'" "$(docker logs "$PREFIX$1" 2>&1)" "$2"
}

# expect_clouve_ops_sudoers <name>: clouve-ops has passwordless sudo through a root-owned mode 440 file.
expect_clouve_ops_sudoers() {
  local file=/etc/sudoers.d/clouve-ops
  assert_eq "$1: $file content" 'clouve-ops ALL=(ALL) NOPASSWD: ALL' "$(docker exec "$PREFIX$1" cat "$file" 2>&1)"
  assert_eq "$1: $file is mode 440, root:root" '440 root:root' "$(docker exec "$PREFIX$1" stat -c '%a %U:%G' "$file" 2>&1)"
  assert_eq "$1: clouve-ops runs commands as root with sudo -n" '0' "$(docker exec -u clouve-ops "$PREFIX$1" sudo -n id -u 2>&1)"
}

# ssh_as_clouve_ops <name> <password> <command>: runs the command as clouve-ops
# over SSH to 127.0.0.1 inside nc-t1-<name> and prints what it prints, or
# nothing when the login fails. The image has ssh but not sshpass, so an
# askpass script hands ssh the password, which it reads from its environment.
ssh_as_clouve_ops() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "NC_TEST_PW=$2" "$PREFIX$1" bash -c '
    d="$(mktemp -d)" || exit 1
    cat > "$d/askpass" <<"EOF"
#!/bin/sh
printf "%s\n" "$NC_TEST_PW"
EOF
    chmod 700 "$d/askpass"
    SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 20 ssh \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 clouve-ops@127.0.0.1 "$1" </dev/null 2>/dev/null
    rc=$?
    rm -rf "$d"
    exit "$rc"' _ "$3"
}

# expect_ops_password_dropped <name> <password>: mariadbd's environment holds
# no CLOUVE_OPS_PASSWORD, and clouve-ops still logs in with the password, which
# the sshd kit took before the wrapper dropped it. mariadbd runs as mysql, and
# root in a container has no CAP_SYS_PTRACE, so only mysql can read
# /proc/<pid>/environ: the test reads it as mysql, and MARIADB_DATABASE shows
# that the read worked.
expect_ops_password_dropped() {
  local names
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  names="$(docker exec -u mysql "$PREFIX$1" sh -c '
    for p in /proc/[0-9]*; do
      if [ "$(cat "$p/comm" 2>/dev/null)" = mariadbd ]; then tr "\0" "\n" < "$p/environ" | cut -d= -f1; exit; fi
    done' 2>&1)"
  assert_contains "$1: mariadbd's environment can be read (it has MARIADB_DATABASE)" "$names" MARIADB_DATABASE
  if grep -qx CLOUVE_OPS_PASSWORD <<< "$names"; then
    fail "$1: mariadbd's environment has no CLOUVE_OPS_PASSWORD"
  else
    pass "$1: mariadbd's environment has no CLOUVE_OPS_PASSWORD"
  fi
  assert_eq "$1: clouve-ops logs in over SSH with the password" clouve-ops "$(ssh_as_clouve_ops "$1" "$2" 'id -un')"
  assert_eq "$1: a wrong password is refused" '' "$(ssh_as_clouve_ops "$1" "not-$2" 'id -un')"
}

# expect_memory_cnf <name> <MB>: the file the wrapper wrote holds exactly this.
expect_memory_cnf() {
  assert_eq "$1: $MEMORY_CNF holds ${2}M" "$(printf '[mysqld]\ninnodb_buffer_pool_size = %sM' "$2")" \
    "$(docker exec "$PREFIX$1" cat "$MEMORY_CNF" 2>&1)"
}

expect_var transaction_isolation READ-COMMITTED
expect_var binlog_format ROW
expect_var character_set_server utf8mb4
expect_var collation_server utf8mb4_bin
expect_var innodb_file_per_table 1
expect_var innodb_log_file_size 268435456
expect_var max_connections 200
expect_var skip_name_resolve 1
expect_pool 512m 134217728
expect_pool 2g   536870912
expect_pool none 268435456
expect_memory_cnf 512m 128
expect_memory_cnf 2g 512
expect_memory_cnf none 256
expect_version_prefix 12.3.
expect_env_in_image MARIADB_AUTO_UPGRADE 1
assert_eq "image ENTRYPOINT and CMD" '["/usr/local/bin/clouve-entrypoint.sh"] ["mariadbd"]' \
  "$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$IMAGE" 2>&1)"
expect_sshd_listening 2g
expect_log_contains none 'CLOUVE_OPS_PASSWORD is unset'
expect_clouve_ops_sudoers 2g
expect_ops_password_dropped 2g opspw

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '%sAll Nextcloud database image checks passed.%s\n' "$GREEN" "$RESET"
else
  printf '%sNextcloud database image checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi
