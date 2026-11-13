#!/bin/bash

# ============================================================================
# LimeSurvey entrypoint test: a new install, and what every start does
# ============================================================================
# Runs the LimeSurvey image and its database image for real, on a network of
# the test's own with no published ports, on volumes made the way a cluster
# makes them (root's top folder, mode 755, lost+found, nothing copied in; the
# nested upload volume too).
#
# 1. Before the database answers (the database host can't be resolved):
#    PID 1's environment, which the AI Assistant reads once its sshd answers,
#    holds LIMESURVEY_DB_USER and DB_MYSQL_ENGINE=InnoDB; clouve-ops signs in
#    over SSH; both volumes' top folders are www-data's; the stand-in for the
#    health check answers GET / with 200 and everything else with 503 and
#    Retry-After, and has no CLOUVE_OPS_PASSWORD; no command line holds a
#    password while the entrypoint asks the database; the image's state
#    folder, clouve/, is root's with mode 700; docker stop and SIGTERM end
#    the wait at once, with status 0; and a database that never answers ends
#    the container with status 1.
# 2. A start without DB_PASSWORD or ADMIN_PASSWORD stops with status 1,
#    prints no value and leaves the volumes as they were.
# 3. A new install: no password is on any command line while it runs (the
#    process list is sampled about ten times a second) or in the log; the
#    site is LimeSurvey 7.10.0 with InnoDB tables; the admin signs in with
#    ADMIN_PASSWORD; config.php and security.php are www-data's, mode 600;
#    the upload skeleton is on the nested volume; Apache is PID 1 without
#    CLOUVE_OPS_PASSWORD (PHP under Apache finds none) and clouve-ops still
#    signs in; installer/, node_modules/ and clouve/ are denied over HTTP,
#    so the command-line install worked with installer/ closed to the web;
#    allowed_hosts.php names localhost and PUBLIC_URL's host; the stand-in
#    is gone and Apache has the port.
# 4. A restart installs nothing again.
# 5. A new container with another PUBLIC_URL and a rotated database password:
#    config.php follows both, allowed_hosts.php gains the new host and keeps
#    a host added by hand, and the admin page answers on the new host.
# 6. An install that is killed after it made its tables is cleared and done
#    again at the next start.
# 7. A demo survey import that is killed leaves one demo survey, not two.
# 8. The AI Assistant's skill has a restore under way when the container
#    starts (clouve/backups/RESTORE-IN-PROGRESS): nothing is installed,
#    upgraded or refused; the page says "being restored", the note for the
#    AI Assistant (clouve/needs-attention) says kind=restore, and clouve-ops signs
#    in; the wait outlasts DB_WAIT_SECONDS; docker stop ends it at once; and
#    when the marker goes, the same container starts the site.
# 9. An installed site whose database was lost: the install into the empty
#    database is killed halfway, and the next start clears it and installs
#    again, with the security.php from before.
# 10. tool.php changes the real settings of a config.php that also has the
#    same settings commented out, and a PUBLIC_URL without http:// gets a
#    warning.
# 11. A volume with no code and a database with tables: the start waits for
#    repair (no Apache, the "needs attention" page, the sshd, a FAILED line,
#    and the note clouve/needs-attention with the line's words, kind=repair),
#    and nothing is changed.
#
# Every container, volume and network is named ls-ep-t-* (LS_TEST_PREFIX
# changes that) and is removed at the end, with the images the test built.
#
# Usage: bash tests/limesurvey-entrypoint.test.sh [--image limesurvey=REF] [--image limesurvey-mariadb=REF] [--keep]
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${LS_TEST_PREFIX:-ls-ep-t-}"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"

VERSION=7.10.0
DB_VERSION=718

ls_parse_args "$@"
[ "${#LS_ARGS[@]}" -eq 0 ] || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2; exit 2; }
ls_need_docker
WORK="$(mktemp -d)"
trap ls_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ls_remove_all

echo "LimeSurvey entrypoint"
if ! ls_image limesurvey-mariadb || ! ls_image limesurvey; then
  fail "the images build or are on this machine"
  echo; printf '%sLimeSurvey entrypoint checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
IMAGE="${LS_IMAGE[limesurvey]}"
docker network create "${PREFIX}net" >/dev/null

# top_folder VOLUME: "<owner>:<group> <mode>" of a volume's top folder, and whether lost+found is still root's.
top_folder() {
  docker run --rm --network none -v "$1:/v:ro" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" \
    sh -c 'echo "$(stat -c "%u:%g %a" /v) lost+found=$(stat -c "%u:%g %a" /v/lost+found 2>/dev/null)"'
}
# environ_of CONTAINER PID: the environment of a process, one NAME=value per line, read as root.
environ_of() { docker exec -u root "$1" sh -c "tr '\\0' '\\n' < /proc/$2/environ" 2>/dev/null; }

# --- 1. before the database answers ---------------------------------------------------------------------------------
echo
echo "Before the database answers"
A="${PREFIX}wait"
ls_new_disk "${PREFIX}wait-html" "${PREFIX}wait-upload"
ls_start_app "$A" "${PREFIX}db.invalid" "${PREFIX}wait-html" "${PREFIX}wait-upload" "$IMAGE" \
  -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW" -e DB_USERNAME=lime_user_7
if ls_wait_log "$A" "waiting for the database at ${PREFIX}db.invalid" 60; then
  pass "the entrypoint waits for the database"
else
  fail "the entrypoint waits for the database"
  docker logs --tail 15 "$A" 2>&1 | sed 's/^/       | /'
fi
env1="$(environ_of "$A" 1)"
assert_eq "PID 1 has LIMESURVEY_DB_USER, from DB_USERNAME, once" "LIMESURVEY_DB_USER=lime_user_7" \
  "$(grep '^LIMESURVEY_DB_USER=' <<< "$env1")"
assert_eq "PID 1 has DB_MYSQL_ENGINE=InnoDB" "DB_MYSQL_ENGINE=InnoDB" "$(grep '^DB_MYSQL_ENGINE=' <<< "$env1")"
assert_eq "PID 1 has the database host and name the persona shows" "2" \
  "$(grep -cE "^(DB_HOST=${PREFIX}db.invalid|DB_NAME=limesurvey)\$" <<< "$env1")"
assert_eq "PID 1's environment holds no variable of the image's own making besides those" "0" "$(grep -c '^CLV_' <<< "$env1")"
whoami=""
for _ in $(seq 1 30); do whoami="$(ls_ssh_whoami "$A" "$LS_OPS_PW")"; [ -n "$whoami" ] && break; sleep 1; done
assert_eq "clouve-ops signs in over SSH while the entrypoint waits" "clouve-ops" "$whoami"
assert_eq "a wrong password is refused" "" "$(ls_ssh_whoami "$A" "not-$LS_OPS_PW")"
assert_eq "the code volume's top folder is www-data's, lost+found untouched" "33:33 755 lost+found=0:0 700" \
  "$(top_folder "${PREFIX}wait-html")"
assert_eq "the upload volume's top folder is www-data's, lost+found untouched" "33:33 755 lost+found=0:0 700" \
  "$(top_folder "${PREFIX}wait-upload")"
assert_eq "the stand-in answers GET / with 200" "200" "$(ls_http "$A" /)"
assert_contains "with a short page that says what is going on" \
  "$(docker exec "$A" curl -s -m 10 http://127.0.0.1:8080/)" "LimeSurvey"
assert_eq "HEAD / is 200 too (the Docker health check uses wget --spider)" "200" "$(ls_http "$A" / -I)"
assert_eq "its answers carry the X-Clouve-Standin header, which ./test.sh waits past" "1" \
  "$(docker exec "$A" curl -s -m 10 -D - -o /dev/null http://127.0.0.1:8080/ | grep -ci '^X-Clouve-Standin: limesurvey')"
assert_eq "GET /index.php/admin is 503" "503" "$(ls_http "$A" /index.php/admin)"
assert_eq "GET /?r=admin/remotecontrol is 503" "503" "$(ls_http "$A" '/?r=admin/remotecontrol')"
assert_eq "POST / is 503" "503" "$(ls_http "$A" / -X POST -d '{}')"
assert_eq "a 503 carries Retry-After" "1" \
  "$(docker exec "$A" curl -s -m 10 -D - -o /dev/null http://127.0.0.1:8080/index.php/admin/remotecontrol | grep -ci '^Retry-After: [0-9]')"
standin_pid="$(docker exec "$A" pgrep -f 'php -S' | head -n 1)"
standin_user="$(docker exec "$A" ps -o user= -p "${standin_pid:-0}" 2>/dev/null | tr -d ' ')"
assert_eq "the stand-in runs as www-data" "www-data" "$standin_user"
assert_eq "the stand-in has no CLOUVE_OPS_PASSWORD" "0" "$(environ_of "$A" "${standin_pid:-0}" | grep -c '^CLOUVE_OPS_PASSWORD=')"
assert_eq "the log holds no password" "0" "$(ls_secrets_in "$(docker logs "$A" 2>&1)")"
assert_eq "the image's state folder, clouve/, is root's with mode 700" "root:root 700" \
  "$(docker exec "$A" stat -c '%U:%G %a' /var/www/html/clouve 2>/dev/null)"
assert_eq "www-data can't list it" "denied" \
  "$(docker exec -u www-data "$A" sh -c 'ls /var/www/html/clouve >/dev/null 2>&1 && echo listed || echo denied')"
# A stop request while the entrypoint waits: docker stop sends the image's stop signal (SIGWINCH), then kills.
t0=$(date +%s)
docker stop -t 30 "$A" >/dev/null 2>&1
took=$(( $(date +%s) - t0 ))
if [ "$took" -le 8 ]; then pass "docker stop ends the wait in $took s (it may wait 30)"; else fail "docker stop ends the wait in $took s (it may wait 30)"; fi
assert_eq "the container ends with status 0, not with a kill's 137" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$A")"
assert_contains "the log says it was asked to stop" "$(docker logs "$A" 2>&1)" "the container was asked to stop before LimeSurvey was started"
docker rm -f -v "$A" >/dev/null 2>&1
ls_start_app "$A" "${PREFIX}db.invalid" "${PREFIX}wait-html" "${PREFIX}wait-upload" "$IMAGE"
ls_wait_log "$A" "waiting for the database at ${PREFIX}db.invalid" 60 || fail "the entrypoint waits for the database again"
sleep 2
docker kill -s TERM "$A" >/dev/null 2>&1
code="$(ls_wait_exit "$A" 8)"
assert_eq "SIGTERM ends the wait too, with status 0, within 8 s" "0" "${code:-still running}"
docker rm -f -v "$A" >/dev/null 2>&1

A="${PREFIX}nodb"
ls_start_app "$A" "${PREFIX}db.invalid" "${PREFIX}wait-html" "${PREFIX}wait-upload" "$IMAGE" -e DB_WAIT_SECONDS=6
code="$(ls_wait_exit "$A" 90)"
log="$(docker logs "$A" 2>&1)"
assert_eq "a database that never answers ends the container with status 1" "1" "$code"
assert_contains "and the log says so" "$log" "did not answer within 6 s"
assert_lacks "Apache never started" "$log" "starting Apache"
docker rm -f -v "$A" >/dev/null 2>&1
# A database host that takes the connection and never greets: the client waits, so the process list shows it.
docker run -d --name "${PREFIX}mute" --network "${PREFIX}net" --memory 64m "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" \
  sh -c 'while :; do tail -f /dev/null | nc -l -p 3306 > /dev/null; done' >/dev/null
A="${PREFIX}slowdb"
ls_start_app "$A" "${PREFIX}mute" "${PREFIX}wait-html" "${PREFIX}wait-upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW"
ls_wait_log "$A" "waiting for the database at ${PREFIX}mute" 60 || fail "the entrypoint waits for the mute database"
ls_watch_ps "$A" "$WORK/ps-wait" &
sleep 12
touch "$WORK/ps-wait.stop"; wait
if grep -q "mariadb -h ${PREFIX}mute" "$WORK/ps-wait"; then pass "the process list was sampled while the entrypoint asked the database"; else
  fail "the process list was sampled while the entrypoint asked the database"; fi
assert_eq "no command line held a password during the wait" "0" "$(ls_secrets_in "$(cat "$WORK/ps-wait")")"
assert_contains "a database that doesn't greet is given 10 s per try" "$(docker logs "$A" 2>&1)" "no answer within 10 s"
docker rm -f -v "$A" "${PREFIX}mute" >/dev/null 2>&1
docker volume rm -f "${PREFIX}wait-html" "${PREFIX}wait-upload" >/dev/null 2>&1

# --- 2. missing passwords -------------------------------------------------------------------------------------------
echo
echo "A start without a password"
ls_new_disk "${PREFIX}miss-html" "${PREFIX}miss-upload"
for var in DB_PASSWORD ADMIN_PASSWORD; do
  A="${PREFIX}miss"
  ls_start_app "$A" "${PREFIX}db.invalid" "${PREFIX}miss-html" "${PREFIX}miss-upload" "$IMAGE" -e "$var="
  code="$(ls_wait_exit "$A" 60)"
  log="$(docker logs "$A" 2>&1)"
  assert_eq "without $var the container stops with status 1" "1" "$code"
  assert_contains "the log names $var" "$log" "$var is not set"
  assert_eq "and holds no password" "0" "$(ls_secrets_in "$log")"
  docker rm -f -v "$A" >/dev/null 2>&1
done
assert_eq "the code volume is as it was (root's top folder)" "0:0 755 lost+found=0:0 700" "$(top_folder "${PREFIX}miss-html")"
docker volume rm -f "${PREFIX}miss-html" "${PREFIX}miss-upload" >/dev/null 2>&1

# --- 3. a new install -----------------------------------------------------------------------------------------------
echo
echo "A new install on new disks"
DB="${PREFIX}db"
A="${PREFIX}app"
ls_new_disk "${PREFIX}db-data" "${PREFIX}html" "${PREFIX}upload"
ls_start_db "$DB" "${PREFIX}db-data"
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW"
ls_watch_ps "$A" "$WORK/ps-install" &
started=$SECONDS
rc=0; ls_wait_apache "$A" 300 || rc=$?
touch "$WORK/ps-install.stop"; wait
if [ "$rc" -eq 0 ]; then
  pass "the site installs and Apache answers ($((SECONDS - started)) s)"
else
  fail "the site installs and Apache answers"
  docker logs --tail 25 "$A" 2>&1 | sed 's/^/       | /'
  echo; printf '%sLimeSurvey entrypoint checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
samples="$(grep -c 'console' "$WORK/ps-install")"
if [ "$samples" -ge 1 ]; then pass "the process list was sampled while console.php ran ($samples lines)"; else
  fail "the process list was sampled while console.php ran"; fi
assert_eq "no command line held a password during the install" "0" "$(ls_secrets_in "$(cat "$WORK/ps-install")")"
echo "       command lines seen during the install (php and the database client):"
grep -E '^(php|mariadb|bash /clouve)' "$WORK/ps-install" | sort -u | head -n 8 | cut -c1-150 | sed 's/^/         /'
log="$(docker logs "$A" 2>&1)"
assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
assert_eq "the code on the volume is LimeSurvey $VERSION" "$VERSION $DB_VERSION" "$(ls_code_version "$A")"
assert_eq "the database is at version $DB_VERSION" "$DB_VERSION" "$(ls_db_version "$DB")"
assert_eq "every table is InnoDB" "InnoDB" \
  "$(ls_sql "$DB" "SELECT DISTINCT engine FROM information_schema.tables WHERE table_schema='limesurvey'")"
assert_eq "config.php says InnoDB for new tables" "InnoDB" \
  "$(docker exec -u www-data "$A" php -r 'define("BASEPATH", "."); $c = include "/var/www/html/application/config/config.php"; echo $c["config"]["mysqlEngine"];')"
hash="$(ls_sql "$DB" "SELECT password FROM lime_users WHERE users_name='$LS_ADMIN_USER'")"
# shellcheck disable=SC2016  # PHP code
assert_eq "the admin signs in with ADMIN_PASSWORD" "yes" \
  "$(docker exec -e "T_P=$LS_ADMIN_PW" -e "T_H=$hash" "$A" php -r 'echo password_verify(getenv("T_P"), getenv("T_H")) ? "yes" : "no";')"
assert_eq "config.php and security.php are www-data's, mode 600" "www-data:www-data 600 www-data:www-data 600" \
  "$(docker exec "$A" sh -c 'cd /var/www/html/application/config && echo "$(stat -c "%U:%G %a" config.php) $(stat -c "%U:%G %a" security.php)"')"
assert_eq "both volumes' top folders are www-data's" "33:33 755 33:33 755" \
  "$(docker exec "$A" sh -c 'echo "$(stat -c "%u:%g %a" /var/www/html) $(stat -c "%u:%g %a" /var/www/html/upload)"')"
assert_eq "the upload skeleton is on the nested volume" "" \
  "$(docker exec "$A" sh -c 'cd /clouve/limesurvey/package/upload && for e in *; do [ -e "/var/www/html/upload/$e" ] || echo "missing $e"; done')"
assert_eq "no install stamp is left" "0" "$(docker exec "$A" sh -c 'ls /var/www/html/clouve/install-in-progress 2>/dev/null | wc -l')"
assert_eq "nor the install's marker table" "0" \
  "$(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey' AND table_name LIKE 'clouve%'")"
assert_eq "Apache is PID 1" "apache2" "$(ls_pid1 "$A")"
echo "       ps for PID 1: $(docker exec "$A" ps -o pid=,user=,args= -p 1 | tr -s ' ')"
assert_eq "PID 1 (Apache) has no CLOUVE_OPS_PASSWORD" "0" "$(environ_of "$A" 1 | grep -c '^CLOUVE_OPS_PASSWORD=')"
# shellcheck disable=SC2016  # PHP code
docker exec -i -u www-data "$A" sh -c 'cat > /var/www/html/clv-ops-probe.php' <<'PHP'
<?php
$n = 'CLOUVE_OPS_PASSWORD';
echo 'user=', posix_getpwuid(posix_geteuid())['name'], ' getenv=', getenv($n) === false ? 'absent' : 'present',
     ' server=', isset($_SERVER[$n]) ? 'present' : 'absent', ' env=', isset($_ENV[$n]) ? 'present' : 'absent', "\n";
PHP
assert_eq "PHP under Apache finds no CLOUVE_OPS_PASSWORD" "user=www-data getenv=absent server=absent env=absent" \
  "$(docker exec "$A" curl -s -m 10 http://127.0.0.1:8080/clv-ops-probe.php)"
docker exec "$A" rm -f /var/www/html/clv-ops-probe.php
assert_eq "clouve-ops still signs in over SSH" "clouve-ops" "$(ls_ssh_whoami "$A" "$LS_OPS_PW")"
assert_eq "the stand-in is gone" "0" "$(docker exec "$A" pgrep -fc 'php -S')"
assert_eq "and Apache's answers carry no X-Clouve-Standin header" "0" \
  "$(docker exec "$A" curl -s -m 10 -D - -o /dev/null http://127.0.0.1:8080/ | grep -ci '^X-Clouve-Standin')"
installer_file="$(docker exec "$A" sh -c 'cd /var/www/html && find installer -type f | head -n 1')"
assert_eq "installer/ is denied over HTTP ($installer_file)" "403" "$(ls_http "$A" "/$installer_file")"
node_file="$(docker exec "$A" sh -c 'cd /var/www/html && find node_modules -type f | head -n 1')"
assert_eq "node_modules/ is denied over HTTP" "403" "$(ls_http "$A" "/$node_file")"
assert_eq "clouve/ is denied over HTTP" "403" "$(ls_http "$A" /clouve/)"
assert_eq "clouve/ and what the install wrote there are root's, and nothing in it is readable by others" "root:root 700 0" \
  "$(docker exec "$A" sh -c 'echo "$(stat -c "%U:%G %a" /var/www/html/clouve) $(find /var/www/html/clouve \( ! -user root -o -perm /077 \) | wc -l)"')"
# shellcheck disable=SC2016  # PHP code
hosts_php='define("BASEPATH", "."); $c = include "/var/www/html/application/config/allowed_hosts.php";
  sort($c["allowedHosts"]); echo implode(",", $c["allowedHosts"]);'
assert_eq "allowed_hosts.php names localhost" "localhost" "$(docker exec -u www-data "$A" php -r "$hosts_php")"
assert_eq "the admin sign-in page answers on localhost" "200" \
  "$(ls_http "$A" /index.php/admin/authentication/sa/login -H 'Host: localhost:8080')"

# --- 4. a restart ---------------------------------------------------------------------------------------------------
echo
echo "A restart"
docker restart "$A" >/dev/null
rc=0; ls_wait_log "$A" "nothing to install or upgrade" 120 || rc=$?
assert_eq "the second start finds nothing to install or upgrade" "0" "$rc"
rc=0; ls_wait_apache "$A" 120 || rc=$?
assert_eq "and Apache answers again" "0" "$rc"
assert_eq "the install ran once" "1" "$(docker logs "$A" 2>&1 | grep -c 'new install: copying LimeSurvey')"
assert_eq "there is one admin account" "1" "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_users")"

# --- 5. another address and a rotated database password -------------------------------------------------------------
echo
echo "Another PUBLIC_URL and a rotated database password"
docker rm -f -v "$A" >/dev/null 2>&1
NEW_DB_PW="db-pw-rotated-'q\"\$x\\-91c2"
LS_EXTRA_SECRETS=("$NEW_DB_PW")
docker exec -i -e "MYSQL_PWD=$LS_DB_ROOT_PW" -e "T_PW=$NEW_DB_PW" "$DB" sh -c \
  'printf "ALTER USER limesurvey@\"%%\" IDENTIFIED BY \"%s\";\n" "$(printf "%s" "$T_PW" | sed "s/[\\\\\"]/\\\\&/g")" | mariadb -u root' \
  || fail "the database password could be rotated"
# A host that an admin added by hand stays.
# shellcheck disable=SC2016  # PHP code
docker run --rm --network none -u www-data -v "${PREFIX}html:/var/www/html" --entrypoint php "$IMAGE" -r '
  $f = "/var/www/html/application/config/allowed_hosts.php";
  file_put_contents($f, "<?php if (!defined(\"BASEPATH\")) exit(\"No direct script access allowed\");\nreturn array(\"allowedHosts\" => array(\"localhost\", \"alias.example.test\"));\n");'
old_pw="$LS_DB_PW"
LS_DB_PW="$NEW_DB_PW"
LS_PUBLIC_URL="https://surveys.example.test"
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW"
rc=0; ls_wait_apache "$A" 120 || rc=$?
assert_eq "Apache answers with the new settings" "0" "$rc"
# shellcheck disable=SC2016  # PHP code
got="$(docker exec -u www-data -e "T_PW=$NEW_DB_PW" "$A" php -r 'define("BASEPATH", ".");
  $c = include "/var/www/html/application/config/config.php";
  echo $c["config"]["publicurl"], " ", $c["components"]["db"]["password"] === getenv("T_PW") ? "new-password" : "old-password";')"
assert_eq "config.php has the new publicurl and the new database password" "https://surveys.example.test new-password" "$got"
assert_eq "config.php is still www-data's, mode 600" "www-data:www-data 600" \
  "$(docker exec "$A" stat -c '%U:%G %a' /var/www/html/application/config/config.php)"
assert_eq "allowed_hosts.php gains the new host and keeps the others" "alias.example.test,localhost,surveys.example.test" \
  "$(docker exec -u www-data "$A" php -r "$hosts_php")"
assert_eq "the admin sign-in page answers on the new host" "200" \
  "$(ls_http "$A" /index.php/admin/authentication/sa/login -H 'Host: surveys.example.test')"
assert_eq "and on the host added by hand" "200" \
  "$(ls_http "$A" /index.php/admin/authentication/sa/login -H 'Host: alias.example.test')"
assert_eq "a host nobody listed gets 400" "400" \
  "$(ls_http "$A" /index.php/admin/authentication/sa/login -H 'Host: other.example.test')"
assert_eq "the site reads its database with the new password" "200" "$(ls_http "$A" /index.php/admin/authentication/sa/login -H 'Host: localhost')"
log="$(docker logs "$A" 2>&1)"
assert_eq "the log holds no password, old or new" "0" "$(( $(ls_secrets_in "$log") + $(grep -cF -- "$old_pw" <<< "$log") ))"
assert_lacks "an https:// PUBLIC_URL gets no warning" "$log" "PUBLIC_URL does not begin with"
docker rm -f -v "$A" >/dev/null 2>&1
SECURITY_SUM="$(docker run --rm --network none -v "${PREFIX}html:/v:ro" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" sha256sum /v/application/config/security.php | cut -d' ' -f1)"

# --- 6. an install that is cut off ----------------------------------------------------------------------------------
echo
echo "An install that is killed after it made its tables"
DB2="${PREFIX}db2"
A="${PREFIX}cut"
LS_DB_PW="$old_pw"
LS_PUBLIC_URL="http://localhost:8080"
ls_new_disk "${PREFIX}db2-data" "${PREFIX}cut-html" "${PREFIX}cut-upload"
ls_start_db "$DB2" "${PREFIX}db2-data"
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE" -e CLV_LS_TEST_PAUSE=install-done:600
rc=0; ls_wait_log "$A" "test pause at install-done" 300 || rc=$?
assert_eq "the install reaches the pause after console.php install" "0" "$rc"
assert_eq "its tables are there" "1" "$(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_users")"
assert_eq "the install stamp is on the volume" "1" "$(docker exec "$A" sh -c 'ls /var/www/html/clouve/install-in-progress 2>/dev/null | wc -l')"
assert_eq "the stand-in answers the health check meanwhile" "200" "$(ls_http "$A" /)"
docker kill "$A" >/dev/null 2>&1
docker rm -f -v "$A" >/dev/null 2>&1
ls_sql "$DB2" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('clv_test_leftover', 'from the cut-off install')" >/dev/null
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE"
rc=0; ls_wait_apache "$A" 300 || rc=$?
assert_eq "the next start installs again and Apache answers" "0" "$rc"
log="$(docker logs "$A" 2>&1)"
assert_contains "the log says it cleared the unfinished install" "$log" "an install was cut off"
assert_eq "the cut-off install's tables were dropped (its leftover row is gone)" "0" \
  "$(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_settings_global WHERE stg_name='clv_test_leftover'")"
assert_eq "there is one admin account" "1" "$(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_users")"
assert_eq "the site is LimeSurvey $VERSION" "$VERSION $DB_VERSION" "$(ls_code_version "$A")"
assert_eq "no install stamp is left" "0" "$(docker exec "$A" sh -c 'ls /var/www/html/clouve/install-in-progress 2>/dev/null | wc -l')"
docker rm -f -v "$A" >/dev/null 2>&1

# --- 7. a demo survey import that is cut off ------------------------------------------------------------------------
echo
echo "The import of the demo survey is killed before its marker is written"
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE" -e INSTALL_DEMO_DATA=true -e CLV_LS_TEST_PAUSE=demo-imported:600
rc=0; ls_wait_log "$A" "test pause at demo-imported" 300 || rc=$?
assert_eq "the import reaches the pause after the survey is in" "0" "$rc"
assert_eq "the survey is in the database, and the marker is not yet on the volume" "1 0" \
  "$(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_surveys") $(docker exec "$A" sh -c 'ls /var/www/html/.demo_data_installed 2>/dev/null | wc -l')"
docker kill "$A" >/dev/null 2>&1
docker rm -f -v "$A" >/dev/null 2>&1
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE" -e INSTALL_DEMO_DATA=true
rc=0; ls_wait_apache "$A" 300 || rc=$?
log="$(docker logs "$A" 2>&1)"
assert_eq "the next start comes up" "0" "$rc"
assert_contains "it found the survey that the last start had imported, and did not import again" "$log" "It is not imported again"
assert_eq "there is one demo survey, not two" "1" "$(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_surveys")"
assert_eq "the marker is written and the import's own stamp is gone" "1 0" \
  "$(docker exec "$A" sh -c 'echo "$(ls /var/www/html/.demo_data_installed 2>/dev/null | wc -l) $(ls /var/www/html/.demo_data_importing 2>/dev/null | wc -l)"')"
assert_eq "the start logged no warning" "" "$(grep -F '[limesurvey] WARNING' <<< "$log" | cut -c1-200)"
docker restart "$A" >/dev/null
rc=0; ls_wait_apache "$A" 120 || rc=$?
assert_eq "a restart imports nothing again" "0 1" "$rc $(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_surveys")"
docker rm -f -v "$A" >/dev/null 2>&1

# --- 8. a restore that the skill has under way ----------------------------------------------------------------------
echo
echo "The AI Assistant's skill has a restore under way when the container starts"
# What the skill's restore.sh leaves when the container restarts in the middle: its marker, a folder and a file of
# root's, and a database that is half loaded (here: LimeSurvey's settings table is not there yet).
docker run --rm --network none -v "${PREFIX}cut-html:/v" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" sh -c \
  'mkdir -p -m 700 /v/clouve/backups && printf "20261112-101500\nstarted 20261112-101502 UTC\n" > /v/clouve/backups/RESTORE-IN-PROGRESS &&
   chmod 600 /v/clouve/backups/RESTORE-IN-PROGRESS && chown -R 0:0 /v/clouve/backups' || fail "the marker could be written"
ls_sql "$DB2" "RENAME TABLE lime_settings_global TO clv_not_loaded_yet" >/dev/null
tables_before="$(ls_sql "$DB2" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey'")"
A="${PREFIX}rest"
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW" -e DB_WAIT_SECONDS=5
rc=0; ls_wait_log "$A" "a restore from a backup is under way" 60 || rc=$?
assert_eq "the start says that a restore is under way" "0" "$rc"
sleep 12
log="$(docker logs "$A" 2>&1)"
assert_eq "it is still waiting after 12 s, though DB_WAIT_SECONDS is 5" "true entrypoint.sh" \
  "$(docker inspect --format '{{.State.Running}}' "$A") $(ls_pid1 "$A")"
assert_eq "it said so once" "1" "$(grep -c 'a restore from a backup is under way' <<< "$log")"
assert_contains "the line says how to finish the restore or give it up" "$log" "To give the restore up, remove the marker as root"
assert_eq "it decided nothing about the site: no install, no upgrade, no refusal" "0" \
  "$(grep -c -e 'new install' -e '\[clouve-upgrade\]' -e '\[limesurvey\] ERROR' -e 'waiting for the database' <<< "$log")"
assert_contains "the page says that the site is being restored" \
  "$(docker exec "$A" curl -s -m 10 http://127.0.0.1:8080/)" "LimeSurvey is being restored"
assert_eq "the health check answers 200, and everything else 503" "200 503" "$(ls_http "$A" /) $(ls_http "$A" /index.php/admin)"
ls_assert_note "a restore under way" "$A" restore
assert_contains "the note's reason is the log line's words" "$(docker exec "$A" cat /var/www/html/clouve/needs-attention 2>&1)" \
  "reason=a restore from a backup is under way ("
whoami=""
for _ in $(seq 1 30); do whoami="$(ls_ssh_whoami "$A" "$LS_OPS_PW")"; [ -n "$whoami" ] && break; sleep 1; done
assert_eq "clouve-ops signs in, to finish the restore" "clouve-ops" "$whoami"
assert_eq "the database is as the restore left it" "$tables_before" \
  "$(ls_sql "$DB2" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey'")"
t0=$(date +%s)
docker stop -t 30 "$A" >/dev/null 2>&1
took=$(( $(date +%s) - t0 ))
if [ "$took" -le 8 ]; then pass "docker stop ends the wait in $took s"; else fail "docker stop ends the wait in $took s"; fi
assert_eq "with status 0" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$A")"
docker rm -f -v "$A" >/dev/null 2>&1
ls_start_app "$A" "$DB2" "${PREFIX}cut-html" "${PREFIX}cut-upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW"
rc=0; ls_wait_log "$A" "a restore from a backup is under way" 60 || rc=$?
assert_eq "a new container waits again" "0" "$rc"
# The restore finishes: the table is there, and the marker goes.
ls_sql "$DB2" "RENAME TABLE clv_not_loaded_yet TO lime_settings_global" >/dev/null
docker exec "$A" rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS
rc=0; ls_wait_apache "$A" 120 || rc=$?
log="$(docker logs "$A" 2>&1)"
assert_eq "with the marker gone, the same container starts the site" "0" "$rc"
assert_contains "the log says the start goes on" "$log" "the restore's marker is gone: the start goes on"
assert_eq "and the note is gone" "gone" "$(docker exec "$A" sh -c 'if [ -e /var/www/html/clouve/needs-attention ]; then echo there; else echo gone; fi')"
assert_contains "and the site is the one from before" "$log" "nothing to install or upgrade"
assert_eq "the page is LimeSurvey's again" "0" "$(docker exec "$A" curl -s -m 10 http://127.0.0.1:8080/ | grep -c 'is being restored')"
docker rm -f -v "$A" >/dev/null 2>&1

# --- 9. an installed site whose database was lost -------------------------------------------------------------------
echo
echo "An installed site whose database was lost: the install into the empty database is killed halfway"
LS_DB_PW="$NEW_DB_PW"
docker exec -e "MYSQL_PWD=$LS_DB_ROOT_PW" "$DB" mariadb -u root -e 'DROP DATABASE limesurvey; CREATE DATABASE limesurvey' >/dev/null 2>&1 ||
  fail "the first site's database could be emptied"
A="${PREFIX}app"
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE" -e CLV_LS_TEST_PAUSE=install-done:600
rc=0; ls_wait_log "$A" "test pause at install-done" 120 || rc=$?
assert_eq "the start installs into the empty database" "0" "$rc"
docker kill "$A" >/dev/null 2>&1
# What a kill in the middle of the installer leaves: some of the tables. LimeSurvey's settings table, which says
# that a site is installed, is among them, and the users table is not.
ls_sql "$DB" "DROP TABLE lime_users, lime_surveys, lime_questions, lime_permissions" >/dev/null
echo "       killed, with $(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey'") tables left in the database"
assert_eq "the install's stamp is on the volume, and says that only the database was being installed" "mode=database" \
  "$(docker run --rm --network none -v "${PREFIX}html:/v:ro" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" sh -c 'grep "^mode=" /v/clouve/install-in-progress 2>/dev/null')"
docker rm -f -v "$A" >/dev/null 2>&1
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE"
rc=0; ls_wait_apache "$A" 300 || rc=$?
log="$(docker logs "$A" 2>&1)"
assert_eq "the next start comes up" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 15 | sed 's/^/       | /'
assert_contains "it cleared the cut-off install and installed again" "$log" "an install was cut off"
assert_eq "the database is whole: version $DB_VERSION, one admin account" "$DB_VERSION 1" \
  "$(ls_db_version "$DB") $(ls_sql "$DB" "SELECT COUNT(*) FROM lime_users")"
assert_eq "security.php is the one from before the database was lost" "$SECURITY_SUM" \
  "$(docker exec "$A" sha256sum /var/www/html/application/config/security.php | cut -d' ' -f1)"
assert_eq "the code on the volume was not copied again" "0" "$(grep -c 'new install: copying LimeSurvey' <<< "$log")"
assert_eq "no install stamp is left" "0" "$(docker exec "$A" sh -c 'ls /var/www/html/clouve/install-in-progress 2>/dev/null | wc -l')"
docker rm -f -v "$A" >/dev/null 2>&1
LS_DB_PW="$old_pw"

# --- 10. config.php with commented-out settings, and a PUBLIC_URL that is no web address ----------------------------
echo
echo "A config.php that has its settings commented out as well"
# shellcheck disable=SC2016  # the script is for the bash in the container
out="$(docker run --rm --network none -u www-data -e LS_ROOT=/tmp/site -e DB_PASSWORD=new-pw-61f0 -e DB_HOST=new-host \
  -e DB_USERNAME=new-user -e DB_NAME=limesurvey -e PUBLIC_URL=https://new.example.test --entrypoint bash "$IMAGE" -c '
  mkdir -p /tmp/site/application/config && cat > /tmp/site/application/config/config.php <<"PHP"
<?php if (!defined("BASEPATH")) exit("No direct script access allowed");
return array(
  "components" => array(
    "db" => array(
      "connectionString" => "mysql:host=old-host;port=3306;dbname=limesurvey;",
      // "password" => "commented-out-1",
      # "username" => "commented-out-2",
      "username" => "old-user",
      /* "password" => "commented-out-3", */
      "password" => "old-pw",
      "charset" => "utf8mb4",
    ),
  ),
  "config" => array(
    // "publicurl" => "http://commented-out-4.example.test",
    "publicurl" => "http://old.example.test",
    "debug" => 0,
  ),
);
PHP
  changed="$(php /clouve/limesurvey/installer/tool.php sync-config 2>&1)"; echo "status=$? changed=$changed"
  php -r "define(\"BASEPATH\", \".\"); \$c = include \"/tmp/site/application/config/config.php\";
    echo \$c[\"components\"][\"db\"][\"password\"], \" \", \$c[\"components\"][\"db\"][\"username\"], \" \",
      \$c[\"components\"][\"db\"][\"connectionString\"], \" \", \$c[\"config\"][\"publicurl\"], \"\n\";"
  echo "comments=$(grep -c "commented-out-[1-4]" /tmp/site/application/config/config.php)"' 2>&1)"
assert_contains "tool.php changed the four settings" "$out" "status=0 changed=connectionString username password publicurl"
assert_contains "the real lines have the new values" "$out" \
  "new-pw-61f0 new-user mysql:host=new-host;port=3306;dbname=limesurvey; https://new.example.test"
assert_contains "and the four commented-out lines are as they were" "$out" "comments=4"

echo
echo "A PUBLIC_URL without http://"
LS_PUBLIC_URL="surveys.example.test"
A="${PREFIX}app"
LS_DB_PW="$NEW_DB_PW"
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE"
rc=0; ls_wait_apache "$A" 120 || rc=$?
LS_DB_PW="$old_pw"
LS_PUBLIC_URL="http://localhost:8080"
assert_eq "the site starts" "0" "$rc"
assert_contains "and the log warns that PUBLIC_URL is no web address" "$(docker logs "$A" 2>&1)" \
  "[limesurvey] WARNING: PUBLIC_URL does not begin with http:// or https://"
docker rm -f -v "$A" >/dev/null 2>&1

# --- 11. no code, but tables in the database ------------------------------------------------------------------------
echo
echo "A volume with no code and a database with tables"
A="${PREFIX}lost"
ls_new_disk "${PREFIX}lost-html" "${PREFIX}lost-upload"
tables_before="$(ls_sql "$DB2" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey'")"
ls_start_app "$A" "$DB2" "${PREFIX}lost-html" "${PREFIX}lost-upload" "$IMAGE" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW"
rc=0; ls_wait_hold "$A" 120 || rc=$?
log="$(docker logs "$A" 2>&1)"
assert_eq "the start waits for repair" "0" "$rc"
ls_assert_hold "no code, but tables" "$A"
ls_assert_note "no code, but tables" "$A" repair
assert_contains "the log says why" "$log" "the volume holds no LimeSurvey code, but the database limesurvey has $tables_before tables"
assert_eq "clouve-ops can sign in" "clouve-ops" "$(ls_ssh_whoami "$A" "$LS_OPS_PW")"
assert_eq "the database is as it was" "$tables_before 1" \
  "$(ls_sql "$DB2" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='limesurvey'") $(ls_sql "$DB2" "SELECT COUNT(*) FROM lime_users")"
assert_eq "no code was copied onto the volume" "0" \
  "$(docker run --rm --network none -v "${PREFIX}lost-html:/v:ro" "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}" sh -c 'ls /v/index.php /v/application 2>/dev/null | wc -l')"
t0=$(date +%s)
docker stop -t 30 "$A" >/dev/null 2>&1
took=$(( $(date +%s) - t0 ))
if [ "$took" -le 8 ]; then pass "docker stop ends the wait in $took s, with status $(docker inspect --format '{{.State.ExitCode}}' "$A")"; else
  fail "docker stop ends the wait in $took s"; fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sLimeSurvey entrypoint checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sLimeSurvey entrypoint checks failed.%s\n' "$RED" "$RESET"
exit 1
