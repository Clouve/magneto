#!/bin/bash

# ============================================================================
# The Education Kit's Moodle keeps its copy of Gibbon's database password in step (release 4.5.6, #109)
# ============================================================================
# In the Education Kit, Moodle signs its users in against Gibbon's database (auth_db) and syncs enrolments from it
# (enrol_database). The kit's integration SQL wrote Gibbon's database password into Moodle's own settings once, at the
# first start, so after a database password rotation those two settings would keep the old one. The image's
# gibbon-integration-password.sh, run by the entrypoint at every start, puts the deployment's password there:
#   - only when ENABLE_GIBBON_INTEGRATION is true, GIBBON_DB_PASSWORD is set, the integration has run (its marker)
#     and Moodle is installed (config.php); otherwise it does nothing;
#   - set_config for auth_db/pass and enrol_database/dbpass, only where the stored value differs (set_config clears
#     Moodle's settings cache), and never a setting that isn't there; it says "changed" or nothing;
#   - the password goes to PHP on stdin; no command line holds it, nothing the scripts print holds it, and PHP runs as
#     www-data with an empty environment, so Moodle's code never sees CLOUVE_OPS_PASSWORD (or the password itself);
#   - a Moodle that can't load (its database is down) leaves a warning and the start goes on.
# Moodle is a stand-in here: a config.php whose get_config and set_config keep the settings in a JSON file and record
# what PHP's environment held and the uid it ran as. It runs in php:8.3-cli with no network. Most cases put a recorder
# in place of "su -s /bin/sh www-data -c" to check the command lines; one runs the image's own su and checks the uid.
#
# Usage: bash tests/moodle-gibbon-password.test.sh
# ============================================================================

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/../apps/moodle/image/installer"
IMAGE="${PHP_IMAGE:-php:8.3-cli}"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
FAILED=0
pass() { printf '  %bPASS%b %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %bFAIL%b %s\n' "$RED" "$NC" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

command -v docker > /dev/null || { echo "This test needs Docker." >&2; exit 2; }
docker image inspect "$IMAGE" > /dev/null 2>&1 || docker pull -q "$IMAGE" > /dev/null || { echo "Can't get $IMAGE" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
NEW=NEWgibbonNEWgibbonNEWgibbon12345
OLD=OLDgibbon1
OPS=opsSECRETvalue99

# new_site <auth_db pass or -> <enrol_database dbpass or ->: a stand-in Moodle in $S/moodle, its settings in
# $S/store.json (a "-" leaves the setting out), the integration marker in $S/installed, and a recorder of command lines.
new_site() {
  S="$(mktemp -d "$WORK/site.XXXX")"
  mkdir -p "$S/moodle" "$S/installed" "$S/installer"
  cp "$INSTALLER/gibbon-integration-password.sh" "$INSTALLER/gibbon-integration-password.php" "$S/installer/"
  : > "$S/installed/.gibbon-integration-setup"
  python3 - "$S/store.json" "$1" "$2" <<'PY'
import json, sys
path, auth, enrol = sys.argv[1:4]
store = {"auth_db": {}, "enrol_database": {}}
if auth != "-": store["auth_db"]["pass"] = auth
if enrol != "-": store["enrol_database"]["dbpass"] = enrol
store["auth_db"]["host"] = "tkt-1-gibbon-mysql"
json.dump(store, open(path, "w"))
PY
  cat > "$S/moodle/config.php" <<'PHP'
<?php
// A stand-in for Moodle's config.php and its settings API.
if (!defined('CLI_SCRIPT')) { exit(9); }
$GLOBALS['store_path'] = '/t/store.json';
file_put_contents('/t/env.txt', (getenv('CLOUVE_OPS_PASSWORD') === false ? 'no-ops' : 'ops') . ' ' .
    (getenv('GIBBON_DB_PASSWORD') === false ? 'no-gibbon' : 'gibbon') . ' ' . (function_exists('posix_getuid') ? posix_getuid() : '?'));
if (file_exists('/t/broken')) { fwrite(STDERR, "Error: Database connection failed\n"); exit(1); }
function get_config($plugin, $name) {
    $s = json_decode(file_get_contents($GLOBALS['store_path']), true);
    return array_key_exists($name, $s[$plugin] ?? []) ? $s[$plugin][$name] : false;
}
function set_config($name, $value, $plugin) {
    $s = json_decode(file_get_contents($GLOBALS['store_path']), true);
    $s[$plugin][$name] = $value;
    file_put_contents($GLOBALS['store_path'], json_encode($s, JSON_FORCE_OBJECT));
    file_put_contents('/t/writes.txt', "$plugin/$name\n", FILE_APPEND);
    return true;
}
PHP
  # The recorder stands in for "su -s /bin/sh www-data -c": it keeps its command line, then runs it.
  cat > "$S/record" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> /t/argv.txt
exec sh -c "$1"
SH
  chmod +x "$S/record"
  chmod -R a+rwX "$S"
}

# run [VAR=value ...]: runs the script in the container as the entrypoint does, with the deployment's settings.
run() {
  RC=0
  # The passwords reach docker by their names alone (their values come from this shell's environment), never argv.
  OUT="$(GIBBON_DB_PASSWORD="$NEW" CLOUVE_OPS_PASSWORD="$OPS" docker run --rm --network none -v "$S:/t" -w /t \
    -e ENABLE_GIBBON_INTEGRATION=true -e GIBBON_DB_PASSWORD -e CLOUVE_OPS_PASSWORD \
    -e INSTALLED_VERSIONS_PATH=/t/installed -e MOODLE_INSTALL_PATH=/t/moodle -e CLV_AS_WWW=/t/record \
    "$@" "$IMAGE" bash /t/installer/gibbon-integration-password.sh 2>&1)" || RC=$?
}
setting() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(s[sys.argv[2]].get(sys.argv[3], "-"))' "$S/store.json" "$1" "$2"; }
everything() { cat "$S/argv.txt" "$S/writes.txt" 2> /dev/null; printf '%s\n' "$OUT"; }

echo "the stored password differs: both settings get the deployment's, and the log says so"
new_site "$OLD" "$OLD"
run
assert_eq "exits 0" "0" "$RC"
assert_eq "auth_db/pass" "$NEW" "$(setting auth_db pass)"
assert_eq "enrol_database/dbpass" "$NEW" "$(setting enrol_database dbpass)"
assert_eq "the other settings stay" "tkt-1-gibbon-mysql" "$(setting auth_db host)"
assert_eq "the log line" "✓ Moodle's Gibbon sign-in and enrolment settings now use the deployment's Gibbon database password" "$OUT"
assert_eq "no command line, write or output holds the password" "0" "$(everything | grep -cF "$NEW")"
assert_eq "PHP saw neither CLOUVE_OPS_PASSWORD nor the password in its environment" "no-ops no-gibbon" "$(cut -d' ' -f1,2 "$S/env.txt")"

echo "with the image's own su (no recorder): PHP runs as www-data, with an empty environment"
new_site "$OLD" "$OLD"
run -e CLV_AS_WWW=
assert_eq "exits 0" "0" "$RC"
assert_eq "auth_db/pass" "$NEW" "$(setting auth_db pass)"
assert_eq "PHP ran as www-data (uid 33), and saw neither CLOUVE_OPS_PASSWORD nor the password" "no-ops no-gibbon 33" "$(cat "$S/env.txt")"
assert_eq "the output doesn't hold the password" "0" "$(printf '%s\n' "$OUT" | grep -cF "$NEW")"

echo "the same password already: nothing is written and nothing is said"
new_site "$NEW" "$NEW"
run
assert_eq "exits 0" "0" "$RC"
assert_eq "no write" "" "$(cat "$S/writes.txt" 2> /dev/null)"
assert_eq "no line" "" "$OUT"

echo "a setting that isn't there isn't made"
new_site "$OLD" -
run
assert_eq "auth_db/pass changes" "$NEW" "$(setting auth_db pass)"
assert_eq "enrol_database/dbpass stays missing" "-" "$(setting enrol_database dbpass)"

echo "without the integration, its marker, the password or config.php: nothing runs"
for case in flag marker password config; do
  new_site "$OLD" "$OLD"
  case "$case" in
    flag) run -e ENABLE_GIBBON_INTEGRATION=false ;;
    marker) rm "$S/installed/.gibbon-integration-setup"; run ;;
    password) run -e GIBBON_DB_PASSWORD= ;;
    config) rm "$S/moodle/config.php"; run ;;
  esac
  assert_eq "$case: exits 0" "0" "$RC"
  assert_eq "$case: PHP never ran" "no" "$([[ -e "$S/argv.txt" ]] && echo yes || echo no)"
  assert_eq "$case: the setting stays" "$OLD" "$(setting auth_db pass)"
done

echo "a Moodle that can't load: a warning, and the start goes on"
new_site "$OLD" "$OLD"
: > "$S/broken"
run
assert_eq "exits 0" "0" "$RC"
assert_eq "the warning" "⚠ Warning: Moodle's Gibbon sign-in and enrolment settings couldn't be checked against the deployment's Gibbon database password (continuing)" "$OUT"
assert_eq "the setting stays" "$OLD" "$(setting auth_db pass)"

echo "the entrypoint runs it at every start, right after update-config.sh"
order="$(grep -nE '^"\$MOODLE_PACKAGE_INSTALLER"/(update-config|gibbon-integration-password)\.sh$' "$INSTALLER/entrypoint.sh" | cut -d: -f2- | paste -sd' ')"
assert_eq "update-config.sh, then gibbon-integration-password.sh, each on a line of its own" \
  '"$MOODLE_PACKAGE_INSTALLER"/update-config.sh "$MOODLE_PACKAGE_INSTALLER"/gibbon-integration-password.sh' "$order"

echo
if [[ $FAILED -eq 0 ]]; then printf '%bMoodle Gibbon password tests passed.%b\n' "$GREEN" "$NC"; exit 0
else printf '%bMoodle Gibbon password tests FAILED.%b\n' "$RED" "$NC"; exit 1; fi
