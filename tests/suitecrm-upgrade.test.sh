#!/bin/bash

# ============================================================================
# SuiteCRM upgrade test: a real 8.9.1 site, upgraded in place by the new image
# ============================================================================
# Builds a SuiteCRM 8.9.1 site with the image this repo shipped before (commit
# SC_OLD_REF in tests/lib/suitecrm-test-lib.sh) and MariaDB 12.1, the line the
# existing installs were made with, on volumes shaped like new cluster disks.
# It gives the site what a customer's has: an account with a contact and three
# opportunities, two leads, a note with a file, a custom field with a value, a
# logic hook, settings, a second user with a role and a security group, the
# outgoing mail account with a password, the OAuth2 client of the Customer
# Kit's LimeSurvey plugin, an extension, and files in uploads/ and
# public/media-upload/. Each case then starts the new images on a copy of
# those volumes, as a cluster does when a deployment's image changes, and
# checks which SuiteCRM the site ends on and that everything is still there.
#
# plain          The upgrade runs once and ends on 8.10.2 with all of it. The
#                files from uploads/ and public/media-upload/ are in media/ and
#                public/media/. The backup is kept, root's and closed. The
#                database moved to MariaDB 12.3. No password was on a command
#                line or in the log. The key that encrypts stored mail
#                passwords is closed to others. The scheduler is held until it
#                is released, then runs as www-data. A second start doesn't
#                upgrade again. Prints the wall time and the peak memory.
# slow           The upgrade is made to last longer than the 105 seconds the
#                platform's health check allows. The stand-in answers GET /
#                with 200 all the way, API calls get 503, and sshd answers.
# stale-cache    SuiteCRM's compiled settings were written in the same second the
#                upgrade reads them. Symfony's cache:clear then takes them for
#                fresh and rebuilds nothing, and SuiteCRM 8.9.1's upgrade would
#                delete uploads/ and public/media-upload/ from its old
#                keep-list. The upgrade must end with the files in place.
# fail           SuiteCRM's upgrade fails twice (a broken package): the site
#                ends on a working 8.9.1 with all its data, the failure is
#                recorded, and later starts don't try again. The database was
#                never changed, so the way back leaves it alone, and a dump
#                taken afterwards equals one taken before. Another build
#                of the image tries again by itself, and so does this one once
#                the failure file is removed.
# finalize       The second upgrade command fails once, after the code was
#                replaced and part of the database changed: the way back runs,
#                the second try succeeds.
# kill-backup    The container is killed while the backup is written.
# kill-upgrade   Killed between SuiteCRM's two upgrade commands. The way back
#                puts the files back and leaves the database alone: a dump
#                taken after the way back equals one taken before.
# kill-restore   Killed during the way back, with the database's tables
#                dropped. The next start loads the dump and upgrades.
# kill-cleanup   Killed after the upgrade succeeded, before its clean-up.
# restore-fails  The way back can't reach the database: the container exits
#                with a failing status and Apache never starts. The next start
#                runs the way back again and then the upgrade.
# bad-dump       The backup's dump is cut short after it was stamped: it is
#                never loaded, nothing is dropped, Apache never starts, and
#                the container waits with the stand-in and the sshd up.
# newer          A volume with a newer SuiteCRM: the container exits and
#                changes nothing.
# unfinished     VERSION says 8.10.2, the database has no finished-upgrade row
#                and neither a state nor a backup is left: Apache never starts
#                and nothing is backed up or changed. The container waits
#                until staff finish the upgrade with the runbook's command.
#                While it waits, tmp/clouve-backup/needs-attention holds the
#                FAILED line's words for the AI Assistant, and it goes when
#                the wait is over. Every case that waits checks that note. No
#                note is written while a moved-aside state folder is there.
# space          Too little free space on the volume: no upgrade, the site
#                keeps running 8.9.1, and upgrade-skipped says why.
# trust-old-image  An upgrade is cut off, and the earlier image then starts
#                once on the volume and gives everything to www-data. The new
#                image moves the state folder aside, never starts Apache on
#                the half-upgraded site and keeps the backup. After the
#                README's staff step it goes back and upgrades.
# trust-reset    The same after SuiteCRM's own permission reset and a start of
#                the earlier image, with the cut in the middle of the upgrade's
#                first step, when the customer's files are in the state folder.
#                The earlier image finds its marker and leaves the database alone.
# root-owned     Files of root's in the install: the upgrade is not tried and
#                the log names them. Files of root's that appear in the middle
#                of an upgrade: the way back removes them with the rest.
# db-changed     The database changes before SuiteCRM's second command: the way
#                back loads the dump, and a dump taken afterwards equals one
#                taken before the upgrade.
# stale-list     SuiteCRM's compiled keep-list is the old one: the try stops
#                before the upgrade command, and the next one compiles the list
#                anew. And cache as a link to a folder next to it: the link
#                becomes a real folder and the upgrade runs.
# files-gone     uploads/ is gone when the way back looks for it: it says so
#                and Apache doesn't start.
# kill-anywhere  Killed at several moments after each phase began, twice in a
#                row: the site always ends on one whole version.
# stop           A stop request in the middle of an upgrade ends the container
#                within seconds with a clean status, and two of them are not
#                two failed tries.
# restore-marker While tmp/clouve-backup/restore-in-progress is there, a start
#                waits behind the stand-in, its note says kind=restore, and
#                neither background job runs.
# state-lost     The state file is gone and the complete backup is there: the
#                start goes back from it and upgrades.
# scheduler      The hold on an install that never ran a scheduled job stays
#                through a permission reset and the removal of the state
#                folder, until the README's release.
# runbook        The README's way back by hand, run as written after a
#                finished upgrade: the old version runs and stays, and the
#                commands keep the customer's files in <name>.clouve-aside
#                folders.
# password-change  The database password changes between a cut-off upgrade
#                and the next start.
# build-reset    A newer build meets a state an earlier build left after its
#                second try: it makes a try of its own.
#
# --image NAME=REF uses an image that is already built (suitecrm,
# suitecrm-mariadb, suitecrm-old, suitecrm-mariadb-old). Naming cases limits
# the run. Everything the test makes is named sc-t-up-* (SUITECRM_TEST_PREFIX
# changes the sc-t- part), runs on a network with no way out and no published
# port, and is removed at the end unless --keep is given. Every password is
# made up. Needs Docker and git. About 80 minutes for all cases.
#
# SUITECRM_TEST_GOLD=DIR keeps the 8.9.1 site between runs, for whoever works on
# the image: the first run saves the site's two volumes (named
# <SUITECRM_TEST_PREFIX>gold-kept-data and -dbdata, which no run removes) and
# its made-up passwords in DIR, and later runs start from them, whatever their
# prefix. Remove the two volumes and DIR by hand when done.
#
# Usage: bash tests/suitecrm-upgrade.test.sh [--image NAME=REF]... [--keep] [CASE...]
# Exit status: 0 when every check passes, 1 when one fails, 2 when it can't run.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suitecrm-test-lib.sh
. "$SCRIPT_DIR/lib/suitecrm-test-lib.sh"
SC_PREFIX="${SC_PREFIX}up-"
OLD=8.9.1
NEW=8.10.2
ALL_CASES=(plain slow stale-cache fail finalize kill-backup kill-upgrade kill-restore kill-cleanup restore-fails bad-dump newer unfinished space
  trust-old-image trust-reset root-owned db-changed stale-list files-gone kill-anywhere stop restore-marker state-lost scheduler
  runbook password-change build-reset)

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}
CASES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image) sc_parse_image_option "${2:-}" || usage; shift ;;
    --keep) SC_KEEP=true ;;
    *)
      known=false
      for c in "${ALL_CASES[@]}"; do [ "$c" = "$1" ] && known=true; done
      [ "$known" = true ] || usage
      CASES+=("$1")
      ;;
  esac
  shift
done
[ "${#CASES[@]}" -gt 0 ] || CASES=("${ALL_CASES[@]}")

sc_need_docker
trap sc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sc_remove_resources    # leftovers of a run that was killed
sc_workdir

echo "SuiteCRM upgrade, $OLD to $NEW"
for name in suitecrm suitecrm-mariadb suitecrm-old suitecrm-mariadb-old; do
  if ! sc_image "$name"; then
    fail "the image $name builds or is on this machine"
    exit 2
  fi
done
APP_IMAGE="${SC_IMAGE[suitecrm]}"
DB_IMAGE="${SC_IMAGE[suitecrm-mariadb]}"
OLD_APP_IMAGE="${SC_IMAGE[suitecrm-old]}"
OLD_DB_IMAGE="${SC_IMAGE[suitecrm-mariadb-old]}"
BUILD="$(docker run --rm --network none --entrypoint cat "$APP_IMAGE" /clouve/suitecrm/BUILD 2>/dev/null)"

rand() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
DB_PW="db-pw-$(rand)"
ROOT_PW="root-pw-$(rand)"
OPS_PW="ops-pw-$(rand)"
ADMIN_PW="Old-Adm1n-$(rand)"
USER_PW="Sally-pw-$(rand)"
SMTP_PW="smtp-pw-$(rand)"
OAUTH_SECRET="$(rand)$(rand)"
ADMIN_USER="admin@example.test"
# The 8.9.1 site of an earlier run (SUITECRM_TEST_GOLD), with the made-up passwords it was built with.
GOLD_DATA="${SC_PREFIX}gold-data"
GOLD_DBDATA="${SC_PREFIX}gold-dbdata"
GOLD_KEPT="${SUITECRM_TEST_PREFIX:-sc-t-}gold-kept-"
GOLD_REUSED=false
# A run with another prefix can start from the same kept site: DIR/volumes names its volumes.
if [ -n "${SUITECRM_TEST_GOLD:-}" ] && [ -r "$SUITECRM_TEST_GOLD/volumes" ]; then
  GOLD_KEPT="$(head -n 1 "$SUITECRM_TEST_GOLD/volumes")"
fi
if [ -n "${SUITECRM_TEST_GOLD:-}" ] && [ -r "$SUITECRM_TEST_GOLD/secrets" ] && [ -r "$SUITECRM_TEST_GOLD/fingerprint" ] &&
  docker volume inspect "${GOLD_KEPT}data" "${GOLD_KEPT}dbdata" >/dev/null 2>&1; then
  # shellcheck disable=SC1091  # written by this test, below
  . "$SUITECRM_TEST_GOLD/secrets"
  GOLD_DATA="${GOLD_KEPT}data"
  GOLD_DBDATA="${GOLD_KEPT}dbdata"
  GOLD_REUSED=true
fi
NET="${SC_PREFIX}net"
docker network create --internal "$NET" >/dev/null

# Names of a case's containers and volumes.
app_of() { echo "${SC_PREFIX}$1-app"; }
db_of() { echo "${SC_PREFIX}$1-db"; }
data_of() { echo "${SC_PREFIX}$1-data"; }
dbdata_of() { echo "${SC_PREFIX}$1-dbdata"; }

# Both containers get what the Customer Kit gives them, the smallest size the images run at: 1 GB and one CPU
# for SuiteCRM, 1 GB and half a CPU for the database, and no swap beyond that.
# db_start CASE [IMAGE]: the case's database container, on its volume.
db_start() {
  local c="$1" image="${2:-$DB_IMAGE}"
  docker rm -f "$(db_of "$c")" >/dev/null 2>&1
  DB_STARTED=$SECONDS
  docker run -d --name "$(db_of "$c")" --network "$NET" --memory 1g --memory-swap 1g --cpus 0.5 \
    -v "$(dbdata_of "$c"):/var/lib/mysql" \
    -e MYSQL_DATABASE=suitecrm -e MYSQL_USER=suitecrm -e "MYSQL_PASSWORD=$DB_PW" -e "MYSQL_ROOT_PASSWORD=$ROOT_PW" \
    "$image" >/dev/null
  sc_wait_for 240 docker exec "$(db_of "$c")" healthcheck.sh --connect --innodb_initialized
}
# app_start CASE [docker run options...]: the case's app container on its volume, with the new image unless an
# option names another (the image is the last word, so SC_APP_IMAGE overrides it).
app_start() {
  local c="$1"
  shift
  sc_save_log "$(app_of "$c")"
  docker rm -f "$(app_of "$c")" >/dev/null 2>&1
  docker run -d --name "$(app_of "$c")" --network "$NET" --memory "${SC_APP_MEMORY:-1g}" \
    --memory-swap "${SC_APP_MEMORY:-1g}" --cpus 1 -v "$(data_of "$c"):/var/www/html" \
    -e "DATABASE_HOST=$(db_of "$c")" -e DATABASE_PORT=3306 -e DATABASE_NAME=suitecrm -e DATABASE_USER=suitecrm \
    -e "DATABASE_PASSWORD=$DB_PW" -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_USER=$ADMIN_USER" \
    -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e SUITECRM_INSTALL_DEMO_DATA=no -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
    "$@" "${SC_APP_IMAGE:-$APP_IMAGE}" >/dev/null
}
# wait_up CASE SECONDS: 0 once Apache is PID 1 and SuiteCRM answers, 2 when the container stopped, 1 after SECONDS.
wait_up() {
  local a deadline=$((SECONDS + $2))
  a="$(app_of "$1")"
  while [ "$SECONDS" -lt "$deadline" ]; do
    sc_apache_serves "$a" && return 0
    sc_running "$a" || return 2
    sleep 2
  done
  return 1
}
# wait_exit CASE SECONDS: 0 once the app container has stopped.
wait_exit() {
  local a deadline=$((SECONDS + $2))
  a="$(app_of "$1")"
  while [ "$SECONDS" -lt "$deadline" ]; do
    sc_running "$a" || return 0
    sleep 1
  done
  return 1
}
in_app() { docker exec "$(app_of "$1")" bash -c "$2" 2>&1; }
# on_volume CASE SCRIPT: runs a sh script with the case's app volume at /v, when the app container is not running.
on_volume() { docker run --rm --network none -v "$(data_of "$1"):/v" "$SC_SHAPER" sh -c "$2" 2>&1; }
# state_of CASE KEY...: values from the upgrade's state file on the volume, in the order asked, when the app
# container is not running. state_in CASE KEY...: the same through the running app container.
state_of() {
  local c="$1" key out=""
  shift
  for key in "$@"; do out="$out $(on_volume "$c" "sed -n 's/^$key=//p' /v/tmp/clouve-backup/state 2>/dev/null")"; done
  echo "${out# }"
}
state_in() {
  local c="$1" key out=""
  shift
  for key in "$@"; do out="$out $(in_app "$c" "sed -n 's/^$key=//p' /var/www/html/tmp/clouve-backup/state 2>/dev/null")"; done
  echo "${out# }"
}
db_tables() { sc_sql "$(db_of "$1")" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='suitecrm'"; }
db_version_row() { sc_sql "$(db_of "$1")" suitecrm "SELECT value FROM config WHERE category='info' AND name='suitecrm_version'"; }
show_log() { docker logs --tail "${2:-30}" "$(app_of "$1")" 2>&1 | sed 's/^/       | /'; }
app_log() { docker logs "$(app_of "$1")" 2>&1; }
count_in_log() { app_log "$1" | grep -cF -- "$2"; }

# db_hash CASE: a checksum of everything the app's database holds: its dump, a row a line, sorted. Two moments of
# the same database give the same checksum only when no table, column or row differs.
db_hash() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec "$(db_of "$1")" sh -c 'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb-dump -uroot --skip-dump-date --skip-comments --skip-extended-insert --single-transaction suitecrm | LC_ALL=C sort | sha256sum | cut -d" " -f1' 2>/dev/null
}
# page_of CASE: what GET / answers, headers and body.
page_of() { docker exec "$(app_of "$1")" curl -s -D - http://127.0.0.1/ 2>/dev/null | tr -d '\r'; }
# assert_waiting CASE TEXT: the container found a site it must not start. It logs TEXT, keeps running without
# Apache, and the stand-in and the sshd answer, so that staff or the AI Assistant can repair the site.
assert_waiting() {
  local c="$1" text="$2" log page
  if sc_wait_log "$(app_of "$c")" "$text" 300; then pass "$c: the log says: $text"; else fail "$c: the log says: $text"; show_log "$c" 20; fi
  sc_wait_log "$(app_of "$c")" "SuiteCRM is not started" 60 >/dev/null
  sleep 8
  log="$(app_log "$c")"
  assert_contains "$c: the log says that SuiteCRM is not started and why the container stays up" "$log" "SuiteCRM is not started"
  assert_lacks "$c: Apache was never started" "$log" "starting Apache"
  assert_eq "$c: the container still runs, and PID 1 is the entrypoint, not Apache" "true entrypoint.sh" \
    "$(docker inspect --format '{{.State.Running}}' "$(app_of "$c")" 2>/dev/null) $(sc_pid1 "$(app_of "$c")")"
  page="$(page_of "$c")"
  assert_contains "$c: the stand-in answers the health check" "$page" "X-Clouve-Standin: suitecrm"
  assert_contains "$c: and its page says that the site needs attention" "$page" "needs attention"
  assert_eq "$c: every other request gets 503" "503" "$(sc_http "$(app_of "$c")" /session-status)"
  assert_ok "$c: the sshd answers, for staff and the AI Assistant" docker exec "$(app_of "$c")" bash -c '</dev/tcp/127.0.0.1/22'
  assert_note "$c" "$log"
}
# assert_note CASE LOG: the note the waiting container leaves for the AI Assistant, which can't read the
# container's log: tmp/clouve-backup/needs-attention, root's, mode 600, with five key=value lines. Its reason and
# its two versions are the ones of the last FAILED line. While a state folder that was moved aside is on the
# volume there is no note, because the image makes no new state folder then: staff put the old one back with mv,
# and a new folder of that name would turn that step into a move into it.
assert_note() {
  local c="$1" failed rest from to note file=/var/www/html/tmp/clouve-backup/needs-attention
  if [ -n "$(in_app "$c" 'ls -d /var/www/html/tmp/clouve-backup.untrusted-* 2>/dev/null')" ]; then
    assert_eq "$c: no new state folder is made next to the one that was moved aside, so the note is left out" "none" \
      "$(in_app "$c" 'if [ -e /var/www/html/tmp/clouve-backup ]; then echo there; else echo none; fi')"
    return
  fi
  failed="$(grep -F '[clouve-upgrade] FAILED suitecrm ' <<< "$2" | tail -n 1)"
  rest="${failed#*FAILED suitecrm }"
  from="${rest%% -> *}"
  rest="${rest#* -> }"
  to="${rest%%: *}"
  note="$(in_app "$c" "cat $file" 2>&1)"
  assert_eq "$c: the note tmp/clouve-backup/needs-attention is root's, mode 600" "root 600" "$(in_app "$c" "stat -c '%U %a' $file" 2>&1)"
  assert_eq "$c: it has the FAILED line's words as its reason, both versions and the kind" \
    "reason=${rest#*: }|from=$from|to=$to|kind=repair" "$(grep -E '^(reason|from|to|kind)=' <<< "$note" | paste -sd'|')"
  assert_eq "$c: and five lines, one of them the time in UTC" "5 1" \
    "$(grep -c . <<< "$note") $(grep -cE '^since=20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<< "$note")"
}
# staff_puts_state_back CASE: the README's step for a state folder the image moved aside: look at it, give it
# back to root, close it, and give it its name again.
staff_puts_state_back() {
  in_app "$1" 'cd /var/www/html/tmp && d="$(ls -d clouve-backup.untrusted-* | head -n 1)" && chown -hR root:root "$d" && chmod -R go= "$d" && mv "$d" clouve-backup'
}
# setting_of CASE: what SuiteCRM's own settings say about the scheduler: on or off.
setting_of() {
  in_app "$1" 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php scheduler 2>/dev/null'
}
jobs_done() { sc_sql "$(db_of "$1")" suitecrm "SELECT COUNT(*) FROM job_queue"; }

# run_php CASE FILE: runs one of the test's PHP scripts in the case's app container, as www-data. SuiteCRM refuses
# a script that PHP reads from standard input, so the script goes into a file there first.
run_php() {
  docker exec -i "$(app_of "$1")" sh -c 'cat > /tmp/sct.php && chmod 644 /tmp/sct.php' < "$2" || return 1
  docker exec -u www-data -e "SC_T_USER_PW=$USER_PW" -e "SC_T_SMTP_PW=$SMTP_PW" -e "SC_T_OAUTH_SECRET=$OAUTH_SECRET" \
    "$(app_of "$1")" php -d display_errors=0 /tmp/sct.php 2>/dev/null
}
# fingerprint CASE: what tests/lib/suitecrm-verify.php prints in the case's app container.
fingerprint() { run_php "$1" "$SCRIPT_DIR/lib/suitecrm-verify.php"; }
# admin_signs_in CASE: what POST /login answers for the admin.
admin_signs_in() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "T_U=$ADMIN_USER" -e "T_P=$ADMIN_PW" "$(app_of "$1")" bash -c '
    J="$(mktemp)"; B="$(mktemp)"; trap "rm -f \"$J\" \"$B\"" EXIT
    curl -s -o /dev/null -c "$J" http://127.0.0.1/
    curl -s -o /dev/null -b "$J" -c "$J" http://127.0.0.1/session-status
    X="$(awk "\$6==\"XSRF-TOKEN\"{print \$7}" "$J")"
    php -r "echo json_encode([\"username\" => getenv(\"T_U\"), \"password\" => getenv(\"T_P\")]);" > "$B"
    curl -s -b "$J" -c "$J" -H "Content-Type: application/json" -H "X-XSRF-TOKEN: $X" --data-binary "@$B" \
      http://127.0.0.1/login' 2>/dev/null
}
# plugin_calls CASE: the status codes of the LimeSurvey plugin's token request and of one API call with the token.
plugin_calls() {
  # shellcheck disable=SC2016  # the script is for the bash inside the container
  docker exec -e "T_U=$ADMIN_USER" -e "T_P=$ADMIN_PW" -e "T_S=$OAUTH_SECRET" "$(app_of "$1")" bash -c '
    T="$(mktemp)"; trap "rm -f \"$T\"" EXIT
    a=$(curl -s -o "$T" -w "%{http_code}" -X POST http://127.0.0.1/Api/access_token \
      --data-urlencode grant_type=password --data-urlencode client_id=limesurvey-sct1 \
      --data-urlencode "client_secret=$T_S" --data-urlencode "username=$T_U" --data-urlencode "password=$T_P")
    token=$(php -r "echo json_decode(file_get_contents(\"$T\"), true)[\"access_token\"] ?? \"\";")
    b=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/Api/V8/meta/modules \
      -H "Accept: application/vnd.api+json" -H "Authorization: Bearer $token")
    echo "$a $b"' 2>/dev/null
}
# site_is CASE VERSION: the site runs VERSION and holds everything the 8.9.1 site was given.
site_is() {
  local c="$1" want="$2" files
  assert_eq "$c: VERSION on the volume is $want" "$want" "$(in_app "$c" 'cat /var/www/html/VERSION')"
  if [ "$want" = "$NEW" ]; then
    assert_eq "$c: the database records $NEW as installed" "$NEW" "$(db_version_row "$c")"
    assert_eq "$c: SuiteCRM's own version command prints $NEW" "$NEW" \
      "$(in_app "$c" 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php bin/console suitecrm:version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | tail -n 1')"
    files="$(in_app "$c" 'cd /var/www/html; cat media/documents/sct-private.txt public/media/images/sct-public.txt 2>&1 | xargs; ls -d uploads public/media-upload 2>/dev/null | xargs')"
    assert_eq "$c: the files from uploads/ and public/media-upload/ are in media/ and public/media/" "private file public file" "$files"
    if [ "$files" != "private file public file" ]; then
      in_app "$c" 'cd /var/www/html; find uploads media public/media-upload public/media 2>&1 | head -n 30; grep -n "Moved\|directory" logs/upgrade.log | tail -n 12' | sed 's/^/       | /'
    fi
  else
    assert_eq "$c: the database has no finished-upgrade row" "" "$(db_version_row "$c")"
    files="$(in_app "$c" 'cd /var/www/html; cat uploads/documents/sct-private.txt public/media-upload/images/sct-public.txt 2>&1 | xargs; ls -d media public/media 2>/dev/null | xargs')"
    assert_eq "$c: the files in uploads/ and public/media-upload/ are where 8.9 keeps them" "private file public file" "$files"
  fi
  assert_eq "$c: every record, link, setting, user, role and file is there" "$GOLD" "$(fingerprint "$c")"
  assert_contains "$c: the admin signs in" "$(admin_signs_in "$c")" '"login_success"'
  assert_eq "$c: the LimeSurvey plugin's OAuth2 client still gets a token and an API answer" "200 200" "$(plugin_calls "$c")"
  assert_eq "$c: every file is www-data's, the state folder and lost+found aside" "0" \
    "$(in_app "$c" 'cd /var/www/html && find . \( -path ./lost+found -o -path ./tmp/clouve-backup \) -prune -o ! -user www-data -print | wc -l')"
}

# plant_failing_migration CASE: puts a migration that fails into the new code, while the upgrade pauses between
# SuiteCRM's two commands. The second command then changes the database and fails. The way back removes the file
# with the rest of that code.
plant_failing_migration() {
  docker exec -i -u www-data "$(app_of "$1")" sh -c 'cat > /var/www/html/core/backend/Migrations/Version20991231235959.php' <<'PHP'
<?php

declare(strict_types=1);

namespace App\Migrations;

use Doctrine\DBAL\Schema\Schema;

final class Version20991231235959 extends BaseMigration
{
    public function getDescription(): string
    {
        return 'test: fails on purpose';
    }

    public function up(Schema $schema): void
    {
        throw new \RuntimeException('forced failure for the upgrade test');
    }

    public function down(Schema $schema): void
    {
    }
}
PHP
}

# clone CASE: the case gets its own copy of the 8.9.1 site's two volumes.
clone() {
  sc_copy_volume "$GOLD_DATA" "$(data_of "$1")" && sc_copy_volume "$GOLD_DBDATA" "$(dbdata_of "$1")"
}
drop_case() {
  [ "${SC_KEEP:-false}" = true ] && return 0
  sc_save_log "$(app_of "$1")"
  docker rm -f -v "$(app_of "$1")" "$(db_of "$1")" >/dev/null 2>&1
  docker volume rm -f "$(data_of "$1")" "$(dbdata_of "$1")" >/dev/null 2>&1
}
wants() { local c; for c in "${CASES[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

# A package that isn't a zip, for the cases where SuiteCRM's upgrade has to fail, and another build id.
head -c 2048 /dev/urandom > "$SC_WORK/bad.zip"
echo 0000000000000000 > "$SC_WORK/other-build"
chmod 644 "$SC_WORK/bad.zip" "$SC_WORK/other-build"
BAD_ZIP=(-v "$SC_WORK/bad.zip:/clouve/suitecrm/SuiteCRM-$NEW.zip:ro")

# --- the 8.9.1 site ---------------------------------------------------------------
if [ "$GOLD_REUSED" = true ]; then
  echo
  echo "The $OLD site of an earlier run ($SUITECRM_TEST_GOLD)"
  GOLD="$(cat "$SUITECRM_TEST_GOLD/fingerprint")"
  pass "the site's volumes and its $(grep -c . <<< "$GOLD") facts are there"
else
  echo
  echo "The $OLD site (image $OLD_APP_IMAGE, database $OLD_DB_IMAGE)"
  sc_new_disk "${SC_PREFIX}gold-data"
  sc_new_disk "${SC_PREFIX}gold-dbdata"
  if ! db_start gold "$OLD_DB_IMAGE"; then
    fail "the old database starts"
    docker logs --tail 20 "$(db_of gold)" 2>&1 | sed 's/^/       | /'
    exit 1
  fi
  SC_APP_IMAGE="$OLD_APP_IMAGE" SC_APP_MEMORY=2g app_start gold
  if wait_up gold 400; then
    pass "SuiteCRM $OLD installs on new disks"
  else
    fail "SuiteCRM $OLD installs on new disks"
    show_log gold 30
    exit 1
  fi
  seeded="$(run_php gold "$SCRIPT_DIR/lib/suitecrm-seed.php" | tail -n 1)"
  assert_eq "the site gets its records, users, settings and files" "seeded" "$seeded"
  GOLD="$(fingerprint gold)"
  if [ "$(grep -c . <<< "$GOLD")" -ge 20 ] && ! grep -qE 'MISSING|=NO|ok=NO' <<< "$GOLD"; then
    pass "and reads them back ($(grep -c . <<< "$GOLD") facts)"
  else
    fail "and reads them back"
    sed 's/^/       | /' <<< "$GOLD"
    exit 1
  fi
  assert_eq "it is SuiteCRM $OLD on MariaDB 12.1" "$OLD 12.1" \
    "$(in_app gold 'cat /var/www/html/VERSION') $(docker exec "$(db_of gold)" cat /var/lib/mysql/mariadb_upgrade_info | cut -d. -f1,2)"
  assert_eq "the plugin's OAuth2 client works on $OLD" "200 200" "$(plugin_calls gold)"
  docker stop -t 30 "$(app_of gold)" >/dev/null 2>&1
  docker stop -t 60 "$(db_of gold)" >/dev/null 2>&1
  docker rm -f "$(app_of gold)" "$(db_of gold)" >/dev/null 2>&1
  if [ -n "${SUITECRM_TEST_GOLD:-}" ] && [ "$FAILED" -eq 0 ]; then
    docker volume rm -f "${GOLD_KEPT}data" "${GOLD_KEPT}dbdata" >/dev/null 2>&1
    mkdir -p "$SUITECRM_TEST_GOLD" && chmod 700 "$SUITECRM_TEST_GOLD" &&
      sc_copy_volume "$GOLD_DATA" "${GOLD_KEPT}data" && sc_copy_volume "$GOLD_DBDATA" "${GOLD_KEPT}dbdata" &&
      ( umask 077
        for name in DB_PW ROOT_PW OPS_PW ADMIN_PW USER_PW SMTP_PW OAUTH_SECRET; do printf '%s=%q\n' "$name" "${!name}"; done > "$SUITECRM_TEST_GOLD/secrets"
        printf '%s\n' "$GOLD" > "$SUITECRM_TEST_GOLD/fingerprint"
        printf '%s\n' "$GOLD_KEPT" > "$SUITECRM_TEST_GOLD/volumes" ) &&
      echo "       kept for later runs: ${GOLD_KEPT}data, ${GOLD_KEPT}dbdata and $SUITECRM_TEST_GOLD"
  fi
fi
SECRETS=("$DB_PW" "$ROOT_PW" "$OPS_PW" "$ADMIN_PW" "$USER_PW" "$SMTP_PW" "$OAUTH_SECRET")

# --- plain ------------------------------------------------------------------------
if wants plain; then
  echo
  echo "plain: the upgrade"
  c=plain
  clone $c
  # The earlier image set every mode to 755 at each start, the key that encrypts stored mail passwords included.
  on_volume $c 'chmod -R 755 /v/public/legacy/custom/blowfish' >/dev/null
  if db_start $c; then
    pass "$c: the new database image starts on the 12.1 data and answers after $((SECONDS - DB_STARTED)) s, its upgrade included"
  else
    fail "$c: the new database image starts on the 12.1 data"
  fi
  app_start $c
  sc_watch_cmdlines "$(app_of $c)" /root/cmdlines.log 120
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  sc_watch_stop "$(app_of $c)" /root/cmdlines.log
  log="$(app_log $c)"
  done_line="$(grep -F '[clouve-upgrade] DONE' <<< "$log" | tail -n 1)"
  assert_contains "$c: the log has the upgrade's finishing line" "$done_line" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  for phase in backup upgrade; do
    assert_eq "$c: the log has one line for the $phase phase" "1" "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase $phase" <<< "$log")"
  done
  site_is $c "$NEW"
  assert_eq "$c: no state is left" "" "$(in_app $c 'cat /var/www/html/tmp/clouve-backup/state 2>/dev/null')"
  assert_eq "$c: SuiteCRM's upgrade leftovers are gone" "" "$(in_app $c 'ls /var/www/html/tmp/package 2>/dev/null')"
  assert_eq "$c: the backup is kept: a folder of root's, mode 700, with files of mode 600" \
    "root 700 root 600 root 600 root 600" \
    "$(in_app $c "cd /var/www/html/tmp/clouve-backup && stat -c '%U %a' $OLD-to-$NEW $OLD-to-$NEW/code.tar.gz $OLD-to-$NEW/db.sql.gz $OLD-to-$NEW/complete | xargs")"
  assert_eq "$c: nothing in the state folder is open to others" "" \
    "$(in_app $c 'find /var/www/html/tmp/clouve-backup \( ! -user root -o -perm /go=rwx \) -print')"
  assert_eq "$c: the code archive leaves the customer's files where they are" "0" \
    "$(in_app $c "tar -tzf /var/www/html/tmp/clouve-backup/$OLD-to-$NEW/code.tar.gz | grep -cE '^\./(tmp|cache|uploads|media|public/media-upload|public/media|public/legacy/upload)/.'")"
  assert_eq "$c: www-data can't read the backup" "denied" \
    "$(in_app $c "setpriv --reuid=www-data --regid=www-data --init-groups -- ls /var/www/html/tmp/clouve-backup >/dev/null 2>&1 && echo readable || echo denied")"
  assert_eq "$c: the database settings in config.php name this container's database" "$(db_of $c)" \
    "$(in_app $c "setpriv --reuid=www-data --regid=www-data --init-groups -- php -r 'include \"/var/www/html/public/legacy/config.php\"; echo \$sugar_config[\"dbconfig\"][\"db_host_name\"];'")"
  assert_contains "$c: the data directory moved to MariaDB 12.3" \
    "$(docker exec "$(db_of $c)" cat /var/lib/mysql/mariadb_upgrade_info)" "12.3."
  assert_eq "$c: the top folder kept its owner and mode" "www-data:www-data 755" "$(in_app $c 'stat -c "%U:%G %a" /var/www/html')"
  assert_eq "$c: the OAuth2 private key is mode 600" "600" "$(in_app $c 'stat -c %a /var/www/html/public/legacy/Api/V8/OAuth2/private.key')"
  assert_eq "$c: the key that encrypts stored mail passwords, and its folder, are closed to others" "1 0" \
    "$(in_app $c 'cd /var/www/html/public/legacy/custom/blowfish && echo "$(find . -type f | wc -l) $(find . -perm /o=rwx | wc -l)"')"
  assert_eq "$c: no password was on a command line during the upgrade" "0" \
    "$(sc_count_secrets_in "$(app_of $c)" /root/cmdlines.log "${SECRETS[@]}")"
  assert_contains "$c: the watcher saw SuiteCRM's upgrade command" "$(in_app $c 'sort -u /root/cmdlines.log')" "suitecrm:app:upgrade"
  echo "       command lines seen during the upgrade (php, the database clients, tar and gzip):"
  in_app $c 'sort -u /root/cmdlines.log | grep -E "^(php|mysql|mysqldump|mariadb|tar|gzip|gunzip) " | cut -c1-170' | sed 's/^/       | /'
  assert_eq "$c: no password is in the container's log" "0" "$(sc_count_secrets_in_log "$(app_of $c)" "${SECRETS[@]}")"
  in_app $c 'cat /var/www/html/tmp/clouve-backup/*.log /var/www/html/tmp/clouve-backup/state /var/www/html/tmp/clouve-backup/*/complete /var/www/html/logs/upgrade.log 2>/dev/null > /root/up-logs.txt; chmod 600 /root/up-logs.txt' >/dev/null
  assert_eq "$c: nor in the upgrade's own logs and state" "0" "$(sc_count_secrets_in "$(app_of $c)" /root/up-logs.txt "${SECRETS[@]}")"
  # The scheduler never ran on this install, so it is held until someone releases it: SuiteCRM's own settings
  # don't switch it on, which only a new install and a release do.
  assert_eq "$c: the scheduler is held" "off" "$(setting_of $c)"
  sc_wait_log "$(app_of $c)" "the scheduler is held" 90 >/dev/null
  assert_contains "$c: the log says so" "$(app_log $c)" "the scheduler is held"
  assert_eq "$c: www-data is an allowed cron user all the same" "yes" \
    "$(in_app $c 'setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php cron')"
  assert_eq "$c: the Messenger worker runs as www-data" "www-data" \
    "$(in_app $c 'ps -eo user:12,args | awk "/php .*messenger:consume internal-async/ && !/awk/{print \$1}" | sort -u')"
  sleep 65
  assert_eq "$c: no scheduled job has run while it is held" "0" "$(sc_sql "$(db_of $c)" suitecrm "SELECT COUNT(*) FROM job_queue")"
  in_app $c '/clouve/suitecrm/installer/release-scheduler.sh' >/dev/null
  if sc_wait_for 180 bash -c "[ \"\$(docker exec -e MYSQL_PWD='$ROOT_PW' $(db_of $c) mariadb -uroot -N -B suitecrm -e \"SELECT COUNT(*) FROM job_queue WHERE status='done' AND resolution='success'\")\" -gt 0 ]"; then
    pass "$c: once it is released, the scheduler runs its jobs"
  else
    fail "$c: once it is released, the scheduler runs its jobs"
    show_log $c 10
  fi
  echo "       wall time of the upgrade at 1 GB and one CPU: $(sed -n 's/.* in \([0-9][0-9]*\) s\..*/\1/p' <<< "$done_line") s; peak memory of the app container: $(sc_peak_mb "$(app_of $c)") MB of 1024 (page cache included), $(in_app $c 'awk "/^anon /{print int(\$2 / 1048576)}" /sys/fs/cgroup/memory.stat') MB anonymous now; OOM kills: $(in_app $c 'sed -n "s/^oom_kill //p" /sys/fs/cgroup/memory.events')"
  # A second start.
  app_start $c
  if wait_up $c 180; then pass "$c: a second start comes up"; else fail "$c: a second start comes up"; show_log $c; fi
  assert_eq "$c: and doesn't upgrade again" "0" "$(count_in_log $c "phase backup")"
  assert_eq "$c: the released scheduler stays released" "on released" "$(setting_of $c) $(in_app $c '[ -e /var/www/html/tmp/clouve-backup/scheduler-held ] || echo released')"
  assert_contains "$c: the admin still signs in" "$(admin_signs_in $c)" '"login_success"'
  drop_case $c
fi

# --- slow -------------------------------------------------------------------------
if wants slow; then
  echo
  echo "slow: an upgrade that outlasts the health check's 105 seconds"
  c=slow
  clone $c
  db_start $c || fail "$c: the database starts"
  started=$SECONDS
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:120
  # One probe a second, as the platform's would see the container: its status code, or 000 without an answer.
  probes="$SC_WORK/probes"
  : > "$probes"
  ( while [ ! -e "$SC_WORK/probes.stop" ]; do echo "$(sc_http "$(app_of $c)" / --max-time 5)" >> "$probes"; sleep 1; done ) &
  prober=$!
  if sc_wait_log "$(app_of $c)" "test pause at upgrade" 180; then pass "$c: the upgrade reaches the test's pause"; else fail "$c: the upgrade reaches the test's pause"; show_log $c; fi
  assert_eq "$c: GET / answers 200" "200" "$(sc_http "$(app_of $c)" /)"
  assert_eq "$c: the plugin's token request gets 503, not a page" "503" "$(sc_http "$(app_of $c)" /Api/access_token -X POST)"
  assert_contains "$c: the stand-in names itself in a header" \
    "$(docker exec "$(app_of $c)" curl -s -D - -o /dev/null http://127.0.0.1/ 2>/dev/null | tr -d '\r')" "X-Clouve-Standin: suitecrm"
  assert_eq "$c: PID 1 is the entrypoint, and the stand-in runs as nobody" "entrypoint.sh nobody" \
    "$(sc_pid1 "$(app_of $c)") $(in_app $c 'ps -eo user:20,args | awk "/ -S 0\.0\.0\.0:80 /{print \$1}" | sort -u')"
  assert_ok "$c: sshd answers during the upgrade" docker exec "$(app_of $c)" bash -c '</dev/tcp/127.0.0.1/22'
  assert_eq "$c: the state file says phase upgrade, from $OLD to $NEW, first attempt" "upgrade $OLD $NEW 1" \
    "$(state_in $c phase from to attempts)"
  if wait_up $c 400; then pass "$c: the site comes up, $((SECONDS - started)) s after the container started"; else fail "$c: the site comes up"; show_log $c 40; fi
  touch "$SC_WORK/probes.stop"
  wait "$prober" 2>/dev/null
  rm -f "$SC_WORK/probes.stop"
  # From the first 200 on, the probe never fails for long. The hand-over from the stand-in to Apache may cost a probe.
  verdict="$(awk '
    $1 == 200 { seen = 1; run = 0; good++; next }
    seen { run++; if (run > worst) worst = run }
    END { printf "answers=%d longest-gap=%d", good, worst + 0 }' "$probes")"
  good="${verdict#answers=}"; good="${good%% *}"
  gap="${verdict##*=}"
  if [ "$good" -ge 105 ] && [ "$gap" -le 5 ]; then
    pass "$c: the health check passed all the way ($good answers of 200, longest gap $gap s)"
  else
    fail "$c: the health check passed all the way ($verdict)"
  fi
  assert_eq "$c: the container was never restarted" "0" "$(docker inspect --format '{{.RestartCount}}' "$(app_of $c)")"
  assert_eq "$c: no stand-in is left" "0" "$(in_app $c 'pgrep -fc -- "-S 0.0.0.0:80"')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- stale-cache ------------------------------------------------------------------
if wants stale-cache; then
  echo
  echo "stale-cache: SuiteCRM's compiled settings look fresh when the upgrade reads them"
  c=stale-cache
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c
  # For as long as the upgrade runs, the compiled container's file is given the current time five times a second.
  # touch -c never creates the file, so a cache folder that was removed stays removed.
  docker exec -d "$(app_of $c)" bash -c 'end=$((SECONDS + 240)); while [ "$SECONDS" -lt "$end" ] && [ "$(cat /proc/1/comm)" != apache2 ]; do touch -c /var/www/html/cache/prod/*Container.php /var/www/html/cache/prod/Container*/*Container.php 2>/dev/null; sleep 0.2; done'
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  assert_contains "$c: the upgrade ran" "$(app_log $c)" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  drop_case $c
fi

# --- fail -------------------------------------------------------------------------
if wants fail; then
  echo
  echo "fail: SuiteCRM's upgrade fails twice"
  c=fail
  clone $c
  db_start $c || fail "$c: the database starts"
  before="$(db_hash $c)"
  app_start $c "${BAD_ZIP[@]}"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_eq "$c: the upgrade was tried twice" "2" "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase upgrade" <<< "$log")"
  assert_eq "$c: and the way back ran twice" "2" "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log")"
  assert_contains "$c: the log has the failure line" "$log" "[clouve-upgrade] FAILED suitecrm $OLD -> $NEW: "
  assert_eq "$c: the database was never changed, so neither way back touched it" "2" \
    "$(grep -c "the database is left as it is" <<< "$log")"
  assert_eq "$c: it is, table for table and row for row, what it was before the upgrade" "$before" "$(db_hash $c)"
  site_is $c "$OLD"
  assert_eq "$c: the state says failed, for this build" "failed $BUILD 2" "$(state_in $c phase build attempts)"
  assert_eq "$c: upgrade-failed is there for staff to read" "yes" \
    "$(in_app $c 'grep -q "8.9.1" /var/www/html/tmp/clouve-backup/upgrade-failed && echo yes')"
  assert_eq "$c: the state file and upgrade-failed are root's, mode 600, and nothing in the state folder is open to others" \
    "root 600 root 600 0" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && stat -c "%U %a" state upgrade-failed | xargs; find . \( ! -user root -o -perm /go=rwx \) -print | wc -l' | xargs)"
  assert_eq "$c: no Messenger worker on $OLD, and the scheduler is held" "0 off" \
    "$(in_app $c 'pgrep -u www-data -fc "messenger:consume"') $(setting_of $c)"
  assert_eq "$c: SuiteCRM's upgrade leftovers are gone" "" "$(in_app $c 'ls /var/www/html/tmp/package 2>/dev/null')"
  app_start $c
  if wait_up $c 180; then pass "$c: the next start, with a good package and the same build, comes up"; else fail "$c: the next start comes up"; show_log $c; fi
  assert_eq "$c: it doesn't try again" "0" "$(count_in_log $c "phase backup")"
  assert_contains "$c: and says why, and how to try again" "$(app_log $c)" "upgrade-failed to try again"
  assert_eq "$c: it still runs $OLD" "$OLD" "$(in_app $c 'cat /var/www/html/VERSION')"
  OTHER_BUILD=(-v "$SC_WORK/other-build:/clouve/suitecrm/BUILD:ro")
  app_start $c "${OTHER_BUILD[@]}" "${BAD_ZIP[@]}"
  if wait_up $c 400; then pass "$c: another build of the image comes up"; else fail "$c: another build of the image comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it tried again by itself" "$log" "so this build tries again"
  assert_eq "$c: twice, from a new backup that replaced the earlier one" "2 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase upgrade" <<< "$log") $(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase backup" <<< "$log")"
  assert_eq "$c: its package was broken too, so the state says failed for that build, and one backup is kept" \
    "failed 0000000000000000 $OLD-to-$NEW" "$(state_in $c phase build) $(in_app $c 'cd /var/www/html/tmp/clouve-backup && ls -d *-to-* | xargs')"
  assert_eq "$c: it still runs $OLD" "$OLD" "$(in_app $c 'cat /var/www/html/VERSION')"
  in_app $c 'rm -f /var/www/html/tmp/clouve-backup/upgrade-failed' >/dev/null
  app_start $c "${OTHER_BUILD[@]}"
  if wait_up $c 400; then pass "$c: with the failure file removed and a good package, the same build comes up"; else fail "$c: the start after the failure file was removed comes up"; show_log $c 40; fi
  assert_contains "$c: it upgraded" "$(app_log $c)" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  assert_eq "$c: no state is left" "" "$(in_app $c 'cat /var/www/html/tmp/clouve-backup/state 2>/dev/null')"
  drop_case $c
fi

# --- finalize ---------------------------------------------------------------------
if wants finalize; then
  echo
  echo "finalize: the second upgrade command fails once"
  c=finalize
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:25
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  plant_failing_migration $c
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_eq "$c: the first try failed and the way back ran once" "2 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase upgrade" <<< "$log") $(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log")"
  assert_contains "$c: the second try succeeded" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  assert_lacks "$c: the database had changed, so the way back loaded the dump" "$log" "the database is left as it is"
  site_is $c "$NEW"
  drop_case $c
fi

# --- kill-backup ------------------------------------------------------------------
if wants kill-backup; then
  echo
  echo "kill-backup: killed while the backup is written"
  c=kill-backup
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=backup:120
  sc_wait_log "$(app_of $c)" "test pause at backup" 180 || { fail "$c: the backup reaches the test's pause"; show_log $c; }
  assert_eq "$c: the state says phase backup, and the backup has no final name yet" "backup partial" \
    "$(state_in $c phase) $(in_app $c "cd /var/www/html/tmp/clouve-backup && [ -d $OLD-to-$NEW.partial ] && [ ! -e $OLD-to-$NEW ] && echo partial")"
  docker kill "$(app_of $c)" >/dev/null
  app_start $c
  if wait_up $c 400; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it removed the unfinished backup and started over" "$log" "the backup was cut off"
  assert_contains "$c: and upgraded" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  assert_eq "$c: one backup is kept, and no partial one" "$OLD-to-$NEW" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && ls -d *-to-* | xargs')"
  drop_case $c
fi

# --- kill-upgrade -----------------------------------------------------------------
if wants kill-upgrade; then
  echo
  echo "kill-upgrade: killed between SuiteCRM's two upgrade commands"
  c=kill-upgrade
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:120
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  assert_eq "$c: at the kill, VERSION already says $NEW and the database has no finished-upgrade row" "$NEW " \
    "$(in_app $c 'cat /var/www/html/VERSION') $(db_version_row $c)"
  before="$(db_hash $c)"
  docker kill "$(app_of $c)" >/dev/null
  app_start $c -e CLOUVE_TEST_PAUSE=restored:45
  # The test's pause right after the way back, before the second try changes anything.
  sc_wait_log "$(app_of $c)" "test pause at restored" 240 || { fail "$c: the way back reaches the test's pause"; show_log $c; }
  assert_eq "$c: after the way back the database is, table for table and row for row, what it was" "$before" "$(db_hash $c)"
  assert_eq "$c: and the code is $OLD's again" "$OLD" "$(in_app $c 'cat /var/www/html/VERSION')"
  if wait_up $c 400; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it found the upgrade cut off and put the old version back first" "$log" "the upgrade was cut off"
  assert_eq "$c: the way back ran once, then the upgrade" "1 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log") $(grep -c "^\[clouve-upgrade\] DONE suitecrm $OLD -> $NEW" <<< "$log")"
  assert_contains "$c: the database had not been changed yet, so the way back left it alone" "$log" "the database is left as it is"
  site_is $c "$NEW"
  drop_case $c
fi

# --- kill-restore -----------------------------------------------------------------
if wants kill-restore; then
  echo
  echo "kill-restore: killed during the way back"
  c=kill-restore
  clone $c
  db_start $c || fail "$c: the database starts"
  before="$(db_tables $c)"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:25,restore:120
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  # The same failing migration as in the finalize case: the second command changes the database and then fails.
  plant_failing_migration $c
  sc_wait_log "$(app_of $c)" "test pause at restore" 300 || { fail "$c: the way back reaches the test's pause"; show_log $c; }
  assert_eq "$c: at the kill the state says phase restore and the database's tables are dropped" "restore 0" \
    "$(state_in $c phase) $(db_tables $c)"
  docker kill "$(app_of $c)" >/dev/null
  app_start $c
  if wait_up $c 400; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it ran the way back again" "$log" "the way back was cut off"
  assert_lacks "$c: and loaded the dump, because the database had been changed" "$log" "the database is left as it is"
  assert_contains "$c: then it upgraded" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  if [ "$(db_tables $c)" -gt "$before" ]; then pass "$c: the database has its tables again, and the new version's"; else fail "$c: the database has its tables again ($(db_tables $c), $before before)"; fi
  site_is $c "$NEW"
  drop_case $c
fi

# --- kill-cleanup -----------------------------------------------------------------
if wants kill-cleanup; then
  echo
  echo "kill-cleanup: killed after the upgrade succeeded, before its clean-up"
  c=kill-cleanup
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=cleanup:120
  sc_wait_log "$(app_of $c)" "test pause at cleanup" 240 || { fail "$c: the clean-up reaches the test's pause"; show_log $c; }
  assert_eq "$c: at the kill the database records $NEW and the state still says phase upgrade" "$NEW upgrade" \
    "$(db_version_row $c) $(state_in $c phase)"
  docker kill "$(app_of $c)" >/dev/null
  app_start $c
  if wait_up $c 400; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it found the upgrade finished and only cleaned up" "$log" "had finished"
  assert_eq "$c: nothing was put back and nothing ran twice" "0 0" \
    "$(grep -c "phase restore" <<< "$log") $(grep -c "phase backup" <<< "$log")"
  assert_eq "$c: no state and no leftovers" "" "$(in_app $c 'cat /var/www/html/tmp/clouve-backup/state 2>/dev/null; ls /var/www/html/tmp/package 2>/dev/null')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- restore-fails ----------------------------------------------------------------
if wants restore-fails; then
  echo
  echo "restore-fails: the way back can't reach the database"
  c=restore-fails
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:30
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  docker stop -t 60 "$(db_of $c)" >/dev/null
  if wait_exit $c 300; then pass "$c: the container stops"; else fail "$c: the container stops"; show_log $c 40; fi
  assert_eq "$c: with a failing status" "1" "$(docker inspect --format '{{.State.ExitCode}}' "$(app_of $c)")"
  log="$(app_log $c)"
  assert_contains "$c: the log has the failure line" "$log" "[clouve-upgrade] FAILED suitecrm $OLD -> $NEW: "
  assert_lacks "$c: Apache was never started" "$log" "starting Apache"
  assert_eq "$c: the state is kept, at phase restore" "restore" "$(state_of $c phase)"
  docker start "$(db_of $c)" >/dev/null
  sc_wait_for 240 docker exec "$(db_of $c)" healthcheck.sh --connect --innodb_initialized
  app_start $c
  if wait_up $c 400; then pass "$c: with the database back, the next start comes up"; else fail "$c: with the database back, the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it ran the way back again, then the upgrade" "$log" "the way back was cut off"
  site_is $c "$NEW"
  drop_case $c
fi

# --- bad-dump ---------------------------------------------------------------------
if wants bad-dump; then
  echo
  echo "bad-dump: the backup's dump is cut short after it was stamped"
  c=bad-dump
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:120
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  in_app $c "truncate -s 3000 /var/www/html/tmp/clouve-backup/$OLD-to-$NEW/db.sql.gz" >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  tables="$(db_tables $c)"
  app_start $c
  # A site between two versions with no backup the image can trust. Nothing a restart does can repair it, so
  # the container doesn't exit: it waits, with the stand-in and the sshd up, for staff or the AI Assistant.
  assert_waiting $c "no good backup"
  log="$(app_log $c)"
  assert_contains "$c: as a failure line" "$log" "[clouve-upgrade] FAILED suitecrm $OLD -> $NEW: "
  assert_eq "$c: no table was dropped" "$tables" "$(db_tables $c)"
  assert_eq "$c: the files were left as they were, and the state is kept" "$NEW upgrade" \
    "$(in_app $c 'cat /var/www/html/VERSION') $(state_in $c phase)"
  drop_case $c
fi

# --- newer ------------------------------------------------------------------------
if wants newer; then
  echo
  echo "newer: a volume with a newer SuiteCRM"
  c=newer
  clone $c
  db_start $c || fail "$c: the database starts"
  on_volume $c 'echo 9.9.9 > /v/VERSION' >/dev/null
  tables="$(db_tables $c)"
  app_start $c
  if wait_exit $c 120; then pass "$c: the container stops"; else fail "$c: the container stops"; show_log $c; fi
  assert_eq "$c: with a failing status" "1" "$(docker inspect --format '{{.State.ExitCode}}' "$(app_of $c)")"
  assert_contains "$c: the log says the volume's SuiteCRM is newer than the image's" "$(app_log $c)" "SuiteCRM 9.9.9, which is newer than this image's $NEW"
  assert_eq "$c: nothing was changed" "9.9.9 $tables none" \
    "$(on_volume $c 'cat /v/VERSION') $(db_tables $c) $(on_volume $c '[ -e /v/tmp/clouve-backup ] && echo state-folder || echo none')"
  drop_case $c
fi

# --- unfinished -------------------------------------------------------------------
if wants unfinished; then
  echo
  echo "unfinished: VERSION says $NEW, the database doesn't, and neither a state nor a backup is left"
  c=unfinished
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:120
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  in_app $c 'rm -rf /var/www/html/tmp/clouve-backup' >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  tables="$(db_tables $c)"
  app_start $c
  # A site between two versions with nothing to go back to is never started, and never backed up as if it were
  # a version: the container waits for someone to decide.
  assert_waiting $c "an upgrade was cut off"
  log="$(app_log $c)"
  assert_contains "$c: the log has a failure line that names the runbook" "$log" "[clouve-upgrade] FAILED suitecrm "
  assert_contains "$c: and says that no backup is there to go back to" "$log" "no backup"
  assert_eq "$c: it made no backup of the half-upgraded site and changed nothing" "0 $NEW  $tables" \
    "$(grep -c "phase backup" <<< "$log") $(in_app $c 'cat /var/www/html/VERSION') $(db_version_row $c) $(db_tables $c)"
  # One of the runbook's two ways out: staff decide to finish the upgrade on the site as it is.
  if in_app $c '/clouve/suitecrm/installer/upgrade.sh --finish-as-is' > "$SC_WORK/finish.out" 2>&1; then
    pass "$c: the runbook's command to finish the upgrade as it is ends well"
  else
    fail "$c: the runbook's command to finish the upgrade as it is ends well"
    tail -n 15 "$SC_WORK/finish.out" | sed 's/^/       | /'
  fi
  if wait_up $c 300; then pass "$c: the waiting container sees it and goes on: the site comes up"; else fail "$c: the waiting container sees it and goes on: the site comes up"; show_log $c 40; fi
  assert_eq "$c: the note is gone once the wait is over" "gone" \
    "$(in_app $c 'if [ -e /var/www/html/tmp/clouve-backup/needs-attention ]; then echo there; else echo gone; fi')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- space ------------------------------------------------------------------------
if wants space; then
  echo
  echo "space: too little free space on the volume"
  c=space
  # A volume just big enough for the site, in memory, with the site copied in.
  # Docker unmounts such a volume when no container uses it, so one holds it for the length of the case.
  docker volume create --driver local --opt type=tmpfs --opt device=tmpfs --opt o=size=620m "$(data_of $c)" >/dev/null
  docker run -d --name "${SC_PREFIX}$c-hold" --network none -v "$(data_of $c):/v" "$SC_SHAPER" sleep 3600 >/dev/null
  docker run --rm --network none -v "$GOLD_DATA:/from:ro" -v "$(data_of $c):/to" "$SC_SHAPER" \
    sh -c 'cp -a /from/. /to/ && chown "$(stat -c %u:%g /from)" /to && chmod "$(stat -c %a /from)" /to' >/dev/null
  sc_copy_volume "$GOLD_DBDATA" "$(dbdata_of $c)"
  db_start $c || fail "$c: the database starts"
  app_start $c
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: the log says there is too little space, as a failure line" "$log" "[clouve-upgrade] FAILED suitecrm $OLD -> $NEW: not enough free space"
  assert_eq "$c: no backup was started and no state was written" "0 none" \
    "$(grep -c "phase backup" <<< "$log") $(in_app $c '[ -e /var/www/html/tmp/clouve-backup/state ] && echo state || echo none')"
  site_is $c "$OLD"
  assert_eq "$c: the scheduler is held here too" "off" "$(setting_of $c)"
  assert_eq "$c: the reason, the versions and the time are in upgrade-skipped, root's and closed" "root 600 $OLD $NEW 1 1" \
    "$(in_app $c "cd /var/www/html/tmp/clouve-backup && stat -c '%U %a' upgrade-skipped | xargs; sed -n 's/^from=//p;s/^to=//p' upgrade-skipped | xargs; grep -c '^reason=not enough free space' upgrade-skipped; grep -cE '^time=20[0-9-]+T[0-9:]+Z$' upgrade-skipped" | xargs)"
  docker rm -f "${SC_PREFIX}$c-hold" >/dev/null 2>&1
  drop_case $c
fi

# --- trust-old-image --------------------------------------------------------------
if wants trust-old-image; then
  echo
  echo "trust-old-image: an upgrade is cut off, and the earlier image then starts once on the volume"
  c=trust-old-image
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  docker kill "$(app_of $c)" >/dev/null
  # What pushing the old tag back after a failed roll-out does: the earlier entrypoint gives the whole volume to
  # www-data and sets every mode to 755, at every start.
  SC_APP_IMAGE="$OLD_APP_IMAGE" app_start $c
  sc_wait_for 120 bash -c "[ \"\$(docker exec $(app_of $c) stat -c %U /var/www/html/tmp/clouve-backup 2>/dev/null)\" = www-data ]"
  assert_eq "$c: the earlier image gave the state folder and the backup to www-data" "www-data www-data" \
    "$(in_app $c "stat -c %U /var/www/html/tmp/clouve-backup /var/www/html/tmp/clouve-backup/$OLD-to-$NEW/db.sql.gz | xargs")"
  docker stop -t 20 "$(app_of $c)" >/dev/null 2>&1
  tables="$(db_tables $c)"
  app_start $c
  assert_waiting $c "is not a folder that only root can change"
  log="$(app_log $c)"
  assert_contains "$c: the log has a failure line for staff and alerts" "$log" "[clouve-upgrade] FAILED suitecrm "
  assert_contains "$c: it says where the folder went" "$log" "tmp/clouve-backup.untrusted-"
  assert_contains "$c: and how staff put it back after a look" "$log" "chown -hR root:root"
  assert_lacks "$c: nothing tells anyone to remove a folder" "$log" "Remove it"
  assert_eq "$c: the backup is still on the volume, whole" "3" \
    "$(in_app $c "ls /var/www/html/tmp/clouve-backup.untrusted-*/$OLD-to-$NEW/code.tar.gz /var/www/html/tmp/clouve-backup.untrusted-*/$OLD-to-$NEW/db.sql.gz /var/www/html/tmp/clouve-backup.untrusted-*/$OLD-to-$NEW/complete 2>/dev/null | wc -l")"
  assert_eq "$c: nothing was upgraded, backed up or dropped meanwhile" "$NEW  $tables 0" \
    "$(in_app $c 'cat /var/www/html/VERSION') $(db_version_row $c) $(db_tables $c) $(count_in_log $c "phase backup")"
  # The staff step from the README. The waiting container then goes on by itself.
  staff_puts_state_back $c >/dev/null
  if wait_up $c 400; then pass "$c: after the staff step the container goes on and the site comes up"; else fail "$c: after the staff step the container goes on and the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_eq "$c: it went back from the backup once, then upgraded" "1 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log") $(grep -c "^\[clouve-upgrade\] DONE suitecrm $OLD -> $NEW" <<< "$log")"
  site_is $c "$NEW"
  drop_case $c
fi

# --- trust-reset ------------------------------------------------------------------
if wants trust-reset; then
  echo
  echo "trust-reset: an upgrade is cut off during SuiteCRM's first command, then SuiteCRM's permission reset runs"
  c=trust-reset
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=aside:300
  sc_wait_log "$(app_of $c)" "test pause at aside" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  # SuiteCRM's first command is about to run. The customer's files are out of its reach by then.
  assert_eq "$c: uploads/ and public/media-upload/ are out of the install, in root's state folder" "gone gone private file public file" \
    "$(in_app $c 'cd /var/www/html; [ -e uploads ] || echo gone; [ -e public/media-upload ] || echo gone; cat tmp/clouve-backup/aside/uploads/documents/sct-private.txt tmp/clouve-backup/aside/public__media-upload/images/sct-public.txt 2>&1' | xargs)"
  # The earlier image installs anew, and drops the database, on a volume without .suitecrm_initialized. So the
  # marker stays in the install all the way, and the state folder has a copy.
  assert_eq "$c: the image's marker is still in the install, with a copy in the state folder" "in-place copy" \
    "$(in_app $c 'cd /var/www/html; [ -f .suitecrm_initialized ] && printf "in-place "; [ -f tmp/clouve-backup/aside/.suitecrm_initialized ] && printf copy')"
  assert_eq "$c: the state file says so" "upgrade aside" "$(state_in $c phase step)"
  docker kill "$(app_of $c)" >/dev/null
  # SuiteCRM's documented permission reset: everything that is not www-data's becomes www-data's.
  on_volume $c 'cd /v && find . ! -user 33 -exec chown -h 33:33 {} +' >/dev/null
  # And the earlier image starts once on the volume as it is now, in the middle of the upgrade's first step. It
  # must find its marker and leave the database alone: without the marker it would install anew and drop it.
  tables="$(db_tables $c)"
  SC_APP_IMAGE="$OLD_APP_IMAGE" app_start $c
  sc_wait_log "$(app_of $c)" "already initialized" 120 >/dev/null
  sleep 15
  old_log="$(app_log $c)"
  assert_contains "$c: the earlier image, started in between, finds its marker" "$old_log" "already initialized"
  assert_lacks "$c: and does not install over the site" "$old_log" "First-time initialization"
  assert_eq "$c: the database still has its tables and the customer's account" "$tables 1" \
    "$(db_tables $c) $(sc_sql "$(db_of $c)" suitecrm "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'Acme Research Ltd'")"
  docker stop -t 20 "$(app_of $c)" >/dev/null 2>&1
  app_start $c
  assert_waiting $c "is not a folder that only root can change"
  assert_eq "$c: the backup and the customer's files are still on the volume" "private file public file 3" \
    "$(in_app $c "cd /var/www/html/tmp/clouve-backup.untrusted-*/ && cat aside/uploads/documents/sct-private.txt aside/public__media-upload/images/sct-public.txt | xargs; ls $OLD-to-$NEW | wc -l" | xargs)"
  staff_puts_state_back $c >/dev/null
  # This time through a restart, as staff would do it.
  app_start $c
  if wait_up $c 400; then pass "$c: after the staff step the next start comes up"; else fail "$c: after the staff step the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it put the customer's files back, went back and upgraded" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  assert_eq "$c: nothing is left aside" "" "$(in_app $c 'ls -A /var/www/html/tmp/clouve-backup/aside 2>/dev/null')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- root-owned -------------------------------------------------------------------
if wants root-owned; then
  echo
  echo "root-owned: files of root's in the install, before an upgrade and in the middle of one"
  c=root-owned
  clone $c
  # What a command run as root in the container leaves behind (kubectl exec is root).
  on_volume $c 'mkdir -p /v/public/legacy/cache/sct-by-root && echo x > /v/public/legacy/cache/sct-by-root/file && echo x > /v/public/legacy/include/sct-by-root.php' >/dev/null
  db_start $c || fail "$c: the database starts"
  app_start $c "${BAD_ZIP[@]}"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: the upgrade was not tried, and the log names what is in the way" "$log" "public/legacy/include/sct-by-root.php"
  assert_eq "$c: no backup was started, nothing was removed" "0 $OLD" "$(grep -c "phase backup" <<< "$log") $(in_app $c 'cat /var/www/html/VERSION')"
  assert_eq "$c: the reason, the versions and the time are in upgrade-skipped, root's and closed" "root 600 $OLD $NEW 1 1" \
    "$(in_app $c "cd /var/www/html/tmp/clouve-backup && stat -c '%U %a' upgrade-skipped | xargs; sed -n 's/^from=//p;s/^to=//p' upgrade-skipped | xargs; grep -c '^reason=.*not www-data' upgrade-skipped; grep -cE '^time=20[0-9-]+T[0-9:]+Z$' upgrade-skipped" | xargs)"
  assert_eq "$c: every record, link, setting, user, role and file is there" "$GOLD" "$(fingerprint $c)"
  assert_contains "$c: the admin signs in" "$(admin_signs_in $c)" '"login_success"'
  # Staff give the files to www-data, as the note says. The next start upgrades. In the middle of it, root leaves
  # files in the new code and in the cache, and the upgrade then fails: the way back has to remove them.
  in_app $c 'chown -hR www-data:www-data /var/www/html/public/legacy/cache/sct-by-root /var/www/html/public/legacy/include/sct-by-root.php' >/dev/null
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 240 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  assert_eq "$c: a note of a skipped upgrade goes when an upgrade runs" "gone" \
    "$(in_app $c '[ -e /var/www/html/tmp/clouve-backup/upgrade-skipped ] || echo gone')"
  in_app $c 'cd /var/www/html && mkdir -p core/sct-root-dir/deep cache/prod/sct-root && echo x > core/sct-root-dir/deep/file && echo x > public/legacy/include/sct-root-file.php && chmod 700 core/sct-root-dir' >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  app_start $c "${BAD_ZIP[@]}" -e CLOUVE_TEST_PAUSE=removed:20
  # The test's pause in the middle of the way back: the upgraded code is gone and the old code is not back yet.
  sc_wait_log "$(app_of $c)" "test pause at removed" 240 || { fail "$c: the way back reaches the test's pause"; show_log $c; }
  assert_eq "$c: in the middle of the way back the code is gone, root's files with it, and the image's marker is still there" \
    "gone gone marker" "$(in_app $c 'cd /var/www/html; [ -e bin/console ] || printf "gone "; [ -e core/sct-root-dir ] || printf "gone "; [ -f .suitecrm_initialized ] && printf marker')"
  if wait_up $c 400; then pass "$c: the way back removes root's files with the rest, twice, and $OLD comes up"; else fail "$c: the way back removes root's files with the rest, twice, and $OLD comes up"; show_log $c 40; fi
  assert_eq "$c: the way back ran for the cut-off try and for the failed one" "2" "$(count_in_log $c "phase restore")"
  site_is $c "$OLD"
  drop_case $c
fi

# --- db-changed -------------------------------------------------------------------
if wants db-changed; then
  echo
  echo "db-changed: the database changes before SuiteCRM's second command, as a pre-upgrade migration does from 8.10 on"
  c=db-changed
  clone $c
  db_start $c || fail "$c: the database starts"
  before="$(db_hash $c)"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  sc_sql "$(db_of $c)" suitecrm "ALTER TABLE accounts ADD COLUMN sct_changed_c INT NULL; INSERT INTO config (category, name, value) VALUES ('sct', 'changed', 'yes'); UPDATE accounts SET sct_changed_c = 7;" >/dev/null
  assert_eq "$c: the table count and the version row are as before, so only a real comparison can tell" "$(db_tables $c) " \
    "$(sc_sql "$(db_of $c)" mysql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='suitecrm'") $(db_version_row $c)"
  docker kill "$(app_of $c)" >/dev/null
  app_start $c "${BAD_ZIP[@]}"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: the first way back saw the change and loaded the dump" "$log" "so the dump is loaded"
  assert_eq "$c: the column and the row are gone" " " \
    "$(sc_sql "$(db_of $c)" suitecrm "SHOW COLUMNS FROM accounts LIKE 'sct_changed_c'" | cut -f1) $(sc_sql "$(db_of $c)" suitecrm "SELECT value FROM config WHERE category='sct'")"
  assert_eq "$c: the database is, table for table and row for row, what it was before the upgrade" "$before" "$(db_hash $c)"
  site_is $c "$OLD"
  drop_case $c
fi

# --- stale-list -------------------------------------------------------------------
if wants stale-list; then
  echo
  echo "stale-list: SuiteCRM's compiled keep-list is the old one when the upgrade command would run"
  c=stale-list
  clone $c
  db_start $c || fail "$c: the database starts"
  # The image's library with the removal of the cache switched off: the compiled list stays the old one, in a form
  # SuiteCRM loads without complaint. The check before the first command is then the only thing that can say no.
  docker run --rm --network none --entrypoint cat "$APP_IMAGE" /clouve/suitecrm/installer/lib.sh > "$SC_WORK/lib-nodrop.sh"
  echo 'sc_symfony_cache_drop() { return 0; }' >> "$SC_WORK/lib-nodrop.sh"
  chmod 644 "$SC_WORK/lib-nodrop.sh"
  app_start $c -v "$SC_WORK/lib-nodrop.sh:/clouve/suitecrm/installer/lib.sh:ro"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  # The first try meets the old compiled list and must stop before SuiteCRM's command. The way back then removes
  # the cache itself, as root, so the second try compiles the list anew and may run the command.
  assert_eq "$c: the first try stopped at the check" "1" "$(grep -c "try 1 failed: the keep-list is not in effect" <<< "$log")"
  assert_eq "$c: SuiteCRM's upgrade command was not run in that try: it ran once, in the second" "1 1" \
    "$(in_app $c 'grep -c "^== suitecrm:app:upgrade " /var/www/html/tmp/clouve-backup/upgrade-console.log 2>/dev/null') $(grep -c "phase upgrade (try 2 of 2)" <<< "$log")"
  assert_contains "$c: the second try, with the list compiled anew, upgraded" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  drop_case $c

  echo
  echo "stale-list: cache is a link to a folder next to it, which SuiteCRM runs on"
  clone $c
  on_volume $c 'cd /v && mv cache cache.real && ln -s cache.real cache && chown -h 33:33 cache' >/dev/null
  db_start $c || fail "$c: the database starts"
  app_start $c
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  assert_contains "$c: the upgrade ran" "$(app_log $c)" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  assert_eq "$c: cache is a real folder now" "directory" "$(in_app $c 'stat -c %F /var/www/html/cache')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- files-gone -------------------------------------------------------------------
if wants files-gone; then
  echo
  echo "files-gone: the customer's files are gone when the way back looks for them"
  c=files-gone
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  in_app $c 'rm -rf /var/www/html/uploads /var/www/html/media' >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  app_start $c "${BAD_ZIP[@]}"
  assert_waiting $c "the backup recorded uploads/, and neither uploads/ nor media/ is on the volume"
  log="$(app_log $c)"
  assert_contains "$c: as a failure line" "$log" "[clouve-upgrade] FAILED suitecrm $OLD -> $NEW: "
  assert_lacks "$c: the log never claims that everything is back" "$log" "is back, files and database"
  drop_case $c
fi

# --- kill-anywhere ----------------------------------------------------------------
if wants kill-anywhere; then
  echo
  echo "kill-anywhere: killed at several moments of the upgrade and of the way back, not only at the pauses"
  c=kill-anywhere
  # Seconds after the upgrade phase began: during the keep-list step, while the customer's folders are out of the
  # install, during SuiteCRM's copy and during its second command (each line of the result names the step that
  # was running). SUITECRM_KILL_OFFSETS names other moments.
  for offset in ${SUITECRM_KILL_OFFSETS:-1 2 3 6 12}; do
    clone $c
    db_start $c || fail "$c +$offset s: the database starts"
    app_start $c
    if [ "$offset" = 1 ]; then
      # Once also in the middle of the backup, before the upgrade is killed.
      sc_wait_log "$(app_of $c)" "phase backup" 180 && sleep 1 && docker kill "$(app_of $c)" >/dev/null && app_start $c
    fi
    sc_wait_log "$(app_of $c)" "phase upgrade" 240 || { fail "$c +$offset s: the upgrade starts"; show_log $c; }
    sleep "$offset"
    at_kill="$(in_app $c 'sed -n "s/^step=//p" /var/www/html/tmp/clouve-backup/state 2>/dev/null; cat /proc/1/comm')"
    docker kill "$(app_of $c)" >/dev/null 2>&1
    app_start $c
    # A second kill, in the middle of the way back, when this start goes back.
    if sc_wait_log "$(app_of $c)" "phase restore" 60; then
      sleep $((1 + offset % 3))
      docker kill "$(app_of $c)" >/dev/null 2>&1
      app_start $c
    fi
    if wait_up $c 500; then
      pass "$c +$offset s (step $(xargs <<< "$at_kill")): the site comes up after the kills"
    else
      fail "$c +$offset s (step $(xargs <<< "$at_kill")): the site comes up after the kills"
      show_log $c 40
    fi
    # Two tries that were killed count as two failed tries, so the site may end on the old version. Either way
    # it is one whole version with everything in it, never something in between.
    ended="$(in_app $c 'cat /var/www/html/VERSION')"
    if [ "$ended" = "$OLD" ]; then
      assert_eq "$c +$offset s: it ended on $OLD because two tries were cut off" "failed" "$(state_in $c phase)"
      site_is $c "$OLD"
    else
      site_is $c "$NEW"
    fi
    assert_eq "$c +$offset s: nothing is left aside, and no unfinished backup" "" \
      "$(in_app $c 'ls -A /var/www/html/tmp/clouve-backup/aside 2>/dev/null; ls -d /var/www/html/tmp/clouve-backup/*.partial 2>/dev/null')"
    drop_case $c
  done
fi

# --- stop -------------------------------------------------------------------------
if wants stop; then
  echo
  echo "stop: the container is asked to stop in the middle of an upgrade, twice"
  c=stop
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  began=$SECONDS
  docker stop -t 60 "$(app_of $c)" >/dev/null
  took=$((SECONDS - began))
  if [ "$took" -le 12 ]; then pass "$c: a stop between SuiteCRM's two commands ends the container in $took s"; else fail "$c: a stop between SuiteCRM's two commands ends the container promptly (it took $took s)"; fi
  assert_eq "$c: with a clean status" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$(app_of $c)")"
  log="$(app_log $c)"
  assert_contains "$c: the log says that a stop was asked for" "$log" "asked to stop"
  assert_lacks "$c: and has no failure line" "$log" "[clouve-upgrade] FAILED"
  assert_eq "$c: the state is kept, and the try that was stopped is not counted" "upgrade 0" "$(state_of $c phase attempts)"
  app_start $c
  sc_wait_log "$(app_of $c)" "phase upgrade" 240 || { fail "$c: the next start goes back and upgrades again"; show_log $c; }
  sleep 6
  began=$SECONDS
  docker stop -t 60 "$(app_of $c)" >/dev/null
  took=$((SECONDS - began))
  if [ "$took" -le 12 ]; then pass "$c: a stop in the middle of a SuiteCRM command ends the container in $took s"; else fail "$c: a stop in the middle of a SuiteCRM command ends the container promptly (it took $took s)"; fi
  assert_eq "$c: with a clean status, and again not counted" "0 upgrade 0" \
    "$(docker inspect --format '{{.State.ExitCode}}' "$(app_of $c)") $(state_of $c phase attempts)"
  app_start $c
  if wait_up $c 500; then pass "$c: the third start comes up"; else fail "$c: the third start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  # Had the two stops counted as failed tries, this start would have given up and stayed on the old version.
  assert_contains "$c: it upgraded: two clean stops are not two failed tries" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  drop_case $c
fi

# --- restore-marker ---------------------------------------------------------------
if wants restore-marker; then
  echo
  echo "restore-marker: the skill's restore is under way (tmp/clouve-backup/restore-in-progress)"
  c=restore-marker
  clone $c
  on_volume $c 'mkdir -p /v/tmp && chown 33:33 /v/tmp && mkdir -m 700 /v/tmp/clouve-backup && : > /v/tmp/clouve-backup/restore-in-progress && chmod 600 /v/tmp/clouve-backup/restore-in-progress' >/dev/null
  db_start $c || fail "$c: the database starts"
  app_start $c
  if sc_wait_log "$(app_of $c)" "a restore is under way" 120; then pass "$c: a start that finds the marker says that a restore is under way"; else fail "$c: a start that finds the marker says that a restore is under way"; show_log $c; fi
  sleep 25
  log="$(app_log $c)"
  assert_eq "$c: it says so once, and neither upgrades nor installs nor starts Apache" "1 0 0 0" \
    "$(grep -c "a restore is under way" <<< "$log") $(grep -c "phase backup" <<< "$log") $(grep -c "new install" <<< "$log") $(grep -c "starting Apache" <<< "$log")"
  page="$(page_of $c)"
  assert_contains "$c: the stand-in answers the health check" "$page" "X-Clouve-Standin: suitecrm"
  assert_contains "$c: and its page says that SuiteCRM is being restored" "$page" "SuiteCRM is being restored"
  assert_ok "$c: the sshd answers, so the restore can go on" docker exec "$(app_of $c)" bash -c '</dev/tcp/127.0.0.1/22'
  note="$(in_app $c 'cat /var/www/html/tmp/clouve-backup/needs-attention' 2>&1)"
  assert_eq "$c: the note for the AI Assistant says that a restore is why the container waits (root's, mode 600, five lines)" \
    "kind=restore 5 root 600" \
    "$(grep -x 'kind=restore' <<< "$note") $(grep -c . <<< "$note") $(in_app $c 'stat -c "%U %a" /var/www/html/tmp/clouve-backup/needs-attention' 2>&1)"
  assert_contains "$c: with the log line's words as its reason" "$note" "reason=a restore is under way ("
  began=$SECONDS
  docker stop -t 60 "$(app_of $c)" >/dev/null
  took=$((SECONDS - began))
  if [ "$took" -le 12 ]; then pass "$c: a stop request ends the wait in $took s"; else fail "$c: a stop request ends the wait promptly (it took $took s)"; fi
  assert_eq "$c: with a clean status" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$(app_of $c)")"
  app_start $c
  sc_wait_log "$(app_of $c)" "a restore is under way" 120 || { fail "$c: the next start waits again"; show_log $c; }
  in_app $c 'rm -f /var/www/html/tmp/clouve-backup/restore-in-progress' >/dev/null
  if wait_up $c 500; then pass "$c: when the marker goes, the start carries on and the site comes up"; else fail "$c: when the marker goes, the start carries on and the site comes up"; show_log $c 40; fi
  assert_eq "$c: and the note is gone" "gone" \
    "$(in_app $c 'if [ -e /var/www/html/tmp/clouve-backup/needs-attention ]; then echo there; else echo gone; fi')"
  assert_contains "$c: with the normal start, here the upgrade" "$(app_log $c)" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  # A running site: while the marker is there, neither background job runs.
  in_app $c '/clouve/suitecrm/installer/release-scheduler.sh' >/dev/null
  sc_wait_for 90 bash -c "[ -n \"\$(docker exec $(app_of $c) pgrep -u www-data -f 'messenger:consume internal-async')\" ]"
  assert_eq "$c: the Messenger worker runs and the scheduler is released" "1 on" \
    "$(in_app $c 'pgrep -u www-data -fc "messenger:consume internal-async"') $(setting_of $c)"
  in_app $c ': > /var/www/html/tmp/clouve-backup/restore-in-progress' >/dev/null
  if sc_wait_for 45 bash -c "[ -z \"\$(docker exec $(app_of $c) pgrep -u www-data -f 'messenger:consume|schedulers:run')\" ]"; then
    pass "$c: with the marker there, the Messenger worker stops and no scheduler pass runs"
  else
    fail "$c: with the marker there, the Messenger worker stops and no scheduler pass runs"
  fi
  ran="$(jobs_done $c)"
  sleep 75
  assert_eq "$c: and none starts for as long as it is there" "0 $ran" \
    "$(in_app $c 'pgrep -u www-data -fc "messenger:consume|schedulers:run"') $(jobs_done $c)"
  in_app $c 'rm -f /var/www/html/tmp/clouve-backup/restore-in-progress' >/dev/null
  if sc_wait_for 90 bash -c "[ -n \"\$(docker exec $(app_of $c) pgrep -u www-data -f 'messenger:consume internal-async')\" ]"; then
    pass "$c: when the marker goes, the Messenger worker runs again"
  else
    fail "$c: when the marker goes, the Messenger worker runs again"
    show_log $c 10
  fi
  drop_case $c
fi

# --- state-lost -------------------------------------------------------------------
if wants state-lost; then
  echo
  echo "state-lost: VERSION says $NEW, the state file is gone, and the complete backup is still there"
  c=state-lost
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  in_app $c 'rm -f /var/www/html/tmp/clouve-backup/state' >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  app_start $c
  if wait_up $c 500; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it found the backup of the upgrade that was cut off" "$log" "the complete backup $OLD-to-$NEW"
  assert_eq "$c: went back from it, and upgraded from $OLD again" "1 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log") $(grep -c "^\[clouve-upgrade\] DONE suitecrm $OLD -> $NEW" <<< "$log")"
  assert_lacks "$c: it never treated the half-upgraded site as a version of its own" "$log" "unfinished ->"
  assert_eq "$c: the one backup on the volume is the one of $OLD" "$OLD-to-$NEW" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && ls -d *-to-* | xargs')"
  site_is $c "$NEW"
  drop_case $c
fi

# --- scheduler --------------------------------------------------------------------
if wants scheduler; then
  echo
  echo "scheduler: the hold on an install that never ran a scheduled job survives what staff may do to the volume"
  c=scheduler
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c
  if wait_up $c 400; then pass "$c: the site comes up, upgraded"; else fail "$c: the site comes up, upgraded"; show_log $c 40; fi
  assert_eq "$c: SuiteCRM's own settings don't switch the scheduler on" "off" "$(setting_of $c)"
  docker stop -t 30 "$(app_of $c)" >/dev/null 2>&1
  # SuiteCRM's documented permission reset.
  on_volume $c 'cd /v && find . ! -user 33 -exec chown -h 33:33 {} +' >/dev/null
  app_start $c
  if wait_up $c 180; then pass "$c: after a permission reset the finished site starts"; else fail "$c: after a permission reset the finished site starts"; show_log $c; fi
  assert_contains "$c: the log says that the state folder was moved aside" "$(app_log $c)" "tmp/clouve-backup.untrusted-"
  sleep 70
  assert_eq "$c: no scheduled job has run" "0 off" "$(jobs_done $c) $(setting_of $c)"
  # What the earlier message told people to do.
  in_app $c 'rm -rf /var/www/html/tmp/clouve-backup /var/www/html/tmp/clouve-backup.untrusted-*' >/dev/null
  app_start $c
  if wait_up $c 180; then pass "$c: with the state folder removed the site starts"; else fail "$c: with the state folder removed the site starts"; show_log $c; fi
  assert_contains "$c: the log says that the scheduler is held" "$(app_log $c)" "the scheduler is held"
  sleep 100
  assert_eq "$c: and still no scheduled job has run, and no job has a last run" "0 0" \
    "$(jobs_done $c) $(sc_sql "$(db_of $c)" suitecrm "SELECT COUNT(*) FROM schedulers WHERE last_run IS NOT NULL")"
  # The release, as the README gives it.
  assert_contains "$c: the release says what it did" "$(in_app $c '/clouve/suitecrm/installer/release-scheduler.sh')" "released"
  if sc_wait_for 180 bash -c "[ \"\$(docker exec -e MYSQL_PWD='$ROOT_PW' $(db_of $c) mariadb -uroot -N -B suitecrm -e \"SELECT COUNT(*) FROM job_queue WHERE status='done' AND resolution='success'\")\" -gt 0 ]"; then
    pass "$c: once released, the scheduler runs its jobs, without a restart"
  else
    fail "$c: once released, the scheduler runs its jobs, without a restart"
    show_log $c 10
  fi
  # The hold file is the second way to hold it, which the skill's restore uses.
  in_app $c 'mkdir -p -m 700 /var/www/html/tmp/clouve-backup && : > /var/www/html/tmp/clouve-backup/scheduler-held' >/dev/null
  app_start $c
  if wait_up $c 180; then pass "$c: a restart comes up"; else fail "$c: a restart comes up"; show_log $c; fi
  assert_eq "$c: the setting is still on" "on" "$(setting_of $c)"
  sc_wait_log "$(app_of $c)" "the scheduler is held" 90 >/dev/null
  assert_contains "$c: and the hold file holds the scheduler all the same" "$(app_log $c)" "scheduler-held"
  drop_case $c
fi

# --- runbook ----------------------------------------------------------------------
if wants runbook; then
  echo
  echo "runbook: the README's way back by hand, after an upgrade that finished"
  c=runbook
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c
  if wait_up $c 400; then pass "$c: the site comes up, upgraded"; else fail "$c: the site comes up, upgraded"; show_log $c 40; fi
  docker stop -t 30 "$(app_of $c)" >/dev/null 2>&1
  # The commands are taken from the README as they stand there, and run in a container of the image with the
  # volume mounted and SuiteCRM not running.
  awk '/^### Go back by hand/ { found = 1 } found && /^```bash/ { inside = 1; next } inside && /^```/ { exit } inside' \
    "$SC_REPO/apps/suitecrm/README.md" > "$SC_WORK/go-back.sh"
  if [ "$(grep -c . "$SC_WORK/go-back.sh")" -ge 15 ]; then pass "$c: the README has the commands"; else fail "$c: the README has the commands"; fi
  # What the image leaves when it could not merge the customer's upload folders back into place: the folders stay
  # next to their place as <name>.clouve-aside, with the customer's files in them. The image's own way back keeps
  # them (up_remove_code), so the commands in the README have to keep them too.
  docker run --rm --name "$(app_of $c)-plant" --network none -v "$(data_of $c):/v" "$SC_SHAPER" sh -c '
    for d in /v/media.clouve-aside /v/public/media.clouve-aside; do
      mkdir -p "$d" && echo "a file of the customer" > "$d/clv-customer-file.txt" && chown -R 33:33 "$d" || exit 1
    done' >/dev/null 2>&1 || fail "$c: two <name>.clouve-aside folders are on the volume before the commands run"
  docker run --rm --name "$(app_of $c)-hand" --network "$NET" --memory 2g -v "$(data_of $c):/var/www/html" \
    -e "DATABASE_HOST=$(db_of $c)" -e DATABASE_PORT=3306 -e DATABASE_NAME=suitecrm -e DATABASE_USER=suitecrm \
    -e "DATABASE_PASSWORD=$DB_PW" -v "$SC_WORK/go-back.sh:/root/go-back.sh:ro" --entrypoint bash "$APP_IMAGE" \
    -e /root/go-back.sh > "$SC_WORK/go-back.out" 2>&1
  assert_eq "$c: every command ends well, as written" "0" "$?"
  [ "$FAILED" -eq 0 ] || tail -n 15 "$SC_WORK/go-back.out" | sed 's/^/       | /'
  # The two folders go again before the site starts: this case is about the commands, and the image's own
  # handling of such folders has its own cases.
  assert_eq "$c: the commands keep the customer's files in <name>.clouve-aside folders, as the image's own way back does" \
    "kept kept" \
    "$(docker run --rm --name "$(app_of $c)-plant" --network none -v "$(data_of $c):/v" "$SC_SHAPER" sh -c '
      for d in /v/media.clouve-aside /v/public/media.clouve-aside; do
        if [ "$(cat "$d/clv-customer-file.txt" 2>/dev/null)" = "a file of the customer" ]; then printf "kept "; else printf "gone "; fi
      done
      rm -rf /v/media.clouve-aside /v/public/media.clouve-aside' 2>/dev/null | sed 's/ $//')"
  app_start $c
  if wait_up $c 400; then pass "$c: the container starts the usual way"; else fail "$c: the container starts the usual way"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it stays on $OLD" "$log" "suitecrm stays on $OLD"
  assert_eq "$c: and doesn't upgrade again, with a new backup over the one that was used" "0 $OLD-to-$NEW" \
    "$(grep -c "phase backup" <<< "$log") $(in_app $c 'cd /var/www/html/tmp/clouve-backup && ls -d *-to-* | xargs')"
  site_is $c "$OLD"
  drop_case $c
fi

# --- password-change --------------------------------------------------------------
if wants password-change; then
  echo
  echo "password-change: the database password changes between a cut-off upgrade and the next start"
  c=password-change
  DB_PW2="db-pw2-$(rand)"
  SECRETS+=("$DB_PW2")
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  docker kill "$(app_of $c)" >/dev/null
  sc_sql "$(db_of $c)" mysql "ALTER USER 'suitecrm'@'%' IDENTIFIED BY '$DB_PW2';" >/dev/null
  app_start $c -e "DATABASE_PASSWORD=$DB_PW2"
  if wait_up $c 500; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  # The way back unpacks the old code with the old password in its settings. The upgrade's commands read them.
  assert_eq "$c: the way back ran, and the try after it reached the database with the new password" "1 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $OLD -> $NEW: phase restore" <<< "$log") $(grep -c "^\[clouve-upgrade\] DONE suitecrm $OLD -> $NEW" <<< "$log")"
  assert_eq "$c: no password is in the log" "0" "$(sc_count_secrets_in_log "$(app_of $c)" "${SECRETS[@]}")"
  site_is $c "$NEW"
  drop_case $c
fi

# --- build-reset ------------------------------------------------------------------
if wants build-reset; then
  echo
  echo "build-reset: a newer build meets an upgrade that an earlier build left cut off after its second try"
  c=build-reset
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 180 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  in_app $c "sed -i 's/^attempts=.*/attempts=2/; s/^build=.*/build=0000000000000000/' /var/www/html/tmp/clouve-backup/state" >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  assert_eq "$c: the state is of the earlier build's second try" "upgrade 2 0000000000000000" "$(state_of $c phase attempts build)"
  app_start $c
  if wait_up $c 500; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: this build went back and then made a try of its own" "$log" "[clouve-upgrade] DONE suitecrm $OLD -> $NEW"
  site_is $c "$NEW"
  drop_case $c
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sSuiteCRM upgrade checks passed.%s\n' "$SC_GREEN" "$SC_RESET"
  exit 0
fi
printf '%sSuiteCRM upgrade checks failed.%s\n' "$SC_RED" "$SC_RESET"
exit 1
