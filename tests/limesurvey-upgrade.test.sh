#!/bin/bash

# ============================================================================
# LimeSurvey upgrade test: a real LimeSurvey 6 site, upgraded in place
# ============================================================================
# Builds the image this repository shipped before LimeSurvey 7 (its Dockerfile
# at commit OLD_COMMIT, with FROM pointed at the upstream tag that shipped
# 6.16.1, and a second one on 6.17.18), installs a site with it on volumes
# made the way a cluster makes them (root's top folder, mode 755, lost+found,
# nothing copied in; the nested upload volume too) and a mariadb:11.8
# database, and gives the site data:
#   - a survey whose ranking question's column names collide with a numeric
#     question's (question ids 1 and 13), with two responses. Without
#     upstream's fix 6487164b the update to 7 drops the numeric answers;
#   - the demo survey, active, with two responses;
#   - Clouve's SuiteCRM plugin switched on, and a plugin an admin added,
#     switched on too;
#   - a survey theme an admin added, assigned to a survey;
#   - an uploaded file, a stray file in the web root, and the old image's
#     root-owned config.php and security.php and MyISAM tables.
# It keeps a copy of the three volumes and runs each case on a fresh copy,
# with the new images.
#
# The cases (6.16.1 unless said otherwise):
#   upgrade        The upgrade, slowed down past 105 s with the test-only
#                  pause: the health check is asked every second and never
#                  fails while the upgrade runs; the site ends on LimeSurvey
#                  7.10.0 with every piece of the data; the SuiteCRM plugin is
#                  on again and the added plugin is left off and named; the
#                  survey with several survey_enabled settings has one, and its
#                  link is on; config.php and security.php are kept and
#                  www-data's; tables stay MyISAM; the backup is kept, root's,
#                  with modes 700 and 600; no password is on a command line or
#                  in the log; both volumes' top folders keep their owner and
#                  mode; a restart doesn't upgrade again.
#   upgrade-6.17   The same from 6.17.18, at full speed, with the site in
#                  "soft" maintenance mode before: it is in it afterwards.
#   failure        updatedb fails (a table the update wants to create is
#                  already there): two attempts, then the site runs 6.16.1
#                  with its data, and clouve/upgrade-failed stops a retry. An
#                  image with another build tries again by itself. With the
#                  cause and the file gone, the next start upgrades.
#   kills          The container is killed once in every phase, at the test
#                  pauses. Each time the next start ends on the right version
#                  with the data. Where the upgrade had not reached the
#                  database, the tables are compared at the restore: none was
#                  dropped and made again, and their rows are the same.
#   kills-random   The container is killed at random moments, start after
#                  start on the same volumes (LS_KILL_ROUNDS, 14). The site
#                  ends on 7.10.0 and its whole database is what an upgrade
#                  without a kill gives. Then two kills in a row: the image
#                  gives up, 6.16.1 runs, and no table was touched.
#   bad-dump       A dump that is cut short is never loaded. When the
#                  database needs it, the start waits for repair: Apache
#                  doesn't start, the container stays up with the "needs
#                  attention" page, and the database stays as it was. When the
#                  upgrade had not reached the database, the old code goes
#                  back without the dump, a new backup is made and the upgrade
#                  runs.
#   no-space       Too little free space, as df reports it: nothing is
#                  changed, 6.16.1 keeps running, clouve/upgrade-skipped says
#                  why, and the next start with space upgrades.
#   full-volume    The code volume is a real small filesystem (a tmpfs with a
#                  size and an inode limit). Too few inodes before the upgrade;
#                  the inodes or the space run out while the new code is
#                  copied; the volume is full to the last byte when a failed
#                  database update has to be undone, with and without the
#                  upgrade's reserve file; it fills right after an update that
#                  succeeded. The database is never emptied or loaded without
#                  need (its tables' creation times and a checksum of their
#                  rows are compared), and the site ends on a working version.
#   stuck-state    A finished upgrade whose state file still says upgrade,
#                  data written since, then an image with LimeSurvey 7.10.1:
#                  nothing is put back and the data is kept.
#   stop           docker stop during the copy ends the container at once
#                  with status 0, and the attempt is not counted. During the
#                  database update it waits for the update, and the next start
#                  finishes the upgrade off.
#   untrusted-state  www-data moves clouve/ aside and plants a state file and
#                  a dump: the planted folder is moved aside and never read.
#                  With the site whole the start goes on. With the site
#                  between two versions it waits for repair.
#   runbook        The README's runbook, run as it is written there (the test
#                  takes the code blocks out of apps/limesurvey/README.md): a
#                  damaged dump is got past with a dump of one's own, once to
#                  upgrade again and once to stay on the old version; and
#                  go-back.sh puts the old version back after a finished
#                  upgrade.
#   refusals       Code newer than the image ends the container. A database
#                  newer than its code, the package's code on an older
#                  database, a DBUpdateIncomplete row, a missing security.php,
#                  tables without LimeSurvey's settings table and old code on
#                  an empty database each wait for repair. Nothing is changed.
#
# Every container, volume, network and image is named ls-up-t-* (LS_TEST_PREFIX
# changes that) and is removed at the end unless --keep is given.
#
# Usage: bash tests/limesurvey-upgrade.test.sh [--image limesurvey=REF] [--image limesurvey-mariadb=REF]
#                                             [--old-image 6.16.1=REF] [--old-image 6.17.18=REF]
#                                             [--snapshot 6.16.1=VOLUME] [--snapshot 6.17.18=VOLUME] [--keep] [CASE...]
#   CASE        one of the names above (default: all)
#   --snapshot  keeps the seeded site of that version in the Docker volume VOLUME and uses it again when it is
#               there, so a second run doesn't install and fill the old site again. The volume is never removed.
# Exit status: 0 when every check passes, 1 when one fails, 2 when the test can't run.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${LS_TEST_PREFIX:-ls-up-t-}"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"

# The last commit whose apps/limesurvey/image is the LimeSurvey 6 image.
OLD_COMMIT=cb6cca2b0fb83f658ec732764a728706296ec7df
declare -A OLD_BASE=([6.16.1]=martialblog/limesurvey:6.16.1-251125-apache [6.17.18]=martialblog/limesurvey:6.17.18-261021-apache)
declare -A OLD_IMAGE=()
declare -A SNAPSHOT=()
OLD_DB_IMAGE=mariadb:11.8
NEW_VERSION=7.10.0
NEW_DB=718
SHAPER="${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}"

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --old-image)
      case "${2:-}" in
        6.16.1=?* | 6.17.18=?*) OLD_IMAGE[${2%%=*}]="${2#*=}" ;;
        *) echo "--old-image takes 6.16.1=REF or 6.17.18=REF" >&2; exit 2 ;;
      esac
      shift
      ;;
    --snapshot)
      case "${2:-}" in
        6.16.1=?* | 6.17.18=?*) SNAPSHOT[${2%%=*}]="${2#*=}" ;;
        *) echo "--snapshot takes 6.16.1=VOLUME or 6.17.18=VOLUME" >&2; exit 2 ;;
      esac
      shift
      ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
ls_parse_args ${ARGS[@]+"${ARGS[@]}"}
CASES=(${LS_ARGS[@]+"${LS_ARGS[@]}"})
[ "${#CASES[@]}" -gt 0 ] ||
  CASES=(upgrade upgrade-6.17 failure kills kills-random bad-dump no-space full-volume stuck-state stop untrusted-state runbook refusals)
for c in "${CASES[@]}"; do
  case "$c" in upgrade | upgrade-6.17 | failure | kills | kills-random | bad-dump | no-space | full-volume | stuck-state | stop | untrusted-state | runbook | refusals) ;; *)
    sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
  esac
done
wants() { local c; for c in "${CASES[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

ls_need_docker
WORK="$(mktemp -d)"
trap ls_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ls_remove_all

echo "LimeSurvey upgrade"
if ! ls_image limesurvey-mariadb || ! ls_image limesurvey; then
  fail "the new images build or are on this machine"
  echo; printf '%sLimeSurvey upgrade checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
NEW_IMAGE="${LS_IMAGE[limesurvey]}"
docker network create "${PREFIX}net" >/dev/null

# old_image VERSION: builds the LimeSurvey 6 image of this repository on the upstream tag that shipped VERSION.
old_image() {
  local v="$1" dir log
  [ -n "${OLD_IMAGE[$v]:-}" ] && { docker image inspect "${OLD_IMAGE[$v]}" >/dev/null 2>&1; return; }
  dir="$WORK/old-$v"
  mkdir -p "$dir"
  git -C "$REPO_DIR" archive "$OLD_COMMIT" apps/limesurvey/image 2>/dev/null | tar -x -C "$dir" || return 1
  sed -i "s#^FROM martialblog/limesurvey:6-apache\$#FROM ${OLD_BASE[$v]}#" "$dir/apps/limesurvey/image/Dockerfile"
  grep -qx "FROM ${OLD_BASE[$v]}" "$dir/apps/limesurvey/image/Dockerfile" || return 1
  OLD_IMAGE[$v]="${PREFIX}limesurvey-old:$v"
  if log="$(docker build -t "${OLD_IMAGE[$v]}" "$dir/apps/limesurvey/image" 2>&1)"; then
    LS_BUILT+=("${OLD_IMAGE[$v]}")
  else
    printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
    return 1
  fi
}

# vol_run VOLUME CMD: a shell command in a small container with VOLUME at /v, as root, with no network.
vol_run() { docker run --rm --network none -v "$1:/v" "$SHAPER" sh -c "$2" 2>&1; }
# top_folder VOLUME: "<uid>:<gid> <mode>" of a volume's top folder.
top_folder() { vol_run "$1" 'stat -c "%u:%g %a" /v'; }

# rpc CONTAINER METHOD JSON_PARAMS: a RemoteControl call on the old site, signed in as the admin.
rpc() { docker exec -e "LS_USER=$LS_ADMIN_USER" -e "LS_PASS=$LS_ADMIN_PW" "$1" php /tmp/clv-seed/rpc.php "$2" "$3" 2>&1; }

# seed_site VERSION: installs a LimeSurvey VERSION site with the old image, gives it data, and saves the three
# volumes as ${PREFIX}snap-VERSION. Sets SEED_OK.
# snap_volume VERSION: the volume that holds the saved site of that version.
snap_volume() { printf '%s' "${SNAPSHOT[$1]:-${PREFIX}snap-$1}"; }

seed_site() {
  local v="$1" db="${PREFIX}seed-db" app="${PREFIX}seed-app" i sgq out pid vars
  SEED_OK=false
  # A site that an earlier run saved with --snapshot.
  if [ -n "${SNAPSHOT[$v]:-}" ] && vars="$(docker run --rm --network none -v "${SNAPSHOT[$v]}:/snap:ro" "$SHAPER" \
    sh -c 'test -s /snap/html.tar && test -s /snap/db.tar && cat /snap/vars.sh' 2>/dev/null)" && [ -n "$vars" ]; then
    eval "$vars"
    SEED_OK=true
    pass "a LimeSurvey $v site with data is taken from the volume ${SNAPSHOT[$v]} (database version $OLD_DB_VERSION, $OLD_TABLES tables)"
    return
  fi
  old_image "$v" || { fail "the LimeSurvey $v image builds from commit ${OLD_COMMIT:0:7}"; return; }
  ls_new_disk "${PREFIX}seed-db-data" "${PREFIX}seed-html" "${PREFIX}seed-upload"
  ls_start_db "$db" "${PREFIX}seed-db-data" "$OLD_DB_IMAGE"
  ls_start_app "$app" "$db" "${PREFIX}seed-html" "${PREFIX}seed-upload" "${OLD_IMAGE[$v]}" \
    -e ENABLE_SUITECRM_INTEGRATION=true -e SUITECRM_URL=http://suitecrm.invalid -e SUITECRM_ADMIN_USER=crm_admin \
    -e "SUITECRM_ADMIN_PASSWORD=$CRM_PW" -e "SUITECRM_DB_PASSWORD=$CRM_DB_PW"
  for ((i = 0; i < 180; i++)); do
    [ "$(ls_http "$app" /)" = 200 ] &&
      [ "$(ls_sql "$db" "SELECT active FROM lime_plugins WHERE name='SuiteCRMIntegration'")" = 1 ] && break
    sleep 2
  done
  if [ "$(ls_code_version "$app" | cut -d' ' -f1)" != "$v" ] || [ "$(ls_http "$app" /)" != 200 ]; then
    fail "the LimeSurvey $v site installs with the old image"
    docker logs --tail 15 "$app" 2>&1 | sed 's/^/       | /'
    return
  fi
  # The seed files: a RemoteControl client, a console command that registers a theme, and the two surveys.
  docker exec "$app" mkdir -p /tmp/clv-seed/cmd /tmp/clv-seed/imp
  docker exec -i "$app" sh -c 'cat > /tmp/clv-seed/rpc.php' <<'PHP'
<?php
// php rpc.php <method> '<json array of params>': "@KEY" becomes a session key of LS_USER / LS_PASS.
$url = 'http://127.0.0.1:8080/index.php/admin/remotecontrol';
function call($url, $method, $params) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS => json_encode(['method' => $method, 'params' => $params, 'id' => 1])]);
    $out = curl_exec($ch);
    $j = json_decode((string) $out, true);
    if ($j === null) { fwrite(STDERR, "no JSON reply (HTTP " . curl_getinfo($ch, CURLINFO_HTTP_CODE) . ")\n"); exit(3); }
    return $j['result'] ?? $j;
}
$params = json_decode($argv[2] ?? '[]', true);
$key = call($url, 'get_session_key', [getenv('LS_USER'), getenv('LS_PASS')]);
if (!is_string($key)) { fwrite(STDERR, "sign-in failed\n"); exit(5); }
foreach ($params as $i => $p) { if ($p === '@KEY') { $params[$i] = $key; } }
echo json_encode(call($url, $argv[1], $params)), "\n";
call($url, 'release_session_key', [$key]);
PHP
  docker exec -i "$app" sh -c 'cat > /tmp/clv-seed/cmd/ClvseedCommand.php' <<'PHP'
<?php
class ClvseedCommand extends CConsoleCommand
{
    public function actionTheme($name)
    {
        foreach (['sanitize', 'common', 'database', 'replacements', 'surveytranslator'] as $h) {
            Yii::app()->loadHelper($h);
        }
        return TemplateManifest::importManifest($name) ? 0 : 1;
    }
}
PHP
  # The ranking question is question 1 and the numeric one question 13, so this survey is imported first.
  {
    printf 'id\trelated_id\tclass\ttype/scale\tname\trelevance\ttext\thelp\tlanguage\tvalidation\tmandatory\tother\tdefault\tsame_default\n'
    printf '\t\tS\t\tsid\t\t777001\t\t\t\t\t\t\t\n\t\tS\t\tlanguage\t\ten\t\t\t\t\t\t\t\n\t\tS\t\tformat\t\tA\t\t\t\t\t\t\t\n'
    printf '\t\tSL\t\tsurveyls_title\t\tRanking collision test\t\ten\t\t\t\t\t\n'
    printf '1\t\tG\t1\tG1\t1\t\t\ten\t\t\t\t\t\n'
    printf '1\t\tQ\tR\trank\t1\tRank these\t\ten\t\tN\tN\t\t0\n'
    printf '1\t\tA\t0\tA1\t\tFirst item\t\ten\t\t\t\t\t\n1\t\tA\t0\tA2\t\tSecond item\t\ten\t\t\t\t\t\n'
    for i in 2 3 4 5 6 7 8 9 10 11 12; do printf '%s\t\tQ\tS\ttxt%s\t1\tText %s\t\ten\t\tN\tN\t\t0\n' "$i" "$i" "$i"; done
    printf '13\t\tQ\tN\tnum13\t1\tA number\t\ten\t\tN\tN\t\t0\n'
  } | docker exec -i "$app" sh -c 'cat > /tmp/clv-seed/imp/rank.txt'
  docker exec "$app" sh -c 'cp /clouve/limesurvey/installer/demo_data.lss /tmp/clv-seed/imp/demo.lss &&
    chown -R www-data:www-data /tmp/clv-seed /tmp/suitecrm_integration.log 2>/dev/null; true'
  # As www-data, so the old site's caches stay usable.
  out="$(docker exec -u www-data "$app" sh -c 'cd /var/www/html &&
    php application/commands/console.php importsurvey /tmp/clv-seed/imp/rank.txt:en &&
    php application/commands/console.php importsurvey /tmp/clv-seed/imp/demo.lss:en' 2>&1)"
  if [ "$(tr -d ' \n' <<< "$out")" != 777001123456 ]; then
    fail "the two surveys import into the $v site (got: $(head -c 200 <<< "$out"))"; return
  fi
  ls_sql "$db" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('RPCInterface', 'json')
    ON DUPLICATE KEY UPDATE stg_value = 'json'" >/dev/null
  rpc "$app" activate_survey '["@KEY", 777001]' >/dev/null
  rpc "$app" activate_survey '["@KEY", 123456]' >/dev/null
  rpc "$app" add_response '["@KEY", 777001, {"777001X1X11":"A2","777001X1X12":"A1","777001X1X13":"42.5","777001X1X2":"first answer"}]' >/dev/null
  rpc "$app" add_response '["@KEY", 777001, {"777001X1X11":"A1","777001X1X12":"A2","777001X1X13":"7","777001X1X2":"second answer"}]' >/dev/null
  sgq="$(ls_sql "$db" "SELECT CONCAT(sid, 'X', gid, 'X', qid) FROM lime_questions WHERE sid = 123456 AND title = 'firstName' AND parent_qid = 0")"
  DEMO_QID="${sgq##*X}"
  rpc "$app" add_response "[\"@KEY\", 123456, {\"$sgq\":\"Ada\"}]" >/dev/null
  rpc "$app" add_response "[\"@KEY\", 123456, {\"$sgq\":\"Grace\"}]" >/dev/null
  # The old plugin leaves the demo survey with more than one survey_enabled setting, the first of which says off,
  # so the survey's link to SuiteCRM reads as off. If this old image didn't, the rows are made here.
  pid="$(ls_sql "$db" "SELECT id FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  enabled_rows() { ls_sql "$db" "SELECT COUNT(*) FROM lime_plugin_settings WHERE plugin_id = $pid AND model = 'Survey' AND model_id = 123456 AND \`key\` = 'survey_enabled'"; }
  if [ "$(enabled_rows)" -lt 2 ]; then
    ls_sql "$db" "DELETE FROM lime_plugin_settings WHERE plugin_id = $pid AND model = 'Survey' AND model_id = 123456 AND \`key\` = 'survey_enabled';
      INSERT INTO lime_plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`) VALUES
      ($pid, 'Survey', 123456, 'survey_enabled', '\"0\"'), ($pid, 'Survey', 123456, 'survey_enabled', '1'),
      ($pid, 'Survey', 123456, 'survey_enabled', '1')" >/dev/null
  fi
  ENABLED_ROWS="$(enabled_rows)"
  # A plugin an admin added by hand, switched on, and a survey theme an admin added.
  docker exec -u www-data "$app" sh -c 'mkdir -p /var/www/html/plugins/ClvTestPlugin /var/www/html/upload/surveys/123456/files &&
    cd /var/www/html/plugins/ClvTestPlugin &&
    printf "%s\n" "<?php" "class ClvTestPlugin extends PluginBase" "{" "    protected \$storage = \"DbStorage\";" \
      "    static protected \$name = \"ClvTestPlugin\";" "    static protected \$description = \"A plugin an admin added\";" \
      "    public function init() {}" "}" > ClvTestPlugin.php &&
    printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<config><metadata><name>ClvTestPlugin</name><type>plugin</type><version>1.0.0</version><author>test</author><license>MIT</license><description>test</description></metadata><compatibility><version>6.0</version><version>7.0</version></compatibility><updaters disabled=\"disabled\"></updaters></config>" > config.xml &&
    echo "an uploaded file" > /var/www/html/upload/surveys/123456/files/answer.txt &&
    echo "a stray file" > /var/www/html/clv-stray.txt &&
    cp -a /var/www/html/themes/survey/vanilla /var/www/html/upload/themes/survey/clv_test_theme &&
    sed -i "s#<name>vanilla</name>#<name>clv_test_theme</name>#" /var/www/html/upload/themes/survey/clv_test_theme/config.xml &&
    cd /var/www/html && YII_CONSOLE_COMMANDS=/tmp/clv-seed/cmd php application/commands/console.php clvseed theme --name=clv_test_theme' >/dev/null 2>&1
  ls_sql "$db" "INSERT INTO lime_plugins (name, active, version, load_error, plugin_type) VALUES ('ClvTestPlugin', 1, '1.0.0', 0, 'user');
    UPDATE lime_surveys SET template = 'clv_test_theme' WHERE sid = 123456" >/dev/null
  # What the site holds before the upgrade.
  RANK_BEFORE="$(ls_sql "$db" "SELECT id, \`777001X1X11\`, \`777001X1X12\`, \`777001X1X13\`, \`777001X1X2\` FROM lime_survey_777001 ORDER BY id")"
  DEMO_BEFORE="$(ls_sql "$db" "SELECT id, \`$sgq\` FROM lime_survey_123456 ORDER BY id")"
  OLD_DB_VERSION="$(ls_db_version "$db")"
  ADMIN_HASH="$(ls_sql "$db" "SELECT password FROM lime_users WHERE users_name = '$LS_ADMIN_USER'")"
  SECURITY_SUM="$(docker exec "$app" sha256sum /var/www/html/application/config/security.php | cut -d' ' -f1)"
  OLD_TABLES="$(ls_sql "$db" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey'")"
  TOPS_BEFORE="$(top_folder "${PREFIX}seed-html") $(top_folder "${PREFIX}seed-upload")"
  if [ "$(grep -c . <<< "$RANK_BEFORE")" != 2 ] || [ "$(grep -c . <<< "$DEMO_BEFORE")" != 2 ] ||
    [ "$(ls_sql "$db" "SELECT COUNT(*) FROM lime_templates WHERE name = 'clv_test_theme'")" != 1 ]; then
    fail "the $v site has its two surveys' responses and the added theme"
    return
  fi
  docker exec "$app" sh -c 'rm -rf /tmp/clv-seed' >/dev/null 2>&1
  docker stop -t 20 "$app" >/dev/null 2>&1
  docker stop -t 60 "$db" >/dev/null 2>&1
  docker rm -f -v "$app" "$db" >/dev/null 2>&1
  docker volume create "$(snap_volume "$v")" >/dev/null
  # The values the checks compare with, for a later run that takes the site from the volume.
  declare -p RANK_BEFORE DEMO_BEFORE DEMO_QID OLD_DB_VERSION ADMIN_HASH SECURITY_SUM OLD_TABLES TOPS_BEFORE ENABLED_ROWS |
    sed 's/^declare --/declare -g --/' > "$WORK/vars-$v.sh"
  if docker run --rm --network none -v "$(snap_volume "$v"):/snap" -v "${PREFIX}seed-html:/html:ro" \
    -v "${PREFIX}seed-upload:/upload:ro" -v "${PREFIX}seed-db-data:/db:ro" -v "$WORK/vars-$v.sh:/vars.sh:ro" "$SHAPER" sh -c \
    'tar -C /html -cpf /snap/html.tar . && tar -C /upload -cpf /snap/upload.tar . && tar -C /db -cpf /snap/db.tar . && cp /vars.sh /snap/vars.sh' \
    >/dev/null 2>&1; then
    SEED_OK=true
    pass "a LimeSurvey $v site with data is saved (database version $OLD_DB_VERSION, $OLD_TABLES tables)"
  else
    fail "the $v site's volumes could be saved"
  fi
  docker volume rm -f "${PREFIX}seed-html" "${PREFIX}seed-upload" "${PREFIX}seed-db-data" >/dev/null 2>&1
}

# new_case NAME VERSION: fresh copies of the saved site's volumes as ${PREFIX}NAME-{html,upload,db-data}, and the new
# database image on the database's. Sets DB and APP, the case's container names.
new_case() {
  local n="$1" v="$2"
  DB="${PREFIX}$n-db"
  APP="${PREFIX}$n-app"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}$n-html" "${PREFIX}$n-upload" "${PREFIX}$n-db-data" >/dev/null 2>&1
  docker volume create "${PREFIX}$n-html" >/dev/null
  docker volume create "${PREFIX}$n-upload" >/dev/null
  docker volume create "${PREFIX}$n-db-data" >/dev/null
  docker run --rm --network none -v "$(snap_volume "$v"):/snap:ro" -v "${PREFIX}$n-html:/html" \
    -v "${PREFIX}$n-upload:/upload" -v "${PREFIX}$n-db-data:/db" "$SHAPER" sh -c \
    'tar -C /html -xpf /snap/html.tar && tar -C /upload -xpf /snap/upload.tar && tar -C /db -xpf /snap/db.tar' >/dev/null 2>&1
  ls_start_db "$DB" "${PREFIX}$n-db-data"
  ls_wait_db "$DB" 120
}

# start_new NAME [docker run options...]: the new image (or START_IMAGE, when a case sets it) on the case's volumes.
START_IMAGE=""
start_new() {
  local n="$1"
  shift
  docker rm -f -v "$APP" >/dev/null 2>&1
  ls_start_app "$APP" "$DB" "${PREFIX}$n-html" "${PREFIX}$n-upload" "${START_IMAGE:-$NEW_IMAGE}" \
    -e ENABLE_SUITECRM_INTEGRATION=true -e SUITECRM_URL=http://suitecrm.invalid -e SUITECRM_ADMIN_USER=crm_admin \
    -e "SUITECRM_ADMIN_PASSWORD=$CRM_PW" -e "SUITECRM_DB_PASSWORD=$CRM_DB_PW" -e "CLOUVE_OPS_PASSWORD=$LS_OPS_PW" "$@"
}

# other_image NAME COMMAND: an image made from the new one by running COMMAND in it as root. It stands in for an
# image that Clouve builds later. Prints its tag. The caller adds the tag to LS_BUILT, so the image goes at the end:
# this function runs inside $( ), where a change to the list would be lost.
other_image() {
  local tag="${PREFIX}limesurvey-$1:test" log
  if log="$(printf 'FROM %s\nUSER root\nRUN %s\n' "$NEW_IMAGE" "$2" | docker build -t "$tag" - 2>&1)"; then
    echo "$tag"
  else
    printf '%s\n' "$log" | tail -n 10 | sed 's/^/       /' >&2
    return 1
  fi
}

# small_case NAME VERSION: like new_case, but the code volume is a small filesystem of its own: a tmpfs of 1500 MB
# with 120,000 inodes, kept mounted by the container HOLD, which the case also uses to fill it. A full disk there
# is a real one: writes fail with "No space left on device".
small_case() {
  local n="$1" v="$2"
  DB="${PREFIX}$n-db"
  APP="${PREFIX}$n-app"
  HOLD="${PREFIX}$n-hold"
  docker rm -f -v "$APP" "$DB" "$HOLD" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}$n-html" "${PREFIX}$n-upload" "${PREFIX}$n-db-data" >/dev/null 2>&1
  docker volume create --driver local --opt type=tmpfs --opt device=tmpfs \
    --opt o=size=1500m,nr_inodes=120000,uid=33,gid=33,mode=0755 "${PREFIX}$n-html" >/dev/null
  docker volume create "${PREFIX}$n-upload" >/dev/null
  docker volume create "${PREFIX}$n-db-data" >/dev/null
  docker run -d --name "$HOLD" --network none --memory "$LS_MEMORY" -v "$(snap_volume "$v"):/snap:ro" \
    -v "${PREFIX}$n-html:/html" -v "${PREFIX}$n-upload:/upload" -v "${PREFIX}$n-db-data:/db" "$SHAPER" \
    sleep 86400 >/dev/null
  docker exec "$HOLD" sh -c \
    'tar -C /html -xpf /snap/html.tar && tar -C /upload -xpf /snap/upload.tar && tar -C /db -xpf /snap/db.tar' >/dev/null 2>&1
  ls_start_db "$DB" "${PREFIX}$n-db-data"
  ls_wait_db "$DB" 120
}
# hold CMD: a shell command in the holder, as root, with the code volume at /html.
hold() { docker exec "$HOLD" sh -c "$1" 2>&1; }
# free_inodes, free_mb: what the small code volume has left.
free_inodes() { hold "df -Pi /html | awk 'NR == 2 {print \$4}'"; }
free_mb() { hold "df -Pm /html | awk 'NR == 2 {print \$4}'"; }
# eat_inodes LEAVE: makes empty files until LEAVE inodes are free.
eat_inodes() {
  local free
  free="$(free_inodes)"
  [ "$free" -gt "$1" ] || return 0
  hold "mkdir -p /html/.clv-test-inodes && cd /html/.clv-test-inodes && seq 1 $((free - $1)) | sed \"s/^/\$(date +%s)-/\" | xargs touch"
}
# eat_space LEAVE_MB: a file of zeros that leaves LEAVE_MB free. 0 fills the volume to the last byte.
eat_space() {
  if [ "$1" = 0 ]; then
    hold 'cat /dev/zero >> /html/.clv-test-filler 2>/dev/null; true' >/dev/null
  else
    hold "dd if=/dev/zero of=/html/.clv-test-filler bs=1M count=$(( $(free_mb) - $1 )) conv=notrunc oflag=append 2>/dev/null; true" >/dev/null
  fi
}
# give_back: removes what eat_inodes and eat_space made.
give_back() { hold 'rm -rf /html/.clv-test-inodes /html/.clv-test-filler' >/dev/null; }
# end_pause: ends the test pause the upgrade is in, so it goes on at once.
end_pause() {
  # shellcheck disable=SC2016  # the script is for the sh in the container
  docker exec "$APP" sh -c 'for p in /proc/[0-9]*; do
    [ "$(cat "$p/comm" 2>/dev/null)" = sleep ] && kill "${p#/proc/}" 2>/dev/null; done; true'
}
# pause_at NAME STEP [docker run options...]: starts the new image with a pause at STEP and waits for it.
pause_at() {
  local n="$1" step="$2"
  shift 2
  start_new "$n" -e "CLV_LS_TEST_PAUSE=$step:900" "$@"
  if ! ls_wait_log "$APP" "test pause at $step" 600; then
    fail "the upgrade reaches the pause at $step"
    docker logs --tail 15 "$APP" 2>&1 | sed 's/^/       | /'
    return 1
  fi
}
# clouve_file NAME PATH: a file under clouve/ on the case's code volume, read as root. Nothing when it isn't there.
clouve_file() { vol_run "${PREFIX}$1-html" "cat /v/clouve/$2 2>/dev/null"; }
# clouve_count NAME GLOB: how many entries under clouve/ match.
clouve_count() { vol_run "${PREFIX}$1-html" "ls -d /v/clouve/$2 2>/dev/null | wc -l"; }
# readme_block HEADING [N]: the Nth (first) bash block under that heading of the app's README.md.
readme_block() {
  awk -v h="$1" -v want="${2:-1}" '$0 == h {f = 1; next} f && /^#/ {exit} f && /^```bash$/ {n++; c = (n == want); next}
    c && /^```$/ {exit} c {print}' "$LS_APP_DIR/README.md"
}
# site_sum DB: the tables a start doesn't write to, counted and summed.
site_sum() { ls_db_sum "$1" "$LS_VOLATILE_TABLES"; }

# rank_after DB: the ranking survey's answers in LimeSurvey 7's table, in the order of RANK_BEFORE: id, the two
# ranks, question 13, question 2. LimeSurvey 7 names a column after its question (Q13). This survey's two rank columns
# share their old names with questions 11 and 12, and keep those names' new form (Q11, Q12).
rank_after() {
  ls_sql "$1" "SELECT id, Q11, Q12, Q13, Q2 FROM lime_responses_777001 ORDER BY id"
}

# check_new_site LABEL: the site of the current case is LimeSurvey 7.10.0 with the data made before the upgrade.
check_new_site() {
  local label="$1" rank
  assert_eq "$label: the code is LimeSurvey $NEW_VERSION" "$NEW_VERSION $NEW_DB" "$(ls_code_version "$APP")"
  assert_eq "$label: the database is at version $NEW_DB" "$NEW_DB" "$(ls_db_version "$DB")"
  assert_eq "$label: no DBUpdateIncomplete row" "0" \
    "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_settings_global WHERE stg_name = 'DBUpdateIncomplete'")"
  rank="$(rank_after "$DB")"
  assert_eq "$label: the ranking survey keeps its ranks, its numbers (42.5 and 7) and its texts" "$RANK_BEFORE" "$rank"
  assert_eq "$label: the demo survey keeps its two responses" "$DEMO_BEFORE" \
    "$(ls_sql "$DB" "SELECT id, Q$DEMO_QID FROM lime_responses_123456 ORDER BY id")"
  assert_eq "$label: the admin's password is the one from before" "$ADMIN_HASH" \
    "$(ls_sql "$DB" "SELECT password FROM lime_users WHERE users_name = '$LS_ADMIN_USER'")"
}

# check_old_site LABEL VERSION: the site of the current case runs LimeSurvey VERSION with the data it had.
check_old_site() {
  local label="$1" v="$2"
  assert_eq "$label: Apache serves the site" "apache2 200" "$(ls_pid1 "$APP") $(ls_http "$APP" /)"
  assert_eq "$label: the code is LimeSurvey $v" "$v $OLD_DB_VERSION" "$(ls_code_version "$APP")"
  assert_eq "$label: the database is at version $OLD_DB_VERSION" "$OLD_DB_VERSION" "$(ls_db_version "$DB")"
  assert_eq "$label: no DBUpdateIncomplete row" "0" \
    "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_settings_global WHERE stg_name = 'DBUpdateIncomplete'")"
  assert_eq "$label: the ranking survey's answers are as before" "$RANK_BEFORE" \
    "$(ls_sql "$DB" "SELECT id, \`777001X1X11\`, \`777001X1X12\`, \`777001X1X13\`, \`777001X1X2\` FROM lime_survey_777001 ORDER BY id")"
  assert_eq "$label: the SuiteCRM plugin is still on" "1" \
    "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  assert_eq "$label: the admin sign-in page of LimeSurvey $v answers" "200" \
    "$(ls_http "$APP" /index.php/admin/authentication/sa/login)"
}

# upgraded_sum DB: the tables of an upgraded site and a checksum of their rows, without the tables a start writes to
# and the ones in which LimeSurvey's update stores the time it ran.
upgraded_sum() { ls_db_sum "$1" "$UPGRADED_SKIP"; }
UPGRADED_SKIP="$LS_VOLATILE_TABLES"

# state_of NAME: the phase in the case's upgrade state file, read from the volume.
state_of() { vol_run "${PREFIX}$1-html" "sed -n 's/^phase=//p' /v/clouve/upgrade-*/state 2>/dev/null | head -n 1"; }

CRM_PW="crm-pw-71c0d2e9"
CRM_DB_PW="crmdb-pw-0b6e3a55"
LS_EXTRA_SECRETS=("$CRM_PW" "$CRM_DB_PW")

echo
echo "The LimeSurvey 6.16.1 site"
seed_site 6.16.1
if [ "$SEED_OK" != true ]; then
  echo; printf '%sLimeSurvey upgrade checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
echo "       the ranking survey before the upgrade (id, rank 1, rank 2, question 13, question 2):"
sed 's/^/         /' <<< "$RANK_BEFORE"

# --- 1. the upgrade, slowed down ------------------------------------------------------------------------------------
if wants upgrade; then
  echo
  echo "The upgrade from 6.16.1, slowed down past 105 s"
  new_case up 6.16.1
  start_new up -e CLV_LS_TEST_PAUSE=upgrade-copy:110
  started=$SECONDS
  ls_watch_ps "$APP" "$WORK/ps-upgrade" &
  # The health check, once a second, with what PID 1 is at that moment.
  ( while [ ! -e "$WORK/health.stop" ]; do
      printf '%s %s %s\n' "$(date +%s)" "$(ls_pid1 "$APP")" "$(ls_http "$APP" / -m 5)" >> "$WORK/health"
      sleep 1
    done ) &
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  took=$((SECONDS - started))
  sleep 3
  touch "$WORK/health.stop" "$WORK/ps-upgrade.stop"; wait
  if [ "$rc" -ne 0 ]; then
    fail "the upgraded site comes up"
    docker logs --tail 30 "$APP" 2>&1 | sed 's/^/       | /'
  else
    pass "the upgraded site comes up ($took s from the container's start, 110 s of it the pause)"
    if [ "$took" -gt 105 ]; then pass "the upgrade outlasted the health check's 105 s"; else fail "the upgrade outlasted the health check's 105 s"; fi
    # The moment the stand-in handed the port to Apache, from the log's own timestamps.
    handover="$(docker logs -t "$APP" 2>&1 | sed -n 's/^\([^ ]*\) \[limesurvey\] the site is ready: the stand-in hands.*/\1/p' | head -n 1)"
    handover="$(date -d "$handover" +%s 2>/dev/null || echo 0)"
    # Answers count from the first 200 on: before it the container was still starting, which the probe's 30 s
    # initial delay covers.
    first_ok="$(grep -n -m1 ' 200$' "$WORK/health" | cut -d: -f1)"
    tail -n "+${first_ok:-1}" "$WORK/health" > "$WORK/health.counted"
    during="$(awk -v t="$handover" '$1 < t' "$WORK/health.counted" | grep -c .)"
    during_bad="$(awk -v t="$handover" '$1 < t && $3 != 200' "$WORK/health.counted" | grep -c .)"
    after="$(awk -v t="$handover" '$1 >= t' "$WORK/health.counted" | grep -c .)"
    after_bad="$(awk -v t="$handover" '$1 >= t && $3 != 200' "$WORK/health.counted" | grep -c .)"
    if [ "${first_ok:-99}" -le 5 ]; then pass "the stand-in answered within 5 s of the container's start"; else
      fail "the stand-in answered within 5 s of the container's start (answer ${first_ok:-none} was the first 200)"; fi
    assert_eq "the health check never failed while the upgrade ran ($during answers, one a second)" "0" "$during_bad"
    if [ "$during" -ge 100 ]; then pass "and it was asked for more than 100 s before the hand-over"; else
      fail "and it was asked for more than 100 s before the hand-over ($during answers)"; fi
    if [ "$after_bad" -le 2 ]; then pass "the hand-over to Apache cost at most 2 answers ($after_bad failed)"; else
      fail "the hand-over to Apache cost at most 2 answers ($after_bad failed)"; fi
    echo "       health check: $during answers before the hand-over, $during_bad not 200; $after answers from the hand-over on, $after_bad not 200"
    awk '$3 != 200 {print "         not 200: answer " NR " (PID 1 " $2 ", status " $3 ")"}' "$WORK/health"
    check_new_site "after the upgrade"
    echo "       the ranking survey after the upgrade (id, rank 1, rank 2, question 13, question 2):"
    rank_after "$DB" | sed 's/^/         /'
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "no command line held a password during the upgrade" "0" "$(ls_secrets_in "$(cat "$WORK/ps-upgrade")")"
    echo "       command lines seen during the upgrade (php and the database client):"
    grep -E '^(php|mariadb|gzip|bash /clouve)' "$WORK/ps-upgrade" | sort -u | head -n 10 | cut -c1-150 | sed 's/^/         /'
    if grep -q 'console.php updatedb' "$WORK/ps-upgrade" || grep -q 'mariadb-dump' "$WORK/ps-upgrade"; then
      pass "the process list was sampled while the dump or updatedb ran"
    else
      fail "the process list was sampled while the dump or updatedb ran"
    fi
    assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
    assert_eq "the start logged no warning" "" "$(grep -F -e '[limesurvey] WARNING' -e 'could not' <<< "$log" | cut -c1-200)"
    for phase in backup upgrade "done"; do
      assert_contains "the log has a [clouve-upgrade] line for $phase" "$log" "[clouve-upgrade] $phase: "
    done
    assert_eq "the SuiteCRM plugin is on again" "1" "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
    assert_eq "the demo survey had $ENABLED_ROWS survey_enabled settings and has one now, which says on" '"1"' \
      "$(ls_sql "$DB" "SELECT value FROM lime_plugin_settings WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = 123456")"
    assert_contains "and the log says which survey and what was kept" "$log" \
      "[suitecrm-plugin] survey 123456 had $ENABLED_ROWS survey_enabled settings. One is kept, and the survey's link to SuiteCRM is on"
    assert_eq "its SuiteCRM passwords are no longer stored in clear text" "0" \
      "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_plugin_settings WHERE \`key\` IN ('suitecrm_admin_password', 'suitecrm_db_password') AND (value LIKE '%$CRM_PW%' OR value LIKE '%$CRM_DB_PW%')")"
    assert_eq "and its debug mode, which the old image switched on, is off" '"0"' \
      "$(ls_sql "$DB" "SELECT value FROM lime_plugin_settings WHERE \`key\` = 'debug_mode' AND model IS NULL")"
    assert_eq "the plugin the admin added is left off" "0" "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'ClvTestPlugin'")"
    assert_contains "and the log names it" "$log" "left off: ClvTestPlugin"
    assert_eq "its folder is kept" "1" "$(docker exec "$APP" sh -c 'ls /var/www/html/plugins/ClvTestPlugin/ClvTestPlugin.php | wc -l')"
    assert_eq "the SuiteCRM plugin's code is the package's (it lists LimeSurvey 7)" "1" \
      "$(docker exec "$APP" grep -c '<version>7.0</version>' /var/www/html/plugins/SuiteCRMIntegration/config.xml)"
    assert_eq "the added theme is still registered and assigned" "1 clv_test_theme" \
      "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_templates WHERE name = 'clv_test_theme'") $(ls_sql "$DB" "SELECT template FROM lime_surveys WHERE sid = 123456")"
    assert_eq "the theme's files, the uploaded file and the stray file are there" "3" \
      "$(docker exec "$APP" sh -c 'ls /var/www/html/upload/themes/survey/clv_test_theme/config.xml /var/www/html/upload/surveys/123456/files/answer.txt /var/www/html/clv-stray.txt 2>/dev/null | wc -l')"
    assert_eq "security.php is the one from before (the encryption keys)" "$SECURITY_SUM" \
      "$(docker exec "$APP" sha256sum /var/www/html/application/config/security.php | cut -d' ' -f1)"
    assert_eq "config.php and security.php are www-data's now, mode 600" "www-data:www-data 600 www-data:www-data 600" \
      "$(docker exec "$APP" sh -c 'cd /var/www/html/application/config && echo "$(stat -c "%U:%G %a" config.php) $(stat -c "%U:%G %a" security.php)"')"
    assert_eq "the tables that were MyISAM are still MyISAM" "MyISAM" \
      "$(ls_sql "$DB" "SELECT engine FROM information_schema.tables WHERE table_schema = 'limesurvey' AND table_name = 'lime_surveys'")"
    assert_eq "maintenance mode is off" "off" "$(ls_sql "$DB" "SELECT stg_value FROM lime_settings_global WHERE stg_name = 'maintenancemode'")"
    assert_eq "the survey list answers and the admin sign-in page too" "200 200" \
      "$(ls_http "$APP" /) $(ls_http "$APP" /index.php/admin/authentication/sa/login -H 'Host: localhost')"
    assert_eq "the demo survey's page renders with the added theme" "200" "$(ls_http "$APP" /index.php/123456 -H 'Host: localhost')"
    backup="/var/www/html/clouve/upgrade-6.16.1-to-$NEW_VERSION"
    assert_eq "the backup folder is kept, mode 700, with the dump and the state file at 600" "700 600 600" \
      "$(docker exec "$APP" sh -c "echo \"\$(stat -c %a $backup) \$(stat -c %a $backup/db.sql.gz) \$(stat -c %a $backup/state)\"")"
    assert_eq "clouve/ is root's, mode 700, and so is everything the upgrade wrote there (the old code keeps its owners)" "root:root 700 0" \
      "$(docker exec "$APP" sh -c 'echo "$(stat -c "%U:%G %a" /var/www/html/clouve) $(find /var/www/html/clouve -path "/var/www/html/clouve/upgrade-*/code/*" -prune -o \( ! -user root -o -perm /077 \) -print | wc -l)"')"
    assert_eq "www-data can read neither the folder nor the dump" "no no" \
      "$(docker exec -u www-data "$APP" sh -c 'ls /var/www/html/clouve >/dev/null 2>&1 && echo yes || echo no; cat /var/www/html/clouve/upgrade-*/db.sql.gz >/dev/null 2>&1 && echo yes || echo no' | tr '\n' ' ' | sed 's/ $//')"
    assert_eq "the marker and the reserve of an upgrade under way are gone" "0" \
      "$(docker exec "$APP" sh -c "ls $backup/db-touched $backup/reserve 2>/dev/null | wc -l")"
    assert_eq "the old code is in it" "6.16.1" \
      "$(docker exec "$APP" sed -n "s/^\$config\['versionnumber'\] = '\([0-9.]*\)'.*/\1/p" "$backup/code/application/config/version.php")"
    assert_eq "its state says done" "done" "$(docker exec "$APP" sed -n 's/^phase=//p' "$backup/state")"
    assert_eq "the backup is denied over HTTP" "403" "$(ls_http "$APP" "/clouve/upgrade-6.16.1-to-$NEW_VERSION/db.sql.gz")"
    assert_eq "both volumes' top folders keep their owner and mode" "$TOPS_BEFORE" \
      "$(top_folder "${PREFIX}up-html") $(top_folder "${PREFIX}up-upload")"
    assert_eq "Apache is PID 1 and clouve-ops signs in" "apache2 clouve-ops" "$(ls_pid1 "$APP") $(ls_ssh_whoami "$APP" "$LS_OPS_PW")"
    # A restart must not upgrade again. docker restart keeps the pause variable, which then has nothing to pause.
    docker restart "$APP" >/dev/null
    rc=0; ls_wait_apache "$APP" 120 || rc=$?
    assert_eq "after a restart Apache answers" "0" "$rc"
    assert_eq "and the upgrade ran once" "1" "$(docker logs "$APP" 2>&1 | grep -c '\[clouve-upgrade\] done: ')"
    check_new_site "after the restart"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 3. updatedb fails ----------------------------------------------------------------------------------------------
if wants failure; then
  echo
  echo "updatedb fails"
  new_case fail 6.16.1
  # The update creates lime_responses_777001. With the table already there, that step fails.
  ls_sql "$DB" "CREATE TABLE lime_responses_777001 (id INT) ENGINE=MyISAM" >/dev/null
  start_new fail
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "the container comes up all the same" "0" "$rc"
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the upgrade was tried twice, and each failure has its FAILED line" "2" \
    "$(grep -c '\[clouve-upgrade\] FAILED limesurvey 6.16.1 -> 7.10.0: console.php updatedb ended with status 1' <<< "$log")"
  assert_eq "then it gave up" "1" "$(grep -c '\[clouve-upgrade\] FAILED limesurvey 6.16.1 -> 7.10.0: gave up after 2 attempts' <<< "$log")"
  assert_lacks "no answer is quoted in a FAILED line" "$(grep 'FAILED limesurvey' <<< "$log")" "first answer"
  assert_contains "the log says the old version keeps running" "$log" "LimeSurvey 6.16.1 keeps running"
  check_old_site "after the failed upgrade" 6.16.1
  assert_eq "clouve/upgrade-failed names this image's build" "1" \
    "$(docker exec "$APP" sh -c 'grep -cx "build=$(cat /clouve/limesurvey/image-build)" /var/www/html/clouve/upgrade-failed')"
  assert_eq "the state says failed" "failed" "$(state_of fail)"
  assert_eq "the old version's own start steps logged no warning (settings, the SuiteCRM plugin)" "" \
    "$(grep -F -e '[limesurvey] WARNING' -e 'could not' <<< "$log" | cut -c1-200)"
  assert_contains "the SuiteCRM plugin's settings were written on LimeSurvey 6.16.1 too" "$log" "[suitecrm-plugin] settings written: "
  assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
  start_new fail
  rc=0; ls_wait_apache "$APP" 300 || rc=$?
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the next start comes up" "0" "$rc"
  assert_contains "without trying again" "$log" "[clouve-upgrade] not upgrading: "
  assert_eq "no upgrade phase ran" "0" "$(grep -c '\[clouve-upgrade\] backup: ' <<< "$log")"
  check_old_site "after the second start" 6.16.1
  # An image with another build tries again by itself. The cause is still there, so it fails again, under its own name.
  other="$(other_image other 'sed -i "1s/\$/-other/" /clouve/limesurvey/image-build')"
  if [ -n "$other" ]; then
    LS_BUILT+=("$other")
    START_IMAGE="$other" start_new fail
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "an image with another build comes up" "0" "$rc"
    assert_eq "it tried the upgrade again, twice" "2" "$(grep -c '\[clouve-upgrade\] upgrade: limesurvey 6.16.1 -> 7.10.0, attempt' <<< "$log")"
    assert_eq "clouve/upgrade-failed now names that image's build" "1" \
      "$(docker exec "$APP" sh -c 'grep -cx "build=$(cat /clouve/limesurvey/image-build)" /var/www/html/clouve/upgrade-failed')"
    check_old_site "after the other build's attempts" 6.16.1
  else
    fail "an image with another build could be made from the new image"
  fi
  # With the cause gone and the file removed, the next start upgrades.
  ls_sql "$DB" "DROP TABLE lime_responses_777001" >/dev/null
  docker exec "$APP" rm -f /var/www/html/clouve/upgrade-failed
  start_new fail
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "with clouve/upgrade-failed removed, the next start comes up" "0" "$rc"
  check_new_site "after the retry"
  assert_eq "one backup folder is kept" "1" "$(docker exec "$APP" sh -c 'ls -d /var/www/html/clouve/upgrade-*/ | wc -l')"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 4. a kill in every phase ---------------------------------------------------------------------------------------
if wants kills; then
  # kill_at STEP: starts the upgrade with a pause at STEP, kills the container there, and starts a new one.
  # With "untouched", the start after the kill is paused at its restore, and the tables are compared there with
  # the ones from before the upgrade: the log line alone would not show a database that was emptied and loaded.
  kill_at() {
    local step="$1"
    KILL_SUM="$(ls_db_sum "$DB")"; KILL_MADE="$(ls_db_made "$DB")"
    start_new kill -e "CLV_LS_TEST_PAUSE=$step:900"
    if ! ls_wait_log "$APP" "test pause at $step" 600; then
      fail "the upgrade reaches the pause at $step"
      docker logs --tail 15 "$APP" 2>&1 | sed 's/^/       | /'
      return 1
    fi
    assert_eq "killed at $step: the health check answers at that moment" "200" "$(ls_http "$APP" /)"
    docker kill "$APP" >/dev/null 2>&1
    if [ "${2:-}" = untouched ]; then
      start_new kill -e CLV_LS_TEST_PAUSE=restore:900
      if ls_wait_log "$APP" "test pause at restore" 600; then
        assert_eq "killed at $step: at the restore, no table was dropped and made again" "$KILL_MADE" "$(ls_db_made "$DB")"
        assert_eq "killed at $step: and every table holds the rows it held before the upgrade" "$KILL_SUM" "$(ls_db_sum "$DB")"
        end_pause
      else
        fail "killed at $step: the next start reaches its restore"
      fi
    else
      start_new kill
    fi
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    assert_eq "killed at $step: the next start comes up" "0" "$rc"
    [ "$rc" -eq 0 ] || docker logs --tail 15 "$APP" 2>&1 | sed 's/^/       | /'
  }
  for step in backup upgrade-move upgrade-copy upgrade-updatedb; do
    echo
    echo "The container is killed at $step"
    new_case kill 6.16.1
    how=""
    case "$step" in upgrade-move | upgrade-copy) how=untouched ;; esac
    if kill_at "$step" "$how"; then
      log="$(docker logs "$APP" 2>&1)"
      case "$step" in
        backup) assert_contains "the partial backup was removed and the upgrade started again" "$log" "the backup was cut off" ;;
        upgrade-updatedb) assert_contains "the finished update was kept, with no restore" "$log" "the database update had finished" ;;
        *) assert_contains "the old version was put back first" "$log" "[clouve-upgrade] restore: LimeSurvey 6.16.1 is back"
          assert_contains "without touching the database, which the upgrade had not reached" "$log" "the database was not changed by the upgrade" ;;
      esac
      check_new_site "killed at $step"
      assert_eq "killed at $step: the SuiteCRM plugin is on again" "1" \
        "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
      assert_eq "killed at $step: the state says done" "done" "$(state_of kill)"
    fi
    docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  done
  echo
  echo "The container is killed during a restore"
  new_case kill 6.16.1
  ls_sql "$DB" "CREATE TABLE lime_responses_777001 (id INT) ENGINE=MyISAM" >/dev/null
  if kill_at restore; then
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the restore ran again" "$log" "[clouve-upgrade] restore: "
    check_old_site "killed during a restore" 6.16.1
    assert_eq "killed during a restore: the state says failed" "failed" "$(state_of kill)"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 5. a dump that is cut short ------------------------------------------------------------------------------------
if wants bad-dump; then
  cut_dump() { vol_run "${PREFIX}dump-html" 'f=$(ls /v/clouve/upgrade-*/db.sql.gz) && head -c 2000 "$f" > "$f.cut" && cat "$f.cut" > "$f" && rm "$f.cut"' >/dev/null; }
  echo
  echo "A dump that is cut short, when the database needs it"
  new_case dump 6.16.1
  # The database update fails halfway (a table it creates is already there), and the container is killed before the
  # way back: the database is half updated, and only the dump could put it right.
  ls_sql "$DB" "CREATE TABLE lime_responses_777001 (id INT) ENGINE=MyISAM" >/dev/null
  start_new dump -e CLV_LS_TEST_PAUSE=upgrade-updatedb:900
  if ls_wait_log "$APP" "test pause at upgrade-updatedb" 600; then
    docker kill "$APP" >/dev/null 2>&1
    cut_dump
    before="$(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey'") $(ls_db_version "$DB")"
    start_new dump
    rc=0; ls_wait_hold "$APP" 300 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "the start waits for repair" "0" "$rc"
    ls_assert_hold "a damaged dump" "$APP"
    ls_assert_note "a damaged dump" "$APP" repair
    assert_contains "the log says the backup is not whole" "$log" "is not the backup that was stamped complete"
    assert_lacks "no message says to remove the folder that holds the backup" "$(grep -F '[clouve-upgrade] FAILED' <<< "$log")" "remove"
    assert_eq "clouve-ops can sign in to repair it" "clouve-ops" "$(ls_ssh_whoami "$APP" "$LS_OPS_PW")"
    assert_eq "nothing was loaded over the database (its tables and version are as the kill left them)" "$before" \
      "$(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey'") $(ls_db_version "$DB")"
    assert_eq "the state is kept for the next look" "restore" "$(state_of dump)"
  else
    fail "the upgrade reaches the pause after updatedb"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  echo
  echo "A dump that is cut short, when the database was never touched"
  new_case dump 6.16.1
  start_new dump -e CLV_LS_TEST_PAUSE=upgrade-copy:900
  if ls_wait_log "$APP" "test pause at upgrade-copy" 600; then
    docker kill "$APP" >/dev/null 2>&1
    cut_dump
    start_new dump
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "the next start comes up" "0" "$rc"
    assert_contains "the old code went back without the dump" "$log" "the database was not changed by the upgrade, so it stays as it is"
    assert_contains "the damaged backup was thrown away and a new one made" "$log" "no longer matches its stamp"
    check_new_site "after a new backup"
  else
    fail "the upgrade reaches the pause after the copy"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 6. too little free space ---------------------------------------------------------------------------------------
if wants no-space; then
  echo
  echo "Too little free space on the code volume"
  new_case space 6.16.1
  # A df that reports 100 MB free, in front of the real one. Nothing in the image is changed.
  printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 10000000 9897600 102400 99%% /var/www/html"\n' > "$WORK/df"
  chmod 755 "$WORK/df"
  start_new space -v "$WORK/df:/usr/local/bin/df:ro"
  rc=0; ls_wait_apache "$APP" 300 || rc=$?
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the container comes up" "0" "$rc"
  assert_contains "the log says how much is free and how much is needed" "$log" "[clouve-upgrade] FAILED limesurvey 6.16.1 -> 7.10.0: the code volume has 100 MB free"
  check_old_site "with too little space" 6.16.1
  assert_eq "no backup folder was made" "0" "$(docker exec "$APP" sh -c 'ls -d /var/www/html/clouve/upgrade-*/ 2>/dev/null | wc -l')"
  assert_eq "and no upgrade-failed file: the next start checks again" "0" "$(docker exec "$APP" sh -c 'ls /var/www/html/clouve/upgrade-failed 2>/dev/null | wc -l')"
  assert_contains "the log says the upgrade was skipped at this start" "$log" "[clouve-upgrade] skipped: "
  note="$(clouve_file space upgrade-skipped)"
  assert_contains "clouve/upgrade-skipped has the reason" "$note" "reason=the code volume has 100 MB free"
  assert_eq "and the versions, the build and the time" "4" "$(grep -c -E '^(from=6\.16\.1|to=7\.10\.0|build=7\.10\.0\+.*|when=20..-..-..T..:..:..Z)$' <<< "$note")"
  assert_eq "the note is root's, mode 600" "root:root 600" "$(docker exec "$APP" stat -c '%U:%G %a' /var/www/html/clouve/upgrade-skipped)"
  # The note never stops a retry: the next start, with space, upgrades and removes it.
  start_new space
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "with space, the next start comes up" "0" "$rc"
  check_new_site "after the space came back"
  assert_eq "clouve/upgrade-skipped is gone" "0" "$(clouve_count space upgrade-skipped)"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 7. newer code, and a database newer than its code --------------------------------------------------------------
if wants refusals; then
  echo
  echo "Code newer than the image"
  new_case refuse 6.16.1
  vol_run "${PREFIX}refuse-html" "sed -i \"s/^\\(.config\\['versionnumber'\\] = \\)'6.16.1'/\\1'7.99.0'/; s/^\\(.config\\['dbversionnumber'\\] = \\)640/\\1999/\" /v/application/config/version.php" >/dev/null
  start_new refuse
  code="$(ls_wait_exit "$APP" 300)"
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the start stops with status 1" "1" "$code"
  assert_contains "the log says the volume's code is newer" "$log" "the volume holds LimeSurvey 7.99.0 (database version 999), which is newer than this image's"
  assert_lacks "Apache never started" "$log" "starting Apache"
  assert_eq "no upgrade phase ran" "0" "$(grep -c '\[clouve-upgrade\]' <<< "$log")"
  # waits LABEL NEEDLE: the start waits for repair, says NEEDLE, and changed nothing in the database.
  waits() {
    local label="$1" needle="$2" rc=0 log
    start_new refuse
    ls_wait_hold "$APP" 300 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "$label: the start waits for repair" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 12 | sed 's/^/       | /'
    ls_assert_hold "$label" "$APP"
    assert_contains "$label: the log says what was found" "$log" "$needle"
    assert_eq "$label: no upgrade ran" "0" "$(grep -c -e '\[clouve-upgrade\] backup: ' -e '\[clouve-upgrade\] restore: ' <<< "$log")"
    assert_eq "$label: no table was dropped, made or changed" "$REFUSE_SUM" "$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
    docker rm -f -v "$APP" >/dev/null 2>&1
  }
  version_file() { vol_run "${PREFIX}refuse-html" "sed -i \"s/^\\(.config\\['versionnumber'\\] = \\)'[0-9.]*'/\\1'$1'/; s/^\\(.config\\['dbversionnumber'\\] = \\)[0-9]*/\\1$2/\" /v/application/config/version.php" >/dev/null; }
  echo
  echo "A database newer than its code"
  version_file 6.16.1 640
  ls_sql "$DB" "UPDATE lime_settings_global SET stg_value = '718' WHERE stg_name = 'DBVersion'" >/dev/null
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "a database newer than its code" "the database is at version 718, which is newer than the code on the volume (LimeSurvey 6.16.1"
  assert_eq "the code on the volume is still 6.16.1" "1" \
    "$(vol_run "${PREFIX}refuse-html" "grep -c \"'6.16.1'\" /v/application/config/version.php")"
  ls_sql "$DB" "UPDATE lime_settings_global SET stg_value = '640' WHERE stg_name = 'DBVersion'" >/dev/null

  echo
  echo "The package's code on an older database, with no upgrade under way"
  version_file "$NEW_VERSION" "$NEW_DB"
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "new code on an old database" "but the database is at version 640, not $NEW_DB, and no upgrade of this image is under way"
  version_file 6.16.1 640

  echo
  echo "A DBUpdateIncomplete row, with no upgrade under way"
  ls_sql "$DB" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('DBUpdateIncomplete', '640')" >/dev/null
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "a DBUpdateIncomplete row" "the database says an update from version 640 failed or was cut off (DBUpdateIncomplete)"
  ls_sql "$DB" "DELETE FROM lime_settings_global WHERE stg_name = 'DBUpdateIncomplete'" >/dev/null

  echo
  echo "No security.php"
  vol_run "${PREFIX}refuse-html" 'mv /v/application/config/security.php /v/security.php.kept' >/dev/null
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "no security.php" "application/config/security.php is missing, and the database holds a LimeSurvey install"
  assert_eq "no new security.php was made" "0" "$(vol_run "${PREFIX}refuse-html" 'ls /v/application/config/security.php 2>/dev/null | wc -l')"
  vol_run "${PREFIX}refuse-html" 'mv /v/security.php.kept /v/application/config/security.php' >/dev/null

  echo
  echo "Tables, but not LimeSurvey's settings table"
  ls_sql "$DB" "RENAME TABLE lime_settings_global TO clv_hidden_settings" >/dev/null
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "no settings table" "tables and none of them is LimeSurvey's settings table (lime_settings_global)"
  ls_sql "$DB" "RENAME TABLE clv_hidden_settings TO lime_settings_global" >/dev/null

  echo
  echo "After all of these, the site is still the one from before"
  start_new refuse
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "put right again, the site upgrades" "0" "$rc"
  check_new_site "after the refusals"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1

  echo
  echo "Old code on an empty database"
  new_case refuse 6.16.1
  docker exec -e "MYSQL_PWD=$LS_DB_ROOT_PW" "$DB" mariadb -h 127.0.0.1 -u root -e 'DROP DATABASE limesurvey; CREATE DATABASE limesurvey' >/dev/null 2>&1
  REFUSE_SUM="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
  waits "old code on an empty database" "the volume holds LimeSurvey 6.16.1 and the database limesurvey is empty. This image installs"
  assert_eq "nothing was installed into the empty database" "0" \
    "$(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey'")"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 8. kills at random moments, and two kills in a row -------------------------------------------------------------
if wants kills-random; then
  echo
  echo "An upgrade without a kill, to compare with"
  new_case ref 6.16.1
  start_new ref
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "the upgraded site comes up" "0" "$rc"
  REF_SUM="$(upgraded_sum "$DB")"
  ls_db_sums "$DB" "$UPGRADED_SKIP" > "$WORK/ref-sums"
  # How long the upgrade took, from its first log line to its last, in milliseconds.
  t_first="$(docker logs -t "$APP" 2>&1 | sed -n 's/^\([^ ]*\) \[clouve-upgrade\] .*/\1/p' | head -n 1)"
  t_last="$(docker logs -t "$APP" 2>&1 | sed -n 's/^\([^ ]*\) \[clouve-upgrade\] done: .*/\1/p' | head -n 1)"
  window=$(( $(date -d "$t_last" +%s%3N) - $(date -d "$t_first" +%s%3N) + 500 ))
  echo "       the upgrade took $((window - 500)) ms. Kills come at a random moment within $window ms of a start's first [clouve-upgrade] line"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1

  rounds="${LS_KILL_ROUNDS:-14}"
  echo
  echo "The container is killed at $rounds random moments, one start after the other, on the same volumes"
  new_case rnd 6.16.1
  landed=""
  fresh=0
  round=1
  while [ "$round" -le "$rounds" ] && [ "$fresh" -le "$rounds" ]; do
    start_new rnd
    # Until this start's upgrade (or its restore) has begun.
    for ((i = 0; i < 1200; i++)); do
      docker logs "$APP" 2>&1 | grep -qF '[clouve-upgrade]' && break
      [ "$(ls_pid1 "$APP")" = apache2 ] && break
      ls_running "$APP" || break
      sleep 0.05
    done
    offset=$(( (RANDOM * 32768 + RANDOM) % window ))
    sleep "$(printf '%d.%03d' $((offset / 1000)) $((offset % 1000)))"
    docker kill "$APP" >/dev/null 2>&1
    where="$(vol_run "${PREFIX}rnd-html" 'f=$(ls /v/clouve/upgrade-*/state 2>/dev/null | head -n 1); if [ -n "$f" ]; then
      p=$(sed -n "s/^phase=//p" "$f"); s=$(sed -n "s/^step=//p" "$f"); r=$(sed -n "s/^rstep=//p" "$f")
      case "$p" in upgrade) echo "upgrade/$s" ;; restore) echo "restore/$r" ;; *) echo "$p" ;; esac; else echo "no-state"; fi')"
    if [ "$where" = "done" ]; then
      # The kill came after the upgrade had finished. That round says nothing, so the site is taken afresh.
      fresh=$((fresh + 1))
      new_case rnd 6.16.1
      continue
    fi
    landed="$landed$round:${offset}ms:$where "
    # Every round is a first attempt: this case is about the kills, and the next one about the count.
    vol_run "${PREFIX}rnd-html" 'rm -f /v/clouve/upgrade-attempts /v/clouve/upgrade-failed' >/dev/null
    round=$((round + 1))
  done
  echo "       kills (round:offset:state on the volume): $landed"
  echo "       states hit: $(tr ' ' '\n' <<< "$landed" | cut -d: -f3 | grep . | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
  if [ "$(tr ' ' '\n' <<< "$landed" | cut -d: -f3 | grep . | sort -u | wc -l)" -ge 3 ]; then
    pass "the kills landed in at least three different states of the upgrade"
  else
    fail "the kills landed in at least three different states of the upgrade"
  fi
  [ "$fresh" -eq 0 ] || echo "       ($fresh kills came after an upgrade had finished. Each time the site was taken afresh, and the round run again)"
  assert_eq "all $rounds kills landed while an upgrade or a restore was under way" "$rounds" "$(tr ' ' '\n' <<< "$landed" | grep -c .)"
  start_new rnd
  rc=0; ls_wait_apache "$APP" 900 || rc=$?
  assert_eq "after the kills, a start that is left alone comes up" "0" "$rc"
  [ "$rc" -eq 0 ] || docker logs --tail 25 "$APP" 2>&1 | sed 's/^/       | /'
  check_new_site "after kills at random moments"
  assert_eq "after kills at random moments: the whole database is what an upgrade without a kill gives (tables, and a checksum of their rows)" \
    "$REF_SUM" "$(upgraded_sum "$DB")"
  if [ "$REF_SUM" != "$(upgraded_sum "$DB")" ]; then
    echo "       tables that differ from the upgrade without a kill:"
    ls_db_sums "$DB" "$UPGRADED_SKIP" | diff "$WORK/ref-sums" - | grep '^[<>]' | cut -f1 | sort -u | sed 's/^/         /'
  fi
  assert_eq "after kills at random moments: the state says done" "done" "$(state_of rnd)"
  assert_eq "after kills at random moments: the SuiteCRM plugin is on again" "1" \
    "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1

  echo
  echo "Two kills in a row: the image gives up, and the old version runs"
  new_case two 6.16.1
  before="$(site_sum "$DB")"; made="$(ls_db_made "$DB")"
  for n in first second; do
    if pause_at two upgrade-copy; then docker kill "$APP" >/dev/null 2>&1; fi
  done
  assert_eq "each kill counted as an attempt" "count=2" "$(clouve_file two upgrade-attempts | grep '^count=')"
  start_new two
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the third start comes up" "0" "$rc"
  assert_contains "it gave up without a third attempt" "$log" "[clouve-upgrade] FAILED limesurvey 6.16.1 -> 7.10.0: gave up after 2 attempts"
  assert_eq "no attempt ran at the third start" "0" "$(grep -c '\[clouve-upgrade\] upgrade: limesurvey 6.16.1 -> 7.10.0, attempt' <<< "$log")"
  assert_contains "clouve/upgrade-failed says the upgrade was cut off twice" "$(clouve_file two upgrade-failed)" "reason=the upgrade was cut off twice"
  check_old_site "after two kills" 6.16.1
  assert_eq "after two kills: the state says failed" "failed" "$(state_of two)"
  assert_eq "after two kills: no table was dropped and made again" "$made" "$(ls_db_made "$DB")"
  assert_eq "after two kills: the tables hold what they held before the upgrade" "$before" "$(site_sum "$DB")"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 9. a code volume that fills up, on a real small filesystem -----------------------------------------------------
if wants full-volume; then
  # after_full LABEL: the old version runs, whole, and the database was never touched.
  after_full() {
    local label="$1" rc=0 log
    ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "$label: the container comes up on the old version" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 20 | sed 's/^/       | /'
    check_old_site "$label" 6.16.1
    assert_eq "$label: no table was dropped and made again" "$FULL_MADE" "$(ls_db_made "$DB")"
    assert_eq "$label: the tables hold what they held before" "$FULL_SUM" "$(site_sum "$DB")"
    assert_lacks "$label: nothing was loaded from the dump" "$log" "loaded from the dump"
  }

  echo
  echo "Too few inodes on the code volume (a tmpfs with a size and an inode limit)"
  small_case full 6.16.1
  FULL_SUM="$(site_sum "$DB")"; FULL_MADE="$(ls_db_made "$DB")"
  eat_inodes 20000
  echo "       the volume has $(free_inodes) free inodes and $(free_mb) MB free. The new code is $(docker run --rm --network none --entrypoint sh "$NEW_IMAGE" -c 'find /clouve/limesurvey/package | wc -l') files and folders"
  start_new full
  after_full "too few inodes"
  log="$(docker logs "$APP" 2>&1)"
  assert_contains "the log says how many inodes are free and how many are needed" "$log" "free inodes and the upgrade needs about"
  assert_contains "the upgrade was skipped at this start" "$log" "[clouve-upgrade] skipped: "
  assert_eq "no backup folder was made, and no upgrade-failed" "0 0" "$(clouve_count full 'upgrade-*-to-*') $(clouve_count full upgrade-failed)"
  assert_contains "clouve/upgrade-skipped says why" "$(clouve_file full upgrade-skipped)" "reason=the code volume has"
  assert_eq "the note is root's, mode 600" "0:0 600" "$(vol_run "${PREFIX}full-html" 'stat -c "%u:%g %a" /v/clouve/upgrade-skipped')"

  echo
  echo "The inodes run out while the new code is copied"
  give_back
  if pause_at full upgrade-move; then
    eat_inodes 9000
    echo "       filled during the pause: $(free_inodes) free inodes"
    end_pause
    after_full "inodes gone during the copy"
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the copy failed" "$log" "FAILED limesurvey 6.16.1 -> 7.10.0: the copy of the new code failed"
    assert_contains "the old code went back by renames" "$log" "[clouve-upgrade] restore: LimeSurvey 6.16.1 is back"
    assert_contains "and the database was left alone" "$log" "the database was not changed by the upgrade, so it stays as it is"
    assert_eq "no half-copied new code is left: the web root holds LimeSurvey 6.16.1 only" "6.16.1 640" "$(ls_code_version "$APP")"
    assert_eq "the upgrade's folder is gone, with its state" "0" "$(clouve_count full 'upgrade-*-to-*')"
    assert_contains "the second try was skipped, with the reason in clouve/upgrade-skipped" "$(clouve_file full upgrade-skipped)" "free inodes"
  fi
  echo
  echo "With the inodes back, the next start upgrades"
  give_back
  start_new full
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "the container comes up" "0" "$rc"
  check_new_site "after the inodes came back"
  assert_eq "clouve/upgrade-skipped is gone" "0" "$(clouve_count full upgrade-skipped)"
  docker rm -f -v "$APP" "$DB" "$HOLD" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}full-html" >/dev/null 2>&1

  echo
  echo "The space runs out while the new code is copied"
  small_case full 6.16.1
  FULL_SUM="$(site_sum "$DB")"; FULL_MADE="$(ls_db_made "$DB")"
  if pause_at full upgrade-move; then
    eat_space 60
    echo "       filled during the pause: $(free_mb) MB free"
    end_pause
    after_full "space gone during the copy"
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the copy failed" "$log" "FAILED limesurvey 6.16.1 -> 7.10.0: the copy of the new code failed"
    assert_contains "the old code went back by renames" "$log" "[clouve-upgrade] restore: LimeSurvey 6.16.1 is back"
    assert_eq "the web root holds LimeSurvey 6.16.1 only" "6.16.1 640" "$(ls_code_version "$APP")"
    assert_contains "the second try was skipped, with the reason in clouve/upgrade-skipped" "$(clouve_file full upgrade-skipped)" "MB free"
  fi
  docker rm -f -v "$APP" "$DB" "$HOLD" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}full-html" >/dev/null 2>&1

  echo
  echo "The volume is full to the last byte when a failed database update has to be undone"
  small_case full 6.16.1
  # The update creates lime_responses_777001. With the table already there, that step fails halfway.
  ls_sql "$DB" "CREATE TABLE lime_responses_777001 (id INT) ENGINE=MyISAM" >/dev/null
  FULL_SUM="$(site_sum "$DB")"
  if pause_at full upgrade-updatedb; then
    eat_space 0
    echo "       filled during the pause: $(hold "df -Pk /html | awk 'NR == 2 {print \$4}'") KB free"
    end_pause
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "the container comes up on the old version" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 20 | sed 's/^/       | /'
    assert_contains "the update failed" "$log" "console.php updatedb ended with status 1"
    assert_contains "the restore gave up its reserve file, wrote its state and loaded the dump" "$log" "[clouve-upgrade] restore: the database is as it was before the upgrade (loaded from the dump)"
    check_old_site "full during the restore" 6.16.1
    assert_eq "full during the restore: the tables hold what they held before the upgrade" "$FULL_SUM" "$(site_sum "$DB")"
  fi

  echo
  echo "Full to the last byte, and the reserve file is gone too: the restore does not start"
  give_back
  docker exec "$APP" rm -f /var/www/html/clouve/upgrade-failed /var/www/html/clouve/upgrade-attempts >/dev/null 2>&1
  if pause_at full upgrade-updatedb; then
    hold 'rm -f /html/clouve/upgrade-*/reserve'
    eat_space 0
    at_pause="$(ls_db_sum "$DB") / $(ls_db_made "$DB") / version $(ls_db_version "$DB")"
    end_pause
    rc=0; ls_wait_hold "$APP" 300 || rc=$?
    assert_eq "the start waits for repair" "0" "$rc"
    ls_assert_hold "no room for the restore's state" "$APP"
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the log says the restore was not started" "$log" "so the restore was not started"
    assert_eq "the database is exactly as the failed update left it: nothing was dropped, nothing loaded" "$at_pause" \
      "$(ls_db_sum "$DB") / $(ls_db_made "$DB") / version $(ls_db_version "$DB")"
    assert_eq "the state still says upgrade" "upgrade" "$(state_of full)"
    assert_eq "the dump is still there" "1" "$(clouve_count full 'upgrade-*-to-*/db.sql.gz')"
    # Staff free some space and restart.
    give_back
    start_new full
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "with space again, the next start comes up" "0" "$rc"
    assert_contains "it loaded the dump" "$log" "[clouve-upgrade] restore: the database is as it was before the upgrade (loaded from the dump)"
    check_old_site "after the space came back" 6.16.1
    assert_eq "after the space came back: the tables hold what they held before the upgrade" "$FULL_SUM" "$(site_sum "$DB")"
  fi
  docker rm -f -v "$APP" "$DB" "$HOLD" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}full-html" >/dev/null 2>&1

  echo
  echo "The volume fills up right after a database update that succeeded"
  small_case full 6.16.1
  if pause_at full upgrade-updatedb; then
    hold 'rm -f /html/clouve/upgrade-*/reserve'
    eat_space 0
    made="$(ls_db_made "$DB")"
    end_pause
    rc=0; ls_wait_hold "$APP" 300 || rc=$?
    assert_eq "the start waits for repair" "0" "$rc"
    ls_assert_hold "the upgrade is complete but can't be recorded" "$APP"
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the log says the upgrade is complete and only its state is missing" "$log" "The upgrade itself is complete"
    assert_lacks "it never said done" "$log" "[clouve-upgrade] done: "
    assert_eq "the state still says upgrade" "upgrade" "$(state_of full)"
    give_back
    start_new full
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "with space again, the next start comes up" "0" "$rc"
    assert_contains "it finished the upgrade off" "$log" "the database update had finished: finishing it off"
    assert_lacks "and restored nothing" "$log" "[clouve-upgrade] restore: "
    check_new_site "after the state could be written"
    assert_eq "after the state could be written: no table was dropped and made again" "$made" "$(ls_db_made "$DB")"
    assert_eq "after the state could be written: the state says done" "done" "$(state_of full)"
  fi
  docker rm -f -v "$APP" "$DB" "$HOLD" >/dev/null 2>&1
  docker volume rm -f "${PREFIX}full-html" >/dev/null 2>&1
fi

# --- 10. a state that says upgrade on a site that has run since ------------------------------------------------------
if wants stuck-state; then
  echo
  echo "A finished upgrade whose state still says upgrade, data written since, then an image with a newer LimeSurvey"
  new_case stuck 6.16.1
  start_new stuck
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "the upgrade to $NEW_VERSION comes up" "0" "$rc"
  docker stop -t 30 "$APP" >/dev/null 2>&1
  # What an upgrade leaves when its last state write fails (the code volume was full) and the site runs on.
  vol_run "${PREFIX}stuck-html" 'cd /v/clouve/upgrade-6.16.1-to-*/ && sed -i "s/^phase=done/phase=upgrade/; s/^step=.*/step=updating/" state &&
    echo "since=test" > db-touched && chmod 600 state db-touched && grep -c "^phase=upgrade" state' >/dev/null
  assert_eq "the state says upgrade again" "upgrade" "$(state_of stuck)"
  # The site has run since: a setting and a table that the dump doesn't have.
  ls_sql "$DB" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('clv_written_after', 'kept');
    CREATE TABLE lime_clv_after (id INT PRIMARY KEY, note VARCHAR(20)); INSERT INTO lime_clv_after VALUES (1, 'one'), (2, 'two')" >/dev/null
  # shellcheck disable=SC2016  # sed's own $ and \1
  next="$(other_image next 'sed -i "s/^\(\$config\[.versionnumber.\] = \).7\.10\.0./\1'"'"'7.10.1'"'"'/" /clouve/limesurvey/package/application/config/version.php && sed -i "1s/^7\.10\.0/7.10.1/" /clouve/limesurvey/image-build && grep -q 7.10.1 /clouve/limesurvey/package/application/config/version.php')"
  if [ -n "$next" ]; then
    LS_BUILT+=("$next")
    START_IMAGE="$next" start_new stuck
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "the image with LimeSurvey 7.10.1 comes up" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 20 | sed 's/^/       | /'
    assert_contains "it found the earlier upgrade complete" "$log" "the database update had finished: finishing it off"
    assert_lacks "it put no old version back" "$log" "[clouve-upgrade] restore: "
    assert_eq "the setting written after the upgrade is still there" "kept" \
      "$(ls_sql "$DB" "SELECT stg_value FROM lime_settings_global WHERE stg_name = 'clv_written_after'")"
    assert_eq "and the table with its two rows" "2" "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_clv_after")"
    assert_eq "the site is on LimeSurvey 7.10.1 now" "7.10.1 $NEW_DB" "$(ls_code_version "$APP")"
    assert_contains "the newer image then upgraded from 7.10.0" "$log" "[clouve-upgrade] done: limesurvey 7.10.0 -> 7.10.1"
    assert_eq "the ranking survey's answers are all there" "$RANK_BEFORE" "$(rank_after "$DB")"
  else
    fail "an image with LimeSurvey 7.10.1 could be made from the new image"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 11. a stop request during the upgrade ---------------------------------------------------------------------------
if wants stop; then
  echo
  echo "The container is asked to stop while the new code is copied"
  new_case stop 6.16.1
  if pause_at stop upgrade-copy; then
    t0=$(date +%s)
    docker stop -t 60 "$APP" >/dev/null 2>&1
    took=$(( $(date +%s) - t0 ))
    log="$(docker logs "$APP" 2>&1)"
    if [ "$took" -le 15 ]; then pass "docker stop ended the container in $took s (it may wait 60)"; else fail "docker stop ended the container in $took s (it may wait 60)"; fi
    assert_eq "the container ended with status 0, not with a kill's 137" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$APP")"
    assert_contains "the upgrade said that it stopped" "$log" "[clouve-upgrade] stopped: the container was asked to stop"
    assert_eq "the stopped attempt is not counted" "0" "$(clouve_count stop upgrade-attempts)"
    assert_eq "the state is what a kill would leave" "upgrade" "$(state_of stop)"
  fi
  echo
  echo "The container is asked to stop while the database update runs"
  start_new stop -e CLV_LS_TEST_PAUSE=updatedb:20
  if ls_wait_log "$APP" "test pause at updatedb" 600; then
    assert_contains "this start is attempt 1 again" "$(docker logs "$APP" 2>&1)" "attempt 1 of 2"
    sleep 2
    t0=$(date +%s)
    docker stop -t 120 "$APP" >/dev/null 2>&1
    took=$(( $(date +%s) - t0 ))
    log="$(docker logs "$APP" 2>&1)"
    if [ "$took" -ge 10 ] && [ "$took" -le 90 ]; then pass "docker stop waited for the database update ($took s; the update was made to last 20 s)"; else
      fail "docker stop waited for the database update ($took s; the update was made to last 20 s)"; fi
    assert_eq "the container ended with status 0" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$APP")"
    assert_contains "the upgrade stopped after the update" "$log" "[clouve-upgrade] stopped: the container was asked to stop"
    assert_eq "the database update ran to its end" "$NEW_DB" "$(ls_db_version "$DB")"
    assert_eq "no DBUpdateIncomplete row" "0" "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_settings_global WHERE stg_name = 'DBUpdateIncomplete'")"
    assert_eq "the stopped attempt is not counted" "0" "$(clouve_count stop upgrade-attempts)"
    start_new stop
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "the next start comes up" "0" "$rc"
    assert_contains "it finished the upgrade off, with no restore" "$log" "the database update had finished: finishing it off"
    assert_lacks "it loaded nothing" "$log" "[clouve-upgrade] restore: "
    check_new_site "after a stop during the database update"
    assert_eq "after a stop during the database update: the state says done" "done" "$(state_of stop)"
  else
    fail "the upgrade reaches the pause inside the database update"
    docker logs --tail 15 "$APP" 2>&1 | sed 's/^/       | /'
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 12. a state folder that is not root's ---------------------------------------------------------------------------
if wants untrusted-state; then
  # plant: as www-data, moves the real clouve/ aside and puts a folder of its own there: a state that asks for a
  # restore, the marker that says the database was changed, and a dump with a stamp that matches it. The dump
  # drops nothing by itself. It makes one table, so a load would show.
  plant() {
    docker run --rm --network none -u www-data -v "${PREFIX}$1-html:/v" --entrypoint bash "$NEW_IMAGE" -c '
      cd /v && mv clouve clouve.real && mkdir clouve && d=clouve/upgrade-6.16.1-to-7.10.0 && mkdir "$d" &&
      printf "phase=restore\nrstep=removing-new\nfrom=6.16.1\nfrom_db=640\nto=7.10.0\nto_db=718\n" > "$d/state" &&
      echo "since=planted" > "$d/db-touched" &&
      printf "%s\n" "CREATE TABLE planted_by_www_data (id INT);" "-- Dump completed" | gzip > "$d/db.sql.gz" &&
      printf "sha256=%s\ntables=1\ndbversion=640\ncode=6.16.1\n" "$(sha256sum "$d/db.sql.gz" | cut -d" " -f1)" > "$d/backup-complete"' 2>&1
  }
  echo
  echo "PHP code moves clouve/ aside and plants a state and a dump (the site is whole)"
  new_case plant 6.16.1
  start_new plant
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  assert_eq "the upgrade comes up" "0" "$rc"
  assert_eq "clouve/ and what the upgrade wrote there are root's, and nothing in it is readable by others" "0:0 700 0" \
    "$(vol_run "${PREFIX}plant-html" 'echo "$(stat -c "%u:%g %a" /v/clouve) $(find /v/clouve -path "/v/clouve/upgrade-*/code/*" -prune -o \( ! -user 0 -o -perm /077 \) -print | wc -l)"')"
  assert_eq "www-data can't list the folder or read the dump" "denied denied" \
    "$(docker exec -u www-data "$APP" sh -c 'ls /var/www/html/clouve >/dev/null 2>&1 && echo listed || echo denied; cat /var/www/html/clouve/upgrade-*/db.sql.gz >/dev/null 2>&1 && echo read || echo denied' | tr '\n' ' ' | sed 's/ $//')"
  docker stop -t 30 "$APP" >/dev/null 2>&1
  before="$(site_sum "$DB")"; made="$(ls_db_made "$DB")"
  out="$(plant plant)" || { fail "www-data could plant its folder (the web root is its own)"; echo "       $out"; }
  start_new plant
  rc=0; ls_wait_apache "$APP" 600 || rc=$?
  log="$(docker logs "$APP" 2>&1)"
  assert_eq "the next start comes up: the code and the database agree" "0" "$rc"
  assert_contains "the log says the folder was not root's and where it went" "$log" "was not a folder of root's, so nothing in it was read or used. It is now /var/www/html/clouve.untrusted-"
  assert_lacks "the planted state was not acted on" "$log" "[clouve-upgrade] restore"
  assert_eq "the planted dump was not loaded" "0" \
    "$(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey' AND table_name = 'planted_by_www_data'")"
  assert_eq "no table was dropped and made again" "$made" "$(ls_db_made "$DB")"
  assert_eq "the tables hold what they held" "$before" "$(site_sum "$DB")"
  check_new_site "after the planted folder"
  assert_eq "clouve/ is a new folder of root's, mode 700" "0:0 700" "$(vol_run "${PREFIX}plant-html" 'stat -c "%u:%g %a" /v/clouve')"
  assert_eq "the planted folder was moved aside as it was: still www-data's, its state untouched" "33 phase=restore" \
    "$(vol_run "${PREFIX}plant-html" 'd=$(ls -d /v/clouve.untrusted-*) && echo "$(stat -c %u "$d") $(head -n 1 "$d"/upgrade-*/state)"')"
  assert_eq "the real folder, which www-data had renamed, was left alone" "done" \
    "$(vol_run "${PREFIX}plant-html" "sed -n 's/^phase=//p' /v/clouve.real/upgrade-*/state")"
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1

  echo
  echo "The same while an upgrade is under way: the site is between two versions, and its backup is not trusted"
  new_case plant 6.16.1
  # Killed with the new code on the volume and the database still at the old version.
  if pause_at plant upgrade-copy; then
    docker kill "$APP" >/dev/null 2>&1
    before="$(ls_db_sum "$DB") / $(ls_db_made "$DB")"
    out="$(plant plant)" || { fail "www-data could plant its folder"; echo "       $out"; }
    start_new plant
    rc=0; ls_wait_hold "$APP" 300 || rc=$?
    assert_eq "the start waits for repair instead of starting a site without its state" "0" "$rc"
    ls_assert_hold "between two versions" "$APP"
    log="$(docker logs "$APP" 2>&1)"
    assert_contains "the FAILED line names the folder that was moved aside and says to keep it" "$log" "If it holds an upgrade's backup, that backup is the way back, so keep it."
    assert_lacks "the planted state was not acted on" "$log" "[clouve-upgrade] restore"
    assert_eq "the planted dump was not loaded, and no table was dropped" "$before / 0" \
      "$(ls_db_sum "$DB") / $(ls_db_made "$DB") / $(ls_sql "$DB" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'limesurvey' AND table_name = 'planted_by_www_data'")"
    assert_eq "clouve-ops can sign in to repair it" "clouve-ops" "$(ls_ssh_whoami "$APP" "$LS_OPS_PW")"
    ls_assert_note "between two versions" "$APP" repair
    t0=$(date +%s); docker stop -t 60 "$APP" >/dev/null 2>&1; took=$(( $(date +%s) - t0 ))
    if [ "$took" -le 15 ]; then pass "a stop request ends the wait in $took s"; else fail "a stop request ends the wait in $took s"; fi
    assert_eq "with status 0" "0" "$(docker inspect --format '{{.State.ExitCode}}' "$APP")"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 13. the README's runbook, as written ----------------------------------------------------------------------------
if wants runbook; then
  # damaged: an upgrade that was cut off after its database update began, with a dump that is cut short. The start
  # then waits for repair. A whole copy of the dump stands in for the platform's own backup.
  damaged() {
    new_case book 6.16.1
    BOOK_SUM="$(site_sum "$DB")"
    pause_at book upgrade-updatedb || return 1
    docker kill "$APP" >/dev/null 2>&1
    docker run --rm --network none -v "${PREFIX}book-html:/v" -v "$WORK:/out" "$SHAPER" sh -c \
      'f=$(ls /v/clouve/upgrade-*/db.sql.gz) && cp "$f" /out/before-upgrade.sql.gz && chmod 644 /out/before-upgrade.sql.gz &&
       head -c 2000 "$f" > "$f.cut" && cat "$f.cut" > "$f" && rm "$f.cut"' >/dev/null
    # The update is made to look cut off halfway.
    ls_sql "$DB" "UPDATE lime_settings_global SET stg_value = '700' WHERE stg_name = 'DBVersion'" >/dev/null
    start_new book
    rc=0; ls_wait_hold "$APP" 300 || rc=$?
    assert_eq "$1: the start waits for repair" "0" "$rc"
    assert_contains "$1: because the dump is not the one that was stamped" "$(docker logs "$APP" 2>&1)" "is not the backup that was stamped complete"
    docker cp "$WORK/before-upgrade.sql.gz" "$APP:/root/before-upgrade.sql.gz" >/dev/null
  }
  block="$(readme_block '### A damaged dump')"
  keep_old="$(readme_block '### A damaged dump' 2)"
  go_back="$(readme_block '### Go back to the old version after a finished upgrade')"
  assert_eq "the README has the three code blocks this case runs" "3" \
    "$(( $(grep -c 'rm upgrade-\*-to-\*/db-touched' <<< "$block") + $(grep -c 'upgrade-attempts' <<< "$keep_old") + $(grep -c 'go-back.sh --yes-lose-what-was-written-since' <<< "$go_back") ))"

  echo
  echo "The runbook's steps for a damaged dump, then a restart: the site upgrades again"
  if damaged "a damaged dump"; then
    out="$(docker exec -i "$APP" bash -s <<< "$block" 2>&1)"
    assert_eq "the README's block runs in the waiting container and prints the old database version" "640" "$(tail -n 1 <<< "$out")"
    docker restart -t 30 "$APP" >/dev/null
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "after the restart the container comes up" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 15 | sed 's/^/       | /'
    assert_contains "the image put the old code back itself" "$log" "[clouve-upgrade] restore: LimeSurvey 6.16.1 is back"
    assert_contains "threw the damaged backup away and made a new one" "$log" "and a new backup is made"
    check_new_site "after the runbook's steps"
    assert_eq "after the runbook's steps: the state says done" "done" "$(state_of book)"

    echo
    echo "The runbook's way back from the finished upgrade"
    ls_sql "$DB" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('clv_written_after', 'lost on the way back')" >/dev/null
    out="$(docker exec -i "$APP" bash -s <<< "$go_back" 2>&1)"
    assert_contains "go-back.sh says what the next start will do" "$out" "the next start puts LimeSurvey 6.16.1 back"
    assert_eq "it changed nothing in the site itself" "$NEW_VERSION $NEW_DB $NEW_DB" "$(ls_code_version "$APP") $(ls_db_version "$DB")"
    docker restart -t 30 "$APP" >/dev/null
    rc=0; ls_wait_log "$APP" "gave up after 2 attempts" 600 || rc=$?
    ls_wait_apache "$APP" 600 || rc=$?
    log="$(docker logs "$APP" 2>&1)"
    assert_eq "after the restart the old version comes up" "0" "$rc"
    [ "$rc" -eq 0 ] || printf '%s\n' "$log" | tail -n 15 | sed 's/^/       | /'
    check_old_site "after the way back" 6.16.1
    assert_eq "after the way back: the tables hold what they held before the upgrade" "$BOOK_SUM" "$(site_sum "$DB")"
    assert_eq "after the way back: what was written since the upgrade is gone, as the README says" "0" \
      "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_settings_global WHERE stg_name = 'clv_written_after'")"
    assert_contains "clouve/upgrade-failed says the old version was put back by hand" "$(clouve_file book upgrade-failed)" \
      "reason=the old version was put back by hand (go-back.sh)"
    assert_eq "after the way back: the state says failed" "failed" "$(state_of book)"
    docker restart -t 30 "$APP" >/dev/null
    rc=0; ls_wait_apache "$APP" 300 || rc=$?
    assert_eq "another restart stays on the old version" "0 1" "$rc $(docker logs "$APP" 2>&1 | grep -c '\[clouve-upgrade\] not upgrading: ')"
    assert_eq "and the code is still LimeSurvey 6.16.1" "6.16.1 640" "$(ls_code_version "$APP")"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1

  echo
  echo "The runbook's steps for a damaged dump, with the attempt counter filled: the old version stays"
  if damaged "a damaged dump, to stay on the old version"; then
    out="$(docker exec -i "$APP" bash -s <<< "$block" 2>&1)"
    assert_eq "the README's block prints the old database version" "640" "$(tail -n 1 <<< "$out")"
    docker exec -i "$APP" bash -s <<< "$keep_old" >/dev/null 2>&1
    docker restart -t 30 "$APP" >/dev/null
    rc=0; ls_wait_log "$APP" "gave up after 2 attempts" 600 || rc=$?
    ls_wait_apache "$APP" 600 || rc=$?
    assert_eq "after the restart the old version comes up" "0" "$rc"
    check_old_site "kept on the old version" 6.16.1
    assert_eq "kept on the old version: the tables hold what they held before the upgrade" "$BOOK_SUM" "$(site_sum "$DB")"
    assert_contains "clouve/upgrade-failed has the reason that was given" "$(clouve_file book upgrade-failed)" "reason=kept on the old version by hand"
  fi
  docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
fi

# --- 2. the upgrade from 6.17.18, at full speed ---------------------------------------------------------------------
if wants upgrade-6.17; then
  echo
  echo "The LimeSurvey 6.17.18 site"
  seed_site 6.17.18
  if [ "$SEED_OK" = true ]; then
    echo
    echo "The upgrade from 6.17.18, at full speed"
    new_case up17 6.17.18
    # The admin had put the site in "soft" maintenance mode before the upgrade.
    ls_sql "$DB" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('maintenancemode', 'soft')
      ON DUPLICATE KEY UPDATE stg_value = 'soft'" >/dev/null
    start_new up17
    rc=0; ls_wait_apache "$APP" 600 || rc=$?
    if [ "$rc" -eq 0 ]; then
      log="$(docker logs "$APP" 2>&1)"
      pass "the upgraded site comes up"
      echo "       $(grep -m1 '\[clouve-upgrade\] done: ' <<< "$log")"
      check_new_site "from 6.17.18"
      assert_eq "the site is in soft maintenance mode again, as its admin had it" "soft" \
        "$(ls_sql "$DB" "SELECT stg_value FROM lime_settings_global WHERE stg_name = 'maintenancemode'")"
      assert_contains "and the log says so" "$log" "maintenance mode is 'soft' again, as it was before the upgrade"
      assert_eq "the SuiteCRM plugin is on again" "1" "$(ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
      assert_eq "the old code in the backup is 6.17.18" "6.17.18" \
        "$(docker exec "$APP" sed -n "s/^\$config\['versionnumber'\] = '\([0-9.]*\)'.*/\1/p" "/var/www/html/clouve/upgrade-6.17.18-to-$NEW_VERSION/code/application/config/version.php")"
      assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
    else
      fail "the upgraded site comes up"
      docker logs --tail 30 "$APP" 2>&1 | sed 's/^/       | /'
    fi
    docker rm -f -v "$APP" "$DB" >/dev/null 2>&1
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sLimeSurvey upgrade checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sLimeSurvey upgrade checks failed.%s\n' "$RED" "$RESET"
exit 1
