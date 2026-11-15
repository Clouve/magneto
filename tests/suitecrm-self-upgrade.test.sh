#!/bin/bash

# ============================================================================
# SuiteCRM self-upgrade test: a site this image installed, upgraded by a later one
# ============================================================================
# tests/suitecrm-upgrade.test.sh starts from a site the earlier image made. That
# image gave the whole volume to www-data, lost+found included, and its folders
# had no set-group-ID bit. A site that this image installs is different on both
# counts, and every later version bump has to upgrade such a site. This test
# installs SuiteCRM with the image under test on a volume shaped like a new
# cluster disk (root's top folder, lost+found of root's with mode 700), and
# then starts the same image with a rehearsal package: SuiteCRM's own release
# zip with another VERSION in it, mounted where the image keeps its package.
# No newer SuiteCRM exists to test with, and SuiteCRM's upgrade commands treat
# such a zip as a newer release.
#
# plain          8.10.2, installed here, upgrades to the rehearsal 8.10.3. The
#                state folder is root's with mode 700, lost+found stays root's,
#                the files in media/ and public/media/, the markers and the
#                OAuth2 key are kept, the scheduler stays switched on, and the
#                log names the files that someone put at the top of the install
#                and in public/ before SuiteCRM's upgrade removes them.
# kill           The same upgrade, killed between SuiteCRM's two commands: the
#                next start goes back and upgrades.
# migration      A second bump, to a rehearsal 8.10.4 whose package has a
#                pre-upgrade migration: from 8.10 on, SuiteCRM's first command
#                changes the database. The upgrade is killed after that
#                command and then fails on a broken package: the way back loads
#                the dump, and the database is what it was (staff's pause file
#                keeps the background jobs still meanwhile). Another build then
#                upgrades to 8.10.4, which also proves the second bump.
# other-version  A backup is cut off, and an image with another version starts
#                (a roll-back): nothing had changed, so the site just starts.
#
# --image NAME=REF uses an image that is already built (suitecrm,
# suitecrm-mariadb); otherwise the test builds it and removes it at the end.
# Naming cases limits the run (migration needs plain). Everything the test makes
# is named sc-t-self-* (SUITECRM_TEST_PREFIX changes the sc-t- part), runs on a
# network with no way out and no published port, and is removed at the end
# unless --keep is given. Every password is made up. The rehearsal packages
# (about 500 MB each) are made in a temporary folder and removed. Needs Docker
# and python3. About 15 minutes.
#
# Usage: bash tests/suitecrm-self-upgrade.test.sh [--image NAME=REF]... [--keep] [CASE...]
# Exit status: 0 when every check passes, 1 when one fails, 2 when it can't run.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/suitecrm-test-lib.sh
. "$SCRIPT_DIR/lib/suitecrm-test-lib.sh"
SC_PREFIX="${SC_PREFIX}self-"
BASE=8.10.2
NEXT=8.10.3
AFTER=8.10.4
ALL_CASES=(plain kill migration other-version)

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
wants() { local c; for c in "${CASES[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

sc_need_docker
if ! command -v python3 >/dev/null 2>&1; then
  echo "This test needs python3." >&2
  exit 2
fi
trap sc_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sc_remove_resources    # leftovers of a run that was killed
sc_workdir

echo "SuiteCRM self-upgrade: a site this image installed, $BASE to a rehearsal $NEXT and $AFTER"
if ! sc_image suitecrm || ! sc_image suitecrm-mariadb; then
  fail "the images build or are on this machine"
  exit 2
fi
APP_IMAGE="${SC_IMAGE[suitecrm]}"
DB_IMAGE="${SC_IMAGE[suitecrm-mariadb]}"

rand() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
DB_PW="db-pw-$(rand)"
ROOT_PW="root-pw-$(rand)"
OPS_PW="ops-pw-$(rand)"
ADMIN_PW="Adm1n-pw-$(rand)"
ADMIN_USER="admin@example.test"
NET="${SC_PREFIX}net"
docker network create --internal "$NET" >/dev/null

# --- the rehearsal packages -------------------------------------------------------
# make_package VERSION [MIGRATION FILE]: the image's release zip with VERSION in its VERSION file and, when a file
# is named, that file as a pre-upgrade migration in it.
make_package() {
  python3 -I - "$SC_WORK/release.zip" "$SC_WORK/SuiteCRM-$1.zip" "$1" "${2:--}" <<'PY'
import sys, zipfile
src, dst, version, extra = sys.argv[1:5]
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == 'VERSION':
            data = (version + '\n').encode()
        zout.writestr(item, data)
    if extra != '-':
        info = zipfile.ZipInfo('core/backend/PreUpgradeMigrations/Version20991231000000.php')
        info.external_attr = 0o100644 << 16
        with open(extra, 'rb') as handle:
            zout.writestr(info, handle.read())
PY
}
cat > "$SC_WORK/Version20991231000000.php" <<'PHP'
<?php

namespace App\PreUpgradeMigrations;

/**
 * Test only: a pre-upgrade migration, the kind SuiteCRM 8.10 runs in its first upgrade command.
 */
class Version20991231000000 extends BasePreUpgradeMigration
{
    public function getDescription(): string
    {
        return 'test: changes the database before the package is copied';
    }

    public function shouldRun(): bool
    {
        return true;
    }

    public function execute(): void
    {
        $connection = $this->container->get('doctrine')->getConnection();
        $connection->executeStatement('ALTER TABLE accounts ADD COLUMN sct_pre_upgrade_c INT NULL');
        $connection->executeStatement("INSERT INTO config (category, name, value) VALUES ('sct', 'pre_upgrade', 'ran')");
    }
}
PHP
docker run --rm --network none --entrypoint cat "$APP_IMAGE" "/clouve/suitecrm/SuiteCRM-$BASE.zip" > "$SC_WORK/release.zip"
if make_package "$NEXT" && { ! wants migration || make_package "$AFTER" "$SC_WORK/Version20991231000000.php"; }; then
  pass "the rehearsal packages are made from the image's own release zip"
else
  fail "the rehearsal packages are made from the image's own release zip"
  exit 2
fi
rm -f "$SC_WORK/release.zip"
head -c 2048 /dev/urandom > "$SC_WORK/bad.zip"
echo 0000000000000000 > "$SC_WORK/other-build"
for v in "$NEXT" "$AFTER"; do echo "$v" > "$SC_WORK/VERSION-$v"; done
chmod 644 "$SC_WORK"/*.zip "$SC_WORK"/VERSION-* "$SC_WORK/other-build" 2>/dev/null
# with_package VERSION [ZIP]: the docker run options that give the image that version's package.
with_package() {
  echo "-v $SC_WORK/VERSION-$1:/clouve/suitecrm/app/VERSION:ro -v ${2:-$SC_WORK/SuiteCRM-$1.zip}:/clouve/suitecrm/SuiteCRM-$1.zip:ro"
}

app_of() { echo "${SC_PREFIX}$1-app"; }
db_of() { echo "${SC_PREFIX}$1-db"; }
data_of() { echo "${SC_PREFIX}$1-data"; }
dbdata_of() { echo "${SC_PREFIX}$1-dbdata"; }
db_start() {
  docker rm -f "$(db_of "$1")" >/dev/null 2>&1
  docker run -d --name "$(db_of "$1")" --network "$NET" --memory 1g --memory-swap 1g \
    -v "$(dbdata_of "$1"):/var/lib/mysql" \
    -e MYSQL_DATABASE=suitecrm -e MYSQL_USER=suitecrm -e "MYSQL_PASSWORD=$DB_PW" -e "MYSQL_ROOT_PASSWORD=$ROOT_PW" \
    "$DB_IMAGE" >/dev/null
  sc_wait_for 240 docker exec "$(db_of "$1")" healthcheck.sh --connect --innodb_initialized
}
# app_start CASE [docker run options...]
app_start() {
  local c="$1"
  shift
  sc_save_log "$(app_of "$c")"
  docker rm -f "$(app_of "$c")" >/dev/null 2>&1
  # shellcheck disable=SC2068  # the options are words
  docker run -d --name "$(app_of "$c")" --network "$NET" --memory 2g --memory-swap 2g \
    -v "$(data_of "$c"):/var/www/html" \
    -e "DATABASE_HOST=$(db_of "$c")" -e DATABASE_PORT=3306 -e DATABASE_NAME=suitecrm -e DATABASE_USER=suitecrm \
    -e "DATABASE_PASSWORD=$DB_PW" -e SUITECRM_URL=https://crm.example.test -e "SUITECRM_ADMIN_USER=$ADMIN_USER" \
    -e "SUITECRM_ADMIN_PASSWORD=$ADMIN_PW" -e SUITECRM_INSTALL_DEMO_DATA=no -e "CLOUVE_OPS_PASSWORD=$OPS_PW" \
    $@ "$APP_IMAGE" >/dev/null
}
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
in_app() { docker exec "$(app_of "$1")" bash -c "$2" 2>&1; }
sql() { sc_sql "$(db_of "$1")" suitecrm "$2"; }
app_log() { docker logs "$(app_of "$1")" 2>&1; }
show_log() { docker logs --tail "${2:-30}" "$(app_of "$1")" 2>&1 | sed 's/^/       | /'; }
db_version_row() { sql "$1" "SELECT value FROM config WHERE category='info' AND name='suitecrm_version'"; }
db_hash() {
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec "$(db_of "$1")" sh -c 'MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}" mariadb-dump -uroot --skip-dump-date --skip-comments --skip-extended-insert --single-transaction suitecrm | LC_ALL=C sort | sha256sum | cut -d" " -f1' 2>/dev/null
}
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
clone() {
  sc_copy_volume "${SC_PREFIX}base-data" "$(data_of "$1")" && sc_copy_volume "${SC_PREFIX}base-dbdata" "$(dbdata_of "$1")"
}
drop_case() {
  [ "${SC_KEEP:-false}" = true ] && return 0
  sc_save_log "$(app_of "$1")"
  docker rm -f -v "$(app_of "$1")" "$(db_of "$1")" >/dev/null 2>&1
  docker volume rm -f "$(data_of "$1")" "$(dbdata_of "$1")" >/dev/null 2>&1
}
# site_is CASE VERSION: the site runs VERSION and holds what the installed site was given.
site_is() {
  local c="$1" want="$2"
  assert_eq "$c: VERSION, the database's record and SuiteCRM's own version command say $want" "$want $want $want" \
    "$(in_app "$c" 'cat /var/www/html/VERSION') $(db_version_row "$c") $(in_app "$c" 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php bin/console suitecrm:version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | tail -n 1')"
  assert_eq "$c: the files in media/ and public/media/ are there" "private file public file" \
    "$(in_app "$c" 'cd /var/www/html; cat media/documents/sct-private.txt public/media/images/sct-public.txt 2>&1 | xargs')"
  assert_eq "$c: the record is there" "Self Upgrade Ltd" "$(sql "$c" "SELECT name FROM accounts WHERE id='sct-self-1'")"
  assert_eq "$c: the image's markers are there, the OAuth2 key is closed, and lost+found is root's" \
    "www-data www-data www-data 600 root 700" \
    "$(in_app "$c" 'cd /var/www/html && stat -c %U .suitecrm_initialized .suitecrm_url | xargs; stat -c "%U %a" public/legacy/Api/V8/OAuth2/private.key lost+found | xargs' | xargs)"
  assert_eq "$c: every file is www-data's, the state folder and lost+found aside" "0" \
    "$(in_app "$c" 'cd /var/www/html && find . \( -path ./lost+found -o -path ./tmp/clouve-backup \) -prune -o ! -user www-data -print | wc -l')"
  assert_eq "$c: the state folder is root's, mode 700, and nothing in it is open to others" "root 700 0" \
    "$(in_app "$c" 'stat -c "%U %a" /var/www/html/tmp/clouve-backup | xargs; find /var/www/html/tmp/clouve-backup \( ! -user root -o -perm /go=rwx \) -print | wc -l' | xargs)"
  assert_eq "$c: nothing is left aside" "" "$(in_app "$c" 'ls -A /var/www/html/tmp/clouve-backup/aside 2>/dev/null')"
  assert_eq "$c: the scheduler is still switched on in SuiteCRM's settings" "on" \
    "$(in_app "$c" 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php scheduler 2>/dev/null')"
  assert_contains "$c: the admin signs in" "$(admin_signs_in "$c")" '"login_success"'
}

# --- the installed site ------------------------------------------------------------
echo
echo "The $BASE site, installed by this image on new disks"
sc_new_disk "${SC_PREFIX}base-data"
sc_new_disk "${SC_PREFIX}base-dbdata"
db_start base || { fail "the database starts"; exit 1; }
app_start base
if wait_up base 400; then pass "SuiteCRM $BASE installs"; else fail "SuiteCRM $BASE installs"; show_log base 30; exit 1; fi
# What a customer's site has: files in the two media folders, a record, and two files someone put there by
# hand: one at the top of the install and a site-verification file in the web root.
in_app base 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- bash -c "
  mkdir -p media/documents public/media/images && echo \"private file\" > media/documents/sct-private.txt &&
  echo \"public file\" > public/media/images/sct-public.txt && echo stray > sct-stray.txt &&
  echo verify > public/sct-verify.html"' >/dev/null
sql base "INSERT INTO accounts (id, name, deleted) VALUES ('sct-self-1', 'Self Upgrade Ltd', 0)" >/dev/null
assert_eq "tmp/ has the set-group-ID bit, as on every volume this image installs, and lost+found is root's" \
  "www-data 2755 root 700" "$(in_app base 'cd /var/www/html && stat -c "%U %a" tmp lost+found | xargs')"
assert_eq "its scheduler is switched on" "on" \
  "$(in_app base 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php scheduler 2>/dev/null')"
docker stop -t 30 "$(app_of base)" >/dev/null 2>&1
docker stop -t 60 "$(db_of base)" >/dev/null 2>&1
docker rm -f "$(app_of base)" "$(db_of base)" >/dev/null 2>&1

# --- plain ------------------------------------------------------------------------
if wants plain || wants migration; then
  echo
  echo "plain: $BASE to the rehearsal $NEXT"
  c=plain
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c "$(with_package "$NEXT")"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: the log has the upgrade's finishing line" "$log" "[clouve-upgrade] DONE suitecrm $BASE -> $NEXT"
  assert_lacks "$c: and no failure line" "$log" "[clouve-upgrade] FAILED"
  site_is $c "$NEXT"
  gone="$(grep -F 'will be gone from the site' <<< "$log" | tail -n 1)"
  assert_contains "$c: before SuiteCRM's upgrade removed it, the log named the file at the top of the install" "$gone" " sct-stray.txt"
  assert_contains "$c: and the one in the web root" "$gone" " public/sct-verify.html"
  assert_eq "$c: both are in the backup's code archive" "2" \
    "$(in_app $c "tar -tzf /var/www/html/tmp/clouve-backup/$BASE-to-$NEXT/code.tar.gz | grep -cxE '\./(sct-stray\.txt|public/sct-verify\.html)'")"
  assert_eq "$c: no state is left, and no note of a skipped upgrade" "" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && cat state upgrade-skipped 2>/dev/null')"
fi

# --- kill -------------------------------------------------------------------------
if wants kill; then
  echo
  echo "kill: the same upgrade, killed between SuiteCRM's two commands"
  c=kill
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c "$(with_package "$NEXT")" -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 240 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  docker kill "$(app_of $c)" >/dev/null
  app_start $c "$(with_package "$NEXT")"
  if wait_up $c 400; then pass "$c: the next start comes up"; else fail "$c: the next start comes up"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_eq "$c: it went back once, then upgraded" "1 1" \
    "$(grep -c "^\[clouve-upgrade\] suitecrm $BASE -> $NEXT: phase restore" <<< "$log") $(grep -c "^\[clouve-upgrade\] DONE suitecrm $BASE -> $NEXT" <<< "$log")"
  site_is $c "$NEXT"
  drop_case $c
fi

# --- migration --------------------------------------------------------------------
if wants migration; then
  echo
  echo "migration: a second bump, to a rehearsal $AFTER whose first command changes the database"
  c=plain
  docker stop -t 30 "$(app_of $c)" >/dev/null 2>&1
  before="$(db_hash $c)"
  app_start $c "$(with_package "$AFTER")" -e CLOUVE_TEST_PAUSE=upgrade:300
  sc_wait_log "$(app_of $c)" "test pause at upgrade" 300 || { fail "$c: the upgrade reaches the test's pause"; show_log $c; }
  assert_eq "$c: SuiteCRM's first command has run the package's pre-upgrade migration: a new column and a new row" \
    "sct_pre_upgrade_c ran" "$(sql $c "SHOW COLUMNS FROM accounts LIKE 'sct_pre%'" | cut -f1) $(sql $c "SELECT value FROM config WHERE category='sct'")"
  # Staff's pause file: on this site the scheduler is switched on, and its jobs would write to the database as
  # soon as SuiteCRM runs again. With the file there, the database stays as the way back leaves it.
  in_app $c ': > /var/www/html/tmp/clouve-backup/loops-paused' >/dev/null
  docker kill "$(app_of $c)" >/dev/null
  # The next start has a broken package: the upgrade fails twice, and the old version has to be whole again.
  app_start $c "$(with_package "$AFTER" "$SC_WORK/bad.zip")"
  if wait_up $c 400; then pass "$c: the site comes up"; else fail "$c: the site comes up"; show_log $c 40; fi
  sc_wait_log "$(app_of $c)" "the scheduler stands still" 60 >/dev/null
  log="$(app_log $c)"
  assert_eq "$c: with staff's pause file there, neither background job runs" "0 1 1" \
    "$(in_app $c 'pgrep -u www-data -fc "messenger:consume|schedulers:run"') $(grep -c "the scheduler stands still" <<< "$log") $(grep -c "the Messenger worker stands still" <<< "$log")"
  assert_contains "$c: the way back saw that the database had changed and loaded the dump" "$log" "so the dump is loaded"
  assert_eq "$c: the column, the row and the record of the migration are gone" "  " \
    "$(sql $c "SHOW COLUMNS FROM accounts LIKE 'sct_pre%'" | cut -f1) $(sql $c "SELECT value FROM config WHERE category='sct'") $(sql $c "SELECT version FROM pre_upgrade_migration_versions WHERE version LIKE '%20991231000000%'")"
  assert_eq "$c: the database is, table for table and row for row, what it was before" "$before" "$(db_hash $c)"
  assert_contains "$c: the log has the failure line, and $NEXT runs" "$log" "[clouve-upgrade] FAILED suitecrm $NEXT -> $AFTER: "
  in_app $c 'rm -f /var/www/html/tmp/clouve-backup/loops-paused' >/dev/null
  if sc_wait_for 60 bash -c "[ -n \"\$(docker exec $(app_of $c) pgrep -u www-data -f 'messenger:consume internal-async')\" ]"; then
    pass "$c: without the pause file the Messenger worker runs again"
  else
    fail "$c: without the pause file the Messenger worker runs again"
  fi
  site_is $c "$NEXT"
  # Another build with a good package tries again by itself.
  app_start $c "$(with_package "$AFTER")" -v "$SC_WORK/other-build:/clouve/suitecrm/BUILD:ro"
  if wait_up $c 400; then pass "$c: another build with a good package comes up"; else fail "$c: another build with a good package comes up"; show_log $c 40; fi
  assert_contains "$c: it upgraded a second time" "$(app_log $c)" "[clouve-upgrade] DONE suitecrm $NEXT -> $AFTER"
  site_is $c "$AFTER"
  assert_eq "$c: one backup is kept, the newest" "$NEXT-to-$AFTER" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && ls -d *-to-* | xargs')"
fi
wants plain || wants migration && drop_case plain

# --- other-version ----------------------------------------------------------------
if wants other-version; then
  echo
  echo "other-version: a backup is cut off, then an image with another version starts"
  c=other-version
  clone $c
  db_start $c || fail "$c: the database starts"
  app_start $c "$(with_package "$NEXT")" -e CLOUVE_TEST_PAUSE=backup:300
  sc_wait_log "$(app_of $c)" "test pause at backup" 240 || { fail "$c: the backup reaches the test's pause"; show_log $c; }
  assert_eq "$c: the state says phase backup, to $NEXT" "backup $NEXT" \
    "$(in_app $c "sed -n 's/^phase=//p;s/^to=//p' /var/www/html/tmp/clouve-backup/state | xargs")"
  docker kill "$(app_of $c)" >/dev/null
  # The roll-back: the image as it is, with $BASE.
  app_start $c
  if wait_up $c 240; then pass "$c: the image with $BASE starts on the volume"; else fail "$c: the image with $BASE starts on the volume"; show_log $c 40; fi
  log="$(app_log $c)"
  assert_contains "$c: it says that the backup was cut off and that nothing had changed" "$log" "backup was cut off"
  assert_lacks "$c: and stops on nothing" "$log" "[clouve-upgrade] FAILED"
  assert_eq "$c: no state and no unfinished backup are left" "" \
    "$(in_app $c 'cd /var/www/html/tmp/clouve-backup && cat state 2>/dev/null; ls -d *.partial 2>/dev/null')"
  site_is $c "$BASE"
  drop_case $c
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sSuiteCRM self-upgrade checks passed.%s\n' "$SC_GREEN" "$SC_RESET"
  exit 0
fi
printf '%sSuiteCRM self-upgrade checks failed.%s\n' "$SC_RED" "$SC_RESET"
exit 1
