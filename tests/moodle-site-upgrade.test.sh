#!/bin/bash

# ============================================================================
# Moodle site upgrade test: an older image's site, upgraded by the newer image
# ============================================================================
# Starts the Moodle image at --from TAG on volumes shaped like new cluster disks
# (lib/new-disk-volumes.sh), installs the site, and gives it made-up data: a
# course category, a course, a user enrolled in it and a cohort. It adds plugins
# the way Site administration > Plugins > Install plugins does (their folders in
# the code tree, then Moodle's upgrade): the ZIPs in --plugin-zips, or stand-ins,
# plus one whose supported range ends at the old branch. It puts the category,
# the course, the cohort and the user on the Classic theme, gives Classic a brand
# colour, and forces Classic as the site theme in config.php only (the site's own
# setting stays Boost, so only the forced line can make Moodle carry Classic's
# settings over: config.php must still force it when Moodle upgrades). Then it stops that
# container and starts the image at --to TAG on the same volumes, as a cluster
# does when a listing moves to a newer image.
#
# It checks that the upgrade ran once, in maintenance mode, and left it off; that
# the database is at the new image's $version; that the added plugins are there
# and installed, and the one outside its supported range is held back in
# clouve/upgrade-stash/ with the reason in the log; that the data is there; that
# Moodle's status, security and performance checks fail on nothing that passed
# before (it lists the checks that are new in the new Moodle and don't pass); the site and every category, course, cohort and user theme are Boost, with
# Classic's brand colour on Boost and Classic uninstalled; that config.php no
# longer forces Classic; that GET / answers 200 (after Moodle's redirect to its
# login page, as Moodle forces login by default); that Moodle's CLI upgrade has
# nothing left to do; that cron runs; and that a restart doesn't upgrade again.
#
# --cut-off stops the new container (docker kill) while Moodle's database upgrade
# runs, then starts it again: the second start must finish the upgrade with the
# same result.
#
# --newer-core-plugin adds a made-up report_aiusage at version 2026110100 to the old
# site. Moodle 5.3 ships its own report_aiusage at 2026100500, and Moodle can't go
# back to an older version of a plugin, so the new image must leave the site on its
# old code: no new version recorded, GET / still answering, and the log saying why.
# Deleting only the plugin's folder must not change that (Moodle still records the
# newer version); uninstalling it in Moodle, as the log says, must let the next
# start upgrade the site.
#
# The images are r.clv.zone/e2eorg/moodle and moodle-mysql at each tag, as
# ./build.sh tags them; the database image comes from --from both times. Needs
# Docker and python3. Everything it starts runs on a network of its own with no
# published ports, and it removes all of it at the end unless --keep is given.
#
# Usage: bash tests/moodle-site-upgrade.test.sh --from TAG [--to TAG] [--plugin-zips DIR] [--cut-off]
#                                              [--newer-core-plugin] [--keep]
#   --to defaults to latest. Exit status: 0 when every check passes, 1 when one
#   fails, 2 when the test can't run (no image, Docker missing).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/new-disk-volumes.sh
. "$REPO/lib/new-disk-volumes.sh"

FROM=""
TO=latest
ZIPS=""
CUT_OFF=false
NEWER_CORE=false
KEEP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift ;;
    --to) TO="${2:-}"; shift ;;
    --plugin-zips) ZIPS="${2:-}"; shift ;;
    --cut-off) CUT_OFF=true ;;
    --newer-core-plugin) NEWER_CORE=true ;;
    --keep) KEEP=true ;;
    *) sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *fails, 2/p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$FROM" ] || [ -z "$TO" ]; then
  echo "Usage: bash tests/moodle-site-upgrade.test.sh --from TAG [--to TAG] [--plugin-zips DIR] [--cut-off]" \
    "[--newer-core-plugin] [--keep]" >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi
OLD_IMAGE="r.clv.zone/e2eorg/moodle:$FROM"
NEW_IMAGE="r.clv.zone/e2eorg/moodle:$TO"
DB_IMAGE="r.clv.zone/e2eorg/moodle-mysql:$FROM"
for image in "$OLD_IMAGE" "$NEW_IMAGE" "$DB_IMAGE"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "No image $image on this machine." >&2
    exit 2
  fi
done

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
assert_not_contains() { if ! grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$3"; fi; }

RUN="msu-$$"
NET="$RUN-net"
DB="$RUN-db"
APP="$RUN-app"
WORK="$(mktemp -d)"
cleanup() {
  if [ "$KEEP" = true ]; then
    echo "Kept: containers $DB and $APP, network $NET, volumes $RUN-db_data, $RUN-moodle_data and $RUN-moodledata"
  else
    docker rm -f "$APP" "$DB" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker volume rm -f "$RUN-db_data" "$RUN-moodle_data" "$RUN-moodledata" >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# The site's settings, all made up. Nothing here is a real account.
DB_ENV=(-e MYSQL_DATABASE=moodle -e MYSQL_USER=moodle -e MYSQL_PASSWORD=moodle_password
  -e MYSQL_ROOT_PASSWORD=root_password)
APP_ENV=(-e DB_HOST="$DB" -e DB_NAME=moodle -e DB_USER=moodle -e DB_PASSWORD=moodle_password
  -e MOODLE_URL=http://localhost -e MOODLE_SITE_NAME="Sample Moodle Site" -e MOODLE_EMAIL=admin@example.invalid
  -e MOODLE_USERNAME=admin -e MOODLE_PASSWORD=Sample-Admin-1 -e "MOODLE_CRON_INTERVAL=* * * * *")

# start_app IMAGE: the Moodle container on the site's volumes.
start_app() {
  docker rm -f "$APP" >/dev/null 2>&1
  docker run -d --name "$APP" --network "$NET" "${APP_ENV[@]}" \
    -v "$RUN-moodle_data:/var/www/html" -v "$RUN-moodledata:/var/moodledata" "$1" >/dev/null
}
# wait_for_log CONTAINER TEXT SECONDS [SKIP]: waits until the container's log, after its first SKIP lines, has the
# text; status 1 if the container stops or the time runs out.
# It takes the log first and then searches it, so only grep's answer counts (not a pipe that docker logs or tail
# ended early).
wait_for_log() {
  local end=$((SECONDS + $3)) log
  while (( SECONDS < end )); do
    log="$(docker logs "$1" 2>&1)"
    grep -qF -- "$2" <<< "$(tail -n +"$((${4:-0} + 1))" <<< "$log")" && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || return 1
    sleep 5
  done
  return 1
}
# in_app COMMAND...: a command in the Moodle container, as www-data.
in_app() { docker exec -u www-data "$APP" "$@"; }
# sql QUERY: one MySQL query's rows, tab-separated, no header.
sql() { docker exec "$DB" mysql -umoodle -pmoodle_password moodle -N -B -e "$1" 2>/dev/null; }
# http_status: GET / on the site, from inside its container: the first answer's status (what the platform's probe
# sees), then the status at the end of the site's redirects (Moodle forces login by default, so / sends a visitor to
# the login page).
http_status() {
  printf '%s %s' "$(docker exec "$APP" curl -s -o /dev/null -w '%{http_code}' http://localhost/)" \
    "$(docker exec "$APP" curl -s -L --max-redirs 5 -o /dev/null -w '%{http_code}' http://localhost/)"
}
# all_checks: every status, security and performance check of Moodle's, one "<check> <status>" per line, as
# admin/cli/checks.php runs them. This runner loads lib/filelib.php first, because Moodle's public paths check uses its
# curl class without loading it (checks.php then stops on "Class curl not found" in 5.2 and 5.3 alike). The site's
# wwwroot (http://localhost) is the container's own Apache, so the checks that fetch pages work here.
all_checks() {
  docker exec -i -u www-data "$APP" php <<'PHP' 2>/dev/null | sort -u
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->libdir . '/filelib.php');
foreach (['status', 'security', 'performance'] as $type) {
    foreach (\core\check\manager::get_checks($type) as $check) {
        try {
            $status = $check->get_result()->get_status();
        } catch (\Throwable $e) {
            $status = 'exception';
        }
        echo $check->get_ref(), ' ', $status, "\n";
    }
}
PHP
}
# failing CHECKS: the checks of an all_checks list that don't pass (warning or worse).
failing() { awk '$2 !~ /^(ok|info|na)$/ {print $1}' <<< "$1"; }
# assert_get_root LABEL: GET / answers 200, or a redirect to a page on the site that answers 200.
assert_get_root() {
  local codes tries=0
  codes="$(http_status)"
  while [[ "$codes" == 000* ]] && (( tries++ < 15 )); do   # Apache starts just after the entrypoint's last line
    sleep 2
    codes="$(http_status)"
  done
  if [[ "$codes" == "200 200" || "$codes" =~ ^30[1-8]\ 200$ ]]; then pass "$1 ($codes)"; else
    fail "$1"; printf '       GET / then the end of its redirects: %s\n' "$codes"; fi
}

echo "Moodle site upgrade: $OLD_IMAGE -> $NEW_IMAGE$([ "$CUT_OFF" = true ] && echo ', cut off during the upgrade')"

# --- The site on the old image ---------------------------------------------------
nd_shaper_ready || exit 2
docker network create "$NET" >/dev/null || exit 2
for key in db_data moodle_data moodledata; do
  nd_make_new_disk "$RUN-$key" "$RUN" "$key" || exit 2
done
docker run -d --name "$DB" --network "$NET" "${DB_ENV[@]}" -v "$RUN-db_data:/var/lib/mysql" "$DB_IMAGE" >/dev/null || exit 2
start_app "$OLD_IMAGE" || exit 2
if ! wait_for_log "$APP" "DONE!" 900; then
  docker logs "$APP" 2>&1 | tail -n 30 | sed 's/^/    old: /'
  echo "The old image's site did not install." >&2
  exit 1
fi
OLD_VERSION="$(sql "SELECT value FROM mdl_config WHERE name = 'version'")"
OLD_BRANCH="$(sql "SELECT value FROM mdl_config WHERE name = 'branch'")"
echo "  Installed: Moodle $(sql "SELECT value FROM mdl_config WHERE name = 'release'") ($OLD_VERSION)"

# The added plugins: the ZIPs' plugins, or stand-ins, and one whose supported range ends at the old branch.
SRC="$WORK/plugins"
mkdir -p "$SRC/0/oldsupport/lang/en"
if [ -n "$ZIPS" ]; then
  python3 -I -c '
import pathlib, sys, zipfile
for n, z in enumerate(sorted(pathlib.Path(sys.argv[1]).glob("*.zip")), start=1):
    with zipfile.ZipFile(z) as f:
        f.extractall(pathlib.Path(sys.argv[2]) / str(n))
' "$ZIPS" "$SRC" || exit 2
else
  for p in local:sitetool theme:childtheme; do
    type="${p%%:*}" name="${p#*:}"
    mkdir -p "$SRC/$name/$name/lang/en"
    printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$plugin->component = '%s';\n\$plugin->version = 2026010100;\n\$plugin->requires = 2024100700;\n" \
      "${type}_$name" > "$SRC/$name/$name/version.php"
    printf "<?php\n\$string['pluginname'] = 'Sample %s';\n" "$name" > "$SRC/$name/$name/lang/en/${type}_$name.php"
  done
  printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$THEME->name = 'childtheme';\n\$THEME->parents = ['boost'];\n\$THEME->sheets = [];\n\$THEME->rendererfactory = 'theme_overridden_renderer_factory';\n" \
    > "$SRC/childtheme/childtheme/config.php"
fi
printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$plugin->component = 'local_oldsupport';\n\$plugin->version = 2026010100;\n\$plugin->supported = [401, %s];\n" \
  "$OLD_BRANCH" > "$SRC/0/oldsupport/version.php"
printf "<?php\n\$string['pluginname'] = 'Sample old plugin';\n" > "$SRC/0/oldsupport/lang/en/local_oldsupport.php"
if [ "$NEWER_CORE" = true ]; then
  mkdir -p "$SRC/newer/aiusage/lang/en"
  printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$plugin->component = 'report_aiusage';\n\$plugin->version = 2026110100;\n\$plugin->requires = 2024100700;\n" \
    > "$SRC/newer/aiusage/version.php"
  printf "<?php\n\$string['pluginname'] = 'Sample AI usage report';\n" > "$SRC/newer/aiusage/lang/en/report_aiusage.php"
fi
COMPONENTS=()
for dir in "$SRC"/*/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  component="$(sed -nE "s/^[[:space:]]*\\\$plugin->component[[:space:]]*=[[:space:]]*'([a-z0-9_]+)'.*/\\1/p" "$dir/version.php")"
  type="${component%%_*}"
  typedir="$(in_app php -r '$c = json_decode(file_get_contents("/var/www/html/lib/components.json"), true);
    echo $c["plugintypes"][$argv[1]] ?? "";' "$type")"
  if [ -z "$component" ] || [ -z "$typedir" ]; then
    echo "Can't place the plugin in $dir." >&2
    exit 2
  fi
  docker cp "$dir" "$APP:/var/www/html/$typedir/$name" >/dev/null || exit 2
  docker exec "$APP" chown -R www-data:www-data "/var/www/html/$typedir/$name"
  COMPONENTS+=("$component")
done
if ! in_app php /var/www/html/admin/cli/upgrade.php --non-interactive > "$WORK/install-plugins.log" 2>&1; then
  tail -n 20 "$WORK/install-plugins.log" | sed 's/^/    install: /'
  echo "The old site could not install the plugins." >&2
  exit 1
fi

# Made-up data, and the Classic theme everywhere it can be chosen.
cat > "$WORK/seed.php" <<'PHP'
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->dirroot . '/course/lib.php');
require_once($CFG->dirroot . '/user/lib.php');
require_once($CFG->dirroot . '/cohort/lib.php');
require_once($CFG->libdir . '/enrollib.php');
\core\cron::setup_user();
$category = core_course_category::create(['name' => 'Sample Faculty', 'idnumber' => 'SAMPLE-FAC']);
$course = create_course((object)['fullname' => 'Introduction to Sample Studies', 'shortname' => 'SAMPLE101',
    'category' => $category->id]);
$userid = user_create_user((object)['username' => 'sample.learner', 'password' => 'Sample-Learner-1',
    'firstname' => 'Sam', 'lastname' => 'Learner', 'email' => 'sam.learner@example.invalid', 'auth' => 'manual',
    'confirmed' => 1, 'mnethostid' => $CFG->mnet_localhost_id]);
$cohortid = cohort_add_cohort((object)['contextid' => context_system::instance()->id, 'name' => 'Sample Cohort',
    'idnumber' => 'SAMPLE-COH']);
cohort_add_member($cohortid, $userid);
enrol_try_internal_enrol($course->id, $userid, $DB->get_field('role', 'id', ['shortname' => 'student']));
foreach (['allowcategorythemes', 'allowcoursethemes', 'allowcohortthemes', 'allowuserthemes'] as $setting) {
    set_config($setting, 1);
}
set_config('brandcolor', '#0f6e5a', 'theme_classic');
$DB->set_field('course_categories', 'theme', 'classic', ['id' => $category->id]);
$DB->set_field('course', 'theme', 'classic', ['id' => $course->id]);
$DB->set_field('cohort', 'theme', 'classic', ['id' => $cohortid]);
$DB->set_field('user', 'theme', 'classic', ['id' => $userid]);
purge_all_caches();
echo "seeded\n";
PHP
docker cp "$WORK/seed.php" "$APP:/tmp/seed.php" >/dev/null && docker exec "$APP" chmod 644 /tmp/seed.php
if ! in_app php /tmp/seed.php > "$WORK/seed.log" 2>&1 || ! grep -q '^seeded$' "$WORK/seed.log"; then
  tail -n 20 "$WORK/seed.log" | sed 's/^/    seed: /'
  echo "The old site could not be given its data." >&2
  exit 1
fi
docker exec "$APP" sed -i "/require_once.*lib\/setup.php/i \$CFG->theme = 'classic';" /var/www/html/config.php
assert_get_root "the old site answers GET / with 200, after its redirect to the login page"
OLD_CHECKS="$(all_checks)"
echo "  Checks that fail on the old site: $(failing "$OLD_CHECKS" | tr '\n' ' ')"
docker stop -t 30 "$APP" >/dev/null
docker rm "$APP" >/dev/null

# --- The new image on the same volumes -----------------------------------------
start_app "$NEW_IMAGE" || exit 2
if [ "$CUT_OFF" = true ]; then
  # Moodle's upgrade prints a "-->component" line for each plugin it upgrades, after core's steps: killing the
  # container at the first one cuts the upgrade off in the middle.
  if wait_for_log "$APP" "Running database upgrade" 600 && wait_for_log "$APP" "-->" 300; then
    docker kill "$APP" >/dev/null
    echo "  Cut off: killed the new container while Moodle's database upgrade ran ($(docker logs "$APP" 2>&1 |
      grep -m1 -e '-->'))"
    docker logs "$APP" > "$WORK/cut.log" 2>&1
    start_app "$NEW_IMAGE" || exit 2
  else
    fail "the upgrade reached Moodle's database upgrade, where the test cuts it off"
  fi
fi
if ! wait_for_log "$APP" "DONE!" 1200; then
  fail "the new image starts the site"
  docker logs "$APP" 2>&1 | tail -n 40 | sed 's/^/    new: /'
  exit 1
fi
LOG="$(docker logs "$APP" 2>&1)"
if [ "$NEWER_CORE" = true ]; then
  assert_contains "the new image leaves the site on its old code" "$LOG" "NOT UPGRADED"
  assert_contains "and says why" "$LOG" "report_aiusage: the site has version 2026110100 of it"
  assert_eq "the database stays at the old version" "${OLD_VERSION%%.*}" \
    "$(sql "SELECT value FROM mdl_config WHERE name = 'version'" | cut -d. -f1)"
  assert_eq "the volume's marker too" "${OLD_VERSION%%.*}" "$(docker exec "$APP" cat /var/www/html/clouve/installed/version)"
  assert_eq "the code on the volume is the old one" "${OLD_VERSION%%.*}" "$(in_app sed -nE \
    's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' /var/www/html/public/version.php)"
  assert_eq "nothing was moved aside" "no" \
    "$(docker exec "$APP" sh -c 'test -e /var/www/html/clouve/upgrade-previous && echo yes || echo no')"
  assert_get_root "GET / answers 200 on the old code"
  # An admin who deletes only the folder: Moodle still records the newer version, so the site still isn't upgraded.
  docker exec "$APP" rm -rf /var/www/html/public/report/aiusage
  BEFORE="$(docker logs "$APP" 2>&1 | wc -l)"
  docker restart -t 30 "$APP" >/dev/null
  if wait_for_log "$APP" "Cron daemon started" 600 "$BEFORE"; then
    NEXT="$(docker logs "$APP" 2>&1 | tail -n +"$((BEFORE + 1))")"
    assert_contains "with only its folder deleted, the site still isn't upgraded" "$NEXT" "NOT UPGRADED"
    assert_contains "because Moodle still records the newer version" "$NEXT" \
      "report_aiusage: Moodle has version 2026110100 of it recorded"
    assert_get_root "and GET / still answers 200"
  else
    fail "the site restarts with the folder deleted"
  fi
  # The way out the log gives: uninstall it in Moodle while the site runs its old code, then start again.
  assert_contains "Moodle's CLI uninstalls it" \
    "$(in_app php /var/www/html/admin/cli/uninstall_plugins.php --plugins=report_aiusage --run 2>&1)" "Uninstalling"
  BEFORE="$(docker logs "$APP" 2>&1 | wc -l)"
  docker restart -t 30 "$APP" >/dev/null
  if wait_for_log "$APP" "Cron daemon started" 900 "$BEFORE"; then
    NEXT="$(docker logs "$APP" 2>&1 | tail -n +"$((BEFORE + 1))")"
    assert_contains "then the next start upgrades the site" "$NEXT" "Moodle upgrade completed successfully"
    NEW_VERSION="$(in_app sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
      /var/www/html/public/version.php)"
    assert_eq "to the new image's version" "$NEW_VERSION" \
      "$(sql "SELECT value FROM mdl_config WHERE name = 'version'" | cut -d. -f1)"
    assert_eq "with the new Moodle's own report_aiusage" \
      "$(in_app sed -nE 's/^[[:space:]]*\$plugin->version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
        /var/www/html/public/report/aiusage/version.php)" \
      "$(sql "SELECT value FROM mdl_config_plugins WHERE plugin = 'report_aiusage' AND name = 'version'")"
    assert_get_root "and GET / answers 200 on the new code"
  else
    fail "the site restarts after the uninstall"
  fi
  echo
  if [[ "$FAILED" -eq 0 ]]; then printf "${GREEN}All checks passed.${NC}\n"; else printf "${RED}Some checks failed.${NC}\n"; fi
  exit "$FAILED"
fi
if [ "$CUT_OFF" = true ]; then
  assert_not_contains "the cut-off start didn't finish the upgrade" "$(cat "$WORK/cut.log")" "Moodle upgrade completed successfully"
  assert_contains "the next start picks up the upgrade that was cut off" "$LOG" "Picking up an upgrade that was cut off"
fi
NEW_VERSION="$(in_app sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9.]+).*/\1/p' /var/www/html/public/version.php)"
assert_eq "the upgrade ran once$([ "$CUT_OFF" = true ] && echo ' in this start')" "1" \
  "$(grep -c '^UPGRADING Moodle' <<< "$LOG")"
assert_contains "from the old version to the new" "$LOG" "UPGRADING Moodle ${OLD_VERSION%%.*} -> ${NEW_VERSION%%.*}"
assert_eq "in maintenance mode" "1" "$(grep -c 'Enabling maintenance mode' <<< "$LOG")"
assert_eq "which it turned off" "1" "$(grep -c 'Disabling maintenance mode' <<< "$LOG")"
assert_eq "and nothing keeps the site in maintenance" "no" \
  "$(docker exec "$APP" sh -c 'test -e /var/moodledata/climaintenance.html && echo yes || echo no')"
DB_VERSION="$(sql "SELECT value FROM mdl_config WHERE name = 'version'")"
assert_eq "the database is at the new image's version" "${NEW_VERSION%%.*}" "${DB_VERSION%%.*}"
assert_eq "the volume's marker records it" "${NEW_VERSION%%.*}" "$(docker exec "$APP" cat /var/www/html/clouve/installed/version)"
for component in "${COMPONENTS[@]}"; do
  [ "$component" = local_oldsupport ] && continue
  type="${component%%_*}" name="${component#*_}"
  typedir="$(in_app php -r '$c = json_decode(file_get_contents("/var/www/html/lib/components.json"), true);
    echo $c["plugintypes"][$argv[1]] ?? "";' "$type")"
  disk="$(docker exec "$APP" cat "/var/www/html/$typedir/$name/version.php" 2>/dev/null |
    sed -nE 's/^[[:space:]]*\$plugin->version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p')"
  installed="$(sql "SELECT value FROM mdl_config_plugins WHERE plugin = '$component' AND name = 'version'")"
  if [ -n "$disk" ] && [ "$disk" = "$installed" ]; then pass "$component is there and installed ($installed)"; else
    fail "$component is there and installed (disk: ${disk:-none}, database: ${installed:-none})"; fi
done
assert_contains "the plugin outside its supported range is held back, and the log says why" "$LOG" \
  "local_oldsupport held back (its version.php supports Moodle 401 to $OLD_BRANCH, not "
assert_eq "its code is in the stash" "1" \
  "$(docker exec "$APP" sh -c 'ls -d /var/www/html/clouve/upgrade-stash/*/public/local/oldsupport 2>/dev/null | wc -l')"
assert_eq "the course is there" "Introduction to Sample Studies" \
  "$(sql "SELECT fullname FROM mdl_course WHERE shortname = 'SAMPLE101'")"
assert_eq "the user is there, enrolled" "1" "$(sql "SELECT COUNT(*) FROM mdl_user_enrolments ue
  JOIN mdl_user u ON u.id = ue.userid JOIN mdl_enrol e ON e.id = ue.enrolid JOIN mdl_course c ON c.id = e.courseid
  WHERE u.username = 'sample.learner' AND c.shortname = 'SAMPLE101'")"
assert_eq "the cohort is there, with its member" "1" "$(sql "SELECT COUNT(*) FROM mdl_cohort_members m
  JOIN mdl_cohort c ON c.id = m.cohortid WHERE c.idnumber = 'SAMPLE-COH'")"
assert_eq "the site theme is Boost" "boost" "$(sql "SELECT value FROM mdl_config WHERE name = 'theme'")"
assert_eq "no category, course, cohort or user is left on Classic" "0" "$(sql "SELECT
  (SELECT COUNT(*) FROM mdl_course_categories WHERE theme = 'classic') + (SELECT COUNT(*) FROM mdl_course WHERE theme = 'classic')
  + (SELECT COUNT(*) FROM mdl_cohort WHERE theme = 'classic') + (SELECT COUNT(*) FROM mdl_user WHERE theme = 'classic')")"
assert_eq "Classic's brand colour is Boost's now" "#0f6e5a" \
  "$(sql "SELECT value FROM mdl_config_plugins WHERE plugin = 'theme_boost' AND name = 'brandcolor'")"
assert_eq "Classic is uninstalled" "0" "$(sql "SELECT COUNT(*) FROM mdl_config_plugins WHERE plugin = 'theme_classic'")"
assert_eq "and not in the code" "no" \
  "$(docker exec "$APP" sh -c 'test -e /var/www/html/public/theme/classic && echo yes || echo no')"
CONFIG="$(docker exec "$APP" cat /var/www/html/config.php)"
assert_contains "config.php no longer forces Classic" "$CONFIG" \
  "// Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \$CFG->theme = 'classic';"
assert_get_root "GET / answers 200, after its redirect to the login page"
NEW_CHECKS="$(all_checks)"
echo "  Checks that fail on the upgraded site: $(failing "$NEW_CHECKS" | tr '\n' ' ')"
echo "  Checks new in this Moodle that don't pass: $(comm -13 <(awk '{print $1}' <<< "$OLD_CHECKS") \
  <(failing "$NEW_CHECKS" | sort) | tr '\n' ' ')"
assert_eq "the upgrade makes no check fail that passed before" "" \
  "$(comm -12 <(comm -13 <(failing "$OLD_CHECKS" | sort) <(failing "$NEW_CHECKS" | sort)) <(awk '{print $1}' <<< "$OLD_CHECKS"))"
UPGRADE_CLI="$(in_app php /var/www/html/admin/cli/upgrade.php --non-interactive 2>&1)"
assert_contains "Moodle's CLI upgrade has nothing left to do" "$UPGRADE_CLI" "No upgrade needed"
# Moodle's cron.php keeps running for a few minutes after its tasks (cron_keepalive), so "Completed" comes late: a
# scheduled task that completes shows that cron runs.
CRON_OK=false
if ! wait_for_log "$APP" "Cron daemon started" 60; then
  fail "the entrypoint says it started cron (within 60 s)"
elif docker exec "$APP" sh -c \
    'for i in $(seq 1 60); do grep -q "^Scheduled task complete:" /var/log/moodle-cron.log && exit 0; sleep 5; done; exit 1'; then
  pass "cron runs Moodle's scheduled tasks"
  CRON_OK=true
else
  fail "cron runs Moodle's scheduled tasks (within 5 minutes)"
fi
if [ "$CRON_OK" = false ]; then
  docker inspect -f 'container started {{.State.StartedAt}}, restarts {{.RestartCount}}' "$APP" 2>&1 | sed 's/^/    cron: /'
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  docker exec "$APP" sh -c 'echo "PID 1 age: $(ps -o etime= -p 1)"; ls -la /var/log/moodle-cron.log; cat /etc/cron.d/moodle-cron
    tail -n 25 /var/log/moodle-cron.log; ps -eo pid,ppid,etime,args | grep -v -E "ps -eo|grep"' 2>&1 | sed 's/^/    cron: /'
  docker logs "$APP" 2>&1 | grep -n -E "DONE!|cron|Cron" | tail -n 8 | sed 's/^/    cron: /'
fi
assert_eq "and no cron run failed" "0" "$(docker exec "$APP" sh -c 'grep -c "Moodle Cron Failed" /var/log/moodle-cron.log')"
BEFORE_RESTART="$(docker logs "$APP" 2>&1 | wc -l)"
docker restart -t 30 "$APP" >/dev/null
if wait_for_log "$APP" "Cron daemon started" 600 "$BEFORE_RESTART"; then
  RESTART_LOG="$(docker logs "$APP" 2>&1 | tail -n +"$((BEFORE_RESTART + 1))")"
  assert_not_contains "a restart doesn't upgrade again" "$RESTART_LOG" "UPGRADING Moodle"
  assert_get_root "and GET / still answers 200"
else
  fail "the site restarts"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf "${GREEN}All checks passed.${NC}\n"
else
  printf "${RED}Some checks failed.${NC}\n"
  docker logs "$APP" 2>&1 | grep -E 'UPGRAD|WARNING|held back|Kept|maintenance|error|Error' | tail -n 40 | sed 's/^/    log: /'
fi
exit "$FAILED"
