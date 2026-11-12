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
#     incompatible with the new branch, a supported range that leaves the new
#     branch out, or needing a plugin the new site won't have; or whose
#     version.php can't be read;
#   - a plugin whose plugin type the new Moodle no longer has;
#   - every carried plugin, when Moodle's upgrade fails twice with them in place
#     (it then runs once more without them, as before this fix). A single
#     failure only makes it run the upgrade again with the plugins in place.
# Plugins that were part of the old Moodle and are gone from the new one (mod_chat
# in 5.0, the Classic theme in 5.3) are never carried over, and a config.php line
# that forces the Classic theme is turned into a comment when the new code has
# no Classic theme (Moodle's own upgrade moves every other Classic choice to Boost).
#
# Checks the helper's plan on two layouts (5.2 to 5.3, both under public/, and
# a pre-5.1 tree without public/ to 5.3), then runs upgrade.sh on fake Moodle
# trees with stub CLI scripts: a normal upgrade, an old layout, a start cut off
# during the copy, a move aside that was cut off, a start cut off during Moodle's
# upgrade (its upgrade lock is cleared, by SQL with the password in MYSQL_PWD),
# a failing Moodle upgrade, one that fails once, a symlinked clouve/, little free
# space, a fresh install, an unreadable tree, a symlinked stash, a config.php
# that forces Classic, and a
# Classic theme that an admin installed again after 5.3. Last, it runs the plan
# and upgrade.sh from the previous pinned Moodle to the Dockerfile's, on trees
# made from the real releases' metadata (lib/*.json, version.php, every
# db/subplugins.json, the old release's Classic theme), with the plugins of the
# ZIPs in MOODLE_PLUGIN_ZIPS as the added ones (stand-ins when it isn't set) and
# one whose supported range ends at the old release.
#
# Runs in the php:8.3-apache image (the Moodle image's base), because it needs
# PHP, root and the www-data user. Needs Docker, and network the first time: the
# two Moodle releases are downloaded once (about 190 MB), checked against their
# sha256 and kept in ~/.cache/magneto/moodle-tarballs (MOODLE_TARBALL_CACHE).
# Set TEST_PHP_IMAGE to use another image, for example
# mirror.gcr.io/library/php:8.3-apache.
#
# Usage: bash tests/moodle-upgrade-plugins.test.sh
#        MOODLE_PLUGIN_ZIPS=<folder of plugin ZIPs> bash tests/moodle-upgrade-plugins.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The Moodle that the image replaces: the previous pinned build, as the Dockerfile had it.
PREV_URL=https://download.moodle.org/download.php/direct/stable502/moodle-5.2.tgz
PREV_SHA256=48f0f521375006be84c227e6a595313ebcc9dc55455499b5150dcfe865782cfe

if [[ "${1:-}" != "--in-container" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "This test needs Docker." >&2
    exit 2
  fi
  sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
  }
  # fetch_tarball URL SHA256: the release in the cache, downloaded once and checked every time.
  CACHE="${MOODLE_TARBALL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/magneto/moodle-tarballs}"
  fetch_tarball() {
    local file="$CACHE/$2.tgz"
    mkdir -p "$CACHE" || return 1
    if [[ ! -f "$file" ]]; then
      echo "Downloading $1 ..." >&2
      curl -fsSL --retry 2 -o "$file.part" "$1" && mv "$file.part" "$file" || { rm -f "$file.part"; return 1; }
    fi
    if [[ "$(sha256_of "$file")" != "$2" ]]; then
      echo "$file does not have the checksum $2; removed it." >&2
      rm -f "$file"
      return 1
    fi
  }
  DOCKERFILE="$REPO_DIR/apps/moodle/image/Dockerfile"
  NEW_VERSION="$(sed -nE 's/^ENV MOODLE_VERSION=([0-9]+).*/\1/p' "$DOCKERFILE")"
  NEW_RELEASE="$(sed -nE 's/^ENV MOODLE_RELEASE=([0-9.]+).*/\1/p' "$DOCKERFILE")"
  NEW_SHA256="$(sed -nE 's/^ADD --checksum=sha256:([0-9a-f]{64}).*/\1/p' "$DOCKERFILE")"
  NEW_URL="$(sed -nE 's#^[[:space:]]*(https://download\.moodle\.org/[^[:space:]]+\.tgz).*#\1#p' "$DOCKERFILE")"
  NEW_URL="${NEW_URL//'${MOODLE_VERSION}'/$NEW_VERSION}"
  NEW_URL="${NEW_URL//'${MOODLE_RELEASE}'/$NEW_RELEASE}"
  if [[ -z "$NEW_SHA256" || "$NEW_URL" != https://*.tgz ]] || ! fetch_tarball "$PREV_URL" "$PREV_SHA256" ||
      ! fetch_tarball "$NEW_URL" "$NEW_SHA256"; then
    echo "Could not get the previous Moodle and the Dockerfile's, which the run on the real metadata needs." >&2
    exit 2
  fi
  # The plugins in MOODLE_PLUGIN_ZIPS, unpacked here because the PHP image has no unzip. Each ZIP gets a folder of its
  # own, because two plugins of different types can have the same name (local_x and theme_x).
  PLUGIN_SRC="$(mktemp -d)"
  trap 'rm -rf "$PLUGIN_SRC"' EXIT
  if [[ -n "${MOODLE_PLUGIN_ZIPS:-}" ]]; then
    if ! python3 -I -c '
import pathlib, sys, zipfile
for n, z in enumerate(sorted(pathlib.Path(sys.argv[1]).glob("*.zip"))):
    with zipfile.ZipFile(z) as f:
        f.extractall(pathlib.Path(sys.argv[2]) / str(n))
' "$MOODLE_PLUGIN_ZIPS" "$PLUGIN_SRC" || [[ -z "$(ls -A "$PLUGIN_SRC")" ]]; then
      echo "MOODLE_PLUGIN_ZIPS ($MOODLE_PLUGIN_ZIPS) holds no plugin ZIP that python3 can unpack." >&2
      exit 2
    fi
    chmod -R a+rX "$PLUGIN_SRC"
  fi
  docker run --rm -v "$REPO_DIR":/magneto:ro -v "$CACHE":/moodle-tarballs:ro -v "$PLUGIN_SRC":/plugin-src:ro \
    -e PREV_TGZ="/moodle-tarballs/$PREV_SHA256.tgz" -e NEW_TGZ="/moodle-tarballs/$NEW_SHA256.tgz" --entrypoint bash \
    "${TEST_PHP_IMAGE:-php:8.3-apache}" /magneto/tests/moodle-upgrade-plugins.test.sh --in-container
  exit $?
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
 "deleted": {"mod": ["chat"], "editor": ["atto"], "theme": ["classic"]}}
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
# names a file that exists (it removes the file). When it fails, it prints
# STUB_CULPRIT as Moodle prints the plugin it is upgrading ("-->component").
mkdir -p "$NEW/admin/cli"
cat > "$NEW/admin/cli/upgrade.php" <<'PHP'
<?php
$root = dirname(__DIR__, 2);
// Moodle's upgrade lock (upgraderunning in its config table), which a start cut off during the upgrade leaves set.
if (file_exists(getenv('MOODLEDATA_PATH') . '/upgraderunning')) {
    echo "!!! Site is being upgraded, please retry later. !!!\n";
    file_put_contents(getenv('MOODLEDATA_PATH') . '/cli.log', "upgrade locked\n", FILE_APPEND);
    exit(1);
}
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
if ($fails && getenv('STUB_CULPRIT')) {
    echo "-->" . getenv('STUB_CULPRIT') . "\n";
}
$config = (string)@file_get_contents("$root/config.php");
$forced = preg_match('/^\s*\$CFG->theme\s*=\s*[\'"]classic[\'"]/m', $config) ? 'yes' : 'no';
file_put_contents(getenv('MOODLEDATA_PATH') . '/theme.log', "classic forced=$forced\n", FILE_APPEND);
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
{"standard": {"mod": ["assign", "chat"], "local": [], "theme": ["boost", "classic"], "editor": ["atto", "tiny"],
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
plugin "$OLD/public/theme/classic" theme_classic "\$plugin->supported = [500, 502];"
plugin "$OLD/public/theme/oldtheme" theme_oldtheme "\$plugin->incompatible = 503;"
plugin "$OLD/public/local/oldsupport" local_oldsupport "\$plugin->supported = [401, 502];"
plugin "$OLD/public/local/badsupport" local_badsupport "\$plugin->supported = '503';"
plugin "$OLD/public/local/supports503" local_supports503 "\$plugin->supported = [405, 503];"
plugin "$OLD/public/local/wasoutside" local_wasoutside "\$plugin->supported = [400, 405];"
plugin "$OLD/public/theme/classickid" theme_classickid
printf '<?php\n$THEME->name = '"'classickid'"';\n$THEME->parents = ['"'classic'"'];\n' > "$OLD/public/theme/classickid/config.php"
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
# A mysql that records its arguments and its environment's MYSQL_PWD (not the password: whether it is set),
# removes the stub lock file when it is told to delete Moodle's upgrade lock, and answers the query for the plugin
# versions Moodle recorded with the lines of the file STUB_RECORDED names.
cat > "$STUBS/mysql" <<'SH'
#!/bin/bash
echo "mysql $* MYSQL_PWD=${MYSQL_PWD:+set}" >> "${MOODLEDATA_PATH:?}/mysql.log"
if [[ "$*" == *"WHERE name = 'upgraderunning'"* ]]; then
  rm -f "$MOODLEDATA_PATH/upgraderunning"
fi
if [[ "$*" == *"config_plugins WHERE name = 'version'"* && -n "${STUB_RECORDED:-}" ]]; then
  cat "$STUB_RECORDED"
fi
SH
chmod +x "$STUBS/mysql"

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
keep${T}local_supports503${T}public/local/supports503${T}public/local/supports503${T}-
keep${T}local_wasoutside${T}public/local/wasoutside${T}public/local/wasoutside${T}its version.php supports Moodle 400 to 405, not 503, and it already ran on 502 outside that range
keep${T}theme_classickid${T}public/theme/classickid${T}public/theme/classickid${T}-
keep${T}tiny_extra${T}public/lib/editor/tiny/plugins/extra${T}public/lib/editor/tiny/plugins/extra${T}-
skip${T}atto_extra${T}public/lib/editor/atto/plugins/extra${T}-${T}the new Moodle has no atto plugins
skip${T}local_badsupport${T}public/local/badsupport${T}-${T}its version.php has a supported value this script cannot read
skip${T}local_exits${T}public/local/exits${T}-${T}its version.php cannot be read
skip${T}local_listdeps${T}public/local/listdeps${T}-${T}its version.php has dependencies this script cannot read
skip${T}local_needschat${T}public/local/needschat${T}-${T}needs mod_chat, which the new Moodle does not have
skip${T}local_needsold${T}public/local/needsold${T}-${T}needs theme_oldtheme, which is held back too
skip${T}local_nowcore${T}public/local/nowcore${T}-${T}the new Moodle has its own copy
skip${T}local_oldsupport${T}public/local/oldsupport${T}-${T}its version.php supports Moodle 401 to 502, not 503
skip${T}theme_oldtheme${T}public/theme/oldtheme${T}-${T}incompatible with Moodle 503 and later" \
  "$PLAN52"
assert_not_contains "never lists the old Moodle's Classic theme, which 5.3 removed" "$PLAN52" "${T}theme_classic${T}"

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
  env "$@" PATH="$STUBS:$PATH" MOODLE_PACKAGE_PATH="${PKG:-$NEW}" MOODLE_INSTALL_PATH="$site/html" \
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
assert_absent "a plugin whose supported range leaves out the new Moodle is held back" "$H/public/local/oldsupport"
assert_file "a plugin whose supported range includes the new Moodle is back" "$H/public/local/supports503/version.php"
assert_absent "the old Moodle's Classic theme is not carried over" "$H/public/theme/classic"
assert_file "a plugin that already ran outside its supported range on the old Moodle is kept" \
  "$H/public/local/wasoutside/version.php"
assert_contains "with a warning that says why" "$OUT" \
  "WARNING: Kept local_wasoutside (public/local/wasoutside): its version.php supports Moodle 400 to 405, not 503, and it already ran on 502 outside that range"
assert_contains "a kept theme based on Classic gets a warning" "$OUT" \
  "WARNING: theme_classickid is based on the Classic theme, which this Moodle doesn't have"
assert_contains "held-back plugins are named before Moodle's upgrade runs" \
  "$(sed -n '1,/Running database upgrade/p' <<< "$OUT")" "Holding back theme_oldtheme (incompatible with Moodle 503 and later)"
assert_absent "a plugin that needs a removed plugin is held back" "$H/public/local/needschat"
STASH="$(stash_of site52)"
assert_file "held-back plugins are kept in the stash" "$STASH/public/theme/oldtheme/version.php"
assert_dir "as they were, empty folders too" "$STASH/public/theme/oldtheme/emptydir"
assert_file "with the added copy of a plugin the new Moodle ships" "$STASH/public/local/nowcore/version.php"
assert_file "and the plugin whose supported range leaves out the new Moodle" "$STASH/public/local/oldsupport/version.php"
assert_absent "the old Moodle's Classic theme is not stashed: it was part of that Moodle" "$STASH/public/theme/classic"
assert_absent "kept plugins are not in the stash" "$STASH/public/local/academictranscript"
assert_absent "the old code is gone once the upgrade succeeded" "$H/clouve/upgrade-previous"
assert_file "nothing outside the tree is touched" "$WORK/outside/evil/version.php"
assert_contains "the log names a held-back plugin and why" "$OUT" \
  "theme_oldtheme held back (incompatible with Moodle 503 and later)"
assert_contains "the log says where held-back plugins are" "$OUT" "$STASH"
assert_contains "the log says why a plugin outside its supported range is held back" "$OUT" \
  "local_oldsupport held back (its version.php supports Moodle 401 to 502, not 503)"
assert_contains "the log names a kept plugin" "$OUT" "Kept local_academictranscript"
assert_contains "the log says how much the stash holds" "$OUT" "The stash $H/clouve/upgrade-stash holds"
assert_eq "config.php is kept" "<?php // site config" "$(cat "$H/config.php")"
assert_file "Clouve's bookkeeping is kept" "$H/clouve/installed/version"
assert_eq "the CLI steps run in order, with the plugin back before the upgrade" \
"maintenance --enable
upgrade academictranscript=yes
purge
maintenance --disable" "$(cat "$WORK/site52/moodledata/cli.log")"
assert_not_contains "a start that picks up nothing leaves Moodle's upgrade lock alone" \
  "$(cat "$WORK/site52/moodledata/mysql.log" 2>/dev/null)" "upgraderunning"
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

echo "upgrade.sh: a start cut off during Moodle's upgrade, which leaves Moodle's upgrade lock"
make_site "$OLD50" sitelock
H="$WORK/sitelock/html"
printf '<?php // site config\n$CFG->prefix    = '"'m_'"';\n' > "$H/config.php"
touch "$WORK/fail-cp-lock"
upgrade_site sitelock FAIL_CP_ONCE="$WORK/fail-cp-lock" >/dev/null   # leaves the old code in upgrade-previous
touch "$WORK/sitelock/moodledata/upgraderunning"                    # and Moodle's lock, as its upgrade leaves it
OUT="$(upgrade_site sitelock DB_HOST=db.invalid DB_NAME=moodle DB_USER=moodle DB_PASSWORD=Not-A-Real-Password-1)"
RC=$?
assert_eq "the next start completes" "0" "$RC"
assert_contains "after clearing the lock the cut-off start left" "$OUT" "Cleared Moodle's upgrade lock"
assert_eq "so Moodle's upgrade runs once, with the added plugin in place" "upgrade academictranscript=yes" \
  "$(grep '^upgrade' "$WORK/sitelock/moodledata/cli.log")"
assert_file "the added plugin is back" "$H/public/local/academictranscript/version.php"
assert_contains "the lock is deleted from the site's own config table" "$(cat "$WORK/sitelock/moodledata/mysql.log")" \
  "DELETE FROM m_config WHERE name = 'upgraderunning'"
assert_contains "with the password in MYSQL_PWD" "$(cat "$WORK/sitelock/moodledata/mysql.log")" "MYSQL_PWD=set"
assert_not_contains "never on the command line" "$(cat "$WORK/sitelock/moodledata/mysql.log")" "Not-A-Real-Password-1"

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

echo "upgrade.sh: a 5.2 site whose config.php forces the Classic theme"
make_site "$OLD" siteclassic
H="$WORK/siteclassic/html"
cat > "$H/config.php" <<'PHP'
<?php // site config
$CFG->wwwroot   = 'http://example.test';
  $CFG->theme = "classic" ;
$CFG->themelist = 'classic,boost';
require_once(__DIR__ . '/lib/setup.php');
PHP
chown www-data:www-data "$H/config.php"
OUT="$(upgrade_site siteclassic)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_eq "config.php no longer forces the removed theme, and keeps every other line" \
"<?php // site config
\$CFG->wwwroot   = 'http://example.test';
  ; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \$CFG->theme = \"classic\" ;
\$CFG->themelist = 'classic,boost';
require_once(__DIR__ . '/lib/setup.php');" "$(cat "$H/config.php")"
assert_eq "after Moodle's upgrade, which still sees Classic as the site theme and moves its settings to Boost" \
  "classic forced=yes" "$(cat "$WORK/siteclassic/moodledata/theme.log")"
assert_contains "the log says so" "$OUT" "config.php forced the Classic theme"
assert_eq "config.php still belongs to www-data" "www-data" "$(stat -c %U "$H/config.php")"

echo "upgrade.sh: a site where the admin installed the Classic theme again after 5.3"
OLD53="$WORK/old53"
cp -a "$NEW" "$OLD53"
rm -rf "$OLD53/admin"
plugin "$OLD53/public/theme/classic" theme_classic "\$plugin->supported = [503, 503];"
printf '<?php // site config\n$CFG->theme = '"'classic'"';\n' > "$OLD53/config.php"
mkdir -p "$OLD53/clouve/installed"
echo 2026100600 > "$OLD53/clouve/installed/version"
chmod -R a+rX "$OLD53"
assert_eq "the plan keeps it, as any plugin the admin added" \
  "keep${T}theme_classic${T}public/theme/classic${T}public/theme/classic${T}-" "$(plan "$OLD53" "$NEW")"
make_site "$OLD53" siteclassic53
H="$WORK/siteclassic53/html"
OUT="$(upgrade_site siteclassic53)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_file "the admin's Classic theme is back" "$H/public/theme/classic/version.php"
assert_contains "and config.php still chooses it" "$(cat "$H/config.php")" "
\$CFG->theme = 'classic';"
assert_not_contains "nothing about the Classic theme is logged" "$OUT" "config.php forced the Classic theme"

echo "upgrade.sh: config.php lines that set Classic in ways the upgrade can't safely change"
make_site "$OLD" siteclassicodd
H="$WORK/siteclassicodd/html"
cat > "$H/config.php" <<'PHP'
<?php // site config
$debug = false;
if ($debug)
    $CFG->theme = 'classic';   // only while debugging
$CFG->theme = 'classic'; $CFG->lang = 'en';
$CFG->theme = 'classic'; /* chosen
   in 2025 */
require_once(__DIR__ . '/lib/setup.php');
PHP
chown www-data:www-data "$H/config.php"
OUT="$(upgrade_site siteclassicodd)"
RC=$?
assert_eq "exits 0" "0" "$RC"
assert_eq "config.php is still valid PHP" "0" "$(php -l "$H/config.php" >/dev/null 2>&1; echo $?)"
assert_contains "a lone statement becomes an empty one, so the if keeps its body" "$(cat "$H/config.php")" \
  "    ; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \$CFG->theme = 'classic';   // only while debugging"
assert_contains "a line with another statement is left as it is" "$(cat "$H/config.php")" \
  "\$CFG->theme = 'classic'; \$CFG->lang = 'en';"
assert_contains "so is a line that opens a block comment" "$(cat "$H/config.php")" "\$CFG->theme = 'classic'; /* chosen"
assert_contains "and the log says which lines to change by hand" "$OUT" \
  "WARNING: config.php sets the Classic theme on line 5, which this upgrade doesn't change"
assert_contains "for each of them" "$OUT" "WARNING: config.php sets the Classic theme on line 6"

echo "upgrade.sh: a config.php edit that would break PHP is undone"
make_site "$OLD" siteclassiclint
H="$WORK/siteclassiclint/html"
printf '<?php // site config\n$CFG->theme = "classic";\n$broken = ;\n' > "$H/config.php"
cp "$H/config.php" "$WORK/config-lint-before.php"
chown www-data:www-data "$H/config.php"
OUT="$(upgrade_site siteclassiclint)"
assert_eq "config.php is left exactly as it was" "$(cat "$WORK/config-lint-before.php")" "$(cat "$H/config.php")"
assert_contains "and the log says so" "$OUT" "WARNING: config.php fails php -l after the change"

echo "upgrade.sh: an added plugin newer than the new Moodle's own copy"
OLDNEWER="$WORK/oldnewer"
cp -a "$OLD50" "$OLDNEWER"
plugin "$OLDNEWER/local/nowcore" local_nowcore "// added copy, newer"
sed -i 's/2026010100/2026120100/' "$OLDNEWER/local/nowcore/version.php"
chmod -R a+rX "$OLDNEWER"
assert_contains "the plan says to stop" "$(php "$HELPER" "$OLDNEWER" "$NEW")" \
  "stop${T}local_nowcore${T}local/nowcore${T}-${T}the site has version 2026120100 of it, newer than the new Moodle's 2026010100, and Moodle can't go back to an older version"
make_site "$OLDNEWER" sitenewer
H="$WORK/sitenewer/html"
OUT="$(upgrade_site sitenewer)"
RC=$?
assert_eq "upgrade.sh refuses with status 3, so the entrypoint keeps the old code running" "3" "$RC"
assert_contains "and says why" "$OUT" "local_nowcore: the site has version 2026120100 of it"
assert_contains "and what to do: uninstall it in Moodle, then delete its folder" "$OUT" \
  "Uninstall it in Moodle while the site still runs this code"
assert_contains "naming the folder" "$OUT" "then delete its folder, local/nowcore"

assert_file "the old code is untouched" "$H/version.php"
assert_absent "nothing was moved aside" "$H/clouve/upgrade-previous"
assert_absent "and Moodle's upgrade never ran" "$WORK/sitenewer/moodledata/cli.log"

echo "upgrade.sh: such a plugin whose folder was deleted, while Moodle still has its newer version recorded"
RECORDED="$WORK/recorded-newer"
printf 'mod_assign\t2026010100\nlocal_nowcore\t2026120100\n' > "$RECORDED"
chmod 644 "$RECORDED"
assert_contains "the plan says to stop" "$(php "$HELPER" "$OLD50" "$NEW" "$RECORDED")" \
  "stop${T}local_nowcore${T}-${T}-${T}Moodle has version 2026120100 of it recorded, newer than the new Moodle's 2026010100, and Moodle can't go back to an older version"
printf 'local_nowcore\t2026010100\n' > "$WORK/recorded-same"
chmod 644 "$WORK/recorded-same"
assert_not_contains "but not when the recorded version is the new Moodle's own" \
  "$(php "$HELPER" "$OLD50" "$NEW" "$WORK/recorded-same")" "stop${T}"
make_site "$OLD50" siterecorded
H="$WORK/siterecorded/html"
OUT="$(upgrade_site siterecorded STUB_RECORDED="$RECORDED" DB_HOST=db.invalid DB_NAME=moodle DB_USER=moodle \
  DB_PASSWORD=Not-A-Real-Password-1)"
RC=$?
assert_eq "upgrade.sh refuses with status 3, before it changes anything" "3" "$RC"
assert_contains "and says why" "$OUT" "local_nowcore: Moodle has version 2026120100 of it recorded"
assert_absent "nothing was moved aside" "$H/clouve/upgrade-previous"
assert_absent "and Moodle's upgrade never ran" "$WORK/siterecorded/moodledata/cli.log"
assert_not_contains "the password never goes on mysql's command line" \
  "$(cat "$WORK/siterecorded/moodledata/mysql.log" 2>/dev/null)" "Not-A-Real-Password-1"

echo "upgrade.sh: one added plugin's upgrade step fails, and Moodle names it"
make_site "$OLD50" siteculprit
H="$WORK/siteculprit/html"
OUT="$(upgrade_site siteculprit STUB_FAIL_WITH=public/local/academictranscript STUB_CULPRIT=local_academictranscript)"
RC=$?
STASH="$(stash_of siteculprit)"
assert_eq "the site comes up" "0" "$RC"
assert_absent "without that plugin" "$H/public/local/academictranscript"
assert_file "which is in the stash" "$STASH/local/academictranscript/version.php"
assert_file "while the other added plugins stay" "$H/public/mod/assign/submission/extra/version.php"
assert_contains "the log names it and says why" "$OUT" \
  "local_academictranscript held back (Moodle's upgrade failed twice while upgrading it)"

# --- The previous Moodle to the image's Moodle, on the real releases' metadata ---------
# The trees above are made up. This run builds the old and new trees from the real releases (the previous pinned build
# and the Dockerfile's): their lib/components.json, lib/plugins.json, public/version.php and every db/subplugins.json,
# and the old release's real Classic theme. The added plugins are the ZIPs in MOODLE_PLUGIN_ZIPS (each holds one top
# folder named after its plugin, as Moodle's plugin installer wants), or stand-ins when it isn't set, plus one plugin
# whose supported range ends at the old release. Each plugin is in a folder of its own: $SRC/<n>/<plugin name>.
REAL_OLD="$WORK/realold"
REAL_NEW="$WORK/realnew"
extract_meta() {
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" --strip-components=1 --wildcards 'moodle/lib/components.json' 'moodle/lib/plugins.json' \
    'moodle/public/version.php' '*/db/subplugins.json' "${@:3}"
}
extract_meta "$PREV_TGZ" "$REAL_OLD" 'moodle/public/theme/classic/*'
extract_meta "$NEW_TGZ" "$REAL_NEW"
cp -a "$NEW/admin" "$REAL_NEW/admin"
# version_field <version.php> <name>: one value of a version.php ($branch, $release) or of its $plugin.
version_field() {
  php -r 'define("MOODLE_INTERNAL", true); define("MATURITY_STABLE", 200); define("MATURITY_BETA", 100);
    define("MATURITY_ALPHA", 50); define("MATURITY_RC", 150); define("ANY_VERSION", "any"); $plugin = new stdClass();
    include $argv[1]; $v = $plugin->{$argv[2]} ?? ${$argv[2]} ?? ""; echo is_scalar($v) ? $v : json_encode($v);' \
    "$1" "$2" 2>/dev/null
}
# type_dir <tree> <type>: the folder of a plugin type, from the tree's lib/components.json.
type_dir() {
  php -r '$c = json_decode(file_get_contents($argv[1]), true); echo $c["plugintypes"][$argv[2]] ?? "";' \
    "$1/lib/components.json" "$2"
}
PREV_BRANCH="$(version_field "$REAL_OLD/public/version.php" branch)"
NEW_BRANCH="$(version_field "$REAL_NEW/public/version.php" branch)"
PREV_REL="$(version_field "$REAL_OLD/public/version.php" release)"
NEW_REL="$(version_field "$REAL_NEW/public/version.php" release)"
echo "added-plugins.php and upgrade.sh: Moodle $PREV_REL to $NEW_REL, with the real releases' metadata"
SRC="$WORK/plugin-src"
mkdir -p "$SRC"
if [[ -n "$(ls -A /plugin-src 2>/dev/null)" ]]; then
  cp -a /plugin-src/. "$SRC/"
  echo "  The added plugins are the ZIPs' $(ls -d "$SRC"/*/*/ | wc -l | tr -d ' ') plugins"
else
  SUPPORTS="\$plugin->requires = 2024100700;"$'\n'"\$plugin->supported = [405, $NEW_BRANCH];"
  plugin "$SRC/1/sitetool" local_sitetool "$SUPPORTS"
  plugin "$SRC/2/childtheme" theme_childtheme "$SUPPORTS"$'\n'"\$plugin->dependencies = ['theme_boost' => 2024100700];"
  printf '<?php\n$THEME->name = '"'childtheme'"';\n$THEME->parents = ['"'boost'"'];\n' > "$SRC/2/childtheme/config.php"
  plugin "$SRC/3/needsfiveone" local_needsfiveone "\$plugin->requires = 2025100600;"
  echo "  The added plugins are stand-ins (set MOODLE_PLUGIN_ZIPS to use real ones)"
fi
plugin "$SRC/old/oldsupport" local_oldsupport "\$plugin->supported = [401, $PREV_BRANCH];"
EXPECTED=()
KEPT_PATHS=()
KEPT_SOURCES=()
for dir in "$SRC"/*/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  component="$(version_field "$dir/version.php" component)"
  type="${component%%_*}"
  old="$(type_dir "$REAL_OLD" "$type")/$name"
  new="$(type_dir "$REAL_NEW" "$type")/$name"
  mkdir -p "$(dirname "$REAL_OLD/$old")"
  cp -a "$dir" "$REAL_OLD/$old"
  if [[ "$component" == local_oldsupport ]]; then
    EXPECTED+=("skip${T}$component${T}$old${T}-${T}its version.php supports Moodle 401 to $PREV_BRANCH, not $NEW_BRANCH")
  else
    EXPECTED+=("keep${T}$component${T}$old${T}$new${T}-")
    KEPT_PATHS+=("$new")
    KEPT_SOURCES+=("$dir")
  fi
done
cat > "$REAL_OLD/config.php" <<'PHP'
<?php // site config
$CFG->theme = 'classic';
require_once(__DIR__ . '/lib/setup.php');
PHP
mkdir -p "$REAL_OLD/clouve/installed"
version_field "$REAL_OLD/public/version.php" version | cut -d. -f1 > "$REAL_OLD/clouve/installed/version"
chmod -R a+rX "$REAL_OLD" "$REAL_NEW"
assert_eq "the plan keeps the added plugins and holds back the one whose supported range ends at $PREV_BRANCH" \
  "$(printf '%s\n' "${EXPECTED[@]}" | sort)" "$(plan "$REAL_OLD" "$REAL_NEW")"
assert_not_contains "and never lists the Classic theme" "$(plan "$REAL_OLD" "$REAL_NEW")" "${T}theme_classic${T}"
make_site "$REAL_OLD" sitereal
H="$WORK/sitereal/html"
OUT="$(PKG="$REAL_NEW" upgrade_site sitereal)"
RC=$?
STASH="$(stash_of sitereal)"
assert_eq "exits 0" "0" "$RC"
for i in "${!KEPT_PATHS[@]}"; do
  new="${KEPT_PATHS[$i]}"
  if diff -r "${KEPT_SOURCES[$i]}" "$H/$new" >/dev/null; then pass "$new is back, file for file"; else
    fail "$new is back, file for file"; fi
done
assert_absent "the plugin whose supported range ends at $PREV_BRANCH is held back" "$H/public/local/oldsupport"
assert_file "in the stash" "$STASH/public/local/oldsupport/version.php"
assert_contains "and the log says why" "$OUT" \
  "local_oldsupport held back (its version.php supports Moodle 401 to $PREV_BRANCH, not $NEW_BRANCH)"
assert_absent "the old release's Classic theme is not carried over" "$H/public/theme/classic"
assert_absent "nor stashed" "$STASH/public/theme/classic"
assert_eq "Moodle's upgrade still sees Classic forced, so it moves Classic's settings to Boost" "classic forced=yes" \
  "$(cat "$WORK/sitereal/moodledata/theme.log")"
assert_contains "and afterwards config.php no longer forces Classic" "$(cat "$H/config.php")" \
  "; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \$CFG->theme = 'classic';"

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf "${GREEN}All checks passed.${NC}\n"
else
  printf "${RED}Some checks failed.${NC}\n"
fi
exit "$FAILED"
