#!/bin/bash

# ============================================================================
# Moodle upgrade: plugins added through the UI test
# ============================================================================
# Admins add plugins with Site administration > Plugins > Install plugins, and
# Moodle writes them into the code tree on the volume. When an image brings a
# newer Moodle, apps/moodle/image/installer/upgrade.sh replaces that whole tree
# with the image's pristine copy. Before this fix it deleted every added plugin
# (their data stayed in the database, their code was gone).
#
# upgrade.sh now moves the old tree aside, copies the new one, and copies back
# the plugins that installer/added-plugins.php lists (plugins that were not part
# of the old Moodle, by the old tree's lib/plugins.json). The old tree stays
# aside until Moodle's upgrade succeeds, so a start that is cut off can simply
# run again. It holds back, in clouve/upgrade-stash/:
#   - a plugin that the new Moodle ships itself (the new core copy wins);
#   - a plugin whose version.php says it won't work with the new Moodle: marked
#     incompatible with the new branch, or needing a plugin the new site won't
#     have; or whose version.php can't be read;
#   - a plugin whose plugin type the new Moodle no longer has;
#   - every carried plugin, when Moodle's upgrade fails twice with them in place
#     (it then runs once more without them, as before this fix). A single
#     failure only makes it run the upgrade again with the plugins in place.
# Plugins that were part of the old Moodle and are gone from the new one (mod_chat
# in 5.0) are never carried over.
#
# Checks the helper's plan on two layouts (5.2 to 5.3, both under public/, and
# a pre-5.1 tree without public/ to 5.3), then runs upgrade.sh on fake Moodle
# trees with stub CLI scripts: a normal upgrade, an old layout, a start cut off
# during the copy, a move aside that was cut off, a failing Moodle upgrade, one
# that fails once, a symlinked clouve/, little free space, a fresh install, an
# unreadable tree and a symlinked stash.
#
# Runs in the php:8.3-apache image (the Moodle image's base), because it needs
# PHP, root and the www-data user. Needs Docker; set TEST_PHP_IMAGE to use
# another image, for example mirror.gcr.io/library/php:8.3-apache.
#
# Usage: bash tests/moodle-upgrade-plugins.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "${1:-}" != "--in-container" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "This test needs Docker." >&2
    exit 2
  fi
  exec docker run --rm -v "$REPO_DIR":/magneto:ro --entrypoint bash \
    "${TEST_PHP_IMAGE:-php:8.3-apache}" /magneto/tests/moodle-upgrade-plugins.test.sh --in-container
fi

INSTALLER_DIR="$REPO_DIR/apps/moodle/image/installer"
HELPER="$INSTALLER_DIR/added-plugins.php"
UPGRADE_SH="$INSTALLER_DIR/upgrade.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected:\n%s\n       actual:\n%s\n' \
    "$(sed 's/^/         /' <<< "$2")" "$(sed 's/^/         /' <<< "$3")"; fi; }
assert_ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1"; printf '       did NOT want: %q\n' "$2"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
assert_not_contains() { if ! grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$3"; fi; }
assert_file() { if [[ -f "$2" ]]; then pass "$1"; else fail "$1"; printf '       missing: %s\n' "$2"; fi; }
assert_dir() { if [[ -d "$2" && ! -L "$2" ]]; then pass "$1"; else fail "$1"; printf '       not a folder: %s\n' "$2"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1"; printf '       still there: %s\n' "$2"; fi; }

WORK="$(mktemp -d)"
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# plugin <dir> <component> [extra version.php lines]
plugin() {
  mkdir -p "$1"
  printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$plugin->component = '%s';\n\$plugin->version = 2026010100;\n%s\n" \
    "$2" "${3:-}" > "$1/version.php"
}

# moodle_version <file> <version> <release> <branch>: a Moodle version.php, with the same guard line as Moodle's.
moodle_version() {
  mkdir -p "$(dirname "$1")"
  printf "<?php\ndefined('MOODLE_INTERNAL') || die();\n\$version = %s.00;\n\$release = '%s (Build: 20260101)';\n\$branch = '%s';\n\$maturity = MATURITY_STABLE;\n" \
    "$2" "$3" "$4" > "$1"
}

# --- The new Moodle (5.3 layout: code under public/, metadata in lib/) --------
NEW="$WORK/new"
mkdir -p "$NEW/lib"
cat > "$NEW/lib/components.json" <<'JSON'
{"plugintypes": {"mod": "public/mod", "local": "public/local", "theme": "public/theme", "editor": "public/lib/editor"},
 "subsystems": {}}
JSON
cat > "$NEW/lib/plugins.json" <<'JSON'
{"standard": {"mod": ["assign"], "local": ["nowcore"], "theme": ["boost"], "editor": ["tiny"],
              "assignsubmission": ["file"], "tiny": ["media"]},
 "deleted": {"mod": ["chat"], "editor": ["atto"]}}
JSON
moodle_version "$NEW/public/version.php" 2026100600 5.3 503
plugin "$NEW/public/mod/assign" mod_assign
mkdir -p "$NEW/public/mod/assign/db"
echo '{"subplugintypes": {"assignsubmission": "submission"}, "plugintypes": {"assignsubmission": "mod/assign/submission"}}' \
  > "$NEW/public/mod/assign/db/subplugins.json"
plugin "$NEW/public/mod/assign/submission/file" assignsubmission_file
plugin "$NEW/public/local/nowcore" local_nowcore "// core copy"
plugin "$NEW/public/theme/boost" theme_boost
plugin "$NEW/public/lib/editor/tiny" editor_tiny
mkdir -p "$NEW/public/lib/editor/tiny/db"
echo '{"subplugintypes": {"tiny": "plugins"}}' > "$NEW/public/lib/editor/tiny/db/subplugins.json"
plugin "$NEW/public/lib/editor/tiny/plugins/media" tiny_media
# Stub CLI scripts: each one records its call. upgrade.php records whether the
# added plugin is in place when it runs. It fails when STUB_FAIL_WITH names a
# path (relative to the code tree) that exists, and once when STUB_FAIL_ONCE
# names a file that exists (it removes the file).
mkdir -p "$NEW/admin/cli"
cat > "$NEW/admin/cli/upgrade.php" <<'PHP'
<?php
$root = dirname(__DIR__, 2);
$present = is_file("$root/public/local/academictranscript/version.php") ? 'yes' : 'no';
$failwith = getenv('STUB_FAIL_WITH');
$fails = $failwith && file_exists("$root/$failwith");
$failonce = getenv('STUB_FAIL_ONCE');
if ($failonce && file_exists($failonce)) {
    unlink($failonce);
    $fails = true;
}
file_put_contents(getenv('MOODLEDATA_PATH') . '/cli.log', "upgrade academictranscript=$present" . ($fails ? ' failed' : '') . "\n",
    FILE_APPEND);
exit($fails ? 1 : 0);
PHP
cat > "$NEW/admin/cli/maintenance.php" <<'PHP'
<?php
file_put_contents(getenv('MOODLEDATA_PATH') . '/cli.log', "maintenance {$argv[1]}\n", FILE_APPEND);
PHP
cat > "$NEW/admin/cli/purge_caches.php" <<'PHP'
<?php
file_put_contents(getenv('MOODLEDATA_PATH') . '/cli.log', "purge\n", FILE_APPEND);
PHP

# --- The old Moodle 5.2 site, with plugins an admin added ---------------------
OLD="$WORK/old52"
mkdir -p "$OLD/lib"
cat > "$OLD/lib/components.json" <<'JSON'
{"plugintypes": {"mod": "public/mod", "local": "public/local", "theme": "public/theme", "editor": "public/lib/editor",
                 "badtype": "../../outside"},
 "subsystems": {}}
JSON
cat > "$OLD/lib/plugins.json" <<'JSON'
{"standard": {"mod": ["assign", "chat"], "local": [], "theme": ["boost"], "editor": ["atto", "tiny"],
              "assignsubmission": ["file"], "atto": ["bold"], "tiny": ["media"]},
 "deleted": {}}
JSON
moodle_version "$OLD/public/version.php" 2026042000 5.2 502
mkdir -p "$OLD/public/lib"
echo '<?php // removed upstream' > "$OLD/public/lib/oldcore.php"
plugin "$OLD/public/mod/assign" mod_assign
mkdir -p "$OLD/public/mod/assign/db"
echo '{"subplugintypes": {"assignsubmission": "submission"}, "plugintypes": {"assignsubmission": "mod/assign/submission"}}' \
  > "$OLD/public/mod/assign/db/subplugins.json"
plugin "$OLD/public/mod/assign/submission/file" assignsubmission_file
plugin "$OLD/public/mod/assign/submission/extra" assignsubmission_extra
plugin "$OLD/public/mod/chat" mod_chat
plugin "$OLD/public/local/academictranscript" local_academictranscript
mkdir -p "$OLD/public/local/academictranscript/classes/local"
echo '<?php // calculator' > "$OLD/public/local/academictranscript/classes/local/calculator.php"
plugin "$OLD/public/local/academictranscript/lib/vendorlib" vendorlib_inside_a_plugin
plugin "$OLD/public/local/needsx" local_needsx "\$plugin->dependencies = ['local_academictranscript' => 2026010100];"
plugin "$OLD/public/local/needschat" local_needschat "\$plugin->dependencies = ['mod_chat' => ANY_VERSION];"
plugin "$OLD/public/local/needsold" local_needsold "\$plugin->dependencies = ['theme_oldtheme' => ANY_VERSION];"
plugin "$OLD/public/local/nowcore" local_nowcore "// added copy"
plugin "$OLD/public/local/noisy" local_noisy "echo 'noise'; \$plugin->release = \$undefined . '1.0';"
plugin "$OLD/public/local/exits" local_exits "echo 'bye'; exit(0);"
plugin "$OLD/public/local/listdeps" local_listdeps "\$plugin->dependencies = ['local_academictranscript'];"
plugin "$OLD/public/theme/boost" theme_boost
plugin "$OLD/public/theme/oldtheme" theme_oldtheme "\$plugin->incompatible = 503;"
mkdir -p "$OLD/public/theme/oldtheme/emptydir"
plugin "$OLD/public/lib/editor/atto" editor_atto
mkdir -p "$OLD/public/lib/editor/atto/db"
echo '{"subplugintypes": {"atto": "plugins"}}' > "$OLD/public/lib/editor/atto/db/subplugins.json"
plugin "$OLD/public/lib/editor/atto/plugins/bold" atto_bold
plugin "$OLD/public/lib/editor/atto/plugins/extra" atto_extra
plugin "$OLD/public/lib/editor/tiny" editor_tiny
mkdir -p "$OLD/public/lib/editor/tiny/db"
echo '{"subplugintypes": {"tiny": "plugins"}}' > "$OLD/public/lib/editor/tiny/db/subplugins.json"
plugin "$OLD/public/lib/editor/tiny/plugins/media" tiny_media
plugin "$OLD/public/lib/editor/tiny/plugins/extra" tiny_extra
mkdir -p "$OLD/public/local/not-a-plugin-name"
echo '<?php' > "$OLD/public/local/not-a-plugin-name/version.php"
echo '<?php // site config' > "$OLD/config.php"
mkdir -p "$OLD/clouve/installed"
echo 2026042000 > "$OLD/clouve/installed/version"
# A folder outside every code tree, which the bad "badtype" path above points at.
plugin "$WORK/outside/evil" badtype_evil

# --- An old site from before Moodle 5.1 (no public/, 4.5-style subplugins) ----
OLD50="$WORK/old50"
mkdir -p "$OLD50/lib"
echo '{"plugintypes": {"mod": "mod", "local": "local"}, "subsystems": {}}' > "$OLD50/lib/components.json"
echo '{"standard": {"mod": ["assign"], "local": [], "assignsubmission": ["file"]}, "deleted": {}}' > "$OLD50/lib/plugins.json"
moodle_version "$OLD50/version.php" 2025041400 5.0 500
plugin "$OLD50/mod/assign" mod_assign
mkdir -p "$OLD50/mod/assign/db"
echo '{"plugintypes": {"assignsubmission": "mod/assign/submission"}}' > "$OLD50/mod/assign/db/subplugins.json"
plugin "$OLD50/mod/assign/submission/file" assignsubmission_file
plugin "$OLD50/mod/assign/submission/extra" assignsubmission_extra
plugin "$OLD50/local/academictranscript" local_academictranscript
echo '<?php // site config' > "$OLD50/config.php"

# A cp that fails once, when FAIL_CP_ONCE names a file that exists (the file is
# removed). It cuts a run off during the copy of the new tree.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/cp" <<'SH'
#!/bin/bash
if [[ -n "${FAIL_CP_ONCE:-}" && -e "$FAIL_CP_ONCE" ]]; then
  rm -f "$FAIL_CP_ONCE"
  echo "cp: simulated failure" >&2
  exit 1
fi
exec /bin/cp "$@"
SH
chmod +x "$STUBS/cp"
# A df that reports STUB_DF_FREE_KB free kilobytes when it is set.
cat > "$STUBS/df" <<'SH'
#!/bin/bash
if [[ -n "${STUB_DF_FREE_KB:-}" ]]; then
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "stub 100000 99000 $STUB_DF_FREE_KB 99% /"
  exit 0
fi
exec /bin/df "$@"
SH
chmod +x "$STUBS/df"

chmod -R a+rX "$WORK"
T=$'\t'
# The plan without its closing "end" line, sorted. Prints a marker when "end" is missing.
plan() {
  local out
  out="$(php "$HELPER" "$1" "$2")"
  [[ "$(tail -n1 <<< "$out")" == end ]] || echo "THE PLAN HAS NO end LINE"
  sed '$d' <<< "$out" | sort
}

echo "added-plugins.php: plan for a 5.2 site moving to 5.3"
PLAN52="$(plan "$OLD" "$NEW")"
assert_eq "keeps added plugins and holds back the ones that won't work with the new Moodle" \
"keep${T}assignsubmission_extra${T}public/mod/assign/submission/extra${T}public/mod/assign/submission/extra${T}-
keep${T}local_academictranscript${T}public/local/academictranscript${T}public/local/academictranscript${T}-
keep${T}local_needsx${T}public/local/needsx${T}public/local/needsx${T}-
keep${T}local_noisy${T}public/local/noisy${T}public/local/noisy${T}-
keep${T}tiny_extra${T}public/lib/editor/tiny/plugins/extra${T}public/lib/editor/tiny/plugins/extra${T}-
skip${T}atto_extra${T}public/lib/editor/atto/plugins/extra${T}-${T}the new Moodle has no atto plugins
skip${T}local_exits${T}public/local/exits${T}-${T}its version.php cannot be read
skip${T}local_listdeps${T}public/local/listdeps${T}-${T}its version.php has dependencies this script cannot read
skip${T}local_needschat${T}public/local/needschat${T}-${T}needs mod_chat, which the new Moodle does not have
skip${T}local_needsold${T}public/local/needsold${T}-${T}needs theme_oldtheme, which is held back too
skip${T}local_nowcore${T}public/local/nowcore${T}-${T}the new Moodle has its own copy
skip${T}theme_oldtheme${T}public/theme/oldtheme${T}-${T}incompatible with Moodle 503 and later" \
  "$PLAN52"

echo "added-plugins.php: plan for a site from before 5.1 (no public/) moving to 5.3"
PLAN50="$(plan "$OLD50" "$NEW")"
assert_eq "maps each added plugin to its place under public/" \
"keep${T}assignsubmission_extra${T}mod/assign/submission/extra${T}public/mod/assign/submission/extra${T}-
keep${T}local_academictranscript${T}local/academictranscript${T}public/local/academictranscript${T}-" \
  "$PLAN50"

echo "added-plugins.php: a tree without lib/plugins.json"
NOMETA="$WORK/nometa"
cp -a "$OLD50" "$NOMETA"
rm "$NOMETA/lib/plugins.json"
ERR="$(php "$HELPER" "$NOMETA" "$NEW" 2>&1 >/dev/null)"
RC=$?
assert_eq "fails" "1" "$RC"
assert_contains "says which file is missing" "$ERR" "plugins.json"

# --- upgrade.sh --------------------------------------------------------------
# make_site <old tree to copy, or "" for an empty volume> <name>
make_site() {
  local site="$WORK/$2"
  mkdir -p "$site/html" "$site/moodledata/cache"
  [[ -z "$1" ]] || cp -a "$1/." "$site/html/"
  chown -R www-data:www-data "$site/html" "$site/moodledata"
}
# upgrade_site <name> [VAR=value ...]: runs upgrade.sh on the site, with the stub cp on PATH.
upgrade_site() {
  local site="$WORK/$1"
  shift
  env "$@" PATH="$STUBS:$PATH" MOODLE_PACKAGE_PATH="$NEW" MOODLE_INSTALL_PATH="$site/html" \
    MOODLEDATA_PATH="$site/moodledata" MOODLE_PACKAGE_INSTALLER="$INSTALLER_DIR" bash "$UPGRADE_SH" 2>&1
}
stash_of() { find "$WORK/$1/html/clouve/upgrade-stash" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1; }

echo "upgrade.sh: a 5.2 site with added plugins moves to 5.3"
make_site "$OLD" site52
OUT="$(upgrade_site site52)"
RC=$?
H="$WORK/site52/html"
assert_eq "exits 0" "0" "$RC"
assert_file "the added plugin is back" "$H/public/local/academictranscript/version.php"
assert_file "with all its files" "$H/public/local/academictranscript/classes/local/calculator.php"
assert_file "and what it bundles" "$H/public/local/academictranscript/lib/vendorlib/version.php"
assert_file "an added subplugin of a core plugin is back" "$H/public/mod/assign/submission/extra/version.php"
assert_file "an added TinyMCE plugin is back" "$H/public/lib/editor/tiny/plugins/extra/version.php"
assert_file "a plugin that needs another added plugin is back" "$H/public/local/needsx/version.php"
assert_absent "a plugin removed from Moodle core is not carried over" "$H/public/mod/chat"
assert_absent "a core file removed upstream is gone" "$H/public/lib/oldcore.php"
assert_contains "the new core copy wins over an added copy" "$(cat "$H/public/local/nowcore/version.php")" "core copy"
assert_absent "an incompatible plugin is held back" "$H/public/theme/oldtheme"
assert_absent "a plugin that needs a removed plugin is held back" "$H/public/local/needschat"
STASH="$(stash_of site52)"
assert_file "held-back plugins are kept in the stash" "$STASH/public/theme/oldtheme/version.php"
assert_dir "as they were, empty folders too" "$STASH/public/theme/oldtheme/emptydir"
assert_file "with the added copy of a plugin the new Moodle ships" "$STASH/public/local/nowcore/version.php"
assert_absent "kept plugins are not in the stash" "$STASH/public/local/academictranscript"
assert_absent "the old code is gone once the upgrade succeeded" "$H/clouve/upgrade-previous"
assert_file "nothing outside the tree is touched" "$WORK/outside/evil/version.php"
assert_contains "the log names a held-back plugin and why" "$OUT" \
  "theme_oldtheme held back (incompatible with Moodle 503 and later)"
assert_contains "the log says where held-back plugins are" "$OUT" "$STASH"
assert_contains "the log names a kept plugin" "$OUT" "Kept local_academictranscript"
assert_contains "the log says how much the stash holds" "$OUT" "The stash $H/clouve/upgrade-stash holds"
assert_eq "config.php is kept" "<?php // site config" "$(cat "$H/config.php")"
assert_file "Clouve's bookkeeping is kept" "$H/clouve/installed/version"
assert_eq "the CLI steps run in order, with the plugin back before the upgrade" \
"maintenance --enable
upgrade academictranscript=yes
purge
maintenance --disable" "$(cat "$WORK/site52/moodledata/cli.log")"
assert_eq "restored plugins belong to www-data" "www-data" \
  "$(stat -c %U "$H/public/local/academictranscript/version.php")"

echo "upgrade.sh: a site from before 5.1 moves to the public/ layout"
make_site "$OLD50" site50
OUT="$(upgrade_site site50)"
RC=$?
H="$WORK/site50/html"
assert_eq "exits 0" "0" "$RC"
assert_file "the added plugin is under public/" "$H/public/local/academictranscript/version.php"
assert_file "the added subplugin is under public/" "$H/public/mod/assign/submission/extra/version.php"
assert_absent "the old layout is gone" "$H/local"

echo "upgrade.sh: a start cut off during the copy, then a restart"
make_site "$OLD50" sitecut
touch "$WORK/fail-cp"
OUT="$(upgrade_site sitecut FAIL_CP_ONCE="$WORK/fail-cp")"
RC=$?
H="$WORK/sitecut/html"
assert_ne "the first start fails" "0" "$RC"
OUT="$(upgrade_site sitecut)"
RC=$?
assert_eq "the next start completes" "0" "$RC"
assert_contains "and says it picks up the cut-off upgrade" "$OUT" "cut off"
assert_file "the added plugin is back" "$H/public/local/academictranscript/version.php"
assert_eq "it was in place when Moodle's upgrade ran" "upgrade academictranscript=yes" \
  "$(grep '^upgrade' "$WORK/sitecut/moodledata/cli.log")"
assert_absent "the old code is gone once the upgrade succeeded" "$H/clouve/upgrade-previous"

echo "upgrade.sh: a move aside that was cut off"
make_site "$OLD" sitepartial
H="$WORK/sitepartial/html"
mkdir -p "$H/clouve/upgrade-previous.partial"
mv "$H/public" "$H/clouve/upgrade-previous.partial/"
OUT="$(upgrade_site sitepartial)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_file "the added plugin is back" "$H/public/local/academictranscript/version.php"
assert_absent "the half-moved folder is gone" "$H/clouve/upgrade-previous.partial"
assert_eq "the plugin was in place when Moodle's upgrade ran" "upgrade academictranscript=yes" \
  "$(grep '^upgrade' "$WORK/sitepartial/moodledata/cli.log")"

echo "upgrade.sh: Moodle's upgrade fails with an added plugin in place"
make_site "$OLD50" sitebroken
OUT="$(upgrade_site sitebroken STUB_FAIL_WITH=public/local/academictranscript)"
RC=$?
H="$WORK/sitebroken/html"
STASH="$(stash_of sitebroken)"
assert_eq "the site still comes up" "0" "$RC"
assert_absent "without the added plugins" "$H/public/local/academictranscript"
assert_file "which are saved in the stash" "$STASH/local/academictranscript/version.php"
assert_contains "the log says why" "$OUT" \
  "local_academictranscript held back (Moodle's upgrade failed twice with the added plugins in place)"
assert_eq "the upgrade runs twice with them, then once without them" \
"maintenance --enable
upgrade academictranscript=yes failed
upgrade academictranscript=yes failed
upgrade academictranscript=no
purge
maintenance --disable" "$(cat "$WORK/sitebroken/moodledata/cli.log")"
assert_absent "the old code is gone once the upgrade succeeded" "$H/clouve/upgrade-previous"

echo "upgrade.sh: Moodle's upgrade fails once, for another reason"
make_site "$OLD50" siteblip
touch "$WORK/siteblip/moodledata/fail-once"   # in a folder www-data can write, as the stub runs as www-data
OUT="$(upgrade_site siteblip STUB_FAIL_ONCE="$WORK/siteblip/moodledata/fail-once")"
RC=$?
H="$WORK/siteblip/html"
assert_eq "exits 0" "0" "$RC"
assert_file "the added plugin stays" "$H/public/local/academictranscript/version.php"
assert_absent "nothing is held back" "$H/clouve/upgrade-stash"
assert_eq "the upgrade runs again with the plugins in place" \
"maintenance --enable
upgrade academictranscript=yes failed
upgrade academictranscript=yes
purge
maintenance --disable" "$(cat "$WORK/siteblip/moodledata/cli.log")"

echo "upgrade.sh: clouve/ is a symbolic link"
make_site "$OLD" siteclouvelink
H="$WORK/siteclouvelink/html"
mv "$H/clouve" "$WORK/clouve-elsewhere"
ln -s "$WORK/clouve-elsewhere" "$H/clouve"
OUT="$(upgrade_site siteclouvelink)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_dir "clouve/ is a real folder" "$H/clouve"
assert_eq "nothing is moved through the link" "installed" "$(ls -A "$WORK/clouve-elsewhere")"
assert_file "the version stamp is copied into the new folder, for entrypoint.sh" "$H/clouve/installed/version"
assert_file "the added plugin is back" "$H/public/local/academictranscript/version.php"

echo "upgrade.sh: little free space on the code volume"
make_site "$OLD50" sitefull
OUT="$(upgrade_site sitefull STUB_DF_FREE_KB=1)"
RC=$?
assert_eq "still tries, and here succeeds" "0" "$RC"
assert_contains "warns that the old code needs room while it is kept" "$OUT" "WARNING: the code volume has"

echo "upgrade.sh: a fresh install (empty volume)"
make_site "" sitefresh
OUT="$(upgrade_site sitefresh)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_file "copies the code" "$WORK/sitefresh/html/public/version.php"
assert_not_contains "prints no warning" "$OUT" "WARNING"

echo "upgrade.sh: a tree the helper can't read"
make_site "$NOMETA" sitenometa
OUT="$(upgrade_site sitenometa)"
RC=$?
STASH="$(stash_of sitenometa)"
assert_eq "still upgrades" "0" "$RC"
assert_contains "warns" "$OUT" "WARNING"
assert_file "and keeps the old code, added plugins included" "$STASH/previous/local/academictranscript/version.php"

echo "upgrade.sh: a symlinked stash"
make_site "$OLD" sitelink
H="$WORK/sitelink/html"
mkdir -p "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$H/clouve/upgrade-stash"
OUT="$(upgrade_site sitelink)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_dir "the stash is a real folder" "$H/clouve/upgrade-stash"
assert_eq "nothing is written through the link" "" "$(ls -A "$WORK/elsewhere")"

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf "${GREEN}All checks passed.${NC}\n"
else
  printf "${RED}Some checks failed.${NC}\n"
fi
exit "$FAILED"
