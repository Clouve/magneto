#!/bin/bash
# tests/lib/limesurvey-test-lib.sh: what the four LimeSurvey tests share (tests/limesurvey-*.test.sh).
#
# Source this file after setting PREFIX (every container, network, volume and image the test makes begins with it)
# and REPO_DIR. It defines the pass and fail helpers, the image options, and functions that start a database and a
# LimeSurvey container on a network of the test's own, with no published ports and a memory limit, and that ask the
# site questions through docker exec. It changes no shell option.
#
#   --image limesurvey=REF          use an image that is already built instead of building this checkout's
#   --image limesurvey-mariadb=REF  the same for the database image
#   --keep                          leave what the test made in place when it ends
# LS_TEST_PREFIX sets PREFIX from outside (the tests' own defaults differ, so two of them can run side by side).

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
# assert_eq <label> <expected> <actual>
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
# assert_contains <label> <text> <needle>
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
# assert_lacks <label> <text> <needle>: prints only the label when it fails, since the needle can be a secret.
assert_lacks() { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1"; fi; }

LS_APP_DIR="$REPO_DIR/apps/limesurvey"
declare -A LS_IMAGE=()
LS_BUILT=()
LS_KEEP=false
LS_MEMORY="${LS_TEST_MEMORY:-2g}"

# ls_parse_args "$@": takes --image NAME=REF and --keep; the other arguments come back in LS_ARGS.
ls_parse_args() {
  LS_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        case "${2:-}" in
          limesurvey=?* | limesurvey-mariadb=?*) LS_IMAGE[${2%%=*}]="${2#*=}" ;;
          *) echo "--image takes limesurvey=REF or limesurvey-mariadb=REF" >&2; exit 2 ;;
        esac
        shift
        ;;
      --keep) LS_KEEP=true ;;
      *) LS_ARGS+=("$1") ;;
    esac
    shift
  done
}

ls_need_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "This test needs Docker." >&2
    exit 2
  fi
}

# ls_image NAME: makes sure LS_IMAGE[NAME] names an image on this machine, building this checkout's when none was
# given. NAME is limesurvey or limesurvey-mariadb. Status 1 when the build fails or the image is missing.
ls_image() {
  local name="$1" context="$LS_APP_DIR/image" log
  [ "$name" = limesurvey-mariadb ] && context="$LS_APP_DIR/image/mariadb"
  if [ -z "${LS_IMAGE[$name]:-}" ]; then
    LS_IMAGE[$name]="${PREFIX}$name:test"
    if log="$(docker build -t "${LS_IMAGE[$name]}" "$context" 2>&1)"; then
      LS_BUILT+=("${LS_IMAGE[$name]}")
    else
      printf '%s\n' "$log" | tail -n 20 | sed 's/^/       /'
      return 1
    fi
  fi
  docker image inspect "${LS_IMAGE[$name]}" >/dev/null 2>&1
}

# ls_remove_all: removes the containers, volumes and networks whose names begin with PREFIX, and the images this run
# built. Nothing else.
ls_remove_all() {
  local name
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls -q 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker network rm "$name" >/dev/null 2>&1 ;; esac
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null)
}

# shellcheck disable=SC2329  # the EXIT trap runs it
ls_cleanup() {
  local image
  if [ "$LS_KEEP" = true ]; then
    echo "Kept everything named ${PREFIX}*"
  else
    ls_remove_all
    for image in ${LS_BUILT[@]+"${LS_BUILT[@]}"}; do docker rmi -f "$image" >/dev/null 2>&1; done
  fi
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# ls_new_disk VOLUME...: makes each volume the way a cluster makes a new disk: a top folder of root's, mode 755, with
# lost+found (root's, 700) in it and nothing else (README.md, "Volumes on a cluster").
ls_new_disk() {
  local v
  for v in "$@"; do
    docker volume create "$v" >/dev/null &&
      docker run --rm --network none -v "$v:/v" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" \
        sh -c 'chown 0:0 /v && chmod 755 /v && mkdir -m 700 /v/lost+found' || return 1
  done
}

# The site's settings, all made up. A test can change them before it starts a container.
LS_DB_PW="db-pw-4c1d9e7a"
LS_DB_ROOT_PW="root-pw-8a2f6b3c"
LS_ADMIN_PW="Admin-pw-5e7c2a91!"
LS_OPS_PW="ops-pw-d3b8f014"
LS_ADMIN_USER="Test_Admin"
LS_PUBLIC_URL="http://localhost:8080"

# ls_start_db NAME VOLUME [IMAGE]: the database container NAME on the network ${PREFIX}net and the volume VOLUME.
ls_start_db() {
  docker network inspect "${PREFIX}net" >/dev/null 2>&1 || docker network create "${PREFIX}net" >/dev/null
  docker run -d --name "$1" --network "${PREFIX}net" --memory "$LS_MEMORY" -v "$2:/var/lib/mysql" \
    -e MYSQL_DATABASE=limesurvey -e MYSQL_USER=limesurvey -e "MYSQL_PASSWORD=$LS_DB_PW" \
    -e "MYSQL_ROOT_PASSWORD=$LS_DB_ROOT_PW" "${3:-${LS_IMAGE[limesurvey-mariadb]}}" >/dev/null
}

# ls_wait_db NAME [SECONDS]: until the database answers a query from its own container as the limesurvey user.
ls_wait_db() {
  local i
  for ((i = 0; i < ${2:-120}; i++)); do
    if docker exec -e "MYSQL_PWD=$LS_DB_PW" "$1" mariadb -h 127.0.0.1 -u limesurvey limesurvey -e 'SELECT 1' \
      >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

# ls_sql DB_CONTAINER QUERY: rows of a query on the site's database, tab-separated, no header.
ls_sql() {
  docker exec -e "MYSQL_PWD=$LS_DB_PW" "$1" mariadb -h 127.0.0.1 -u limesurvey limesurvey -N -B -e "$2" 2>&1
}

# ls_start_app NAME DB_CONTAINER HTML_VOLUME UPLOAD_VOLUME IMAGE [docker run options...]: a LimeSurvey container with
# the manifest's variables. The options come before the image, so they can add or override variables.
ls_start_app() {
  local name="$1" db="$2" html="$3" upload="$4" image="$5"
  shift 5
  docker run -d --name "$name" --network "${PREFIX}net" --memory "$LS_MEMORY" \
    -v "$html:/var/www/html" -v "$upload:/var/www/html/upload" \
    -e DB_TYPE=mysql -e "DB_HOST=$db" -e DB_PORT=3306 -e DB_NAME=limesurvey -e DB_USERNAME=limesurvey \
    -e "DB_PASSWORD=$LS_DB_PW" -e "ADMIN_USER=$LS_ADMIN_USER" -e "ADMIN_NAME=Test Admin" \
    -e ADMIN_EMAIL=admin@example.invalid -e "ADMIN_PASSWORD=$LS_ADMIN_PW" -e "PUBLIC_URL=$LS_PUBLIC_URL" \
    -e INSTALL_DEMO_DATA=false "$@" "$image" >/dev/null
}

# ls_http CONTAINER PATH [curl options...]: the HTTP status of a GET on the container's own port 8080.
ls_http() {
  local c="$1" path="$2"
  shift 2
  docker exec "$c" curl -s -o /dev/null -m 20 -w '%{http_code}' "$@" "http://127.0.0.1:8080$path" 2>/dev/null
}

# ls_pid1 CONTAINER: the name of the container's PID 1.
ls_pid1() { docker exec "$1" cat /proc/1/comm 2>/dev/null; }

# ls_running CONTAINER: whether the container runs.
ls_running() { [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# ls_wait_apache CONTAINER [SECONDS]: 0 once Apache is PID 1 and GET / answers 200; 2 when the container stopped
# first; 1 when the time ran out.
ls_wait_apache() {
  local i
  for ((i = 0; i < ${2:-300}; i++)); do
    if [ "$(ls_pid1 "$1")" = apache2 ] && [ "$(ls_http "$1" /)" = 200 ]; then return 0; fi
    ls_running "$1" || return 2
    sleep 1
  done
  return 1
}

# ls_wait_log CONTAINER TEXT [SECONDS]: 0 once the container's log holds TEXT; 2 when the container stopped without
# it; 1 when the time ran out.
ls_wait_log() {
  local i
  for ((i = 0; i < ${3:-300}; i++)); do
    if docker logs "$1" 2>&1 | grep -qF -- "$2"; then return 0; fi
    ls_running "$1" || { docker logs "$1" 2>&1 | grep -qF -- "$2" && return 0; return 2; }
    sleep 1
  done
  return 1
}

# ls_wait_hold CONTAINER [SECONDS]: 0 once the container says that it waits for a repair (it could not start
# LimeSurvey, and stays up with its stand-in page and its sshd); 2 when it stopped first; 1 when the time ran out.
ls_wait_hold() {
  ls_wait_log "$1" "The container stays up so that the site can be repaired: the page says" "${2:-300}"
}

# ls_assert_hold LABEL CONTAINER: what holds of a start that waits for a repair: the container runs, its PID 1 is
# still the entrypoint, Apache never started, the page says that the site needs attention, and the log has the
# line that staff alert on.
ls_assert_hold() {
  local label="$1" c="$2" log
  log="$(docker logs "$c" 2>&1)"
  assert_eq "$label: the container keeps running, and its PID 1 is still the entrypoint" "true entrypoint.sh" \
    "$(docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null) $(ls_pid1 "$c")"
  assert_lacks "$label: Apache never started" "$log" "starting Apache"
  assert_contains "$label: the page says that the site needs attention" \
    "$(docker exec "$c" curl -s -m 10 http://127.0.0.1:8080/ 2>/dev/null)" "LimeSurvey needs attention from Clouve support"
  assert_eq "$label: the health check answers 200, and everything else 503" "200 503" \
    "$(ls_http "$c" /) $(ls_http "$c" /index.php/admin/authentication/sa/login)"
  assert_contains "$label: the log has the line that staff alert on" "$log" "[clouve-upgrade] FAILED limesurvey "
}

# ls_assert_note LABEL CONTAINER KIND: the note a waiting container leaves for the AI Assistant, which can't read the
# container's log: clouve/needs-attention, root's, mode 600, with five key=value lines, the same keys as the
# SuiteCRM image's note. KIND is repair or restore. For repair, the reason and the two versions are the ones of the
# [clouve-upgrade] FAILED line.
ls_assert_note() {
  local label="$1" c="$2" kind="$3" note file=/var/www/html/clouve/needs-attention
  note="$(docker exec "$c" cat "$file" 2>&1)"
  assert_eq "$label: the note clouve/needs-attention is root's, mode 600" "root 600" "$(docker exec "$c" stat -c '%U %a' "$file" 2>&1)"
  assert_eq "$label: it has five lines: reason, since (in UTC), from, to and kind=$kind" "reason since from to kind / kind=$kind / 1" \
    "$(cut -d= -f1 <<< "$note" | xargs) / $(tail -n 1 <<< "$note") / $(grep -cE '^since=20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<< "$note")"
  if [ "$kind" = repair ]; then
    assert_contains "$label: its reason and its versions are the FAILED line's" "$(docker logs "$c" 2>&1)" \
      "[clouve-upgrade] FAILED limesurvey $(sed -n 's/^from=//p' <<< "$note") -> $(sed -n 's/^to=//p' <<< "$note"): $(sed -n 's/^reason=//p' <<< "$note")"
  fi
}

# ls_wait_exit CONTAINER [SECONDS]: 0 once the container has stopped; prints its exit code.
ls_wait_exit() {
  local i
  for ((i = 0; i < ${2:-300}; i++)); do
    if ! ls_running "$1"; then docker inspect --format '{{.State.ExitCode}}' "$1" 2>/dev/null; return 0; fi
    sleep 1
  done
  return 1
}

# ls_code_version CONTAINER: "<versionnumber> <dbversionnumber>" of the code on the volume, read as www-data.
ls_code_version() {
  # shellcheck disable=SC2016  # PHP code
  docker exec -u www-data "$1" php -r '$c = include "/var/www/html/application/config/version.php";
    echo $c["versionnumber"], " ", $c["dbversionnumber"];' 2>/dev/null
}

# ls_db_version DB_CONTAINER: DBVersion in the site's database.
ls_db_version() { ls_sql "$1" "SELECT stg_value FROM lime_settings_global WHERE stg_name='DBVersion'"; }

# ls_db_sum DB_CONTAINER [EXCLUDE_REGEX]: "<tables> <checksum>" of the site's database: how many tables it has and a
# SHA-256 over MariaDB's own checksum of every table's rows. Two databases with the same answer hold the same tables
# with the same rows. Tables whose names match EXCLUDE_REGEX are left out of both numbers.
ls_db_sum() {
  local sums
  sums="$(ls_db_sums "$@")" || { echo "error"; return 1; }
  if [ -z "$sums" ]; then echo "0 none"; return 0; fi
  printf '%s %s\n' "$(grep -c . <<< "$sums")" "$(sha256sum <<< "$sums" | cut -c1-16)"
}

# ls_db_sums DB_CONTAINER [EXCLUDE_REGEX]: one line for each table, with MariaDB's checksum of its rows. For a test
# that wants to say which tables differ.
ls_db_sums() {
  local db="$1" skip="${2:-^$}" names sql="" t
  names="$(ls_sql "$db" "SELECT table_name FROM information_schema.tables WHERE table_schema = 'limesurvey'
    AND table_type = 'BASE TABLE' AND table_name NOT REGEXP '$skip' ORDER BY table_name")" || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    sql="$sql${sql:+, }\`$t\`"
  done <<< "$names"
  [ -n "$sql" ] || return 0
  ls_sql "$db" "CHECKSUM TABLE $sql"
}

# ls_db_made DB_CONTAINER: when the newest of LimeSurvey's tables in the site's database was made, and how many
# there are. A database whose tables were dropped and loaded again gives another answer, even when the rows are the
# same. The SuiteCRM plugin's own two tables are left out: at a start, configure-suitecrm-plugin.sh brings a table
# of mappings that the earlier image made to the plugin's current shape, whichever LimeSurvey runs, and that
# ALTER TABLE gives the table a new creation time. ls_db_sum still covers their rows.
ls_db_made() {
  ls_sql "$1" "SELECT CONCAT(COUNT(*), ' tables, newest made ', MAX(create_time)) FROM information_schema.tables
    WHERE table_schema = 'limesurvey' AND table_type = 'BASE TABLE' AND table_name NOT IN ('lime_survey_crm_mappings', 'lime_survey_crm_sync_log')"
}

# The tables a start of a working site writes to (the plugin's settings, sessions, sign-in attempts), for ls_db_sum.
LS_VOLATILE_TABLES='^lime_(plugins|plugin_settings|settings_global|sessions|failed_login_attempts|notifications)$'

# ls_secrets_in TEXT: how many of the made-up passwords TEXT holds.
ls_secrets_in() {
  local n=0 s
  for s in "$LS_DB_PW" "$LS_DB_ROOT_PW" "$LS_ADMIN_PW" "$LS_OPS_PW" ${LS_EXTRA_SECRETS[@]+"${LS_EXTRA_SECRETS[@]}"}; do
    [[ "$1" == *"$s"* ]] && n=$((n + 1))
  done
  echo "$n"
}

# ls_watch_ps CONTAINER FILE: samples the container's process list (every process's full command line, read from
# /proc as root) into FILE about ten times a second, until the file FILE.stop exists. Run it in the background.
ls_watch_ps() {
  # shellcheck disable=SC2016  # the script is for the sh in the container
  while [ ! -e "$2.stop" ]; do
    docker exec -u root "$1" sh -c 'for f in /proc/[0-9]*/cmdline; do tr "\0" " " < "$f" 2>/dev/null; echo; done' \
      >> "$2" 2>/dev/null
    sleep 0.1
  done
}

# ls_ssh_whoami CONTAINER PASSWORD: what `id -un` prints for clouve-ops signed in over SSH with PASSWORD, from inside
# the container. Nothing when the sign-in fails.
ls_ssh_whoami() {
  # shellcheck disable=SC2016  # the script is for the bash in the container
  docker exec -e "T_PW=$2" "$1" bash -c '
    d="$(mktemp -d)"; printf "#!/bin/sh\nprintf \"%%s\\n\" \"\$T_PW\"\n" > "$d/askpass"; chmod 700 "$d/askpass"
    SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 30 ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      clouve-ops@127.0.0.1 id -un </dev/null 2>/dev/null; rm -rf "$d"'
}
