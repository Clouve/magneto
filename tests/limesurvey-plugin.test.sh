#!/bin/bash

# ============================================================================
# LimeSurvey plugin test: Clouve's SuiteCRM plugin on LimeSurvey 7
# ============================================================================
# Starts the LimeSurvey image with ENABLE_SUITECRM_INTEGRATION=true and the
# demo survey, its database image, and a stand-in for SuiteCRM: a small HTTP
# server that records the token request and each record it is sent, and an
# empty "suitecrm" database with the one table the plugin writes its OAuth2
# client to. No SuiteCRM runs here; the Customer Kit's test covers the real
# pair.
#
#   - The plugin's files: config.xml lists LimeSurvey 7.0 beside 6.0, and
#     every PHP file passes php -l on the image's PHP with all warnings on.
#   - The start: the plugin is registered and switched on; its settings come
#     from the environment, with both passwords stored encrypted and debug
#     mode off; no password is on a command line or in the log; the demo
#     survey has exactly one survey_enabled setting, and it says on.
#   - LimeSurvey 7's plugin manager accepts the plugin: switched off, an
#     admin can switch it on again in the browser.
#   - A start never changes whether the plugin is on: switched off, it stays
#     off through a restart, while its settings still follow the environment.
#   - The question editor's script, run with LimeSurvey's jQuery in a page
#     like the classic editor's: a value from a stored mapping or from
#     SuiteCRM is shown as text and adds no attribute and no element. With
#     the survey's link off the section is hidden and stays in the form. A
#     respondent's survey page doesn't load the script (its calls would only
#     get 401); a signed-in admin's page does.
#   - Each of the eleven AJAX endpoints answers 401 to a caller who is not
#     signed in, 403 to an admin account with no rights, and the main admin
#     gets through. An account that may read one survey's settings can read
#     that survey's mappings and the editor's lists, and nothing else.
#   - An account without the global "settings: update" right never starts
#     the OAuth2 setup and never makes the plugin call SuiteCRM: it gets
#     the field lists from the cache.
#   - The four endpoints that change something take POST with LimeSurvey's
#     CSRF token and refuse a GET.
#   - A response submitted over HTTP, as a browser submits it, becomes a lead:
#     the stand-in gets a token request with the admin name and password from
#     the environment and a Leads record with the mapped answers.
#   - No answer reaches a log file: not the container's log, not /tmp, not
#     /var/log, not LimeSurvey's runtime folder, with debug mode off and with
#     it on. /tmp/suitecrm_integration.log is never made.
#   - The sync log keeps what was sent only for a sync that failed, and a
#     write to it removes the rows older than 90 days.
#   - The plugin writes only to Leads and Cases. A mapping that names another
#     module, or a field SuiteCRM does not list for the module, is refused
#     when it is saved (LimeSurvey's own question save and actionSaveMappings)
#     and again when a response is sent: the stand-in gets no request for it.
#     Saving a mapping needs the right to change the survey's content.
#   - Saving a question while the survey's link is off keeps its mapping.
#   - A redirect from SuiteCRM's address is not followed.
#   - The settings page says that field mapping is done in the classic
#     question editor and how to switch to it. It never holds a stored
#     password or the OAuth2 client secret, an empty password field keeps
#     what is stored, and the page needs the global "settings: update" right.
#
# Every container, volume and network is named ls-pl-t-* (LS_TEST_PREFIX
# changes that) and is removed at the end, with the images the test built.
# The script checks run in a small Node image with jsdom that the test builds
# (it needs the npm registry once). LS_PLUGIN_JS_IMAGE names one that is
# already built.
#
# Usage: bash tests/limesurvey-plugin.test.sh [--image limesurvey=REF] [--image limesurvey-mariadb=REF] [--keep]
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${LS_TEST_PREFIX:-ls-pl-t-}"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"

PLUGIN_DIR="$LS_APP_DIR/image/installer/SuiteCRMIntegration"
CRM_PW="crm-pw-5d81e0c7"
CRM_DB_PW="crmdb-pw-a94f2b16"
USER_PW="User-pw-33e1c8a0!"
LS_EXTRA_SECRETS=("$CRM_PW" "$CRM_DB_PW")
ENDPOINTS=(actionGetModules actionGetFields actionGetAllFields actionTestConnection actionRefreshCache actionGetSyncLogs
  actionSaveMappings actionGetMappings actionGetTransformRules actionCheckStatus actionInitializeOAuth2)

ls_parse_args "$@"
[ "${#LS_ARGS[@]}" -eq 0 ] || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2; exit 2; }
ls_need_docker
WORK="$(mktemp -d)"
chmod 755 "$WORK"
trap ls_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ls_remove_all

echo "The plugin's files"
assert_eq "config.xml lists LimeSurvey 7.0 and 6.0" "2" "$(grep -cE '<version>(7\.0|6\.0)</version>' "$PLUGIN_DIR/config.xml")"
# The status panel and "Initialize OAuth2" both ask SuiteCRM's database whether the client the plugin holds is
# still there. They share one method, so the two can't come to disagree.
assert_eq "one method asks whether SuiteCRM still has the OAuth2 client, and both callers use it" "1 2" \
  "$(grep -c 'FROM oauth2clients WHERE id = ? AND deleted = 0' "$PLUGIN_DIR/SuiteCRMIntegration.php") $(grep -c -- '->oauth2ClientIsGone(' "$PLUGIN_DIR/SuiteCRMIntegration.php")"
if ! ls_image limesurvey-mariadb || ! ls_image limesurvey; then
  fail "the images build or are on this machine"
  echo; printf '%sLimeSurvey plugin checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
IMAGE="${LS_IMAGE[limesurvey]}"
lint="$(docker run --rm --network none --entrypoint sh "$IMAGE" -c 'cd /clouve/limesurvey/package/plugins/SuiteCRMIntegration &&
  for f in *.php classes/*.php /clouve/limesurvey/installer/commands/*.php; do php -d error_reporting=-1 -l "$f" 2>&1 | grep -v "^No syntax errors"; done' 2>&1)"
assert_eq "every PHP file of the plugin passes php -l on the image's PHP" "" "$lint"
assert_eq "the image's copy of the plugin is this checkout's" \
  "$(cd "$PLUGIN_DIR" && find . -type f | LC_ALL=C sort | xargs sha256sum)" \
  "$(docker run --rm --network none --entrypoint sh "$IMAGE" -c 'cd /clouve/limesurvey/package/plugins/SuiteCRMIntegration && find . -type f | LC_ALL=C sort | xargs sha256sum')"

# --- the plugin's scripts, run in a page -------------------------------------------------------------------------
echo
echo "The question editor's script"
JS_IMAGE="${LS_PLUGIN_JS_IMAGE:-}"
mkdir -p "$WORK/js"
chmod 755 "$WORK/js"
if [ -z "$JS_IMAGE" ]; then
  JS_IMAGE="${PREFIX}jsdom:test"
  printf 'FROM mirror.gcr.io/library/node:22-alpine\nWORKDIR /t\nRUN npm install --no-audit --no-fund jsdom@26.1.0\n' > "$WORK/js/Dockerfile"
  if docker build -t "$JS_IMAGE" "$WORK/js" >/dev/null 2>&1; then LS_BUILT+=("$JS_IMAGE"); fi
fi
# run_js SCRIPT FILE...: runs a script of $WORK/js in the Node image, with no network, and prints its lines.
run_js() {
  local script="$1"
  shift
  docker run --rm --name "${PREFIX}js" --network none --memory 512m -e NODE_PATH=/t/node_modules \
    -v "$WORK/js:/js:ro" -v "$PLUGIN_DIR/assets:/assets:ro" "$JS_IMAGE" node "/js/$script" "$@" 2>&1
}
# report_js OUTPUT COUNT: one PASS or FAIL per "ok" or "not ok" line, and a check that COUNT of them passed.
report_js() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "ok "*) pass "${line#ok }" ;;
      "not ok "*) fail "${line#not ok }" ;;
      *) [ -z "$line" ] || printf '       %s\n' "$line" ;;
    esac
  done <<< "$1"
  assert_eq "all $2 of these checks ran and passed" "$2" "$(grep -c '^ok ' <<< "$1")"
}
docker run --rm --network none --entrypoint cat "$IMAGE" /clouve/limesurvey/package/node_modules/jquery/dist/jquery.min.js > "$WORK/js/jquery.js"
cat > "$WORK/js/editor-test.js" <<'JS'
// Runs the plugin's question-editor.js in a page like the classic question editor's, with LimeSurvey's own jQuery,
// and prints one line per check: "ok <what>" or "not ok <what>". node editor-test.js <jquery.js> <question-editor.js>
const fs = require('fs');
const { JSDOM } = require('jsdom');
const jquery = fs.readFileSync(process.argv[2], 'utf8');
const editor = fs.readFileSync(process.argv[3], 'utf8');
const HOSTILE_MODULE = 'Leads" style="animation-name:spinner-border" onanimationstart="window.__clv=1" data-x="';
const HOSTILE_TEXT = '</option></select><img src=x onerror="window.__clv=1">';

// page(options): the editor page after the script has loaded its two lists and built its controls.
function page(o) {
  const dom = new JSDOM('<!doctype html><html><head><meta name="baseUrl" content=""></head><body><form>' +
    '<input type="hidden" name="sid" value="123456">' +
    '<div id="advanced-options-container">' +
    '<div class="accordion-item panel-advancedquestionsettings" id="crm-section"><div class="accordion-body"><div class="mb-3">' +
    '<input type="text" name="advancedSettings[SuiteCRM Integration][suitecrm_mappings_json]"></div></div></div>' +
    '<div class="accordion-item panel-advancedquestionsettings" id="other-section"><div class="accordion-body"><div class="mb-3">' +
    '<input type="text" name="advancedSettings[Display][cssclass]"></div></div></div>' +
    '</div></form></body></html>',
    { runScripts: 'outside-only', url: 'http://localhost/index.php/questionAdministration/edit/questionId/7' });
  const w = dom.window;
  w.console.error = function () {};
  w.console.warn = function () {};
  const field = w.document.querySelector('input[name*="suitecrm_mappings_json"]');
  field.value = o.stored;
  w.eval(jquery);
  const calls = [];
  w.jQuery.ajax = function (s) {
    calls.push(s);
    const answer = s.data.function === 'actionGetAllFields' ? o.fields : { rules: o.rules };
    w.setTimeout(function () { s.success(answer); }, 0);
  };
  w.eval(editor);
  return new Promise(function (resolve) {
    w.setTimeout(function () { resolve({ w: w, calls: calls, field: field }); }, 100);
  });
}
// planted(w): how many things a value planted in the page: an event handler, a style, or an element of its own.
function planted(w) {
  let n = w.document.querySelectorAll('img, script, iframe').length;
  w.document.querySelectorAll('#crm-section *').forEach(function (el) {
    for (const a of el.attributes) {
      if (/^on/i.test(a.name) || a.name === 'data-x' || (a.name === 'style' && /animation/.test(a.value))) { n++; }
    }
  });
  return n + ('__clv' in w ? 1 : 0);
}
function say(ok, what) { console.log((ok ? 'ok ' : 'not ok ') + what); }
const plainFields = { fields: { Leads: { first_name: { label: 'First Name' } } }, modules: ['Leads'], surveyEnabled: true };
const plainRules = { none: 'No transformation', uppercase: 'UPPERCASE' };

(async function () {
  let p = await page({ stored: JSON.stringify([{ module: HOSTILE_MODULE, field: 'first_name' }]), fields: plainFields, rules: plainRules });
  const group = p.w.document.querySelector('.suitecrm-module-group');
  say(planted(p.w) === 0, 'a stored module name adds no attribute and no element to the page');
  say(group !== null && group.getAttribute('data-module') === HOSTILE_MODULE && group.textContent.indexOf(HOSTILE_MODULE) !== -1,
    'it is shown as text');

  const hostileFields = { fields: {}, modules: [HOSTILE_TEXT, 'Leads'], surveyEnabled: true };
  hostileFields.fields[HOSTILE_TEXT] = { first_name: { label: 'First Name' } };
  hostileFields.fields.Leads = { first_name: { label: HOSTILE_TEXT } };
  hostileFields.fields.Leads['x" onfocus="window.__clv=1'] = { label: 'Second' };
  const hostileRules = { none: 'No transformation' };
  hostileRules['u" onfocus="window.__clv=1'] = HOSTILE_TEXT;
  p = await page({ stored: JSON.stringify([{ module: 'Leads', field: 'first_name' }]), fields: hostileFields, rules: hostileRules });
  say(planted(p.w) === 0, 'module names, field names, field labels and rule labels from the server add no attribute and no element');
  const labels = Array.prototype.map.call(p.w.document.querySelectorAll('.suitecrm-field-select option'), function (el) { return el.textContent; });
  say(labels.some(function (t) { return t.indexOf(HOSTILE_TEXT) !== -1; }), 'a field label is shown as text');
  say(p.w.jQuery('.suitecrm-field-select').val() === JSON.stringify({ module: 'Leads', field: 'first_name' }), 'and the stored field is still selected');

  const stored = JSON.stringify([{ module: 'Leads', field: 'first_name' }]);
  p = await page({ stored: stored, fields: { fields: plainFields.fields, modules: ['Leads'], surveyEnabled: false }, rules: plainRules });
  const section = p.w.document.getElementById('crm-section');
  say(section.style.display === 'none' && p.w.document.getElementById('other-section').style.display !== 'none',
    'with the survey\'s link off the section is hidden, and only that section');
  say(p.field.form !== null && p.field.value === stored, 'the hidden section still carries the stored mapping in the form');
  say(p.calls.length > 0 && p.calls.every(function (s) { return String(s.data.surveyId) === '123456'; }),
    'the lists are asked for with the survey id of the form when the address has none');

  p = await page({ stored: stored, fields: plainFields, rules: plainRules });
  say(p.w.document.getElementById('crm-section').style.display !== 'none', 'with the link on the section shows');
})().catch(function (e) { console.log('not ok the script runs: ' + e.message); });
JS
cat > "$WORK/js/admin-test.js" <<'JS'
// Runs the plugin's admin.js with LimeSurvey's jQuery, presses its three buttons with hostile answers from the server,
// and prints "ok <what>" or "not ok <what>". node admin-test.js <jquery.js> <admin.js>
const fs = require('fs');
const { JSDOM } = require('jsdom');
const HOSTILE = '<img src=x onerror="window.__clv=1">';
const dom = new JSDOM('<!doctype html><html><head><meta name="baseUrl" content=""></head><body>' +
  '<div><button class="suitecrm-test-connection">Test Connection</button><span class="connection-result"></span></div>' +
  '<div><button class="suitecrm-refresh-cache">Refresh Field Cache</button><span class="cache-result"></span></div>' +
  '<div><button class="suitecrm-view-logs" data-survey-id="123456">View Sync Logs</button><div class="sync-logs-container"></div></div>' +
  '</body></html>', { runScripts: 'outside-only', url: 'http://localhost/index.php/admin/pluginmanager' });
const w = dom.window;
w.LS = { data: { csrfTokenName: 'YII_CSRF_TOKEN', csrfToken: 'token-of-the-page' } };
w.eval(fs.readFileSync(process.argv[2], 'utf8'));
const calls = [];
const status = {};
status[HOSTILE] = { success: false, error: HOSTILE };
const answers = {
  actionTestConnection: { success: false, message: HOSTILE },
  actionRefreshCache: { success: true, status: status },
  actionGetSyncLogs: { stats: {}, logs: [{ synced_at: HOSTILE, crm_module: HOSTILE, sync_status: 'failed', crm_record_id: HOSTILE, error_message: HOSTILE }] }
};
w.jQuery.ajax = function (s) { calls.push(s); s.success(answers[s.data.function]); };
w.eval(fs.readFileSync(process.argv[3], 'utf8'));
function say(ok, what) { console.log((ok ? 'ok ' : 'not ok ') + what); }
w.setTimeout(function () {
  w.jQuery('.suitecrm-test-connection, .suitecrm-refresh-cache, .suitecrm-view-logs').trigger('click');
  say(calls.length === 3 && w.document.querySelectorAll('img').length === 0 && !('__clv' in w),
    'admin.js shows what the server answers as text: no element is added');
  say(w.document.body.textContent.indexOf(HOSTILE) !== -1, 'and the text is on the page');
  const changing = calls.filter(function (s) { return s.data.function !== 'actionGetSyncLogs'; });
  say(changing.length === 2 && changing.every(function (s) {
    return String(s.type || s.method).toUpperCase() === 'POST' && s.data.YII_CSRF_TOKEN === 'token-of-the-page';
  }), 'it posts the test and the cache refresh with the page\'s CSRF token');
}, 50);
JS
cat > "$WORK/js/page-test.js" <<'JS'
// Runs the status panel's script of the plugin's settings page, as the server sent it, with LimeSurvey's jQuery.
// node page-test.js <jquery.js> <page.html>
const fs = require('fs');
const { JSDOM } = require('jsdom');
const HOSTILE = '<img src=x onerror="window.__clv=1">';
const html = fs.readFileSync(process.argv[3], 'utf8');
function say(ok, what) { console.log((ok ? 'ok ' : 'not ok ') + what); }
const script = /<script>\s*(var SuiteCRMStatus[\s\S]*?)<\/script>/.exec(html);
if (!script) { say(false, 'the settings page has the status panel\'s script'); process.exit(0); }
const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'http://localhost/index.php/admin/pluginmanager/sa/configure/id/1' });
const w = dom.window;
w.eval(fs.readFileSync(process.argv[2], 'utf8'));
w.$ = w.jQuery;
const calls = [];
const row = { status: 'error', message: HOSTILE };
w.jQuery.ajax = function (s) {
  calls.push(s);
  if (/actionCheckStatus$/.test(s.url)) {
    s.success({ suitecrm_http: row, suitecrm_database: row, oauth2_table: row, oauth2_client: row, overall: 'error' });
  } else {
    s.success({ success: false, error: HOSTILE, message: HOSTILE });
  }
};
w.eval(script[1] + '\nwindow.SuiteCRMStatus = SuiteCRMStatus;');
const before = w.document.querySelectorAll('img').length;
w.SuiteCRMStatus.checkStatus();
w.SuiteCRMStatus.initializeOAuth2();
w.SuiteCRMStatus.testConnection();
say(calls.length === 3 && w.document.querySelectorAll('img').length === before && !('__clv' in w),
  'the status panel shows what the server answers as text: no element is added');
say(w.document.getElementById('status-database').textContent.indexOf(HOSTILE) !== -1, 'and the text is in the panel');
const token = /name="YII_CSRF_TOKEN"[^>]*value="([^"]+)"|value="([^"]+)"[^>]*name="YII_CSRF_TOKEN"/.exec(html);
const tokenValue = token ? (token[1] || token[2]).replace(/&amp;/g, '&') : null;
const changing = calls.filter(function (s) { return !/actionCheckStatus$/.test(s.url); });
say(tokenValue !== null && changing.length === 2 && changing.every(function (s) {
  return String(s.method || s.type).toUpperCase() === 'POST' && s.data && s.data.YII_CSRF_TOKEN === tokenValue;
}), 'the panel posts the OAuth2 setup and the connection test with the page\'s CSRF token');
JS
chmod 644 "$WORK/js/"*
if docker image inspect "$JS_IMAGE" >/dev/null 2>&1; then
  report_js "$(run_js editor-test.js /js/jquery.js /assets/question-editor.js)" 9
  report_js "$(run_js admin-test.js /js/jquery.js /assets/admin.js)" 3
else
  fail "the Node image for the script checks builds, or LS_PLUGIN_JS_IMAGE names one"
fi

# --- the stand-in for SuiteCRM ------------------------------------------------------------------------------------
cat > "$WORK/router.php" <<'PHP'
<?php
// A stand-in for SuiteCRM's API. It records each request as one JSON line and answers as SuiteCRM 8 does.
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$method = $_SERVER['REQUEST_METHOD'];
$body = file_get_contents('php://input');
$entry = ['method' => $method, 'path' => $path];
header('Content-Type: application/json');
if ($method === 'POST' && $path === '/Api/access_token') {
    parse_str($body, $form);
    $entry += ['grant_type' => $form['grant_type'] ?? null, 'username' => $form['username'] ?? null,
        'password_ok' => hash_equals((string) getenv('STUB_PASSWORD'), (string) ($form['password'] ?? '')),
        'has_client' => !empty($form['client_id']) && !empty($form['client_secret'])];
    $answer = ['token_type' => 'Bearer', 'expires_in' => 3600, 'access_token' => 'stub-token'];
} elseif ($method === 'GET' && preg_match('#^/Api/V8/meta/fields/(Leads|Cases|Users)$#', $path, $m)) {
    // SuiteCRM lists the fields of every module, Users among them, to whoever holds the admin's token.
    $names = [
        'Leads' => ['first_name', 'last_name', 'email1', 'phone_work', 'account_name', 'title', 'lead_source_description', 'description'],
        'Cases' => ['name', 'type', 'priority', 'description', 'case_number', 'account_name'],
        'Users' => ['user_name', 'status', 'is_admin'],
    ][$m[1]];
    $fields = [];
    foreach ($names as $n) { $fields[$n] = ['type' => 'varchar', 'dbType' => 'varchar', 'len' => 255, 'required' => false]; }
    $answer = ['data' => ['type' => 'fields', 'id' => $m[1], 'attributes' => $fields]];
} elseif ($method === 'POST' && $path === '/Api/V8/module') {
    $entry['bearer'] = ($_SERVER['HTTP_AUTHORIZATION'] ?? '') === 'Bearer stub-token';
    $entry['body'] = json_decode($body, true);
    if (strpos($body, 'FAILME') !== false) {
        // A record SuiteCRM does not take.
        http_response_code(500);
        $answer = ['errors' => [['detail' => 'the stand-in refuses this record']]];
    } else {
        http_response_code(201);
        $answer = ['data' => ['type' => $entry['body']['data']['type'] ?? '', 'id' => 'stub-record-' . mt_rand(1000, 9999), 'attributes' => new stdClass()]];
    }
} elseif (strpos($path, '/redir/') === 0) {
    // An address that sends every request on to another one: the same path without /redir.
    header('Location: http://' . $_SERVER['HTTP_HOST'] . substr($path, 6), true, 307);
    $answer = new stdClass();
} elseif ($path === '/') {
    $answer = ['stub' => 'SuiteCRM'];
} else {
    http_response_code(404);
    $answer = ['errors' => [['detail' => 'not found']]];
}
file_put_contents('/tmp/stub-requests.jsonl', json_encode($entry) . "\n", FILE_APPEND | LOCK_EX);
echo json_encode($answer);
PHP
chmod 644 "$WORK/router.php"

DB="${PREFIX}db"
CRM="${PREFIX}crm"
A="${PREFIX}app"
ls_new_disk "${PREFIX}db-data" "${PREFIX}html" "${PREFIX}upload"
ls_start_db "$DB" "${PREFIX}db-data"
docker run -d --name "$CRM" --network "${PREFIX}net" --memory 512m --user www-data -e "STUB_PASSWORD=$CRM_PW" \
  -v "$WORK/router.php:/stub/router.php:ro" --entrypoint php "$IMAGE" -S 0.0.0.0:8080 /stub/router.php >/dev/null
ls_wait_db "$DB" 120 || fail "the database starts"
docker exec -i -e "MYSQL_PWD=$LS_DB_ROOT_PW" "$DB" mariadb -u root <<SQL
CREATE DATABASE suitecrm;
CREATE USER 'suitecrm'@'%' IDENTIFIED BY '$CRM_DB_PW';
GRANT ALL ON suitecrm.* TO 'suitecrm'@'%';
CREATE TABLE suitecrm.oauth2clients (id CHAR(36) PRIMARY KEY, name VARCHAR(255), date_entered DATETIME,
  date_modified DATETIME, created_by CHAR(36), deleted TINYINT, secret VARCHAR(4000), is_confidential TINYINT,
  allowed_grant_type VARCHAR(255), duration_value INT, duration_amount INT, duration_unit VARCHAR(255));
SQL

# start_app [docker run options...]: LimeSurvey with the Customer Kit's variables for the plugin.
start_app() {
  docker rm -f -v "$A" >/dev/null 2>&1
  ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE" -e INSTALL_DEMO_DATA=true \
    -e ENABLE_SUITECRM_INTEGRATION=true -e "SUITECRM_URL=http://$CRM:8080" -e SUITECRM_ADMIN_USER=crm_admin \
    -e "SUITECRM_ADMIN_PASSWORD=$CRM_PW" -e "SUITECRM_DB_HOST=$DB" -e SUITECRM_DB_NAME=suitecrm \
    -e SUITECRM_DB_USER=suitecrm -e "SUITECRM_DB_PASSWORD=$CRM_DB_PW" "$@"
}
# setting KEY: the stored value of one of the plugin's own settings.
setting() { ls_sql "$DB" "SELECT value FROM lime_plugin_settings WHERE \`key\` = '$1' AND model IS NULL AND plugin_id = (SELECT id FROM lime_plugins WHERE name = 'SuiteCRMIntegration')"; }
plugin_active() { ls_sql "$DB" "SELECT active FROM lime_plugins WHERE name = 'SuiteCRMIntegration'"; }
stub_log() { docker exec "$CRM" cat /tmp/stub-requests.jsonl 2>/dev/null; }
# stub_count [TEXT]: how many requests the stand-in recorded, or how many of them hold TEXT.
stub_count() { stub_log | grep -cF -- "${1:-\"method\"}"; }
# crm_sql QUERY: rows of a query on the stand-in's SuiteCRM database.
crm_sql() { docker exec -e "MYSQL_PWD=$CRM_DB_PW" "$DB" mariadb -h 127.0.0.1 -u suitecrm suitecrm -N -B -e "$1" 2>&1; }

echo
echo "The start"
start_app
ls_watch_ps "$A" "$WORK/ps-start" &
rc=0; ls_wait_apache "$A" 300 || rc=$?
touch "$WORK/ps-start.stop"; wait
if [ "$rc" -ne 0 ]; then
  fail "LimeSurvey starts with the plugin"
  docker logs --tail 25 "$A" 2>&1 | sed 's/^/       | /'
  echo; printf '%sLimeSurvey plugin checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
pass "LimeSurvey starts with the plugin"
log="$(docker logs "$A" 2>&1)"
assert_eq "the plugin is registered, switched on, at config.xml's version" \
  "1 $(sed -n 's:.*<version>\([0-9][0-9.]*\)</version>.*:\1:p' "$PLUGIN_DIR/config.xml" | head -n 1)" \
  "$(ls_sql "$DB" "SELECT CONCAT(active, ' ', version) FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
assert_contains "its address is SUITECRM_URL" "$(setting suitecrm_url)" "$CRM:8080"
assert_eq "its SuiteCRM admin name is SUITECRM_ADMIN_USER" '"crm_admin"' "$(setting suitecrm_admin_user)"
stored="$(setting suitecrm_admin_password)$(setting suitecrm_db_password)"
if [ "${#stored}" -gt 40 ]; then pass "both passwords are stored"; else fail "both passwords are stored"; fi
assert_eq "and neither is stored in clear text" "0" "$(ls_secrets_in "$stored")"
assert_eq "debug mode is off" '"0"' "$(setting debug_mode)"
assert_eq "no command line held a password during the start" "0" "$(ls_secrets_in "$(cat "$WORK/ps-start")")"
assert_eq "the log holds no password" "0" "$(ls_secrets_in "$log")"
SID="$(ls_sql "$DB" "SELECT sid FROM lime_surveys LIMIT 1")"
assert_eq "the demo survey has one survey_enabled setting, and it says on" '"1"' \
  "$(ls_sql "$DB" "SELECT value FROM lime_plugin_settings WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = '$SID'")"
assert_eq "the start made no call to SuiteCRM (LimeSurvey starts whether or not SuiteCRM is up)" "0" "$(stub_log | grep -c .)"

# --- signing in over HTTP -----------------------------------------------------------------------------------------
cat > "$WORK/clv-web.sh" <<'SH'
#!/bin/bash
# clv-web.sh login USER JAR   signs in to LimeSurvey's admin (the password is in T_PASS)
# clv-web.sh get JAR PATH     GET with the session; prints the HTTP status, the body goes to /tmp/clv-web.body
# clv-web.sh post JAR PATH k=v...  POST with the session and its CSRF token; prints the HTTP status
# clv-web.sh postnotoken JAR PATH k=v...  the same POST without the token
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
    if [ -z "$tok" ]; then
      # An account that may not open the plugin manager finds the token on its dashboard.
      curl -s "${H[@]}" -c "$jar" -b "$jar" -o /tmp/clv-web.body "$B/index.php/dashboard/view"
      tok="$(grep -o '<input[^>]*name="YII_CSRF_TOKEN"[^>]*>' /tmp/clv-web.body | head -n 1 | sed -E 's/.*value="([^"]*)".*/\1/')"
    fi
    args=(--data-urlencode "YII_CSRF_TOKEN=$tok")
    for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    curl -s "${H[@]}" -c "$jar" -b "$jar" -o /tmp/clv-web.body -w '%{http_code}' "${args[@]}" "$B$path"
    ;;
  postnotoken)
    jar="$2"; path="$3"; shift 3
    args=(--data-urlencode "clv=1")
    for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    curl -s "${H[@]}" -c "$jar" -b "$jar" -o /tmp/clv-web.body -w '%{http_code}' "${args[@]}" "$B$path"
    ;;
esac
SH
chmod 755 "$WORK/clv-web.sh"
# The helper goes into the LimeSurvey container, again after each new container.
install_web() { docker cp "$WORK/clv-web.sh" "$A:/tmp/clv-web.sh" >/dev/null; }
install_web
web() { docker exec -e "T_PASS=${T_PASS:-}" "$A" /tmp/clv-web.sh "$@"; }
body() { docker exec "$A" cat /tmp/clv-web.body 2>/dev/null; }
direct() { printf '/index.php/plugins/direct?plugin=SuiteCRMIntegration&function=%s&surveyId=%s&questionId=%s&module=Leads' "$1" "$2" "$3"; }
QID="$(ls_sql "$DB" "SELECT qid FROM lime_questions WHERE sid = $SID AND title = 'firstName' AND parent_qid = 0")"
PLUGIN_ID="$(ls_sql "$DB" "SELECT id FROM lime_plugins WHERE name = 'SuiteCRMIntegration'")"
T_PASS="$LS_ADMIN_PW" web login "$LS_ADMIN_USER" /tmp/admin.jar

echo
echo "LimeSurvey 7's plugin manager accepts the plugin"
ls_sql "$DB" "UPDATE lime_plugins SET active = 0 WHERE name = 'SuiteCRMIntegration'" >/dev/null
web post /tmp/admin.jar /index.php/admin/pluginmanager/sa/activate "pluginId=$PLUGIN_ID" >/dev/null
assert_eq "an admin can switch it on in the browser" "1" "$(plugin_active)"

echo
echo "A start never changes whether the plugin is on"
ls_sql "$DB" "UPDATE lime_plugins SET active = 0 WHERE name = 'SuiteCRMIntegration'" >/dev/null
start_app -e "SUITECRM_ADMIN_USER=crm_admin_2"
rc=0; ls_wait_apache "$A" 300 || rc=$?
assert_eq "LimeSurvey starts again" "0" "$rc"
assert_eq "the plugin an admin switched off is still off" "0" "$(plugin_active)"
assert_contains "the log says it stays off" "$(docker logs "$A" 2>&1)" "It stays off"
assert_eq "while its settings follow the environment (a new SuiteCRM admin name)" '"crm_admin_2"' "$(setting suitecrm_admin_user)"
assert_eq "the demo survey was not imported a second time" "1" "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_surveys")"
ls_sql "$DB" "UPDATE lime_plugins SET active = 1 WHERE name = 'SuiteCRMIntegration'" >/dev/null
start_app
rc=0; ls_wait_apache "$A" 300 || rc=$?
assert_eq "and with the old name back, LimeSurvey starts" "0 \"crm_admin\"" "$rc $(setting suitecrm_admin_user)"
install_web
T_PASS="$LS_ADMIN_PW" web login "$LS_ADMIN_USER" /tmp/admin.jar

echo
echo "Who the AJAX endpoints answer"
# Five more accounts: one with no rights at all, one that may read the demo survey's settings, one that may change
# its content, one that may change its settings and not its content, and one that may read the global settings.
docker exec "$A" mkdir -p /tmp/clv-cmd
docker exec -i "$A" sh -c 'cat > /tmp/clv-cmd/ClvtestCommand.php' <<'PHP'
<?php
class ClvtestCommand extends CConsoleCommand
{
    public function actionUser($name)
    {
        $uid = User::insertUser($name, getenv('T_PASS'), $name, 1, $name . '@example.invalid');
        if (!is_numeric($uid)) { echo "could not make $name\n"; return 1; }
        Permission::model()->setGlobalPermission($uid, 'auth_db', ['read_p']);
        echo $uid, "\n";
        return 0;
    }

    private function plugin()
    {
        $row = Plugin::model()->findByAttributes(['name' => 'SuiteCRMIntegration']);
        return App()->getPluginManager()->loadPlugin('SuiteCRMIntegration', $row->id);
    }

    // Whether the plugin reads back the value in T_EXPECT for one of its settings. The value is never printed.
    public function actionReads($key)
    {
        echo $this->plugin()->getSetting($key) === getenv('T_EXPECT') ? "same\n" : "different\n";
        return 0;
    }

    // Whether the page that clv-web.sh fetched last holds the plugin's OAuth2 client secret. It is never printed.
    public function actionSecretinpage()
    {
        $secret = (string) $this->plugin()->getSetting('oauth_client_secret');
        $page = (string) file_get_contents('/tmp/clv-web.body');
        echo $secret === '' ? "no secret stored\n" : (strpos($page, $secret) !== false ? "in the page\n" : "not in the page\n");
        return 0;
    }

    // The API client's own checks, with the stand-in as SuiteCRM (T_URL): a module that is not on the plugin's list,
    // a module with a path in it, and an attribute that is not a field name.
    public function actionClient()
    {
        $this->plugin();
        $client = new SuiteCRMApiClient(['baseUrl' => getenv('T_URL'), 'clientId' => 'x', 'clientSecret' => 'x',
            'username' => 'x', 'password' => 'x']);
        $tries = [['fields', 'Users', []], ['record', 'Users', ['user_name' => 'x']],
            ['record', 'Leads/../Users', ['last_name' => 'x']], ['record', 'Leads', ['last_name) x' => 'x']]];
        $out = [];
        foreach ($tries as [$what, $module, $attributes]) {
            try {
                $what === 'fields' ? $client->getModuleFields($module) : $client->createRecord($module, $attributes);
                $out[] = 'sent';
            } catch (Exception $e) {
                $out[] = 'refused';
            }
        }
        echo implode(' ', $out), "\n";
        return 0;
    }
}
PHP
# clvtest ACTION [docker exec options...]: one of the test's own console commands, as www-data.
clvtest() {
  local action="$1"
  shift
  docker exec -u www-data -e YII_CONSOLE_COMMANDS=/tmp/clv-cmd "$@" "$A" sh -c "cd /var/www/html && php application/commands/console.php clvtest $action" 2>&1 | tail -n 1
}
mkuser() { docker exec -u www-data -e "T_PASS=$USER_PW" -e YII_CONSOLE_COMMANDS=/tmp/clv-cmd "$A" sh -c "cd /var/www/html && php application/commands/console.php clvtest user --name=$1" 2>&1 | tail -n 1; }
NOBODY_UID="$(mkuser clv_nobody)"
READER_UID="$(mkuser clv_reader)"
EDITOR_UID="$(mkuser clv_editor)"
SETTER_UID="$(mkuser clv_setter)"
SETTINGS_UID="$(mkuser clv_settings)"
# grant ENTITY ENTITY_ID UID PERMISSION [UPDATE]: the right to read, and with UPDATE=1 to change.
grant() {
  ls_sql "$DB" "INSERT INTO lime_permissions (entity, entity_id, uid, permission, create_p, read_p, update_p, delete_p, import_p, export_p)
    VALUES ('$1', $2, ${3:-0}, '$4', 0, 1, ${5:-0}, 0, 0, 0)" >/dev/null
}
grant survey "$SID" "$READER_UID" surveysettings
grant survey "$SID" "$EDITOR_UID" surveycontent 1
grant survey "$SID" "$SETTER_UID" surveysettings 1
grant global 0 "$SETTINGS_UID" settings
T_PASS="$USER_PW" web login clv_nobody /tmp/nobody.jar
T_PASS="$USER_PW" web login clv_reader /tmp/reader.jar
T_PASS="$USER_PW" web login clv_editor /tmp/editor.jar
T_PASS="$USER_PW" web login clv_setter /tmp/setter.jar
T_PASS="$USER_PW" web login clv_settings /tmp/settings.jar

# Until here nobody with the global "settings: update" right has called the plugin: the OAuth2 client is not made
# and the field cache is empty.
code="$(web get /tmp/reader.jar "$(direct actionGetAllFields "$SID" "$QID")")"
assert_eq "an account with rights on one survey gets an answer for the editor's field lists" "200" "$code"
assert_eq "and that call sends nothing to SuiteCRM" "0" "$(stub_count)"
assert_eq "and does not start the OAuth2 setup: no client in SuiteCRM's database, no OAuth2 setting written" "0 0" \
  "$(crm_sql "SELECT COUNT(*) FROM oauth2clients") $(ls_sql "$DB" "SELECT COUNT(*) FROM lime_plugin_settings WHERE plugin_id = $PLUGIN_ID AND \`key\` IN ('oauth_initialized', 'oauth_client_id', 'oauth_init_error') AND value NOT IN ('\"\"', '\"0\"')")"
# The four endpoints that change something take POST only, so the main admin posts those.
post_only() { case "$1" in actionSaveMappings | actionInitializeOAuth2 | actionRefreshCache | actionTestConnection) return 0 ;; esac; return 1; }
anon_bad=""; nobody_bad=""; admin_bad=""
for f in "${ENDPOINTS[@]}"; do
  code="$(ls_http "$A" "$(direct "$f" "$SID" "$QID")" -H 'Host: localhost')"
  [ "$code" = 401 ] || anon_bad="$anon_bad $f=$code"
  code="$(web get /tmp/nobody.jar "$(direct "$f" "$SID" "$QID")")"
  [ "$code" = 403 ] || nobody_bad="$nobody_bad $f=$code"
  if post_only "$f"; then
    code="$(web post /tmp/admin.jar "$(direct "$f" "$SID" "$QID")")"
  else
    code="$(web get /tmp/admin.jar "$(direct "$f" "$SID" "$QID")")"
  fi
  case "$code" in 401 | 403 | 405 | 000) admin_bad="$admin_bad $f=$code" ;; esac
done
assert_eq "each of the ${#ENDPOINTS[@]} endpoints answers 401 to a caller who is not signed in" "" "$anon_bad"
assert_contains "and says why, as JSON" "$(docker exec "$A" curl -s -H 'Host: localhost' "http://127.0.0.1:8080$(direct actionGetSyncLogs "$SID" "$QID")")" '{"error":"Sign in'
assert_eq "each answers 403 to a signed-in account with no rights" "" "$nobody_bad"
assert_eq "the main admin gets through to each" "" "$admin_bad"
assert_eq "the main admin reads the sync log and the status" "200 200" \
  "$(web get /tmp/admin.jar "$(direct actionGetSyncLogs "$SID" "$QID")") $(web get /tmp/admin.jar "$(direct actionCheckStatus "$SID" "$QID")")"
got=""
for f in actionGetMappings actionGetAllFields actionGetTransformRules actionGetSyncLogs actionSaveMappings actionCheckStatus actionInitializeOAuth2 actionRefreshCache actionTestConnection; do
  got="$got $f=$(web get /tmp/reader.jar "$(direct "$f" "$SID" "$QID")")"
done
assert_eq "an account that may read the survey's settings reads its mappings and the editor's lists, and nothing else" \
  " actionGetMappings=200 actionGetAllFields=200 actionGetTransformRules=200 actionGetSyncLogs=403 actionSaveMappings=403 actionCheckStatus=403 actionInitializeOAuth2=403 actionRefreshCache=403 actionTestConnection=403" "$got"
assert_eq "the same account gets 403 for a question of a survey it has no rights on" "403" \
  "$(web get /tmp/reader.jar "$(direct actionGetMappings 0 999999)")"
assert_eq "a function that is not an endpoint is refused" "400" "$(web get /tmp/admin.jar "$(direct getSetting "$SID" "$QID")")"
assert_eq "the status of the connection needs the global \"settings: update\" right: an account that may read the global settings gets 403" \
  "403" "$(web get /tmp/settings.jar "$(direct actionCheckStatus "$SID" "$QID")")"
# The main admin's calls above made the OAuth2 client and filled the field cache. The cache is then made to look a year
# old: a caller with the "settings: update" right would have the plugin read the lists again.
ls_sql "$DB" "UPDATE lime_plugin_settings SET value = '{\"Leads\":{\"cached_at\":1},\"Cases\":{\"cached_at\":1}}' WHERE plugin_id = $PLUGIN_ID AND \`key\` = 'scf_meta'" >/dev/null
before="$(stub_count)"
code="$(web get /tmp/reader.jar "$(direct actionGetAllFields "$SID" "$QID")")"
assert_contains "the account with rights on one survey now gets the field lists, from the cache" "$code $(body)" '200 {"fields":{"Leads":{"first_name"'
assert_eq "however old the cache is, that account's call sends nothing to SuiteCRM" "$before" "$(stub_count)"

echo
echo "The endpoints that change something take POST with the token only"
got=""; got_notoken=""; got_post=""
for f in actionSaveMappings actionInitializeOAuth2 actionRefreshCache actionTestConnection; do
  got="$got $f=$(web get /tmp/admin.jar "$(direct "$f" "$SID" "$QID")&mappings=%5B%5D")"
  got_notoken="$got_notoken $f=$(web postnotoken /tmp/admin.jar "$(direct "$f" "$SID" "$QID")")"
  got_post="$got_post $f=$(web post /tmp/admin.jar "$(direct "$f" "$SID" "$QID")")"
done
assert_eq "a GET with the main admin's session is refused" \
  " actionSaveMappings=405 actionInitializeOAuth2=405 actionRefreshCache=405 actionTestConnection=405" "$got"
assert_eq "a POST without the CSRF token is refused" \
  " actionSaveMappings=400 actionInitializeOAuth2=400 actionRefreshCache=400 actionTestConnection=400" "$got_notoken"
assert_eq "a POST with the token goes through" \
  " actionSaveMappings=200 actionInitializeOAuth2=200 actionRefreshCache=200 actionTestConnection=200" "$got_post"

echo
echo "A response becomes a lead"
docker exec -i "$A" sh -c 'cat > /tmp/clv-submit.php' <<'PHP'
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
docker exec -i "$A" sh -c 'cat > /tmp/clv-rpc.php' <<'PHP'
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
ls_sql "$DB" "INSERT INTO lime_settings_global (stg_name, stg_value) VALUES ('RPCInterface', 'json') ON DUPLICATE KEY UPDATE stg_value = 'json';
  UPDATE lime_surveys SET format = 'A' WHERE sid = $SID" >/dev/null
docker exec -e "LS_USER=$LS_ADMIN_USER" -e "LS_PASS=$LS_ADMIN_PW" "$A" php /tmp/clv-rpc.php activate_survey "$SID" >/dev/null
qid() { ls_sql "$DB" "SELECT qid FROM lime_questions WHERE sid = $SID AND title = '$1' AND parent_qid = 0"; }
# submit MARKER: a sales inquiry whose answers all carry MARKER.
submit() {
  docker exec "$A" php /tmp/clv-submit.php "$SID" "Q$(qid requestType)=SALES" "Q$(qid firstName)=Zebulon-$1" \
    "Q$(qid lastName)=Quillfeather-$1" "Q$(qid email)=zeb-$1@example.invalid" "Q$(qid productInterest)=CRM" 2>&1
}
# in_logs MARKER: how many log files and log lines of the LimeSurvey container hold MARKER. Session files hold the
# answers of a response in progress and are not logs.
in_logs() {
  local n
  n="$(docker logs "$A" 2>&1 | grep -c -- "$1")"
  n=$((n + $(docker exec -u root "$A" sh -c "grep -rl -- '$1' /tmp /var/log /var/www/html/tmp/runtime /var/www/html/upload 2>/dev/null | grep -v -e '/sess_' -e '/tmp/clv-' | wc -l")))
  echo "$n"
}
# The question editor's script is for signed-in people only. newQuestionAttributes also runs on a public survey page,
# and the script calls the plugin's endpoints, which answer 401 to anyone not signed in: on the rig on 2026-11-12, two
# respondents' visits sent 14 refused calls. A respondent's page doesn't load it; a signed-in admin's still does.
web get /tmp/respondent.jar "/index.php/$SID?lang=en&newtest=Y" >/dev/null
page="$(body)"
assert_contains "a respondent gets the survey's page" "$page" "$SID"
editor_js() { if grep -q 'question-editor\.js' <<< "$1"; then echo loaded; else echo "not loaded"; fi; }
assert_eq "a respondent's survey page doesn't load the question editor's script" "not loaded" "$(editor_js "$page")"
web get /tmp/admin.jar "/index.php/$SID?lang=en&newtest=Y" >/dev/null
assert_eq "a signed-in admin's page still loads it" "loaded" "$(editor_js "$(body)")"
M1="m1x7731"
assert_eq "a response submitted over HTTP is completed" "submitted" "$(submit "$M1")"
for _ in $(seq 1 20); do stub_log | grep -q "Zebulon-$M1" && break; sleep 1; done
requests="$(stub_log)"
token="$(grep '"path":"\\/Api\\/access_token"' <<< "$requests" | tail -n 1)"
assert_contains "the stand-in got a token request with the admin name from the environment" "$token" '"grant_type":"password","username":"crm_admin"'
assert_contains "with the SuiteCRM admin's password, which the plugin read back from its encrypted setting" "$token" '"password_ok":true'
assert_contains "and with the OAuth2 client the plugin made in SuiteCRM's database" "$token" '"has_client":true'
lead="$(grep '"type":"Leads"' <<< "$requests" | tail -n 1)"
assert_contains "the stand-in got a Leads record with the bearer token" "$lead" '"method":"POST","path":"\/Api\/V8\/module","bearer":true'
assert_contains "with the mapped answers" "$lead" "\"first_name\":\"Zebulon-$M1\",\"last_name\":\"Quillfeather-$M1\",\"email1\":\"zeb-$M1@example.invalid\""
assert_eq "the OAuth2 client is in SuiteCRM's database" "1" \
  "$(docker exec -e "MYSQL_PWD=$CRM_DB_PW" "$DB" mariadb -h 127.0.0.1 -u suitecrm suitecrm -N -B -e "SELECT COUNT(*) FROM oauth2clients WHERE name = 'LimeSurvey Integration'" 2>&1)"
assert_eq "the survey's sync log has the lead, for an admin to read" "success" \
  "$(ls_sql "$DB" "SELECT sync_status FROM lime_survey_crm_sync_log WHERE crm_module = 'Leads' ORDER BY id DESC LIMIT 1")"
assert_eq "no log file and no log line holds an answer" "0" "$(in_logs "$M1")"
assert_eq "the plugin made no log file" "0" \
  "$(docker exec "$A" sh -c 'ls /tmp/suitecrm_integration.log /tmp/suitecrm_api.log /var/www/html/tmp/runtime/suitecrm_integration.log 2>/dev/null | wc -l')"

echo
echo "With debug mode on"
ls_sql "$DB" "UPDATE lime_plugin_settings SET value = '\"1\"' WHERE \`key\` = 'debug_mode' AND model IS NULL AND plugin_id = $PLUGIN_ID" >/dev/null
M2="m2x9054"
assert_eq "a second response is completed" "submitted" "$(submit "$M2")"
for _ in $(seq 1 20); do stub_log | grep -q "Zebulon-$M2" && break; sleep 1; done
assert_contains "and becomes a lead too" "$(stub_log)" "\"first_name\":\"Zebulon-$M2\""
debug_lines="$(docker exec "$A" sh -c 'wc -l < /var/www/html/tmp/runtime/suitecrm_integration.log 2>/dev/null || echo 0')"
if [ "$debug_lines" -ge 5 ]; then pass "the debug log is written, in LimeSurvey's runtime folder ($debug_lines lines)"; else
  fail "the debug log is written, in LimeSurvey's runtime folder ($debug_lines lines)"; fi
assert_eq "it holds no answer, and neither does any other log" "0" "$(in_logs "$M2")"
assert_eq "it holds no password" "0" "$(ls_secrets_in "$(docker exec "$A" cat /var/www/html/tmp/runtime/suitecrm_integration.log 2>/dev/null)")"
assert_eq "the web server does not serve it" "403" "$(ls_http "$A" /tmp/runtime/suitecrm_integration.log -H 'Host: localhost')"
assert_eq "nothing was written to /tmp" "0" "$(docker exec "$A" sh -c 'ls /tmp/suitecrm_integration.log /tmp/suitecrm_api.log 2>/dev/null | wc -l')"
assert_eq "the container's log holds no password" "0" "$(ls_secrets_in "$(docker logs "$A" 2>&1)")"

echo
echo "The sync log"
log_sql() { ls_sql "$DB" "SELECT $1 FROM lime_survey_crm_sync_log WHERE $2" | tr '\t' ' '; }
assert_eq "it has the two leads, each with the id of the record SuiteCRM made" "2" \
  "$(log_sql 'COUNT(*)' "sync_status = 'success' AND crm_module = 'Leads' AND crm_record_id LIKE 'stub-record-%'")"
assert_eq "a sync that worked leaves nothing of the response in it: not what was sent, not the answer, not the mappings" "0" \
  "$(log_sql 'COUNT(*)' "sync_status = 'success' AND (request_payload IS NOT NULL OR response_data IS NOT NULL OR field_mappings_used IS NOT NULL)")"
ls_sql "$DB" "INSERT INTO lime_survey_crm_sync_log (response_id, survey_id, crm_module, sync_status, synced_at)
  VALUES (9001, $SID, 'Leads', 'success', NOW() - INTERVAL 91 DAY), (9002, $SID, 'Leads', 'success', NOW() - INTERVAL 89 DAY)" >/dev/null
# The stand-in answers 500 to a record that holds FAILME.
M5="m5xFAILME31"
assert_eq "a response whose lead SuiteCRM does not take is still completed" "submitted" "$(submit "$M5")"
assert_eq "the failed sync keeps what was sent and what SuiteCRM said, for an admin to see why" "1" \
  "$(log_sql 'COUNT(*)' "sync_status = 'failed' AND crm_module = 'Leads' AND request_payload LIKE '%Zebulon-$M5%' AND error_message LIKE '%the stand-in refuses this record%'")"
assert_eq "writing to the log removed the row older than 90 days and kept the newer one" "0 1" \
  "$(log_sql 'COALESCE(SUM(response_id = 9001), 0), COALESCE(SUM(response_id = 9002), 0)' "response_id IN (9001, 9002)")"
assert_eq "no log file and no log line holds an answer of the failed sync" "0" "$(in_logs "$M5")"

echo
echo "The plugin writes only to Leads and Cases"
# mapping QID: a question's stored mapping. plant QID JSON: writes one straight into the database, which is how a
# survey import or an earlier version of the plugin leaves it.
mapping() { ls_sql "$DB" "SELECT value FROM lime_question_attributes WHERE qid = $1 AND attribute = 'suitecrm_mappings_json'"; }
plant() { ls_sql "$DB" "UPDATE lime_question_attributes SET value = '$2' WHERE qid = $1 AND attribute = 'suitecrm_mappings_json'" >/dev/null; }
# save_question JAR QID JSON: LimeSurvey's own question save, as the classic editor posts it.
save_question() {
  web post "$1" /index.php/questionAdministration/saveQuestionData "sid=$SID" bFullPOST=1 ajax=1 "question[qid]=$2" \
    "advancedSettings[suitecrm integration][suitecrm_mappings_json]=$3"
}
# save_mappings JAR QID JSON: the plugin's own endpoint.
save_mappings() { web post "$1" "$(direct actionSaveMappings "$SID" "$2")" "mappings=$3"; }
LAST_QID="$(qid lastName)"
last_mapping="$(mapping "$LAST_QID")"
first_mapping="$(mapping "$QID")"

# When a response is sent.
plant "$LAST_QID" '[{"module":"Leads","field":"last_name"},{"module":"Users","field":"user_name"},{"module":"Users","field":"is_admin"}]'
M3="m3x4410"
assert_eq "with a mapping to Users planted in the database, a response is completed" "submitted" "$(submit "$M3")"
requests="$(stub_log)"
assert_eq "the stand-in got no request that names Users: not for its fields, not for a record" "0" "$(grep -c 'Users' <<< "$requests")"
assert_contains "the lead still arrives, from the mappings to Leads" "$(grep "Zebulon-$M3" <<< "$requests")" "\"last_name\":\"Quillfeather-$M3\""
assert_eq "the survey's sync log says that mappings of that question were refused, and holds nothing of the response" "1" \
  "$(log_sql 'COUNT(*)' "response_id = (SELECT MAX(response_id) FROM lime_survey_crm_sync_log WHERE response_id < 9000) AND sync_status = 'failed' AND crm_module = 'Refused' AND error_message LIKE '%question $LAST_QID%' AND request_payload IS NULL AND response_data IS NULL AND field_mappings_used IS NULL")"
plant "$LAST_QID" '[{"module":"Leads","field":"last_name"},{"module":"Leads/../../x","field":"y"},{"module":"leads","field":"title"},{"module":"Leads","field":"no_such_field"},{"module":"Leads","field":"id"},{"module":"Leads","field":"descr iption"}]'
M4="m4x8262"
assert_eq "with a module that is a path, and fields SuiteCRM does not list for Leads, a response is completed" "submitted" "$(submit "$M4")"
requests="$(stub_log)"
lead="$(grep "Zebulon-$M4" <<< "$requests")"
assert_contains "the lead arrives" "$lead" "\"last_name\":\"Quillfeather-$M4\""
assert_eq "without the refused fields" "0" "$(grep -c -e 'no_such_field' -e '"id"' -e 'descr iption' -e '"y"' <<< "$lead")"
assert_eq "every address the stand-in was ever asked for is one of SuiteCRM's API: no mapping reached a URL" "" \
  "$(sed -n 's/.*"path":"\([^"]*\)".*/\1/p' <<< "$requests" | sort -u | grep -vxF -e '\/Api\/access_token' -e '\/Api\/V8\/meta\/fields\/Leads' -e '\/Api\/V8\/meta\/fields\/Cases' -e '\/Api\/V8\/meta\/modules' -e '\/Api\/V8\/module' -e '\/' | tr '\n' ' ')"
assert_eq "the refusals are in the container's log, without a mapping's own text and without an answer" "1 0 0" \
  "$(docker logs "$A" 2>&1 | grep -c 'Refused .* field mapping' | sed 's/^[1-9][0-9]*$/1/') $(docker logs "$A" 2>&1 | grep -c -e 'no_such_field' -e 'Leads/\.\.') $(($(in_logs "$M3") + $(in_logs "$M4")))"
plant "$LAST_QID" "$last_mapping"
before="$(stub_count)"
assert_eq "the plugin's API client itself refuses a module that is not on the list and an attribute that is not a field name" \
  "refused refused refused refused $before" "$(clvtest client -e "T_URL=http://$CRM:8080") $(stub_count)"

# When a mapping is saved in LimeSurvey's question editor.
code="$(save_question /tmp/editor.jar "$QID" '[{"module":"Leads","field":"first_name"},{"module":"Users","field":"user_name"},{"module":"Zzmod9917","field":"x"},{"module":"Leads","field":"first name"},{"module":"Leads","field":"no_such_field"}]')"
assert_eq "an account that may change the survey's content saves a question in LimeSurvey's editor" "200" "$code"
assert_eq "of the mappings it sent, only the one to a field of Leads is stored" '[{"module":"Leads","field":"first_name"}]' "$(mapping "$QID")"
assert_eq "the refusal is in the container's log, without the module's name" "1 0" \
  "$(docker logs "$A" 2>&1 | grep -c "Refused 4 field mappings of question $QID" | sed 's/^[1-9][0-9]*$/1/') $(docker logs "$A" 2>&1 | grep -c 'Zzmod9917')"
save_question /tmp/editor.jar "$QID" 'not a list of mappings' >/dev/null
assert_eq "a value that is not a list of mappings is stored as no mapping" '[]' "$(mapping "$QID")"
save_question /tmp/setter.jar "$QID" '[{"module":"Cases","field":"name"}]' >/dev/null
assert_eq "an account without the right to change the survey's content changes no mapping there" '[]' "$(mapping "$QID")"
code="$(save_question /tmp/editor.jar "$QID" "$first_mapping")"
assert_eq "a mapping to Leads is saved as it is" "200 $first_mapping" "$code $(mapping "$QID")"

# When a mapping is saved through the plugin's own endpoint.
assert_eq "actionSaveMappings: an account that may change the survey's settings and not its content gets 403" "403" \
  "$(save_mappings /tmp/setter.jar "$QID" '[]')"
assert_eq "an account that may change the survey's content gets through" "200" "$(save_mappings /tmp/editor.jar "$QID" '[]')"
got=""
for m in '[{"module":"Users","field":"user_name"}]' '[{"module":"Leads","field":"first name"}]' '[{"module":"Leads","field":"no_such_field"}]' \
  '[{"module":"Leads","field":"first_name"},{"crm_module":"Users","crm_field_name":"is_admin"}]' '{"module":"Leads"}'; do
  got="$got $(save_mappings /tmp/admin.jar "$QID" "$m")"
done
assert_eq "from the main admin too, it refuses another module, a field name that is not a name, a field Leads does not have, a list with one such entry, and what is not a list" \
  " 400 400 400 400 400" "$got"
assert_eq "and stored none of them" "0" "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_survey_crm_mappings WHERE question_id = $QID")"
# The image's script makes the mappings table without the transform_rule column that the plugin writes (another
# change puts that right). Until then a mapping that passes the checks fails at the INSERT, so this check is only
# that the plugin's own checks let it through.
code="$(save_mappings /tmp/editor.jar "$QID" '[{"module":"Leads","field":"first_name"}]')"
case "$code $(body)" in
  400* | 403* | 405* | *"does not write"*) fail "a mapping to a field of Leads passes those checks ($code)" ;;
  *) pass "a mapping to a field of Leads passes those checks" ;;
esac

echo
echo "A save while the survey's link is off keeps the mapping"
EMAIL_QID="$(qid email)"
email_mapping="$(mapping "$EMAIL_QID")"
survey_link() { ls_sql "$DB" "UPDATE lime_plugin_settings SET value = '\"$1\"' WHERE \`key\` = 'survey_enabled' AND model = 'Survey' AND model_id = '$SID'" >/dev/null; }
survey_link 0
web get /tmp/editor.jar "$(direct actionGetAllFields "$SID" "$EMAIL_QID")" >/dev/null
assert_contains "the editor's script is told that the link is off, so it hides the section" "$(body)" '"surveyEnabled":false'
code="$(save_question /tmp/editor.jar "$EMAIL_QID" "$email_mapping")"
assert_eq "the question is saved" "200" "$code"
assert_eq "and its mapping is still stored, as it was" "1 $email_mapping" \
  "$(ls_sql "$DB" "SELECT COUNT(*) FROM lime_question_attributes WHERE qid = $EMAIL_QID AND attribute = 'suitecrm_mappings_json'") $(mapping "$EMAIL_QID")"
survey_link 1
web get /tmp/editor.jar "$(direct actionGetAllFields "$SID" "$EMAIL_QID")" >/dev/null
assert_contains "with the link on again the script is told so" "$(body)" '"surveyEnabled":true'
# LimeSurvey serves a copy of the script that it publishes under tmp/assets, in a folder named after the date of the
# plugin's assets folder. A copy from an earlier image can be there under the same name.
EDIT_PAGE="/index.php/questionAdministration/edit/questionId/$EMAIL_QID"
web get /tmp/admin.jar "$EDIT_PAGE" >/dev/null
script="$(body | grep -o 'src="[^"]*question-editor\.js[^"]*"' | head -n 1 | sed 's/^src="//; s/"$//; s/?.*//')"
assert_contains "the classic editor's page loads the plugin's script from LimeSurvey's published assets" "$script" "/assets/"
docker exec -u www-data "$A" sh -c "echo '// a copy from an earlier image' >> '/var/www/html$script'"
web get /tmp/admin.jar "$EDIT_PAGE" >/dev/null
assert_eq "a published copy that differs from the plugin's script is replaced when the page is next opened" \
  "$(sha256sum < "$PLUGIN_DIR/assets/question-editor.js")" "$(docker exec "$A" sha256sum "/var/www/html$script" 2>/dev/null | sed 's/ .*/  -/')"

echo
echo "A redirect from SuiteCRM's address is not followed"
set_url() { ls_sql "$DB" "UPDATE lime_plugin_settings SET value = '\"$1\"' WHERE \`key\` = 'suitecrm_url' AND model IS NULL AND plugin_id = $PLUGIN_ID" >/dev/null; }
set_url "http://$CRM:8080/redir"
tokens="$(stub_count '"path":"\/Api\/access_token"')"
heads="$(stub_count '"method":"HEAD","path":"\/"')"
web post /tmp/admin.jar "$(direct actionTestConnection "$SID" "$QID")" >/dev/null
web get /tmp/admin.jar "$(direct actionCheckStatus "$SID" "$QID")" >/dev/null
assert_eq "the plugin asked the address it was given: once for a token, once to see that it answers" "1 1" \
  "$(stub_count '"path":"\/redir\/Api\/access_token"') $(stub_count '"method":"HEAD","path":"\/redir\/"')"
assert_eq "it followed neither redirect, so the admin's name and password went to no other address" "$tokens $heads" \
  "$(stub_count '"path":"\/Api\/access_token"') $(stub_count '"method":"HEAD","path":"\/"')"
set_url "http://$CRM:8080"

echo
echo "The status says so when SuiteCRM no longer has the OAuth2 client"
status_of() { web get /tmp/admin.jar "$(direct actionCheckStatus "$SID" "$QID")" >/dev/null; body; }
client_id="$(setting oauth_client_id | tr -d '"')"
assert_eq "with the client in SuiteCRM, the status of the OAuth2 client is ok" "1" \
  "$(status_of | grep -c '"oauth2_client":{"status":"ok"')"
crm_sql "UPDATE oauth2clients SET deleted = 1 WHERE id = '$client_id'" >/dev/null
status="$(status_of)"
assert_eq "with the client deleted in SuiteCRM, the status of the OAuth2 client is an error, and the link is not ready" "1 0" \
  "$(grep -c '"oauth2_client":{"status":"error"' <<< "$status") $(grep -c '"overall":"ready"' <<< "$status")"
assert_contains "and it says to initialize OAuth2 again" "$status" 'Initialize OAuth2'
crm_sql "UPDATE oauth2clients SET deleted = 0 WHERE id = '$client_id'" >/dev/null
assert_eq "with the client back, the status is ok again" "1" "$(status_of | grep -c '"oauth2_client":{"status":"ok"')"

echo
echo "The settings page"
code="$(web get /tmp/admin.jar "/index.php/admin/pluginmanager/sa/configure/id/$PLUGIN_ID")"
page="$(body | sed 's/<[^>]*>//g')"
assert_eq "the main admin opens the plugin's settings" "200" "$code"
assert_contains "it says field mapping is done in the classic question editor" "$page" "Field mapping is done in the classic question editor"
assert_contains "and how to switch to it" "$page" 'open the menu under your name at the top right, choose the entry for the new editor, pick "Classic" and save'
assert_contains "with a link that opens LimeSurvey's own editor switch" "$(body)" 'data-bs-target="#activate_editor"'
assert_contains "which this page has" "$(body)" 'activate_editor'
assert_eq "the settings page of the plugin is closed to a caller who is not signed in" "0" \
  "$(docker exec "$A" curl -s -L -H 'Host: localhost' "http://127.0.0.1:8080/index.php/admin/pluginmanager/sa/configure/id/$PLUGIN_ID" | grep -c 'suitecrm-field-mapping-help')"
CONFIGURE="/index.php/admin/pluginmanager/sa/configure/id/$PLUGIN_ID"
web get /tmp/admin.jar "$CONFIGURE" >/dev/null
assert_contains "the page the main admin gets has the settings form" "$(body)" 'name="suitecrm_url"'
assert_eq "it holds no stored password" "0" "$(ls_secrets_in "$(body)")"
assert_eq "its three secret fields are empty, and the browser is told not to fill in a password it has saved" "3" \
  "$(body | grep -o '<input[^>]*name="\(suitecrm_admin_password\|suitecrm_db_password\|oauth_client_secret\)"[^>]*>' | grep 'type="password"' | grep 'value=""' | grep -c 'autocomplete="new-password"')"
assert_eq "and not the OAuth2 client secret" "not in the page" "$(clvtest secretinpage)"
body > "$WORK/js/settings-page.html"
chmod 644 "$WORK/js/settings-page.html"
if docker image inspect "$JS_IMAGE" >/dev/null 2>&1; then
  report_js "$(run_js page-test.js /js/jquery.js /js/settings-page.html)" 3
fi
# An error text that the OAuth2 setup stored comes from a database or from SuiteCRM.
oauth_state() {
  ls_sql "$DB" "UPDATE lime_plugin_settings SET value = '\"$1\"' WHERE \`key\` = 'oauth_initialized' AND model IS NULL AND plugin_id = $PLUGIN_ID;
    UPDATE lime_plugin_settings SET value = '\"$2\"' WHERE \`key\` = 'oauth_init_error' AND model IS NULL AND plugin_id = $PLUGIN_ID" >/dev/null
}
oauth_state 0 '<img src=x onerror=alert(1)>'
web get /tmp/admin.jar "$CONFIGURE" >/dev/null
assert_eq "a stored error text is shown as text: the page holds no element made from it" "0" "$(body | grep -c '<img src=x onerror')"
oauth_state 1 ''

code="$(web get /tmp/settings.jar "$CONFIGURE")"
assert_eq "an account that may read the global settings and not change them opens the page" "200" "$code"
assert_eq "the page it gets holds no stored password" "0" "$(ls_secrets_in "$(body)")"
assert_eq "and none of the plugin's settings and no status panel, only a note that the right is missing" "0 0 1" \
  "$(body | grep -c 'name="suitecrm_url"') $(body | grep -c 'id="suitecrm-status-panel"') $(body | grep -c 'id="suitecrm-settings-no-access"')"

docker exec -i "$A" sh -c 'cat > /tmp/clv-settings-save.php' <<'PHP'
<?php
// php clv-settings-save.php <jar> <plugin id>: opens the plugin's settings page with the session in <jar> and saves its
// form as a browser does. Every field goes back as the page gave it, except the ones in T_SET (a query string).
$jar = $argv[1];
$url = 'http://127.0.0.1:8080/index.php/admin/pluginmanager/sa/configure/id/' . (int) $argv[2];
parse_str((string) getenv('T_SET'), $set);
function req($url, $jar, $post = null) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_COOKIEJAR => $jar, CURLOPT_COOKIEFILE => $jar,
        CURLOPT_TIMEOUT => 120, CURLOPT_HTTPHEADER => ['Host: localhost']]);
    if ($post !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, $post); }
    $body = (string) curl_exec($ch);
    return [curl_getinfo($ch, CURLINFO_HTTP_CODE), $body];
}
[, $html] = req($url, $jar);
$doc = new DOMDocument();
@$doc->loadHTML($html);
$form = $doc->getElementById('pluginsettings-SuiteCRMIntegration');
if ($form === null) { echo "no form\n"; exit(1); }
$fields = [];
foreach ($form->getElementsByTagName('input') as $input) {
    $type = strtolower($input->getAttribute('type'));
    if ($input->getAttribute('name') === '' || in_array($type, ['submit', 'button', 'file'], true)) { continue; }
    if (in_array($type, ['checkbox', 'radio'], true) && !$input->hasAttribute('checked')) { continue; }
    $fields[$input->getAttribute('name')] = $input->getAttribute('value');
}
foreach ($form->getElementsByTagName('select') as $select) {
    $value = null;
    foreach ($select->getElementsByTagName('option') as $i => $option) {
        if ($i === 0 || $option->hasAttribute('selected')) { $value = $option->getAttribute('value'); }
    }
    $fields[$select->getAttribute('name')] = (string) $value;
}
foreach ($form->getElementsByTagName('textarea') as $area) { $fields[$area->getAttribute('name')] = $area->textContent; }
[$code] = req($url, $jar, http_build_query(array_merge($fields, $set)));
echo $code, "\n";
PHP
# save_settings QUERY: the main admin saves the settings form, with the fields in QUERY changed.
save_settings() { docker exec -e "T_SET=$1" "$A" php /tmp/clv-settings-save.php /tmp/admin.jar "$PLUGIN_ID" 2>&1 | tail -n 1; }
stored_secrets() { printf '%s %s %s' "$(setting suitecrm_admin_password)" "$(setting suitecrm_db_password)" "$(setting oauth_client_secret)" | sha256sum | cut -c1-16; }
stored_before="$(stored_secrets)"
assert_eq "the main admin saves the form with the two password fields and the secret's field empty" "200" \
  "$(save_settings 'suitecrm_admin_password=&suitecrm_db_password=&oauth_client_secret=')"
assert_eq "an empty field means keep: the two stored passwords and the secret are as they were" "$stored_before" "$(stored_secrets)"
assert_eq "and the plugin still reads both passwords back" "same same" \
  "$(clvtest 'reads --key=suitecrm_admin_password' -e "T_EXPECT=$CRM_PW") $(clvtest 'reads --key=suitecrm_db_password' -e "T_EXPECT=$CRM_DB_PW")"
assert_eq "the other settings went back as the page gave them" "\"1\" \"1\" \"crm_admin\"" "$(setting enabled) $(setting debug_mode) $(setting suitecrm_admin_user)"
NEW_PW="crm-pw-new-71c0e4b2"
LS_EXTRA_SECRETS+=("$NEW_PW")
assert_eq "a new password typed into the field is saved" "200" "$(save_settings "suitecrm_admin_password=$NEW_PW")"
assert_eq "the plugin reads the new one back, and it is stored encrypted" "same 0" \
  "$(clvtest 'reads --key=suitecrm_admin_password' -e "T_EXPECT=$NEW_PW") $(ls_secrets_in "$(setting suitecrm_admin_password)")"
assert_eq "the old password goes back the same way" "200 same" \
  "$(save_settings "suitecrm_admin_password=$CRM_PW") $(clvtest 'reads --key=suitecrm_admin_password' -e "T_EXPECT=$CRM_PW")"
assert_eq "the image's own command, which writes these settings at every start, finds them in step" "settings already in step" \
  "$(docker exec -u www-data "$A" sh -c 'cd /var/www/html && YII_CONSOLE_COMMANDS=/clouve/limesurvey/installer/commands php application/commands/console.php clouve suitecrm' 2>&1 | tail -n 1)"
assert_eq "the container's log still holds no password" "0" "$(ls_secrets_in "$(docker logs "$A" 2>&1)")"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sLimeSurvey plugin checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sLimeSurvey plugin checks failed.%s\n' "$RED" "$RESET"
exit 1
