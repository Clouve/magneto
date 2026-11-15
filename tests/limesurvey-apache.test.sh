#!/bin/bash

# ============================================================================
# LimeSurvey Apache test: what the running site serves, runs and logs
# ============================================================================
# Runs the LimeSurvey image and its database image for real, on a network of
# the test's own with no published ports: a new install on volumes made the
# way a cluster makes them, then requests from inside the container.
#
# 1. A new install starts: Apache is PID 1 and GET / answers 200.
# 2. The log. The access log is the container's log. A request's line has
#    the method, the path and the status. It has neither the query string
#    nor the Referer, so participant tokens, prefilled answers and reset
#    keys in them are not logged. Apache's error lines leave the Referer
#    out too. A request from a probe (a User-Agent with check, health or
#    probe in it) is not logged, as in the base image.
# 3. Apache's parent is root, and www-data can change nothing in Apache's
#    log and run folders. A try to point access.log at another file fails.
#    After a graceful reload (kill -USR1 1, then apache2ctl graceful) and
#    after a restart of the container, Apache is PID 1, serves, and logs to
#    the container's output.
# 4. The folders clouve/, node_modules/ and installer/ are denied, eight
#    other spellings of a path into them are refused, and a .htaccess in
#    them that grants access changes nothing. (The image test shows the same
#    on files that Apache's user can read, so it is the rule that denies.)
# 5. upload/. No PHP file there is run or served: at the top, in a survey's
#    folder, in a plugin's and a theme's folder, with path info after the
#    name, in other letter case, with the other PHP extensions, by other
#    spellings of the path, and with a .htaccess in upload/ that grants
#    access and hands another extension to PHP. PHP stays off there when
#    the web root's .htaccess does the same. A plugin in upload/plugins/
#    still loads, because LimeSurvey includes it. An uploaded theme's style
#    sheet, script and image are still served. A file that a participant
#    uploaded with an answer (fu_...) is denied, with and without
#    LimeSurvey's own upload/surveys/.htaccess.
# 6. On port 80 the default virtual host writes the log line, and it has
#    the same format.
# 7. Behind the ingress: with X-Forwarded-Proto: https every cookie the
#    sign-in page sets is Secure; a plain request inside the cluster gets
#    them without the flag.
#
# Every container, volume and network is named ls-ap-t-* (LS_TEST_PREFIX
# changes that) and is removed at the end, with the images the test built.
#
# Usage: bash tests/limesurvey-apache.test.sh [--image limesurvey=REF] [--image limesurvey-mariadb=REF] [--keep]
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFIX="${LS_TEST_PREFIX:-ls-ap-t-}"
# shellcheck source=lib/limesurvey-test-lib.sh
. "$SCRIPT_DIR/lib/limesurvey-test-lib.sh"

VERSION=7.10.0
DB_VERSION=718

ls_parse_args "$@"
[ "${#LS_ARGS[@]}" -eq 0 ] || { sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "${BASH_SOURCE[0]}" >&2; exit 2; }
ls_need_docker
trap ls_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ls_remove_all

echo "LimeSurvey behind Apache"
if ! ls_image limesurvey-mariadb || ! ls_image limesurvey; then
  fail "the images build or are on this machine"
  echo; printf '%sLimeSurvey Apache checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
IMAGE="${LS_IMAGE[limesurvey]}"
DB="${PREFIX}db"
A="${PREFIX}app"

# The helpers below are this test's own. PORT is the port of the container that is asked.
PORT=8080
# status CONTAINER PATH [curl options...]: the HTTP status of a GET, with the path sent as written.
status() {
  local c="$1" path="$2"
  shift 2
  docker exec "$c" curl -s -o /dev/null -m 20 --path-as-is -w '%{http_code}' "$@" "http://127.0.0.1:$PORT$path" 2>/dev/null
}
# body CONTAINER PATH [curl options...]: the body of the same GET.
body() {
  local c="$1" path="$2"
  shift 2
  docker exec "$c" curl -s -m 20 --path-as-is "$@" "http://127.0.0.1:$PORT$path" 2>/dev/null
}
# headers CONTAINER PATH: the response headers of the same GET.
headers() { docker exec "$1" curl -s -m 20 -o /dev/null -D - "http://127.0.0.1:$PORT$2" 2>/dev/null | tr -d '\r'; }
# logs CONTAINER: the container's log, both streams.
logs() { docker logs "$1" 2>&1; }
# wait_logged CONTAINER TEXT [SECONDS]: 0 once the container's log holds TEXT.
wait_logged() {
  local i
  for ((i = 0; i < ${3:-15} * 5; i++)); do
    if logs "$1" | grep -qF -- "$2"; then return 0; fi
    sleep 0.2
  done
  return 1
}
# line_of TEXT AGENT: the last line of TEXT that ends with the User-Agent AGENT.
line_of() { grep -F "\"$2\"" <<< "$1" | tail -n 1; }
# The combined format, with "-" where the Referer was: client, two dashes, the time, the request, the status, the
# size, "-", the User-Agent. access_line LINE REQUEST STATUS AGENT says whether LINE is such a line.
access_line() {
  local re='^[0-9a-fA-F.:]+ - - \[[^]]+\] "([^"]*)" ([0-9]{3}) [0-9]+ "-" "([^"]*)"$'
  [[ "$1" =~ $re && "${BASH_REMATCH[1]}" == "$2" && "${BASH_REMATCH[2]}" == "$3" && "${BASH_REMATCH[3]}" == "$4" ]]
}
# assert_access_line LABEL LINE REQUEST STATUS AGENT
assert_access_line() {
  if access_line "$2" "$3" "$4" "$5"; then pass "$1"; else
    fail "$1"; printf '       wanted: ... "%s" %s <size> "-" "%s"\n       line:   %q\n' "$3" "$4" "$5" "$2"; fi
}

# --- 1. a new install -------------------------------------------------------------------------------------------------
echo
echo "A new install"
docker volume create "${PREFIX}db-data" >/dev/null
ls_new_disk "${PREFIX}html" "${PREFIX}upload"
ls_start_db "$DB" "${PREFIX}db-data"
if ! ls_wait_db "$DB" 180; then
  fail "the database starts"
  docker logs --tail 15 "$DB" 2>&1 | sed 's/^/       | /'
fi
ls_start_app "$A" "$DB" "${PREFIX}html" "${PREFIX}upload" "$IMAGE"
rc=0
ls_wait_apache "$A" 600 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "the site starts: Apache is PID 1 and GET / answers 200"
else
  fail "the site starts: Apache is PID 1 and GET / answers 200"
  docker logs --tail 25 "$A" 2>&1 | sed 's/^/       | /'
  echo; printf '%sLimeSurvey Apache checks failed.%s\n' "$RED" "$RESET"; exit 1
fi
assert_eq "the code on the volume is LimeSurvey $VERSION" "$VERSION $DB_VERSION" "$(ls_code_version "$A")"
assert_eq "and so is the database" "$DB_VERSION" "$(ls_db_version "$DB")"
assert_contains "the page is LimeSurvey's" "$(body "$A" /)" "LimeSurvey"

# --- 2. the log -------------------------------------------------------------------------------------------------------
echo
echo "The log"
TOKEN=lsApTokenMark7f3a
ANSWER=lsApAnswerMark91c2
REFERER=lsApRefererMark5d8e
AGENT="ls-apache-test/1.0"
# The shape of a survey invitation link, followed from a page whose own address carries a token.
code="$(status "$A" "/index.php/123456?token=$TOKEN&lang=en&firstName=$ANSWER" -A "$AGENT get" \
  -e "http://localhost:8080/index.php/123456?token=$REFERER")"
post_code="$(status "$A" "/index.php/admin/authentication/sa/login?key=$TOKEN" -A "$AGENT post" -X POST -d "note=$ANSWER" \
  -e "http://localhost:8080/index.php/admin?key=$REFERER")"
# A request that Apache denies writes a line to the error log as well.
denied_code="$(status "$A" "/node_modules/nothing.js?token=$TOKEN" -A "$AGENT denied" \
  -e "http://localhost:8080/index.php/123456?token=$REFERER")"
status "$A" "/upload/readme.txt?from=kubelet" -A "kube-probe/1.31" >/dev/null
status "$A" "/upload/readme.txt" -A "ELB-HealthChecker/2.0" >/dev/null
status "$A" "/upload/readme.txt" -A "$AGENT last" >/dev/null
wait_logged "$A" "$AGENT last" || true
log="$(logs "$A")"
assert_access_line "a GET's line has the method, the path, the protocol and the status" "$(line_of "$log" "$AGENT get")" \
  "GET /index.php/123456 HTTP/1.1" "$code" "$AGENT get"
assert_access_line "and so has a POST's" "$(line_of "$log" "$AGENT post")" \
  "POST /index.php/admin/authentication/sa/login HTTP/1.1" "$post_code" "$AGENT post"
assert_eq "the denied request answered 403" "403" "$denied_code"
assert_access_line "and has its line" "$(line_of "$log" "$AGENT denied")" \
  "GET /node_modules/nothing.js HTTP/1.1" 403 "$AGENT denied"
# The error line as Apache writes it by default, to its last character: the time, the module and level, the process,
# the client and the message. By default ", referer: ..." follows.
error_re='^\[[^]]+\] \[authz_core:error\] \[pid [0-9]+:tid [0-9]+\] \[client [0-9a-fA-F.:]+\] AH01630: client denied by server configuration: /var/www/html/node_modules/nothing\.js$'
assert_eq "with Apache's error line, which names the file and ends there" "1" "$(grep -cE "$error_re" <<< "$log")"
assert_lacks "no line of the log has a query string's token" "$log" "$TOKEN"
assert_lacks "or a prefilled answer" "$log" "$ANSWER"
assert_lacks "and none has the Referer, the error line included" "$log" "$REFERER"
assert_eq "a probe's request is not logged, as in the base image (kube-probe, ELB-HealthChecker)" "0" \
  "$(grep -cE 'kube-probe|ELB-HealthChecker' <<< "$log")"
assert_access_line "the request after the probes is" "$(line_of "$log" "$AGENT last")" \
  "GET /upload/readme.txt HTTP/1.1" 200 "$AGENT last"

# --- 3. Apache's parent, its folders and a graceful reload ------------------------------------------------------------
echo
echo "Apache's folders and a graceful reload"
assert_eq "Apache's parent is root and its workers are www-data" "root www-data" \
  "$(docker exec "$A" sh -c 'echo "$(ps -o user= -p 1) $(ps -o user= --ppid 1 | sort -u | paste -s -d,)"' | tr -s ' ')"
# What a review did as www-data: remove the link access.log and make one that points at a file of its choice. At
# the next reload Apache's parent, which is root, would create that file and write the access log into it.
SWAP=/tmp/ls-apache-test-swap.log
# shellcheck disable=SC2016  # the script is for the bash in the container
did="$(docker exec -u www-data "$A" bash -c '
  cd /var/log/apache2 || exit 1
  rm -f access.log 2>/dev/null
  ln -s "$1" access.log 2>/dev/null
  [ "$(readlink access.log)" = /dev/stdout ] || echo "access.log points at $(readlink access.log)"
  for d in /var/log/apache2 /var/run/apache2 /var/lock/apache2; do
    touch "$d/www-probe" 2>/dev/null && echo "made $d/www-probe"
  done
  rm -f /var/run/apache2/apache2.pid 2>/dev/null
  [ -e /var/run/apache2/apache2.pid ] || echo "removed the PID file"' _ "$SWAP" 2>&1)"
assert_eq "www-data can't point access.log at another file, or change the log and run folders" "" "$did"
# reload LABEL COMMAND...: a graceful reload, then what must still hold.
reload() {
  local label="$1" before after i
  shift
  before="$(logs "$A" | grep -c 'resuming normal operations')"
  docker exec -u root "$A" "$@" >/dev/null 2>&1
  for ((i = 0; i < 150; i++)); do
    after="$(logs "$A" | grep -c 'resuming normal operations')"
    [ "$after" -gt "$before" ] && break
    sleep 0.2
  done
  assert_eq "$label: Apache says so on the container's output and goes on" "$((before + 1))" "$after"
  assert_eq "$label: Apache is still PID 1" "apache2" "$(ls_pid1 "$A")"
  assert_eq "$label: GET / answers 200" "200" "$(status "$A" /)"
  status "$A" "/upload/readme.txt?token=$TOKEN" -A "$AGENT after $label" >/dev/null
  wait_logged "$A" "$AGENT after $label" || true
  assert_access_line "$label: a request's line is on the container's output" \
    "$(line_of "$(logs "$A")" "$AGENT after $label")" "GET /upload/readme.txt HTTP/1.1" 200 "$AGENT after $label"
}
reload "kill -USR1 1" bash -c 'kill -USR1 1'
reload "apache2ctl graceful" apache2ctl graceful
assert_contains "the reloads are named in the log" "$(logs "$A")" "Graceful restart requested"
# Under Docker a restart of the same container starts Apache again on the same folders.
docker restart "$A" >/dev/null 2>&1
rc=0
ls_wait_apache "$A" 300 || rc=$?
assert_eq "docker restart: Apache is PID 1 again and GET / answers 200" "0" "$rc"
status "$A" "/upload/readme.txt?token=$TOKEN" -A "$AGENT after restart" >/dev/null
wait_logged "$A" "$AGENT after restart" || true
assert_access_line "docker restart: a request's line is on the container's output" \
  "$(line_of "$(logs "$A")" "$AGENT after restart")" "GET /upload/readme.txt HTTP/1.1" 200 "$AGENT after restart"
assert_eq "no reload or restart made the file that www-data pointed the log at" "" \
  "$(docker exec -u root "$A" sh -c "ls $SWAP 2>/dev/null")"

# --- 4. the denied folders --------------------------------------------------------------------------------------------
echo
echo "The denied folders"
# A file in each folder, written as root: the image may keep clouve/ closed to www-data.
MARK=lsApDeniedMark3b6f
# shellcheck disable=SC2016  # the script is for the bash in the container
docker exec -u root "$A" bash -c '
  cd /var/www/html && mkdir -p clouve node_modules installer &&
    for d in clouve node_modules installer; do echo "$1" > "$d/ls-apache-test.txt" && chmod 644 "$d/ls-apache-test.txt"; done' \
  _ "$MARK"
# denied_everywhere NOTE: each of the three files answers 403, and eight other spellings of its path are refused: a
# 4xx answer (403 from Apache, 404 or 400 where LimeSurvey answers for a path that is no file) without the file's
# content. curl sends each path as written.
denied_everywhere() {
  local d f open spelling code
  for d in clouve node_modules installer; do
    f="ls-apache-test.txt"
    assert_eq "a file in $d/ is denied$1" "403" "$(status "$A" "/$d/$f")"
    open=""
    for spelling in "/${d^^}/$f" "//$d/$f" "/./$d/$f" "/upload/../$d/$f" "/$d//$f" "/$d/./$f" \
      "/%$(printf '%02x' "'${d:0:1}")${d:1}/$f" "/index.php/$d/$f"; do
      code="$(status "$A" "$spelling")"
      case "$code" in 4??) ;; *) open="$open $spelling=$code" ;; esac
      [[ "$(body "$A" "$spelling")" == *"$MARK"* ]] && open="$open $spelling=served"
    done
    assert_eq "eight other spellings of /$d/$f are refused$1" "" "$open"
  done
}
denied_everywhere ""
# shellcheck disable=SC2016  # the script is for the bash in the container
docker exec -u root "$A" bash -c '
  for d in clouve node_modules installer; do
    printf "%s\n" "<FilesMatch \".*\">" "    Require all granted" "</FilesMatch>" > "/var/www/html/$d/.htaccess" &&
      chmod 644 "/var/www/html/$d/.htaccess" || echo "could not write $d/.htaccess"
  done'
denied_everywhere ", with a .htaccess there that grants access"
docker exec -u root "$A" bash -c 'cd /var/www/html && rm -f {clouve,node_modules,installer}/.htaccess \
  {clouve,node_modules,installer}/ls-apache-test.txt'

# --- 5. upload/ -------------------------------------------------------------------------------------------------------
echo
echo "upload/"
# Files as LimeSurvey writes them, as www-data. Every probe file is the same PHP, which prints ran-42 when it runs.
docker exec -i -u www-data "$A" bash -s <<'EOF'
set -e
cd /var/www/html/upload
mkdir -p surveys/123456/files surveys/123456/images plugins/ClouveProbe themes/survey/probe/css \
  themes/survey/probe/scripts themes/survey/probe/files
for f in probe.php surveys/123456/files/probe.php plugins/ClouveProbe/run.php themes/survey/probe/probe.php \
  probe.PHP probe.Php probe.php5 probe.php8 probe.phtml probe.phar probe.pht probe.phps probe.s18; do
  printf '%s\n' '<?php echo "ran-" . (6 * 7);' > "$f"
done
printf '%s\n' 'body { color: #123456; }' > themes/survey/probe/css/custom.css
printf '%s\n' 'window.lsApacheTest = 1;' > themes/survey/probe/scripts/custom.js
printf '\211PNG\r\n\032\n' > themes/survey/probe/files/logo.png
cp themes/survey/probe/files/logo.png surveys/123456/images/logo.png
printf '%s\n' 'a file that a participant uploaded' > surveys/123456/files/fu_k3x9a7q2m5d8
# A small plugin. LimeSurvey includes its class file when the plugin is switched on, and init() then sets a header.
cat > plugins/ClouveProbe/ClouveProbe.php <<'PHP'
<?php

class ClouveProbe extends \LimeSurvey\PluginManager\PluginBase
{
    protected static $description = 'Test plugin: sets a header when LimeSurvey loads it';
    protected static $name = 'ClouveProbe';

    public function init()
    {
        if (!headers_sent()) {
            header('X-Clouve-Probe-Plugin: loaded-' . (6 * 7));
        }
    }
}
PHP
cat > plugins/ClouveProbe/config.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<config>
    <metadata>
        <name>ClouveProbe</name>
        <type>plugin</type>
        <creationDate>2026-11-12</creationDate>
        <lastUpdate>2026-11-12</lastUpdate>
        <author>Clouve</author>
        <authorEmail>test@example.invalid</authorEmail>
        <authorUrl>https://example.invalid</authorUrl>
        <license>GNU General Public License version 2 or later</license>
        <version>1.0.0</version>
        <description><![CDATA[Test plugin: sets a header when LimeSurvey loads it]]></description>
    </metadata>
    <compatibility>
        <version>7.0</version>
    </compatibility>
    <updaters disabled="disabled"></updaters>
</config>
XML
EOF
assert_eq "the test's files are in upload/" "0" "$?"

# php_closed LABEL PATH...: each GET answers 403 (or 404 with ALSO_404 set), and no body has what the PHP prints
# or its source.
php_closed() {
  local label="$1" path code text open=""
  shift
  for path in "$@"; do
    code="$(status "$A" "$path")"
    text="$(body "$A" "$path")"
    case "$code" in 403) ;; 404) [ -n "${ALSO_404:-}" ] || open="$open $path=$code" ;; *) open="$open $path=$code" ;; esac
    [[ "$text" == *ran-42* ]] && open="$open $path=ran"
    [[ "$text" == *'<?php'* ]] && open="$open $path=source"
  done
  assert_eq "$label" "" "$open"
}
php_closed "a PHP file at the top of upload/ is denied: not run, and its source not served" /upload/probe.php
php_closed "the same in a survey's, a plugin's and a theme's folder" /upload/surveys/123456/files/probe.php \
  /upload/plugins/ClouveProbe/run.php /upload/plugins/ClouveProbe/ClouveProbe.php /upload/themes/survey/probe/probe.php
php_closed "with path info or a query after the name" /upload/probe.php/extra/path /upload/probe.php/ \
  '/upload/probe.php?x=1' /upload/probe.php/x.css
php_closed "in other letter case (.PHP, .Php)" /upload/probe.PHP /upload/probe.Php
php_closed "with the other PHP extensions (.php5, .php8, .phtml, .phar, .pht, .phps)" /upload/probe.php5 \
  /upload/probe.php8 /upload/probe.phtml /upload/probe.phar /upload/probe.pht /upload/probe.phps
ALSO_404=1 php_closed "by other spellings of the path (//, /./, /../, %70, upper case)" //upload//probe.php \
  /upload/./probe.php /upload/themes/../probe.php /upload/probe.ph%70 /%75pload/probe.php /UPLOAD/probe.php \
  /upload/PROBE.PHP
# A .htaccess as a file written into upload/: it grants access to everything, hands the extension .s18 to PHP and
# switches PHP on. It is in the folder of a survey's files too.
docker exec -i -u www-data "$A" bash -s <<'EOF'
cd /var/www/html/upload || exit 1
cat > .htaccess <<'HTACCESS'
<FilesMatch ".*">
    Require all granted
</FilesMatch>
<FilesMatch "\.s18$">
    SetHandler application/x-httpd-php
</FilesMatch>
php_flag engine on
HTACCESS
cp .htaccess surveys/123456/files/.htaccess
EOF
php_closed "with a .htaccess in upload/ that grants access, a PHP file is still denied" /upload/probe.php \
  /upload/surveys/123456/files/probe.php /upload/probe.php/extra/path /upload/probe.PHP /upload/probe.phtml
assert_lacks "and the extension that the .htaccess hands to PHP is not run" "$(body "$A" /upload/probe.s18)" "ran-42"
assert_eq "a file beside it is still served, so the .htaccess broke nothing" "200" "$(status "$A" /upload/readme.txt)"
docker exec -u www-data "$A" rm -f /var/www/html/upload/.htaccess /var/www/html/upload/surveys/123456/files/.htaccess
# The web root's .htaccess is LimeSurvey's own, and Apache reads it. The same two lines there hand .s18 to PHP in
# every folder. PHP is off in upload/ all the same, and the file is put back as it was.
docker exec -i -u www-data "$A" bash -s <<'EOF'
cd /var/www/html || exit 1
cp -p .htaccess .htaccess.ls-apache-test
printf '%s\n' '<FilesMatch "\.s18$">' '    SetHandler application/x-httpd-php' '</FilesMatch>' 'php_flag engine on' >> .htaccess
cp upload/probe.s18 probe.s18
EOF
assert_eq "with .s18 handed to PHP by the web root's .htaccess, such a file runs in the web root" "ran-42" \
  "$(body "$A" /probe.s18)"
assert_lacks "and still doesn't run in upload/" "$(body "$A" /upload/probe.s18)" "ran-42"
docker exec -u www-data "$A" bash -c 'cd /var/www/html && mv .htaccess.ls-apache-test .htaccess && rm -f probe.s18'

# The plugin: off at first, then switched on the way the plugin manager does it, with a row in the plugins table.
assert_eq "before the plugin is switched on, no page has its header" "0" \
  "$(headers "$A" / | grep -ci '^X-Clouve-Probe-Plugin:')"
ls_sql "$DB" "INSERT INTO lime_plugins (name, plugin_type, active, priority, version, load_error)
  VALUES ('ClouveProbe', 'upload', 1, 0, '1.0.0', 0)" >/dev/null
assert_eq "a plugin in upload/plugins/ loads: LimeSurvey includes it and its code runs" \
  "X-Clouve-Probe-Plugin: loaded-42" "$(headers "$A" / | grep -i '^X-Clouve-Probe-Plugin:')"
assert_eq "LimeSurvey recorded no load error for it" "1 0" \
  "$(ls_sql "$DB" "SELECT active, load_error FROM lime_plugins WHERE name='ClouveProbe'" | tr '\t' ' ')"
assert_eq "and the page still answers 200" "200" "$(status "$A" /)"

assert_eq "an uploaded theme's style sheet is served" "200 body { color: #123456; }" \
  "$(status "$A" /upload/themes/survey/probe/css/custom.css) $(body "$A" /upload/themes/survey/probe/css/custom.css)"
assert_eq "its script is served" "200 window.lsApacheTest = 1;" \
  "$(status "$A" /upload/themes/survey/probe/scripts/custom.js) $(body "$A" /upload/themes/survey/probe/scripts/custom.js)"
assert_eq "its image is served as an image" "200 image/png" \
  "$(status "$A" /upload/themes/survey/probe/files/logo.png) $(headers "$A" /upload/themes/survey/probe/files/logo.png |
    sed -n 's/^[Cc]ontent-[Tt]ype: //p')"
assert_eq "an image in a survey's folder is served" "200" "$(status "$A" /upload/surveys/123456/images/logo.png)"
assert_eq "a participant's uploaded file (fu_...) is denied" "403" \
  "$(status "$A" /upload/surveys/123456/files/fu_k3x9a7q2m5d8)"
# LimeSurvey's own upload/surveys/.htaccess has that rule. An upload volume from an older install may lack the
# file, and the image must deny these files all the same.
docker exec -u www-data "$A" mv /var/www/html/upload/surveys/.htaccess /var/www/html/upload/surveys/.htaccess.off
assert_eq "and still denied without LimeSurvey's upload/surveys/.htaccess" "403" \
  "$(status "$A" /upload/surveys/123456/files/fu_k3x9a7q2m5d8)"
docker exec -u www-data "$A" mv /var/www/html/upload/surveys/.htaccess.off /var/www/html/upload/surveys/.htaccess
assert_eq "LimeSurvey's own PHP still runs: GET /index.php answers 200" "200" "$(status "$A" /index.php)"

# --- 7. HTTPS at the ingress ------------------------------------------------------------------------------------------
echo
echo "HTTPS at the ingress"
# TLS ends at the ingress, which sends X-Forwarded-Proto: https. LimeSurvey marks its session and CSRF cookies Secure
# when PHP sees HTTPS (application/config/internal.php), so such a request has to count as HTTPS. The rig showed the
# session cookie without the flag on 2026-11-12. A plain request from inside the cluster (a probe, the plugin's own
# calls) sends no such header and keeps plain cookies.
set_cookies() {
  docker exec "$A" curl -s -m 20 -o /dev/null -D - -H 'Host: localhost' "$@" \
    "http://127.0.0.1:$PORT/index.php/admin/authentication/sa/login" 2>/dev/null | tr -d '\r' | grep -i '^set-cookie:' | tr 'A-Z' 'a-z'
}
cookies="$(set_cookies -H 'X-Forwarded-Proto: https')"
if [ -n "$cookies" ] && ! grep -qv '; secure' <<< "$cookies"; then
  pass "behind a forwarded HTTPS header, every cookie the sign-in page sets is Secure ($(grep -c . <<< "$cookies"))"
else
  fail "behind a forwarded HTTPS header, every cookie the sign-in page sets is Secure"
  sed 's/=[^;]*/=<value>/; s/^/       | /' <<< "$cookies"
fi
cookies="$(set_cookies)"
if [ -n "$cookies" ] && ! grep -q '; secure' <<< "$cookies"; then
  pass "a plain request inside the cluster gets them without the flag"
else
  fail "a plain request inside the cluster gets them without the flag"
fi

# --- 6. port 80-------------------------------------------------------------------------------------------------------
echo
echo "Port 80"
# With LISTEN_PORT=80 a request reaches the base image's default virtual host (*:80), which has a log line of its
# own. On 8080 no virtual host matches and the server's own line is used. Both name the format combined. The
# virtual host's line has no rule for probes, so a probe's request is logged here: that tells the two apart.
V="${PREFIX}port80"
PORT=80
docker run -d --name "$V" --network none --memory "$LS_MEMORY" --user root --entrypoint bash "$IMAGE" -c \
  'echo served > /var/www/html/probe.txt && exec apache2-foreground' >/dev/null
for _ in $(seq 1 60); do [ "$(status "$V" /probe.txt)" = 200 ] && break; sleep 0.5; done
assert_eq "Apache answers on port 80" "200" "$(status "$V" /probe.txt)"
status "$V" "/probe.txt?token=$TOKEN" -A "kube-probe/1.31 port80" \
  -e "http://localhost/index.php/123456?token=$REFERER" >/dev/null
wait_logged "$V" "kube-probe/1.31 port80" || true
log="$(logs "$V")"
assert_access_line "the virtual host's line has the same format" "$(line_of "$log" "kube-probe/1.31 port80")" \
  "GET /probe.txt HTTP/1.1" 200 "kube-probe/1.31 port80"
assert_lacks "with no query string" "$log" "$TOKEN"
assert_lacks "and no Referer" "$log" "$REFERER"
docker rm -f -v "$V" >/dev/null 2>&1

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sLimeSurvey Apache checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sLimeSurvey Apache checks failed.%s\n' "$RED" "$RESET"
exit 1
