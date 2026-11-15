#!/bin/bash

# ============================================================================
# SuiteCRM entrypoint test: a new install, its restarts and what runs afterwards
# ============================================================================
# Starts the SuiteCRM image and its database image on volumes shaped like new
# cluster disks (root's top folder, mode 755, lost+found, none of the image's
# files) and checks what apps/suitecrm/image/installer/entrypoint.sh does.
# Every password here is made up, and no check prints one.
#
# wait      The entrypoint waits for a database that never answers. PID 1's
#           environment already holds SUITECRM_DB_HOST, _PORT, _NAME, _USER and
#           _PASSWORD (the AI Assistant reads it as soon as sshd answers), the
#           clouve-ops sshd answers, the stand-in answers the health check
#           with its own header, the volume's top folder is www-data's with
#           nothing new in it, Apache's worker limit follows the memory limit,
#           the stand-in's environment holds no password, a stop request ends
#           the wait within seconds with a clean status, and a start without
#           DATABASE_PASSWORD stops and names the variable.
# refuse    A new disk and a database that already has tables: the container
#           stops, says why, and changes neither the database nor the volume.
#           SuiteCRM's installer would drop that database.
# install   A new install at the Customer Kit's size (1 GB). While it runs, a
#           stand-in that is not Apache and not root answers GET / and HEAD /
#           with 200 and everything else with 503 and Retry-After, each with
#           the header X-Clouve-Standin: suitecrm, sshd answers, and the
#           install-in-progress stamp is there. Afterwards Apache is PID 1 on
#           the same port with no stand-in left, no password was on a command
#           line, in the container's log or in SuiteCRM's own install logs,
#           config_si.php is gone, every file is www-data's with upstream's
#           modes, the settings files and the OAuth2 key are closed to others,
#           the admin signs in with a password full of quotes, PHP under Apache
#           finds no CLOUVE_OPS_PASSWORD, SuiteCRM's settings switch the
#           scheduler on, the scheduler and the Messenger worker run as
#           www-data under Apache and come back when they exit, the session
#           cookie is Secure behind a forwarded HTTPS header, PHP sees the
#           client's address from a private peer's X-Forwarded-For and ignores
#           the header from any other peer, the access log has neither a query
#           string nor a Referer, and no PHP file in an upload folder is run
#           or served.
# restart   The same volumes with a new site address and a new database
#           password: public/legacy/config.php and .env.local follow the
#           environment, nothing is installed again, and SuiteCRM answers.
# cut-off   An install that is killed before it finishes: the next start clears
#           it and installs again. A stamp next to a database that people have
#           worked in is refused: nothing is cleared and nothing dropped.
# demo      SUITECRM_INSTALL_DEMO_DATA=yes installs the demo records.
# password  A database password with a blank, @, :, /, %, # and both quotes:
#           SuiteCRM's two configurations both reach the database, at the
#           install and after a restart.
# address   A SUITECRM_URL that is not an address: the start says so and
#           leaves the address SuiteCRM has.
# empty-db  SuiteCRM on the volume and a database without tables: Apache is
#           not started, the log says that the database is empty, and the
#           container waits with the stand-in and the sshd up.
#
# --image NAME=REF uses an image that is already built (suitecrm,
# suitecrm-mariadb); otherwise the test builds it and removes it at the end.
# Naming cases limits the run. Everything the test makes is named sc-t-ep-*
# (SUITECRM_TEST_PREFIX changes the sc-t- part), runs on networks with no way
# out and no published port, and is removed at the end unless --keep is given.
# Needs Docker. About 10 minutes.
#
# Usage: bash tests/suitecrm-entrypoint.test.sh [--image NAME=REF]... [--keep] [CASE...]
#   CASE  wait, refuse, install, restart, cut-off, demo, password, address or empty-db
#         (default: all; restart, address and empty-db need install)
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suitecrm-test-lib.sh
. "$SCRIPT_DIR/lib/suitecrm-test-lib.sh"
SC_PREFIX="${SC_PREFIX}ep-"
VERSION=8.10.2

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" | sed '$d' >&2
  exit 2
}
CASES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image) sc_parse_image_option "${2:-}" || usage; shift ;;
    --keep) SC_KEEP=true ;;
    wait|refuse|install|restart|cut-off|demo|password|address|empty-db) CASES+=("$1") ;;
    *) usage ;;
  esac
  shift
done
[ "${#CASES[@]}" -gt 0 ] || CASES=(wait refuse install restart cut-off demo password address empty-db)
wants() { local c; for c in "${CASES[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

sc_need_docker
trap sc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sc_remove_resources    # leftovers of a run that was killed

echo "SuiteCRM entrypoint"
if ! sc_image suitecrm || ! sc_image suitecrm-mariadb; then
  fail "the images build or are on this machine"
  exit 1
fi
APP_IMAGE="${SC_IMAGE[suitecrm]}"
DB_IMAGE="${SC_IMAGE[suitecrm-mariadb]}"

# Made-up secrets. The admin's has a space, both quotes, a $ and a backslash: the installer has to get it whole.
rand() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
DB_PW="db-pw-$(rand)"
DB_PW2="db-pw2-$(rand)"
ROOT_PW="root-pw-$(rand)"
OPS_PW="ops-pw-$(rand)"
ADMIN_PW="Adm1n -'q\"\$x\\y $(rand)"
ADMIN_USER="admin@example.test"
SECRETS=("$DB_PW" "$DB_PW2" "$ROOT_PW" "$OPS_PW" "$ADMIN_PW")

NET="${SC_PREFIX}net"
PUB="${SC_PREFIX}pub"
DB="${SC_PREFIX}db"
docker network create --internal "$NET" >/dev/null
# A network whose addresses are not private ones (TEST-NET-2), for a peer Apache must not trust.
docker network create --internal --subnet 198.51.100.0/24 "$PUB" >/dev/null

# start_db: the database container, on a new disk.
start_db() {
  sc_new_disk "${SC_PREFIX}dbdata"
  docker run -d --name "$DB" --network "$NET" --memory 1g -v "${SC_PREFIX}dbdata:/var/lib/mysql" \
    -e MYSQL_DATABASE=suitecrm -e MYSQL_USER=suitecrm -e "MYSQL_PASSWORD=$DB_PW" -e "MYSQL_ROOT_PASSWORD=$ROOT_PW" \
    "$DB_IMAGE" >/dev/null
  sc_wait_for 180 docker exec "$DB" healthcheck.sh --connect --innodb_initialized
}
# extra_database NAME: one more database the app's user owns, so each case installs into its own.
extra_database() {
  sc_sql "$DB" mysql "CREATE DATABASE \`$1\`; GRANT ALL PRIVILEGES ON \`$1\`.* TO 'suitecrm'@'%';"
}
# start_app NAME VOLUME DATABASE [docker run options...]: an app container on VOLUME.
start_app() {
  local name="$1" volume="$2" database="$3"
  shift 3
  docker run -d --name "$name" --network "$NET" --memory 1g -v "$volume:/var/www/html" \
    -e "DATABASE_HOST=$DB" -e DATABASE_PORT=3306 -e "DATABASE_NAME=$database" -e DATABASE_USER=suitecrm \
    -e "DATABASE_PASSWORD=$DB_PW" -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_USER=$ADMIN_USER" \
    -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e SUITECRM_INSTALL_DEMO_DATA=no -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
    "$@" "$APP_IMAGE" >/dev/null
}
# in_app CONTAINER SCRIPT: runs a bash script in the container as root.
in_app() { docker exec "$1" bash -c "$2" 2>&1; }
# ops_signs_in CONTAINER: what `id -un` prints over SSH as clouve-ops, signed in with the password.
ops_signs_in() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "T_PW=$OPS_PW" "$1" bash -c '
    d="$(mktemp -d)"; printf "#!/bin/sh\nprintf \"%%s\\n\" \"\$T_PW\"\n" > "$d/askpass"; chmod 700 "$d/askpass"
    SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 30 ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      clouve-ops@127.0.0.1 id -un </dev/null 2>/dev/null; rm -rf "$d"'
}
# admin_signs_in CONTAINER PASSWORD: what POST /login answers for the admin.
admin_signs_in() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "T_U=$ADMIN_USER" -e "T_P=$2" "$1" bash -c '
    J="$(mktemp)"; B="$(mktemp)"; trap "rm -f \"$J\" \"$B\"" EXIT
    curl -s -o /dev/null -c "$J" http://127.0.0.1/
    curl -s -o /dev/null -b "$J" -c "$J" http://127.0.0.1/session-status
    X="$(awk "\$6==\"XSRF-TOKEN\"{print \$7}" "$J")"
    php -r "echo json_encode([\"username\" => getenv(\"T_U\"), \"password\" => getenv(\"T_P\")]);" > "$B"
    curl -s -b "$J" -c "$J" -H "Content-Type: application/json" -H "X-XSRF-TOKEN: $X" --data-binary "@$B" \
      http://127.0.0.1/login' 2>/dev/null
}
# env_of_pid1 CONTAINER NAME: the value NAME has in PID 1's environment, or nothing.
env_of_pid1() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec -e "T_NAME=$2" "$1" sh -c 'tr "\0" "\n" < /proc/1/environ | sed -n "s/^$T_NAME=//p"'
}
# wait_installed CONTAINER SECONDS: 0 once Apache is PID 1 and SuiteCRM says it is installed.
wait_installed() {
  local deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sc_apache_serves "$1" && return 0
    sc_running "$1" || return 2
    sleep 2
  done
  return 1
}
show_log() { docker logs --tail "${2:-25}" "$1" 2>&1 | sed 's/^/       | /'; }

# --- wait ------------------------------------------------------------------------
if wants wait; then
  echo
  echo "wait: before the database answers"
  A="${SC_PREFIX}wait"
  sc_new_disk "${SC_PREFIX}wait-data"
  # No database container is on this network, so the name never resolves.
  docker run -d --name "$A" --network "$NET" --memory 1g -v "${SC_PREFIX}wait-data:/var/www/html" \
    -e "DATABASE_HOST=${SC_PREFIX}nodb" -e DATABASE_NAME=suitecrm -e DATABASE_USER=crmuser \
    -e "DATABASE_PASSWORD=$DB_PW" -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_USER=$ADMIN_USER" \
    -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e "CLOUVE_OPS_PASSWORD=$OPS_PW" "$APP_IMAGE" >/dev/null
  if sc_wait_log "$A" "waiting for the database at ${SC_PREFIX}nodb:3306" 60; then
    pass "the entrypoint waits for the database"
  else
    fail "the entrypoint waits for the database"
    show_log "$A"
  fi
  assert_eq "PID 1's environment has SUITECRM_DB_HOST" "${SC_PREFIX}nodb" "$(env_of_pid1 "$A" SUITECRM_DB_HOST)"
  assert_eq "PID 1's environment has SUITECRM_DB_PORT" "3306" "$(env_of_pid1 "$A" SUITECRM_DB_PORT)"
  assert_eq "PID 1's environment has SUITECRM_DB_NAME" "suitecrm" "$(env_of_pid1 "$A" SUITECRM_DB_NAME)"
  assert_eq "PID 1's environment has SUITECRM_DB_USER" "crmuser" "$(env_of_pid1 "$A" SUITECRM_DB_USER)"
  if [ "$(env_of_pid1 "$A" SUITECRM_DB_PASSWORD)" = "$DB_PW" ]; then
    pass "PID 1's environment has SUITECRM_DB_PASSWORD, the database password"
  else
    fail "PID 1's environment has SUITECRM_DB_PASSWORD, the database password"
  fi
  assert_eq "and no helper variable of the entrypoint's own" "" \
    "$(in_app "$A" 'tr "\0" "\n" < /proc/1/environ | grep -c "^CLV_SC_" | grep -v "^0$"')"
  if sc_wait_for 30 docker exec "$A" bash -c '</dev/tcp/127.0.0.1/22'; then
    pass "the clouve-ops sshd answers while the entrypoint still waits"
  else
    fail "the clouve-ops sshd answers while the entrypoint still waits"
  fi
  assert_eq "clouve-ops signs in with the password" "clouve-ops" "$(ops_signs_in "$A")"
  assert_eq "the stand-in answers the health check while the entrypoint waits" "200 200 503" \
    "$(sc_http "$A" /) $(sc_http "$A" / -I) $(sc_http "$A" /session-status)"
  assert_contains "and names itself in a header, so nothing takes it for SuiteCRM" \
    "$(docker exec "$A" curl -s -D - -o /dev/null http://127.0.0.1/ 2>/dev/null | tr -d '\r')" "X-Clouve-Standin: suitecrm"
  assert_eq "the new disk's top folder is www-data's, and nothing else is in it yet" "www-data lost+found" \
    "$(in_app "$A" 'echo "$(stat -c %U /var/www/html) $(ls -A /var/www/html | tr "\n" " " | sed "s/ $//")"')"
  assert_eq "lost+found stays root's" "root 700" "$(in_app "$A" 'stat -c "%U %a" /var/www/html/lost+found')"
  assert_eq "at 1 GB Apache gets 6 workers" "ServerLimit 6 MaxRequestWorkers 6" \
    "$(in_app "$A" 'grep -E "^\s*(ServerLimit|MaxRequestWorkers)" /etc/apache2/conf-enabled/zz-clouve-mpm.conf | xargs')"
  assert_eq "no password is in the log" "0" "$(sc_count_secrets_in_log "$A" "${SECRETS[@]}")"
  # The stand-in answers the network as nobody and needs no password. Root can read another user's environment
  # only with a privilege a container doesn't have, so this one exec asks for it.
  assert_eq "the stand-in's environment holds no password and no variable at all" "0" \
    "$(docker exec --privileged "$A" bash -c 'tr "\0" "\n" < "/proc/$(pgrep -f -- "-S 0.0.0.0:80" | head -n 1)/environ" | grep -c .')"
  began=$SECONDS
  docker stop -t 60 "$A" >/dev/null
  took=$((SECONDS - began))
  if [ "$took" -le 12 ]; then pass "a stop request ends the wait for the database in $took s"; else fail "a stop request ends the wait for the database promptly (it took $took s)"; fi
  assert_eq "with a clean status" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$A")"
  assert_contains "and the log says that it was asked to stop" "$(docker logs "$A" 2>&1)" "asked to stop"
  docker rm -f -v "$A" >/dev/null 2>&1

  docker run -d --name "$A" --network "$NET" --memory 2g -v "${SC_PREFIX}wait-data:/var/www/html" \
    -e "DATABASE_HOST=${SC_PREFIX}nodb" -e DATABASE_NAME=suitecrm -e DATABASE_USER=crmuser \
    -e "DATABASE_PASSWORD=$DB_PW" -e SUITECRM_URL=https://crm.example.test "$APP_IMAGE" >/dev/null
  sc_wait_log "$A" "waiting for the database at" 60
  assert_eq "at 2 GB Apache gets 17 workers" "ServerLimit 17 MaxRequestWorkers 17" \
    "$(in_app "$A" 'grep -E "^\s*(ServerLimit|MaxRequestWorkers)" /etc/apache2/conf-enabled/zz-clouve-mpm.conf | xargs')"
  assert_eq "without CLOUVE_OPS_PASSWORD there is no sshd" "0" "$(in_app "$A" 'pgrep -c sshd')"
  docker rm -f -v "$A" >/dev/null 2>&1

  docker run -d --name "$A" --network "$NET" --memory 1g -v "${SC_PREFIX}wait-data:/var/www/html" \
    -e "DATABASE_HOST=${SC_PREFIX}nodb" -e DATABASE_NAME=suitecrm -e DATABASE_USER=crmuser \
    -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" "$APP_IMAGE" >/dev/null
  sc_wait_for 30 bash -c "! [ \"\$(docker inspect --format '{{.State.Running}}' $A)\" = true ]"
  assert_eq "a start without DATABASE_PASSWORD stops with status 1" "false 1" \
    "$(docker inspect --format '{{.State.Running}} {{.State.ExitCode}}' "$A")"
  assert_contains "and names the variable" "$(docker logs "$A" 2>&1)" "DATABASE_PASSWORD is not set"
  assert_eq "without printing a password" "0" "$(sc_count_secrets_in_log "$A" "${SECRETS[@]}")"
  docker rm -f -v "$A" >/dev/null 2>&1
fi

if wants refuse || wants install || wants restart || wants cut-off || wants demo || wants password || wants address || wants empty-db; then
  echo
  if start_db; then pass "the database starts on a new disk"; else fail "the database starts on a new disk"; show_log "$DB"; fi
fi

# --- refuse ----------------------------------------------------------------------
if wants refuse; then
  echo
  echo "refuse: a new disk, and a database that already has tables"
  A="${SC_PREFIX}refuse"
  extra_database crm_kept
  sc_sql "$DB" crm_kept "CREATE TABLE accounts (id INT PRIMARY KEY, name VARCHAR(50)); INSERT INTO accounts VALUES (1, 'kept');"
  sc_new_disk "${SC_PREFIX}refuse-data"
  start_app "$A" "${SC_PREFIX}refuse-data" crm_kept
  sc_wait_for 90 bash -c "! [ \"\$(docker inspect --format '{{.State.Running}}' $A)\" = true ]"
  assert_eq "the container stops with a failing status" "false 1" \
    "$(docker inspect --format '{{.State.Running}} {{.State.ExitCode}}' "$A")"
  log="$(docker logs "$A" 2>&1)"
  assert_contains "the log says the database already has tables" "$log" "already has 1 table"
  assert_contains "and that nothing was installed" "$log" "not installing"
  assert_eq "the table and its row are still there" "kept" "$(sc_sql "$DB" crm_kept "SELECT name FROM accounts WHERE id = 1")"
  assert_eq "the volume holds nothing new" "lost+found" \
    "$(docker run --rm --network none -v "${SC_PREFIX}refuse-data:/v:ro" "$SC_SHAPER" ls -A /v | tr '\n' ' ' | sed 's/ $//')"
  docker rm -f -v "$A" >/dev/null 2>&1
fi

# --- install ---------------------------------------------------------------------
A="${SC_PREFIX}app"
if wants install; then
  echo
  echo "install: a new install on a new disk, at 1 GB"
  sc_new_disk "${SC_PREFIX}data"
  started=$SECONDS
  start_app "$A" "${SC_PREFIX}data" suitecrm -e CLOUVE_TEST_PAUSE=install:20
  sc_watch_cmdlines "$A" /root/cmdlines.log 150
  if sc_wait_log "$A" "test pause at install" 120; then
    pass "the install reaches the test's pause"
  else
    fail "the install reaches the test's pause"
    show_log "$A"
  fi
  # While the install runs: the stand-in, sshd and the stamp.
  assert_eq "the stand-in answers GET / with 200" "200" "$(sc_http "$A" /)"
  assert_contains "with a page that says what is going on" \
    "$(docker exec "$A" curl -s http://127.0.0.1/ 2>/dev/null)" "SuiteCRM is starting"
  assert_eq "it answers HEAD / with 200 too, as Docker's own health check asks" "200" "$(sc_http "$A" / -I)"
  assert_eq "it answers an API call with 503" "503" "$(sc_http "$A" /Api/access_token -X POST)"
  headers="$(docker exec "$A" curl -s -D - -o /dev/null -X POST http://127.0.0.1/Api/access_token 2>/dev/null | tr -d '\r')"
  assert_contains "and tells the caller to come back" "$headers" "Retry-After: 30"
  assert_contains "the 503 carries the stand-in's header" "$headers" "X-Clouve-Standin: suitecrm"
  assert_contains "and so does the page" \
    "$(docker exec "$A" curl -s -D - -o /dev/null http://127.0.0.1/ 2>/dev/null | tr -d '\r')" "X-Clouve-Standin: suitecrm"
  assert_eq "it answers every other path with 503" "503 503 503" \
    "$(sc_http "$A" /index.php) $(sc_http "$A" '/?x=1') $(sc_http "$A" /session-status)"
  assert_eq "the stand-in is PHP's built-in server, not Apache, and not root" "nobody" \
    "$(in_app "$A" 'ps -eo user:20,args | awk "/ -S 0\.0\.0\.0:80 /{print \$1}" | sort -u')"
  assert_eq "PID 1 is still the entrypoint" "entrypoint.sh" "$(sc_pid1 "$A")"
  assert_eq "clouve-ops signs in during the install" "clouve-ops" "$(ops_signs_in "$A")"
  assert_eq "the install-in-progress stamp is there, root's and closed" "root 600" \
    "$(in_app "$A" 'stat -c "%U %a" /var/www/html/.clouve-install-in-progress')"

  if wait_installed "$A" 300; then
    pass "SuiteCRM is installed and Apache (PID 1) serves it, $((SECONDS - started)) s after the container started (20 s of that is the pause)"
  else
    fail "SuiteCRM is installed and Apache (PID 1) serves it within 300 s"
    show_log "$A" 40
  fi
  sc_watch_stop "$A" /root/cmdlines.log
  log="$(docker logs "$A" 2>&1)"
  assert_eq "no stand-in is left once Apache serves" "0" "$(in_app "$A" 'pgrep -fc -- "-S 0.0.0.0:80"')"
  assert_eq "and Apache's answers don't carry the stand-in's header" "0" \
    "$(docker exec "$A" curl -s -D - -o /dev/null http://127.0.0.1/ 2>/dev/null | grep -ci 'X-Clouve-Standin')"
  if [ "$(grep -n 'the stand-in has stopped' <<< "$log" | head -n 1 | cut -d: -f1)" -lt \
       "$(grep -n 'starting Apache' <<< "$log" | head -n 1 | cut -d: -f1)" ] 2>/dev/null; then
    pass "the stand-in stopped before Apache started"
  else
    fail "the stand-in stopped before Apache started"
  fi
  assert_eq "the installed version is $VERSION, in VERSION and in the database" "$VERSION $VERSION" \
    "$(in_app "$A" 'cat /var/www/html/VERSION') $(sc_sql "$DB" suitecrm "SELECT value FROM config WHERE category='info' AND name='suitecrm_version'")"
  assert_eq "the stamp is gone" "gone" "$(in_app "$A" '[ -e /var/www/html/.clouve-install-in-progress ] || echo gone')"
  assert_eq "config_si.php is gone" "" "$(in_app "$A" 'find /var/www/html -name config_si.php -not -path "*/vendor/*"')"
  assert_eq "every file is www-data's, lost+found aside" "0" \
    "$(in_app "$A" 'cd /var/www/html && find . -path ./lost+found -prune -o ! -user www-data -print | wc -l')"
  assert_eq "the files have upstream's modes: folders 2755, files 0644, bin/console 0755" "2755 2755 2755 2755 644 644 755" \
    "$(in_app "$A" 'cd /var/www/html && stat -c %a bin vendor config public/legacy/modules VERSION composer.json bin/console | xargs')"
  assert_eq "the settings files are closed to others" "0" \
    "$(in_app "$A" 'cd /var/www/html && find .env.local public/legacy/config.php public/legacy/config_override.php -perm /o=rwx 2>/dev/null | wc -l')"
  assert_eq "the OAuth2 keys are there, mode 600" "600 600" \
    "$(in_app "$A" 'cd /var/www/html/public/legacy/Api/V8/OAuth2 && stat -c %a private.key public.key | xargs')"
  assert_eq "www-data is an allowed cron user" "www-data" \
    "$(in_app "$A" 'cd /var/www/html/public/legacy && runuser -u www-data -- php -r "include \"config.php\"; if (is_file(\"config_override.php\")) { include \"config_override.php\"; } echo implode(\",\", \$sugar_config[\"cron\"][\"allowed_cron_users\"]);"')"
  assert_eq "no demo records were installed" "0" "$(sc_sql "$DB" suitecrm "SELECT COUNT(*) FROM accounts")"
  assert_eq "no password was on a command line during the install" "0" \
    "$(sc_count_secrets_in "$A" /root/cmdlines.log "${SECRETS[@]}")"
  assert_contains "the watcher saw the installer run" "$(in_app "$A" 'sort -u /root/cmdlines.log')" "bin/console"
  echo "       command lines seen during the install (php, the database client and the stand-in):"
  in_app "$A" 'sort -u /root/cmdlines.log | grep -E "^(php|mysql|mariadb|setpriv|bash -c umask)" | cut -c1-150' | sed 's/^/       | /'
  assert_eq "no password is in the container's log" "0" "$(sc_count_secrets_in_log "$A" "${SECRETS[@]}")"
  in_app "$A" 'cd /var/www/html && cat logs/install.log public/legacy/install.log logs/prod/*.log logs/legacy/*.log 2>/dev/null > /root/sc-logs.txt; chmod 600 /root/sc-logs.txt' >/dev/null
  assert_eq "no password is in SuiteCRM's install logs on the volume" "0" \
    "$(sc_count_secrets_in "$A" /root/sc-logs.txt "${SECRETS[@]}")"
  assert_contains "the admin signs in with a password full of quotes" "$(admin_signs_in "$A" "$ADMIN_PW")" '"login_success"'
  assert_lacks "and a wrong password is refused" "$(admin_signs_in "$A" "wrong-$ADMIN_PW")" '"login_success"'

  # What runs once Apache is PID 1.
  assert_eq "PID 1 is Apache" "apache2" "$(sc_pid1 "$A")"
  assert_eq "PID 1's environment holds no CLOUVE_OPS_PASSWORD" "0" \
    "$(in_app "$A" 'tr "\0" "\n" < /proc/1/environ | grep -c "^CLOUVE_OPS_PASSWORD="')"
  # shellcheck disable=SC2016  # PHP code
  docker exec -i "$A" sh -c 'cat > /var/www/html/public/clv-probe.php && chmod 644 /var/www/html/public/clv-probe.php' <<'PHP'
<?php
$n = 'CLOUVE_OPS_PASSWORD';
echo 'user=', posix_getpwuid(posix_geteuid())['name'],
     ' ops=', (getenv($n) === false && !isset($_SERVER[$n]) && !isset($_ENV[$n])) ? 'absent' : 'present',
     ' addr=', $_SERVER['REMOTE_ADDR'], ' https=', $_SERVER['HTTPS'] ?? 'off', "\n";
PHP
  probe="$(docker exec "$A" curl -s http://127.0.0.1/clv-probe.php)"
  assert_eq "PHP under Apache runs as www-data and finds no CLOUVE_OPS_PASSWORD" "user=www-data ops=absent" "${probe%% addr=*}"
  assert_eq "clouve-ops still signs in" "clouve-ops" "$(ops_signs_in "$A")"
  tree="$(in_app "$A" 'ps -eo pid,ppid,user:12,args --sort=pid | cut -c1-150')"
  children="$(in_app "$A" 'ps -o user:12,args --ppid 1 | cut -c1-110')"
  assert_contains "the scheduler loop is a child of PID 1" "$children" "loops.sh scheduler"
  assert_contains "the Messenger worker loop is a child of PID 1" "$children" "loops.sh worker"
  assert_eq "the Messenger worker runs as www-data, capped at 256 MB" "www-data" \
    "$(in_app "$A" 'ps -eo user:12,args | awk "/php .*messenger:consume internal-async .*--memory-limit=256M/ && !/awk|runuser/{print \$1}" | sort -u')"
  assert_eq "the scheduler is not held on a new install: SuiteCRM's own settings switch it on" "no on" \
    "$(in_app "$A" '[ -e /var/www/html/tmp/clouve-backup/scheduler-held ] && echo yes || echo no') $(in_app "$A" 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php scheduler')"
  assert_contains "the setting is one line in config_override.php" \
    "$(in_app "$A" 'cat /var/www/html/public/legacy/config_override.php')" "\$sugar_config['clouve']['scheduler'] = 'on';"
  assert_eq "settings.php refuses to run as root, because it reads files that www-data can change" "2" \
    "$(in_app "$A" 'cd /var/www/html && php /clouve/suitecrm/installer/settings.php scheduler >/dev/null 2>&1; echo $?')"
  assert_contains "the log says that the loops are small root loops whose commands run as www-data" "$log$(docker logs "$A" 2>&1)" \
    "a small root loop that runs SuiteCRM's scheduled jobs once a minute as www-data"
  if sc_wait_for 150 bash -c "[ \"\$(docker exec -e MYSQL_PWD='$ROOT_PW' $DB mariadb -uroot -N -B suitecrm -e \"SELECT COUNT(*) FROM job_queue WHERE status='done' AND resolution='success'\")\" -gt 0 ]"; then
    pass "the scheduler ran as www-data: finished jobs are in job_queue"
  else
    fail "the scheduler ran as www-data: finished jobs are in job_queue"
    show_log "$A" 10
  fi
  worker="$(in_app "$A" 'pgrep -u www-data -f "messenger:consume internal-async" | head -n 1')"
  in_app "$A" "kill -KILL $worker" >/dev/null
  if sc_wait_for 60 bash -c "w=\$(docker exec $A pgrep -u www-data -f 'messenger:consume internal-async' | head -n 1); [ -n \"\$w\" ] && [ \"\$w\" != '$worker' ]"; then
    pass "a Messenger worker that exits is started again"
  else
    fail "a Messenger worker that exits is started again"
  fi
  assert_eq "and Apache is still PID 1" "apache2" "$(sc_pid1 "$A")"
  assert_eq "at 1 GB Apache's worker limit is 6" "6" \
    "$(in_app "$A" 'sed -n "s/^\s*MaxRequestWorkers //p" /etc/apache2/conf-enabled/zz-clouve-mpm.conf')"

  # Behind the ingress.
  cookies="$(docker exec "$A" curl -s -o /dev/null -D - -H 'X-Forwarded-Proto: https' -H 'Host: crm.example.test' http://127.0.0.1/session-status | tr -d '\r' | grep -i '^set-cookie: *SCRMSESSID' | tr 'A-Z' 'a-z')"
  assert_contains "the session cookie is Secure behind a forwarded HTTPS header" "$cookies" "; secure"
  cookies="$(docker exec "$A" curl -s -o /dev/null -D - -H 'Host: crm.example.test' http://127.0.0.1/session-status | tr -d '\r' | grep -i '^set-cookie: *SCRMSESSID' | tr 'A-Z' 'a-z')"
  assert_lacks "and not Secure on plain HTTP, as an in-cluster caller sees it" "$cookies" "; secure"
  docker network connect "$PUB" "$A" >/dev/null
  peer() { docker run --rm --name "${SC_PREFIX}peer" --network "$1" --entrypoint curl "$APP_IMAGE" -s "${@:2}"; }
  private="$(peer "$NET" -H 'X-Forwarded-For: 203.0.113.7' "http://$A/clv-probe.php")"
  assert_eq "PHP sees the client's address that a private peer forwards" "addr=203.0.113.7 https=off" "addr=${private##* addr=}"
  public_ip="$(docker inspect --format "{{(index .NetworkSettings.Networks \"$PUB\").IPAddress}}" "$A")"
  public="$(peer "$PUB" -H 'X-Forwarded-For: 203.0.113.7' "http://$public_ip/clv-probe.php")"
  case "${public##* addr=}" in
    198.51.100.*) pass "a peer that is not private can't name another address" ;;
    *) fail "a peer that is not private can't name another address (PHP saw ${public##* addr=})" ;;
  esac
  docker exec "$A" rm -f /var/www/html/public/clv-probe.php

  # The access log is the container's log. A password-reset link or an API token in a query string or a Referer
  # must not end up there.
  docker exec "$A" curl -s -o /dev/null -H 'Referer: https://crm.example.test/#/reset?token=sct-referer-secret' \
    'http://127.0.0.1/session-status?token=sct-query-secret' >/dev/null
  sleep 1
  line="$(docker logs "$A" 2>&1 | grep -F '"GET /session-status ' | tail -n 1)"
  assert_contains "the access log has the request's method and path" "$line" '"GET /session-status HTTP/1.1" 200'
  assert_lacks "and not its query string" "$line" "sct-query-secret"
  assert_eq "nor the Referer, anywhere in the log" "0" "$(docker logs "$A" 2>&1 | grep -c 'sct-referer-secret\|sct-query-secret')"

  # Where uploads land, no PHP file is run or served, whatever its name's case, and an .htaccess there changes
  # nothing. Other files in the public media folder are served as before.
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -u www-data "$A" bash -c '
    cd /var/www/html/public && mkdir -p media/images media-upload/images legacy/upload &&
    for d in media/images media-upload/images legacy/upload; do
      echo "<?php echo \"SCT-RAN\";" > "$d/sct-probe.php"; echo "<?php echo \"SCT-RAN\";" > "$d/sct-probe.PhP"
      echo "<?php echo \"SCT-RAN\";" > "$d/sct-probe.txt"
      printf "AddType application/x-httpd-php .txt\nphp_flag engine on\nRequire all granted\n" > "$d/.htaccess"
    done; echo "plain" > media/images/sct-plain.txt'
  ran=""
  for u in /media/images/sct-probe.php /media/images/sct-probe.PhP /media/images/sct-probe.txt \
           /media-upload/images/sct-probe.php /media-upload/images/sct-probe.txt \
           /legacy/upload/sct-probe.php /legacy/upload/sct-probe.txt; do
    body="$(docker exec "$A" curl -s "http://127.0.0.1$u")"
    case "$body" in *SCT-RAN*) case "$body" in *'<?php'*) ;; *) ran="$ran $u" ;; esac ;; esac
    case "$u" in *.php|*.PhP) case "$body" in *'<?php'*) ran="$ran $u(source)" ;; esac ;; esac
  done
  assert_eq "no PHP file in an upload folder is run, and none is served as text" "" "$ran"
  assert_eq "a PHP file there is refused, and another file in the public media folder is still served" "403 403 200" \
    "$(sc_http "$A" /media/images/sct-probe.php) $(sc_http "$A" /media-upload/images/sct-probe.PhP) $(sc_http "$A" /media/images/sct-plain.txt)"
  docker exec "$A" bash -c 'cd /var/www/html/public && rm -rf media/images/sct-* media/images/.htaccess media-upload legacy/upload/sct-* legacy/upload/.htaccess'
  # A page of SuiteCRM's older part, asked for without a cookie, sets the session cookie itself.
  cookies="$(docker exec "$A" curl -s -o /dev/null -D - -H 'X-Forwarded-Proto: https' -H 'Host: crm.example.test' 'http://127.0.0.1/legacy/index.php?module=Users&action=Login' | tr -d '\r' | grep -i '^set-cookie:' | tr 'A-Z' 'a-z')"
  if [ -z "$cookies" ] || { [[ "$cookies" == *"httponly"* ]] && [[ "$cookies" == *"samesite=lax"* ]]; }; then
    pass "a session cookie that an older page sets is HttpOnly and SameSite=Lax"
  else
    fail "a session cookie that an older page sets is HttpOnly and SameSite=Lax"
    printf '       %s\n' "$cookies"
  fi

  echo "       PID 1 and what runs under it:"
  sed 's/^/       | /' <<< "$tree"
  echo "       memory at idle, 1 GB limit: $(in_app "$A" 'echo "$(( $(cat /sys/fs/cgroup/memory.current) / 1048576 )) MB in use ($(awk "/^anon /{print int(\$2 / 1048576)}" /sys/fs/cgroup/memory.stat) MB of it anonymous), peak $(( $(cat /sys/fs/cgroup/memory.peak) / 1048576 )) MB"')"
fi

# --- restart ---------------------------------------------------------------------
if wants restart; then
  echo
  echo "restart: a new site address and a new database password"
  if ! docker volume inspect "${SC_PREFIX}data" >/dev/null 2>&1; then
    fail "the restart case needs the install case's volume (run both)"
  else
    docker rm -f -v "$A" >/dev/null 2>&1
    sc_sql "$DB" mysql "ALTER USER 'suitecrm'@'%' IDENTIFIED BY '$DB_PW2';" >/dev/null
    docker run -d --name "$A" --network "$NET" --memory 1g -v "${SC_PREFIX}data:/var/www/html" \
      -e "DATABASE_HOST=$DB" -e DATABASE_PORT=3306 -e DATABASE_NAME=suitecrm -e DATABASE_USER=suitecrm \
      -e "DATABASE_PASSWORD=$DB_PW2" -e SUITECRM_URL=https://crm2.example.test:8443/ \
      -e "SUITECRM_ADMIN_USER=$ADMIN_USER" -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
      "$APP_IMAGE" >/dev/null
    if wait_installed "$A" 180; then
      pass "SuiteCRM answers after the restart"
    else
      fail "SuiteCRM answers after the restart"
      show_log "$A" 30
    fi
    log="$(docker logs "$A" 2>&1)"
    assert_lacks "nothing is installed again" "$log" "new install"
    # shellcheck disable=SC2016  # PHP code
    settings="$(docker exec -e "T_PW=$DB_PW2" "$A" runuser -u www-data -- php -r '
      include "/var/www/html/public/legacy/config.php";
      $d = $sugar_config["dbconfig"];
      $env = file_get_contents("/var/www/html/.env.local");
      echo $sugar_config["site_url"], " ", $sugar_config["host_name"], " ", $d["db_host_name"], " ", $d["db_port"], " ",
        $d["db_name"], " ", $d["db_user_name"], " ", $d["db_password"] === getenv("T_PW") ? "new-password" : "OLD-PASSWORD",
        " ", str_contains($env, ":" . urlencode(getenv("T_PW")) . "@") ? "env-new-password" : "ENV-OLD-PASSWORD";')"
    assert_eq "config.php and .env.local follow the environment" \
      "https://crm2.example.test:8443 crm2.example.test $DB 3306 suitecrm suitecrm new-password env-new-password" "$settings"
    assert_eq ".env.local still has one DATABASE_URL line and its APP_SECRET" "1 1" \
      "$(in_app "$A" 'grep -c "^DATABASE_URL=" /var/www/html/.env.local; grep -c "^APP_SECRET=" /var/www/html/.env.local' | xargs)"
    assert_eq "the settings files are still www-data's and closed to others" "www-data 0" \
      "$(in_app "$A" 'cd /var/www/html && echo "$(stat -c %U public/legacy/config.php) $(find .env.local public/legacy/config.php -perm /o=rwx | wc -l)"')"
    assert_contains "the admin still signs in" "$(admin_signs_in "$A" "$ADMIN_PW")" '"login_success"'
    assert_eq "no password is in the log" "0" "$(sc_count_secrets_in_log "$A" "${SECRETS[@]}")"
    sc_sql "$DB" mysql "ALTER USER 'suitecrm'@'%' IDENTIFIED BY '$DB_PW';" >/dev/null
  fi
fi
docker rm -f -v "$A" >/dev/null 2>&1

# --- cut-off ---------------------------------------------------------------------
if wants cut-off; then
  echo
  echo "cut-off: an install that is killed before it finishes"
  A="${SC_PREFIX}cut"
  extra_database crm_cut
  sc_new_disk "${SC_PREFIX}cut-data"
  start_app "$A" "${SC_PREFIX}cut-data" crm_cut -e CLOUVE_TEST_PAUSE=install-end:120
  if sc_wait_log "$A" "test pause at install-end" 240; then
    pass "the installer ran, and the install is not finished yet"
  else
    fail "the installer ran, and the install is not finished yet"
    show_log "$A"
  fi
  tables="$(sc_sql "$DB" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='crm_cut'")"
  if [ "${tables:-0}" -gt 100 ]; then pass "its tables are in the database ($tables)"; else fail "its tables are in the database (${tables:-none})"; fi
  docker kill "$A" >/dev/null
  docker rm -f -v "$A" >/dev/null 2>&1
  start_app "$A" "${SC_PREFIX}cut-data" crm_cut
  if wait_installed "$A" 300; then
    pass "the next start ends with SuiteCRM installed"
  else
    fail "the next start ends with SuiteCRM installed"
    show_log "$A" 40
  fi
  log="$(docker logs "$A" 2>&1)"
  assert_contains "it says it found an unfinished install and cleared it" "$log" "an install was cut off"
  assert_eq "the stamp is gone" "gone" "$(in_app "$A" '[ -e /var/www/html/.clouve-install-in-progress ] || echo gone')"
  assert_eq "the version row is in the database" "$VERSION" \
    "$(sc_sql "$DB" crm_cut "SELECT value FROM config WHERE category='info' AND name='suitecrm_version'")"
  assert_contains "the admin signs in" "$(admin_signs_in "$A" "$ADMIN_PW")" '"login_success"'
  # A stamp that is still there next to a site people have worked in: a second user is in the database.
  docker stop -t 30 "$A" >/dev/null 2>&1
  sc_sql "$DB" crm_cut "INSERT INTO users (id, user_name, status, deleted) VALUES ('sct-second-user', 'sally', 'Active', 0)" >/dev/null
  tables="$(sc_sql "$DB" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='crm_cut'")"
  docker run --rm --network none -v "${SC_PREFIX}cut-data:/v" "$SC_SHAPER" \
    sh -c "umask 077; printf 'database=%s/crm_cut\\nstarted=2026-01-01T00:00:00Z\\n' '$DB' > /v/.clouve-install-in-progress" >/dev/null
  docker rm -f -v "$A" >/dev/null 2>&1
  start_app "$A" "${SC_PREFIX}cut-data" crm_cut
  sc_wait_for 120 bash -c "! [ \"\$(docker inspect --format '{{.State.Running}}' $A)\" = true ]"
  assert_eq "a stamp next to a database with two users stops the container" "false 1" \
    "$(docker inspect --format '{{.State.Running}} {{.State.ExitCode}}' "$A")"
  assert_contains "the log says how many users the database holds" "$(docker logs "$A" 2>&1)" "holds 2 users"
  assert_eq "nothing was dropped and nothing was cleared" "$tables $VERSION" \
    "$(sc_sql "$DB" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='crm_cut'") $(docker run --rm --network none -v "${SC_PREFIX}cut-data:/v:ro" "$SC_SHAPER" cat /v/VERSION)"
  docker rm -f -v "$A" >/dev/null 2>&1
fi

# --- demo ------------------------------------------------------------------------
if wants demo; then
  echo
  echo "demo: SUITECRM_INSTALL_DEMO_DATA=yes"
  A="${SC_PREFIX}demo"
  extra_database crm_demo
  sc_new_disk "${SC_PREFIX}demo-data"
  start_app "$A" "${SC_PREFIX}demo-data" crm_demo -e SUITECRM_INSTALL_DEMO_DATA=yes
  if wait_installed "$A" 420; then
    pass "SuiteCRM installs with demo data"
  else
    fail "SuiteCRM installs with demo data"
    show_log "$A" 40
  fi
  accounts="$(sc_sql "$DB" crm_demo "SELECT COUNT(*) FROM accounts")"
  if [ "${accounts:-0}" -gt 0 ]; then pass "the demo accounts are there ($accounts)"; else fail "the demo accounts are there (${accounts:-none})"; fi
  docker rm -f -v "$A" >/dev/null 2>&1
fi

# --- password --------------------------------------------------------------------
if wants password; then
  echo
  echo "password: a database password with a blank, @, :, /, %, # and both quotes"
  A="${SC_PREFIX}pw"
  ODD_PW="p w@:/%#'\"+&=?\$x\\y-$(rand)"
  SECRETS+=("$ODD_PW")
  extra_database crm_pw
  # A second database user with that password. The value goes through the environment, never a command line.
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec -e "T_PW=$ODD_PW" "$DB" sh -c '
    esc=$(printf "%s" "$T_PW" | sed "s/\\\\/\\\\\\\\/g; s/'"'"'/'"''"'/g")
    MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb -uroot -e "CREATE USER '"'"'oddpw'"'"'@'"'"'%'"'"' IDENTIFIED BY '"'"'$esc'"'"'; GRANT ALL PRIVILEGES ON crm_pw.* TO '"'"'oddpw'"'"'@'"'"'%'"'"';"' >/dev/null 2>&1
  sc_new_disk "${SC_PREFIX}pw-data"
  start_odd() {
    docker rm -f -v "$A" >/dev/null 2>&1
    docker run -d --name "$A" --network "$NET" --memory 1g -v "${SC_PREFIX}pw-data:/var/www/html" \
      -e "DATABASE_HOST=$DB" -e DATABASE_PORT=3306 -e DATABASE_NAME=crm_pw -e DATABASE_USER=oddpw \
      -e "DATABASE_PASSWORD=$ODD_PW" -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_USER=$ADMIN_USER" \
      -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e "CLOUVE_OPS_PASSWORD=$OPS_PW" "$APP_IMAGE" >/dev/null
  }
  both_reach_the_database() {
    # SuiteCRM's newer part reads .env.local (Doctrine), its older part config.php. Each asks the database itself.
    docker exec -i "$A" sh -c 'cat > /tmp/sct-legacy.php && chmod 644 /tmp/sct-legacy.php' <<'PHP'
<?php
chdir('/var/www/html/public/legacy');
define('sugarEntry', true);
require 'include/entryPoint.php';
echo 'answer=', DBManagerFactory::getInstance()->getOne('SELECT 41 + 1'), "\n";
PHP
    # shellcheck disable=SC2016  # the script is for the bash inside the container
    in_app "$A" 'cd /var/www/html && w() { setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"; }
      w php bin/console dbal:run-sql "SELECT 41 + 1" 2>/dev/null | grep -qw 42 && printf "doctrine "
      w php /tmp/sct-legacy.php 2>/dev/null | grep -qx "answer=42" && printf "legacy"'
  }
  start_odd
  if wait_installed "$A" 300; then pass "SuiteCRM installs with that password"; else fail "SuiteCRM installs with that password"; show_log "$A" 30; fi
  assert_eq "both of SuiteCRM's configurations reach the database" "doctrine legacy" "$(both_reach_the_database)"
  sleep 20
  assert_eq "the Messenger worker, which reads .env.local, stays up" "1 0" \
    "$(in_app "$A" 'pgrep -u www-data -fc "messenger:consume internal-async"') $(docker logs "$A" 2>&1 | grep -c 'the Messenger worker stopped')"
  assert_contains "the admin signs in" "$(admin_signs_in "$A" "$ADMIN_PW")" '"login_success"'
  start_odd
  if wait_installed "$A" 180; then pass "a restart comes up"; else fail "a restart comes up"; show_log "$A" 30; fi
  assert_eq "and both still reach the database" "doctrine legacy" "$(both_reach_the_database)"
  assert_eq "no password is in the log" "0" "$(sc_count_secrets_in_log "$A" "${SECRETS[@]}")"
  docker rm -f -v "$A" >/dev/null 2>&1
fi

# --- address ---------------------------------------------------------------------
if wants address; then
  echo
  echo "address: a SUITECRM_URL that is not an address"
  A="${SC_PREFIX}app"
  if ! docker volume inspect "${SC_PREFIX}data" >/dev/null 2>&1; then
    fail "the address case needs the install case's volume (run both)"
  else
    site_url() { in_app "$A" 'runuser -u www-data -- php -r "include \"/var/www/html/public/legacy/config.php\"; echo \$sugar_config[\"site_url\"], \" \", \$sugar_config[\"host_name\"];"'; }
    docker rm -f -v "$A" >/dev/null 2>&1
    start_app "$A" "${SC_PREFIX}data" suitecrm -e SUITECRM_URL=https://crm3.example.test
    wait_installed "$A" 180 || { fail "SuiteCRM answers"; show_log "$A"; }
    assert_eq "a good address is written" "https://crm3.example.test crm3.example.test" "$(site_url)"
    for bad in 'crm.example.com' ' http://' '//host.example' 'https://bad host.example'; do
      docker rm -f -v "$A" >/dev/null 2>&1
      start_app "$A" "${SC_PREFIX}data" suitecrm -e "SUITECRM_URL=$bad"
      wait_installed "$A" 180 || { fail "SuiteCRM answers with SUITECRM_URL='$bad'"; show_log "$A"; }
      assert_contains "SUITECRM_URL='$bad': the log says that it is not an address" "$(docker logs "$A" 2>&1)" \
        "SUITECRM_URL is not an address"
      assert_eq "SUITECRM_URL='$bad': the address SuiteCRM has stays" "https://crm3.example.test crm3.example.test" "$(site_url)"
    done
    docker rm -f -v "$A" >/dev/null 2>&1
    start_app "$A" "${SC_PREFIX}data" suitecrm -e 'SUITECRM_URL=  https://crm4.example.test/  '
    wait_installed "$A" 180 || { fail "SuiteCRM answers"; show_log "$A"; }
    assert_eq "blanks around a good address are dropped" "https://crm4.example.test crm4.example.test" "$(site_url)"
    docker rm -f -v "$A" >/dev/null 2>&1
  fi
fi

# --- empty-db --------------------------------------------------------------------
if wants empty-db; then
  echo
  echo "empty-db: SuiteCRM on the volume, and a database without tables"
  A="${SC_PREFIX}app"
  if ! docker volume inspect "${SC_PREFIX}data" >/dev/null 2>&1; then
    fail "the empty-db case needs the install case's volume (run both)"
  else
    docker rm -f -v "$A" >/dev/null 2>&1
    extra_database crm_empty
    start_app "$A" "${SC_PREFIX}data" crm_empty
    if sc_wait_log "$A" "has no SuiteCRM tables" 120; then pass "the log says that the database has no SuiteCRM tables"; else fail "the log says that the database has no SuiteCRM tables"; show_log "$A"; fi
    sc_wait_log "$A" "SuiteCRM is not started" 30 >/dev/null
    sleep 5
    log="$(docker logs "$A" 2>&1)"
    assert_contains "as a failure line for staff and alerts" "$log" "[clouve-upgrade] FAILED suitecrm "
    assert_lacks "it does not call it a cut-off upgrade" "$log" "an upgrade was cut off"
    assert_lacks "Apache was never started" "$log" "starting Apache"
    assert_lacks "and nothing was installed over the volume" "$log" "new install"
    assert_eq "the container waits: PID 1 is the entrypoint, the stand-in answers and says the site needs attention" \
      "entrypoint.sh 200 1" "$(sc_pid1 "$A") $(sc_http "$A" /) $(docker exec "$A" curl -s http://127.0.0.1/ | grep -c 'needs attention')"
    assert_eq "clouve-ops signs in, so the database can be restored" "clouve-ops" "$(ops_signs_in "$A")"
    assert_eq "the database is still empty" "0" "$(sc_sql "$DB" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='crm_empty'")"
    # Staff point the container at the right database again: here, by giving the tables back.
    # shellcheck disable=SC2016  # the script is for the sh inside the container
    docker exec "$DB" sh -c 'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"; export MYSQL_PWD; mariadb-dump -uroot suitecrm | mariadb -uroot crm_empty' >/dev/null 2>&1
    if wait_installed "$A" 180; then pass "once the tables are back, the waiting container goes on and SuiteCRM answers"; else fail "once the tables are back, the waiting container goes on and SuiteCRM answers"; show_log "$A" 30; fi
    docker rm -f -v "$A" >/dev/null 2>&1
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sSuiteCRM entrypoint checks passed.%s\n' "$SC_GREEN" "$SC_RESET"
  exit 0
fi
printf '%sSuiteCRM entrypoint checks failed.%s\n' "$SC_RED" "$SC_RESET"
exit 1
