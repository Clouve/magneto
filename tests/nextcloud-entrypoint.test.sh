#!/bin/bash

# ============================================================================
# Nextcloud entrypoint test
# ============================================================================
# apps/nextcloud/image/installer/entrypoint.sh runs as root and stays PID 1
# until it hands over to the official entrypoint. Its first steps run before
# the database answers, and nothing else tests them where they run: in the
# built image, as PID 1. This test starts that image with no network and a
# database host that can't resolve, so the entrypoint waits for the database
# (step 6) and stays there, and checks what it did up to that point:
#   - step 0, the second run of itself: /proc/1/environ, which the AI
#     Assistant reads, holds the cleaned admin login (Jose_Garcia for
#     José_García) and the decoded email (o'brien@... for o&apos;brien@...),
#     once each. The first run logs the login once, and the second run passes
#     its marker variable on to nothing it starts;
#   - step 1: before the first install (no version.php on the volume), what
#     the entrypoint starts gets MYSQL_HOST, MYSQL_DATABASE, MYSQL_USER and
#     MYSQL_PASSWORD, copied from NEXTCLOUD_DB_*. On a later start (version.php
#     there) it gets none of them, and NEXTCLOUD_ADMIN_PASSWORD isn't needed;
#   - step 1 again: a first start without NEXTCLOUD_ADMIN_PASSWORD exits 1 and
#     says why, without printing any value, and leaves the volume empty. A
#     version.php left there would make every later start skip the install;
#   - step 4: a restore marker in data/clouve-backups, a folder only root can
#     enter, gets a warning and a note in /run/clouve that www-data, which
#     runs the hooks, can see. Once the marker is gone, the next start removes
#     the note, which a docker restart would otherwise keep;
#   - steps 4 and 5: no CLOUVE_OPS_PASSWORD in Valkey's environment. www-data
#     (valkey-server's user) can read /proc/<pid>/environ of valkey-server,
#     but Valkey writes its process title over that memory as it starts, so
#     the test also reads the environment Valkey is started with, that of
#     start-valkey.sh and runuser, as root. Of root's processes, /proc shows it
#     only for PID 1 and its own subshells (which share the environment PID 1
#     started with), so nothing PID 1 starts after the sshd has it. (sshd
#     inherited it from the kit too, but like Valkey it writes its process
#     title over that memory.) clouve-ops still logs in over SSH with the
#     password, and a wrong one is refused.
# No check prints a password: the test compares them inside its own shell.
#
# The image is r.clv.zone/e2eorg/nextcloud, which ./build.sh nextcloud builds
# (NC_TEST_IMAGE names another). The test first checks that the image's
# installer folder, hooks and persona match this checkout, and stops if they
# don't, so it never passes against an old build. Nothing here needs the
# network. Every container and volume it makes is named nc-tf-ep-*, and it
# removes them when it exits.
#
# Usage: bash tests/nextcloud-entrypoint.test.sh
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker
# or without the image.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="$REPO_DIR/apps/nextcloud/image"
IMAGE="${NC_TEST_IMAGE:-r.clv.zone/e2eorg/nextcloud:latest}"
PREFIX="nc-tf-ep-"    # every container and volume this test makes begins with this
WAIT_SECONDS=90

# Made-up secrets for the containers. The test fails if any of them shows in what a container prints.
DB_PW="db-pw-3f9a1c0e"
ADMIN_PW="admin-pw-7d2e4b19"
OPS_PW="ops-pw-c81f5a62"
# A name that never resolves. With --network none no name does, and .invalid is reserved for that.
DB_HOST="nc-tf-ep-db.invalid"

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
  if [[ "$2" == *"$3"* ]]; then
    pass "$1"
  else
    fail "$1"
    printf '       wanted: %q\n' "$3"
  fi
}
# assert_lacks <label> <text> <needle>: prints only the label when it fails, since the needle can be a secret.
assert_lacks() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1"; fi
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "This test needs the image $IMAGE. Build it with ./build.sh nextcloud (or name another with NC_TEST_IMAGE)." >&2
  exit 2
fi

# Removes the containers and volumes named nc-tf-ep-*, and nothing else.
remove_test_resources() {
  local name
  while IFS= read -r name; do
    case "$name" in
      "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;;
    esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in
      "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;;
    esac
  done < <(docker volume ls -q 2>/dev/null)
}
trap remove_test_resources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_resources    # leftovers of a run that was killed

# --- the image matches this checkout -------------------------------------------
echo "Nextcloud entrypoint ($IMAGE)"
# shellcheck disable=SC2016  # the script is for the sh inside the container
# Both sides sort in the C locale: the host's locale and the image's would order some names differently.
in_image="$(docker run --rm --name "${PREFIX}sums" --network none --entrypoint sh "$IMAGE" -c '
  cd /clouve/nextcloud/installer && find . -type f | LC_ALL=C sort | xargs sha256sum
  cd /docker-entrypoint-hooks.d && find . -name 10-clouve.sh | LC_ALL=C sort | xargs sha256sum
  cd /clouve/context && find . -type f | LC_ALL=C sort | xargs sha256sum' 2>&1)"
in_tree="$( (cd "$IMAGE_DIR/installer" && find . -type f | LC_ALL=C sort | xargs sha256sum
             cd "$IMAGE_DIR/installer/hooks" && find . -name 10-clouve.sh | LC_ALL=C sort | xargs sha256sum
             cd "$IMAGE_DIR/context" && find . -type f | LC_ALL=C sort | xargs sha256sum) 2>&1)"
if [[ -n "$in_tree" && "$in_image" == "$in_tree" ]]; then
  pass "the image's installer, hooks and persona are this checkout's"
else
  fail "the image's installer, hooks and persona are this checkout's: rebuild it with ./build.sh nextcloud"
  diff <(printf '%s\n' "$in_tree") <(printf '%s\n' "$in_image") | sed 's/^/       /' | head -n 20
  echo
  printf '%sNextcloud entrypoint checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi
# The official entrypoint opens its init lock as root. With `9>` a symlink that www-data put there would make root create
# or truncate any file, so the build changes it to `9<`, a read-only open.
# shellcheck disable=SC2016  # the script is for the sh inside the container
lock_opens="$(docker run --rm --name "${PREFIX}lockopen" --network none --entrypoint sh "$IMAGE" -c '
  grep -c ") 9< /var/www/html/nextcloud-init-sync.lock\$" /entrypoint.sh
  grep -c "9> */var/www/html/nextcloud-init-sync.lock" /entrypoint.sh' 2>&1)"
if [[ "$lock_opens" == $'1\n0' ]]; then
  pass "the official entrypoint opens its init lock read-only (9<), and nowhere with 9>"
else
  fail "the official entrypoint should open its init lock read-only (9<) once and never with 9> (got: $(tr '\n' ' ' <<<"$lock_opens"))"
fi
# It also reads the volume's version.php, PHP that www-data can change. The build makes it run that file as www-data,
# through upstream's own run_as, as it runs occ (installer/patch-official-entrypoint.sh).
# shellcheck disable=SC2016  # the script is for the sh inside the container
version_reads="$(docker run --rm --name "${PREFIX}verread" --network none --entrypoint sh "$IMAGE" -c '
  grep -cF "installed_version=\"\$(run_as '"'"'php -d display_errors=stderr -r " /entrypoint.sh
  grep -cF "installed_version=\"\$(php -r " /entrypoint.sh' 2>&1)"
if [[ "$version_reads" == $'1\n0' ]]; then
  pass "the official entrypoint reads the volume's version.php as www-data (run_as), never as root"
else
  fail "the official entrypoint should read version.php through run_as once and never as root (got: $(tr '\n' ' ' <<<"$version_reads"))"
fi

# --- helpers --------------------------------------------------------------------
# start_nc <name> <admin user> [docker run options...]: starts nc-tf-ep-<name> on the volume nc-tf-ep-<name>, with the
# database settings, the admin's email and the clouve-ops password. The options add the rest (NEXTCLOUD_ADMIN_PASSWORD).
start_nc() {
  local name="$1" admin="$2"
  shift 2
  docker run -d --name "$PREFIX$name" --network none -v "$PREFIX$name:/var/www/html" \
    -e "NEXTCLOUD_DB_HOST=$DB_HOST" -e NEXTCLOUD_DB_NAME=nextcloud -e NEXTCLOUD_DB_USER=nextcloud \
    -e "NEXTCLOUD_DB_PASSWORD=$DB_PW" -e NEXTCLOUD_URL=http://localhost:8080 \
    -e "NEXTCLOUD_ADMIN_USER=$admin" -e 'NEXTCLOUD_ADMIN_EMAIL=o&apos;brien@example.com' \
    -e "CLOUVE_OPS_PASSWORD=$OPS_PW" "$@" "$IMAGE" >/dev/null
}

# wait_for_db_wait <name> [<count>]: 0 once the entrypoint has logged <count> times (1 when not given) that it waits for
# the database, 2 when the container stopped first, 1 after WAIT_SECONDS. A container that Docker restarted keeps the
# log of its earlier start, so the second start's wait is the second line.
wait_for_db_wait() {
  local c="$PREFIX$1" want="${2:-1}" i
  for ((i = 0; i < WAIT_SECONDS; i++)); do
    if [[ "$(docker logs "$c" 2>&1 | grep -cF "waiting for the database at $DB_HOST")" -ge "$want" ]]; then
      return 0
    fi
    if [[ "$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]]; then
      return 2
    fi
    sleep 1
  done
  return 1
}

# parked <name> [<count>]: waits for the database wait (the <count>th, as wait_for_db_wait) and records whether it came.
parked() {
  local rc
  wait_for_db_wait "$1" "${2:-1}"
  rc=$?
  case "$rc" in
    0) pass "$1: the entrypoint got as far as its wait for the database, and waits there" ;;
    2) fail "$1: the container stopped before the wait for the database" ;;
    *) fail "$1: no wait for the database within $WAIT_SECONDS s" ;;
  esac
  if [[ "$rc" -ne 0 ]]; then
    docker logs --tail 15 "$PREFIX$1" 2>&1 | sed 's/^/       /'
    return 1
  fi
}

# pid1_env <name>: the environment PID 1 was started with, one VAR=value per line. It holds the test's made-up
# secrets, so it is only ever compared, never printed.
pid1_env() { docker exec "$PREFIX$1" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null; }

# child_env <name>: the environment of what PID 1 starts while it waits for the database: its `sleep 5` between two
# tries. That process starts after every step before the wait, so it has what the official entrypoint would get.
# shellcheck disable=SC2016  # the script is for the sh inside the container
child_env() {
  docker exec "$PREFIX$1" sh -c '
    for try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = sleep ] || continue
        [ "$(sed -n "s/^PPid:[[:space:]]*//p" "$p/status" 2>/dev/null)" = 1 ] || continue
        tr "\0" "\n" < "$p/environ" 2>/dev/null && exit 0
      done
      sleep 0.3
    done
    exit 1' 2>/dev/null
}

# value_of <env text> <NAME>: the value of NAME in VAR=value lines (the first one), or nothing.
value_of() { sed -n "s/^$2=//p" <<<"$1" | head -n 1; }

# count_of <env text> <NAME>: how many lines set NAME.
count_of() { grep -c "^$2=" <<<"$1"; }

# valkey_environ <name>: valkey-server's /proc/<pid>/environ read as www-data, its user: "bytes=N" (how much it could
# read), then the names of the variables in it, one per line. Valkey writes its process title over that memory as it
# starts, so the names are gone. proc_env reads the environment it was started with.
# shellcheck disable=SC2016  # the script is for the sh inside the container
valkey_environ() {
  docker exec -u www-data "$PREFIX$1" sh -c '
    for p in /proc/[0-9]*; do
      if [ "$(cat "$p/comm" 2>/dev/null)" = valkey-server ]; then
        echo "bytes=$(wc -c < "$p/environ")"
        tr "\0" "\n" < "$p/environ" | grep "=" | cut -d= -f1
        exit 0
      fi
    done
    echo "no valkey-server"' 2>&1
}

# proc_env <name> <comm>: the environment of the first process with this command name, read as root (so only root's
# processes), one VAR=value per line. Compared, never printed.
# shellcheck disable=SC2016  # the script is for the sh inside the container
proc_env() {
  docker exec -e "NC_TEST_COMM=$2" "$PREFIX$1" sh -c '
    for p in /proc/[0-9]*; do
      if [ "$(cat "$p/comm" 2>/dev/null)" = "$NC_TEST_COMM" ]; then tr "\0" "\n" < "$p/environ"; exit 0; fi
    done
    exit 1' 2>/dev/null
}

# expect_valkey_env <name> <MYSQL_* wanted, yes or no>: what www-data can read of valkey-server's environment, and the
# environment of the two root processes that start it (start-valkey.sh, then runuser), which is the one Valkey got.
expect_valkey_env() {
  local out bytes envs envr want
  out="$(valkey_environ "$1")"
  bytes="$(sed -n 's/^bytes=//p' <<<"$out")"
  if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
    pass "$1: www-data can read valkey-server's /proc/<pid>/environ ($bytes bytes)"
  else
    fail "$1: www-data can read valkey-server's /proc/<pid>/environ"
    printf '       got: %q\n' "$out"
  fi
  if grep -qx CLOUVE_OPS_PASSWORD <<<"$out"; then
    fail "$1: and it holds no CLOUVE_OPS_PASSWORD"
  else
    pass "$1: and it holds no CLOUVE_OPS_PASSWORD"
  fi
  envs="$(proc_env "$1" start-valkey.sh)"
  envr="$(proc_env "$1" runuser)"
  assert_eq "$1: start-valkey.sh and runuser, which start valkey-server, have NEXTCLOUD_DB_NAME (the read worked)" \
    "nextcloud nextcloud" "$(value_of "$envs" NEXTCLOUD_DB_NAME) $(value_of "$envr" NEXTCLOUD_DB_NAME)"
  assert_eq "$1: but not CLOUVE_OPS_PASSWORD, so Valkey was started without it" "0 0" \
    "$(count_of "$envs" CLOUVE_OPS_PASSWORD) $(count_of "$envr" CLOUVE_OPS_PASSWORD)"
  if [[ "$2" == yes ]]; then want="1 1"; else want="0 0"; fi
  assert_eq "$1: MYSQL_HOST in their environment: $2" "$want" "$(count_of "$envs" MYSQL_HOST) $(count_of "$envr" MYSQL_HOST)"
}

# holders_of <name> <VAR>: which running processes have VAR in their environment, one per line and each once: "1" for
# PID 1 and its own subshells (a fork shares the environment PID 1 started with, whatever PID 1 has unset since; their
# command name is entrypoint.sh), and the command name for any other. It reads as root, which may read the environment
# of root's processes only (root in a container has no CAP_SYS_PTRACE). Processes started by docker exec get the
# container's configured environment, which has VAR, so the ones this check starts (marked with NC_TEST_VAR) are left out.
# shellcheck disable=SC2016  # the script is for the sh inside the container
holders_of() {
  docker exec -e "NC_TEST_VAR=$2" "$PREFIX$1" sh -c '
    for p in /proc/[0-9]*; do
      env="$(tr "\0" "\n" < "$p/environ" 2>/dev/null)" || continue
      case "$env" in *NC_TEST_VAR=*) continue ;; esac
      if printf "%s\n" "$env" | grep -q "^$NC_TEST_VAR="; then
        comm="$(cat "$p/comm" 2>/dev/null)"
        if [ "${p#/proc/}" = 1 ] || [ "$comm" = entrypoint.sh ]; then echo 1; else echo "$comm"; fi
      fi
    done | sort -u' 2>/dev/null
}

# expect_holders <name> <VAR> <expected>: holders_of gives the expected list. A process that lives for a moment (an SSH
# session ending, the sshd kit's ssh-keygen) can be caught in it, so it asks up to 10 times, a second apart. sshd itself
# never shows up: like valkey-server, it writes its process title over the memory /proc/<pid>/environ reads.
expect_holders() {
  local got i
  for ((i = 0; i < 10; i++)); do
    got="$(holders_of "$1" "$2")"
    if [[ "$got" == "$3" ]]; then break; fi
    sleep 1
  done
  assert_eq "$1: of root's processes, only PID 1 and its own subshells (the environment PID 1 started with) show $2" "$3" "$got"
}

# expect_sshd <name>: sshd listens on port 22 (it makes its host keys first, which takes a moment).
expect_sshd() {
  local i
  for ((i = 0; i < 30; i++)); do
    if docker exec "$PREFIX$1" bash -c '</dev/tcp/127.0.0.1/22' >/dev/null 2>&1; then
      pass "$1: sshd listens on port 22"
      return 0
    fi
    sleep 1
  done
  fail "$1: sshd listens on port 22"
}

# ssh_as_clouve_ops <name> <password> <command>: runs the command as clouve-ops over SSH to 127.0.0.1 inside
# nc-tf-ep-<name> and prints what it prints, or nothing when the login fails. The image has ssh but not sshpass, so an
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

# note_exists <name>: yes or no, whether the root entrypoint's restore note, /run/clouve/restore-cut-off, is there.
note_exists() {
  docker exec "$PREFIX$1" sh -c 'if [ -e /run/clouve/restore-cut-off ]; then echo yes; else echo no; fi' 2>&1
}

# no_secret_in_logs <name>: none of the made-up secrets is in what the container printed.
no_secret_in_logs() {
  local logs
  logs="$(docker logs "$PREFIX$1" 2>&1)"
  assert_lacks "$1: the log holds no database password" "$logs" "$DB_PW"
  assert_lacks "$1: the log holds no admin password" "$logs" "$ADMIN_PW"
  assert_lacks "$1: the log holds no clouve-ops password" "$logs" "$OPS_PW"
}

# --- 1. the first start: an empty volume -----------------------------------------
echo
echo "The first start (empty volume, raw admin name José_García)"
start_nc first 'José_García' -e "NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PW" || fail "first: the container starts"
if parked first; then
  env1="$(pid1_env first)"
  assert_eq "first: /proc/1/environ has the cleaned admin login" "Jose_Garcia" "$(value_of "$env1" NEXTCLOUD_ADMIN_USER)"
  assert_eq "first: /proc/1/environ has the decoded admin email" "o'brien@example.com" "$(value_of "$env1" NEXTCLOUD_ADMIN_EMAIL)"
  assert_eq "first: /proc/1/environ sets each of the two once" "1 1" \
    "$(count_of "$env1" NEXTCLOUD_ADMIN_USER) $(count_of "$env1" NEXTCLOUD_ADMIN_EMAIL)"
  assert_eq "first: PID 1 is the entrypoint, with its argument" \
    "/bin/bash /clouve/nextcloud/installer/entrypoint.sh apache2-foreground" \
    "$(docker exec "${PREFIX}first" sh -c 'tr "\0" " " < /proc/1/cmdline' 2>/dev/null | sed 's/ $//')"
  assert_eq "first: the first run logs the cleaned login once" "1" \
    "$(docker logs "${PREFIX}first" 2>&1 | grep -cxF '[nextcloud] admin login: Jose_Garcia')"

  envc="$(child_env first)"
  if [[ -n "$envc" ]]; then
    pass "first: the environment of what PID 1 starts in the wait can be read (its sleep)"
  else
    fail "first: the environment of what PID 1 starts in the wait can be read (its sleep)"
  fi
  assert_eq "first: what PID 1 starts gets MYSQL_HOST, MYSQL_DATABASE and MYSQL_USER from NEXTCLOUD_DB_*" \
    "$DB_HOST nextcloud nextcloud" \
    "$(value_of "$envc" MYSQL_HOST) $(value_of "$envc" MYSQL_DATABASE) $(value_of "$envc" MYSQL_USER)"
  if [[ "$(value_of "$envc" MYSQL_PASSWORD)" == "$DB_PW" ]]; then same=yes; else same=no; fi
  assert_eq "first: and MYSQL_PASSWORD, which is NEXTCLOUD_DB_PASSWORD" yes "$same"
  assert_eq "first: and the cleaned login" "Jose_Garcia" "$(value_of "$envc" NEXTCLOUD_ADMIN_USER)"
  assert_eq "first: but not the second run's marker variable" "0" "$(count_of "$envc" CLV_NC_ENTRYPOINT_REEXEC)"
  assert_eq "first: and not CLOUVE_OPS_PASSWORD, which leaves once the sshd kit has it" "0" "$(count_of "$envc" CLOUVE_OPS_PASSWORD)"

  expect_valkey_env first yes
  expect_sshd first
  assert_eq "first: clouve-ops logs in over SSH with the password" clouve-ops "$(ssh_as_clouve_ops first "$OPS_PW" 'id -un')"
  assert_eq "first: a wrong password is refused" '' "$(ssh_as_clouve_ops first "not-$OPS_PW" 'id -un')"
  expect_holders first CLOUVE_OPS_PASSWORD 1
  no_secret_in_logs first
fi

# --- 2. a later start: version.php is on the volume ---------------------------------
echo
echo "A later start (version.php on the volume, no NEXTCLOUD_ADMIN_PASSWORD, raw admin name Anne_O&apos;Brien)"
if docker run --rm --name "${PREFIX}seed" --network none -v "${PREFIX}later:/var/www/html" --entrypoint cp "$IMAGE" \
     /usr/src/nextcloud/version.php /var/www/html/version.php >/dev/null 2>&1; then
  pass "later: the volume holds version.php"
else
  fail "later: the volume holds version.php"
fi
start_nc later 'Anne_O&apos;Brien' || fail "later: the container starts"
if parked later; then
  env1="$(pid1_env later)"
  assert_eq "later: /proc/1/environ has the cleaned admin login" "Anne_O'Brien" "$(value_of "$env1" NEXTCLOUD_ADMIN_USER)"
  assert_lacks "later: no complaint about the missing admin password" "$(docker logs "${PREFIX}later" 2>&1)" "NEXTCLOUD_ADMIN_PASSWORD is not set"
  envc="$(child_env later)"
  if [[ -n "$envc" ]]; then
    pass "later: the environment of what PID 1 starts in the wait can be read (its sleep)"
  else
    fail "later: the environment of what PID 1 starts in the wait can be read (its sleep)"
  fi
  assert_eq "later: what PID 1 starts gets no MYSQL_* copies" "0 0 0 0" \
    "$(count_of "$envc" MYSQL_HOST) $(count_of "$envc" MYSQL_DATABASE) $(count_of "$envc" MYSQL_USER) $(count_of "$envc" MYSQL_PASSWORD)"
  assert_eq "later: but it has NEXTCLOUD_DB_NAME" "nextcloud" "$(value_of "$envc" NEXTCLOUD_DB_NAME)"
  expect_valkey_env later no
  assert_eq "later: no restore marker, so no restore note in /run/clouve" no "$(note_exists later)"
  no_secret_in_logs later
fi

# --- 3. a later start after a restore that was cut off ------------------------------------
# The AI Assistant's restore.sh keeps RESTORE-IN-PROGRESS in data/clouve-backups, a folder only root can enter, while it
# works. The hooks run as www-data, so step 4 notes the marker in /run/clouve, where they can see it.
echo
echo "A later start after a restore that was cut off (its marker in a root-only data/clouve-backups)"
# shellcheck disable=SC2016  # the script is for the sh inside the container
if docker run --rm --name "${PREFIX}seed-restore" --network none -v "${PREFIX}restore:/var/www/html" --entrypoint sh "$IMAGE" -c '
     cp /usr/src/nextcloud/version.php /var/www/html/version.php &&
     install -d -o www-data -g www-data /var/www/html/data &&
     install -d -o root -g root -m 700 /var/www/html/data/clouve-backups &&
     printf "20261024-101500\n" > /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS &&
     chmod 600 /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS' >/dev/null 2>&1; then
  pass "restore: the volume holds version.php and a restore marker in a folder that only root can enter"
else
  fail "restore: the volume holds version.php and a restore marker in a folder that only root can enter"
fi
start_nc restore 'admin' || fail "restore: the container starts"
if parked restore; then
  assert_contains "restore: the log says that a restore was cut off" "$(docker logs "${PREFIX}restore" 2>&1)" \
    "[nextcloud] WARNING: A restore was cut off: /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS is there."
  assert_eq "restore: www-data, which runs the hooks, can't see the marker itself" no \
    "$(docker exec -u www-data "${PREFIX}restore" sh -c 'if [ -e /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS ]; then echo yes; else echo no; fi' 2>&1)"
  assert_eq "restore: so root wrote the note, root's and readable by all" "root:root 644" \
    "$(docker exec "${PREFIX}restore" stat -c '%U:%G %a' /run/clouve/restore-cut-off 2>&1)"
  assert_eq "restore: and www-data sees through it that a restore was cut off (nc_restore_cut_off, as the hooks ask)" yes \
    "$(docker exec -u www-data "${PREFIX}restore" bash -c '. /clouve/nextcloud/installer/lib.sh && if nc_restore_cut_off; then echo yes; else echo no; fi' 2>&1)"
  # The restore is finished or undone, and the container restarts. Docker keeps /run across a restart, so the note from
  # the start before is still there until step 4 removes it.
  docker exec "${PREFIX}restore" rm -f /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
  docker restart -t 1 "${PREFIX}restore" >/dev/null 2>&1 || fail "restore: docker restart"
  if parked restore 2; then
    assert_eq "restore: after the marker is gone and Docker restarts the container, the old note is gone too" no "$(note_exists restore)"
    assert_eq "restore: and www-data sees no restore" no \
      "$(docker exec -u www-data "${PREFIX}restore" bash -c '. /clouve/nextcloud/installer/lib.sh && if nc_restore_cut_off; then echo yes; else echo no; fi' 2>&1)"
  fi
  no_secret_in_logs restore
fi

# --- 4. a first start without the admin password -------------------------------------
echo
echo "A first start without NEXTCLOUD_ADMIN_PASSWORD (empty volume)"
started=$SECONDS
nopw_out="$(timeout 120 docker run --name "${PREFIX}nopw" --network none -v "${PREFIX}nopw:/var/www/html" \
  -e "NEXTCLOUD_DB_HOST=$DB_HOST" -e NEXTCLOUD_DB_NAME=nextcloud -e NEXTCLOUD_DB_USER=nextcloud \
  -e "NEXTCLOUD_DB_PASSWORD=$DB_PW" -e NEXTCLOUD_URL=http://localhost:8080 \
  -e 'NEXTCLOUD_ADMIN_USER=José_García' -e 'NEXTCLOUD_ADMIN_EMAIL=o&apos;brien@example.com' \
  -e "CLOUVE_OPS_PASSWORD=$OPS_PW" "$IMAGE" 2>&1)"
nopw_rc=$?
assert_eq "nopw: exit status 1" 1 "$nopw_rc"
if [[ $((SECONDS - started)) -lt 60 ]]; then pass "nopw: it stops at once, not after the wait for the database"; else
  fail "nopw: it stops at once, not after the wait for the database (took $((SECONDS - started)) s)"; fi
assert_contains "nopw: it says why" "$nopw_out" "[nextcloud] ERROR: NEXTCLOUD_ADMIN_PASSWORD is not set, so the first install cannot run"
assert_lacks "nopw: it never waits for the database" "$nopw_out" "waiting for the database"
assert_lacks "nopw: it starts no Valkey" "$nopw_out" "Valkey answers"
assert_lacks "nopw: no database password in what it printed" "$nopw_out" "$DB_PW"
assert_lacks "nopw: no clouve-ops password in what it printed" "$nopw_out" "$OPS_PW"
assert_eq "nopw: the volume is still empty, with no version.php" "" \
  "$(docker run --rm --name "${PREFIX}nopw-ls" --network none -v "${PREFIX}nopw:/v" --entrypoint ls "$IMAGE" -A /v 2>&1)"

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '%sAll Nextcloud entrypoint checks passed.%s\n' "$GREEN" "$RESET"
else
  printf '%sNextcloud entrypoint checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi
