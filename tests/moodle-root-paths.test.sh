#!/bin/bash
# SC2016: many values here hold a $ on purpose (PHP code, sed scripts, bash -c scripts). SC2329: check runs the helpers.
# shellcheck disable=SC2016,SC2329

# ============================================================================
# The Moodle image runs the site's code only as www-data, and root never
# reads or writes config.php through a link
# ============================================================================
# The entrypoint and Moodle's cron start as root, and the site's volumes are
# www-data's: config.php, the plugins' code, clouve/ and moodledata can all be
# changed by PHP code of the site, and an upgrade can be started at will (an
# older stamp). So root must never run that code, never hand it
# CLOUVE_OPS_PASSWORD, and never read, write, move or remove anything through
# a link that it left on a volume.
#
# Static cases: cron.php, the purge and every Moodle CLI run of upgrade.sh run
# as www-data without CLOUVE_OPS_PASSWORD; no script edits config.php with
# sed -i, cp -p or a redirection; every reap is `reap_www_data STEP || exit 1`
# on its own line, right after its step; upgrade.sh copies nothing from where a
# link points, copies a kept plugin's files into a folder it made, and empties
# moodledata's caches from inside each folder; the entrypoint checks clouve/
# and clouve/installed/ again after the install, the purge and the upgrade, and
# writes no SQL file at a fixed name in /tmp.
# config.php cases, on this machine (bash, perl, coreutils): update-config.sh
# on a normal config.php (values set, owner and mode kept, no file left), and
# on a config.php that is a link to the process's environment or to a file holding a
# secret, a folder or a pipe: each is left as it is, nothing of what a link
# points to is copied anywhere or changed, the log names the file and shows
# nothing of it, and the start goes on. Shims put a link at config.php just
# before it is read, at the new file's name just before it is written, and in
# place of the new file just before the rename. --read on a link prints
# nothing.
# refresh-vendor.sh cases (as root in php:8.3-apache, no network): shims swap
# clouve/installed/ or vendor.clouve-new for a link to an outside folder just
# as the marker is written, the image's vendor/ is copied, or leftovers are
# removed. Nothing outside may change.
# installer/www-data.sh and install.sh (as root in php:8.3-apache): reap_www_data
# ends every process of www-data's (detached with setsid, double-forked, a loop
# that keeps forking), leaves nobody's and a root process named www-data alone,
# and logs one line with the count; install.sh runs a stand-in install.php as
# www-data, without CLOUVE_OPS_PASSWORD, with both passwords intact and off its
# command line, in a moodledata it can write, and ends what it left running.
# upgrade.sh in the built image, as root with no network, on a small site whose
# old core version.php prints the plan: entries that name a file read through a
# link, a plugin folder that is a link, a plugin that is a file, and a held-back
# plugin reached through a link; moodledata/cache a link to a folder of root's;
# a link left at clouve/ by added-plugins.php's own run, and a link inside a
# kept plugin on the way to another plugin's place; links that Moodle's upgrade
# leaves on the way to a kept plugin before it is held back, to a held-back
# plugin before it is saved, and at upgrade-previous.done and upgrade-stash.
# Nothing outside the volumes may change or be read onto them, each refusal is a
# [clouve-upgrade] warning, and the upgrade still finishes.
# A real site (the built images, new-disk volumes, no network, cron every
# minute): a line in config.php records the user and whether
# CLOUVE_OPS_PASSWORD is set each time Moodle's code loads it, and so does an
# added plugin's version.php. Cron must run it as www-data and never as root
# (two runs), and the cron log keeps working. config.php a link to
# the process's environment: no clouve-ops password in config.php or in any file
# www-data can read, none of the environment copied onto the volume, the log
# names config.php, and config.php is left a link. A normal config.php again:
# updated, owner and mode kept, GET / answers 200. An upgrade with an added
# plugin and a config.php that forces the Classic theme: no PHP code sees
# CLOUVE_OPS_PASSWORD, the plugin is kept, the Classic line becomes a comment,
# GET / answers 200. clouve/installed/ removed from the installed site: no PHP
# runs as root, the site isn't installed again, and it serves. An upgrade where
# each step's PHP (an added plugin's version.php, config.php) leaves a detached
# process of www-data's that swaps clouve/ for an outside link as soon as root
# makes clouve/upgrade-previous.partial: no swap, nothing of the site moved
# outside the volume, every such process gone, the log says so, and it serves.
#
# --image NAME=REF (moodle, moodle-mysql) picks the images; the default is
# r.clv.zone/e2eorg/<name>:latest, as ./build.sh moodle tags them. --no-docker
# runs only the static and config.php cases. Every container, volume and file it
# makes is removed at the end.
#
# Usage: bash tests/moodle-root-paths.test.sh [--image NAME=REF]... [--no-docker]
#   Exit status: 0 when every check passes, 1 when one fails, 2 when the test
#   can't run (no image, Docker missing).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO/apps/moodle/image/installer"
BASE_IMAGE="${TEST_PHP_IMAGE:-php:8.3-apache}"

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *can.t run/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

declare -A IMAGE=([moodle]=r.clv.zone/e2eorg/moodle:latest [moodle-mysql]=r.clv.zone/e2eorg/moodle-mysql:latest)
DOCKER=true
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${IMAGE[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
    --no-docker) DOCKER=false ;;
    *) usage ;;
  esac
  shift
done

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
# check LABEL COMMAND...: passes when the command succeeds.
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
# show TEXT: up to 5 lines of TEXT, indented, under the last FAIL.
show() { [ -n "$1" ] && head -n 5 <<< "$1" | sed 's/^/       | /'; return 0; }

WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"
RUN="mrp-t-$$"
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  if [ "$DOCKER" = true ]; then
    docker rm -f -v "$RUN-app" "$RUN-db" >/dev/null 2>&1
    docker volume rm -f "$RUN-db_data" "$RUN-moodle_data" "$RUN-moodledata" >/dev/null 2>&1
    # Files a container made as root under $WORK: remove them from inside one.
    [ -d "$WORK/rv" ] && docker run --rm --network none -v "$WORK:/w" --entrypoint rm "$BASE_IMAGE" -rf /w/rv >/dev/null 2>&1
  fi
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# code_lines FILE: FILE's lines that aren't comments, with their numbers (N:text).
code_lines() { grep -nvE '^[[:space:]]*(#|$)' "$1"; }
# runs_php: the lines (from code_lines) that start a php process: php as a command word, not in an echo.
# (A line that starts with a quote continues an echo's text.)
runs_php() { grep -E '(^[0-9]+:|[[:space:];&|(/])php[[:space:]]' | grep -vE '^[0-9]+:[[:space:]]*(echo[[:space:]]|")'; }

# ----------------------------------------------------------------------------
echo "Static cases"
# ----------------------------------------------------------------------------
CRON_SH="$INSTALLER/moodle-cron.sh"
ENTRYPOINT="$INSTALLER/entrypoint.sh"
UPDATE_CONFIG="$INSTALLER/update-config.sh"
UPGRADE_SH="$INSTALLER/upgrade.sh"

cron_php="$(code_lines "$CRON_SH" | runs_php)"
check "moodle-cron.sh runs php once" [ "$(grep -c . <<< "$cron_php")" = 1 ]
if grep -qE 'env -u CLOUVE_OPS_PASSWORD /usr/sbin/runuser -u www-data -- /usr/local/bin/php "\$MOODLE_PATH/admin/cli/cron\.php"' \
    <<< "$cron_php"; then
  pass "moodle-cron.sh runs cron.php as www-data (runuser, by its full path), without CLOUVE_OPS_PASSWORD"
else
  fail "moodle-cron.sh runs cron.php as www-data (runuser, by its full path), without CLOUVE_OPS_PASSWORD"; show "$cron_php"
fi

entry_php="$(code_lines "$ENTRYPOINT" | runs_php)"
bad="$(grep -vE 'env -u CLOUVE_OPS_PASSWORD (/usr/sbin/)?runuser -u www-data -- php ' <<< "$entry_php")"
if [ -n "$entry_php" ] && [ -z "$bad" ]; then
  pass "every php the entrypoint starts runs as www-data, without CLOUVE_OPS_PASSWORD (the Education Kit's cache purge)"
else
  fail "every php the entrypoint starts runs as www-data, without CLOUVE_OPS_PASSWORD (the Education Kit's cache purge)"
  show "${bad:-no php line found}"
fi

su_lines="$(code_lines "$UPGRADE_SH" | grep -E '(^[0-9]+:|[[:space:];&|(])su[[:space:]]')"
bad="$(grep -vE 'env -u CLOUVE_OPS_PASSWORD su -s /bin/bash -p www-data -c ' <<< "$su_lines")"
if [ "$(grep -c . <<< "$su_lines")" -ge 2 ] && [ -z "$bad" ]; then
  pass "upgrade.sh's Moodle CLI and added-plugins.php runs (su -p) take CLOUVE_OPS_PASSWORD out first"
else
  fail "upgrade.sh's Moodle CLI and added-plugins.php runs (su -p) take CLOUVE_OPS_PASSWORD out first"; show "${bad:-$su_lines}"
fi
bad="$(code_lines "$UPGRADE_SH" | runs_php | grep -vE 'as_www_data php |-c "php ')"
if [ -z "$bad" ]; then pass "upgrade.sh runs php only through as_www_data and run_cli"; else
  fail "upgrade.sh runs php only through as_www_data and run_cli"; show "$bad"; fi

# followed_by_reap FILE TEXT: the first code line after each line that holds TEXT calls reap_www_data.
followed_by_reap() {
  TEXT="$2" awk '
    /^[[:space:]]*(#|$)/ { next }
    want { if ($0 !~ /reap_www_data/) bad = bad NR ": " $0 "\n"; want = 0 }
    index($0, ENVIRON["TEXT"]) { want = 1; n++ }
    END { if (n == 0) print "no line holds it"; printf "%s", bad }' "$1"
}
# A reap whose status is lost lets the start go on with a process of www-data's alive, so each call is a statement of
# its own that ends the script when the reap fails: never inside $( ), a pipeline, an if or a || true.
bad=""
for f in "$UPGRADE_SH" "$INSTALLER/install.sh" "$ENTRYPOINT"; do
  bad+="$(code_lines "$f" | grep -E 'reap_www_data[[:space:]]+"' |
    grep -vE '^[0-9]+:[[:space:]]*reap_www_data "[^"$()|]*(\$\{?[A-Za-z_#%*}]*[^"$()|]*)*" \|\| exit 1[[:space:]]*$' |
    sed "s|^|${f##*/}:|")"$'\n'
done
bad="$(grep . <<< "$bad")"
if [ -z "$bad" ]; then pass "every reap_www_data call is a statement of its own: reap_www_data \"...\" || exit 1"; else
  fail "every reap_www_data call is a statement of its own: reap_www_data \"...\" || exit 1"; show "$bad"; fi
# Each $(as_www_data ...) statement (it may go on over lines ending in \) is followed at once by its reap.
bad="$(awk '
  /^[[:space:]]*(#|$)/ { next }
  want == 2 { if ($0 !~ /^[[:space:]]*reap_www_data "/) bad = bad NR ": " $0 "\n"; want = 0 }
  want == 1 && $0 !~ /\\$/ { want = 2; next }
  want == 1 { next }
  /\$\(as_www_data / { n++; want = ($0 ~ /\\$/) ? 1 : 2 }
  END { if (n == 0) print "no $(as_www_data line"; printf "%s", bad }' "$UPGRADE_SH")"
if [ -z "$bad" ]; then pass "upgrade.sh reaps right after each \$(as_www_data ...)"; else
  fail "upgrade.sh reaps right after each \$(as_www_data ...)"; show "$bad"; fi
for fn in run_cli run_upgrade; do
  if awk -v fn="$fn" '$0 ~ "^" fn "\\(\\)" { inside = 1 } inside && /^[[:space:]]*reap_www_data "/ { found = 1 }
      inside && /^}/ { exit } END { exit !found }' "$UPGRADE_SH"; then
    pass "upgrade.sh's $fn reaps after its step"
  else
    fail "upgrade.sh's $fn reaps after its step"
  fi
done
bad="$(code_lines "$UPGRADE_SH" | grep -E '(^|[^_])run_cli[[:space:]].*[^|]\|[^|]|\$\([^)]*run_cli')"
if [ -z "$bad" ]; then pass "upgrade.sh never runs run_cli in a pipeline or a \$( ) (its exit would end only a subshell)"; else
  fail "upgrade.sh never runs run_cli in a pipeline or a \$( ) (its exit would end only a subshell)"; show "$bad"; fi
for step in 'php "$purge_cli"' 'MOODLE_PACKAGE_INSTALLER"/upgrade.sh' 'MOODLE_PACKAGE_INSTALLER"/gibbon-integration-password.sh' \
    'MOODLE_PACKAGE_INSTALLER"/install.sh'; do
  bad="$(followed_by_reap "$ENTRYPOINT" "$step")"
  if [ -z "$bad" ]; then pass "the entrypoint ends what www-data left after: $step"; else
    fail "the entrypoint ends what www-data left after: $step"; show "$bad"; fi
done
# A process that ends while _www_data_live reads /proc must not fail it: under set -e that would end the start.
if awk '/^_www_data_live\(\)/ { inside = 1 } inside && /^}/ { exit } inside { last = $0 }
    END { exit !(last ~ /^[[:space:]]*return 0[[:space:]]*$/) }' "$INSTALLER/www-data.sh" 2>/dev/null; then
  pass "_www_data_live ends with return 0"
else
  fail "_www_data_live ends with return 0"
fi
install_php="$(code_lines "$INSTALLER/install.sh" | grep -E 'runuser|php -r|reap_www_data')"
if grep -q 'runuser -u www-data' <<< "$install_php" && grep -q 'env -u CLOUVE_OPS_PASSWORD' "$INSTALLER/install.sh" &&
    grep -q 'reap_www_data' <<< "$install_php"; then
  pass "install.sh runs install.php as www-data without CLOUVE_OPS_PASSWORD, then ends what it left"
else
  fail "install.sh runs install.php as www-data without CLOUVE_OPS_PASSWORD, then ends what it left"; show "$install_php"
fi

# config.php edits: no sed -i, cp -p, redirection onto it or copy beside it, in the three scripts that change it.
bad=""
for f in "$ENTRYPOINT" "$UPDATE_CONFIG" "$UPGRADE_SH"; do
  bad+="$(code_lines "$f" | grep -E 'config\.php|CONFIG' |
    grep -E 'sed([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*i|cp[[:space:]]+-p|>[[:space:]]*"\$(CONFIG|CONFIG_FILE)"|\.clouve-new' |
    sed "s|^|${f##*/}:|")"$'\n'
  bad+="$(code_lines "$f" | grep -E '>[[:space:]]*"\$3"' | sed "s|^|${f##*/}:|")"$'\n'
done
bad="$(grep . <<< "$bad")"
if [ -z "$bad" ]; then pass "no script edits config.php with sed -i, cp -p or a redirection"; else
  fail "no script edits config.php with sed -i, cp -p or a redirection"; show "$bad"; fi

# upgrade.sh: nothing copied from where a link points, a kept plugin's files copied into a folder made for them, and
# moodledata's caches emptied from inside each folder, never by a pattern on a path that may go through a link.
bad="$(code_lines "$UPGRADE_SH" | grep -E 'readlink|link_target')"
if [ -z "$bad" ]; then pass "upgrade.sh copies nothing from where a link points (no readlink)"; else
  fail "upgrade.sh copies nothing from where a link points (no readlink)"; show "$bad"; fi
check "upgrade.sh copies a kept plugin's files into a folder it has just made: cp -a -- \"\$PREV/\$old/.\"" \
  grep -qE '^[[:space:]]*cp -a -- "\$PREV/\$old/\." "\$MOODLE_INSTALL_PATH/\$new/"' "$UPGRADE_SH"
bad="$(code_lines "$UPGRADE_SH" | grep -E 'MOODLEDATA_PATH[^[:space:]]*/[^[:space:]]*\*')"
# shellcheck disable=SC2143  # grep -q would end code_lines early, which pipefail counts as a failure
if [ -z "$bad" ] && [ -n "$(code_lines "$UPGRADE_SH" | grep -E 'in_folder "\$MOODLEDATA_PATH/')" ]; then
  pass "upgrade.sh empties moodledata's caches from inside each folder (in_folder), never by a pattern on their path"
else
  fail "upgrade.sh empties moodledata's caches from inside each folder (in_folder), never by a pattern on their path"
  show "${bad:-no in_folder \"\$MOODLEDATA_PATH/... line}"
fi
# The entrypoint: after a step that ran the site's PHP, clouve/ and clouve/installed/ are checked again (a link the
# step left there is removed, not followed) before root writes the stamp or a marker there.
for step in 'reap_www_data "the install"' 'reap_www_data "purge_caches.php"' 'reap_www_data "the upgrade"'; do
  next="$(STEP="$step" awk '/^[[:space:]]*(#|$)/ { next } want { print; exit } index($0, ENVIRON["STEP"]) { want = 1 }' \
    "$ENTRYPOINT")"
  if [[ "$next" =~ ^[[:space:]]*stamp_folders\ \"\$MOODLE_INSTALL_PATH\"[[:space:]]*$ ]]; then
    pass "the entrypoint checks clouve/ and clouve/installed/ again after: $step"
  else
    fail "the entrypoint checks clouve/ and clouve/installed/ again after: $step"; show "${next:-no line after it}"
  fi
done
# Root's SQL file for the Education Kit holds Gibbon's database password: never at a fixed name in /tmp, where a file
# put there first could take its place.
bad="$(code_lines "$ENTRYPOINT" | grep -E '/tmp/[A-Za-z0-9_.-]+\.sql')"
if [ -z "$bad" ]; then pass "the entrypoint writes no SQL file at a fixed name in /tmp"; else
  fail "the entrypoint writes no SQL file at a fixed name in /tmp"; show "$bad"; fi

# ----------------------------------------------------------------------------
echo "config.php cases (update-config.sh on this machine)"
# ----------------------------------------------------------------------------
# A fake mysql that records each call's arguments and answers a SELECT of the URL with an old one, so update-config.sh
# takes its "URL changed" path. The real perl and coreutils run.
mkdir -p "$WORK/bin" "$WORK/shims"
cat > "$WORK/bin/mysql" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/calls"
[ -t 0 ] || cat > /dev/null
case "$*" in *"SELECT value"*) echo "https://old.example.test" ;; esac
exit 0
EOF
chmod +x "$WORK/bin/mysql"
# The shims: a tool of the same name that does one thing a racing www-data process could do, once, when it is SHIM_TOOL
# and its arguments match SHIM_MATCH, then runs the real tool. SHIM_DO says what: "link-config" puts a link to $SECRET at $SITE/config.php
# (the file moves to config.php.moved), "link-arg5" puts one at the path in its fifth argument (perl's file name),
# "link-src" puts one in place of mv's source (the argument before the last).
for tool in perl mv; do
  cat > "$WORK/shims/$tool" <<EOF
#!/bin/bash
real="\$(PATH=/usr/bin:/bin command -v $tool)"
if [ "\$SHIM_TOOL" = $tool ] && [[ "\$*" =~ \$SHIM_MATCH ]] && [ ! -e "\$SHIM_FLAG" ]; then
  : > "\$SHIM_FLAG"
  case "\$SHIM_DO" in
    link-config) /bin/mv -T -- "\$SITE/config.php" "\$SITE/config.php.moved"; /bin/ln -s -- "\$SECRET" "\$SITE/config.php" ;;
    link-arg5) /bin/ln -s -- "\$SECRET" "\$5" ;;
    link-src) args=("\$@"); src="\${args[\$((\$# - 2))]}"; /bin/rm -f -- "\$src"; /bin/ln -s -- "\$SECRET" "\$src" ;;
  esac
fi
exec "\$real" "\$@"
EOF
  chmod +x "$WORK/shims/$tool"
done

SITE="$WORK/site"
SECRET="$WORK/outside/secret"
SECRET_TEXT="secret-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
OPS_TEST_PW="ops-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
# new_site: a made-up installed site with a config.php of mode 640, and an outside file holding a secret, mode 600.
new_site() {
  rm -rf "$SITE" "$WORK/outside" "$WORK/flag" && mkdir -p "$SITE" "$WORK/outside"
  printf '%s\n' "<?php" "unset(\$CFG);" "\$CFG->dbhost    = 'x';" "\$CFG->dbname    = 'x';" "\$CFG->dbuser    = 'x';" \
    "\$CFG->dbpass    = 'x';" "\$CFG->wwwroot   = 'x';" "require_once(__DIR__ . '/lib/setup.php');" > "$SITE/config.php"
  chmod 640 "$SITE/config.php"
  printf '%s\n' "$SECRET_TEXT" > "$SECRET"
  chmod 600 "$SECRET"
  : > "$WORK/calls"
}
# run_update [SHIM_DO SHIM_MATCH] [ARGS...]: update-config.sh on $SITE as the entrypoint runs it (CLOUVE_OPS_PASSWORD in
# its environment), with the shims on PATH when SHIM_DO is given. Sets OUT and RC.
run_update() {
  local path="$WORK/bin:/usr/bin:/bin" do="" match="^$" tool=""
  if [[ "${1:-}" == link-* ]]; then
    path="$WORK/shims:$path"; do="$1"; match="$2"; shift 2
    if [ "$do" = link-src ]; then tool="mv"; else tool="perl"; fi
  fi
  OUT="$(cd "$WORK" && env -i PATH="$path" FAKE="$WORK" SITE="$SITE" SECRET="$SECRET" SHIM_DO="$do" SHIM_MATCH="$match" \
    SHIM_TOOL="$tool" SHIM_FLAG="$WORK/flag" MOODLE_INSTALL_PATH="$SITE" DB_HOST=db.example.test DB_NAME=moodle DB_USER=moodle \
    DB_PASSWORD=Db-Pw-1 MOODLE_URL=https://new.example.test CLOUVE_OPS_PASSWORD="$OPS_TEST_PW" \
    timeout 60 bash "$UPDATE_CONFIG" "$@" 2>&1 < /dev/null)"
  RC=$?
}
listing() { (cd "$1" && find . -printf '%p %y %m\n' | sort && find . -type f -exec md5sum {} + | sort); }
# nothing_copied LABEL: no file in the site holds the secret, the clouve-ops password or the run's environment.
nothing_copied() {
  local found
  found="$(grep -rlF -e "$SECRET_TEXT" -e "$OPS_TEST_PW" -e "FAKE=$WORK" "$SITE" 2>/dev/null)"
  if [ -z "$found" ]; then pass "$1"; else fail "$1"; show "$found"; fi
}
no_temp_left() { [ -z "$(find "$SITE" -maxdepth 1 -name '.config.php.*' -print -quit)" ]; }

echo " a normal config.php"
new_site
run_update
cfg="$(cat "$SITE/config.php")"
assert_eq "exits 0" "0" "$RC"
check "the database settings and wwwroot are set" grep -qxF -e "\$CFG->dbhost    = 'db.example.test';" <<< "$cfg"
check "the password is set" grep -qxF "\$CFG->dbpass    = 'Db-Pw-1';" <<< "$cfg"
check "wwwroot is set" grep -qxF "\$CFG->wwwroot   = 'https://new.example.test';" <<< "$cfg"
check "every other line is kept" grep -qxF "require_once(__DIR__ . '/lib/setup.php');" <<< "$cfg"
assert_eq "config.php keeps its owner, group and mode" "$(id -u):$(id -g) 640 regular file" \
  "$(stat -c '%u:%g %a %F' "$SITE/config.php")"
check "no temporary file is left" no_temp_left
check "the database's wwwroot is updated too" grep -q "INSERT INTO mdl_config" "$WORK/calls"
printf 'left\n' > "$SITE/.config.php.clouve-0123456789abcdef"
run_update
check "a new file a cut-off start left is removed at the next" no_temp_left

echo " config.php a link to /proc/self/environ (the root process's environment, CLOUVE_OPS_PASSWORD in it)"
new_site
rm "$SITE/config.php" && ln -s /proc/self/environ "$SITE/config.php"
run_update
assert_eq "exits 0, so the start goes on" "0" "$RC"
assert_eq "config.php is left a link to /proc/self/environ" "/proc/self/environ" "$(readlink "$SITE/config.php")"
nothing_copied "nothing of the environment reaches a file in the site"
check "the log names config.php" grep -qF "$SITE/config.php is a link or not a regular file" <<< "$OUT"
if grep -qF -e "$OPS_TEST_PW" -e "FAKE=" <<< "$OUT"; then fail "the log shows nothing of the environment"; else
  pass "the log shows nothing of the environment"; fi
check "the database's wwwroot is still updated" grep -q "INSERT INTO mdl_config" "$WORK/calls"

echo " config.php a link to a file holding a secret"
new_site
before="$(listing "$WORK/outside")"
rm "$SITE/config.php" && ln -s "$SECRET" "$SITE/config.php"
run_update
assert_eq "exits 0" "0" "$RC"
check "config.php is still the link" [ -L "$SITE/config.php" ]
assert_eq "the file it links to is unchanged (content and mode)" "$before" "$(listing "$WORK/outside")"
nothing_copied "the secret reaches no file in the site"
if grep -qF "$SECRET_TEXT" <<< "$OUT"; then fail "the log doesn't show the secret"; else pass "the log doesn't show the secret"; fi

echo " a folder at config.php"
new_site
rm "$SITE/config.php" && mkdir "$SITE/config.php" && echo keep > "$SITE/config.php/keep"
run_update
assert_eq "exits 0" "0" "$RC"
assert_eq "the folder is left as it is" "keep" "$(cat "$SITE/config.php/keep" 2>/dev/null)"
check "the log names it" grep -qF "$SITE/config.php is a link or not a regular file" <<< "$OUT"

echo " a pipe at config.php"
new_site
rm "$SITE/config.php" && mkfifo "$SITE/config.php"
run_update
check "doesn't hang, exits 0" [ "$RC" = 0 ]
check "the pipe is left as it is" [ -p "$SITE/config.php" ]

echo " races: what a process of www-data's could do mid-edit (shims)"
new_site
before="$(listing "$WORK/outside")"
run_update link-config '-- read '
check "a link put at config.php just before it is read: the shim ran" [ -e "$WORK/flag" ]
assert_eq "  the file the link names is unchanged" "$before" "$(listing "$WORK/outside")"
nothing_copied "  the secret reaches no file in the site"
check "  config.php is the link or a regular file without the secret" \
  bash -c '[ -L "$1/config.php" ] || ! grep -qF "$2" "$1/config.php"' _ "$SITE" "$SECRET_TEXT"
new_site
before="$(listing "$WORK/outside")"
run_update link-arg5 '-- write '
check "a link put at the new file's name just before it is written: the shim ran" [ -e "$WORK/flag" ]
assert_eq "  the file the link names is unchanged (content and mode)" "$before" "$(listing "$WORK/outside")"
check "  the edit fails (status 1), as a failed sed -i did" [ "$RC" = 1 ]
new_site
before="$(listing "$WORK/outside")"
run_update link-src '\.config\.php\.'
check "the new file swapped for a link just before the rename: the shim ran" [ -e "$WORK/flag" ]
assert_eq "  the file the link names is unchanged (content and mode)" "$before" "$(listing "$WORK/outside")"
check "  the edit fails and says why" grep -qF "something replaced the new file before it was renamed" <<< "$OUT"

echo " --read and --edit, as the entrypoint and upgrade.sh use them"
new_site
rm "$SITE/config.php" && ln -s "$SECRET" "$SITE/config.php"
run_update --read "$SITE/config.php"
assert_eq "--read on a link: status 2" "2" "$RC"
if grep -qF "$SECRET_TEXT" <<< "$OUT"; then fail "--read on a link prints nothing of what it links to"; else
  pass "--read on a link prints nothing of what it links to"; fi
new_site
run_update --read "$SITE/config.php"
assert_eq "--read on a regular file prints it" "$(cat "$SITE/config.php")" "$OUT"
run_update --edit "$SITE/config.php" sed '/require_once.*lib\/setup.php/i $CFG->sslproxy = true;'
check "--edit with sed adds a line before the require" grep -qxF '$CFG->sslproxy = true;' "$SITE/config.php"
assert_eq "  and keeps owner, group and mode" "$(id -u):$(id -g) 640" "$(stat -c '%u:%g %a' "$SITE/config.php")"
check "  and leaves no temporary file" no_temp_left

if [ "$DOCKER" = false ]; then
  echo
  if [ "$FAILED" -eq 0 ]; then printf '%sRoot path checks passed (no Docker cases).%s\n' "$GREEN" "$RESET"; exit 0; fi
  printf '%sRoot path checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "The Docker cases need Docker (--no-docker runs the others)." >&2
  exit 2
fi

# ----------------------------------------------------------------------------
echo "refresh-vendor.sh with a folder swapped for a link mid-run (as root in $BASE_IMAGE, no network)"
# ----------------------------------------------------------------------------
mkdir -p "$WORK/rv"
cp "$INSTALLER/refresh-vendor.sh" "$WORK/rv/refresh-moodle.sh"
cat > "$WORK/rv/cases.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
M=/w/rv/refresh-moodle.sh
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
listing() { (cd "$1" && find . -printf '%p %y %m\n' | sort && find . -type f -exec md5sum {} + | sort); }

# The shims: once, when a tool's arguments match SWAP_MATCH, SWAP_PATH becomes a link to SWAP_TO (what was there moves
# to SWAP_PATH.moved), as a process of www-data's could do, then the real tool runs.
mkdir -p /shims
for tool in dd mktemp cp rm mv mkdir; do
  cat > "/shims/$tool" <<EOF
#!/bin/bash
if [[ " \${SWAP_TOOLS:-} " == *" $tool "* && "\$*" =~ \$SWAP_MATCH && ! -e /w/rv/flag ]]; then
  : > /w/rv/flag
  /usr/bin/mv -T -- "\$SWAP_PATH" "\$SWAP_PATH.moved" 2>/dev/null
  /usr/bin/ln -s -- "\$SWAP_TO" "\$SWAP_PATH"
fi
exec /usr/bin/$tool "\$@"
EOF
  chmod +x "/shims/$tool"
done

installed() {
  local first=1 p
  printf '{"packages": ['
  for p in "$@"; do [ "$first" = 1 ] || printf ','; first=0; printf '{"name": "%s", "version": "%s"}' "${p%%:*}" "${p#*:}"; done
  printf ']}\n'
}
vendor_tree() {
  local dir="$1" tag="$2"
  shift 2
  mkdir -p "$dir/composer" "$dir/jmespath"
  installed "$@" > "$dir/composer/installed.json"
  echo "$tag" > "$dir/jmespath/TREE"
}
# moodle_case NAME: an image package and a site on upstream's vendor/ for the same Moodle $version, all www-data's.
moodle_case() {
  C="/w/rv/$1"
  PKG="$C/clouve/moodle/moodle-5.3"
  SITE="$C/site"
  STATE="$SITE/clouve/installed"
  OUT="$C/outside"
  mkdir -p "$PKG/public" "$SITE/public" "$STATE" "$OUT"
  printf '<?php\n$version  = 2026100500.00;\n' | tee "$PKG/public/version.php" > "$SITE/public/version.php"
  vendor_tree "$PKG/vendor" image mtdowling/jmespath.php:2.9.2
  echo '{"m":"image"}' > "$PKG/composer.json"
  echo '{"m":"image-lock"}' > "$PKG/composer.lock"
  vendor_tree "$SITE/vendor" upstream mtdowling/jmespath.php:2.8.0
  vendor_tree "$C/upstream" upstream mtdowling/jmespath.php:2.8.0
  bash "$M" --id "$C/upstream" > "$C/clouve/moodle/vendor-upstream.id"
  bash "$M" --sums "$C/upstream" > "$C/clouve/moodle/vendor-upstream.sums"
  echo "outside" > "$OUT/SENTINEL"
  chown -R www-data:www-data "$SITE" "$OUT"
  rm -f /w/rv/flag
}
# run_swapped TOOLS MATCH PATH: refresh-vendor.sh with the shims on PATH; PATH becomes a link to $OUT.
run_swapped() {
  SWAP_TOOLS="$1" SWAP_MATCH="$2" SWAP_PATH="$3" SWAP_TO="$OUT" PATH="/shims:$PATH" \
    timeout 60 bash "$M" moodle "$PKG" "$SITE" "$STATE" > "$C/log" 2>&1
  RC=$?
}

moodle_case marker
rm -rf "$SITE/vendor" && cp -a "$PKG/vendor" "$SITE/vendor" && chown -R www-data:www-data "$SITE/vendor"
before="$(listing "$OUT")"
run_swapped "mktemp dd" '\.vendor\.' "$STATE"
check "clouve/installed swapped for a link as the marker is written: the shim ran" '[ -e /w/rv/flag ]'
check "  nothing outside changes" '[ "$(listing "$OUT")" = "$before" ]'
check "  the start goes on (exit 0)" '[ "$RC" = 0 ]'

moodle_case copy
before="$(listing "$OUT")"
run_swapped "cp" '(^| )-a( |$)' "$SITE/vendor.clouve-new"
check "vendor.clouve-new swapped for a link as the image's vendor/ is copied: the shim ran" '[ -e /w/rv/flag ]'
check "  nothing outside changes" '[ "$(listing "$OUT")" = "$before" ]'

moodle_case leftovers
echo leftover > "$STATE/.vendor.AbC123"
echo "outside's own" > "$OUT/.vendor.AbC123"
chown -R www-data:www-data "$STATE" "$OUT"
before="$(listing "$OUT")"
run_swapped "rm" '\.vendor\.' "$STATE"
check "clouve/installed swapped for a link as an earlier start's leftovers are removed: the shim ran" '[ -e /w/rv/flag ]'
check "  nothing outside changes or goes" '[ "$(listing "$OUT")" = "$before" ]'
INNER
out="$(docker run --rm --network none -v "$WORK:/w" --entrypoint bash "$BASE_IMAGE" /w/rv/cases.sh 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "${line#PASS }" ;;
    "FAIL "*) fail "${line#FAIL }" ;;
    "") ;;
    *) printf '    %s\n' "$line" ;;
  esac
done <<< "$out"

# ----------------------------------------------------------------------------
echo "What www-data leaves running, and install.sh (as root in $BASE_IMAGE, no network)"
# ----------------------------------------------------------------------------
mkdir -p "$WORK/rv/installer"
cp "$INSTALLER/install.sh" "$WORK/rv/installer/install.sh"
cp "$INSTALLER/moodle-cron.sh" "$WORK/rv/installer/moodle-cron.sh"
if [ -f "$INSTALLER/www-data.sh" ]; then cp "$INSTALLER/www-data.sh" "$WORK/rv/installer/www-data.sh"; fi
cat > "$WORK/rv/units.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
# live UID: the processes that haven't ended (zombies run nothing) with UID as their real, effective, saved or
# filesystem uid, from /proc.
live() {
  local d key a b c e st
  for d in /proc/[0-9]*; do
    st=""
    { while read -r key a b c e; do
        case "$key" in
          State:) st="$a" ;;
          Uid:) if [[ "$st" != [ZX] && " $a $b $c $e " == *" $1 "* ]]; then echo "${d#/proc/}"; fi; break ;;
        esac
      done < "$d/status"; } 2>/dev/null
  done
}
WWW="$(id -u www-data)"
NOBODY="$(id -u nobody)"

echo "reap_www_data"
if [ -f /w/rv/installer/www-data.sh ]; then
  pass "installer/www-data.sh is there"
  . /w/rv/installer/www-data.sh
else
  fail "installer/www-data.sh is there"
fi
runuser -u www-data -- setsid -f sleep 300
runuser -u www-data -- sh -c '(sleep 300 &) &'
runuser -u www-data -- setsid -f sh -c 'while :; do sleep 0.05 & wait; done'
runuser -u nobody -- setsid -f sleep 300
(exec -a www-data sleep 300) &
named=$!
sleep 0.5
check "processes of www-data's run: detached (setsid), double-forked, a loop that keeps forking" \
  '[ "$(live "$WWW" | grep -c .)" -ge 3 ]'
out="$(reap_www_data "a test step" 2>&1)"
check "none of www-data's is left" '[ -z "$(live "$WWW")" ]'
check "nobody's process is left alone" '[ -n "$(live "$NOBODY")" ]'
check "a root process named www-data is left alone: by uid, never by name" 'kill -0 "$named" 2>/dev/null'
check "one log line with the count" \
  '[ "$(grep -c . <<< "$out")" = 1 ] && [[ "$out" =~ ^\[clouve-www-data\]\ a\ test\ step:\ stopped\ [0-9]+\ process ]]'
out="$(reap_www_data "again" 2>&1)"
check "with none left, nothing is logged" '[ -z "$out" ]'
kill "$named" 2>/dev/null

echo "a zombie leader with a live thread"
# The leader thread ends with SYS_exit (not exit_group), so /proc/<pid>/status says Z, while a second thread goes on
# and writes a counter every 50 ms.
mkdir -p /tmp/zl && chown www-data /tmp/zl
cat > /tmp/zl/zl.c <<'C'
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
static void *worker(void *a) {
  for (unsigned long n = 0;; n++) {
    FILE *f = fopen("/tmp/zl/alive", "w");
    if (f) { fprintf(f, "%lu\n", n); fclose(f); }
    usleep(50000);
  }
  return a;
}
int main(void) {
  pthread_t t;
  FILE *f = fopen("/tmp/zl/pid", "w");
  if (f) { fprintf(f, "%d\n", (int) getpid()); fclose(f); }
  pthread_create(&t, 0, worker, 0);
  usleep(200000);
  syscall(SYS_exit, 0);
  return 0;
}
C
if gcc -O2 -pthread -o /tmp/zl/zl /tmp/zl/zl.c 2>/dev/null; then
  runuser -u www-data -- setsid -f /tmp/zl/zl
  sleep 0.6
  zl="$(cat /tmp/zl/pid 2>/dev/null)"
  a1="$(cat /tmp/zl/alive 2>/dev/null)"; sleep 0.2; a2="$(cat /tmp/zl/alive 2>/dev/null)"
  check "its leader shows Z and its thread runs" \
    '[ -n "$zl" ] && grep -q "^State:[[:space:]]*Z" "/proc/$zl/status" && [ "$a1" != "$a2" ]'
  out="$(reap_www_data "zombie leader" 2>&1)"
  a1="$(cat /tmp/zl/alive 2>/dev/null)"; sleep 0.3; a2="$(cat /tmp/zl/alive 2>/dev/null)"
  check "after reap_www_data its thread runs no more" '[ "$a1" = "$a2" ]'
  check "and no task of it is left that isn't a zombie" \
    '! grep -hs "^State:" /proc/"$zl"/task/*/status | grep -qv "Z"'
  check "the log counts it" '[[ "$out" =~ zombie\ leader:\ stopped\ [1-9] ]]'
else
  fail "gcc builds the program with a zombie leader"
fi

echo "CLOUVE_OPS_PASSWORD in the environment of what the reap starts"
# A process of www-data's that reads the environment of every process it may, again and again, as soon as each one
# appears, and leaves /tmp/leak/found-<pid> (that process's command line, never the value) when one holds
# CLOUVE_OPS_PASSWORD.
mkdir -p /tmp/leak && chown www-data /tmp/leak
cat > /tmp/leak/envpoll.c <<'C'
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static unsigned char done[1 << 22];
int main(void) {
  char path[64], buf[65536];
  pid_t self = getpid();
  for (;;) {
    DIR *d = opendir("/proc");
    if (!d) continue;
    struct dirent *e;
    while ((e = readdir(d))) {
      int pid = atoi(e->d_name);
      if (pid <= 1 || pid == self || pid >= (1 << 22) || done[pid]) continue;
      snprintf(path, sizeof path, "/proc/%d/environ", pid);
      int fd = open(path, O_RDONLY);
      if (fd < 0) continue;
      ssize_t n = read(fd, buf, sizeof buf - 1);
      close(fd);
      if (n <= 0) continue;
      buf[n] = 0;
      for (ssize_t i = 0; i < n; i += strlen(buf + i) + 1) {
        if (strncmp(buf + i, "CLOUVE_OPS_PASSWORD=", 20) == 0) {
          char out[64], cl[256] = {0};
          snprintf(out, sizeof out, "/tmp/leak/found-%d", pid);
          snprintf(path, sizeof path, "/proc/%d/cmdline", pid);
          int c = open(path, O_RDONLY);
          ssize_t m = c >= 0 ? read(c, cl, sizeof cl - 1) : 0;
          if (c >= 0) close(c);
          for (ssize_t j = 0; j < m; j++) if (!cl[j]) cl[j] = ' ';
          int o = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
          if (o >= 0) { if (m > 0 && write(o, cl, m) < 0) {} close(o); }
        }
      }
      done[pid] = 1;
    }
    closedir(d);
  }
}
C
# pollers N: N pollers, started fresh (each reap ends the ones before), with an empty environment of their own: a
# poller started from a shell that holds CLOUVE_OPS_PASSWORD would hold it too, and the others would find it there.
pollers() {
  local k
  for (( k = 0; k < $1; k++ )); do env -i /usr/sbin/runuser -u www-data -- /usr/bin/setsid -f /tmp/leak/envpoll; done
  sleep 0.3
}
leaks() { ls /tmp/leak/found-* 2>/dev/null | while read -r f; do echo "${f##*-}: $(cat "$f")"; done; }
if gcc -O2 -o /tmp/leak/envpoll /tmp/leak/envpoll.c 2>/dev/null; then
  rm -f /tmp/leak/found-*
  for trial in $(seq 1 20); do
    pollers 3
    ( export CLOUVE_OPS_PASSWORD="ops-unit-only"; reap_www_data "trial $trial" 2>/dev/null )
  done
  found="$(leaks)"
  check "20 reaps with 3 pollers each: no process the reap starts shows CLOUVE_OPS_PASSWORD" '[ -z "$found" ]'
  [ -z "$found" ] || echo "$found" | head -n 3
else
  fail "gcc builds the environment poller"
fi

echo "a hammer that ends what it may, and a fork chain"
# The hammer is a process of www-data's that sends SIGKILL to every process it may signal (the chain and itself
# aside), over and over: the reap's own processes too, if www-data may signal them. The chain's members each fork the
# next and end at once, so no pid lives long enough for a kill by pid; a heartbeat file shows it runs.
mkdir -p /tmp/rr && chown www-data /tmp/rr
cat > /tmp/rr/hammer.pl <<'PERL'
$0 = "hammer";
while (1) {
  opendir(my $d, '/proc') or next;
  for my $p (readdir $d) {
    next unless $p =~ /^\d+$/;
    next if $p == $$;
    open(my $c, '<', "/proc/$p/cmdline") or next;
    my $cl = do { local $/; <$c> };
    close $c;
    # A zombie (an empty command line) has ended already; signalling it changes nothing.
    next if !defined $cl || $cl eq '' || $cl =~ /^(chain|hammer)/;
    if (kill('KILL', $p)) { open(my $o, '>>', '/tmp/rr/hits'); $cl =~ s/\0/ /g; print $o "$p $cl\n"; close $o; }
  }
  closedir $d;
}
PERL
cat > /tmp/rr/chain.pl <<'PERL'
$0 = "chain";
my $n = 0;
while (1) {
  my $p = fork();
  if (!defined $p) { select(undef, undef, undef, 0.001); next; }
  exit 0 if $p;
  $n++;
  if ($n % 64 == 0) { open(my $f, '>', '/tmp/rr/beat.tmp'); print $f "$n\n"; close $f; rename('/tmp/rr/beat.tmp', '/tmp/rr/beat'); }
  select(undef, undef, undef, 0.0002);
}
PERL
beat() { cat /tmp/rr/beat 2>/dev/null || echo none; }
start_www() { env -i /usr/sbin/runuser -u www-data -- /usr/bin/setsid -f /usr/bin/perl "$@"; }
sleep 300 &
rootsleep=$!
for trial in 1 2 3; do
  rm -f /tmp/rr/beat /tmp/rr/hits
  start_www /tmp/rr/chain.pl; sleep 0.3; start_www /tmp/rr/hammer.pl; sleep 0.5
  b1="$(beat)"; sleep 0.3; b2="$(beat)"
  check "trial $trial: the chain runs" '[ "$b1" != "$b2" ]'
  # Inside $( ), where a caller would lose its status: the hammer must still end nothing of the reap's.
  x="$(reap_www_data "hammer and chain" 2>/tmp/rr/err)"
  rc=$?
  b1="$(beat)"; sleep 1; b2="$(beat)"
  check "trial $trial: after the reap the chain runs no more and nothing of www-data's is left" \
    '[ "$b1" = "$b2" ] && [ -z "$(live "$WWW")" ]'
  check "trial $trial: and it says it finished (status 0)" '[ "$rc" = 0 ]'
  check "trial $trial: the hammer ended none of the reap's processes" '[ ! -s /tmp/rr/hits ]'
  [ ! -s /tmp/rr/hits ] || head -n 3 /tmp/rr/hits
  # Whatever is left, before the next trial.
  env -i /usr/sbin/runuser -u www-data -- /bin/bash -c 'kill -KILL -1' 2>/dev/null; sleep 0.3
done
check "root's own process is left alone" 'kill -0 "$rootsleep" 2>/dev/null'
kill "$rootsleep" 2>/dev/null

echo "a reap that can't make sure ends the start"
# The uid the reap's sender borrows (65533) in use: the reap must not send from it, and must say the start stops.
setpriv --reuid=65533 --regid=65533 --clear-groups sleep 300 &
spare=$!
sleep 0.3
out="$(bash -c 'set -e; . /w/rv/installer/www-data.sh; reap_www_data "uid in use" || exit 1; echo CONTINUED' 2>&1)"
rc=$?
check "uid 65533 in use: the reap fails and the caller stops (status 1, nothing after it ran)" \
  '[ "$rc" = 1 ] && ! grep -q CONTINUED <<< "$out"'
check "  with one line that says the start stops" 'grep -q "^\[clouve-www-data\] uid in use: .*the start stops" <<< "$out"'
kill "$spare" 2>/dev/null
# A process of www-data's that /proc keeps showing (a stand-in for one that won't end): after its 5 s the reap fails.
out="$(bash -c '. /w/rv/installer/www-data.sh; _www_data_live() { [ "$1" = 33 ] && echo 4000000; return 0; }
  reap_www_data "one stays" || exit 1; echo CONTINUED' 2>&1)"
rc=$?
check "a process that stays: the reap fails after its wait and the caller stops" '[ "$rc" = 1 ] && ! grep -q CONTINUED <<< "$out"'
check "  with one line that says the start stops" 'grep -q "^\[clouve-www-data\] one stays: .*the start stops" <<< "$out"'
# Every pid the check listed already gone when root signals it: under set -e that must not end the start. A plain call,
# where set -e holds inside the function (behind || it doesn't).
# The reap calls _www_data_live in $( ), so the count goes in a file: the second look lists a pid that is gone.
rm -f /tmp/gone-count
out="$(bash -c 'set -e; . /w/rv/installer/www-data.sh
  _www_data_live() {
    local n
    if [ "$1" = 33 ]; then n=$(( $(cat /tmp/gone-count 2>/dev/null || echo 0) + 1 )); echo "$n" > /tmp/gone-count
      [ "$n" -eq 2 ] && echo 4000000; fi
    return 0
  }
  reap_www_data "gone already"; echo CONTINUED' 2>&1)"
check "a listed pid already gone: under set -e the reap goes on and finishes" \
  '[ "$(cat /tmp/gone-count 2>/dev/null)" -ge 2 ] && grep -q CONTINUED <<< "$out"'

echo "install.sh"
# upgrade.sh is a stand-in here (it leaves the code tree www-data's, as the real one does), and install.php records
# who ran it, whether CLOUVE_OPS_PASSWORD was in its environment, whether both passwords arrived as given, whether it
# could write moodledata (a new disk: root's top folder), and leaves a detached process behind.
mkdir -p /pkg /site/admin/cli /data
printf '#!/bin/sh\nexit 0\n' > /pkg/upgrade.sh
chmod 755 /pkg/upgrade.sh
cat > /site/admin/cli/install.php <<'PHP'
<?php
$o = [];
foreach ($_SERVER['argv'] as $a) {
    if (preg_match('/^--(dbpass|adminpass)=(.*)$/s', $a, $m)) {
        $o[$m[1]] = $m[2];
    }
}
$line = posix_geteuid() . ' ' . (getenv('CLOUVE_OPS_PASSWORD') === false ? 'no-ops' : 'ops')
    . ' ' . (($o['dbpass'] ?? null) === getenv('T_DB') ? 'db-ok' : 'db-bad')
    . ' ' . (($o['adminpass'] ?? null) === getenv('T_ADMIN') ? 'admin-ok' : 'admin-bad')
    . ' ' . (@mkdir('/data/made-by-install') ? 'data-ok' : 'data-bad');
file_put_contents('/tmp/install-result', $line . "\n");
exec('setsid -f sh -c \'echo $$ > /tmp/install-left; exec sleep 300\' > /dev/null 2>&1 < /dev/null');
PHP
chown -R www-data:www-data /site
export CLOUVE_OPS_PASSWORD="ops-unit-only"
export DB_PASSWORD="db-'q'\\x-unit" MOODLE_PASSWORD="admin-'q'\\x-unit"
export T_DB="$DB_PASSWORD" T_ADMIN="$MOODLE_PASSWORD"
export DB_HOST=db DB_NAME=moodle DB_USER=moodle MOODLE_INSTALL_PATH=/site MOODLEDATA_PATH=/data MOODLE_PACKAGE_INSTALLER=/pkg
rm -f /tmp/leak/found-*
pollers 3
out="$(bash /w/rv/installer/install.sh 2>&1)"
rc=$?
check "install.sh exits 0" '[ "$rc" = 0 ]'
found="$(leaks)"
check "pollers running through install.sh see CLOUVE_OPS_PASSWORD in no process (install.php's, the reap's)" '[ -z "$found" ]'
[ -z "$found" ] || echo "$found" | head -n 3
check "install.php runs as www-data, without CLOUVE_OPS_PASSWORD, both passwords as given, moodledata writable" \
  '[ "$(cat /tmp/install-result 2>/dev/null)" = "$WWW no-ops db-ok admin-ok data-ok" ]'
echo "install.php said: $(cat /tmp/install-result 2>/dev/null)"
left="$(cat /tmp/install-left 2>/dev/null)"
# Gone means no running process with that pid, whoever's it is (a zombie runs nothing).
check "the process install.php left is gone" \
  '[ -n "$left" ] && { [ ! -d "/proc/$left" ] || grep -q "^State:[[:space:]]*Z" "/proc/$left/status"; }'
check "the log says so" 'grep -qE "^\[clouve-www-data\] install.php: stopped [1-9][0-9]* process" <<< "$out"'
check "the log holds neither password" '! grep -qF -f <(printf "%s\n" "$DB_PASSWORD" "$MOODLE_PASSWORD") <<< "$out"'
check "moodledata and the code are www-data's afterwards, as before" \
  '[ "$(stat -c %U /data) $(stat -c %U /site/admin/cli/install.php)" = "www-data www-data" ]'

echo "moodle-cron.sh"
# A stand-in cron.php that records who runs it and waits a moment, with CLOUVE_OPS_PASSWORD in root's environment (cron
# itself never has it) and pollers running.
mkdir -p /var/www/html/admin/cli
printf '%s\n' '<?php' 'file_put_contents("/tmp/cron-result", posix_geteuid() . " " . (getenv("CLOUVE_OPS_PASSWORD") === false ? "no-ops" : "ops") . "\n");' \
  'usleep(500000);' > /var/www/html/admin/cli/cron.php
rm -f /tmp/leak/found-*
pollers 3
bash /w/rv/installer/moodle-cron.sh
check "cron.php runs as www-data without CLOUVE_OPS_PASSWORD" '[ "$(cat /tmp/cron-result 2>/dev/null)" = "$WWW no-ops" ]'
found="$(leaks)"
check "pollers see CLOUVE_OPS_PASSWORD in no process of the cron run" '[ -z "$found" ]'
[ -z "$found" ] || echo "$found" | head -n 3
reap_www_data "the cron test" 2>/dev/null
INNER
out="$(docker run --rm --network none -v "$WORK:/w" --entrypoint bash "$BASE_IMAGE" /w/rv/units.sh 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "${line#PASS }" ;;
    "FAIL "*) fail "${line#FAIL }" ;;
    "") ;;
    *) printf '    %s\n' "$line" ;;
  esac
done <<< "$out"

for ref in "${IMAGE[@]}"; do
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "No image $ref on this machine (./build.sh moodle, or --image NAME=REF)." >&2
    exit 2
  fi
done

# ----------------------------------------------------------------------------
echo "upgrade.sh with links in its plan, clouve/, the new code and moodledata (as root in ${IMAGE[moodle]}, no network)"
# ----------------------------------------------------------------------------
# The image's own upgrade.sh, run as the entrypoint runs it, on a small installed site of www-data's. The plan comes
# from added-plugins.php, which loads the old code's core version.php, so the site's code decides what the plan says.
# Each step that runs the site's PHP runs it as www-data, which can leave links behind for root's next step. The old
# code is only what added-plugins.php reads before that version.php (lib/components.json, lib/plugins.json). config.php
# runs the case's code, then ends the Moodle CLI script (there is no database here).
cat > "$WORK/rv/upgrade-cases.sh" <<'INNER'
#!/bin/bash
set -uo pipefail
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
export MOODLE_PACKAGE_INSTALLER=/clouve/moodle/installer
export MOODLE_PACKAGE_PATH="/clouve/$MOODLE_PATH"
export MOODLE_INSTALL_PATH=/var/www/html MOODLEDATA_PATH=/var/moodledata
# In root's environment while upgrade.sh runs, as in the entrypoint. A value made here, for this run only.
export CLOUVE_OPS_PASSWORD="ops-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
SITE="$MOODLE_INSTALL_PATH"
DATA="$MOODLEDATA_PATH"
PKG="$MOODLE_PACKAGE_PATH"
LOG=/tmp/upgrade.log
# listing DIR: every entry under DIR with its type, owner, mode and content, to compare before and after.
listing() { (cd "$1" && find . -printf '%p %y %u %m\n' | sort && find . -type f -exec md5sum {} + | sort); }
# Folders of root's outside the volumes that the cases' links point to, /usr/local/sbin (on root's PATH, before
# /usr/bin) and /etc: none of them may change.
mkdir -p /opt/victim /opt/zzclouve /opt/zzout/zzkept /opt/zzprev/zzheld /opt/zzdone /opt/zzstash
echo keep > /opt/victim/rootfile && chmod 600 /opt/victim/rootfile
echo keep > /opt/zzout/zzkept/rootfile && echo keep > /opt/zzprev/zzheld/rootfile
outside() { local d; for d in /usr/local/sbin /etc /opt; do echo "== $d"; listing "$d"; done; }
BEFORE="$(outside)"
ISSUE="$(md5sum < /etc/issue)"

# new_site CONFIG_CODE PLAN_CODE: an installed site: config.php runs CONFIG_CODE and then ends the script; the core
# version.php, when added-plugins.php loads it, runs PLAN_CODE (which prints the plan's lines) and ends added-plugins.php
# with the line "end". The site's folder has mode 755, as the entrypoint leaves it.
new_site() {
  find "$SITE" "$DATA" -mindepth 1 -delete
  mkdir -p "$SITE/lib" "$SITE/public" "$SITE/clouve/installed"
  cp "$PKG/lib/components.json" "$PKG/lib/plugins.json" "$SITE/lib/"
  printf '<?php\n%s\nexit(0);\n' "$1" > "$SITE/config.php"
  cat > "$SITE/public/version.php" <<PHP
<?php
\$version = 2025100600.00;
\$branch = '502';
if (PHP_SAPI === 'cli' && strpos(\$_SERVER['argv'][0] ?? '', 'added-plugins.php') !== false) {
    while (ob_get_level()) { ob_end_clean(); }
$2
    echo "end\n";
    exit(0);
}
PHP
  chmod 755 "$SITE"
  chown -R www-data:www-data "$SITE" "$DATA"
}
# as_www SCRIPT: SCRIPT run by bash as www-data, in the site's folder.
as_www() { runuser -u www-data -- bash -c "cd $SITE && $1"; }
# upgrade: the image's upgrade.sh; its output goes to $LOG, and RC is its status.
upgrade() { "$MOODLE_PACKAGE_INSTALLER"/upgrade.sh > "$LOG" 2>&1; RC=$?; }
# warned COMPONENT_OR_TEXT: a [clouve-upgrade] warning names it.
warned() { grep -qF "[clouve-upgrade] WARNING: $1" "$LOG"; }
# real_dir PATH: a folder, not a link.
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
# show_log: the log's lines that matter, when a case fails.
show_log() { grep -E 'clouve-upgrade|clouve-www-data|Kept|Holding|held back|WARNING|Warning|Error|cp:|mv:|rm:|mkdir:' "$LOG" |
  head -n 20 | sed 's/^/      | /'; }

echo "a plan that names links in the previous code: (A) a file read through a link, (B) a plugin folder that is a link"
echo "and a plugin that is a file, copied into it, (C) a held-back plugin reached through a link; and moodledata/cache a"
echo "link to a folder of root's"
new_site "@copy('$SITE/local/zzleak', '$DATA/stolen');" '
    echo "keep\tlocal_zzleak\tzzlink/environ\tlocal/zzleak\t-\n";
    echo "keep\tlocal_zza\tzzdir\tlocal/zza\t-\n";
    echo "keep\tlocal_zzb\tzzpayload\tlocal/zza/mysql\t-\n";
    echo "skip\tlocal_zzc\tzzetc/issue\t-\theld\n";'
as_www 'ln -s /proc/self zzlink && ln -s /usr/local/sbin zzdir && ln -s /etc zzetc &&
  printf "#!/bin/sh\necho ran-as-\$(id -u) > /var/moodledata/ran-mysql\nexec /usr/bin/mysql \"\$@\"\n" > zzpayload &&
  chmod 755 zzpayload && ln -s /opt/victim /var/moodledata/cache &&
  mkdir /var/moodledata/localcache /var/moodledata/temp && touch /var/moodledata/localcache/stale /var/moodledata/temp/stale'
upgrade
check "upgrade.sh exits 0 and finishes" '[ "$RC" = 0 ] && grep -qx "Moodle upgrade completed successfully." "$LOG"'
check "(A) nothing of root's environment reaches the volumes" '! grep -rqF -- "$CLOUVE_OPS_PASSWORD" "$SITE" "$DATA"'
check "(A) the plugin read through a link is held back, with a warning" \
  '[ ! -e "$SITE/local/zzleak" ] && [ ! -L "$SITE/local/zzleak" ] && warned local_zzleak'
check "(B) nothing is written in /usr/local/sbin, and root's mysql is still /usr/bin/mysql" \
  '[ -z "$(ls -A /usr/local/sbin)" ] && [ "$(command -v mysql)" = /usr/bin/mysql ] && [ ! -e "$DATA/ran-mysql" ]'
check "(B) a plugin folder that is a link and a plugin that is a file are held back, with a warning" \
  '[ ! -e "$SITE/local/zza" ] && [ ! -L "$SITE/local/zza" ] && warned local_zza && warned local_zzb'
check "(C) /etc/issue stays where it was, root's and unchanged" \
  '[ -f /etc/issue ] && [ ! -L /etc/issue ] && [ "$(md5sum < /etc/issue)" = "$ISSUE" ] && [ "$(stat -c %U /etc/issue)" = root ]'
check "(C) nothing named issue is on the volume, and the held-back plugin's warning says it isn't saved" \
  '[ -z "$(find "$SITE" "$DATA" -name issue)" ] && warned local_zzc'
check "moodledata/cache, a link to a folder of root's: that folder keeps its file" \
  '[ "$(cat /opt/victim/rootfile 2>/dev/null)" = keep ]'
check "  the log names it, and it is left a link" \
  'warned "$DATA/cache is a link or not a folder" && [ "$(readlink "$DATA/cache")" = /opt/victim ]'
check "  localcache and temp are emptied, as before" \
  'real_dir "$DATA/localcache" && [ -z "$(ls -A "$DATA/localcache")" ] && real_dir "$DATA/temp" && [ -z "$(ls -A "$DATA/temp")" ]'
check "the log shows nothing of root's environment" '! grep -qF -- "$CLOUVE_OPS_PASSWORD" "$LOG"'
[ "$RC" = 0 ] && warned local_zzleak && warned local_zzc || show_log

echo "a link that added-plugins.php's own run leaves at clouve/ before the move aside, and a link inside a kept plugin"
echo "on the way to another kept plugin's new place"
new_site "" '
    if (($_SERVER["argv"][1] ?? "") === "/var/www/html") {
        @rename("/var/www/html/clouve", "/var/www/html/clouve.zz");
        @symlink("/opt/zzclouve", "/var/www/html/clouve");
    }
    echo "keep\tlocal_zza\tpublic/local/zza\tpublic/local/zza\t-\n";
    echo "keep\tlocal_zzb\tpublic/local/zzb\tpublic/local/zza/sub/zzb\t-\n";'
as_www 'for d in public/local/zza public/local/zzb; do mkdir -p $d && printf "<?php\n" > $d/version.php; done &&
  ln -s /usr/local/sbin public/local/zza/sub'
sbin_before="$(ls -A /usr/local/sbin)"
upgrade
check "upgrade.sh exits 0 and finishes" '[ "$RC" = 0 ] && grep -qx "Moodle upgrade completed successfully." "$LOG"'
check "clouve/ is a real folder again, with installed/, and the log names it" \
  'real_dir "$SITE/clouve" && real_dir "$SITE/clouve/installed" && grep -qF "$SITE/clouve is a link or not a folder" "$LOG"'
check "nothing went into the folder clouve/ was a link to" '[ -z "$(ls -A /opt/zzclouve)" ]'
check "the plugin with a link inside is kept, the link copied as a link" \
  '[ -f "$SITE/public/local/zza/version.php" ] && [ "$(readlink "$SITE/public/local/zza/sub")" = /usr/local/sbin ]'
check "the plugin whose new place is reached through that link is held back, with a warning, and saved in the stash" \
  'warned local_zzb && [ -f "$(find "$SITE/clouve/upgrade-stash" -mindepth 1 -maxdepth 1 -type d | head -n 1)/public/local/zzb/version.php" ]'
check "nothing is written in /usr/local/sbin" '[ "$(ls -A /usr/local/sbin)" = "$sbin_before" ]'
[ "$RC" = 0 ] && warned local_zzb || show_log

echo "links that Moodle's upgrade leaves: on the way to a kept plugin before it is held back, on the way to a held-back"
echo "plugin in the previous code before it is saved, at upgrade-previous.done and at upgrade-stash"
new_site '
if (basename($_SERVER["argv"][0] ?? "") === "upgrade.php") {
    $n = 1 + (int) @file_get_contents("/var/moodledata/zzruns");
    file_put_contents("/var/moodledata/zzruns", (string) $n);
    if ($n === 1) {
        $s = "/var/www/html";
        @rename("$s/public/local", "$s/public/local.zz");
        @symlink("/opt/zzout", "$s/public/local");
        @rename("$s/clouve/upgrade-previous/public/local", "$s/clouve/upgrade-previous/public/local.zz");
        @symlink("/opt/zzprev", "$s/clouve/upgrade-previous/public/local");
        @symlink("/opt/zzdone", "$s/clouve/upgrade-previous.done");
        @symlink("/opt/zzstash", "$s/clouve/upgrade-stash");
    }
    if ($n <= 3) {
        echo $n <= 2 ? "-->local_zzkept\n" : "";
        exit(1);
    }
}' '
    echo "keep\tlocal_zzkept\tpublic/local/zzkept\tpublic/local/zzkept\t-\n";
    echo "skip\tlocal_zzheld\tpublic/local/zzheld\t-\theld\n";
    echo "skip\tlocal_zzsaved\tzzsaved\t-\theld\n";'
as_www 'for d in public/local/zzkept public/local/zzheld zzsaved; do mkdir -p $d && printf "<?php\n" > $d/version.php; done'
upgrade
check "upgrade.sh exits 0 (Moodle's upgrade fails three times, then works)" \
  '[ "$RC" = 0 ] && grep -qx "Moodle upgrade completed successfully." "$LOG" && [ "$(cat "$DATA/zzruns")" = 4 ]'
check "a kept plugin reached through a link isn't removed through it when it is held back, with a warning" \
  '[ "$(cat /opt/zzout/zzkept/rootfile 2>/dev/null)" = keep ] && warned "local_zzkept can'"'"'t be held back"'
check "a held-back plugin reached through a link isn't moved through it into the stash, with a warning" \
  '[ "$(cat /opt/zzprev/zzheld/rootfile 2>/dev/null)" = keep ] && warned "local_zzheld isn'"'"'t saved"'
stash="$(find "$SITE/clouve/upgrade-stash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
check "the other held-back plugin is saved in a real stash folder on the volume" \
  'real_dir "$SITE/clouve/upgrade-stash" && [ -f "$stash/zzsaved/version.php" ]'
check "nothing went into the folders upgrade-previous.done and upgrade-stash were links to" \
  '[ -z "$(ls -A /opt/zzdone)" ] && [ -z "$(ls -A /opt/zzstash)" ]'
check "the previous code is gone" '[ ! -e "$SITE/clouve/upgrade-previous" ] && [ ! -e "$SITE/clouve/upgrade-previous.done" ]'
[ "$RC" = 0 ] || show_log

check "nothing outside the volumes changed in any case (/usr/local/sbin, /etc, /opt)" '[ "$(outside)" = "$BEFORE" ]'
INNER
out="$(docker run --rm --network none -v "$WORK:/w" --entrypoint bash "${IMAGE[moodle]}" /w/rv/upgrade-cases.sh 2>&1)"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) pass "${line#PASS }" ;;
    "FAIL "*) fail "${line#FAIL }" ;;
    "") ;;
    *) printf '    %s\n' "$line" ;;
  esac
done <<< "$out"

# ----------------------------------------------------------------------------
echo "A real site (${IMAGE[moodle]}, ${IMAGE[moodle-mysql]})"
# ----------------------------------------------------------------------------
# shellcheck source=../lib/new-disk-volumes.sh
. "$REPO/lib/new-disk-volumes.sh"

DB="$RUN-db"
APP="$RUN-app"
SITE=/var/www/html
CONFIG="$SITE/config.php"
STAMP="$SITE/clouve/installed/version"
OPS_PW="ops-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
CANARY="canary-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
# The site's settings, all made up. The app shares the database's network namespace, so its database is 127.0.0.1.
# S2_CANARY is in the environment only, so a copy of the environment anywhere shows.
DB_ENV=(-e MYSQL_DATABASE=moodle -e MYSQL_USER=moodle -e MYSQL_PASSWORD=moodle_password -e MYSQL_ROOT_PASSWORD=root_password)
APP_ENV=(-e DB_HOST=127.0.0.1 -e DB_NAME=moodle -e DB_USER=moodle -e DB_PASSWORD=moodle_password
  -e MOODLE_URL=http://localhost -e MOODLE_SITE_NAME="Sample Moodle Site" -e MOODLE_EMAIL=admin@example.invalid
  -e MOODLE_USERNAME=admin -e MOODLE_PASSWORD=Sample-Admin-1 -e CLOUVE_OPS_PASSWORD="$OPS_PW"
  -e "MOODLE_CRON_INTERVAL=* * * * *" -e S2_CANARY="$CANARY")

log_since() { docker logs "$APP" 2>&1 | tail -n +"$(($1 + 1))"; }
# wait_started SKIP SECONDS: waits until the log after SKIP lines says DONE! and Apache (PID 1) answers; status 1 if the
# container stops or the time runs out.
wait_started() {
  local end=$((SECONDS + $2))
  while (( SECONDS < end )); do
    if grep -qx 'DONE!' <<< "$(log_since "$1")" && [ "$(docker exec "$APP" cat /proc/1/comm 2>/dev/null)" = apache2 ] &&
       docker exec "$APP" curl -s -o /dev/null http://localhost/ 2>/dev/null; then
      return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ] || return 1
    sleep 3
  done
  return 1
}
# restart_app: restarts the app container as a pod restart would, and waits for it. Prints the log's line count
# before the restart, so the checks can read only this start's log.
restart_app() {
  local skip
  skip="$(docker logs "$APP" 2>&1 | wc -l)"
  docker restart -t 30 "$APP" >/dev/null || return 1
  echo "$skip"
  if ! wait_started "$skip" 900; then
    log_since "$skip" | tail -n 20 | sed 's/^/       | /' >&2
    return 1
  fi
}
assert_get_root() {
  local codes
  codes="$(docker exec "$APP" curl -s -o /dev/null -w '%{http_code}' http://localhost/) $(docker exec "$APP" \
    curl -s -L --max-redirs 5 -o /dev/null -w '%{http_code}' http://localhost/)"
  if [[ "$codes" == "200 200" || "$codes" =~ ^30[1-8]\ 200$ ]]; then pass "$1 ($codes)"; else
    fail "$1"; printf '       GET / then the end of its redirects: %s\n' "$codes"; fi
}
# as_www COMMAND...: runs COMMAND in the app container as www-data, as the site's PHP code runs.
as_www() { docker exec -u www-data "$APP" "$@" < /dev/null; }
# as_www_in COMMAND...: the same, with this script's stdin (a heredoc) as the command's.
as_www_in() { docker exec -i -u www-data "$APP" "$@"; }
# markers: what the probe recorded, one name per line: <uid>-<ops|no>-<script> (web for Apache).
# docker cp reads them from a container that has stopped too.
markers() { docker cp "$APP:/tmp/s2probe" - 2>/dev/null | tar -t 2>/dev/null | sed -n 's|^s2probe/||p' | grep . | sort; }
clear_markers() { docker exec "$APP" sh -c 'rm -f /tmp/s2probe/*'; }
# holding_ops_pw PATH...: the files under PATH that www-data can read and that hold the clouve-ops password (given on
# stdin, never on a command line).
holding_ops_pw() {
  docker exec -i -u www-data "$APP" sh -c 'grep -rlF -f /dev/stdin "$@" 2>/dev/null' _ "$@" <<< "$OPS_PW"
}

nd_shaper_ready || exit 2
for key in db_data moodle_data moodledata; do
  nd_make_new_disk "$RUN-$key" "$RUN" "$key" || exit 2
done
docker run -d --pull=never --name "$DB" --network none "${DB_ENV[@]}" -v "$RUN-db_data:/var/lib/mysql" \
  "${IMAGE[moodle-mysql]}" >/dev/null || exit 2
docker run -d --pull=never --name "$APP" --network "container:$DB" "${APP_ENV[@]}" \
  -v "$RUN-moodle_data:$SITE" -v "$RUN-moodledata:/var/moodledata" "${IMAGE[moodle]}" >/dev/null || exit 2
if ! wait_started 0 900; then
  docker logs "$APP" 2>&1 | tail -n 20 | sed 's/^/       | /'
  fail "the site installs and Apache answers"
  exit 1
fi
pass "the site installs and Apache answers"
CODE_VERSION="$(docker exec "$APP" sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
  "$SITE/public/version.php" | head -n 1)"

# The probe, put there as www-data: each time PHP loads it, it records who ran it, whether CLOUVE_OPS_PASSWORD was in
# its environment, and which script (web for Apache). It lives in moodledata, which an upgrade doesn't move.
as_www_in sh -c 'mkdir -p /tmp/s2probe && chmod 777 /tmp/s2probe && cat > /var/moodledata/s2probe.inc.php' <<'PHP'
<?php
if (function_exists('posix_geteuid')) {
    $s2script = PHP_SAPI === 'cli' ? basename((string) ($_SERVER['argv'][0] ?? 'cli')) : 'web';
    @touch('/tmp/s2probe/' . posix_geteuid() . '-' . (getenv('CLOUVE_OPS_PASSWORD') === false ? 'no' : 'ops') . '-'
        . preg_replace('/[^A-Za-z0-9_.-]/', '_', $s2script));
}
PHP
as_www sed -i "/require_once.*lib\/setup.php/i require '/var/moodledata/s2probe.inc.php';" "$CONFIG"

echo " Moodle's cron (every minute here), config.php recording who runs it"
cron_log_lines="$(docker exec "$APP" sh -c 'wc -l < /var/log/moodle-cron.log')"
clear_markers
runs=0
end=$((SECONDS + 200))
while (( SECONDS < end )); do
  runs="$(docker exec "$APP" sh -c 'tail -n +$(($1 + 1)) /var/log/moodle-cron.log | grep -c "Moodle Cron Started"' _ "$cron_log_lines")"
  (( runs >= 3 )) && break
  sleep 5
done
# Two whole runs: the third has started.
check "cron ran twice since the probe went in" [ "$runs" -ge 2 ]
m="$(markers)"
if grep -q '^0-' <<< "$m"; then fail "cron.php never runs as root"; show "$(grep '^0-' <<< "$m")"; else
  pass "cron.php never runs as root"; fi
check "cron.php runs as www-data (uid 33), without CLOUVE_OPS_PASSWORD" grep -qx '33-no-cron.php' <<< "$m"
cron_log="$(docker exec "$APP" sh -c 'tail -n +$(($1 + 1)) /var/log/moodle-cron.log' _ "$cron_log_lines")"
# cron.php keeps looking for tasks for about 3 minutes after each run (Moodle's keep-alive), so the wrapper's own end
# line comes later; Moodle's line shows that what cron.php prints still reaches the log.
check "the cron log keeps working: cron.php's own output reaches it" grep -q "Cron run completed correctly" <<< "$cron_log"

echo " config.php a link to /proc/self/environ"
as_www sh -c 'mv "$1" "$1.s2-real" && ln -s /proc/self/environ "$1"' _ "$CONFIG"
if ! skip="$(restart_app)"; then
  fail "the site starts again with config.php a link to /proc/self/environ"
else
  log="$(log_since "$skip")"
  # Read as root, but never through a link: a link's target isn't on the volume (and the environment file would be grep's own).
  config_holds="$(docker exec -i "$APP" sh -c '[ -L "$1" ] && echo 0 || grep -cF -f /dev/stdin "$1"' _ "$CONFIG" <<< "$OPS_PW")"
  assert_eq "config.php holds no clouve-ops password" "0" "${config_holds:-0}"
  found="$(holding_ops_pw /var/www/html /var/moodledata /tmp /var/log /clouve)"
  if [ -z "$found" ]; then pass "no file www-data can read holds the clouve-ops password"; else
    fail "no file www-data can read holds the clouve-ops password"; show "$found"; fi
  found="$(docker exec -i "$APP" sh -c 'grep -rlF -f /dev/stdin /var/www/html /var/moodledata 2>/dev/null' <<< "$CANARY")"
  if [ -z "$found" ]; then pass "none of the environment is copied onto the volumes"; else
    fail "none of the environment is copied onto the volumes"; show "$found"; fi
  assert_eq "config.php is left a link to /proc/self/environ" "/proc/self/environ" \
    "$(docker exec "$APP" readlink "$CONFIG")"
  check "the log names config.php" grep -qF "$CONFIG is a link or not a regular file" <<< "$log"
  if grep -qF -e "$OPS_PW" -e "$CANARY" <<< "$(docker logs "$APP" 2>&1)"; then
    fail "the log shows nothing of the environment"; else pass "the log shows nothing of the environment"; fi
fi
as_www sh -c 'rm -f "$1" && mv "$1.s2-real" "$1"' _ "$CONFIG"
if ! skip="$(restart_app)"; then
  fail "the site starts again with its config.php back"
else
  check "a normal config.php is updated again" grep -qF "Updated \$CFG->wwwroot to: http://localhost" <<< "$(log_since "$skip")"
  assert_eq "a normal config.php keeps its owner and mode" "www-data 755 regular file" \
    "$(docker exec "$APP" stat -c '%U %a %F' "$CONFIG")"
  assert_get_root "a normal config.php: GET / answers 200"
fi

echo " an upgrade, with an added plugin and a config.php that forces the Classic theme"
as_www_in sh -c 'd="$1/public/local/s2probe" && mkdir -p "$d/lang/en" && cat > "$d/version.php" &&
  printf "%s\n" "<?php" "\$string[\"pluginname\"] = \"S2 probe\";" > "$d/lang/en/local_s2probe.php"' _ "$SITE" <<'PHP'
<?php
defined('MOODLE_INTERNAL') || die();
require '/var/moodledata/s2probe.inc.php';
$plugin->component = 'local_s2probe';
$plugin->version = 2026010100;
$plugin->requires = 2024100700;
PHP
as_www sed -i "/require_once.*lib\/setup.php/i \$CFG->theme = 'classic';" "$CONFIG"
as_www sh -c 'printf "%s\n" "$2" > "$1"' _ "$STAMP" "$((CODE_VERSION - 100))"
clear_markers
if ! skip="$(restart_app)"; then
  fail "the site upgrades and starts"
else
  log="$(log_since "$skip")"
  check "the upgrade ran" grep -qF "Moodle upgrade completed successfully." <<< "$log"
  check "the added plugin is kept" grep -qF "Kept local_s2probe" <<< "$log"
  m="$(markers)"
  check "Moodle's upgrade loaded the probe as www-data" grep -qE '^33-(no|ops)-upgrade\.php$' <<< "$m"
  if grep -q -- '-ops-' <<< "$m"; then fail "no PHP code during the start saw CLOUVE_OPS_PASSWORD"; show "$(grep -- '-ops-' <<< "$m")"
  else pass "no PHP code during the start saw CLOUVE_OPS_PASSWORD"; fi
  if grep -q '^0-' <<< "$m"; then fail "no PHP code during the start ran as root"; show "$(grep '^0-' <<< "$m")"; else
    pass "no PHP code during the start ran as root"; fi
  cfg="$(docker exec "$APP" cat "$CONFIG")"
  check "config.php's Classic line is now a comment" \
    grep -qF "; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \$CFG->theme = 'classic';" <<< "$cfg"
  assert_eq "config.php keeps its owner and mode" "www-data 755 regular file" "$(docker exec "$APP" stat -c '%U %a %F' "$CONFIG")"
  assert_get_root "after the upgrade: GET / answers 200"
fi

echo " clouve/installed removed from the installed site"
as_www rm -rf "$SITE/clouve/installed"
clear_markers
if ! skip="$(restart_app)"; then
  fail "the site starts again without clouve/installed"
  m="$(markers)"
  if grep -q '^0-' <<< "$m"; then fail "no PHP code during the start ran as root"; show "$(grep '^0-' <<< "$m")"; else
    pass "no PHP code during the start ran as root"; fi
else
  log="$(log_since "$skip")"
  m="$(markers)"
  if grep -q '^0-' <<< "$m"; then fail "no PHP code during the start ran as root"; show "$(grep '^0-' <<< "$m")"; else
    pass "no PHP code during the start ran as root"; fi
  if grep -q 'INITIALIZING Moodle' <<< "$log"; then fail "the site isn't installed again"; else pass "the site isn't installed again"; fi
  check "the log names the folder" grep -qF "$SITE/clouve/installed is missing" <<< "$log"
  assert_eq "the stamp is recorded from the site's code" "$CODE_VERSION" "$(docker exec "$APP" cat "$STAMP" 2>/dev/null)"
  assert_get_root "without clouve/installed: GET / answers 200"
fi

echo " an upgrade where each step's PHP leaves a process of www-data's behind that swaps clouve/ for a link"
# Like a plugin's code could: each CLI step of the start that loads config.php or the plugin's version.php (once per
# script name) starts a detached php (setsid -f) that records its pid, then waits for root's move aside
# (clouve/upgrade-previous.partial) and swaps clouve/ for a link to a folder outside the volume, where root would then
# move the site's code. Cron and Apache start none.
if [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" != true ]; then
  skip="$(docker logs "$APP" 2>&1 | wc -l)"
  if ! docker start "$APP" >/dev/null || ! wait_started "$skip" 900; then fail "the site starts again for the last case"; fi
fi
as_www_in sh -c 'cat > /var/moodledata/s2c.inc.php' <<'PHP'
<?php
if (PHP_SAPI === 'cli' && function_exists('posix_geteuid') && posix_geteuid() === 33 && is_dir('/tmp/s2c/armed')) {
    $s2cscript = preg_replace('/[^A-Za-z0-9_.-]/', '_', basename((string) ($_SERVER['argv'][0] ?? 'cli')));
    if ($s2cscript !== 'cron.php' && @mkdir('/tmp/s2c/spawned-' . $s2cscript)) {
        exec('setsid -f php /var/moodledata/s2c-daemon.php ' . escapeshellarg($s2cscript) . ' > /dev/null 2>&1 < /dev/null');
    }
}
PHP
as_www_in sh -c 'cat > /var/moodledata/s2c-daemon.php' <<'PHP'
<?php
$site = '/var/www/html';
$out = '/tmp/s2c/out';
file_put_contents('/tmp/s2c/pid-' . getmypid(), ($argv[1] ?? '?') . "\n");
$end = microtime(true) + 600;
$seen = [];
for ($i = 0; microtime(true) < $end; $i++) {
    // Every few rounds: the environment of each other process it may read; a CLOUVE_OPS_PASSWORD there is noted with
    // that process's command line, never the value.
    if ($i % 10 === 0) {
        foreach (glob('/proc/[0-9]*') ?: [] as $d) {
            $p = (int) basename($d);
            if ($p === getmypid() || isset($seen[$p])) {
                continue;
            }
            $env = @file_get_contents("$d/environ");
            if ($env === false || $env === '') {
                continue;
            }
            $seen[$p] = true;
            if (strpos("\0" . $env, "\0CLOUVE_OPS_PASSWORD=") !== false) {
                @file_put_contents("/tmp/s2c/environ-leak-$p", str_replace("\0", ' ', (string) @file_get_contents("$d/cmdline")));
            }
        }
    }
    clearstatcache();
    if (is_dir("$site/clouve/upgrade-previous.partial") && !is_link("$site/clouve") && @mkdir('/tmp/s2c/swap-lock')) {
        @rename("$site/clouve", "$site/clouve.s2c-moved");
        @symlink($out, "$site/clouve");
        file_put_contents('/tmp/s2c/swapped', ($argv[1] ?? '?') . "\n");
    }
    if (is_dir("$out/upgrade-previous.partial/admin") || is_dir("$out/upgrade-previous/admin")) {
        @touch('/tmp/s2c/moved-out');
    }
    usleep(200);
}
PHP
as_www sh -c 'mkdir -p /tmp/s2c/armed /tmp/s2c/out/upgrade-previous.partial &&
  d="$1/public/local/s2c" && mkdir -p "$d/lang/en" &&
  printf "%s\n" "<?php" "\$string[\"pluginname\"] = \"S2 swap\";" > "$d/lang/en/local_s2c.php" &&
  printf "%s\n" "<?php" "defined(\"MOODLE_INTERNAL\") || die();" "require \"/var/moodledata/s2c.inc.php\";" \
    "\$plugin->component = \"local_s2c\";" "\$plugin->version = 2026010100;" "\$plugin->requires = 2024100700;" > "$d/version.php"' \
  _ "$SITE"
as_www sed -i "/require_once.*lib\/setup.php/i require '/var/moodledata/s2c.inc.php';" "$CONFIG"
as_www sh -c 'printf "%s\n" "$2" > "$1"' _ "$STAMP" "$((CODE_VERSION - 100))"
# s2c_files: what is in /tmp/s2c, from a stopped container too.
s2c_files() { docker cp "$APP:/tmp/s2c" - 2>/dev/null | tar -t 2>/dev/null | sed -n 's|^s2c/||p' | grep . | sort; }
if ! skip="$(restart_app)"; then
  fail "the site upgrades and starts"
  files="$(s2c_files)"
  if grep -qx -e swapped -e moved-out <<< "$files"; then fail "no process left behind swapped clouve/ while root moved the code"
    show "$(grep -x -e swapped -e moved-out <<< "$files")"; fi
else
  log="$(log_since "$skip")"
  files="$(s2c_files)"
  check "the upgrade ran" grep -qF "Moodle upgrade completed successfully." <<< "$log"
  check "steps did leave processes behind" grep -q '^pid-' <<< "$files"
  if grep -qx -e swapped -e moved-out <<< "$files"; then fail "no process left behind swapped clouve/ while root moved the code"
    show "$(grep -x -e swapped -e moved-out <<< "$files")"
  else pass "no process left behind swapped clouve/ while root moved the code"; fi
  assert_eq "nothing of the site was moved outside the volume" "./upgrade-previous.partial d 755" \
    "$(docker exec "$APP" sh -c 'cd /tmp/s2c/out && find . -mindepth 1 -printf "%p %y %m\n" | sort')"
  assert_eq "clouve/ is a real folder" "folder" \
    "$(docker exec "$APP" sh -c 'if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo folder; else echo other; fi' _ "$SITE/clouve")"
  alive="$(docker exec "$APP" sh -c 'for f in /tmp/s2c/pid-*; do p="${f##*-}"; [ -e "$f" ] || continue
    if [ -d "/proc/$p" ] && ! grep -q "^State:[[:space:]]*Z" "/proc/$p/status" 2>/dev/null; then echo "$p $(cat "$f")"; fi; done')"
  if [ -z "$alive" ]; then pass "every process a step left behind is gone"; else
    fail "every process a step left behind is gone"; show "$alive"; fi
  check "the log says what was stopped" grep -qE '^\[clouve-www-data\] .*: stopped [0-9]+ process' <<< "$log"
  if grep -q '^environ-leak-' <<< "$files"; then fail "no process of the start shows CLOUVE_OPS_PASSWORD to those processes"
    show "$(docker exec "$APP" sh -c 'for f in /tmp/s2c/environ-leak-*; do echo "pid ${f##*-}: $(cat "$f")"; done')"
  else pass "no process of the start shows CLOUVE_OPS_PASSWORD to those processes"; fi
  assert_get_root "after the upgrade: GET / answers 200"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sRoot path checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sRoot path checks failed.%s\n' "$RED" "$RESET"
exit 1
