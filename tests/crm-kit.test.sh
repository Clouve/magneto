#!/bin/bash

# ============================================================================
# Customer Kit test: LimeSurvey and SuiteCRM together, with the link between them
# ============================================================================
# Runs the bundle's four containers (limesurvey, limesurvey-mariadb, suitecrm,
# suitecrm-mariadb) with the settings of bundles/crm-kit/clv-docker-compose.yml:
# every variable and its type, each container's memory and CPU (memoryBase,
# cpuBase), its volumes and its own probe (x-clouve-healthcheck). Placeholders
# get test values, each secret a random one, and a containerReference is the
# container's name on a network of the test's own. Every volume is made the way
# a cluster makes a new disk (README.md, "Volumes on a cluster"). No SuiteCRM or
# LimeSurvey is faked: a survey response travels from a respondent's HTTP
# request through Clouve's plugin and SuiteCRM's API into SuiteCRM's database.
#
# The bundle's files (no container):
#   - the manifest differs from the one at commit OLD_COMMIT only in the two
#     appVersions, the two descriptions and the x-clouve-agent block with both
#     skills: no variable, capacity, volume, probe number or name changed;
#   - docker-compose.yml gives all four services one CLOUVE_OPS_PASSWORD and
#     has the magneto-agent service with both skills and the four siblings;
#   - the kit's LimeSurvey description says, as the standalone listing does,
#     that invitations go through the customer's own mail server, and its
#     SuiteCRM description promises nothing that SuiteCRM's own listing
#     qualifies or leaves out;
#   - description.txt has a short and a long description the publish wizard
#     takes, and its text keeps tests/listing-ai-copy.test.sh's rules.
#
# A new kit (the default):
#   - each container passes its own probe within its budget, on new disks;
#   - LimeSurvey and SuiteCRM run the versions the manifest names;
#   - the plugin is registered and on, with its settings from the environment
#     and no password in clear text; the demo survey is there with its link on;
#   - the plugin's table of mappings has the plugin's current shape, and a
#     question's mappings can be saved (two fields, one with a rule);
#   - each of the plugin's endpoints answers 401 to a caller not signed in;
#   - when the plugin's OAuth2 client is deleted in SuiteCRM, a response is
#     recorded as failed, and "Initialize OAuth2" on the plugin's settings
#     page makes a new client, after which responses become leads again;
#   - a sales inquiry submitted over HTTP becomes one lead in SuiteCRM and no
#     case; a support request becomes a case with its subject, and a lead
#     with the person's contact details;
#   - with CLOUVE_OPS_PASSWORD on all four, each sshd takes the sign-in over
#     the network, and no server has the password in its environment (in the
#     database containers only tini, PID 1, which was started with it);
#   - no container's log holds a password.
#
# --upgrade-from: an old kit first. LimeSurvey 6.16.1 and SuiteCRM 8.9.1, built
# from this repository's Dockerfiles at OLD_COMMIT, on mariadb:11.8 and
# mariadb:12.1, with the old manifest's settings, the plugin on, a lead made
# through it, the OAuth2 client it created and a plugin an admin added. Its five
# volumes are kept, and each case starts the new images on a copy of them, with
# no CLOUVE_OPS_PASSWORD (an install made without the AI Assistant):
#   upgrade   Both database containers pass their command probe before the
#             platform would restart them, MariaDB's own upgrade included (the
#             time is printed). Both apps upgrade in one start while their
#             probes hold (the pair's wall time is printed). LimeSurvey is on
#             7.10.0 and SuiteCRM on 8.10.2. The plugin is on again, the added
#             plugin is left off and named. The earlier response, its lead and
#             the plugin's settings are still there, and its passwords are now
#             stored encrypted. The OAuth2 client is the same and still works:
#             a new response becomes a new lead. The old table of mappings has
#             the current shape. SuiteCRM's scheduler is held. No sshd runs.
#   standin   SuiteCRM's upgrade is held at its stand-in (the test-only pause)
#             while LimeSurvey finishes. A response submitted then is recorded
#             as failed, never as synced, and no lead is made of it. Once
#             SuiteCRM is up, the next response becomes a lead.
#   faulty    The old image can leave the plugin marked as faulty (its log file
#             in /tmp, see the old kit's comment below). LimeSurvey never loads
#             a plugin with that mark. After the upgrade the mark is gone, the
#             log says so, and a response becomes a lead.
#
# --image NAME=REF uses an image that is already built (limesurvey,
# limesurvey-mariadb, suitecrm, suitecrm-mariadb); without it the test builds
# this checkout's. --old-image NAME=REF does the same for the old kit
# (limesurvey, suitecrm, limesurvey-mariadb, suitecrm-mariadb). Everything the
# test makes is named crm-kit-t-* (CRM_KIT_TEST_PREFIX changes that), runs on a
# network with no way out and no published port, and is removed at the end
# unless --keep is given. Every password is made up.
# Needs Docker, git and python3 with PyYAML.
#
# Usage: bash tests/crm-kit.test.sh [--upgrade-from] [--image NAME=REF]... [--old-image NAME=REF]... [--keep] [CASE...]
#   CASE  files, new, upgrade, standin or faulty (default: files and new; with --upgrade-from: files, upgrade,
#         standin and faulty)
# Exit status: 0 when every check passes, 1 when one fails, 2 when the test can't run.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${CRM_KIT_TEST_PREFIX:-crm-kit-t-}"
# shellcheck disable=SC2034  # tests/lib/suitecrm-test-lib.sh reads it when it is sourced
SUITECRM_TEST_PREFIX="$PREFIX"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"
# shellcheck source=lib/suitecrm-test-lib.sh
. "$SCRIPT_DIR/lib/suitecrm-test-lib.sh"

BUNDLE="$REPO_DIR/bundles/crm-kit"
MANIFEST="$BUNDLE/clv-docker-compose.yml"
# The last commit whose images are LimeSurvey 6.16.1 and SuiteCRM 8.9.1, and whose manifest is the old kit's.
OLD_COMMIT=cb6cca2b0fb83f658ec732764a728706296ec7df
OLD_LS=6.16.1
OLD_LS_BASE=martialblog/limesurvey:6.16.1-251125-apache
OLD_SC=8.9.1
SERVICES=(limesurvey-mariadb suitecrm-mariadb suitecrm limesurvey)
NET="${PREFIX}net"
PROBER="${PREFIX}prober"
SHAPER="${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}"
SID=123456
ENDPOINTS=(actionGetModules actionGetFields actionGetAllFields actionTestConnection actionRefreshCache actionGetSyncLogs
  actionSaveMappings actionGetMappings actionGetTransformRules actionCheckStatus actionInitializeOAuth2)

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

declare -A NEW_IMAGE=() OLD_IMAGE=()
UPGRADE=false
KEEP=false
CASES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --upgrade-from) UPGRADE=true ;;
    --keep) KEEP=true ;;
    --image | --old-image)
      case "${2:-}" in
        limesurvey=?* | limesurvey-mariadb=?* | suitecrm=?* | suitecrm-mariadb=?*) ;;
        *) usage ;;
      esac
      if [ "$1" = --image ]; then NEW_IMAGE[${2%%=*}]="${2#*=}"; else OLD_IMAGE[${2%%=*}]="${2#*=}"; fi
      shift
      ;;
    files | new | upgrade | standin | faulty) CASES+=("$1") ;;
    *) usage ;;
  esac
  shift
done
if [ "${#CASES[@]}" -eq 0 ]; then
  if [ "$UPGRADE" = true ]; then CASES=(files upgrade standin faulty); else CASES=(files new); fi
fi
wants() { local c; for c in "${CASES[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  local image
  if [ "$KEEP" = true ]; then
    echo "Kept everything named ${PREFIX}* (containers, volumes, the network)"
  else
    ls_remove_all
  fi
  for image in ${LS_BUILT[@]+"${LS_BUILT[@]}"} ${SC_BUILT[@]+"${SC_BUILT[@]}"}; do docker rmi -f "$image" >/dev/null 2>&1; done
  [ -n "$SC_WORK" ] && rm -rf "$SC_WORK"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

finish() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    printf '%sCustomer Kit checks passed.%s\n' "$GREEN" "$RESET"
    exit 0
  fi
  printf '%sCustomer Kit checks failed.%s\n' "$RED" "$RESET"
  exit 1
}

# --- the manifest's settings ------------------------------------------------------------------------------------------

# kit_settings TAG MANIFEST: writes one env file per service ($WORK/TAG.<service>.env, mode 600) with the manifest's
# variables filled in as the platform fills them, and $WORK/TAG.sh, which sets for each service its memory, CPU,
# volumes, probe and version. The made-up values are kept in $WORK/values.json, so a second manifest gets the same
# ones. Nothing is printed.
kit_settings() {
  python3 -I - "$2" "$WORK" "$1" <<'PY'
import json, os, secrets, shlex, sys
import yaml

manifest, work, tag = sys.argv[1:4]
with open(manifest) as fh:
    doc = yaml.safe_load(fh)
values_file = os.path.join(work, "values.json")
made = {}
if os.path.exists(values_file):
    with open(values_file) as fh:
        made = json.load(fh)
fills = {"{user.firstName}": "Kit", "{user.lastName}": "Admin", "{user.userEmail}": "kit.admin@example.test",
         "{org.name}": "Kit Org"}

def secret(name, admin=False):
    if name not in made:
        made[name] = ("Kit-Adm1n-" if admin else "pw-") + secrets.token_hex(8)
    return made[name]

def write(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, text.encode())
    os.close(fd)

shell = []
for name, svc in doc["services"].items():
    types = svc.get("x-clouve-environment-types") or {}
    lines = []
    for var, value in (svc.get("environment") or {}).items():
        value, kind = str(value), types.get(var, "static")
        if kind == "secret":
            value = secret(value)
        elif kind == "applicationPassword":
            value = secret(value, admin=True)
        elif kind == "applicationUrl":
            value = "https://%s.kit.example.test" % name
        elif kind != "containerReference":
            for k, v in fills.items():
                value = value.replace(k, v)
        if "\n" in value:
            sys.exit("a value with a line break can't go in an env file")
        lines.append("%s=%s" % (var, value))
    write(os.path.join(work, "%s.%s.env" % (tag, name)), "\n".join(lines) + "\n")
    meta = svc.get("x-clouve-metadata") or {}
    hc = svc.get("x-clouve-healthcheck") or {}
    key = shlex.quote(name)
    shell.append("KIT_MEM[%s]=%d" % (key, int(float(meta.get("memoryBase", 1)) * 1024 ** 3)))
    shell.append("KIT_CPU[%s]=%s" % (key, float(meta.get("cpuBase", 1))))
    shell.append("KIT_VOLS[%s]=%s" % (key, shlex.quote(" ".join(svc.get("volumes") or []))))
    shell.append("KIT_VERSION[%s]=%s" % (key, shlex.quote(str((svc.get("x-clouve-bundle-metadata") or {}).get("appVersion", "")))))
    shell.append("KIT_PROBE_TYPE[%s]=%s" % (key, shlex.quote(str(hc.get("type", "")).upper() if hc.get("enabled") else "")))
    shell.append("KIT_PROBE_PORT[%s]=%s" % (key, shlex.quote(str(hc.get("port", "")))))
    shell.append("KIT_PROBE_PATH[%s]=%s" % (key, shlex.quote(str(hc.get("path", "")))))
    shell.append("KIT_PROBE_TIMEOUT[%s]=%d" % (key, int(hc.get("timeout", 1))))
    delay, every, fails = int(hc.get("initialDelay", 0)), int(hc.get("interval", 10)), int(hc.get("failureThreshold", 3))
    # The budget is the one tests/new-disk-start.test.sh gives a container. The last probe before the platform
    # restarts the container runs earlier: the first after initialDelay, then one every interval.
    shell.append("KIT_PROBE_BUDGET[%s]=%d" % (key, delay + fails * every))
    shell.append("KIT_PROBE_LAST[%s]=%d" % (key, delay + (fails - 1) * every))
write(os.path.join(work, tag + ".sh"), "\n".join(shell) + "\n")
write(values_file, json.dumps(made))
write(os.path.join(work, "secrets"), "\n".join(made.values()) + "\n")
PY
}

declare -A KIT_MEM=() KIT_CPU=() KIT_VOLS=() KIT_VERSION=() KIT_PROBE_TYPE=() KIT_PROBE_PORT=() KIT_PROBE_PATH=() \
  KIT_PROBE_TIMEOUT=() KIT_PROBE_BUDGET=() KIT_PROBE_LAST=()
# val TAG SERVICE VARIABLE: the value the service's env file gives the variable.
val() { sed -n "s/^$3=//p" "$WORK/$1.$2.env" | head -n 1; }
# secrets_in TEXT: how many of the run's made-up passwords TEXT holds.
secrets_in() {
  local n=0 s
  while IFS= read -r s; do
    [ -n "$s" ] && [[ "$1" == *"$s"* ]] && n=$((n + 1))
  done < "$WORK/secrets"
  echo "$n"
}

# --- containers -------------------------------------------------------------------------------------------------------

c_of() { echo "${PREFIX}$1"; }
# vol_of CASE NAME: the Docker volume a case uses for the manifest's volume NAME.
vol_of() { echo "${PREFIX}$1-$2"; }

# kit_volumes CASE: the manifest's five volumes for a case, as new disks.
kit_volumes() {
  local svc spec
  for svc in "${SERVICES[@]}"; do
    for spec in ${KIT_VOLS[$svc]}; do
      ls_new_disk "$(vol_of "$1" "${spec%%:*}")" || return 1
    done
  done
}

# kit_run CASE TAG SERVICE IMAGE [docker run options...]: one of the kit's containers with the manifest's settings
# (the env file of TAG), memory and CPU, on the case's volumes, under the service's name on the test's network.
kit_run() {
  local c="$1" tag="$2" svc="$3" image="$4" spec mounts=()
  shift 4
  for spec in ${KIT_VOLS[$svc]}; do mounts+=(-v "$(vol_of "$c" "${spec%%:*}"):${spec#*:}"); done
  docker rm -f "$(c_of "$svc")" >/dev/null 2>&1
  docker run -d --pull=never --name "$(c_of "$svc")" --network "$NET" --network-alias "$svc" \
    --memory "${KIT_MEM[$svc]}" --memory-swap "${KIT_MEM[$svc]}" --cpus "${KIT_CPU[$svc]}" \
    --env-file "$WORK/$tag.$svc.env" "${mounts[@]}" "$@" "$image" >/dev/null
}

# started_at SERVICE: when the container started, in seconds since the epoch.
started_at() { date -d "$(docker inspect --format '{{.State.StartedAt}}' "$(c_of "$1")" 2>/dev/null)" +%s 2>/dev/null; }

# probe SERVICE: the service's own probe, once, as the platform runs it: an HTTP probe from another container on
# the network passes on a status of 200 to 399, a Command probe on exit status 0 inside the container.
probe() {
  local svc="$1" status
  if [ "${KIT_PROBE_TYPE[$svc]}" = HTTP ]; then
    status="$(docker exec "$PROBER" wget -S -O /dev/null -T "${KIT_PROBE_TIMEOUT[$svc]}" \
      "http://$svc:${KIT_PROBE_PORT[$svc]}${KIT_PROBE_PATH[$svc]}" 2>&1 | sed -n 's/^ *HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | head -n 1)"
    [ -n "$status" ] && [ "$status" -ge 200 ] && [ "$status" -lt 400 ]
  else
    timeout "${KIT_PROBE_TIMEOUT[$svc]}" docker exec "$(c_of "$svc")" /bin/sh -c "${KIT_PROBE_PATH[$svc]}" >/dev/null 2>&1
  fi
}

# wait_probe SERVICE: probes once a second until the probe passes, and prints how many seconds after the
# container's start that was. Status 1 when the container stops or 600 seconds pass first.
wait_probe() {
  local svc="$1" begun i
  begun="$(started_at "$svc")"
  for ((i = 0; i < 600; i++)); do
    if probe "$svc"; then echo $(($(date +%s) - begun)); return 0; fi
    sc_running "$(c_of "$svc")" || return 1
    sleep 1
  done
  return 1
}

# check_probe LABEL SERVICE LIMIT_NAME: the container passes its probe within its budget (LIMIT_NAME is BUDGET), or
# before the last probe the platform runs before a restart (LAST). Prints the time.
check_probe() {
  local label="$1" svc="$2" limit took
  if [ "$3" = LAST ]; then limit="${KIT_PROBE_LAST[$svc]}"; else limit="${KIT_PROBE_BUDGET[$svc]}"; fi
  if took="$(wait_probe "$svc")" && [ "$took" -le "$limit" ]; then
    pass "$label (after $took s, limit $limit s)"
  else
    fail "$label (after ${took:-no answer} s, limit $limit s)"
    docker logs --tail 15 "$(c_of "$svc")" 2>&1 | sed 's/^/       | /'
  fi
}

# watch_probes FILE SERVICE...: probes the services once a second and appends "<service> ok|fail" lines to FILE,
# until FILE.stop exists. Run it in the background.
watch_probes() {
  local file="$1" svc
  shift
  while [ ! -e "$file.stop" ]; do
    for svc in "$@"; do
      if probe "$svc"; then echo "$svc ok"; else echo "$svc fail"; fi >> "$file"
    done
    sleep 1
  done
}
# longest_gap FILE SERVICE: "<passes> <longest run of failed probes>" for one service in a watch_probes file.
longest_gap() {
  awk -v s="$2" '$1 == s && $2 == "ok" { good++; run = 0 } $1 == s && $2 == "fail" { run++; if (run > worst) worst = run }
    END { printf "%d %d", good + 0, worst + 0 }' "$1"
}

ls_real() { [ "$(ls_pid1 "$(c_of limesurvey)")" = apache2 ] && [ "$(ls_http "$(c_of limesurvey)" / -H 'Host: localhost')" = 200 ]; }
sc_real() { sc_apache_serves "$(c_of suitecrm)"; }
# waits_for_repair SERVICE: 0 when the app found a site that it must not start. Its container then stays up with
# the stand-in's "needs attention" page and passes its probe, and the app itself never answers.
waits_for_repair() { docker logs "$(c_of "$1")" 2>&1 | grep -qF "The container stays up so that the site can be repaired"; }
# wait_real SECONDS: 0 once both apps themselves answer (Apache is PID 1 in each, not the stand-in). 2 when a
# container stopped, 3 when one waits for a repair, 1 when the time ran out.
wait_real() {
  local deadline=$((SECONDS + $1))
  while [ "$SECONDS" -lt "$deadline" ]; do
    ls_real && sc_real && return 0
    sc_running "$(c_of limesurvey)" && sc_running "$(c_of suitecrm)" || return 2
    if waits_for_repair limesurvey || waits_for_repair suitecrm; then return 3; fi
    sleep 1
  done
  return 1
}
show_logs() {
  local svc
  for svc in "$@"; do
    echo "       last lines of $svc:"
    docker logs --tail 20 "$(c_of "$svc")" 2>&1 | sed 's/^/       | /'
  done
}

# --- the two databases --------------------------------------------------------------------------------------------------

# lsql QUERY: rows from LimeSurvey's database. csql QUERY: rows from SuiteCRM's. Tab-separated, no header. The
# password is in the client's environment.
lsql() { docker exec -e "MYSQL_PWD=$LS_DB_PW" "$(c_of limesurvey-mariadb)" mariadb -h 127.0.0.1 -u limesurvey limesurvey -N -B -e "$1" 2>&1; }
csql() { docker exec -e "MYSQL_PWD=$CRM_DB_PW" "$(c_of suitecrm-mariadb)" mariadb -h 127.0.0.1 -u suitecrm suitecrm -N -B -e "$1" 2>&1; }
plugin_id() { lsql "SELECT id FROM lime_plugins WHERE name = 'SuiteCRMIntegration'"; }
# setting KEY: the stored value of one of the plugin's own settings.
setting() { lsql "SELECT value FROM lime_plugin_settings WHERE \`key\` = '$1' AND model IS NULL AND plugin_id = (SELECT id FROM lime_plugins WHERE name = 'SuiteCRMIntegration')"; }
qid() { lsql "SELECT qid FROM lime_questions WHERE sid = $SID AND title = '$1' AND parent_qid = 0"; }
gid() { lsql "SELECT gid FROM lime_questions WHERE sid = $SID AND title = '$1' AND parent_qid = 0"; }
# field QUESTION_CODE: the name of the question's form field. LimeSurvey 7 names it after the question, LimeSurvey 6
# after the survey, the group and the question.
field() { if [ "$LS_MAJOR" -ge 7 ]; then echo "Q$(qid "$1")"; else echo "${SID}X$(gid "$1")X$(qid "$1")"; fi; }
# mappings_shape: what tells the plugin's current table of mappings from the earlier one.
mappings_shape() {
  lsql "SELECT CONCAT(
      (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'lime_survey_crm_mappings' AND column_name = 'transform_rule'), ' ',
      (SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'lime_survey_crm_mappings' AND index_name = 'unique_question_field_mapping'), ' ',
      (SELECT COUNT(DISTINCT index_name) FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'lime_survey_crm_mappings' AND index_name = 'unique_question_mapping'))"
}

# --- LimeSurvey over HTTP -----------------------------------------------------------------------------------------------

# install_helpers: puts the test's HTTP helpers into the LimeSurvey container (again after each new container).
install_helpers() {
  local a
  a="$(c_of limesurvey)"
  docker exec -i "$a" sh -c 'cat > /tmp/clv-web.sh && chmod 755 /tmp/clv-web.sh' <<'SH'
#!/bin/bash
# clv-web.sh login USER JAR        signs in to LimeSurvey's admin (the password is in T_PASS)
# clv-web.sh get JAR PATH          GET with the session; prints the HTTP status, the body goes to /tmp/clv-web.body
# clv-web.sh post JAR PATH k=v...  POST with the session and its CSRF token; prints the HTTP status
B=http://127.0.0.1:8080
H=(-H 'Host: localhost')
case "$1" in
  login)
    curl -s "${H[@]}" -c "$3" -b "$3" -o /tmp/clv-web.body "$B/index.php/admin/authentication/sa/login"
    tok="$(grep -o '<input[^>]*name="YII_CSRF_TOKEN"[^>]*>' /tmp/clv-web.body | head -n 1 | sed -E 's/.*value="([^"]*)".*/\1/')"
    curl -s "${H[@]}" -c "$3" -b "$3" -o /dev/null --data-urlencode "YII_CSRF_TOKEN=$tok" --data-urlencode authMethod=Authdb \
      --data-urlencode "user=$2" --data-urlencode "password=$T_PASS" --data-urlencode loginlang=default \
      --data-urlencode action=login --data-urlencode login_submit=login "$B/index.php/admin/authentication/sa/login"
    ;;
  get) curl -s "${H[@]}" -c "$2" -b "$2" -o /tmp/clv-web.body -w '%{http_code}' "$B$3" ;;
  post)
    jar="$2"; path="$3"; shift 3
    # The token is kept in the session and printed into every admin page as a hidden field.
    curl -s "${H[@]}" -c "$jar" -b "$jar" -o /tmp/clv-web.body "$B/index.php/admin/pluginmanager/sa/index"
    tok="$(grep -o '<input[^>]*name="YII_CSRF_TOKEN"[^>]*>' /tmp/clv-web.body | head -n 1 | sed -E 's/.*value="([^"]*)".*/\1/')"
    args=(--data-urlencode "YII_CSRF_TOKEN=$tok")
    for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    curl -s "${H[@]}" -c "$jar" -b "$jar" -o /tmp/clv-web.body -w '%{http_code}' "${args[@]}" "$B$path"
    ;;
esac
SH
  docker exec -i "$a" sh -c 'cat > /tmp/clv-submit.php' <<'PHP'
<?php
// Submits one all-in-one LimeSurvey page over HTTP as a browser would: php clv-submit.php <sid> key=value ...
$sid = $argv[1];
$base = 'http://127.0.0.1:8080';
$answers = [];
foreach (array_slice($argv, 2) as $kv) { [$k, $v] = explode('=', $kv, 2); $answers[$k] = $v; }
$jar = tempnam('/tmp', 'clvj');
function req($url, $jar, $post = null) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_COOKIEJAR => $jar, CURLOPT_COOKIEFILE => $jar,
        CURLOPT_FOLLOWLOCATION => true, CURLOPT_TIMEOUT => 120, CURLOPT_HTTPHEADER => ['Host: localhost']]);
    if ($post !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, $post); }
    return (string) curl_exec($ch);
}
$html = req("$base/index.php/$sid?lang=en&newtest=Y", $jar);
preg_match_all('#<input\b[^>]*type=["\']hidden["\'][^>]*>#', $html, $m);
$pairs = [];
foreach ($m[0] as $tag) {
    if (!preg_match('#name=["\']([^"\']*)["\']#', $tag, $n) || array_key_exists($n[1], $answers)) { continue; }
    $v = preg_match('#value=["\']([^"\']*)["\']#', $tag, $vv) ? html_entity_decode($vv[1]) : '';
    // The browser's script marks which questions are shown. Without a script every question counts as shown, and
    // LimeSurvey works out for itself which ones apply.
    if (strpos($n[1], 'relevance') === 0) { $v = '1'; }
    $pairs[] = urlencode($n[1]) . '=' . urlencode($v);
}
foreach ($answers as $k => $v) { $pairs[] = urlencode($k) . '=' . urlencode($v); }
$pairs[] = 'move=movesubmit';
$out = req("$base/index.php/$sid", $jar, implode('&', $pairs));
unlink($jar);
echo stripos(strip_tags($out), 'Thank you') !== false ? "submitted\n" : "not submitted\n";
PHP
  docker exec -i "$a" sh -c 'cat > /tmp/clv-rpc.php' <<'PHP'
<?php
// php clv-rpc.php <method> <sid>: a RemoteControl call as the admin (LS_USER, LS_PASS).
$url = 'http://127.0.0.1:8080/index.php/admin/remotecontrol';
function call($url, $method, $params) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 120,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Host: localhost'],
        CURLOPT_POSTFIELDS => json_encode(['method' => $method, 'params' => $params, 'id' => 1])]);
    $j = json_decode((string) curl_exec($ch), true);
    return $j['result'] ?? null;
}
$key = call($url, 'get_session_key', [getenv('LS_USER'), getenv('LS_PASS')]);
echo json_encode(call($url, $argv[1], [$key, (int) $argv[2]])), "\n";
call($url, 'release_session_key', [$key]);
PHP
}
web() { docker exec -e "T_PASS=${T_PASS:-}" "$(c_of limesurvey)" /tmp/clv-web.sh "$@"; }
body() { docker exec "$(c_of limesurvey)" cat /tmp/clv-web.body 2>/dev/null; }
direct() { printf '/index.php/plugins/direct?plugin=SuiteCRMIntegration&function=%s&surveyId=%s&questionId=%s&module=Leads' "$1" "$SID" "$2"; }

# activate_demo: the admin's step before anyone can answer the demo survey. It is activated through RemoteControl,
# which is switched on for the call and back off, and set to show every question on one page, so that one POST
# submits a response.
activate_demo() {
  local out
  lsql "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('RPCInterface', 'json') ON DUPLICATE KEY UPDATE stg_value = 'json';
    UPDATE lime_surveys SET format = 'A' WHERE sid = $SID" >/dev/null
  out="$(docker exec -e "LS_USER=$LS_ADMIN" -e "LS_PASS=$ADMIN_PW" "$(c_of limesurvey)" php /tmp/clv-rpc.php activate_survey "$SID" 2>&1)"
  lsql "UPDATE lime_settings_global SET stg_value = 'off' WHERE stg_name = 'RPCInterface'" >/dev/null
  [[ "$out" == *'"status":"OK"'* ]]
}
# submit_sales MARKER [COMPANY]: a respondent's sales inquiry whose answers carry MARKER. Without COMPANY the
# respondent leaves the company empty.
submit_sales() {
  docker exec "$(c_of limesurvey)" php /tmp/clv-submit.php "$SID" "$(field requestType)=SALES" "$(field firstName)=Zebulon-$1" \
    "$(field lastName)=Quillfeather-$1" "$(field email)=zeb-$1@example.invalid" "$(field company)=${2:-}" \
    "$(field productInterest)=CRM" 2>&1
}
# submit_support MARKER: a respondent's support request.
submit_support() {
  docker exec "$(c_of limesurvey)" php /tmp/clv-submit.php "$SID" "$(field requestType)=SUPP" "$(field firstName)=Yolanda-$1" \
    "$(field lastName)=Underhill-$1" "$(field email)=yol-$1@example.invalid" "$(field company)=Borealis-$1" \
    "$(field issueTitle)=Printer on fire $1" "$(field issueCategory)=TECH" "$(field issuePriority)=High" \
    "$(field issueDescription)=It burns $1" 2>&1
}
# response_of LAST_NAME: the id of the newest response whose last-name answer is LAST_NAME, or 0. LimeSurvey 7
# keeps a survey's responses in lime_responses_<sid>, LimeSurvey 6 in lime_survey_<sid>.
response_of() {
  local table="lime_responses_$SID" id
  [ "$LS_MAJOR" -ge 7 ] || table="lime_survey_$SID"
  id="$(lsql "SELECT id FROM $table WHERE \`$(field lastName)\` = '$1' ORDER BY id DESC LIMIT 1")"
  case "$id" in '' | *[!0-9]*) echo 0 ;; *) echo "$id" ;; esac
}
# sync_of LAST_NAME COLUMNS [MODULE]: COLUMNS of the newest sync log row for that respondent's response (and for
# MODULE, when given). The plugin keeps what it sent only for a sync that failed, so a row is found by its response.
sync_of() {
  lsql "SELECT $2 FROM lime_survey_crm_sync_log WHERE survey_id = $SID AND response_id = $(response_of "$1")${3:+ AND crm_module = '$3'} ORDER BY id DESC LIMIT 1"
}
# wait_sync LAST_NAME: until the plugin's sync log has a row for that respondent's response, at most 30 s.
wait_sync() {
  local i
  for ((i = 0; i < 30; i++)); do
    [ -n "$(sync_of "$1" id)" ] && return 0
    sleep 1
  done
  return 1
}
leads_of() { csql "SELECT COUNT(*) FROM leads WHERE last_name = 'Quillfeather-$1' AND deleted = 0"; }
# lead_row MARKER: the lead a sales inquiry with MARKER made: first name, last name, company, product interest, email.
lead_row() {
  csql "SELECT CONCAT_WS('|', l.first_name, l.last_name, IFNULL(l.account_name, ''), l.lead_source_description,
      (SELECT ea.email_address FROM email_addr_bean_rel r JOIN email_addresses ea ON ea.id = r.email_address_id
        WHERE r.bean_id = l.id AND r.bean_module = 'Leads' AND r.deleted = 0 LIMIT 1))
    FROM leads l WHERE l.last_name = 'Quillfeather-$1' AND l.deleted = 0"
}
# check_lead LABEL MARKER [COMPANY]: a submitted sales inquiry became exactly one lead with the answers, and the sync
# log says so.
check_lead() {
  local label="$1" m="$2"
  wait_sync "Quillfeather-$m" || :
  assert_eq "$label: SuiteCRM has one lead with the respondent's answers" \
    "Zebulon-$m|Quillfeather-$m|${3:-}|CRM|zeb-$m@example.invalid" "$(lead_row "$m")"
  assert_eq "$label: LimeSurvey's sync log records it as sent, with the lead's id in SuiteCRM" \
    "success $(csql "SELECT id FROM leads WHERE last_name = 'Quillfeather-$m' AND deleted = 0")" \
    "$(sync_of "Quillfeather-$m" "CONCAT(sync_status, ' ', crm_record_id)" Leads)"
}

# check_mappings LABEL: the plugin's table of mappings has the plugin's current shape, and the classic question
# editor's save works for a question with two CRM fields, one of them with a rule. The admin is signed in.
check_mappings() {
  local label="$1" q code
  assert_eq "$label: the table of mappings has the transform_rule column and the key that allows several fields per question" \
    "1 1 0" "$(mappings_shape)"
  q="$(qid jobTitle)"
  code="$(web post /tmp/admin.jar "$(direct actionSaveMappings "$q")" \
    'mappings=[{"module":"Leads","field":"title","label":"Title","type":"varchar","transformRule":"trim"},{"module":"Leads","field":"department","label":"Department","type":"varchar","transformRule":""}]')"
  assert_eq "$label: saving a question's two mappings answers 200" "200" "$code"
  assert_contains "$label: and says both were saved" "$(body)" '"success":true'
  assert_eq "$label: both rows are stored, the rule with its field" "department: title:trim" \
    "$(lsql "SELECT CONCAT(crm_field_name, ':', IFNULL(transform_rule, '')) FROM lime_survey_crm_mappings WHERE question_id = $q ORDER BY crm_field_name" | xargs)"
}

# ops_whoami SERVICE: what `id -un` prints for clouve-ops signed in over SSH to the service from the LimeSurvey
# container, as the AI Assistant signs in from its own. Nothing when the sign-in fails. The password is in T_PW.
ops_whoami() {
  # shellcheck disable=SC2016  # the script is for the bash in the container
  docker exec -e "T_PW=$OPS_PW" -e "T_HOST=$1" "$(c_of limesurvey)" bash -c '
    d="$(mktemp -d)"; printf "#!/bin/sh\nprintf \"%%s\\n\" \"\$T_PW\"\n" > "$d/askpass"; chmod 700 "$d/askpass"
    SSH_ASKPASS="$d/askpass" SSH_ASKPASS_REQUIRE=force timeout 30 ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
      "clouve-ops@$T_HOST" id -un </dev/null 2>/dev/null; rm -rf "$d"'
}
# holders SERVICE: the names of the processes that have CLOUVE_OPS_PASSWORD in their environment. A process of
# another user, or one that changed its user, keeps its environment from root inside the container too, so a small
# container of the test's own reads them: it shares the service's process list and may trace. A database container's
# PID 1 is tini, which was started with the variable and runs nothing but mariadbd. "unreadable" stands for a
# process whose environment could not be read.
holders() {
  # shellcheck disable=SC2016  # the script is for the sh in the container
  docker run --rm --pid "container:$(c_of "$1")" --cap-add SYS_PTRACE --network none "$SHAPER" sh -c 'me=$$
    for p in /proc/[0-9]*; do
      [ "${p#/proc/}" = "$me" ] && continue
      [ "$(sed -n "s/^PPid:[[:space:]]*//p" "$p/status" 2>/dev/null)" = "$me" ] && continue
      if e="$(tr "\0" "\n" < "$p/environ" 2>/dev/null)"; then
        printf "%s\n" "$e" | grep -q "^CLOUVE_OPS_PASSWORD=" && cat "$p/comm" 2>/dev/null
      elif [ -e "$p/comm" ]; then
        echo unreadable
      fi
    done | sort -u | xargs' 2>/dev/null
}
sshd_count() { docker exec "$(c_of "$1")" sh -c 'n=0; for p in /proc/[0-9]*; do [ "$(cat "$p/comm" 2>/dev/null)" = sshd ] && n=$((n + 1)); done; echo $n'; }

# --- images -------------------------------------------------------------------------------------------------------------

# new_images: the four current images, built from this checkout when --image didn't name them.
new_images() {
  local name
  for name in limesurvey-mariadb limesurvey; do
    [ -n "${NEW_IMAGE[$name]:-}" ] && LS_IMAGE["$name"]="${NEW_IMAGE[$name]}"
    ls_image "$name" || return 1
    NEW_IMAGE[$name]="${LS_IMAGE[$name]}"
  done
  for name in suitecrm-mariadb suitecrm; do
    [ -n "${NEW_IMAGE[$name]:-}" ] && SC_IMAGE["$name"]="${NEW_IMAGE[$name]}"
    sc_image "$name" || return 1
    NEW_IMAGE[$name]="${SC_IMAGE[$name]}"
  done
}

# old_images: the old kit's images. LimeSurvey 6.16.1 is this repository's image at OLD_COMMIT with FROM pointed at
# the upstream tag that shipped 6.16.1 (the commit says 6-apache, which has moved on), SuiteCRM 8.9.1 the one at
# the same commit, and the databases the MariaDB lines the installs were made with.
old_images() {
  local dir log
  if [ -z "${OLD_IMAGE[limesurvey]:-}" ]; then
    dir="$WORK/old-limesurvey"
    mkdir -p "$dir"
    git -C "$REPO_DIR" archive "$OLD_COMMIT" apps/limesurvey/image 2>/dev/null | tar -x -C "$dir" || return 1
    sed -i "s#^FROM martialblog/limesurvey:6-apache\$#FROM $OLD_LS_BASE#" "$dir/apps/limesurvey/image/Dockerfile"
    grep -qx "FROM $OLD_LS_BASE" "$dir/apps/limesurvey/image/Dockerfile" || return 1
    OLD_IMAGE[limesurvey]="${PREFIX}limesurvey-old:$OLD_LS"
    if log="$(docker build -t "${OLD_IMAGE[limesurvey]}" "$dir/apps/limesurvey/image" 2>&1)"; then
      LS_BUILT+=("${OLD_IMAGE[limesurvey]}")
    else
      printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
      return 1
    fi
  fi
  [ -n "${OLD_IMAGE[suitecrm]:-}" ] && SC_IMAGE["suitecrm-old"]="${OLD_IMAGE[suitecrm]}"
  sc_image suitecrm-old || return 1
  OLD_IMAGE[suitecrm]="${SC_IMAGE[suitecrm-old]}"
  [ -n "${OLD_IMAGE[suitecrm-mariadb]:-}" ] && SC_IMAGE["suitecrm-mariadb-old"]="${OLD_IMAGE[suitecrm-mariadb]}"
  sc_image suitecrm-mariadb-old || return 1
  OLD_IMAGE[suitecrm-mariadb]="${SC_IMAGE[suitecrm-mariadb-old]}"
  OLD_IMAGE[limesurvey-mariadb]="${OLD_IMAGE[limesurvey-mariadb]:-mariadb:11.8}"
  docker image inspect "${OLD_IMAGE[limesurvey]}" "${OLD_IMAGE[limesurvey-mariadb]}" >/dev/null 2>&1
}

# ======================================================================================================================
# The bundle's files
# ======================================================================================================================
if wants files; then
  echo "The bundle's files"
  git -C "$REPO_DIR" show "$OLD_COMMIT:bundles/crm-kit/clv-docker-compose.yml" > "$WORK/old-manifest.yml" 2>/dev/null
  report="$(python3 -I - "$WORK/old-manifest.yml" "$MANIFEST" "$BUNDLE/docker-compose.yml" "$REPO_DIR/apps/limesurvey/clv-docker-compose.yml" \
    "$REPO_DIR/apps/suitecrm/clv-docker-compose.yml" <<'PY'
import sys
import yaml

old, new, compose, alone, alone_crm = (yaml.safe_load(open(p)) for p in sys.argv[1:6])
out = []
def line(key, ok, detail=""):
    out.append("%s=%s%s" % (key, "ok" if ok else "NO", (" " + detail) if detail and not ok else ""))

same = []
for name in sorted(set(old["services"]) | set(new["services"])):
    a, b = old["services"].get(name) or {}, new["services"].get(name) or {}
    for key in sorted(set(a) | set(b)):
        if key == "x-clouve-bundle-metadata":
            ma, mb = dict(a.get(key) or {}), dict(b.get(key) or {})
            for changed in ("appVersion", "appDescription"):
                ma.pop(changed, None); mb.pop(changed, None)
            if ma != mb: same.append("%s.%s" % (name, key))
        elif a.get(key) != b.get(key):
            same.append("%s.%s" % (name, key))
if old.get("volumes") != new.get("volumes"): same.append("volumes")
extra = sorted(set(new) - set(old) - {"x-clouve-agent"})
line("unchanged", not same and not extra, "changed: %s" % ", ".join(same + extra))
meta = lambda s: (new["services"].get(s) or {}).get("x-clouve-bundle-metadata") or {}
line("versions", str(meta("limesurvey").get("appVersion")) == "7.10.0" and str(meta("suitecrm").get("appVersion")) == "8.10.2",
     "limesurvey %s, suitecrm %s" % (meta("limesurvey").get("appVersion"), meta("suitecrm").get("appVersion")))
agent = new.get("x-clouve-agent") or {}
url = str((agent.get("skills") or {}).get("url") or "")
line("agent", agent.get("enabled") is True and url.endswith("?plugins=limesurvey,suitecrm")
     and (agent.get("advanced") or {}).get("sidecarPullTimeout") == 600, "x-clouve-agent: %r" % (agent,))
services = compose.get("services") or {}
four = ["limesurvey", "limesurvey-mariadb", "suitecrm", "suitecrm-mariadb"]
passwords = {str((services.get(s) or {}).get("environment", {}).get("CLOUVE_OPS_PASSWORD", "")) for s in four + ["magneto-agent"]}
line("ops", len(passwords) == 1 and "" not in passwords, "CLOUVE_OPS_PASSWORD differs or is missing on a service")
env = (services.get("magneto-agent") or {}).get("environment") or {}
line("compose-agent", str(env.get("MAGNETO_AGENT_SKILLS", "")).endswith("?plugins=limesurvey,suitecrm")
     and sorted(str(env.get("CLV_SIDECAR_HOSTS", "")).split(",")) == sorted(four)
     and sorted(str(env.get("CLV_SIDECAR_NAMESPACES", "")).split(",")) == sorted(four),
     "magneto-agent: skills %r, hosts %r" % (env.get("MAGNETO_AGENT_SKILLS"), env.get("CLV_SIDECAR_HOSTS")))
# LimeSurvey sends no email by itself: invitations and reminders go through a mail server the customer sets up. The
# standalone listing says so, and the kit's text for LimeSurvey must not promise more than that one does.
own_mail = "through your own mail server"
describe = lambda doc, svc="limesurvey": str(((doc["services"].get(svc) or {}).get("x-clouve-bundle-metadata") or {}).get("appDescription", ""))
line("mail", own_mail not in describe(alone) or "invitations" not in describe(new) or own_mail in describe(new),
     "the kit's LimeSurvey description offers invitations without \"%s\"" % own_mail)
# The same for SuiteCRM. Its standalone listing says that a change to who can sign in waits for a yes, and it
# doesn't promise to find out why a page is slow.
kit_crm, own_crm = describe(new, "suitecrm"), describe(alone_crm, "suitecrm")
sign_in = "who can sign in"
missing = []
if sign_in in own_crm and "adds users" in kit_crm and sign_in not in kit_crm:
    missing.append("it adds users without saying that a change to %s waits for a yes" % sign_in)
if "slow" in kit_crm and "slow" not in own_crm:
    missing.append("it says \"slow\", which the standalone listing doesn't")
line("crm", not missing, "the kit's SuiteCRM description: %s" % "; ".join(missing))
print("\n".join(out))
PY
)" || report=""
  for key in unchanged versions agent ops compose-agent mail crm; do
    case "$key" in
      unchanged) label="the manifest keeps every variable, capacity, volume, probe and name of the kit at ${OLD_COMMIT:0:7}" ;;
      versions) label="its appVersions are LimeSurvey 7.10.0 and SuiteCRM 8.10.2" ;;
      agent) label="it offers the AI Assistant with the limesurvey and suitecrm skills and a 600 s sidecar wait" ;;
      ops) label="docker-compose.yml gives the four services and the agent one CLOUVE_OPS_PASSWORD" ;;
      compose-agent) label="docker-compose.yml has the magneto-agent service with both skills and the four siblings" ;;
      mail) label="its LimeSurvey description says, as the standalone listing does, that invitations go through the customer's own mail server" ;;
      crm) label="its SuiteCRM description promises nothing that the standalone listing qualifies or leaves out (who can sign in, a slow page)" ;;
    esac
    got="$(sed -n "s/^$key=//p" <<< "$report")"
    if [ "$got" = ok ]; then pass "$label"; else fail "$label"; [ -n "$got" ] && printf '       %s\n' "${got#NO }"; fi
  done
  # The listing's own description, which the publish wizard takes: a short one of at most 120 characters, and a
  # long one of at most 1,000 that keeps the rules for what a listing may say about the AI Assistant's price and usage.
  short="$(sed -n 's/^Short: //p' "$BUNDLE/description.txt")"
  if [ -n "$short" ] && [ "${#short}" -le 120 ]; then pass "description.txt has a short description of at most 120 characters"; else
    fail "description.txt has a short description of at most 120 characters (it has ${#short})"; fi
  long="$(sed -n 's/^Extended: //p' "$BUNDLE/description.txt")"
  if [ -n "$long" ] && [ "${#long}" -le 1000 ]; then pass "description.txt has a long description of at most 1,000 characters"; else
    fail "description.txt has a long description of at most 1,000 characters (it has ${#long})"; fi
  if bash "$SCRIPT_DIR/listing-ai-copy.test.sh" --text "$(cat "$BUNDLE/description.txt")" >/dev/null 2>&1; then
    pass "description.txt keeps the listing rules for the AI Assistant's price and usage"
  else
    fail "description.txt keeps the listing rules for the AI Assistant's price and usage (bash tests/listing-ai-copy.test.sh --text shows which)"
  fi
  echo
fi

wants new || wants upgrade || wants standin || wants faulty || finish

# ======================================================================================================================
# Containers
# ======================================================================================================================
ls_need_docker
ls_remove_all    # leftovers of a run that was killed
echo "The images"
if ! new_images; then
  fail "the four images build or are on this machine"
  exit 2
fi
pass "limesurvey ${NEW_IMAGE[limesurvey]}, limesurvey-mariadb ${NEW_IMAGE[limesurvey-mariadb]}, suitecrm ${NEW_IMAGE[suitecrm]}, suitecrm-mariadb ${NEW_IMAGE[suitecrm-mariadb]}"
kit_settings new "$MANIFEST" || { fail "the manifest's settings can be read"; exit 2; }
# shellcheck source=/dev/null
. "$WORK/new.sh"
LS_DB_PW="$(val new limesurvey DB_PASSWORD)"
CRM_DB_PW="$(val new suitecrm DATABASE_PASSWORD)"
ADMIN_PW="$(val new limesurvey ADMIN_PASSWORD)"
LS_ADMIN="$(val new limesurvey ADMIN_USER)"
CRM_ADMIN="$(val new suitecrm SUITECRM_ADMIN_USER)"
OPS_PW="ops-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
printf 'CLOUVE_OPS_PASSWORD=%s\n' "$OPS_PW" > "$WORK/ops.env"
chmod 600 "$WORK/ops.env"
printf '%s\n' "$OPS_PW" >> "$WORK/secrets"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$PROBER" --network "$NET" --memory 64m "$SHAPER" sleep 86400 >/dev/null

# ======================================================================================================================
# A new kit
# ======================================================================================================================
if wants new; then
  echo
  echo "A new kit, on new disks"
  LS_MAJOR=7
  kit_volumes new || fail "the five volumes are made as new disks"
  for svc in "${SERVICES[@]}"; do
    kit_run new new "$svc" "${NEW_IMAGE[$svc]}" --env-file "$WORK/ops.env" || fail "$svc starts"
  done
  begun=$SECONDS
  for svc in "${SERVICES[@]}"; do
    check_probe "$svc passes its own probe (${KIT_PROBE_TYPE[$svc]} :${KIT_PROBE_PORT[$svc]} ${KIT_PROBE_PATH[$svc]})" "$svc" BUDGET
  done
  rc=0; wait_real 600 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "LimeSurvey and SuiteCRM themselves answer, $((SECONDS - begun)) s after the four containers started"
  else
    fail "LimeSurvey and SuiteCRM themselves answer"
    show_logs limesurvey suitecrm
    finish
  fi
  assert_eq "LimeSurvey is the manifest's version" "${KIT_VERSION[limesurvey]}" "$(ls_code_version "$(c_of limesurvey)" | cut -d' ' -f1)"
  assert_eq "SuiteCRM is the manifest's version" "${KIT_VERSION[suitecrm]}" "$(docker exec "$(c_of suitecrm)" cat /var/www/html/VERSION 2>/dev/null)"
  bad=""
  for svc in "${SERVICES[@]}"; do probe "$svc" || bad="$bad $svc"; done
  assert_eq "each container still passes its probe, and none restarted" " 0 0 0 0" \
    "$bad$(for svc in "${SERVICES[@]}"; do printf ' %s' "$(docker inspect --format '{{.RestartCount}}' "$(c_of "$svc")")"; done)"

  echo
  echo "The plugin and the demo survey"
  assert_eq "the plugin is registered and on" "1" "$(lsql "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  assert_eq "its SuiteCRM address and admin name are the manifest's" "\"$(val new limesurvey SUITECRM_URL)\" \"$CRM_ADMIN\"" \
    "$(setting suitecrm_url) $(setting suitecrm_admin_user)"
  stored="$(lsql "SELECT value FROM lime_plugin_settings WHERE plugin_id = $(plugin_id)")"
  if [ "$(setting suitecrm_admin_password | wc -c)" -gt 20 ] && [ "$(setting suitecrm_db_password | wc -c)" -gt 20 ]; then
    pass "it stores SuiteCRM's admin password and database password"
  else
    fail "it stores SuiteCRM's admin password and database password"
  fi
  assert_eq "and none of its settings holds a password in clear text" "0" "$(secrets_in "$stored")"
  assert_eq "the demo survey is there, with its link to SuiteCRM on" "1 \"1\"" \
    "$(lsql "SELECT COUNT(*) FROM lime_surveys WHERE sid = $SID") $(lsql "SELECT value FROM lime_plugin_settings WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = '$SID'")"
  install_helpers
  anon_bad=""
  for f in "${ENDPOINTS[@]}"; do
    code="$(ls_http "$(c_of limesurvey)" "$(direct "$f" "$(qid firstName)")" -H 'Host: localhost')"
    [ "$code" = 401 ] || anon_bad="$anon_bad $f=$code"
  done
  assert_eq "each of the plugin's ${#ENDPOINTS[@]} endpoints answers 401 to a caller who is not signed in" "" "$anon_bad"
  T_PASS="$ADMIN_PW" web login "$LS_ADMIN" /tmp/admin.jar
  check_mappings "a new kit"

  echo
  echo "A response becomes a lead"
  if activate_demo; then pass "the admin activates the demo survey"; else fail "the admin activates the demo survey"; fi
  M=n1x4471
  assert_eq "a respondent's sales inquiry is completed over HTTP" "submitted" "$(submit_sales "$M" "Acme-$M")"
  check_lead "the sales inquiry" "$M" "Acme-$M"
  assert_eq "the sales inquiry made no case" "0" "$(csql "SELECT COUNT(*) FROM cases WHERE deleted = 0")"
  assert_eq "the plugin's OAuth2 client is in SuiteCRM, with the password grant" "password" \
    "$(csql "SELECT allowed_grant_type FROM oauth2clients WHERE name = 'LimeSurvey Integration' AND deleted = 0")"
  hash="$(csql "SELECT secret FROM oauth2clients WHERE name = 'LimeSurvey Integration' AND deleted = 0")"
  if [ -n "$hash" ] && [ "$(setting oauth_client_secret | tr -d '"' | tr -d '\n' | sha256sum | cut -d' ' -f1)" != "$hash" ]; then
    pass "LimeSurvey does not keep the client's secret in clear text"
  else
    fail "LimeSurvey does not keep the client's secret in clear text"
  fi
  M2=n2x9026
  assert_eq "a respondent's support request is completed over HTTP" "submitted" "$(submit_support "$M2")"
  wait_sync "Underhill-$M2" || :
  assert_eq "the support request became one case with its subject, category, priority and description" \
    "Printer on fire $M2|TECH|High|It burns $M2" \
    "$(csql "SELECT CONCAT_WS('|', name, type, priority, description) FROM cases WHERE deleted = 0")"
  assert_eq "the person who asked for support is a lead too, as the demo survey maps its contact questions" "1" \
    "$(csql "SELECT COUNT(*) FROM leads WHERE last_name = 'Underhill-$M2' AND deleted = 0")"
  assert_eq "the sync log records the case as sent" "success" \
    "$(lsql "SELECT sync_status FROM lime_survey_crm_sync_log WHERE crm_module = 'Cases' ORDER BY id DESC LIMIT 1")"
  assert_eq "no sync is recorded as failed" "0" "$(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log WHERE sync_status <> 'success'")"
  assert_eq "the sync log keeps no copy of the answers of a sync that worked" "0" \
    "$(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log WHERE sync_status = 'success' AND (request_payload IS NOT NULL OR response_data IS NOT NULL OR field_mappings_used IS NOT NULL)")"

  echo
  echo "The way back when the OAuth2 client is gone from SuiteCRM"
  # An admin deletes the client in SuiteCRM, or a restore brings back a database from before the plugin made it.
  csql "UPDATE oauth2clients SET deleted = 1 WHERE name = 'LimeSurvey Integration'" >/dev/null
  M3=n3x3358
  assert_eq "a sales inquiry is still completed" "submitted" "$(submit_sales "$M3" "Acme-$M3")"
  wait_sync "Quillfeather-$M3" || :
  assert_eq "it is recorded as failed, with what was to be sent, and no lead is made" "failed 1 0" \
    "$(sync_of "Quillfeather-$M3" "CONCAT(sync_status, ' ', request_payload LIKE '%Quillfeather-$M3%')") $(leads_of "$M3")"
  code="$(web post /tmp/admin.jar "$(direct actionInitializeOAuth2 0)")"
  assert_eq "the settings page's Initialize OAuth2 answers 200" "200" "$code"
  assert_eq "SuiteCRM has a new client for the plugin, and LimeSurvey keeps its id" \
    "$(setting oauth_client_id | tr -d '"')" "$(csql "SELECT id FROM oauth2clients WHERE name = 'LimeSurvey Integration' AND deleted = 0")"
  M4=n4x4469
  assert_eq "the next sales inquiry is completed" "submitted" "$(submit_sales "$M4" "Acme-$M4")"
  check_lead "with the new client, the response" "$M4" "Acme-$M4"

  echo
  echo "CLOUVE_OPS_PASSWORD on all four"
  for svc in "${SERVICES[@]}"; do
    assert_eq "$svc: clouve-ops signs in over SSH from another container" "clouve-ops" "$(ops_whoami "$svc")"
    case "$svc" in
      *-mariadb) assert_eq "$svc: mariadbd and sshd don't have the password in their environment (only tini, PID 1, was started with it)" "tini" "$(holders "$svc")" ;;
      *) assert_eq "$svc: no process has the password in its environment: not Apache, not PHP, not sshd" "" "$(holders "$svc")" ;;
    esac
  done
  logs=""
  for svc in "${SERVICES[@]}"; do logs="$logs$(docker logs "$(c_of "$svc")" 2>&1)"; done
  assert_eq "no container's log holds a password" "0" "$(secrets_in "$logs")"
  if [ "$KEEP" != true ]; then
    for svc in "${SERVICES[@]}"; do docker rm -f -v "$(c_of "$svc")" >/dev/null 2>&1; done
    for v in $(docker volume ls -q | grep "^${PREFIX}new-"); do docker volume rm -f "$v" >/dev/null 2>&1; done
  fi
fi

wants upgrade || wants standin || wants faulty || finish

# ======================================================================================================================
# The old kit
# ======================================================================================================================
echo
echo "The old kit: LimeSurvey $OLD_LS and SuiteCRM $OLD_SC, as installs have it today"
if ! old_images; then
  fail "the old kit's images build from commit ${OLD_COMMIT:0:7} or are on this machine"
  finish
fi
if ! git -C "$REPO_DIR" show "$OLD_COMMIT:bundles/crm-kit/clv-docker-compose.yml" > "$WORK/old-manifest.yml" 2>/dev/null ||
  ! kit_settings old "$WORK/old-manifest.yml"; then
  fail "the old manifest's settings can be read"
  finish
fi
VOLUMES=()
for svc in "${SERVICES[@]}"; do for spec in ${KIT_VOLS[$svc]}; do VOLUMES+=("${spec%%:*}"); done; done
LS_MAJOR=6
kit_volumes seed || fail "the old kit's five volumes are made as new disks"
for svc in limesurvey-mariadb suitecrm-mariadb limesurvey; do
  kit_run seed old "$svc" "${OLD_IMAGE[$svc]}" || fail "$svc starts"
done
# SuiteCRM 8.9.1's installer gets 2 GB here. It is not what this test is about, and it is slow at the kit's 1 GB.
kit_run seed old suitecrm "${OLD_IMAGE[suitecrm]}" --memory 2g --memory-swap 2g || fail "suitecrm starts"
# The old LimeSurvey image registers the plugin and, two seconds later, imports the demo survey as root. A page that
# is asked for in between loads the plugin as www-data, which makes the plugin's log file in /tmp, and where the
# kernel protects files in /tmp (fs.protected_regular) root's import then fails on that file and LimeSurvey marks
# the plugin as faulty. So nothing here asks the old LimeSurvey for a page until its log says how the import went.
# The faulty case below covers a kit that was hit.
# shellcheck disable=SC2329  # sc_wait_for calls it
old_ready() {
  docker logs "$(c_of limesurvey)" 2>&1 | grep -q -e 'Demo data installation complete' -e 'DEMO-DATA ERROR' && sc_real
}
if sc_wait_for 900 old_ready && [ "$(ls_http "$(c_of limesurvey)" /)" = 200 ] &&
  [ "$(lsql "SELECT CONCAT(active, ' ', load_error) FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")" = "1 0" ] &&
  [ "$(lsql "SELECT COUNT(*) FROM lime_surveys WHERE sid = $SID")" = 1 ]; then
  pass "the old kit installs on new disks, with the plugin on and the demo survey imported"
else
  fail "the old kit installs on new disks, with the plugin on and the demo survey imported"
  show_logs limesurvey suitecrm
  finish
fi
assert_eq "it is LimeSurvey $OLD_LS and SuiteCRM $OLD_SC on MariaDB 11.8 and 12.1" "$OLD_LS $OLD_SC 11.8 12.1" \
  "$(ls_code_version "$(c_of limesurvey)" | cut -d' ' -f1) $(docker exec "$(c_of suitecrm)" cat /var/www/html/VERSION 2>/dev/null) $(docker exec "$(c_of limesurvey-mariadb)" cat /var/lib/mysql/mariadb_upgrade_info | cut -d. -f1,2) $(docker exec "$(c_of suitecrm-mariadb)" cat /var/lib/mysql/mariadb_upgrade_info | cut -d. -f1,2)"
# The old image imports the demo survey with two or three survey_enabled rows, and the plugin reads the first. An
# admin who saves "Enabled" in the survey's settings changes that first row, so the test does the same.
first="$(lsql "SELECT id FROM lime_plugin_settings WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = '$SID' ORDER BY id LIMIT 1")"
if [ -n "$first" ]; then
  lsql "UPDATE lime_plugin_settings SET value = '\"1\"' WHERE id = $first" >/dev/null
else
  lsql "INSERT INTO lime_plugin_settings (plugin_id, model, model_id, \`key\`, value) VALUES ($(plugin_id), 'Survey', $SID, 'survey_enabled', '\"1\"')" >/dev/null
fi
install_helpers
if activate_demo; then pass "the admin activates the demo survey"; else fail "the admin activates the demo survey"; fi
OM=o1x5582
assert_eq "a respondent's sales inquiry is completed on the old kit" "submitted" "$(submit_sales "$OM" "Acme-$OM")"
check_lead "the old kit" "$OM" "Acme-$OM"
OLD_LEAD="$(csql "SELECT id FROM leads WHERE last_name = 'Quillfeather-$OM' AND deleted = 0")"
OLD_CLIENT="$(csql "SELECT CONCAT(id, ' ', secret) FROM oauth2clients WHERE name = 'LimeSurvey Integration' AND deleted = 0")"
assert_eq "the plugin made its OAuth2 client in SuiteCRM, and keeps its id" "${OLD_CLIENT%% *}" "$(setting oauth_client_id | tr -d '"')"
# What an admin of the old kit may have: a plugin added by hand and switched on, and a row in the plugin's table of
# mappings (the table as the old image made it: one CRM field per question, no transform_rule).
docker exec -u www-data "$(c_of limesurvey)" sh -c 'mkdir -p /var/www/html/plugins/ClvTestPlugin && cd /var/www/html/plugins/ClvTestPlugin &&
  printf "%s\n" "<?php" "class ClvTestPlugin extends PluginBase" "{" "    protected \$storage = \"DbStorage\";" \
    "    static protected \$name = \"ClvTestPlugin\";" "    static protected \$description = \"A plugin an admin added\";" \
    "    public function init() {}" "}" > ClvTestPlugin.php &&
  printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<config><metadata><name>ClvTestPlugin</name><type>plugin</type><version>1.0.0</version><author>test</author><license>MIT</license><description>test</description></metadata><compatibility><version>6.0</version><version>7.0</version></compatibility><updaters disabled=\"disabled\"></updaters></config>" > config.xml' >/dev/null 2>&1
lsql "INSERT INTO lime_plugins (name, active, version, load_error, plugin_type) VALUES ('ClvTestPlugin', 1, '1.0.0', 0, 'user');
  INSERT INTO lime_survey_crm_mappings (survey_id, question_id, crm_module, crm_field_name, crm_field_label, crm_field_type)
    VALUES ($SID, $(qid email), 'Leads', 'email1', 'Email', 'varchar')" >/dev/null
assert_eq "its table of mappings has the old shape, with a row in it" "0 0 1 1" "$(mappings_shape) $(lsql "SELECT COUNT(*) FROM lime_survey_crm_mappings")"
OLD_RESPONSES="$(lsql "SELECT COUNT(*) FROM lime_survey_$SID")"
OLD_SYNC="$(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log")"
OLD_LEADS="$(csql "SELECT COUNT(*) FROM leads WHERE deleted = 0")"
OLD_CASES="$(csql "SELECT COUNT(*) FROM cases WHERE deleted = 0")"
OLD_URL="$(setting suitecrm_url)"
OLD_LS_HASH="$(lsql "SELECT password FROM lime_users WHERE users_name = '$LS_ADMIN'")"
old_stored="$(lsql "SELECT value FROM lime_plugin_settings WHERE plugin_id = $(plugin_id)")"
echo "       the old kit: $OLD_RESPONSES response, $OLD_LEADS lead and $OLD_CASES case(s) in SuiteCRM, $OLD_SYNC sync log rows, $(secrets_in "$old_stored") password(s) in clear text in the plugin's settings"
if [ "$OLD_RESPONSES" != 1 ] || [ -z "$OLD_LEAD" ] || [ -z "$OLD_CLIENT" ]; then
  fail "the old kit has its response, its lead and its OAuth2 client"
  show_logs limesurvey
  finish
fi
docker stop -t 30 "$(c_of limesurvey)" "$(c_of suitecrm)" >/dev/null 2>&1
docker stop -t 60 "$(c_of limesurvey-mariadb)" "$(c_of suitecrm-mariadb)" >/dev/null 2>&1
for svc in "${SERVICES[@]}"; do docker rm -f "$(c_of "$svc")" >/dev/null 2>&1; done
pass "the old kit is stopped, and its five volumes are kept"

# new_case CASE: the case gets its own copy of the old kit's volumes.
new_case() {
  local v
  for v in "${VOLUMES[@]}"; do sc_copy_volume "$(vol_of seed "$v")" "$(vol_of "$1" "$v")" || return 1; done
}
drop_case() {
  local v svc
  [ "$KEEP" = true ] && return 0
  for svc in "${SERVICES[@]}"; do docker rm -f "$(c_of "$svc")" >/dev/null 2>&1; done
  for v in "${VOLUMES[@]}"; do docker volume rm -f "$(vol_of "$1" "$v")" >/dev/null 2>&1; done
}
# start_databases CASE: the two new database images on the case's volumes. Each must pass its command probe before
# the last probe the platform runs before it restarts the container, with MariaDB's own upgrade inside that time.
start_databases() {
  local c="$1" svc
  for svc in limesurvey-mariadb suitecrm-mariadb; do kit_run "$c" new "$svc" "${NEW_IMAGE[$svc]}" || fail "$c: $svc starts"; done
  for svc in limesurvey-mariadb suitecrm-mariadb; do
    check_probe "$c: $svc passes its command probe on the old data before the platform would restart it" "$svc" LAST
  done
}
upgrade_logs() { docker logs "$(c_of limesurvey)" 2>&1; docker logs "$(c_of suitecrm)" 2>&1; }

# ======================================================================================================================
# upgrade: both apps in one start
# ======================================================================================================================
if wants upgrade; then
  echo
  echo "upgrade: the new images on the old kit's volumes"
  c=upgrade
  LS_MAJOR=7
  new_case $c || fail "$c: the old kit's volumes are copied"
  start_databases $c
  echo "       MariaDB after the start: limesurvey-mariadb $(docker exec "$(c_of limesurvey-mariadb)" cat /var/lib/mysql/mariadb_upgrade_info 2>/dev/null), suitecrm-mariadb $(docker exec "$(c_of suitecrm-mariadb)" cat /var/lib/mysql/mariadb_upgrade_info 2>/dev/null)"
  assert_contains "$c: SuiteCRM's data directory moved from MariaDB 12.1 to 12.3" \
    "$(docker exec "$(c_of suitecrm-mariadb)" cat /var/lib/mysql/mariadb_upgrade_info 2>/dev/null)" "12.3."
  assert_contains "$c: MariaDB ran its own upgrade there, inside that time" "$(docker logs "$(c_of suitecrm-mariadb)" 2>&1)" "Finished mariadb-upgrade"
  # Both apps at once, as a cluster starts them, with no CLOUVE_OPS_PASSWORD: an install made without the AI Assistant.
  kit_run $c new suitecrm "${NEW_IMAGE[suitecrm]}" || fail "$c: suitecrm starts"
  kit_run $c new limesurvey "${NEW_IMAGE[limesurvey]}" || fail "$c: limesurvey starts"
  begun=$SECONDS
  watch_probes "$WORK/probes-$c" limesurvey suitecrm &
  watcher=$!
  rc=0; wait_real 900 || rc=$?
  took=$((SECONDS - begun))
  touch "$WORK/probes-$c.stop"; wait "$watcher" 2>/dev/null
  if [ "$rc" -eq 0 ]; then
    pass "$c: both apps upgraded in one start and answer themselves, $took s after the two containers started"
  else
    fail "$c: both apps upgraded in one start and answer themselves"
    show_logs limesurvey suitecrm
    drop_case $c
    finish
  fi
  log="$(upgrade_logs)"
  echo "       wall time of the pair's upgrade at the manifest's 1 GB and one CPU each: $took s (LimeSurvey: $(sed -n 's/.*done: limesurvey .* in \([0-9][0-9]*\) s\..*/\1/p' <<< "$log" | tail -n 1) s, SuiteCRM: $(sed -n 's/.*DONE suitecrm .* in \([0-9][0-9]*\) s\..*/\1/p' <<< "$log" | tail -n 1) s)"
  for svc in limesurvey suitecrm; do
    read -r good gap <<< "$(longest_gap "$WORK/probes-$c" "$svc")"
    if [ "$good" -ge 1 ] && [ "$gap" -le 5 ]; then
      pass "$c: $svc passed its probe all through the upgrade ($good passes, longest run of failures $gap)"
    else
      fail "$c: $svc passed its probe all through the upgrade ($good passes, longest run of failures $gap)"
    fi
  done
  assert_eq "$c: neither container restarted" "0 0" \
    "$(docker inspect --format '{{.RestartCount}}' "$(c_of limesurvey)") $(docker inspect --format '{{.RestartCount}}' "$(c_of suitecrm)")"
  assert_eq "$c: LimeSurvey is ${KIT_VERSION[limesurvey]}, code and database" "${KIT_VERSION[limesurvey]} 718 718" \
    "$(ls_code_version "$(c_of limesurvey)") $(lsql "SELECT stg_value FROM lime_settings_global WHERE stg_name = 'DBVersion'")"
  assert_eq "$c: SuiteCRM is ${KIT_VERSION[suitecrm]}, code and database" "${KIT_VERSION[suitecrm]} ${KIT_VERSION[suitecrm]}" \
    "$(docker exec "$(c_of suitecrm)" cat /var/www/html/VERSION 2>/dev/null) $(csql "SELECT value FROM config WHERE category = 'info' AND name = 'suitecrm_version'")"
  assert_contains "$c: LimeSurvey's upgrade logs its finishing line" "$log" "[clouve-upgrade] done: limesurvey $OLD_LS -> ${KIT_VERSION[limesurvey]}"
  assert_contains "$c: SuiteCRM's upgrade logs its finishing line" "$log" "[clouve-upgrade] DONE suitecrm $OLD_SC -> ${KIT_VERSION[suitecrm]}"

  echo
  echo "upgrade: the plugin and what the customer had"
  assert_eq "$c: the SuiteCRM plugin is on again" "1" "$(lsql "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  assert_contains "$c: the log says it was on before and is on again" "$log" "the SuiteCRM plugin was on before the update and is on again"
  assert_eq "$c: the plugin an admin added is left off, with its files kept" "0 ClvTestPlugin.php" \
    "$(lsql "SELECT active FROM lime_plugins WHERE name = 'ClvTestPlugin'") $(docker exec "$(c_of limesurvey)" ls /var/www/html/plugins/ClvTestPlugin 2>/dev/null | grep -x ClvTestPlugin.php)"
  backup="/var/www/html/clouve/upgrade-$OLD_LS-to-${KIT_VERSION[limesurvey]}"
  assert_eq "$c: the backup folder lists the added plugins that were on, and the one left off" \
    "ClvTestPlugin SuiteCRMIntegration / ClvTestPlugin" \
    "$(docker exec "$(c_of limesurvey)" sh -c "cat $backup/active-plugins | xargs; printf '/ '; cat $backup/plugins-left-off | xargs" 2>&1 | xargs)"
  assert_contains "$c: the log names the plugin it left off" "$log" "left off: ClvTestPlugin"
  assert_eq "$c: the plugin's SuiteCRM address is the one from before" "$OLD_URL" "$(setting suitecrm_url)"
  stored="$(lsql "SELECT value FROM lime_plugin_settings WHERE plugin_id = $(plugin_id)")"
  assert_eq "$c: none of its settings holds a password in clear text any more" "0" "$(secrets_in "$stored")"
  assert_eq "$c: the OAuth2 client in SuiteCRM is the one the old kit made, with the same secret" "$OLD_CLIENT" \
    "$(csql "SELECT CONCAT(id, ' ', secret) FROM oauth2clients WHERE name = 'LimeSurvey Integration' AND deleted = 0")"
  assert_eq "$c: and LimeSurvey still keeps its id" "${OLD_CLIENT%% *}" "$(setting oauth_client_id | tr -d '"')"
  assert_eq "$c: the earlier lead is still in SuiteCRM" "$OLD_LEAD Zebulon-$OM|Quillfeather-$OM|Acme-$OM|CRM|zeb-$OM@example.invalid" \
    "$(csql "SELECT id FROM leads WHERE last_name = 'Quillfeather-$OM' AND deleted = 0") $(lead_row "$OM")"
  assert_eq "$c: SuiteCRM has the leads and cases it had" "$OLD_LEADS $OLD_CASES" \
    "$(csql "SELECT COUNT(*) FROM leads WHERE deleted = 0") $(csql "SELECT COUNT(*) FROM cases WHERE deleted = 0")"
  assert_eq "$c: the earlier response is still in LimeSurvey, with its answers" "$OLD_RESPONSES Quillfeather-$OM" \
    "$(lsql "SELECT COUNT(*) FROM lime_responses_$SID") $(lsql "SELECT Q$(qid lastName) FROM lime_responses_$SID ORDER BY id LIMIT 1")"
  assert_eq "$c: the sync log keeps its rows" "$OLD_SYNC" "$(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log")"
  assert_eq "$c: the demo survey is still active, with its link on" "Y 1" \
    "$(lsql "SELECT active FROM lime_surveys WHERE sid = $SID") $(lsql "SELECT value FROM lime_plugin_settings WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = '$SID' ORDER BY id LIMIT 1" | tr -d '"')"
  assert_eq "$c: LimeSurvey's admin password is the one from before" "$OLD_LS_HASH" "$(lsql "SELECT password FROM lime_users WHERE users_name = '$LS_ADMIN'")"

  echo
  echo "upgrade: the link works"
  install_helpers
  UM=u1x6693
  # This respondent leaves the company empty. The old demo survey has a rule that makes a case number for every
  # response, and that alone must not make a case.
  assert_eq "$c: a new sales inquiry is completed" "submitted" "$(submit_sales "$UM")"
  check_lead "$c: the new response" "$UM" ""
  assert_eq "$c: it made a lead and no case" "$((OLD_LEADS + 1)) $OLD_CASES" \
    "$(csql "SELECT COUNT(*) FROM leads WHERE deleted = 0") $(csql "SELECT COUNT(*) FROM cases WHERE deleted = 0")"
  T_PASS="$ADMIN_PW" web login "$LS_ADMIN" /tmp/admin.jar
  assert_eq "$c: the old table's row is kept" "email1" \
    "$(lsql "SELECT crm_field_name FROM lime_survey_crm_mappings WHERE question_id = $(qid email)")"
  check_mappings "$c"

  echo
  echo "upgrade: an install without the AI Assistant"
  # No scheduled job ever ran on the old kit, so the image holds the scheduler: SuiteCRM's own settings don't switch
  # it on ($sugar_config['clouve']['scheduler'] in config_override.php), and it needs no hold file for that.
  assert_eq "$c: SuiteCRM's scheduler is held (its settings don't switch it on, no hold file), and no scheduled job has run" "off 0 0" \
    "$(docker exec "$(c_of suitecrm)" sh -c 'cd /var/www/html && setpriv --reuid=www-data --regid=www-data --init-groups -- php /clouve/suitecrm/installer/settings.php scheduler 2>/dev/null; ls tmp/clouve-backup/scheduler-held 2>/dev/null | wc -l' | xargs) $(csql "SELECT COUNT(*) FROM job_queue")"
  sc_wait_log "$(c_of suitecrm)" "the scheduler is held" 90 >/dev/null
  assert_contains "$c: the log says the scheduler is held, and why" "$(docker logs "$(c_of suitecrm)" 2>&1)" \
    "the scheduler is held: SuiteCRM's settings don't switch it on"
  got=""
  for svc in "${SERVICES[@]}"; do got="$got $(sshd_count "$svc")"; done
  assert_eq "$c: no sshd runs in any of the four containers" " 0 0 0 0" "$got"
  logs=""
  for svc in "${SERVICES[@]}"; do logs="$logs$(docker logs "$(c_of "$svc")" 2>&1)"; done
  assert_eq "$c: no container's log holds a password" "0" "$(secrets_in "$logs")"
  drop_case $c
fi

# ======================================================================================================================
# standin: a response while SuiteCRM is being upgraded
# ======================================================================================================================
if wants standin; then
  echo
  echo "standin: a response that arrives while SuiteCRM's stand-in answers"
  c=standin
  LS_MAJOR=7
  PAUSE=150
  new_case $c || fail "$c: the old kit's volumes are copied"
  start_databases $c
  kit_run $c new suitecrm "${NEW_IMAGE[suitecrm]}" -e "CLOUVE_TEST_PAUSE=upgrade:$PAUSE" || fail "$c: suitecrm starts"
  kit_run $c new limesurvey "${NEW_IMAGE[limesurvey]}" || fail "$c: limesurvey starts"
  if sc_wait_for 300 ls_real; then pass "$c: LimeSurvey has upgraded and answers"; else fail "$c: LimeSurvey has upgraded and answers"; show_logs limesurvey; fi
  if sc_wait_log "$(c_of suitecrm)" "test pause at upgrade" 200; then pass "$c: SuiteCRM's upgrade is held at the test's pause"; else fail "$c: SuiteCRM's upgrade is held at the test's pause"; show_logs suitecrm; fi
  assert_contains "$c: SuiteCRM's stand-in answers the health check, and names itself" \
    "$(docker exec "$(c_of limesurvey)" curl -s -D - -o /dev/null http://suitecrm/ 2>/dev/null | tr -d '\r' | grep -i -e '^HTTP' -e '^X-Clouve-Standin' | xargs)" "200 OK X-Clouve-Standin: suitecrm"
  assert_eq "$c: and answers the plugin's token request with 503" "503" \
    "$(docker exec "$(c_of limesurvey)" curl -s -o /dev/null -w '%{http_code}' -X POST http://suitecrm/Api/access_token 2>/dev/null)"
  install_helpers
  SM=s1x7704
  assert_eq "$c: a respondent's sales inquiry is completed all the same" "submitted" "$(submit_sales "$SM" "Acme-$SM")"
  assert_eq "$c: LimeSurvey keeps the response" "$((OLD_RESPONSES + 1))" "$(lsql "SELECT COUNT(*) FROM lime_responses_$SID")"
  for _ in $(seq 1 30); do [ "$(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log")" -gt "$OLD_SYNC" ] && break; sleep 1; done
  assert_eq "$c: the sync log records the attempt as failed, never as sent" "failed" \
    "$(lsql "SELECT GROUP_CONCAT(DISTINCT sync_status) FROM lime_survey_crm_sync_log WHERE id > (SELECT MAX(id) - ($(lsql "SELECT COUNT(*) FROM lime_survey_crm_sync_log") - $OLD_SYNC) FROM lime_survey_crm_sync_log)")"
  assert_contains "$c: with what SuiteCRM answered" \
    "$(lsql "SELECT error_message FROM lime_survey_crm_sync_log ORDER BY id DESC LIMIT 1")" "503"
  if sc_wait_for $((PAUSE + 300)) sc_real; then pass "$c: SuiteCRM finishes its upgrade and answers"; else fail "$c: SuiteCRM finishes its upgrade and answers"; show_logs suitecrm; fi
  assert_eq "$c: no lead was made of that response" "0" "$(leads_of "$SM")"
  SM2=s2x8815
  assert_eq "$c: the next sales inquiry is completed" "submitted" "$(submit_sales "$SM2" "Acme-$SM2")"
  check_lead "$c: with SuiteCRM up again, the next response" "$SM2" "Acme-$SM2"
  drop_case $c
fi

# ======================================================================================================================
# faulty: the plugin as the old image can leave it
# ======================================================================================================================
if wants faulty; then
  echo
  echo "faulty: an old kit whose plugin the old image marked as faulty"
  c=faulty
  LS_MAJOR=7
  new_case $c || fail "$c: the old kit's volumes are copied"
  start_databases $c
  lsql "UPDATE lime_plugins SET load_error = 1, load_error_message = 'Unknown error - error_get_last() returned null' WHERE name = 'SuiteCRMIntegration'" >/dev/null
  kit_run $c new suitecrm "${NEW_IMAGE[suitecrm]}" || fail "$c: suitecrm starts"
  kit_run $c new limesurvey "${NEW_IMAGE[limesurvey]}" || fail "$c: limesurvey starts"
  rc=0; wait_real 900 || rc=$?
  if [ "$rc" -eq 0 ]; then pass "$c: both apps upgraded and answer themselves"; else fail "$c: both apps upgraded and answer themselves"; show_logs limesurvey suitecrm; fi
  assert_eq "$c: the plugin is on, and no longer marked as faulty" "1 0" \
    "$(lsql "SELECT CONCAT(active, ' ', load_error) FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
  assert_contains "$c: the log says the mark was cleared" "$(docker logs "$(c_of limesurvey)" 2>&1)" "marked the plugin as faulty"
  install_helpers
  FM=f1x9926
  assert_eq "$c: a sales inquiry is completed" "submitted" "$(submit_sales "$FM" "Acme-$FM")"
  check_lead "$c: the response" "$FM" "Acme-$FM"
  drop_case $c
fi

finish
